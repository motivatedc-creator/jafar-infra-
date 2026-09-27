# CONTEXT: server facts

Every Claude Code session reads this file and `docs/hermes-facts.md` first.
They are the only source of server facts. Anything not stated here is an
assumption and must be listed as one.

Sources: the seven bullets from the Jafar Build Plan ("How this plan works"),
plus a read-only audit Jafar ran on the server on 2026-09-27 (marked
*observed*).

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
| Repo on server | `~/jafar-infra-` (note the trailing dash), HTTPS origin, pulls via the `gh` CLI login (no deploy key, no `~/.git-credentials`) |
| Backup (#1) | `~/jafar-infra-/backup/backup-hermes.sh`, user crontab `30 3 * * *`; config `~/.config/hermes-backup/config`; remote `jafar-encrypted:` (rclone crypt over `gdrive:`); local archives `~/hermes-backups` (keep 7), remote keep 30 |
| Backup success marker | `~/.local/state/hermes-backup/last-success` (`<time> <archive name>`); logs in `~/.local/state/hermes-backup/logs/` |
| Not installed yet | `jq`, `age`, `tailscale` |
| **Docker** | **installed (`/usr/bin/docker`) and `dietpi` is in the `docker` group.** Group membership is root-equivalent without a password, which contradicts "no passwordless sudo" and "No Docker" above. Leftover from the OpenHands test; removal is a separate, operator-approved step. |
| `~/.local/state/jafar/` | does not exist yet |

Hermes facts: see `docs/hermes-facts.md`.
