#!/usr/bin/env bash
# install.sh [--dry-run] - install item #3 (watchdog) for the current user.
# Run as dietpi; needs no sudo. Idempotent: every step checks first and
# prints "already done", or runs ("done"), or with --dry-run prints
# "would run" and changes nothing.
#
# Steps:
#   1 state    ~/.local/state/jafar/watchdog/ (chmod 700)
#   2 marker   ~/.local/state/jafar/last-backup -> item #1's last-success
#   3 secrets  report whether ntfy.env / healthchecks.env exist (never written here)
#   4 tools    report whether ping, curl and flock are installed
#   5 cron     the managed every-5-minutes line in the user crontab

set -Eeuo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
JAFAR_STATE="${HOME}/.local/state/jafar"
STATE_DIR="${JAFAR_STATE}/watchdog"
MARKER="${JAFAR_STATE}/last-backup"
SECRETS_DIR="${HOME}/.config/jafar"
HB_CONFIG="${HOME}/.config/hermes-backup/config"
SCHEDULE="*/5 * * * *"
TAG="# jafar-watchdog:managed"

DRY_RUN=no
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=yes ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Usage: install.sh [--dry-run]" >&2; exit 2 ;;
esac

say() { printf 'watchdog: %-8s %s\n' "$1" "$2"; }
[[ "$(id -u)" != 0 ]] || { echo "Run this as dietpi, not root." >&2; exit 2; }
command -v crontab >/dev/null 2>&1 || { echo "watchdog: crontab is not installed" >&2; exit 1; }

# 1 state ---------------------------------------------------------------------
if [[ -d "$STATE_DIR" && "$(stat -c %a -- "$STATE_DIR")" == 700 && "$(stat -c %a -- "$JAFAR_STATE")" == 700 ]]; then
    say state "already done (${STATE_DIR})"
elif [[ "$DRY_RUN" == yes ]]; then
    say state "would run: mkdir ${STATE_DIR} (chmod 700)"
else
    mkdir -p -- "$STATE_DIR"
    chmod 700 -- "$JAFAR_STATE" "$STATE_DIR"
    say state "done (${STATE_DIR})"
fi

# 2 marker --------------------------------------------------------------------
# Item #1 writes <STATE_DIR>/last-success after every verified backup; its
# STATE_DIR can be changed in its config. Link the spec's path to it so
# watchdog.sh reads one fixed place and item #1 stays untouched.
hb_state="${HOME}/.local/state/hermes-backup"
if [[ -r "$HB_CONFIG" ]]; then
    # shellcheck disable=SC2016  # expanded by the inner bash, on purpose
    v=$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${STATE_DIR:-}"' _ "$HB_CONFIG" 2>/dev/null || true)
    [[ -z "$v" ]] || hb_state="$v"
fi
target="${hb_state}/last-success"
if [[ -L "$MARKER" && "$(readlink -- "$MARKER")" == "$target" ]]; then
    say marker "already done (${MARKER} -> ${target})"
elif [[ -e "$MARKER" || -L "$MARKER" ]]; then
    say marker "already done (${MARKER} exists and is left as it is; not a link to ${target})"
elif [[ "$DRY_RUN" == yes ]]; then
    say marker "would run: ln -s ${target} ${MARKER}"
else
    mkdir -p -- "$JAFAR_STATE"; chmod 700 -- "$JAFAR_STATE"
    ln -s -- "$target" "$MARKER"
    say marker "done (${MARKER} -> ${target})"
fi

# 3 secrets (report only: they hold credentials and are created by hand) ------
for f in ntfy.env healthchecks.env; do
    p="${SECRETS_DIR}/${f}"
    if [[ ! -f "$p" ]]; then
        say secrets "NOTE: ${p} is missing; create it (watchdog/README.md, Setup)"
    elif [[ "$(stat -c %a -- "$p")" != 600 ]]; then
        say secrets "NOTE: ${p} should be chmod 600; run: chmod 600 ${p}"
    else
        say secrets "already done (${p} present, 600)"
    fi
done

# 4 tools (report only) ---------------------------------------------------------
for t in ping curl flock; do
    if command -v "$t" >/dev/null 2>&1; then
        say tools "already done (${t} present)"
    elif [[ "$t" == ping ]]; then
        say tools "NOTE: ping is missing; the network check falls back to a TCP connect. To install: sudo apt-get install -y iputils-ping"
    else
        say tools "NOTE: ${t} is missing; to install: sudo apt-get install -y ${t/flock/util-linux}"
    fi
done

# 5 cron ----------------------------------------------------------------------------
# cron treats % specially and does no quoting: refuse paths that would need it.
for p in "${SCRIPT_DIR}/watchdog.sh" "$STATE_DIR"; do
    [[ "$p" =~ ^[A-Za-z0-9._/+-]+$ ]] || { echo "watchdog: path not safe for a crontab line: ${p}" >&2; exit 2; }
done
want="${SCHEDULE} ${SCRIPT_DIR}/watchdog.sh >>${STATE_DIR}/cron.log 2>&1 ${TAG}"
current=$(crontab -l 2>/dev/null || true)
have=$(printf '%s\n' "$current" | grep -F -- "$TAG" || true)
if [[ "$have" == "$want" ]]; then
    say cron "already done (${SCHEDULE})"
elif [[ "$DRY_RUN" == yes ]]; then
    say cron "would run: add the watchdog line to your crontab (${SCHEDULE})"
else
    mkdir -p -- "$STATE_DIR"
    if [[ -n "$current" ]]; then
        printf '%s\n' "$current" >"${STATE_DIR}/crontab.before-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    kept=$(printf '%s\n' "$current" | grep -vF -- "$TAG" || true)
    { [[ -z "$kept" ]] || printf '%s\n' "$kept"; printf '%s\n' "$want"; } | crontab -
    say cron "done (${SCHEDULE})"
fi

if [[ "$DRY_RUN" == yes ]]; then
    echo "watchdog: dry run, nothing was changed"
else
    echo "watchdog: install complete. Verify with: bash ${SCRIPT_DIR}/test.sh"
fi
