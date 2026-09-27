#!/usr/bin/env bash
# hermes-restore.sh - the Jafar Build Plan's restore interface:
#
#   hermes-restore.sh <archive|latest> [--target DIR] [--force] [--dry-run] [--inspect]
#                     [--download-dir DIR]
#
#   latest     newest archive on the off-box remote (downloaded first)
#   --target   Hermes home to restore into (default: ~/.hermes)
#   --force    replace existing items without asking. Items being replaced
#              are MOVED to <target>.pre-restore-<timestamp>/, never deleted.
#              Only the items stored in the archive are touched, so .env and
#              login files already in the target stay where they are.
#   --dry-run  validate the archive and print what would change; change nothing
#   --inspect  validate the archive and list its contents; change nothing
#   --download-dir DIR  where "latest" is downloaded (default ~/hermes-restore-downloads)
#
# When the target is the live ~/.hermes and --force is given, a running
# hermes-gateway user service is stopped before the restore and started
# again afterwards (also if the restore fails).
#
# All validation and file handling is done by restore-hermes.sh. If no
# ~/.config/hermes-backup/config exists yet (fresh machine), the repo's
# config.example is used, which holds the server's settings (no secrets).
#
# Exit codes: those of restore-hermes.sh (0 ok, 1 error, 2 usage/config,
# 5 validation failed, 6 aborted / confirmation missing).

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GATEWAY_UNIT=hermes-gateway
# See the matching comment in bootstrap/bootstrap.sh: systemctl --user needs
# these set explicitly, since not every shell that runs this script got them
# from a login session (e.g. cron, or being called from another script).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

SOURCE="" TARGET="" FORCE=no MODE=restore DL_DIR=""
while (( $# )); do
    case "$1" in
        --target) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; TARGET="$2"; shift 2 ;;
        --force) FORCE=yes; shift ;;
        --download-dir) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; DL_DIR="$2"; shift 2 ;;
        --dry-run) MODE=dry-run; shift ;;
        --inspect) MODE=inspect; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) [[ -z "$SOURCE" ]] || { echo "Only one archive may be given" >&2; exit 2; }
           SOURCE="$1"; shift ;;
    esac
done
[[ -n "$SOURCE" ]] || { usage >&2; exit 2; }
TARGET="${TARGET:-${HOME}/.hermes}"

if [[ -z "${HERMES_BACKUP_CONFIG:-}" && ! -e "${HOME}/.config/hermes-backup/config" ]]; then
    export HERMES_BACKUP_CONFIG="${SCRIPT_DIR}/config.example"
    echo "No ~/.config/hermes-backup/config yet; using the repo defaults (${HERMES_BACKUP_CONFIG})." >&2
fi

args=()
case "$MODE" in
    dry-run) args+=(--dry-run) ;;
    inspect) args+=(--inspect) ;;
esac
args+=(--target "$TARGET")
[[ "$FORCE" == yes ]] && args+=(--yes)
[[ -n "$DL_DIR" ]] && args+=(--download-dir "$DL_DIR")
if [[ "$SOURCE" == latest ]]; then
    args+=(--fetch latest)
else
    args+=(-- "$SOURCE")
fi

# Is the target the live Hermes home? (Only then is the gateway touched.)
canon() { if [[ -d "$1" ]]; then (cd -- "$1" && pwd -P); else printf '%s' "${1%/}"; fi; }
live=no
if [[ "$(canon "$TARGET")" == "$(canon "${HOME}/.hermes")" ]]; then
    live=yes
fi

stopped_gateway=no
# shellcheck disable=SC2329  # invoked by the EXIT trap
restart_gateway() {
    if [[ "$stopped_gateway" == yes ]]; then
        echo "Starting ${GATEWAY_UNIT} again" >&2
        systemctl --user start "$GATEWAY_UNIT" || echo "WARNING: could not start ${GATEWAY_UNIT}; run: systemctl --user start ${GATEWAY_UNIT}" >&2
    fi
}
trap restart_gateway EXIT

if [[ "$live" == yes && "$FORCE" == yes && "$MODE" == restore ]] \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user is-active --quiet "$GATEWAY_UNIT" 2>/dev/null; then
    echo "Stopping ${GATEWAY_UNIT} for the restore" >&2
    systemctl --user stop "$GATEWAY_UNIT"
    stopped_gateway=yes
fi

rc=0
"${SCRIPT_DIR}/restore-hermes.sh" "${args[@]}" || rc=$?
exit "$rc"
