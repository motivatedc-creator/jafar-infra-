# shellcheck shell=bash
# Shared helpers for backup-hermes.sh / restore-hermes.sh.
# Sourced, never executed directly.

# ---------------------------------------------------------------------------
# Defaults. Every value can be overridden in the config file
# (see backup/config.example). Nothing in here is a secret.
# ---------------------------------------------------------------------------
hb_set_defaults() {
    : "${HERMES_USER:=dietpi}"
    : "${HERMES_HOME:=/home/${HERMES_USER}/.hermes}"
    : "${LOCAL_BACKUP_DIR:=${HOME}/hermes-backups}"
    : "${LOCAL_KEEP:=3}"
    : "${STATE_DIR:=${HOME}/.local/state/hermes-backup}"
    : "${LOG_MAX_BYTES:=5242880}"
    : "${INCLUDE_PROFILES:=yes}"
    : "${UPLOAD_BACKEND:=rclone}"
    : "${REMOTE_KEEP:=0}"
    : "${RCLONE_BIN:=rclone}"
    : "${RCLONE_REMOTE:=}"
    : "${RCLONE_CONFIG_FILE:=}"
    : "${RCLONE_VERIFY:=download}"
    : "${LOCALDIR_DEST:=}"
    : "${LOCALDIR_ALLOW_SAME_FS:=no}"

    # Paths (relative to HERMES_HOME, and to each profiles/<name>/) that are
    # backed up. Anything not listed here is NOT backed up.
    if ! declare -p INCLUDE_PATHS >/dev/null 2>&1; then
        INCLUDE_PATHS=(
            config.yaml
            SOUL.md
            memories
            skills
            cron
            sessions
            hooks
            state.db
            # Durable, user/agent-created SQLite state that is not reconstructable
            # from anything else in the backup (see backup/README.md for the
            # evidence behind including these two):
            kanban.db       # Kanban task board: tasks, boards, comments (default board only)
            shared-state.db # Bot Mode "hosted rooms": durable group-chat room identity/membership
        )
    fi
    if ! declare -p EXTRA_INCLUDE_PATHS >/dev/null 2>&1; then
        EXTRA_INCLUDE_PATHS=()
    fi
    if ! declare -p EXTRA_EXCLUDE_PATTERNS >/dev/null 2>&1; then
        EXTRA_EXCLUDE_PATTERNS=()
    fi
    if ! declare -p RCLONE_EXTRA_FLAGS >/dev/null 2>&1; then
        RCLONE_EXTRA_FLAGS=()
    fi
}

# Credential-bearing file/dir names. Excluded anywhere inside included paths,
# and the staged payload is re-scanned for them before archiving (a hit aborts
# the backup). Matched against every path component (GNU tar --exclude and
# find -name semantics).
# shellcheck disable=SC2034  # used by the scripts that source this file
HB_SECRET_PATTERNS=(
    '.env' '.env.*' '*.env'
    'auth.json' 'auth' 'credentials' 'credentials.json' 'token.json'
    '.anthropic_oauth.json' 'google_token.json' 'google_oauth_pending.json'
    'google_oauth.json' '*_oauth.json' 'mcp-tokens' 'pairing'
    '.netrc' '.git-credentials' '.pgpass' 'rclone.conf'
    'id_rsa' 'id_rsa.*' 'id_ed25519' 'id_ed25519.*' 'id_ecdsa' 'id_ecdsa.*'
    '*.pem' '*.key' '*.p12' '*.pfx' '*.kdbx' '*.gpg-agent'
)

# Disposable / regenerable data excluded inside included paths.
# shellcheck disable=SC2034
HB_DISPOSABLE_PATTERNS=(
    '__pycache__' '*.pyc' 'node_modules' '.venv' 'venv' '.cache'
    '.hub' '*.tmp' '*.temp' '*.swp' '*.swo' '*~' '.DS_Store'
    '*.db-wal' '*.db-shm' '*.db-journal'
    '*.sqlite-wal' '*.sqlite-shm' '*.sqlite-journal'
    '*.sqlite3-wal' '*.sqlite3-shm' '*.sqlite3-journal'
    '*.pid' '*.sock'
    # Hermes' own advisory lock files (MEMORY.md.lock, .usage.json.lock,
    # cron/.jobs.lock, cron/.tick.lock). Deliberately not a bare '*.lock':
    # skills may ship real lockfiles such as uv.lock or Cargo.lock.
    '*.md.lock' '*.json.lock' '.*.lock'
)

# Top-level entries of a Hermes home that are deliberately NOT backed up.
# Used only to classify what we skip so the log can flag *unknown* entries.
# shellcheck disable=SC2034
HB_KNOWN_EXCLUDED_TOPLEVEL=(
    # secrets / credentials
    .env auth.json auth credentials .anthropic_oauth.json google_token.json
    google_oauth_pending.json mcp-tokens pairing whatsapp
    # runtimes / code (reinstallable)
    hermes-agent hermes-office node bin venv .venv
    # caches, logs, scratch (regenerable)
    cache image_cache audio_cache document_cache logs sandboxes checkpoints
    # kanban/ (the directory, not kanban.db the file): worker scratch
    # workspaces (~/.hermes/kanban/workspaces/<id>/, ephemeral by design) plus
    # any additional named boards (~/.hermes/kanban/boards/<slug>/kanban.db).
    # Only the default board's top-level kanban.db is backed up today; a
    # non-default board's tasks are NOT covered — see backup/README.md.
    kanban
    # handled separately
    profiles state.db-wal state.db-shm state.db-journal
)

# ---------------------------------------------------------------------------
# Logging. Never pass secrets to these functions.
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-}"
HB_LOG_STDERR="${HB_LOG_STDERR:-auto}"

log() {
    local level="$1"; shift
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [${level}] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || printf '%s\n' "$line" >&2
    fi
    if [[ -z "$LOG_FILE" || "$HB_LOG_STDERR" == yes || ( "$HB_LOG_STDERR" == auto && -t 2 ) ]]; then
        printf '%s\n' "$line" >&2
    fi
}
info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }

# Log every line of a file (e.g. captured stderr of a tool) at a level.
log_file_lines() {
    local level="$1" file="$2" line
    [[ -s "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        log "$level" "  | ${line}"
    done <"$file"
}

die() {
    local code="$1"; shift
    error "$@"
    exit "$code"
}

# Rotate the log once it exceeds LOG_MAX_BYTES (keeps one old copy).
rotate_log() {
    local f="$1" size
    [[ -f "$f" ]] || return 0
    size=$(stat -c %s -- "$f")
    if (( size > LOG_MAX_BYTES )); then
        mv -f -- "$f" "${f}.1"
    fi
}

# ---------------------------------------------------------------------------
# Config loading. The config file is sourced as bash, so it must be owned by
# the invoking user (or root) and must not be group/world writable.
# ---------------------------------------------------------------------------
load_config() {
    local explicit="$1" file owner mode
    if [[ -n "$explicit" ]]; then
        file="$explicit"
    elif [[ -n "${HERMES_BACKUP_CONFIG:-}" ]]; then
        file="$HERMES_BACKUP_CONFIG"
    else
        file="${HOME}/.config/hermes-backup/config"
        if [[ ! -e "$file" ]]; then
            HB_CONFIG_FILE=""
            return 0
        fi
    fi
    [[ -f "$file" && -r "$file" ]] || die 2 "Config file not found or unreadable: ${file}"
    owner=$(stat -c %u -- "$file")
    mode=$(stat -c %a -- "$file")
    if [[ "$owner" != "$(id -u)" && "$owner" != 0 ]]; then
        die 2 "Refusing to source config ${file}: owned by uid ${owner}, not by you"
    fi
    if (( (8#$mode & 8#022) != 0 )); then
        die 2 "Refusing to source config ${file}: mode ${mode} is group/world writable (chmod 600 it)"
    fi
    # shellcheck source=/dev/null
    source "$file"
    # shellcheck disable=SC2034  # read by the calling script
    HB_CONFIG_FILE="$file"
}

# ---------------------------------------------------------------------------
# Filesystem safety helpers
# ---------------------------------------------------------------------------

# Remove a scratch directory that THIS tool created. Refuses anything that is
# not a real directory whose basename carries one of our scratch prefixes and
# whose parent is the expected parent. This is the only recursive delete in
# the toolset.
safe_rmtree() {
    local dir="$1" expected_parent="$2" base parent
    [[ -n "$dir" && -n "$expected_parent" ]] || return 0
    [[ -d "$dir" && ! -L "$dir" ]] || return 0
    base=$(basename -- "$dir")
    parent=$(cd -- "$(dirname -- "$dir")" && pwd -P)
    expected_parent=$(cd -- "$expected_parent" && pwd -P)
    case "$base" in
        .hb-work.*|.hermes-restore.*) ;;
        *) error "safe_rmtree: refusing to remove unexpected path: ${dir}"; return 1 ;;
    esac
    if [[ "$parent" != "$expected_parent" ]]; then
        error "safe_rmtree: refusing to remove ${dir} (parent ${parent} != ${expected_parent})"
        return 1
    fi
    rm -rf --one-file-system -- "$dir"
}

ensure_private_dir() {
    local d="$1"
    mkdir -p -- "$d"
    chmod 700 -- "$d"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die 2 "Required command not found: ${c}"
    done
}

require_gnu_tar() {
    tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar' \
        || die 2 "GNU tar is required (Debian package: tar)"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# A relative path with no empty, '.' or '..' components and no leading '-'.
is_safe_relpath() {
    local p="$1" part
    [[ -n "$p" && "$p" != /* && "$p" != -* ]] || return 1
    local IFS=/
    for part in $p; do
        [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    done
    return 0
}

sanitized_hostname() {
    local h
    h=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)
    h=${h//[^A-Za-z0-9._-]/_}
    printf '%s' "${h:-unknown-host}"
}

# ---------------------------------------------------------------------------
# SQLite helpers (sqlite3 CLI preferred, python3 stdlib as fallback)
# ---------------------------------------------------------------------------
sqlite_tool() {
    if command -v sqlite3 >/dev/null 2>&1; then
        echo sqlite3
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' 2>/dev/null; then
        echo python3
    else
        echo none
    fi
}

is_sqlite_file() {
    local f="$1" magic
    [[ -f "$f" && ! -L "$f" ]] || return 1
    magic=$(head -c 15 -- "$f" 2>/dev/null | tr -d '\0') || return 1
    [[ "$magic" == "SQLite format 3" ]]
}

# Consistent online snapshot via the SQLite backup API (safe while Hermes
# is writing; includes committed WAL content). The copy is switched to
# rollback-journal mode so it is a single self-contained file; Hermes can
# switch it back to WAL when it next opens it.
sqlite_snapshot() {
    local src="$1" dst="$2"
    case "$(sqlite_tool)" in
        python3)
            python3 - "$src" "$dst" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1], timeout=60)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
src.close()
dst.execute("PRAGMA journal_mode=DELETE").fetchall()
dst.close()
PY
            ;;
        sqlite3)
            # .backup takes the destination path as a quoted argument; refuse
            # paths that would break the quoting instead of trying to escape.
            [[ "$dst" != *"'"* && "$dst" != *\\* ]] || { error "Unsafe snapshot path: ${dst}"; return 1; }
            sqlite3 -bail -cmd '.timeout 60000' "$src" ".backup main '${dst}'" \
                && sqlite3 -bail "$dst" 'PRAGMA journal_mode=DELETE;' >/dev/null
            ;;
        *)
            error "Neither sqlite3 nor python3 (with sqlite3 module) is available"
            return 1
            ;;
    esac
}

sqlite_integrity_ok() {
    local db="$1" out
    case "$(sqlite_tool)" in
        python3)
            out=$(python3 - "$db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("PRAGMA integrity_check").fetchone()[0])
c.close()
PY
            ) || return 1
            ;;
        sqlite3)
            out=$(sqlite3 -bail "$db" 'PRAGMA integrity_check;') || return 1
            ;;
        *) return 2 ;;
    esac
    [[ "$out" == ok ]]
}

# ---------------------------------------------------------------------------
# Upload backends. A backend is a file lib/backend-<name>.sh that defines:
#   backend_preflight               sanity-check config/tools (no network)
#   backend_check                   check the destination is reachable/writable
#   upload_backup ARCHIVE SIDECAR   copy both files off-box
#   verify_remote_backup ARCHIVE SIDECAR   prove the remote copy is intact
#   list_remote_backups PREFIX      print remote archive names, oldest first
#   download_backup NAME DESTDIR    fetch archive + sidecar into DESTDIR
#   prune_remote_backups PREFIX KEEP  delete all but the newest KEEP archives
# ---------------------------------------------------------------------------
load_backend() {
    local name="$1" lib_dir="$2" file
    [[ "$name" =~ ^[a-z0-9_-]+$ ]] || die 2 "Invalid UPLOAD_BACKEND: ${name}"
    file="${lib_dir}/backend-${name}.sh"
    [[ -f "$file" ]] || die 2 "Unknown UPLOAD_BACKEND '${name}' (no ${file})"
    # shellcheck source=/dev/null
    source "$file"
    local fn
    for fn in backend_preflight backend_check upload_backup verify_remote_backup \
              list_remote_backups download_backup prune_remote_backups; do
        declare -F "$fn" >/dev/null || die 2 "Backend '${name}' does not define ${fn}()"
    done
}

# Strict archive-name check used before any remote/local deletion.
is_backup_archive_name() {
    [[ "$1" =~ ^hermes-backup-[A-Za-z0-9._-]+-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]
}
