# Hermes Agent disaster-recovery backup

Nightly, off-box, validated backups of the persistent parts of a Hermes Agent
install (`/home/dietpi/.hermes`) on a headless Debian/DietPi server, plus a
restore tool for rebuilding the machine after the SSD dies.

```
backup/
  install.sh              install item #1: config + nightly cron (--dry-run)
  uninstall.sh            remove the cron job; keeps config and backups (--dry-run)
  test.sh                 live check: real backup + restore drill, PASS/FAIL
  README.md               this file
  hermes-backup.sh        plan name for backup-hermes.sh (same thing)
  hermes-restore.sh       plan interface: <archive|latest> [--target] [--force]
  backup-hermes.sh        create → validate → upload → verify (run by cron)
  restore-hermes.sh       inspect / dry-run / restore an archive (full options)
  install-cron.sh         install/remove the nightly cron job (used by install.sh)
  config.example          the server's settings; install.sh copies it to
                          ~/.config/hermes-backup/config
  lib/common.sh           shared helpers (logging, config, safety checks)
  lib/backend-rclone.sh   off-box backend: any rclone remote (reference)
  lib/backend-localdir.sh off-box backend: mounted NAS share / directory
  tests/run-tests.sh      sandboxed end-to-end test suite
  TESTING.md              manual + automated test procedure
```

### Quick start (the plan's install ritual)

One command per line, as `dietpi`, from the repo on the server:

```bash
cd ~/jafar-infra- && git pull
bash backup/install.sh --dry-run
bash backup/install.sh
bash backup/test.sh
```

- `install.sh` prints `already done`, `done` or (with `--dry-run`) `would run`
  for each step, so running it twice changes nothing.
- `test.sh` runs one real backup (uploaded and verified off-box), restores the
  newest off-box archive into a temporary folder, compares it, and deletes the
  folder. Every line must say `PASS`. `bash backup/test.sh --sandbox` runs the
  offline suite instead (fake data, no upload).
- Restore, plan style: `bash backup/hermes-restore.sh latest --force` (§6).

---

## 1. How it works

```
~/.hermes ──(allowlist + secret excludes)──▶ private staging dir
          ──(SQLite online-backup API)────▶ consistent state.db snapshot
          ──▶ MANIFEST.sha256 + ITEMS + BACKUP_INFO
          ──▶ hermes-backup-<host>-<UTC timestamp>.tar.gz  (+ .sha256)
          ──▶ validate: gzip -t, required entries, tar --compare vs staging
          ──▶ upload_backup()        (backend: rclone / localdir / yours)
          ──▶ verify_remote_backup() (exists + size, and by default SHA-256 read-back)
          ──▶ prune old local copies (only after a verified upload)
```

The run is only reported as successful (exit 0, `last-status` = `OK`) once
the off-box copy has been verified. A failed upload leaves the archive in the
local staging dir, exits `3`, and says so in the log.

### Exit codes

| Script | Code | Meaning |
|---|---|---|
| backup | 0 | archive created, validated, uploaded **and verified off-box** |
| backup | 1 | unexpected error, no backup produced |
| backup | 2 | configuration / prerequisite error |
| backup | 3 | local archive OK, but **off-box upload or verification failed** (also `--no-upload`) |
| backup | 4 | secret guard tripped (a credential-like file reached the payload) |
| backup | 75 | another backup run is still holding the lock |
| restore | 5 | archive validation failed — nothing was changed |
| restore | 6 | aborted / confirmation missing — nothing was changed |

---

## 2. What is backed up (and what is not)

Backed up — from `~/.hermes/` **and from every `~/.hermes/profiles/<name>/`**:

| Path | Why |
|---|---|
| `config.yaml` | behaviour/config (Hermes keeps secrets in `.env`, not here) |
| `SOUL.md` | agent identity |
| `memories/` | `MEMORY.md`, `USER.md` |
| `skills/` | installed and self-written skills (minus `skills/.hub/` cache) |
| `cron/` | Hermes' own scheduled jobs (`jobs.json`) and their output |
| `sessions/` | session artifacts |
| `hooks/` | user shell hooks |
| `state.db` | SQLite: sessions, messages, full-text index. Captured with SQLite's online backup API (consistent while Hermes runs; WAL content included) and integrity-checked |
| `kanban.db` | SQLite: the Kanban multi-agent task board — tasks, boards, comments, links. **Default board only**; see the note below. Same snapshot/integrity treatment as `state.db` |
| `shared-state.db` | SQLite: Bot Mode "hosted rooms" — durable group-chat room identity, membership and disband state (introduced in Hermes v0.21.2, split out of `state.db` to avoid concurrent-writer corruption). Same snapshot/integrity treatment as `state.db` |

`kanban.db` and `shared-state.db` are official Hermes-core files (not
plugins), and each is created lazily — it only appears once you've actually
used that feature. Both are documented as durable, not reconstructable from
anything else Hermes keeps: the [Kanban reference](https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban)
calls the board "a durable task board... every handoff is a row... an audit
trail: durable rows in SQLite **forever**", and the
[Bot Mode reference](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)
says a room "carries a durable internal identity" and that "room state lives
in the install's root `shared-state.db`". If your install has never used
Kanban or Bot Mode group chats, these files won't exist and are simply
skipped — nothing to configure.

**Kanban limitation:** only the **default board**'s `~/.hermes/kanban.db` is
backed up. Additional named boards you create with `hermes kanban boards
create <slug>` live at `~/.hermes/kanban/boards/<slug>/kanban.db` and are
**not** covered — the `kanban/` directory (which also holds ephemeral worker
workspaces) is deliberately excluded. If you use multiple boards, add the
board's DB path to `EXTRA_INCLUDE_PATHS` yourself, e.g.
`EXTRA_INCLUDE_PATHS=(kanban/boards/myproject/kanban.db)`.

The list is `INCLUDE_PATHS` in `lib/common.sh`; add your own with
`EXTRA_INCLUDE_PATHS` in the config. It is an **allowlist**: anything not
listed is not copied, so new credential files Hermes might add later are not
swept up by accident. To make sure new *data* is not silently missed either,
every run logs a `WARN` for each top-level entry that is neither backed up nor
on the known-excluded list:

```
[WARN] Not backed up (unknown entry, review it): some-new-dir - add to EXTRA_INCLUDE_PATHS if it is user data
```

Deliberately **excluded**:

| Excluded | Reason | After restore |
|---|---|---|
| `.env` | API keys, bot tokens | recreate by hand |
| `auth.json`, `auth/`, `.anthropic_oauth.json`, `credentials` | provider auth / OAuth tokens | log in again |
| `google_token.json`, `google_oauth_pending.json` | Google Workspace OAuth | re-authorize |
| `mcp-tokens/` | MCP server OAuth tokens | `hermes mcp login <server>` |
| `pairing/` | messaging-platform pairing/approval state | re-approve users |
| `whatsapp/` | WhatsApp session credentials | re-scan QR code |
| `hermes-agent/`, `node/`, `bin/`, `venv/` | code and runtimes | reinstall Hermes |
| `cache/`, `image_cache/`, `audio_cache/`, `document_cache/`, `sandboxes/`, `checkpoints/`, `logs/` | caches, scratch, logs | regenerated |
| `state.db-wal`, `-shm`, `-journal` (same for `kanban.db`, `shared-state.db`) | folded into the snapshot | — |
| `kanban/` (the directory: `kanban/workspaces/`, `kanban/boards/`, `kanban/current`) | ephemeral worker scratch space, plus non-default boards | recreate boards/workspaces; see the Kanban limitation above |

`tools/`, `installs/`, `environments/`, `lsp/`, `vault/`, and every lock
file, PID file, socket and gateway runtime file (`*.lock`, `gateway.pid`,
`gateway.sock`, `gateway_state.json`, `*.dispatch.lock`, `*.init.lock`, …)
are excluded the same way as any other name not on the allowlist: they are
simply never in `INCLUDE_PATHS`, so `backup-hermes.sh` never looks at them.
That is also why they show up as `unknown entry` warnings in the log (as
`kanban/` did before this change) — expected and safe, not a bug. `tools/`,
`installs/` and `environments/` in particular can be very large (downloaded
runtimes/toolchains); leaving them out of the allowlist is what keeps
archives small, not a size cutoff.

Inside the included directories, these names are also excluded anywhere
(and the staged payload is re-scanned for them before archiving — a hit
aborts the run with exit 4): `.env`, `.env.*`, `*.env`, `auth.json`, `auth`,
`credentials`, `credentials.json`, `token.json`, `*_oauth.json`, `mcp-tokens`,
`pairing`, `.netrc`, `.git-credentials`, `.pgpass`, `rclone.conf`, SSH keys
(`id_rsa*`, `id_ed25519*`, `id_ecdsa*`), `*.pem`, `*.key`, `*.p12`, `*.pfx`,
`*.kdbx`. Disposable names are dropped too (`__pycache__`, `*.pyc`,
`node_modules`, `venv`, `.venv`, `.cache`, `.hub`, `*.tmp`, editor swap files,
`*.pid`, `*.sock`). Each credential-pattern hit is logged by **path only**.

> ⚠️ **The archive is still sensitive.** `state.db`, `sessions/` and
> `memories/` hold your conversation history — including anything you ever
> pasted into a chat. `kanban.db` holds task titles/bodies/comments, and
> `shared-state.db` holds your Bot Mode room names and membership. Use an
> encrypted rclone remote (`crypt`, §4.3).

---

## 3. Prerequisites

Assumed: Debian-based DietPi, user `dietpi`, Hermes at `/home/dietpi/.hermes`,
this repository cloned to `/home/dietpi/jafar-infra-` (adjust paths if not).
No passwordless sudo is needed; `sudo` is only used once to install packages.

| Need | Debian package | Notes |
|---|---|---|
| bash ≥ 4.4, coreutils, findutils, gzip | preinstalled | |
| GNU tar | `tar` | BusyBox tar is not supported |
| `flock` | `util-linux` | overlap protection |
| `sqlite3` **or** `python3` | `sqlite3` (recommended) | consistent `state.db` snapshots |
| rclone | `rclone` or upstream installer | off-box upload |
| cron | `cron` | nightly schedule |
| `pgrep` (optional) | `procps` | restore refuses to replace a live home while Hermes runs |

```bash
sudo apt update
sudo apt install -y sqlite3 cron tar gzip util-linux procps
systemctl is-active cron        # should print "active"
```

---

## 4. Setup

### 4.1 Get the scripts and create the config (as `dietpi`)

```bash
cd ~ && git clone <this-repo-url> jafar-infra-
mkdir -p ~/.config/hermes-backup
cp ~/jafar-infra-/backup/config.example ~/.config/hermes-backup/config
chmod 600 ~/.config/hermes-backup/config
nano ~/.config/hermes-backup/config     # at least check RCLONE_REMOTE
```

The config is plain bash. It is refused if it is group/world writable or
owned by another user (it is executed). It contains **no secrets**.

### 4.2 Install rclone

Debian's package works but can be old:

```bash
sudo apt install -y rclone
rclone version
```

For a current release, use rclone's official installer (review it first):

```bash
curl -fsSLo /tmp/rclone-install.sh https://rclone.org/install.sh
less /tmp/rclone-install.sh
sudo bash /tmp/rclone-install.sh
```

### 4.3 Create the remote

Run `rclone config` **as `dietpi`** (the config is per-user, in
`~/.config/rclone/rclone.conf`; `rclone config file` prints the path).

1. **Base remote for your provider** — `n` (new remote), name it e.g.
   `offsite-raw`, pick the storage type (Google Drive, Dropbox, OneDrive,
   S3-compatible, B2, SFTP, …) and follow the prompts.
   *Headless server + browser-based OAuth (Drive, Dropbox, OneDrive):* answer
   **No** to "Use web browser to automatically authenticate?". rclone then
   tells you to run `rclone authorize "<type>"` on a machine that has a
   browser and rclone installed; paste the token it prints back into the
   server prompt.
2. **Encrypted wrapper (strongly recommended)** — `n` again, name it
   `hermes-offsite`, type `crypt`, remote = `offsite-raw:hermes-backups`,
   filename encryption `standard`, and let rclone generate strong passwords
   (password + salt).
   **Store both crypt passwords (and the provider login) in your password
   manager, off this server.** Without them the backups cannot be decrypted —
   and after an SSD failure the server's copy of `rclone.conf` is gone too.
3. Protect the rclone config:

   ```bash
   chmod 600 "$(rclone config file | tail -n1)"
   ```

Then in `~/.config/hermes-backup/config`:

```bash
RCLONE_REMOTE="jafar-encrypted:"            # crypt remote root (Jafar's server), or
# RCLONE_REMOTE="jafar-encrypted:nightly"   # a sub-folder inside it
```

**On Jafar's server** the provider remote is `gdrive:` and the crypt remote
wrapping it is `jafar-encrypted:`, used at its root. That is what
`config.example` (and therefore `install.sh`) sets. The steps above use
`offsite-raw`/`hermes-offsite` as generic example names.

Unencrypted is possible (`RCLONE_REMOTE="offsite-raw:hermes-backups"`) but
then your provider can read your conversation history.

What the scripts expect: `RCLONE_REMOTE` = `<remote-name>:<path>`,
resolved via rclone's default config file unless `RCLONE_CONFIG_FILE` is set.
An rclone config protected with a config password is **not** supported for
unattended runs.

Never commit `rclone.conf`; it is in `.gitignore`, but keep it out of the
repository directory altogether.

### 4.4 Test the remote

```bash
rclone lsd offsite-raw:                                # provider login works
rclone mkdir jafar-encrypted: && rclone lsf jafar-encrypted:
~/jafar-infra-/backup/backup-hermes.sh --check         # uses your config; exit 0 = OK
~/jafar-infra-/backup/backup-hermes.sh                 # first real backup
echo $?                                                # must be 0
```

### 4.5 Verify an archive really exists off-box

```bash
rclone lsl jafar-encrypted:                             # names, sizes, dates
~/jafar-infra-/backup/restore-hermes.sh --list-remote   # same, via the backend
# download the newest one, verify checksum + manifest + SQLite, change nothing:
~/jafar-infra-/backup/restore-hermes.sh --fetch latest --inspect
```

Also look at it from the provider's web UI once (with `crypt`, the file
names there are encrypted gibberish — that is expected).

Every backup run already does this automatically: it confirms the remote
object exists with the right size and, with `RCLONE_VERIFY=download` (the
default), streams it back and compares the SHA-256. Use `RCLONE_VERIFY=size`
if the archives grow large and bandwidth is metered.

### 4.6 Schedule it (cron, as `dietpi`)

```bash
bash ~/jafar-infra-/backup/install.sh --dry-run   # show what would change
bash ~/jafar-infra-/backup/install.sh             # config + cron (idempotent)
crontab -l
```

(`install.sh` calls `install-cron.sh --schedule "30 3 * * *"`; you can also
call `install-cron.sh --print` / `--schedule` directly.)

The exact entry installed (for the assumed paths):

```
30 3 * * * nice -n 10 /home/dietpi/jafar-infra-/backup/backup-hermes.sh >>/home/dietpi/.local/state/hermes-backup/logs/cron.log 2>&1 # hermes-backup:managed
```

- Runs daily at 03:30 **server clock time**, as `dietpi`, no sudo. Jafar's
  server clock is UTC, so that is 07:30 in Dubai.
  Change with `--schedule "M H DOM MON DOW"`; use `--config FILE` for a
  non-default config path.
- The installer refuses to run as root, saves your previous crontab to
  `~/.local/state/hermes-backup/crontab.before-<ts>`, and only replaces the
  line tagged `# hermes-backup:managed`.
- Manual alternative: `crontab -e` and paste the line above.
- **Overlap protection:** the script takes an exclusive `flock` on
  `~/.local/state/hermes-backup/backup.lock`; a second run exits `75`
  immediately.

**Disable / remove:**

```bash
bash ~/jafar-infra-/backup/uninstall.sh          # removes only the managed line
# or temporarily: crontab -e and put '#' in front of the line
```

### 4.7 Logs and status

| File (under `~/.local/state/hermes-backup/`) | Content |
|---|---|
| `logs/backup.log` | one timestamped line per step, incl. rclone's messages; rotated at 5 MiB (one `.1` kept) |
| `logs/cron.log` | anything the script printed outside its log (normally empty) |
| `logs/restore.log` | restore runs |
| `last-status` | `<time> OK|UPLOAD_FAILED|VERIFY_FAILED|FAILED|SKIPPED_LOCKED|… rc=N` |
| `last-success` | `<time> <archive name>` of the last fully verified backup |

All are mode 600 inside a 700 directory. Logs never contain secrets: config
has none, rclone runs without `-vv`/`--dump`, excluded credential files are
logged by path only. Quick health check:

```bash
cat ~/.local/state/hermes-backup/last-status ~/.local/state/hermes-backup/last-success
grep -E 'WARN|ERROR' ~/.local/state/hermes-backup/logs/backup.log | tail
```

---

## 5. Changing the backup destination later

Switching provider is configuration only:

1. `rclone config` → create the new remote (and a new `crypt` wrapper).
2. Edit `RCLONE_REMOTE` in `~/.config/hermes-backup/config`.
3. `backup-hermes.sh --check`, then run one backup and confirm exit 0.
4. Optional: bring history along — `rclone copy old-remote: new-remote: --progress`.
   (Copying between two crypt remotes decrypts and re-encrypts transparently.)

To use a different mechanism entirely, set `UPLOAD_BACKEND=localdir` +
`LOCALDIR_DEST=/mnt/nas/hermes-backups` (a *mounted remote* share; the
backend refuses a destination on the same filesystem as `~/.hermes`), or add
`lib/backend-<name>.sh` implementing:

| Function | Contract |
|---|---|
| `backend_preflight` | check config/tools, no network; `die 2` on problems |
| `backend_check` | check destination reachable/writable (`--check`) |
| `upload_backup ARCHIVE SIDECAR` | copy both off-box; non-zero on failure |
| `verify_remote_backup ARCHIVE SIDECAR` | prove the remote copy is intact; non-zero otherwise |
| `list_remote_backups PREFIX` | print archive names starting with PREFIX |
| `download_backup NAME DESTDIR` | fetch archive (+ sidecar) |
| `prune_remote_backups PREFIX KEEP` | delete all but newest KEEP (only called if `REMOTE_KEEP>0`) |

### Retention

- Local: newest `LOCAL_KEEP` (7 in `config.example`) archives in `LOCAL_BACKUP_DIR`,
  pruned only after a verified upload. Failed runs never prune.
- Remote: nothing is deleted unless `REMOTE_KEEP=N` is set (30 in
  `config.example`), which keeps the newest N archives **of this host**
  (strict name match, one file at a time).

---

## 6. Restore

`restore-hermes.sh` never deletes: anything it replaces is **moved** to
`<target>.pre-restore-<timestamp>/`. Before touching the target it verifies
the sidecar checksum, gzip stream, every entry name/type (no absolute paths,
`..`, device files, absolute symlinks or entries below symlinks), the per-file
SHA-256 manifest and SQLite `integrity_check`. Only items recorded in the
archive are touched; `.env`, tokens etc. in the target are left alone.

**Plan interface** (`hermes-restore.sh`, used by bootstrap #2 and update #4):

```bash
H=~/jafar-infra-/backup/hermes-restore.sh
$H latest --dry-run                      # newest off-box archive: show the plan
$H latest --force                        # restore it into ~/.hermes
$H ARCHIVE.tar.gz --target /tmp/x/.hermes   # somewhere else
```

- `latest` = newest archive on the remote (downloaded to
  `~/hermes-restore-downloads/`, or `--download-dir DIR`).
- Without `--force`, a restore that would replace existing items is refused
  (exit 6). With `--force` those items are **moved** to
  `~/.hermes.pre-restore-<ts>/` — per item, not the whole folder, so `.env`
  and login files already in `~/.hermes` stay in place.
- Into the live `~/.hermes` with `--force`, a running `hermes-gateway` is
  stopped first and started again afterwards, even if the restore fails.
- On a fresh machine with no `~/.config/hermes-backup/config`, the repo's
  `config.example` is used.

**Full options** (`restore-hermes.sh`):

```bash
R=~/jafar-infra-/backup/restore-hermes.sh
$R --inspect  ARCHIVE.tar.gz                    # validate + list contents
$R --dry-run  ARCHIVE.tar.gz                    # validate + show what would change
$R            ARCHIVE.tar.gz                    # restore into ~/.hermes (asks to confirm)
$R --target /tmp/hermes-test/.hermes ARCHIVE    # restore somewhere else
$R --only memories --only skills ARCHIVE        # partial restore
$R --fetch latest --dry-run                     # download newest from the remote
```

Confirmation: interactively you must type `restore`. Non-interactively the
restore proceeds only if nothing would be replaced, or with `--yes`. Into the
live home it refuses while Hermes processes are running (stop Hermes first,
or `--allow-running`). Run it as `dietpi`; if run as root it `chown`s the
restored items to `--owner` (default `dietpi`). Everything restored is made
private (`go-rwx`); the executable bits of skill scripts are kept.

### Disaster-recovery runbook (dead SSD → working Hermes)

`bootstrap/bootstrap.sh` (#2) automates these steps; see
`bootstrap/README.md`. The manual version:

1. Install DietPi/Debian on the new disk; make sure user `dietpi` exists.
2. `sudo apt install -y git sqlite3 cron procps rclone` (or rclone's installer).
3. Install Hermes Agent for `dietpi` following the official Hermes Agent
   install instructions. **Stop it** (CLI and gateway) before restoring.
4. `git clone` this repository to `~/jafar-infra-`; recreate
   `~/.config/hermes-backup/config` from `config.example`.
5. Recreate the rclone remotes (`rclone config`) using the provider login and
   crypt passwords from your password manager — they are not in the backup.
6. `restore-hermes.sh --list-remote`, then
   `restore-hermes.sh --fetch latest --dry-run` and read the plan.
7. `restore-hermes.sh ~/hermes-restore-downloads/<archive>.tar.gz` and type
   `restore`. Files the installer created (e.g. a default `config.yaml`,
   seeded skills) are moved to `~/.hermes.pre-restore-<ts>/`.
8. **Recreate what was intentionally not backed up:**
   - `~/.hermes/.env` — API keys and bot tokens (`chmod 600`), per profile too;
   - provider logins / OAuth (`auth.json`) — e.g. via `hermes setup` or the
     provider's login flow;
   - MCP OAuth — `hermes mcp login <server>`; Google Workspace re-auth;
   - messaging: WhatsApp QR re-pair, DM pairing approvals.
9. Start Hermes; check memories, skills, sessions and Hermes cron jobs.
10. `bash backup/install.sh`, then `bash backup/test.sh` (all PASS).
11. When satisfied, delete `~/.hermes.pre-restore-*` yourself.

If a restore is interrupted, the script prints which items were already
restored and where the previous versions are; roll back an item by moving
it back from the `.pre-restore-*` directory.

---

## 7. Security notes

- Secrets are excluded by design (allowlist + name excludes + pre-archive
  scan). Conversation data is **not** secret-free → encrypt off-box.
- `umask 077` throughout; staging dir, state dir and archives are 700/600.
- Scratch files live in `mktemp -d` directories inside private parents.
  The only recursive delete removes that scratch dir and refuses anything
  not matching its own prefix and parent.
- The config file is only sourced if owned by you/root and not
  group/world writable. Data read from archives (`BACKUP_INFO`, `ITEMS`)
  is parsed, never executed.
- No passwordless sudo; cron runs as `dietpi`.

---

## 8. Assumptions and open decisions

- **Hermes layout** follows the documented Hermes Agent structure
  (`config.yaml`, `.env`, `auth.json`, `SOUL.md`, `memories/`, `skills/`,
  `cron/`, `sessions/`, `state.db`, `logs/`, `profiles/`, `mcp-tokens/`,
  `pairing/`, …). Versions add things; the unknown-entry warning is there so
  you notice. Check `backup.log` after the first run.
- `state.db`, `kanban.db` and `shared-state.db` are restored in
  rollback-journal mode; Hermes/SQLite can switch them back to WAL on first
  open. Files under `sessions/` are copied as-is and may be a few seconds
  apart from `state.db` if Hermes is busy at 03:30.
- `kanban.db`/`shared-state.db` inclusion is based on Hermes's own published
  docs (Kanban and Bot Mode reference pages) describing them as durable,
  official-core state, not on inspection of a specific install's file
  contents. Only the default Kanban board is covered — see §2 for
  multi-board setups.
- `cron/output/` is included (can grow); exclude it with
  `EXTRA_EXCLUDE_PATTERNS=('output')` if you don't need job output history.
- Repo location `/home/dietpi/jafar-infra-` is an assumption; the scripts
  locate themselves, only the docs' example paths depend on it.
- No built-in alerting. Suggested later: a healthcheck ping after success or
  a daily check of `last-success` age.
- Archives are gzip (standard everywhere); no client-side encryption beyond
  rclone `crypt`.
