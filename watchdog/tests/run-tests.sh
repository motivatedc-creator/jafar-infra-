#!/usr/bin/env bash
# Offline tests for watchdog/. Safe anywhere, including the live server:
# every command the watchdog uses to touch the system or the network
# (systemctl, ping, df, curl, crontab, id) is replaced by a stub that only
# writes into a temporary sandbox, and everything runs against a fake home.
#
#   bash watchdog/tests/run-tests.sh
#   KEEP_SANDBOX=1 bash watchdog/tests/run-tests.sh

set -Euo pipefail
umask 077
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WD="$(dirname -- "$TESTS_DIR")"

SB=$(mktemp -d "${TMPDIR:-/tmp}/watchdog-test.XXXXXXXX")
cleanup() {
    if [[ "${KEEP_SANDBOX:-0}" == 1 ]]; then echo "Sandbox kept at ${SB}"
    elif [[ -d "$SB" && "$(basename -- "$SB")" == watchdog-test.* ]]; then rm -rf --one-file-system -- "$SB"; fi
}
trap cleanup EXIT

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n== %s\n' "$1"; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }

HOMEDIR="${SB}/home"
ST="${SB}/state"            # what the stubs read and record
BIN="${SB}/bin"
WSTATE="${HOMEDIR}/.local/state/jafar/watchdog"
HIST="${WSTATE}/history.log"
mkdir -p "$HOMEDIR/.config/jafar" "$ST" "$BIN" "$SB/thermal"

# --------------------------------------------------------------------------
# Stubs
# --------------------------------------------------------------------------
cat >"$BIN/id" <<'SH'
#!/bin/sh
case "$*" in
    -u) echo "${FAKE_UID:-1000}" ;;
    -un) echo dietpi ;;
    *) exec /usr/bin/id "$@" ;;
esac
SH
cat >"$BIN/systemctl" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/systemctl.log"
{ [ -n "$XDG_RUNTIME_DIR" ] && [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; } || echo "$*" >>"$FAKE_STATE/no-dbus-env.log"
case "$*" in
    "--user is-active --quiet hermes-gateway") [ -f "$FAKE_STATE/gateway.active" ] ;;
    "--user restart hermes-gateway")
        [ -f "$FAKE_STATE/gateway.restart-works" ] && : >"$FAKE_STATE/gateway.active"; exit 0 ;;
    *) echo "stub systemctl: unexpected: $*" >&2; exit 1 ;;
esac
SH
cat >"$BIN/ping" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/ping.log"
[ -f "$FAKE_STATE/online" ]
SH
cat >"$BIN/df" <<'SH'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda2 250000000 1 1 $(cat "$FAKE_STATE/disk.pct")% /"
SH
cat >"$BIN/curl" <<'SH'
#!/bin/sh
# Records the URL, the headers and whatever arrives on stdin (--config -).
url="" title="" prio="" cfg=no
echo "$*" >>"$FAKE_STATE/curl.argv"
while [ $# -gt 0 ]; do
    case "$1" in
        --config) [ "$2" = - ] && cfg=yes; shift 2 ;;
        -H) case "$2" in Title:*) title="${2#Title: }" ;; Priority:*) prio="${2#Priority: }" ;; esac; shift 2 ;;
        -o|-m|--data-binary) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[ "$cfg" = yes ] && cat >>"$FAKE_STATE/curl.stdin"
case "$url" in
    https://ntfy.example/*)
        [ -f "$FAKE_STATE/ntfy.fail" ] && exit 22
        echo "$title|$prio" >>"$FAKE_STATE/ntfy.log" ;;
    https://hc.example/*)
        echo "$url" >>"$FAKE_STATE/hc.log" ;;
    *) echo "stub curl: unexpected URL $url" >&2; exit 6 ;;
esac
SH
cat >"$BIN/crontab" <<'SH'
#!/bin/sh
case "$1" in
    -l) [ -f "$FAKE_STATE/crontab" ] || { echo "no crontab for dietpi" >&2; exit 1; }; cat "$FAKE_STATE/crontab" ;;
    -) cat >"$FAKE_STATE/crontab" ;;
    -r) rm -f "$FAKE_STATE/crontab" ;;
    *) exit 1 ;;
esac
SH
chmod 755 "$BIN"/*

# A thresholds.conf like the real one but without the 30 s wait.
sed 's/^GATEWAY_RESTART_WAIT_SECONDS=.*/GATEWAY_RESTART_WAIT_SECONDS=0/' "$WD/thresholds.conf" >"$SB/thresholds.conf"

cat >"$HOMEDIR/.config/jafar/ntfy.env" <<'EOF'
NTFY_URL=https://ntfy.example/jafar-test
NTFY_TOKEN="tk_sandbox_secret"
EOF
echo 'export HC_URL=https://hc.example/ping/abc' >"$HOMEDIR/.config/jafar/healthchecks.env"
chmod 600 "$HOMEDIR/.config/jafar/"*.env

meminfo() { printf 'MemTotal: 16000000 kB\nMemAvailable: %s kB\n' "$1" >"$SB/meminfo"; }
thermal() {  # thermal <millidegrees>...  (none = no zones)
    rm -rf "$SB/thermal"; mkdir -p "$SB/thermal"
    local i=0 t; for t; do mkdir -p "$SB/thermal/thermal_zone$i"; echo "$t" >"$SB/thermal/thermal_zone$i/temp"; i=$((i + 1)); done
}
healthy() {
    : >"$ST/gateway.active"; : >"$ST/online"; : >"$ST/gateway.restart-works"
    rm -f "$ST/ntfy.fail"
    echo 42 >"$ST/disk.pct"; meminfo 8000000; thermal 45000 51000
    mkdir -p "$HOMEDIR/.local/state/hermes-backup"
    echo "2026-09-27T03:30:00Z hermes-backup-x.tar.gz" >"$HOMEDIR/.local/state/hermes-backup/last-success"
}
reset_logs() { rm -f "$ST"/{ntfy.log,hc.log,systemctl.log,no-dbus-env.log,curl.argv,curl.stdin,ping.log}; }

wd() {  # wd [args]: run watchdog.sh; sets OUT and RC
    OUT=$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS HOME="$HOMEDIR" PATH="${BIN}:${PATH}" \
          FAKE_STATE="$ST" WD_CONF="${WD_CONF:-$SB/thresholds.conf}" WD_MEMINFO="$SB/meminfo" \
          WD_THERMAL_DIR="$SB/thermal" bash "$WD/watchdog.sh" "$@" </dev/null 2>&1); RC=$?
}
inst() { OUT=$(HOME="$HOMEDIR" PATH="${BIN}:${PATH}" FAKE_STATE="$ST" bash "$WD/$1" "${@:2}" </dev/null 2>&1); RC=$?; }
nt() { cat "$ST/ntfy.log" 2>/dev/null; }
nt_count() { local n; n=$(nt | wc -l); echo "$n"; }
hc_count() { local n=0; [[ -f "$ST/hc.log" ]] && n=$(wc -l <"$ST/hc.log"); echo "$n"; }
last_hist() { tail -n 1 "$HIST"; }

# --------------------------------------------------------------------------
section "1. All healthy: first run is silent, heartbeat sent, history written"
healthy; reset_logs
wd
check "exit 0" test "$RC" -eq 0
check "prints nothing on a normal run" test -z "$OUT"
check "no notification" test "$(nt_count)" -eq 0
check "healthchecks pinged once" test "$(hc_count)" -eq 1
check "state folder is 700" test "$(stat -c %a "$WSTATE")" = 700
check "history has one line" test "$(wc -l <"$HIST")" -eq 1
L=$(last_hist)
check "history line has every check" has "$L" "network=OK gateway=OK disk=OK:42% memory=OK:7812MB temp=OK:51C backup="
check "history line records the heartbeat" has "$L" "hc=ok alerts=0"
check "history line starts with a UTC timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' "$HIST"
check "ping was ping -c1 ... 1.1.1.1" grep -qE -- '-c1 .*1\.1\.1\.1' "$ST/ping.log"
check "systemctl --user had XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS (cron has neither)" test ! -e "$ST/no-dbus-env.log"
wd
check "second healthy run: still no notification" test "$(nt_count)" -eq 0
check "second run: heartbeat again (every run)" test "$(hc_count)" -eq 2

section "2. Disk: WARN, no repeat, CRIT (high), back to OK"
reset_logs; echo 90 >"$ST/disk.pct"; wd
check "one alert 'Jafar: disk WARN', default priority" test "$(nt)" = "Jafar: disk WARN|default"
wd
check "same state again: no new alert" test "$(nt_count)" -eq 1
echo 96 >"$ST/disk.pct"; wd
check "WARN -> CRIT alerts with high priority" test "$(nt | tail -n1)" = "Jafar: disk CRIT|high"
echo 85 >"$ST/disk.pct"; wd
check "85% is not above 85: back to OK" test "$(nt | tail -n1)" = "Jafar: disk OK|low"
check "exactly three alerts" test "$(nt_count)" -eq 3
echo 42 >"$ST/disk.pct"; wd
check "OK -> OK: nothing more" test "$(nt_count)" -eq 3

section "3. Memory and temperature"
reset_logs; meminfo 1000000; wd
check "MemAvailable ~976 MiB < 1536: 'Jafar: memory WARN'" test "$(nt)" = "Jafar: memory WARN|default"
meminfo 1572864; wd
check "exactly 1.5 GiB is not below: memory OK" test "$(nt | tail -n1)" = "Jafar: memory OK|low"
reset_logs; thermal 40000 86000 30000; wd
check "hottest zone 86 C > 85: 'Jafar: temp WARN'" test "$(nt)" = "Jafar: temp WARN|default"
check "history shows the hottest zone" has "$(last_hist)" "temp=WARN:86C"
thermal; wd
check "no thermal zones: no alert (skipped)" test "$(nt_count)" -eq 1
check "no thermal zones: history says SKIP" has "$(last_hist)" "temp=SKIP"
check "a skip keeps the old state" grep -q '^WARN ' "$WSTATE/temp.state"
thermal 50000; wd
check "readable again and cool: temp OK" test "$(nt | tail -n1)" = "Jafar: temp OK|low"

section "4. Backup marker age"
reset_logs; M="$HOMEDIR/.local/state/hermes-backup/last-success"
touch -d '27 hours ago' "$M"; wd
check "fallback marker 27 h old: 'Jafar: backup WARN'" test "$(nt)" = "Jafar: backup WARN|default"
touch -d '25 hours ago' "$M"; wd
check "25 h old: backup OK" test "$(nt | tail -n1)" = "Jafar: backup OK|low"
mkdir -p "$HOMEDIR/.local/state/jafar"; touch -d '30 hours ago' "$HOMEDIR/.local/state/jafar/last-backup"
touch "$M"; wd
check "the spec's marker ~/.local/state/jafar/last-backup wins over the fallback" test "$(nt | tail -n1)" = "Jafar: backup WARN|default"
rm -f "$HOMEDIR/.local/state/jafar/last-backup" "$M"; wd
check "no marker at all stays WARN (no repeat)" test "$(nt_count)" -eq 3
check "history says none" has "$(last_hist)" "backup=WARN:none"
healthy; wd
check "marker back: backup OK" test "$(nt | tail -n1)" = "Jafar: backup OK|low"

section "5. Gateway: restart once -> RESTARTED; still dead -> DOWN (high)"
reset_logs; rm -f "$ST/gateway.active"; wd
check "restart attempted exactly once" test "$(grep -c '^--user restart hermes-gateway$' "$ST/systemctl.log")" -eq 1
check "'Jafar: gateway RESTARTED'" test "$(nt)" = "Jafar: gateway RESTARTED|default"
check "state stored as OK after a successful restart" grep -q '^OK ' "$WSTATE/gateway.state"
wd
check "healthy next run: no further alert" test "$(nt_count)" -eq 1
reset_logs; rm -f "$ST/gateway.active" "$ST/gateway.restart-works"; wd
check "restart fails: 'Jafar: gateway DOWN' with high priority" test "$(nt)" = "Jafar: gateway DOWN|high"
wd
check "still down next run: restart tried again" test "$(grep -c '^--user restart hermes-gateway$' "$ST/systemctl.log")" -eq 2
check "still down: no second DOWN alert" test "$(nt_count)" -eq 1
: >"$ST/gateway.active"; wd
check "back up by itself: 'Jafar: gateway OK'" test "$(nt | tail -n1)" = "Jafar: gateway OK|low"
check "no systemctl call ever lacked the dbus variables" test ! -e "$ST/no-dbus-env.log"
healthy

section "6. Offline: nothing sent, states held, everything delivered once back"
reset_logs; rm -f "$ST/online"; echo 91 >"$ST/disk.pct"; wd
check "offline: no notification" test "$(nt_count)" -eq 0
check "offline: no healthchecks ping (it will notice the silence)" test "$(hc_count)" -eq 0
check "offline: disk state not advanced" test ! -e "$WSTATE/disk.state" -o -z "$(grep '^WARN' "$WSTATE/disk.state" 2>/dev/null)"
check "history records OFFLINE and pending" has "$(last_hist)" "network=OFFLINE"
check "history counts the pending alert" has "$(last_hist)" "hc=skipped alerts=0 pending=1"
rm -f "$ST/gateway.active" "$ST/gateway.restart-works"; : >"$ST/gateway.restart-works"; wd
check "offline: gateway still restarted locally" test "$(grep -c '^--user restart hermes-gateway$' "$ST/systemctl.log")" -eq 1
check "offline: RESTARTED remembered for later" grep -q '^RESTARTED ' "$WSTATE/gateway.state"
check "offline: still silent" test "$(nt_count)" -eq 0
: >"$ST/online"; wd
N=$(nt)
check "online again: 'Jafar: network OK'" has "$N" "Jafar: network OK|low"
check "online again: the held 'Jafar: disk WARN' is delivered" has "$N" "Jafar: disk WARN|default"
check "online again: the held 'Jafar: gateway RESTARTED' is delivered" has "$N" "Jafar: gateway RESTARTED|default"
check "online again: exactly those three" test "$(nt_count)" -eq 3
check "online again: heartbeat resumes" test "$(hc_count)" -eq 1
wd
check "next run: nothing repeated" test "$(nt_count)" -eq 3
healthy; wd

section "7. A failed ntfy send is retried next run"
reset_logs; : >"$ST/ntfy.fail"; echo 97 >"$ST/disk.pct"; wd
check "send failed: nothing logged as delivered" test "$(nt_count)" -eq 0
check "send failed: state not advanced" hasnt "$(cat "$WSTATE/disk.state")" "CRIT"
check "send failed: pending counted" has "$(last_hist)" "pending=1"
check "heartbeat still sent" test "$(hc_count)" -eq 1
rm -f "$ST/ntfy.fail"; wd
check "next run: 'Jafar: disk CRIT' delivered" test "$(nt)" = "Jafar: disk CRIT|high"
healthy; wd

section "8. Secrets stay off the command line; missing configs are survivable"
check "the ntfy token was never in curl's arguments" hasnt "$(cat "$ST/curl.argv")" "tk_sandbox_secret"
check "the ntfy token went in on stdin (--config -)" has "$(cat "$ST/curl.stdin")" 'header = "Authorization: Bearer tk_sandbox_secret"'
mv "$HOMEDIR/.config/jafar/healthchecks.env" "$SB/hc.bak"; mv "$HOMEDIR/.config/jafar/ntfy.env" "$SB/ntfy.bak"
reset_logs; echo 90 >"$ST/disk.pct"; wd
check "no configs: still exits 0" test "$RC" -eq 0
check "no configs: history says hc=unset and ntfy=unset" has "$(last_hist)" "hc=unset alerts=0 pending=1 ntfy=unset"
mv "$SB/hc.bak" "$HOMEDIR/.config/jafar/healthchecks.env"
printf 'NTFY_SERVER=https://ntfy.example/\nNTFY_TOPIC=jafar-topic\n' >"$HOMEDIR/.config/jafar/ntfy.env"
wd
check "NTFY_SERVER + NTFY_TOPIC form works and the held alert arrives" test "$(nt)" = "Jafar: disk WARN|default"
mv "$SB/ntfy.bak" "$HOMEDIR/.config/jafar/ntfy.env"
healthy; wd

section "9. history.log keeps 7 days"
{ echo "$(date -u -d '8 days ago' +%Y-%m-%dT%H:%M:%SZ) old=drop"
  echo "$(date -u -d '6 days ago' +%Y-%m-%dT%H:%M:%SZ) recent=keep"; } >"$HIST"
wd
check "8-day-old line dropped" hasnt "$(cat "$HIST")" "old=drop"
check "6-day-old line kept" has "$(cat "$HIST")" "recent=keep"
check "this run appended" test "$(wc -l <"$HIST")" -eq 2

section "10. --check changes nothing"
rm -rf "$WSTATE"; reset_logs; rm -f "$ST/gateway.active"; echo 99 >"$ST/disk.pct"
wd --check
check "exit 0" test "$RC" -eq 0
check "reports gateway DOWN" grep -qE '^gateway +DOWN' <<<"$OUT"
check "reports disk CRIT" grep -qE '^disk +CRIT' <<<"$OUT"
check "reports every check" test "$(grep -cE '^(network|gateway|disk|memory|temp|backup) ' <<<"$OUT")" -eq 6
check "no restart" test "$(grep -c restart "$ST/systemctl.log")" -eq 0
check "no notification, no heartbeat" test ! -e "$ST/ntfy.log" -a ! -e "$ST/hc.log"
check "no state folder created" test ! -e "$WSTATE"
healthy
WD_CONF="$WD/thresholds.conf" wd --check
check "the shipped thresholds.conf parses" test "$RC" -eq 0

section "11. Guards: root, bad arguments, bad thresholds.conf"
FAKE_UID=0 wd
check "refuses root (exit 2)" test "$RC" -eq 2
wd --bogus
check "unknown option (exit 2)" test "$RC" -eq 2
printf 'DISK_WARN_PCT=eighty\n' >"$SB/bad.conf"; WD_CONF="$SB/bad.conf" wd --check
check "non-number threshold (exit 2)" test "$RC" -eq 2
printf 'DISK_WARN_PCT=96\nDISK_CRIT_PCT=95\n' >"$SB/bad.conf"; WD_CONF="$SB/bad.conf" wd --check
check "WARN above CRIT (exit 2)" test "$RC" -eq 2
printf 'PING_HOST=1.1.1.1;rm\n' >"$SB/bad.conf"; WD_CONF="$SB/bad.conf" wd --check
check "unsafe PING_HOST (exit 2)" test "$RC" -eq 2
printf 'FOO=1\n' >"$SB/bad.conf"; WD_CONF="$SB/bad.conf" wd --check
check "unknown key only warns (exit 0)" test "$RC" -eq 0

section "12. install.sh / uninstall.sh"
rm -rf "$HOMEDIR/.local/state/jafar"; rm -f "$ST/crontab"
echo "0 1 * * * /bin/true # someone else's line" >"$ST/crontab"
inst install.sh --dry-run
check "dry run exits 0" test "$RC" -eq 0
check "dry run reports 'would run'" has "$OUT" "would run"
check "dry run changed nothing" test ! -e "$HOMEDIR/.local/state/jafar" -a "$(cat "$ST/crontab")" = "0 1 * * * /bin/true # someone else's line"
inst install.sh
check "install exits 0" test "$RC" -eq 0
check "state folder 700" test "$(stat -c %a "$WSTATE")" = 700
check "\$HOME/.local/state/jafar is 700" test "$(stat -c %a "$HOMEDIR/.local/state/jafar")" = 700
check "last-backup links to item #1's marker" test "$(readlink "$HOMEDIR/.local/state/jafar/last-backup")" = "$HOMEDIR/.local/state/hermes-backup/last-success"
CRON=$(cat "$ST/crontab")
check "cron line runs every 5 minutes" has "$CRON" "*/5 * * * * ${WD}/watchdog.sh >>${WSTATE}/cron.log 2>&1 # jafar-watchdog:managed"
check "other crontab lines kept" has "$CRON" "someone else's line"
check "previous crontab saved" compgen -G "${WSTATE}/crontab.before-*" >/dev/null
inst install.sh
check "second install: exit 0" test "$RC" -eq 0
check "second install: nothing to do" test -z "$(grep -E '^watchdog: [a-z]+ +done \(' <<<"$OUT")"
check "second install: one managed line only" test "$(grep -c jafar-watchdog:managed "$ST/crontab")" -eq 1
inst install.sh --dry-run
check "dry run after install: no 'would run' (bootstrap step 9 treats it as done)" hasnt "$OUT" "would run"
chmod 644 "$HOMEDIR/.config/jafar/ntfy.env"; inst install.sh --dry-run
check "loose secrets file is reported, not changed" has "$OUT" "should be chmod 600"
check "...and it is only a NOTE (no 'would run')" hasnt "$OUT" "would run"
chmod 600 "$HOMEDIR/.config/jafar/ntfy.env"
wd
check "the linked marker is read through the link" has "$(last_hist)" "backup=OK:"
FAKE_UID=0 inst install.sh
check "install refuses root" test "$RC" -eq 2
inst uninstall.sh --dry-run
check "uninstall dry run: would run, nothing removed" test "$(grep -c jafar-watchdog:managed "$ST/crontab")" -eq 1
inst uninstall.sh
check "uninstall exits 0" test "$RC" -eq 0
check "uninstall removed the managed line" test "$(grep -c jafar-watchdog:managed "$ST/crontab")" -eq 0
check "uninstall kept the other line" has "$(cat "$ST/crontab")" "someone else's line"
check "uninstall removed the link" test ! -L "$HOMEDIR/.local/state/jafar/last-backup"
check "uninstall kept the secrets and history" test -f "$HOMEDIR/.config/jafar/ntfy.env" -a -f "$HIST"
check "item #1's marker untouched" test -f "$HOMEDIR/.local/state/hermes-backup/last-success"
inst uninstall.sh
check "second uninstall: already done" has "$OUT" "already done (no managed watchdog line)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
