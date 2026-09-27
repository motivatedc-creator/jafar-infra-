#!/usr/bin/env bash
# uninstall.sh [--dry-run] - remove item #3's scheduled job. Run as dietpi.
#
# Removes the managed line from the user crontab and the last-backup link
# that install.sh made. It never deletes ~/.config/jafar/*.env or the
# watchdog's state and history; their locations are printed so the operator
# can decide about them. Healthchecks will alert once the pings stop: pause
# the check there first if the removal is intended.

set -Eeuo pipefail
umask 077
export LC_ALL=C

JAFAR_STATE="${HOME}/.local/state/jafar"
MARKER="${JAFAR_STATE}/last-backup"
TAG="# jafar-watchdog:managed"

DRY_RUN=no
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=yes ;;
    *) echo "Usage: uninstall.sh [--dry-run]" >&2; exit 2 ;;
esac
[[ "$(id -u)" != 0 ]] || { echo "Run this as dietpi, not root." >&2; exit 2; }

current=$(crontab -l 2>/dev/null || true)
if ! printf '%s\n' "$current" | grep -qF -- "$TAG"; then
    echo "watchdog: cron     already done (no managed watchdog line)"
elif [[ "$DRY_RUN" == yes ]]; then
    echo "watchdog: cron     would run: remove the managed watchdog line from your crontab"
else
    mkdir -p -- "${JAFAR_STATE}/watchdog"
    printf '%s\n' "$current" >"${JAFAR_STATE}/watchdog/crontab.before-$(date -u +%Y%m%dT%H%M%SZ)"
    kept=$(printf '%s\n' "$current" | grep -vF -- "$TAG" || true)
    if [[ -n "$kept" ]]; then printf '%s\n' "$kept" | crontab -; else crontab -r 2>/dev/null || true; fi
    echo "watchdog: cron     done (managed watchdog line removed)"
fi

# Only a link pointing at item #1's marker is ours; a real file is left alone.
if [[ -L "$MARKER" && "$(readlink -- "$MARKER")" == */last-success ]]; then
    if [[ "$DRY_RUN" == yes ]]; then
        echo "watchdog: marker   would run: rm ${MARKER} (a link; the backup marker itself stays)"
    else
        rm -f -- "$MARKER"
        echo "watchdog: marker   done (${MARKER} link removed)"
    fi
else
    echo "watchdog: marker   already done (no last-backup link of ours)"
fi

cat <<EOF
watchdog: kept     ~/.config/jafar/ntfy.env, ~/.config/jafar/healthchecks.env
                   and ~/.local/state/jafar/watchdog/ (states, history.log).
                   Nothing else was changed.
EOF
