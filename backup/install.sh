#!/usr/bin/env bash
# install.sh [--dry-run] - install item #1 (backup + restore) for the current
# user. Run as dietpi; needs no sudo. Idempotent: every step checks first and
# prints "already done", or runs ("done"), or with --dry-run prints
# "would run" and changes nothing.
#
# Steps:
#   1 config  ~/.config/hermes-backup/config from config.example (chmod 600)
#   2 rclone  report whether rclone and its config exist (never changed here)
#   3 cron    the managed nightly line in the user crontab (03:30, server clock)

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_DIR="${HOME}/.config/hermes-backup"
CONFIG="${CONFIG_DIR}/config"
SCHEDULE="${HB_CRON_SCHEDULE:-30 3 * * *}"
TAG="# hermes-backup:managed"

DRY_RUN=no
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=yes ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: install.sh [--dry-run]" >&2; exit 2 ;;
esac

say() { printf 'backup: %-7s %s\n' "$1" "$2"; }
[[ "$(id -u)" != 0 ]] || { echo "Run this as dietpi, not root." >&2; exit 2; }

# 1 config -------------------------------------------------------------------
if [[ -f "$CONFIG" ]]; then
    say config "already done (${CONFIG})"
elif [[ "$DRY_RUN" == yes ]]; then
    say config "would run: copy config.example to ${CONFIG} (chmod 600)"
else
    mkdir -p -- "$CONFIG_DIR"
    chmod 700 -- "$CONFIG_DIR"
    install -m 600 -- "${SCRIPT_DIR}/config.example" "$CONFIG"
    say config "done (${CONFIG})"
fi

# 2 rclone (report only: remotes hold credentials and are created by hand) ---
rclone_conf="${HOME}/.config/rclone/rclone.conf"
if ! command -v rclone >/dev/null 2>&1; then
    say rclone "NOTE: rclone is not installed; backups cannot upload until it is (backup/README.md section 4.2)"
elif [[ ! -f "$rclone_conf" ]]; then
    say rclone "NOTE: ${rclone_conf} is missing; create the remotes first (backup/README.md section 4.3)"
else
    say rclone "already done (${rclone_conf} present)"
fi

# 3 cron -----------------------------------------------------------------------
# Without a user config, install-cron.sh falls back to the same STATE_DIR that
# config.example sets, so the printed line is the one step 1 would lead to.
want=$("${SCRIPT_DIR}/install-cron.sh" --schedule "$SCHEDULE" --print 2>/dev/null) \
    || { echo "backup: could not compute the cron line" >&2; exit 1; }
have=$(crontab -l 2>/dev/null | grep -F -- "$TAG" || true)
if [[ "$have" == "$want" ]]; then
    say cron "already done (${SCHEDULE})"
elif [[ "$DRY_RUN" == yes ]]; then
    say cron "would run: install-cron.sh --schedule \"${SCHEDULE}\""
else
    "${SCRIPT_DIR}/install-cron.sh" --schedule "$SCHEDULE" >/dev/null
    say cron "done (${SCHEDULE})"
fi

if [[ "$DRY_RUN" == yes ]]; then
    echo "backup: dry run, nothing was changed"
else
    echo "backup: install complete. Verify with: bash ${SCRIPT_DIR}/test.sh"
fi
