#!/usr/bin/env bash
# backup-hermes.sh - disaster-recovery backup of a Hermes Agent home directory.
#
# Creates a compressed, timestamped, validated archive of the persistent
# (non-secret) Hermes data, stores it in a private local staging directory,
# then copies it off-box via a pluggable backend (upload_backup) and verifies
# the remote copy. Exits non-zero unless the off-box copy is verified.
#
# Exit codes:
#   0   archive created, validated, uploaded and verified off-box
#   1   unexpected error (backup NOT completed)
#   2   configuration / prerequisite error
#   3   local archive OK but off-box upload or verification FAILED
#       (also used with --no-upload: a local-only archive is not a backup)
#   4   secret guard tripped: a credential-like file reached the payload
#   75  another backup run holds the lock (EX_TEMPFAIL)
#
# See backup/README.md for setup and backup/TESTING.md for verification.

set -Eeuo pipefail
umask 077
export LC_ALL=C
# cron runs with a minimal PATH; rclone may live in /usr/local/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin:${HOME}/bin:${PATH:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: backup-hermes.sh [options]

  --config FILE    config file (default: $HERMES_BACKUP_CONFIG or
                   ~/.config/hermes-backup/config)
  --check          validate config and test the off-box destination; no backup
  --no-upload      create and validate a local archive only (testing).
                   Exits 3: a local-only archive is NOT disaster protection.
  -h, --help       show this help
EOF
}

CONFIG_ARG=""
MODE=backup
while (( $# )); do
    case "$1" in
        --config) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CONFIG_ARG="$2"; shift 2 ;;
        --check) MODE=check; shift ;;
        --no-upload) MODE=local; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

load_config "$CONFIG_ARG"
hb_set_defaults

ensure_private_dir "$STATE_DIR"
ensure_private_dir "${STATE_DIR}/logs"
LOG_FILE="${STATE_DIR}/logs/backup.log"
rotate_log "$LOG_FILE"
touch -- "$LOG_FILE" && chmod 600 -- "$LOG_FILE"

WORK_DIR=""
RUN_STATUS="FAILED"
# shellcheck disable=SC2317,SC2329  # EXIT trap invokes this cleanup handler indirectly.
on_exit() {
    local rc=$?
    if [[ -n "$WORK_DIR" ]]; then
        safe_rmtree "$WORK_DIR" "$LOCAL_BACKUP_DIR" || true
    fi
    if [[ "$MODE" == backup ]]; then
        printf '%s %s rc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_STATUS" "$rc" \
            >"${STATE_DIR}/last-status" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        error "Backup run finished with exit code ${rc} (${RUN_STATUS})"
    fi
}
trap on_exit EXIT
trap 'error "Command failed (line ${LINENO}): ${BASH_COMMAND}"' ERR

info "===== hermes backup start (mode=${MODE}, pid=$$) ====="
if [[ -n "${HB_CONFIG_FILE:-}" ]]; then info "Config: ${HB_CONFIG_FILE}"; else info "Config: none found, using defaults"; fi

# --- single-instance lock -------------------------------------------------
exec 9>"${STATE_DIR}/backup.lock"
if ! flock -n 9; then
    RUN_STATUS="SKIPPED_LOCKED"
    warn "Another backup run is in progress (lock ${STATE_DIR}/backup.lock); exiting"
    exit 75
fi

# --- preflight --------------------------------------------------------------
require_cmd tar gzip sha256sum flock find sort stat mktemp
require_gnu_tar
if ! is_uint "$LOCAL_KEEP" || (( LOCAL_KEEP < 1 )); then die 2 "LOCAL_KEEP must be an integer >= 1"; fi
is_uint "$REMOTE_KEEP" || die 2 "REMOTE_KEEP must be an integer (0 = never prune remote)"

if [[ "$MODE" != local ]]; then
    load_backend "$UPLOAD_BACKEND" "${SCRIPT_DIR}/lib"
    backend_preflight
fi

if [[ "$MODE" == check ]]; then
    backend_check || die 3 "Off-box destination check FAILED"
    info "Check OK: config valid and destination reachable"
    exit 0
fi

[[ -d "$HERMES_HOME" ]] || die 2 "HERMES_HOME is not a directory: ${HERMES_HOME}"
[[ -r "$HERMES_HOME" && -x "$HERMES_HOME" ]] || die 2 "HERMES_HOME is not readable: ${HERMES_HOME}"
HERMES_HOME=$(cd -- "$HERMES_HOME" && pwd -P)   # resolve a symlinked home once
[[ "$(sqlite_tool)" != none ]] || die 2 "Need sqlite3 (apt install sqlite3) or python3 for consistent state.db snapshots"
info "Hermes home: ${HERMES_HOME}; sqlite tool: $(sqlite_tool); backend: ${UPLOAD_BACKEND}"

ensure_private_dir "$LOCAL_BACKUP_DIR"
WORK_DIR=$(mktemp -d "${LOCAL_BACKUP_DIR}/.hb-work.XXXXXXXX")
STAGE_ROOT="${WORK_DIR}/stage"
PAYLOAD_DIR="${STAGE_ROOT}/hermes-backup"
ERRF="${WORK_DIR}/stderr"
mkdir -p -- "${PAYLOAD_DIR}/home"
: >"$ERRF"

HOST=$(sanitized_hostname)
TS=$(date -u +%Y%m%dT%H%M%SZ)
PREFIX="hermes-backup-${HOST}-"
ARCHIVE_NAME="${PREFIX}${TS}.tar.gz"
ARCHIVE="${LOCAL_BACKUP_DIR}/${ARCHIVE_NAME}"
SIDECAR="${ARCHIVE}.sha256"
[[ ! -e "$ARCHIVE" ]] || die 1 "Archive already exists: ${ARCHIVE}"

# --- select items -------------------------------------------------------------
in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

ALL_INCLUDES=("${INCLUDE_PATHS[@]}" "${EXTRA_INCLUDE_PATHS[@]}")
for p in "${ALL_INCLUDES[@]}"; do
    is_safe_relpath "$p" || die 2 "Unsafe include path in config: '${p}'"
done

ROOTS=(".")
if [[ "$INCLUDE_PROFILES" == yes && -d "${HERMES_HOME}/profiles" ]]; then
    while IFS= read -r -d '' prof; do
        pname=$(basename -- "$prof")
        if is_safe_relpath "profiles/${pname}"; then
            ROOTS+=("profiles/${pname}")
        else
            warn "Skipping profile with unsafe name: ${pname}"
        fi
    done < <(find "${HERMES_HOME}/profiles" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

ITEMS=()
for root in "${ROOTS[@]}"; do
    rootdir="${HERMES_HOME}/${root}"
    for p in "${ALL_INCLUDES[@]}"; do
        rel="${root#.}"; rel="${rel#/}"; rel="${rel:+${rel}/}${p}"
        src="${HERMES_HOME}/${rel}"
        if [[ -L "$src" ]]; then
            warn "Included path is a symlink; only the link itself is saved, NOT its target content: ${rel}"
            ITEMS+=("$rel")
        elif [[ -e "$src" ]]; then
            ITEMS+=("$rel")
        fi
    done
    # Report top-level entries we are not saving, so new Hermes data is noticed.
    skipped_known=()
    while IFS= read -r -d '' entry; do
        name=$(basename -- "$entry")
        if in_list "$name" "${ALL_INCLUDES[@]}"; then continue; fi
        if in_list "$name" "${HB_KNOWN_EXCLUDED_TOPLEVEL[@]}"; then skipped_known+=("$name"); continue; fi
        shown="$name"; [[ "$root" == . ]] || shown="${root}/${name}"
        warn "Not backed up (unknown entry, review it): ${shown} - add to EXTRA_INCLUDE_PATHS if it is user data"
    done < <(find "$rootdir" -mindepth 1 -maxdepth 1 -print0 | sort -z)
    if (( ${#skipped_known[@]} )); then
        info "Excluded by design in ${root}: ${skipped_known[*]}"
    fi
done
(( ${#ITEMS[@]} > 0 )) || die 1 "Nothing to back up under ${HERMES_HOME}"
info "Items to back up (${#ITEMS[@]}): ${ITEMS[*]}"

# --- build exclude list and report what it strips -----------------------------
EXCLUDES=("${HB_SECRET_PATTERNS[@]}" "${HB_DISPOSABLE_PATTERNS[@]}" "${EXTRA_EXCLUDE_PATTERNS[@]}")
TAR_EXCLUDES=()
FIND_SECRET_EXPR=()
for pat in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=("--exclude=${pat}"); done
for pat in "${HB_SECRET_PATTERNS[@]}"; do
    (( ${#FIND_SECRET_EXPR[@]} )) && FIND_SECRET_EXPR+=(-o)
    FIND_SECRET_EXPR+=(-name "$pat")
done

if cd -- "$HERMES_HOME"; then
    stripped=$(find "${ITEMS[@]}" -mindepth 1 \( "${FIND_SECRET_EXPR[@]}" \) -prune -print 2>/dev/null || true)
else
    stripped=""
fi
if [[ -n "$stripped" ]]; then
    while IFS= read -r line; do info "Excluded (credential pattern): ${line}"; done <<<"$stripped"
fi

# --- copy into private staging area -------------------------------------------
info "Copying items into staging area"
set +e
tar -C "$HERMES_HOME" --create --file=- "${TAR_EXCLUDES[@]}" -- "${ITEMS[@]}" 2>>"$ERRF" \
    | tar -C "${PAYLOAD_DIR}/home" --extract --file=- --no-same-owner 2>>"$ERRF"
pst=("${PIPESTATUS[@]}")
set -e
log_file_lines WARN "$ERRF"; : >"$ERRF"
if (( pst[0] == 1 )); then
    warn "Some files changed while being copied (Hermes is running); they are captured as of copy time"
elif (( pst[0] != 0 )); then
    die 1 "Copy to staging failed (tar create exit ${pst[0]})"
fi
(( pst[1] == 0 )) || die 1 "Copy to staging failed (tar extract exit ${pst[1]})"

# --- secret guard (defense in depth) -----------------------------------------
leaked=$(cd -- "${PAYLOAD_DIR}/home" && find . -mindepth 1 \( "${FIND_SECRET_EXPR[@]}" \) -print)
if [[ -n "$leaked" ]]; then
    while IFS= read -r line; do error "Credential-like path in payload: ${line}"; done <<<"$leaked"
    RUN_STATUS="SECRET_GUARD"
    die 4 "Secret guard tripped; refusing to create archive"
fi

# --- consistent SQLite snapshots ----------------------------------------------
while IFS= read -r -d '' staged; do
    rel="${staged#"${PAYLOAD_DIR}/home/"}"
    is_sqlite_file "$staged" || continue
    info "Snapshotting SQLite database ${rel}"
    snap="${staged}.hb-snapshot"
    if ! sqlite_snapshot "${HERMES_HOME}/${rel}" "$snap" 2>>"$ERRF"; then
        log_file_lines ERROR "$ERRF"
        die 1 "SQLite snapshot failed for ${rel}"
    fi
    sqlite_integrity_ok "$snap" || die 1 "SQLite integrity_check failed on snapshot of ${rel}"
    mv -f -- "$snap" "$staged"
done < <(find "${PAYLOAD_DIR}/home" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
# The copy step already excluded -wal/-shm/-journal files; nothing else to do.

# --- metadata -------------------------------------------------------------------
printf '%s\n' "${ITEMS[@]}" >"${PAYLOAD_DIR}/ITEMS"
file_count=$(find "${PAYLOAD_DIR}/home" -type f | wc -l)
hermes_rev="unknown"
if [[ -d "${HERMES_HOME}/hermes-agent/.git" ]] && command -v git >/dev/null 2>&1; then
    hermes_rev=$(git -C "${HERMES_HOME}/hermes-agent" rev-parse --short HEAD 2>/dev/null || echo unknown)
fi
{
    echo "format_version=1"
    echo "tool=hermes-backup"
    echo "created_utc=${TS}"
    echo "hostname=${HOST}"
    echo "source_hermes_home=${HERMES_HOME}"
    echo "hermes_agent_git_rev=${hermes_rev}"
    echo "items_count=${#ITEMS[@]}"
    echo "files_count=${file_count}"
    echo "secrets_excluded=yes"
} >"${PAYLOAD_DIR}/BACKUP_INFO"
(cd -- "$PAYLOAD_DIR" && find home -type f -print0 | sort -z | xargs -0 -r sha256sum --) \
    >"${PAYLOAD_DIR}/MANIFEST.sha256"
info "Payload: ${#ITEMS[@]} items, ${file_count} files"

# --- create archive ------------------------------------------------------------
PARTIAL="${LOCAL_BACKUP_DIR}/.${ARCHIVE_NAME}.partial"
info "Creating archive ${ARCHIVE_NAME}"
tar -C "$STAGE_ROOT" --create --gzip --file="$PARTIAL" --sort=name --numeric-owner \
    hermes-backup 2>>"$ERRF" || { log_file_lines ERROR "$ERRF"; die 1 "tar create failed"; }

# --- validate archive ----------------------------------------------------------
info "Validating archive"
gzip -t -- "$PARTIAL" || die 1 "gzip integrity test failed"
listing=$(tar -tzf "$PARTIAL") || die 1 "Cannot list archive"
for req in hermes-backup/BACKUP_INFO hermes-backup/ITEMS hermes-backup/MANIFEST.sha256; do
    grep -Fxq -- "$req" <<<"$listing" || die 1 "Archive is missing ${req}"
done
if ! tar -C "$STAGE_ROOT" --compare --gzip --file="$PARTIAL" >"$ERRF" 2>&1; then
    log_file_lines ERROR "$ERRF"
    die 1 "Archive content does not match staged data"
fi
hash=$(sha256sum <"$PARTIAL" | cut -d' ' -f1)
printf '%s  %s\n' "$hash" "$ARCHIVE_NAME" >"${SIDECAR}.partial"
mv -- "$PARTIAL" "$ARCHIVE"
mv -- "${SIDECAR}.partial" "$SIDECAR"
chmod 600 -- "$ARCHIVE" "$SIDECAR"
info "Archive OK: ${ARCHIVE} ($(stat -c %s -- "$ARCHIVE") bytes, sha256 ${hash})"

safe_rmtree "$WORK_DIR" "$LOCAL_BACKUP_DIR"
WORK_DIR=""

# --- off-box --------------------------------------------------------------------
if [[ "$MODE" == local ]]; then
    RUN_STATUS="LOCAL_ONLY"
    warn "--no-upload: archive exists ONLY on this machine; this is NOT a completed backup"
    exit 3
fi

if ! upload_backup "$ARCHIVE" "$SIDECAR"; then
    RUN_STATUS="UPLOAD_FAILED"
    die 3 "Off-box upload FAILED; archive kept locally at ${ARCHIVE}"
fi
if ! verify_remote_backup "$ARCHIVE" "$SIDECAR"; then
    RUN_STATUS="VERIFY_FAILED"
    die 3 "Off-box verification FAILED; archive kept locally at ${ARCHIVE}"
fi
info "Off-box copy verified"

# --- retention (only after a verified off-box copy) ----------------------------
mapfile -t local_archives < <(find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f -name "${PREFIX}*.tar.gz" -printf '%f\n' | sort)
excess=$(( ${#local_archives[@]} - LOCAL_KEEP ))
for (( i = 0; i < excess; i++ )); do
    old="${local_archives[$i]}"
    is_backup_archive_name "$old" || continue
    info "Pruning local staging copy ${old}"
    rm -f -- "${LOCAL_BACKUP_DIR}/${old}" "${LOCAL_BACKUP_DIR}/${old}.sha256"
done

if (( REMOTE_KEEP > 0 )); then
    prune_remote_backups "$PREFIX" "$REMOTE_KEEP" || warn "Remote pruning failed (backup itself is fine)"
fi

RUN_STATUS="OK"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ARCHIVE_NAME" >"${STATE_DIR}/last-success"
info "===== hermes backup OK: ${ARCHIVE_NAME} ====="
exit 0
