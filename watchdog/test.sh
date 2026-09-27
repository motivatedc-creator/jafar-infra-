#!/usr/bin/env bash
# test.sh - verify item #3 on the real server. Run as dietpi. Prints
# PASS/FAIL per check and exits non-zero if any check fails.
#
#   bash watchdog/test.sh             live check: installed state, every
#                                     watchdog check (watchdog.sh --check:
#                                     no restart, no state change), one
#                                     healthchecks ping and ONE ntfy test
#                                     notification ("Jafar: watchdog TEST")
#   bash watchdog/test.sh --sandbox   the offline suite in tests/run-tests.sh:
#                                     stubbed commands, fake home, no network
#
# The live gateway-stop and power-cut tests are operator steps: README.md,
# "Acceptance tests".

set -Euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
    "") ;;
    --sandbox) exec bash "${SCRIPT_DIR}/tests/run-tests.sh" ;;
    *) echo "Usage: test.sh [--sandbox]" >&2; exit 2 ;;
esac

FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

STATE_DIR="${HOME}/.local/state/jafar/watchdog"
NTFY_ENV="${HOME}/.config/jafar/ntfy.env"
HC_ENV="${HOME}/.config/jafar/healthchecks.env"

# --- installed state -----------------------------------------------------------
check "cron line installed (every 5 minutes)" bash -c 'crontab -l 2>/dev/null | grep -qF "# jafar-watchdog:managed"'
check "state folder ${STATE_DIR} is chmod 700" test "$(stat -c %a "$STATE_DIR" 2>/dev/null)" = 700
check "ntfy config ${NTFY_ENV} is chmod 600" test "$(stat -c %a "$NTFY_ENV" 2>/dev/null)" = 600
check "healthchecks config ${HC_ENV} is chmod 600" test "$(stat -c %a "$HC_ENV" 2>/dev/null)" = 600
recent_run() {
    local last cutoff
    last=$(tail -n 1 "${STATE_DIR}/history.log" 2>/dev/null | awk '{print $1}')
    cutoff=$(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
    [[ -n "$last" && ! "$last" < "$cutoff" ]]
}
if recent_run; then pass "cron ran the watchdog in the last 11 minutes (history.log)"
else fail "cron ran the watchdog in the last 11 minutes (history.log; just installed? wait 5 minutes and rerun)"; fi

# --- every watchdog check, read-only ---------------------------------------------
out=$(bash "${SCRIPT_DIR}/watchdog.sh" --check 2>&1); rc=$?
if (( rc != 0 )); then
    fail "watchdog.sh --check exits 0 (got ${rc}): ${out}"
else
    while read -r name state detail; do
        [[ -n "$name" ]] || continue
        case "$state" in
            OK) pass "${name}: ${detail}" ;;
            SKIP) pass "${name}: skipped (${detail})" ;;
            *) fail "${name} is ${state}: ${detail}" ;;
        esac
    done <<<"$out"
fi

# --- the two outside services ------------------------------------------------------
# Read one KEY=value without executing the file (same rules as watchdog.sh).
env_get() {
    local line val=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line#export }"
        [[ "$line" == "$2="* ]] && val="${line#"$2"=}"
    done <"$1"
    val="${val#[\"\']}"; val="${val%[\"\']}"
    printf '%s' "$val"
}
hc=""; [[ -r "$HC_ENV" ]] && hc=$(env_get "$HC_ENV" HC_URL)
if [[ -z "$hc" ]]; then fail "HC_URL is set in ${HC_ENV}"
else check "healthchecks ping succeeds (HC_URL)" curl -fsS -m 10 -o /dev/null "$hc"; fi

url="" token=""
if [[ -r "$NTFY_ENV" ]]; then
    url=$(env_get "$NTFY_ENV" NTFY_URL)
    topic=$(env_get "$NTFY_ENV" NTFY_TOPIC)
    server=$(env_get "$NTFY_ENV" NTFY_SERVER)
    [[ -n "$url" || -z "$topic" ]] || { server="${server:-https://ntfy.sh}"; url="${server%/}/${topic}"; }
    token=$(env_get "$NTFY_ENV" NTFY_TOKEN)
fi
ntfy_test() {
    local auth=""
    [[ -z "$token" ]] || auth="header = \"Authorization: Bearer ${token}\""
    printf '%s\n' "$auth" | curl -fsS -m 15 -o /dev/null --config - \
        -H "Title: Jafar: watchdog TEST" -H "Priority: low" -H "Tags: test_tube" \
        --data-binary "watchdog/test.sh on $(hostname): if you can read this, alerts reach your phone." "$url"
}
if [[ -z "$url" ]]; then fail "NTFY_URL (or NTFY_TOPIC) is set in ${NTFY_ENV}"
else check "ntfy accepted the test notification (check your phone for \"Jafar: watchdog TEST\")" ntfy_test; fi

echo
if (( FAILS == 0 )); then echo "watchdog test: all PASS"; else echo "watchdog test: ${FAILS} FAIL"; fi
(( FAILS == 0 ))
