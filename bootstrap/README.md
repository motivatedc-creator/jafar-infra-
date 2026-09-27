# #2 Rebuild-from-zero

One script turns a freshly flashed DietPi into Jafar. Every fix learned the
hard way (libatomic, dbus, logind, linger) is encoded once, and every step
checks first, so the same script is safe to run on the live server.

```
bootstrap/
  bootstrap.sh     the 10 steps (--dry-run, --from-step N)
  packages.txt     apt packages for step 1, one per line
  install.sh       nothing to install (bootstrap is run by hand); --dry-run
  uninstall.sh     nothing to remove; never undoes the server; --dry-run
  test.sh          the plan's check: --dry-run must say "already done" x10
  README.md        this file
  tests/run-tests.sh  offline suite with stubbed system commands
```

## The steps

| # | Step | Already done when | Otherwise |
|---|---|---|---|
| 1 | packages | every package in `packages.txt` is installed | `sudo apt-get update`, `sudo apt-get install -y <missing>` |
| 2 | logind | `systemd-logind` is not masked and is active | `sudo systemctl unmask`, then `start` (it is a `static` unit, so there is nothing to `enable`) |
| 3 | linger | `Linger=yes` and `/run/user/<uid>/bus` exists | `sudo loginctl enable-linger dietpi`; if the bus still doesn't appear, `sudo systemctl start user@<uid>.service` |
| 4 | tailscale | `tailscale` is installed | official installer from `https://tailscale.com/install.sh`, then prints **now run: sudo tailscale up** (never run for you) |
| 5 | hermes | `~/.local/bin/hermes` and `~/.hermes/hermes-agent` exist | official installer from the **V11 row of `docs/hermes-facts.md`**, run with `--non-interactive --skip-setup`. No URL there = stop (exit 2) |
| 6 | re-auth | `hermes-gateway` is running | **pause** with the checklist: `hermes auth add openai-codex`, `hermes photon setup --phone <+971...>` |
| 7 | rclone | `~/.config/rclone/rclone.conf` exists and has the backup remote (`jafar-encrypted:`) | **pause**, pointing to `backup/README.md` section 4.3 |
| 8 | restore | a restore is not needed (see below) **and** the gateway service exists and runs | `bash backup/hermes-restore.sh latest --force`, then `hermes config check`, `hermes gateway install`, `hermes gateway start` |
| 9 | items | every item's `install.sh --dry-run` reports nothing to do | runs the items that report "would run", in the plan's folder order: backup, watchdog, update, guard, secrets, models, evals, dashboard, digest, skills/*, mcp |
| 10 | checks | gateway active, `Linger=yes`, user bus present | prints PASS/FAIL per check; any FAIL = exit 1 |

Installers are downloaded to a private temp file first and only then run,
so a cut-off download never executes. Docker and OpenHands are never
installed; `bootstrap.sh` refuses a `packages.txt` that lists them.

**When step 8 skips the restore:** if bootstrap already restored once
(marker `~/.local/state/jafar/bootstrap-restored`), or if
`~/.hermes/state.db` already holds at least one conversation. That protects
the live server: restoring there would roll `~/.hermes` back to the last
03:30 backup. A fresh install has no `state.db` (or 0 conversations) until
the gateway runs.

**Pauses** stop the script with exit code 20 and print the exact command to
continue, e.g. `bash ~/jafar-infra-/bootstrap/bootstrap.sh --from-step 7`.
In `--dry-run` they only say "would pause".

## Rebuilding a dead server (one command per line)

Before you start you need, from the vault: the sudo password, the Google
login, and both rclone crypt passwords.

1. Flash DietPi to the new SSD, boot, finish the DietPi first-run setup, and
   SSH in as `dietpi`.
2. Give the server access to the private repo, as the old one had it
   (the `gh` CLI login):

   ```
   sudo apt update
   sudo apt install -y git gh
   gh auth login
   gh repo clone motivatedc-creator/jafar-infra- ~/jafar-infra-
   ```

3. Preview, then run:

   ```
   bash ~/jafar-infra-/bootstrap/bootstrap.sh --dry-run
   bash ~/jafar-infra-/bootstrap/bootstrap.sh
   ```

4. When it prints `now run: sudo tailscale up`, run that after the script
   pauses, and approve the machine on your phone.
5. At the **re-auth** pause, run the two commands it prints, then continue
   with the printed `--from-step 7` command.
6. At the **rclone** pause (fresh machine), recreate `gdrive` and
   `jafar-encrypted` as in `backup/README.md` section 4.3, then continue with
   `--from-step 7` again.
7. The run ends with `bootstrap: PASS`. Text Jafar "ping".

## On the live server (the plan's install ritual)

```
cd ~/jafar-infra- && git pull
bash bootstrap/install.sh
bash bootstrap/test.sh
```

`test.sh` runs `bootstrap.sh --dry-run` and needs `already done` on all 10
steps. Any "would run" on the live server is either real missing setup or a
bug; paste the output back to the Claude Code session. As of 2026-09-27
the server lacks `jq`, `age` and Tailscale (see `CONTEXT.md`), so steps 1
and 4 will say "would run" until `bash bootstrap/bootstrap.sh` (or #11)
installs them.

Offline suite (stubs every system command; safe anywhere):

```
bash bootstrap/test.sh --sandbox
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every step done, final checks PASS |
| 1 | a step or a final check failed |
| 2 | usage error, run as root, or a required fact is missing (e.g. no installer URL) |
| 20 | paused for the operator; the output says what to do and how to continue |
