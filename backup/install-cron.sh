#!/usr/bin/env bash
# install-cron.sh - install/remove the nightly hermes backup in the invoking
# user's crontab (run it as dietpi, not root). Idempotent: the managed line is
# tagged and replaced on re-install; other crontab lines are left untouched,
# and the previous crontab is saved before every change.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAG="# hermes-backup:managed"
SCHEDULE="30 3 * * *"
ACTION=install
CONFIG_ARG=""

usage() {
    cat <<'EOF'
Usage: install-cron.sh [--schedule "M H DOM MON DOW"] [--config FILE] [--print | --remove]

  (default)    install or update the nightly job (default schedule 03:30 daily,
               server clock, which is UTC on Jafar's server)
  --print      only print the crontab line that would be installed
  --remove     remove the managed line from your crontab
EOF
}

while (( $# )); do
    case "$1" in
        --schedule) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SCHEDULE="$2"; shift 2 ;;
        --config) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CONFIG_ARG="$2"; shift 2 ;;
        --print) ACTION=print; shift ;;
        --remove) ACTION=remove; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

HB_LOG_STDERR=yes
[[ "$(id -u)" != 0 ]] || die 2 "Run this as the Hermes user (dietpi), not root: the job must run as that user"
require_cmd crontab

[[ "$SCHEDULE" =~ ^[0-9*/,-]+( [0-9*/,A-Za-z-]+){4}$ ]] || die 2 "Schedule must be 5 cron fields, got '${SCHEDULE}'"

load_config "$CONFIG_ARG"
hb_set_defaults

# cron treats % specially and does no quoting-aware parsing of our paths:
# refuse anything that would need escaping instead of trying to escape it.
check_cron_safe() { [[ "$1" =~ ^[A-Za-z0-9._/+-]+$ ]] || die 2 "Path not safe for a crontab line: $1"; }
check_cron_safe "${SCRIPT_DIR}/backup-hermes.sh"
check_cron_safe "${STATE_DIR}"

cmd="nice -n 10 ${SCRIPT_DIR}/backup-hermes.sh"
if [[ -n "$CONFIG_ARG" ]]; then
    cfg="$(cd -- "$(dirname -- "$CONFIG_ARG")" && pwd -P)/$(basename -- "$CONFIG_ARG")"
    check_cron_safe "$cfg"
    cmd+=" --config ${cfg}"
fi
LINE="${SCHEDULE} ${cmd} >>${STATE_DIR}/logs/cron.log 2>&1 ${TAG}"

if [[ "$ACTION" == print ]]; then
    printf '%s\n' "$LINE"
    exit 0
fi

current=$(crontab -l 2>/dev/null || true)
ensure_private_dir "$STATE_DIR"
ensure_private_dir "${STATE_DIR}/logs"
if [[ -n "$current" ]]; then
    saved="${STATE_DIR}/crontab.before-$(date -u +%Y%m%dT%H%M%SZ)"
    printf '%s\n' "$current" >"$saved"
    echo "Saved current crontab to ${saved}"
fi
kept=$(printf '%s\n' "$current" | grep -vF -- "$TAG" || true)

if [[ "$ACTION" == remove ]]; then
    if [[ "$kept" == "$current" ]]; then
        echo "No managed hermes-backup line found; crontab unchanged."
        exit 0
    fi
    if [[ -z "${kept//[$'\n']/}" ]]; then
        crontab -r
    else
        printf '%s\n' "$kept" | crontab -
    fi
    echo "Removed the hermes-backup cron job."
    exit 0
fi

if [[ -z "${HB_CONFIG_FILE:-}" ]]; then
    echo "WARNING: no config file found. Create ~/.config/hermes-backup/config first (see config.example)." >&2
fi
{ [[ -n "${kept//[$'\n']/}" ]] && printf '%s\n' "$kept"; printf '%s\n' "$LINE"; } | crontab -
crontab -l | grep -qF -- "$LINE" || die 1 "Crontab update could not be verified"
echo "Installed cron job for $(id -un):"
echo "  ${LINE}"
echo "Test it now with: ${SCRIPT_DIR}/backup-hermes.sh${CONFIG_ARG:+ --config ${CONFIG_ARG}}"
