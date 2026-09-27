#!/usr/bin/env bash
# watchdog.sh - item #3: check Jafar from outside Hermes and alert by ntfy.
# Runs as dietpi from the user crontab every 5 minutes; needs no sudo.
#
#   watchdog.sh            one run: check, restart a stopped gateway once,
#                          alert on state changes, ping healthchecks, log
#   watchdog.sh --check    only evaluate and print every check; no restart,
#                          no alert, no heartbeat, no state or log change
#
# Checks (limits in thresholds.conf next to this script):
#   network  ping -c1 PING_HOST fails = OFFLINE
#   gateway  systemctl --user is-active hermes-gateway; if not: restart once,
#            wait, recheck -> RESTARTED or DOWN
#   disk     / use > DISK_WARN_PCT = WARN, > DISK_CRIT_PCT = CRIT
#   memory   MemAvailable < MEM_WARN_MB = WARN
#   temp     hottest thermal zone > TEMP_WARN_C = WARN (SKIP if none)
#   backup   ~/.local/state/jafar/last-backup older than
#            BACKUP_MAX_AGE_HOURS = WARN
#
# Alerts go to ntfy (~/.config/jafar/ntfy.env) only when a check changes
# state (OK->BAD, BAD->OK, WARN->CRIT...), titled "Jafar: <check> <STATE>".
# While OFFLINE nothing is sent and the other checks' states are not
# advanced, so every change is delivered on the first run back online. A
# failed send is retried the same way on the next run. healthchecks
# (~/.config/jafar/healthchecks.env, HC_URL) is pinged on every online run:
# if this script, cron or the machine dies, healthchecks raises the alarm.
#
# State: ~/.local/state/jafar/watchdog/<check>.state; one line per run in
# history.log there (kept HISTORY_DAYS days).
#
# Exit codes: 0 run completed (whatever the checks found); 2 usage error,
# run as root, or a bad thresholds.conf.

set -Euo pipefail   # no -e: one failing probe must not stop the other checks
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Paths. The WD_* overrides exist for the sandbox tests only.
CONF="${WD_CONF:-${SCRIPT_DIR}/thresholds.conf}"
STATE_DIR="${WD_STATE_DIR:-${HOME}/.local/state/jafar/watchdog}"
SECRETS_DIR="${WD_SECRETS_DIR:-${HOME}/.config/jafar}"
NTFY_ENV="${SECRETS_DIR}/ntfy.env"
HC_ENV="${SECRETS_DIR}/healthchecks.env"
# The spec's marker. install.sh links it to item #1's real marker; the
# fallback covers a server where that link is missing.
BACKUP_MARKER="${WD_BACKUP_MARKER:-${HOME}/.local/state/jafar/last-backup}"
BACKUP_MARKER_FALLBACK="${WD_BACKUP_MARKER_FALLBACK:-${HOME}/.local/state/hermes-backup/last-success}"
MEMINFO="${WD_MEMINFO:-/proc/meminfo}"
THERMAL_DIR="${WD_THERMAL_DIR:-/sys/class/thermal}"
HISTORY="${STATE_DIR}/history.log"
CRON_LOG="${STATE_DIR}/cron.log"
GATEWAY=hermes-gateway
CHECKS=(network gateway disk memory temp backup)

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=run
case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Usage: watchdog.sh [--check]" >&2; exit 2 ;;
esac
[[ "$(id -u)" != 0 ]] || { echo "watchdog: run as dietpi, not root (it checks dietpi's user services)" >&2; exit 2; }

# cron gives neither variable; systemctl --user needs both to reach the user
# bus. Linger keeps the bus at this fixed path (same fix as bootstrap.sh).
MY_UID="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${MY_UID}}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# --- thresholds.conf --------------------------------------------------------------
DISK_WARN_PCT=85 DISK_CRIT_PCT=95 MEM_WARN_MB=1536 TEMP_WARN_C=85
BACKUP_MAX_AGE_HOURS=26 GATEWAY_RESTART_WAIT_SECONDS=30 PING_HOST=1.1.1.1 HISTORY_DAYS=7

load_conf() {
    local line key val n=0
    [[ -r "$CONF" ]] || { echo "watchdog: cannot read ${CONF}" >&2; exit 2; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^([A-Z_]+)=([^[:space:]]+)$ ]]; then
            echo "watchdog: ${CONF}:${n}: not KEY=VALUE: ${line}" >&2; exit 2
        fi
        key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        case "$key" in
            DISK_WARN_PCT|DISK_CRIT_PCT|MEM_WARN_MB|TEMP_WARN_C|BACKUP_MAX_AGE_HOURS|GATEWAY_RESTART_WAIT_SECONDS|HISTORY_DAYS)
                [[ "$val" =~ ^[0-9]{1,6}$ ]] || { echo "watchdog: ${CONF}:${n}: ${key} must be a whole number" >&2; exit 2; }
                printf -v "$key" '%d' "$((10#$val))" ;;
            PING_HOST)
                [[ "$val" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "watchdog: ${CONF}:${n}: PING_HOST is not a host name or address" >&2; exit 2; }
                PING_HOST="$val" ;;
            *) echo "watchdog: ${CONF}:${n}: unknown key ${key} (ignored)" >&2 ;;
        esac
    done <"$CONF"
    (( DISK_WARN_PCT < DISK_CRIT_PCT )) || { echo "watchdog: DISK_WARN_PCT must be below DISK_CRIT_PCT" >&2; exit 2; }
}
load_conf

# Read one KEY=value from an env file without executing it. Accepts an
# optional "export " and surrounding quotes. Prints nothing if absent.
env_get() {
    local file="$1" key="$2" line val="" found=no
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#export }"
        [[ "$line" == "${key}="* ]] || continue
        val="${line#"${key}"=}" found=yes
    done <"$file"
    [[ "$found" == yes ]] || return 0
    if [[ ${#val} -ge 2 && ( ( "$val" == \"*\" ) || ( "$val" == \'*\' ) ) ]]; then
        val="${val:1:${#val}-2}"
    fi
    printf '%s' "$val"
}

# --- checks ------------------------------------------------------------------------
# Each check sets NEW[check] (state), INFO[check] (alert text) and
# SHORT[check] (value for history.log).
declare -A NEW INFO SHORT PREV

check_network() {
    local ok=no
    if command -v ping >/dev/null 2>&1; then
        ping -c1 -W 5 "$PING_HOST" >/dev/null 2>&1 && ok=yes
    else
        # No ping installed: fall back to a TCP connect to the same host.
        # shellcheck disable=SC2016  # $1 is expanded by the inner bash
        timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$PING_HOST" >/dev/null 2>&1 && ok=yes
    fi
    if [[ "$ok" == yes ]]; then
        NEW[network]=OK INFO[network]="${PING_HOST} answers" SHORT[network]=OK
    else
        NEW[network]=OFFLINE INFO[network]="no reply from ${PING_HOST}" SHORT[network]=OFFLINE
    fi
}

gateway_active() { systemctl --user is-active --quiet "$GATEWAY" >/dev/null 2>&1; }
check_gateway() {
    if gateway_active; then
        NEW[gateway]=OK INFO[gateway]="${GATEWAY} is active" SHORT[gateway]=OK
        return
    fi
    if [[ "$MODE" == check ]]; then
        NEW[gateway]=DOWN INFO[gateway]="${GATEWAY} is not active (not restarted: --check)" SHORT[gateway]=DOWN
        return
    fi
    systemctl --user restart "$GATEWAY" >/dev/null 2>&1
    sleep "$GATEWAY_RESTART_WAIT_SECONDS"
    if gateway_active; then
        NEW[gateway]=RESTARTED SHORT[gateway]=RESTARTED
        INFO[gateway]="${GATEWAY} was not active; restarted it and it is active again"
    else
        NEW[gateway]=DOWN SHORT[gateway]=DOWN
        INFO[gateway]="${GATEWAY} is not active and a restart did not bring it back. Check: systemctl --user status ${GATEWAY}"
    fi
}

check_disk() {
    local pct
    pct=$(df -P / 2>/dev/null | awk 'NR == 2 { sub(/%$/, "", $5); print $5 }')
    if [[ ! "$pct" =~ ^[0-9]+$ ]]; then
        NEW[disk]=SKIP INFO[disk]="could not read disk usage of /" SHORT[disk]=SKIP
    elif (( pct > DISK_CRIT_PCT )); then
        NEW[disk]=CRIT INFO[disk]="/ is ${pct}% full (CRIT above ${DISK_CRIT_PCT}%)" SHORT[disk]="CRIT:${pct}%"
    elif (( pct > DISK_WARN_PCT )); then
        NEW[disk]=WARN INFO[disk]="/ is ${pct}% full (WARN above ${DISK_WARN_PCT}%)" SHORT[disk]="WARN:${pct}%"
    else
        NEW[disk]=OK INFO[disk]="/ is ${pct}% full" SHORT[disk]="OK:${pct}%"
    fi
}

check_memory() {
    local mb
    mb=$(awk '$1 == "MemAvailable:" { print int($2 / 1024) }' "$MEMINFO" 2>/dev/null)
    if [[ ! "$mb" =~ ^[0-9]+$ ]]; then
        NEW[memory]=SKIP INFO[memory]="no MemAvailable in ${MEMINFO}" SHORT[memory]=SKIP
    elif (( mb < MEM_WARN_MB )); then
        NEW[memory]=WARN INFO[memory]="${mb} MiB available (WARN below ${MEM_WARN_MB} MiB)" SHORT[memory]="WARN:${mb}MB"
    else
        NEW[memory]=OK INFO[memory]="${mb} MiB available" SHORT[memory]="OK:${mb}MB"
    fi
}

check_temp() {
    local f v max=""
    for f in "$THERMAL_DIR"/thermal_zone*/temp; do
        [[ -r "$f" ]] || continue
        v=$(cat -- "$f" 2>/dev/null) || continue
        v="${v//[[:space:]]/}"
        [[ "$v" =~ ^-?[0-9]+$ ]] || continue
        if [[ -z "$max" ]] || (( v > max )); then max="$v"; fi
    done
    if [[ -z "$max" ]]; then
        NEW[temp]=SKIP INFO[temp]="no readable thermal zone" SHORT[temp]=SKIP
        return
    fi
    local c=$(( max / 1000 ))
    if (( max > TEMP_WARN_C * 1000 )); then
        NEW[temp]=WARN INFO[temp]="hottest zone is ${c} C (WARN above ${TEMP_WARN_C} C)" SHORT[temp]="WARN:${c}C"
    else
        NEW[temp]=OK INFO[temp]="hottest zone is ${c} C" SHORT[temp]="OK:${c}C"
    fi
}

check_backup() {
    local m="" mtime now age h
    if [[ -e "$BACKUP_MARKER" ]]; then m="$BACKUP_MARKER"
    elif [[ -e "$BACKUP_MARKER_FALLBACK" ]]; then m="$BACKUP_MARKER_FALLBACK"
    fi
    if [[ -z "$m" ]]; then
        NEW[backup]=WARN SHORT[backup]="WARN:none"
        INFO[backup]="no backup marker (${BACKUP_MARKER}); no successful backup recorded"
        return
    fi
    mtime=$(stat -L -c %Y -- "$m" 2>/dev/null) || mtime=0
    now=$(date +%s)
    age=$(( now - mtime )); (( age < 0 )) && age=0
    h=$(( age / 3600 ))
    if (( age > BACKUP_MAX_AGE_HOURS * 3600 )); then
        NEW[backup]=WARN SHORT[backup]="WARN:${h}h"
        INFO[backup]="last successful backup is ${h} h old (WARN above ${BACKUP_MAX_AGE_HOURS} h)"
    else
        NEW[backup]=OK INFO[backup]="last successful backup is ${h} h old" SHORT[backup]="OK:${h}h"
    fi
}

# Same order as CHECKS: network first, it decides whether alerts can go out.
run_checks() { check_network; check_gateway; check_disk; check_memory; check_temp; check_backup; }

# --- --check mode ---------------------------------------------------------------
if [[ "$MODE" == check ]]; then
    run_checks
    for c in "${CHECKS[@]}"; do printf '%-8s %-9s %s\n' "$c" "${NEW[$c]}" "${INFO[$c]}"; done
    exit 0
fi

# --- a real run -------------------------------------------------------------------
if ! mkdir -p -- "$STATE_DIR" || ! chmod 700 -- "$STATE_DIR"; then
    echo "watchdog: cannot create ${STATE_DIR}" >&2; exit 1
fi
# Never two runs at once (a run can take GATEWAY_RESTART_WAIT_SECONDS).
if command -v flock >/dev/null 2>&1; then
    exec 9>"${STATE_DIR}/.lock"
    flock -n 9 || exit 0
fi

state_file() { printf '%s/%s.state' "$STATE_DIR" "$1"; }
read_state() { local f s=""; f=$(state_file "$1"); [[ -f "$f" ]] && read -r s _ <"$f"; printf '%s' "${s:-OK}"; }
write_state() { printf '%s %s\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$(state_file "$1")"; }
state_since() { local f _s t=""; f=$(state_file "$1"); [[ -f "$f" ]] && read -r _s t <"$f"; printf '%s' "$t"; }

NTFY_URL=$(env_get "$NTFY_ENV" NTFY_URL)
topic=$(env_get "$NTFY_ENV" NTFY_TOPIC)
if [[ -z "$NTFY_URL" && -n "$topic" ]]; then   # NTFY_SERVER + NTFY_TOPIC form
    server=$(env_get "$NTFY_ENV" NTFY_SERVER)
    server="${server:-https://ntfy.sh}"
    NTFY_URL="${server%/}/${topic}"
fi
NTFY_TOKEN=$(env_get "$NTFY_ENV" NTFY_TOKEN)
HC_URL=$(env_get "$HC_ENV" HC_URL)

# send_ntfy <title> <priority> <tags> <body>. The token goes to curl on stdin
# (--config -), never on the command line where ps would show it.
send_ntfy() {
    [[ -n "$NTFY_URL" ]] || return 1
    local auth=""
    [[ -z "$NTFY_TOKEN" ]] || auth="header = \"Authorization: Bearer ${NTFY_TOKEN}\""
    printf '%s\n' "$auth" | curl -fsS -m 15 -o /dev/null --config - \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" --data-binary "$4" "$NTFY_URL"
}

priority_of() {
    case "$1" in
        CRIT|DOWN) echo "high" ;;
        OK) echo "low" ;;
        *) echo "default" ;;
    esac
}
tags_of() {
    case "$1" in
        CRIT|DOWN) echo "rotating_light" ;;
        OK) echo "white_check_mark" ;;
        *) echo "warning" ;;
    esac
}

run_checks
for c in "${CHECKS[@]}"; do PREV[$c]=$(read_state "$c"); done
ONLINE=yes; [[ "${NEW[network]}" == OK ]] || ONLINE=no

SENT=0 PENDING=0
# alert <check> <title state> <body> <state to store once delivered>
alert() {
    local c="$1" st="$2" body="$3" store="$4"
    if [[ "$ONLINE" == yes ]] && send_ntfy "Jafar: ${c} ${st}" "$(priority_of "$st")" "$(tags_of "$st")" "$body" 2>>"$CRON_LOG"; then
        write_state "$c" "$store"; SENT=$((SENT + 1))
    else
        PENDING=$((PENDING + 1))
        # A restart that could not be reported is remembered, so the
        # "RESTARTED" notice still goes out on a later run.
        [[ "$st" != RESTARTED ]] || write_state "$c" RESTARTED
    fi
}

for c in "${CHECKS[@]}"; do
    new="${NEW[$c]}" prev="${PREV[$c]}"
    case "$c:$new" in
        *:SKIP) continue ;;                 # no data this run: keep the old state
        network:OFFLINE)
            [[ "$prev" == OFFLINE ]] || write_state network OFFLINE
            continue ;;                     # cannot be sent; healthchecks covers it
        network:OK)
            if [[ "$prev" == OFFLINE ]]; then
                since=$(state_since network)
                alert network OK "back online; offline since ${since:-unknown} (no alerts could be sent meanwhile)" OK
            fi
            continue ;;
        gateway:RESTARTED)
            alert gateway RESTARTED "${INFO[gateway]}" OK; continue ;;
        gateway:OK)
            if [[ "$prev" == RESTARTED ]]; then
                alert gateway RESTARTED "${GATEWAY} was restarted by the watchdog in an earlier run and is active" OK
                continue
            fi ;;
    esac
    [[ "$new" == "$prev" ]] && continue
    alert "$c" "$new" "${INFO[$c]} (was ${prev})" "$new"
done

# Heartbeat: every run that is online.
if [[ "$ONLINE" != yes ]]; then hc=skipped
elif [[ -z "$HC_URL" ]]; then hc="unset"
elif curl -fsS -m 10 -o /dev/null "$HC_URL" 2>>"$CRON_LOG"; then hc=ok
else hc=fail
fi

# history.log: one line per run; drop lines older than HISTORY_DAYS.
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
line="$now_iso"
for c in "${CHECKS[@]}"; do line+=" ${c}=${SHORT[$c]}"; done
line+=" hc=${hc} alerts=${SENT}"
(( PENDING == 0 )) || line+=" pending=${PENDING}"
[[ -n "$NTFY_URL" ]] || line+=" ntfy=unset"
printf '%s\n' "$line" >>"$HISTORY"

cutoff=$(date -u -d "${HISTORY_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$cutoff" ]] && head -n1 -- "$HISTORY" | awk -v c="$cutoff" '{ exit !($1 < c) }'; then
    awk -v c="$cutoff" '$1 >= c' "$HISTORY" >"${HISTORY}.tmp" && mv -f -- "${HISTORY}.tmp" "$HISTORY"
fi
# cron.log only collects error output; keep it small.
if [[ -f "$CRON_LOG" ]] && (( $(stat -c %s -- "$CRON_LOG" 2>/dev/null || echo 0) > 102400 )); then
    tail -n 200 -- "$CRON_LOG" >"${CRON_LOG}.tmp" && mv -f -- "${CRON_LOG}.tmp" "$CRON_LOG"
fi
exit 0
