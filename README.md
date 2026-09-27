# jafar-infra-

Infrastructure for Jafar — a headless Debian/DietPi server running
[Hermes Agent](https://hermes-agent.nousresearch.com/) as user `dietpi`.

| Directory | What |
|---|---|
| [`backup/`](backup/README.md) | Disaster-recovery backup & restore of `~/.hermes`: nightly cron, validated archives, off-box upload via rclone (provider-agnostic), sandboxed test suite |

Server facts: [`CONTEXT.md`](CONTEXT.md) and [`docs/hermes-facts.md`](docs/hermes-facts.md)
(every Claude Code session reads these first).

Every item folder has `install.sh`, `uninstall.sh`, `test.sh` and `README.md`;
`install.sh` and `uninstall.sh` accept `--dry-run`.

Start with [`backup/README.md`](backup/README.md); verify with
[`backup/TESTING.md`](backup/TESTING.md).

No secrets live in this repository — see `.gitignore`.
