# #3 Watchdog

A dead Jafar can't report his own death, so something outside Hermes does it.
Every 5 minutes cron runs `watchdog.sh` as `dietpi`. It checks the machine,
restarts a stopped gateway once, sends a phone notification through
**ntfy** when a check changes state, and pings **healthchecks**. If the box,
cron or this script dies, the pings stop and healthchecks raises the alarm
from outside.

```
watchdog/
  watchdog.sh       one run (cron); --check = read-only report
  thresholds.conf   the limits (no secrets); edits apply on the next run
  install.sh        state folder, backup-marker link, cron line; --dry-run
  uninstall.sh      removes the cron line and the link; --dry-run
  test.sh           live check on the server; --sandbox = offline suite
  README.md         this file
  tests/run-tests.sh  offline suite with stubbed commands and a fake home
```

## The checks

| Check | How | States |
|---|---|---|
| network | `ping -c1 -W 5 1.1.1.1` (`PING_HOST`) | `OK`, `OFFLINE` |
| gateway | `systemctl --user is-active hermes-gateway`; if not active: `restart` once, wait 30 s, check again | `OK`, `RESTARTED`, `DOWN` |
| disk | `/` use from `df -P /` | `OK`, `WARN` > 85 %, `CRIT` > 95 % |
| memory | `MemAvailable` from `/proc/meminfo` | `OK`, `WARN` < 1536 MiB (1.5 GB) |
| temp | hottest `/sys/class/thermal/thermal_zone*/temp` | `OK`, `WARN` > 85 C; `SKIP` when no zone is readable |
| backup | age of `~/.local/state/jafar/last-backup` | `OK`, `WARN` older than 26 h or missing |
| heartbeat | `curl -fsS -m 10 "$HC_URL"` | every run that is online |

All limits are in `thresholds.conf`.

## Alerts

- Sent only when a check **changes** state: OK to bad, bad to OK, and
  WARN to CRIT or back. Nothing repeats while a state holds.
- Title: `Jafar: <check> <STATE>`, e.g. `Jafar: disk CRIT`,
  `Jafar: gateway RESTARTED`, `Jafar: backup OK`. The body says the value
  and the limit.
- Priority: `CRIT` and gateway `DOWN` = **high**; `WARN` and `RESTARTED` =
  default; back to `OK` = low.
- **While OFFLINE nothing is sent** (it couldn't be) and the other checks'
  states are held. On the first run back online you get `Jafar: network OK`
  plus every change that happened meanwhile. The heartbeat also pauses, so
  a long outage shows up on healthchecks.
- A failed ntfy send is retried on the next run the same way.
- `SKIP` (no data this run) never alerts and keeps the previous state.
- A gateway that stays `DOWN` is restarted again on every run, but alerts
  only once.

## Files on the server

| Path | What |
|---|---|
| `~/.config/jafar/ntfy.env` | `NTFY_URL=https://ntfy.sh/<topic>` (or `NTFY_SERVER=` + `NTFY_TOPIC=`); optional `NTFY_TOKEN=` for a protected topic. chmod 600 |
| `~/.config/jafar/healthchecks.env` | `HC_URL=https://hc-ping.com/<uuid>`. chmod 600 |
| `~/.local/state/jafar/watchdog/<check>.state` | last reported state and when it was set |
| `~/.local/state/jafar/watchdog/history.log` | one line per run, 7 days kept |
| `~/.local/state/jafar/watchdog/cron.log` | error output only (trimmed at 100 KB) |
| `~/.local/state/jafar/last-backup` | link made by `install.sh` to item #1's `~/.local/state/hermes-backup/last-success` |

The env files are read as plain `KEY=value` lines, never executed. The ntfy
token reaches `curl` on stdin, not on its command line.

A history line looks like:

```
2026-09-27T20:05:01Z network=OK gateway=OK disk=OK:42% memory=OK:12034MB temp=OK:51C backup=OK:16h hc=ok alerts=0
```

## Setup (one command per line)

1. **ntfy**: install the ntfy app on the phone and subscribe to a topic
   name that is long and hard to guess (anyone who knows it can read it).
2. **healthchecks**: at healthchecks.io create a check with **period 5
   minutes, grace 10 minutes**, and add a notification method that reaches
   the phone (its ntfy integration on the same or another topic, or email).
   Copy its ping URL.
3. On the server, as `dietpi`, replace `<topic>` and `<uuid>`:

   ```
   mkdir -p ~/.config/jafar
   chmod 700 ~/.config/jafar
   install -m 600 /dev/null ~/.config/jafar/ntfy.env
   printf 'NTFY_URL=https://ntfy.sh/<topic>\n' > ~/.config/jafar/ntfy.env
   install -m 600 /dev/null ~/.config/jafar/healthchecks.env
   printf 'HC_URL=https://hc-ping.com/<uuid>\n' > ~/.config/jafar/healthchecks.env
   cd ~/jafar-infra-
   git pull
   bash watchdog/install.sh --dry-run
   bash watchdog/install.sh
   ```

4. Wait 5 minutes, then:

   ```
   bash ~/jafar-infra-/watchdog/test.sh
   ```

   Every line must say PASS, and the phone must show
   **Jafar: watchdog TEST**.

`install.sh` is idempotent: run it again any time; it prints
`already done` for each step. It never writes the env files; it only
reports if one is missing or not chmod 600. If `ping` is missing it says so
(`sudo apt-get install -y iputils-ping`); until then the network check uses
a TCP connect to the same host.

## Everyday commands

```
bash ~/jafar-infra-/watchdog/watchdog.sh --check
tail -n 20 ~/.local/state/jafar/watchdog/history.log
bash ~/jafar-infra-/watchdog/test.sh --sandbox
```

`--check` evaluates every check and prints it. It does not restart the
gateway, send anything, ping healthchecks, or touch any state file.

To change a limit, edit `~/jafar-infra-/watchdog/thresholds.conf`; the next
run uses it. A malformed value makes `watchdog.sh` exit 2 and write the
reason to `cron.log`; healthchecks then alerts because the pings stop.

## Acceptance tests (operator, after merge)

Not run by Claude Code; they touch the live gateway and the power.

**Gateway stop** (expected: `Jafar: gateway RESTARTED` within about 5.5
minutes, gateway running again):

```
systemctl --user stop hermes-gateway
```

Wait for the notification, then:

```
systemctl --user is-active hermes-gateway
tail -n 3 ~/.local/state/jafar/watchdog/history.log
```

**Power cut** (expected: healthchecks reports the check down about 15
minutes after the cut; after power returns, pings resume and healthchecks
reports it up; the watchdog sends `Jafar: backup ...` or others only if
something actually changed): pull the power, wait 20 minutes, restore it,
wait 10 minutes, then:

```
bash ~/jafar-infra-/watchdog/test.sh
```

## Uninstall

```
bash ~/jafar-infra-/watchdog/uninstall.sh --dry-run
bash ~/jafar-infra-/watchdog/uninstall.sh
```

It removes the cron line and the `last-backup` link. It keeps the env
files, states and history. Pause the check on healthchecks first, or it
will alert when the pings stop.
