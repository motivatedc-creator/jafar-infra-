#!/usr/bin/env bash
# uninstall.sh [--dry-run] - remove item #1's scheduled job. Run as dietpi.
#
# Removes only the managed line from the user crontab. It never deletes
# backups, the config, logs or anything in ~/.hermes; their locations are
# printed so the operator can decide about them.

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TAG="# hermes-backup:managed"

DRY_RUN=no
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=yes ;;
    *) echo "Usage: uninstall.sh [--dry-run]" >&2; exit 2 ;;
esac
[[ "$(id -u)" != 0 ]] || { echo "Run this as dietpi, not root." >&2; exit 2; }

if ! crontab -l 2>/dev/null | grep -qF -- "$TAG"; then
    echo "backup: cron    already done (no managed backup line)"
elif [[ "$DRY_RUN" == yes ]]; then
    echo "backup: cron    would run: install-cron.sh --remove"
else
    "${SCRIPT_DIR}/install-cron.sh" --remove >/dev/null
    echo "backup: cron    done (managed backup line removed)"
fi

cat <<EOF
backup: kept    ~/.config/hermes-backup/config, ~/hermes-backups/,
                ~/.local/state/hermes-backup/ and every off-box archive.
                Nothing else was changed.
EOF
