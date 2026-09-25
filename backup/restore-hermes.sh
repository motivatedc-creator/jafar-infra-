#!/usr/bin/env bash
# restore-hermes.sh - validate and restore a hermes-backup archive.
#
# Safe by default:
#   * the archive is fully validated (checksum sidecar, gzip, entry names and
#     types, per-file SHA-256 manifest, SQLite integrity) before anything in
#     the target is touched;
#   * existing files are never deleted or overwritten in place: anything that
#     would be replaced is first moved to <target>.pre-restore-<timestamp>/;
#   * replacing existing data requires explicit confirmation;
#   * only the items recorded in the archive are touched. Secrets (.env,
#     auth.json, OAuth tokens, ...) are not in the archive and are left alone.
#
# Exit codes: 0 ok, 1 error, 2 usage/config error, 5 validation failed,
#             6 aborted by user / confirmation missing.

set -Eeuo pipefail
umask 077
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.local/bin:${HOME}/bin:${PATH:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage:
  restore-hermes.sh [options] ARCHIVE.tar.gz
  restore-hermes.sh [options] --fetch NAME|latest
  restore-hermes.sh [--config FILE] --list-remote

Modes (default: restore):
  --inspect           validate the archive and list its contents; change nothing
  --dry-run           validate and show exactly what would change in the
                      target; change nothing

Options:
  --target DIR        Hermes home to restore into
                      (default: HERMES_HOME from config, i.e. /home/dietpi/.hermes)
  --owner USER        owner of restored files (default: HERMES_USER, i.e. dietpi)
  --only PATH         restore only this item/subtree; repeatable
                      (e.g. --only memories --only profiles/work)
  --yes               confirm replacing existing items non-interactively
                      (they are still moved aside, never deleted)
  --allow-running     proceed although Hermes processes seem to be running
  --require-checksum  fail if there is no ARCHIVE.sha256 next to the archive
  --fetch NAME|latest download the archive from the configured backend first
  --download-dir DIR  where --fetch stores it (default: ~/hermes-restore-downloads)
  --list-remote       list archives on the configured backend and exit
  --config FILE       config file (default: $HERMES_BACKUP_CONFIG or
                      ~/.config/hermes-backup/config; optional for restore)
  -h, --help          show this help
EOF
}

MODE=restore
CONFIG_ARG="" TARGET_ARG="" OWNER_ARG="" ARCHIVE="" FETCH="" DOWNLOAD_DIR=""
ASSUME_YES=no ALLOW_RUNNING=no REQUIRE_CHECKSUM=no LIST_REMOTE=no
ONLY=()
need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "Option $1 needs a value" >&2; exit 2; }; }
while (( $# )); do
    case "$1" in
        --inspect) MODE=inspect; shift ;;
        --dry-run) MODE=dry-run; shift ;;
        --target) need_arg "$@"; TARGET_ARG="$2"; shift 2 ;;
        --owner) need_arg "$@"; OWNER_ARG="$2"; shift 2 ;;
        --only) need_arg "$@"; ONLY+=("${2%/}"); shift 2 ;;
        --yes) ASSUME_YES=yes; shift ;;
        --allow-running) ALLOW_RUNNING=yes; shift ;;
        --require-checksum) REQUIRE_CHECKSUM=yes; shift ;;
        --fetch) need_arg "$@"; FETCH="$2"; shift 2 ;;
        --download-dir) need_arg "$@"; DOWNLOAD_DIR="$2"; shift 2 ;;
        --list-remote) LIST_REMOTE=yes; shift ;;
        --config) need_arg "$@"; CONFIG_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; ARCHIVE="${1:-}"; shift || true ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) [[ -z "$ARCHIVE" ]] || { echo "Only one archive may be given" >&2; exit 2; }
           ARCHIVE="$1"; shift ;;
    esac
done

load_config "$CONFIG_ARG"
hb_set_defaults
TARGET="${TARGET_ARG:-$HERMES_HOME}"
TARGET="${TARGET%/}"
OWNER="${OWNER_ARG:-$HERMES_USER}"
: "${DOWNLOAD_DIR:=${HOME}/hermes-restore-downloads}"

# Log to stderr and, when possible, to a private restore log.
HB_LOG_STDERR=yes
if ensure_private_dir "${STATE_DIR}/logs" 2>/dev/null; then
    LOG_FILE="${STATE_DIR}/logs/restore.log"
    touch -- "$LOG_FILE" 2>/dev/null && chmod 600 -- "$LOG_FILE" || LOG_FILE=""
fi

require_cmd tar gzip sha256sum find sort stat mktemp mv
require_gnu_tar

# --- remote listing / fetching ---------------------------------------------
# Names look like hermes-backup-<host>-<YYYYmmddTHHMMSSZ>.tar.gz; order by
# timestamp across all hosts (a rebuilt machine may have a new hostname).
sort_by_timestamp() { awk '{ n = $0; sub(/\.tar\.gz$/, "", n); print substr(n, length(n) - 15) "\t" $0 }' | sort | cut -f2-; }

if [[ "$LIST_REMOTE" == yes || -n "$FETCH" ]]; then
    load_backend "$UPLOAD_BACKEND" "${SCRIPT_DIR}/lib"
    backend_preflight
fi
if [[ "$LIST_REMOTE" == yes ]]; then
    list_remote_backups "hermes-backup-" | sort_by_timestamp
    exit 0
fi
if [[ -n "$FETCH" ]]; then
    [[ -z "$ARCHIVE" ]] || die 2 "Give either an ARCHIVE path or --fetch, not both"
    if [[ "$FETCH" == latest ]]; then
        FETCH=$(list_remote_backups "hermes-backup-" | sort_by_timestamp | tail -n 1)
        [[ -n "$FETCH" ]] || die 1 "No backups found on the remote"
    fi
    is_backup_archive_name "$FETCH" || die 2 "Not a valid backup archive name: ${FETCH}"
    ensure_private_dir "$DOWNLOAD_DIR"
    info "Downloading ${FETCH} into ${DOWNLOAD_DIR}"
    download_backup "$FETCH" "$DOWNLOAD_DIR" || die 1 "Download failed"
    ARCHIVE="${DOWNLOAD_DIR}/${FETCH}"
fi
[[ -n "$ARCHIVE" ]] || { usage >&2; exit 2; }

# --- state for cleanup / failure reporting ------------------------------------
WORK_DIR="" WORK_PARENT="" SAFETY_DIR="" APPLYING=no
RESTORED=() MOVED_ASIDE=()
# shellcheck disable=SC2329  # invoked via trap
on_exit() {
    local rc=$?
    if [[ "$APPLYING" == yes && $rc -ne 0 ]]; then
        error "RESTORE DID NOT COMPLETE. Target may be partially restored: ${TARGET}"
        (( ${#RESTORED[@]} )) && error "Items already restored: ${RESTORED[*]}"
        if (( ${#MOVED_ASIDE[@]} )); then
            error "Your previous data for these items is intact in ${SAFETY_DIR}: ${MOVED_ASIDE[*]}"
            error "To roll back an item: mv '${TARGET}/<item>' somewhere, then mv '${SAFETY_DIR}/<item>' '${TARGET}/<item>'"
        fi
    fi
    if [[ -n "$WORK_DIR" ]]; then
        safe_rmtree "$WORK_DIR" "$WORK_PARENT" || true
    fi
}
trap on_exit EXIT
trap 'error "Command failed (line ${LINENO}): ${BASH_COMMAND}"' ERR

fail_validation() { error "VALIDATION FAILED: $*"; error "Nothing was changed."; exit 5; }

# --- 1. validate the archive file itself -----------------------------------------
[[ -f "$ARCHIVE" && -r "$ARCHIVE" ]] || die 2 "Archive not found or unreadable: ${ARCHIVE}"
ARCHIVE="$(cd -- "$(dirname -- "$ARCHIVE")" && pwd -P)/$(basename -- "$ARCHIVE")"
ARCHIVE_NAME=$(basename -- "$ARCHIVE")
info "Archive: ${ARCHIVE}"
[[ "$ARCHIVE_NAME" == *.tar.gz ]] || fail_validation "archive name must end in .tar.gz"
is_backup_archive_name "$ARCHIVE_NAME" || warn "Archive name does not follow the usual hermes-backup naming"

if [[ -f "${ARCHIVE}.sha256" ]]; then
    want=$(cut -d' ' -f1 <"${ARCHIVE}.sha256")
    got=$(sha256sum <"$ARCHIVE" | cut -d' ' -f1)
    [[ -n "$want" && "$got" == "$want" ]] || fail_validation "SHA-256 does not match ${ARCHIVE_NAME}.sha256"
    info "Checksum sidecar OK (${got})"
elif [[ "$REQUIRE_CHECKSUM" == yes ]]; then
    fail_validation "no checksum sidecar ${ARCHIVE_NAME}.sha256 (--require-checksum)"
else
    warn "No ${ARCHIVE_NAME}.sha256 next to the archive; relying on the internal manifest"
fi

gzip -t -- "$ARCHIVE" 2>/dev/null || fail_validation "gzip integrity test failed (corrupt or truncated)"

names_raw=$(tar -tzf "$ARCHIVE") || fail_validation "cannot list archive"
vlines_raw=$(tar -tvzf "$ARCHIVE") || fail_validation "cannot list archive"
mapfile -t NAMES <<<"$names_raw"
mapfile -t VLINES <<<"$vlines_raw"
(( ${#NAMES[@]} == ${#VLINES[@]} && ${#NAMES[@]} > 0 )) || fail_validation "archive listing is inconsistent"
SYMLINKS=()
for i in "${!NAMES[@]}"; do
    n="${NAMES[$i]}"; t="${VLINES[$i]:0:1}"
    [[ "$n" == hermes-backup/* || "$n" == hermes-backup ]] || fail_validation "unexpected entry outside hermes-backup/: ${n}"
    is_safe_relpath "${n%/}" || fail_validation "unsafe entry name: ${n}"
    case "$t" in
        -|d|h) ;;
        l) target_of="${VLINES[$i]##* -> }"
           [[ "$target_of" != /* ]] || fail_validation "symlink with absolute target: ${n} -> ${target_of}"
           SYMLINKS+=("${n%/}") ;;
        *) fail_validation "unsupported entry type '${t}': ${n}" ;;
    esac
done
# Never extract anything *through* a symlink contained in the archive.
for s in "${SYMLINKS[@]}"; do
    for n in "${NAMES[@]}"; do
        [[ "$n" != "${s}/"* ]] || fail_validation "entry below a symlink: ${n}"
    done
done
for req in hermes-backup/BACKUP_INFO hermes-backup/ITEMS hermes-backup/MANIFEST.sha256; do
    printf '%s\n' "${NAMES[@]}" | grep -Fxq -- "$req" || fail_validation "missing ${req}"
done
info "Archive structure OK (${#NAMES[@]} entries)"

# --- 2. extract to a private scratch dir and verify contents -------------------
if [[ "$MODE" == restore ]]; then
    WORK_PARENT=$(dirname -- "$TARGET")
    [[ -d "$WORK_PARENT" && -w "$WORK_PARENT" ]] || die 2 "Parent of target is missing or not writable: ${WORK_PARENT}"
else
    WORK_PARENT="${TMPDIR:-/tmp}"
fi
WORK_PARENT=$(cd -- "$WORK_PARENT" && pwd -P)
WORK_DIR=$(mktemp -d "${WORK_PARENT}/.hermes-restore.XXXXXXXX")
tar -C "$WORK_DIR" --extract --gzip --file="$ARCHIVE" --no-same-owner \
    || fail_validation "extraction failed"
PAYLOAD="${WORK_DIR}/hermes-backup"

info_val() { grep -m1 "^$1=" "${PAYLOAD}/BACKUP_INFO" | cut -d= -f2- || true; }
[[ "$(info_val format_version)" == 1 ]] || fail_validation "unsupported backup format_version '$(info_val format_version)'"

(cd -- "$PAYLOAD" && sha256sum --check --strict --quiet MANIFEST.sha256) \
    || fail_validation "per-file SHA-256 manifest check failed"
manifest_count=$(grep -c . "${PAYLOAD}/MANIFEST.sha256" || true)
payload_count=$(find "${PAYLOAD}/home" -type f | wc -l)
(( manifest_count == payload_count )) || fail_validation "payload has ${payload_count} files but manifest lists ${manifest_count}"
info "Manifest OK (${payload_count} files verified)"

mapfile -t ITEMS < <(grep -v '^$' "${PAYLOAD}/ITEMS")
(( ${#ITEMS[@]} > 0 )) || fail_validation "ITEMS list is empty"
for it in "${ITEMS[@]}"; do
    is_safe_relpath "$it" || fail_validation "unsafe item path: ${it}"
    [[ -e "${PAYLOAD}/home/${it}" || -L "${PAYLOAD}/home/${it}" ]] || fail_validation "item missing from payload: ${it}"
done

while IFS= read -r -d '' db; do
    is_sqlite_file "$db" || continue
    rel="${db#"${PAYLOAD}/home/"}"
    if [[ "$(sqlite_tool)" == none ]]; then
        warn "Cannot check SQLite integrity of ${rel} (install sqlite3)"
    elif sqlite_integrity_ok "$db"; then
        info "SQLite integrity OK: ${rel}"
    else
        fail_validation "SQLite integrity_check failed: ${rel}"
    fi
done < <(find "${PAYLOAD}/home" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
info "ARCHIVE VALID"

# --- 3. describe ------------------------------------------------------------------
echo
echo "Backup info:"
sed 's/^/  /' "${PAYLOAD}/BACKUP_INFO"
echo

if [[ "$MODE" == inspect ]]; then
    echo "Items in archive:"
    for it in "${ITEMS[@]}"; do
        n=$(find "${PAYLOAD}/home/${it}" -type f | wc -l)
        printf '  %-40s %6s files  %s\n' "$it" "$n" "$(du -sh -- "${PAYLOAD}/home/${it}" | cut -f1)"
    done
    echo
    echo "All files:"
    (cd -- "${PAYLOAD}/home" && find . -mindepth 1 \( -type f -o -type l \) -printf '  %M %10s  %P\n' | sort -k3)
    exit 0
fi

SELECTED=()
if (( ${#ONLY[@]} )); then
    for o in "${ONLY[@]}"; do
        is_safe_relpath "$o" || die 2 "Unsafe --only path: ${o}"
    done
    for it in "${ITEMS[@]}"; do
        for o in "${ONLY[@]}"; do
            if [[ "$it" == "$o" || "$it" == "$o/"* ]]; then SELECTED+=("$it"); break; fi
        done
    done
    (( ${#SELECTED[@]} )) || die 2 "--only matched no items. Items in archive: ${ITEMS[*]}"
else
    SELECTED=("${ITEMS[@]}")
fi

CONFLICTS=()
echo "Restore plan (target: ${TARGET}, owner: ${OWNER}):"
for it in "${SELECTED[@]}"; do
    if [[ -e "${TARGET}/${it}" || -L "${TARGET}/${it}" ]]; then
        CONFLICTS+=("$it")
        printf '  REPLACE  %s   (existing copy will be moved aside)\n' "$it"
    else
        printf '  NEW      %s\n' "$it"
    fi
done
echo
echo "Not in the backup and NOT touched (recreate/re-authenticate manually):"
echo "  .env, auth.json, OAuth/MCP tokens, pairing data, WhatsApp session, logs, caches, Hermes code"
echo

if [[ "$MODE" == dry-run ]]; then
    (( ${#CONFLICTS[@]} )) && echo "Existing items would be moved to: ${TARGET}.pre-restore-<timestamp>/"
    info "Dry run: nothing was changed"
    exit 0
fi

# --- 4. pre-flight for the actual restore -----------------------------------------
IS_ROOT=no
[[ "$(id -u)" == 0 ]] && IS_ROOT=yes
id -u -- "$OWNER" >/dev/null 2>&1 || die 2 "Owner user does not exist: ${OWNER}"
OWNER_GROUP=$(id -gn -- "$OWNER")
if [[ "$IS_ROOT" == no && "$(id -un)" != "$OWNER" ]]; then
    die 2 "Run as ${OWNER} (or as root) so restored files get the right owner; you are $(id -un)"
fi

live_home() { local h; h=$(getent passwd "$OWNER" | cut -d: -f6); printf '%s/.hermes' "${h%/}"; }
canon() { if [[ -d "$1" ]]; then (cd -- "$1" && pwd -P); else printf '%s' "$1"; fi; }
IS_LIVE=no
if [[ "$(canon "$TARGET")" == "$(canon "$(live_home)")" || "$(canon "$TARGET")" == "$(canon "$HERMES_HOME")" ]]; then
    IS_LIVE=yes
fi
if command -v pgrep >/dev/null 2>&1; then
    running=$(pgrep -a -u "$OWNER" -f hermes 2>/dev/null \
        | grep -Ev '(restore|backup)-hermes\.sh' | grep -v "^$$ " || true)
    if [[ -n "$running" ]]; then
        warn "Processes that look like Hermes are running as ${OWNER}:"
        while IFS= read -r l; do warn "  ${l}"; done <<<"$running"
        if [[ "$IS_LIVE" == yes && "$ALLOW_RUNNING" != yes ]]; then
            die 6 "Stop Hermes (CLI sessions and gateway) before restoring into the live home, or pass --allow-running"
        fi
    fi
else
    warn "pgrep not available; cannot check whether Hermes is running. Stop it before restoring."
fi

if (( ${#CONFLICTS[@]} )); then
    echo "${#CONFLICTS[@]} existing item(s) in ${TARGET} will be replaced (moved aside, not deleted)."
fi
if [[ "$ASSUME_YES" != yes ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Type 'restore' to proceed: " answer
        [[ "$answer" == restore ]] || die 6 "Aborted by user; nothing was changed"
    elif (( ${#CONFLICTS[@]} )); then
        die 6 "Existing data would be replaced and there is no terminal to confirm; re-run with --yes"
    fi
fi

# --- 5. apply ----------------------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%M%SZ)
APPLYING=yes
if [[ ! -d "$TARGET" ]]; then
    info "Creating ${TARGET}"
    mkdir -p -- "$TARGET"
fi
chmod 700 -- "$TARGET"
if (( ${#CONFLICTS[@]} )); then
    SAFETY_DIR="${TARGET}.pre-restore-${TS}"
    [[ ! -e "$SAFETY_DIR" ]] || die 1 "Safety directory already exists: ${SAFETY_DIR}"
    mkdir -m 700 -- "$SAFETY_DIR"
    info "Existing items will be moved to ${SAFETY_DIR}"
fi

for it in "${SELECTED[@]}"; do
    dest="${TARGET}/${it}"
    if [[ -e "$dest" || -L "$dest" ]]; then
        mkdir -p -- "$(dirname -- "${SAFETY_DIR}/${it}")"
        mv -- "$dest" "${SAFETY_DIR}/${it}"
        MOVED_ASIDE+=("$it")
        info "Moved aside: ${it}"
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    mv -- "${PAYLOAD}/home/${it}" "$dest"
    RESTORED+=("$it")
    info "Restored: ${it}"
done

# Permissions: private to the owner. Ownership: only needed when run as root.
for it in "${SELECTED[@]}"; do
    dest="${TARGET}/${it}"
    [[ -L "$dest" ]] || chmod -R go-rwx -- "$dest"
    if [[ "$IS_ROOT" == yes ]]; then
        chown -R -h -- "${OWNER}:${OWNER_GROUP}" "$dest"
        d=$(dirname -- "$dest")
        while [[ "$d" != "$TARGET" && "$d" == "$TARGET"/* ]]; do
            chown -h -- "${OWNER}:${OWNER_GROUP}" "$d"; chmod go-rwx -- "$d"
            d=$(dirname -- "$d")
        done
    fi
done
if [[ "$IS_ROOT" == yes ]]; then
    chown -h -- "${OWNER}:${OWNER_GROUP}" "$TARGET"
    [[ -z "$SAFETY_DIR" ]] || chown -R -h -- "${OWNER}:${OWNER_GROUP}" "$SAFETY_DIR"
fi
APPLYING=no

info "RESTORE COMPLETE: ${#RESTORED[@]} item(s) into ${TARGET}"
[[ -z "$SAFETY_DIR" ]] || info "Previous versions kept in ${SAFETY_DIR} (remove it yourself once satisfied)"

cat <<EOF

Next steps (secrets were intentionally NOT backed up):
  1. Make sure Hermes itself is installed for ${OWNER} (see backup/README.md).
  2. Recreate ${TARGET}/.env with your API keys / bot tokens (chmod 600).
  3. Re-authenticate providers that used OAuth / auth.json (e.g. run 'hermes setup'
     or the provider's login flow).
  4. Re-authenticate OAuth MCP servers ('hermes mcp login <server>') and
     Google Workspace if you used it.
  5. Re-pair messaging platforms that need it (WhatsApp QR, DM pairing approvals).
  6. Start Hermes and check your memories, skills, sessions and cron jobs.
EOF
exit 0
