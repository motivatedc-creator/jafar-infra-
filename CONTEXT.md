# CONTEXT: server facts

Every Claude Code session reads this file and `docs/hermes-facts.md` first.
They are the only source of server facts. Anything not stated here is an
assumption and must be listed as one.

Sources: the seven bullets from the Jafar Build Plan ("How this plan works"),
plus a read-only audit Jafar ran on the server on 2026-09-27 (marked
*observed*).

**Keeping this file current:** the build plan writes this file once, in
session 1, but each item after that changes the live server in ways the
next session needs to know without re-deriving or guessing them. So: when
a PR adds a cron job, a config path, a state file, an installed package,
or anything else a later item might depend on or collide with, add one row
to "Observed on the server" (or update an existing one) in that same PR.
Keep it to facts a future session needs — paths, schedules, markers,
service names — not the item's design or how it works; that belongs in
the item's own README.md.

## From the build plan

- Hardware: salvaged AIO board, i7-7700HQ, ~16 GB RAM, 256 GB SATA SSD, Ethernet, no display.
- OS: DietPi (Debian). User `dietpi`, home `/home/dietpi`. Operator timezone Asia/Dubai.
- `dietpi` has no passwordless sudo. Anything needing root is either a separate step the operator runs with sudo, or runs from root's crontab.
- Hermes lives in `~/.hermes`. Gateway = systemd user service `hermes-gateway`, linger enabled.
- The operator is phone-only: every instruction must be copy-pasteable, one command per line.
- Secrets live in `~/.config/jafar/*.env` (chmod 600), never in git.
- Bash checked with shellcheck. Python 3 standard library preferred. No Docker.

## Observed on the server (2026-09-27)

| Fact | Value |
|---|---|
| Debian version | 13.7 |
| `dietpi` | uid 1000, gid 1000; `sudo -n true` fails (password required) |
| System clock | **UTC** (`timedatectl`). Cron times are UTC: 03:30 UTC = 07:30 Dubai |
| systemd-logind | unit is `static` (no install section), `active` |
| Linger / user bus | `Linger=yes`; `/run/user/1000/bus` exists |
| Hermes | v0.21.5+2168, code in `~/.hermes/hermes-agent` (git, rev 59004a623), CLI `~/.local/bin/hermes` |
| Gateway unit | `~/.config/systemd/user/hermes-gateway.service` (written by `hermes gateway install`), enabled, active |
| Repo on server | `~/jafar-infra-` (note the trailing dash), HTTPS origin, pulls **and pushes** via the `gh` CLI login (no deploy key, no `~/.git-credentials`); Jafar has used it to open a PR (`gh pr create`) successfully, so the login carries repo write scope, not just read |
| Backup (#1) | `~/jafar-infra-/backup/backup-hermes.sh`, user crontab `30 3 * * *`; config `~/.config/hermes-backup/config`; remote `jafar-encrypted:` (rclone crypt over `gdrive:`); local archives `~/hermes-backups` (keep 7), remote keep 30 |
| Backup success marker | `~/.local/state/hermes-backup/last-success` (`<time> <archive name>`); logs in `~/.local/state/hermes-backup/logs/` |
| Watchdog (#3) | `~/jafar-infra-/watchdog/watchdog.sh`, user crontab `*/5 * * * *`; secrets `~/.config/jafar/ntfy.env` (`NTFY_URL=`) and `~/.config/jafar/healthchecks.env` (`HC_URL=`), both chmod 600; state and history in `~/.local/state/jafar/watchdog/`; installed and live-verified (13/13 PASS) on 2026-09-27 |
| Not installed yet | `jq`, `age`, `tailscale` |
| **Docker** | **installed (`/usr/bin/docker`) and `dietpi` is in the `docker` group.** Group membership is root-equivalent without a password, which contradicts "no passwordless sudo" and "No Docker" above. Leftover from the OpenHands test; removal is a separate, operator-approved step. |
| `~/.local/state/jafar/` | exists now (created by #3); holds `watchdog/` and a `last-backup` symlink to item #1's success marker |

Hermes facts: see `docs/hermes-facts.md`.
