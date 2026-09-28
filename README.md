# jafar-infra-

Infrastructure for Jafar — a headless Debian/DietPi server running
[Hermes Agent](https://hermes-agent.nousresearch.com/) as user `dietpi`.

| Directory | What |
|---|---|
| [`bootstrap/`](bootstrap/README.md) | #2 Rebuild-from-zero: one script turns a fresh DietPi into Jafar (`--dry-run`, `--from-step N`) |
| [`backup/`](backup/README.md) | Disaster-recovery backup & restore of `~/.hermes`: nightly cron, validated archives, off-box upload via rclone (provider-agnostic), sandboxed test suite |
| [`watchdog/`](watchdog/README.md) | #3 Watchdog: every 5 minutes checks gateway, disk, memory, temperature, network and backup age; ntfy alerts on state changes; healthchecks heartbeat |

Server facts: [`CONTEXT.md`](CONTEXT.md) and [`docs/hermes-facts.md`](docs/hermes-facts.md)
(every Claude Code session reads these first). **When a PR changes what's
true about the live server** (a new cron job, config path, state file,
installed package, anything a later item needs to know or might collide
with), it updates `CONTEXT.md`'s "Observed on the server" table in the
same PR — see the note at the top of that file.

Every item folder has `install.sh`, `uninstall.sh`, `test.sh` and `README.md`;
`install.sh` and `uninstall.sh` accept `--dry-run`.

Start with [`backup/README.md`](backup/README.md); verify with
[`backup/TESTING.md`](backup/TESTING.md).

No secrets live in this repository — see `.gitignore`.
