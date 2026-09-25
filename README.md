# jafar-infra-

Infrastructure for Jafar — a headless Debian/DietPi server running
[Hermes Agent](https://hermes-agent.nousresearch.com/) as user `dietpi`.

| Directory | What |
|---|---|
| [`backup/`](backup/README.md) | Disaster-recovery backup & restore of `~/.hermes`: nightly cron, validated archives, off-box upload via rclone (provider-agnostic), sandboxed test suite |

Start with [`backup/README.md`](backup/README.md); verify with
[`backup/TESTING.md`](backup/TESTING.md).

No secrets live in this repository — see `.gitignore`.
