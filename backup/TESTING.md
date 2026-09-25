# Testing the Hermes backup

Two layers:

1. **Automated suite** — sandboxed, no real data, no real remote. Run it
   after every change to the scripts and once on the server itself.
2. **Manual procedure** — against your real Hermes home and real rclone
   remote, without risking the live installation. Do it once after setup,
   then periodically (e.g. quarterly). A backup you have never restored is
   a hope, not a backup.

All commands run as `dietpi`. `B=~/jafar-infra-/backup` below.

---

## A. Automated suite

```bash
B=~/jafar-infra-/backup
$B/tests/run-tests.sh                  # prints PASS/FAIL per check, exits non-zero on any FAIL
KEEP_SANDBOX=1 $B/tests/run-tests.sh   # keep the temp sandbox for inspection
shellcheck -x $B/*.sh $B/lib/*.sh $B/tests/*.sh   # static checks (apt install shellcheck)
```

It builds a fake Hermes home under `$TMPDIR` containing fake secrets with a
unique sentinel string (`.env`, `auth.json`, `mcp-tokens/`, `pairing/`,
`whatsapp/`, `google_token.json`, keys and `.env` files hidden inside
`skills/`, a second profile with its own `.env`, …) and a WAL-mode `state.db`.
It never touches `~/.hermes`, `~/.config/hermes-backup` or your remotes.

| Step | What the suite checks |
|---|---|
| 1 create | exit 0; archive + sidecar exist; modes 600/700; no scratch left; `last-status` OK; unknown top-level entry is warned about; sentinel never in logs |
| 2 inspect | every expected file is in the archive (incl. profile data); `--inspect` works |
| 3 secrets | none of ~30 secret/disposable paths are in the archive; **sentinel string appears in no archived file** |
| 4 integrity | `gzip -t`; sidecar `sha256sum -c`; internal manifest; `state.db` snapshot has the data and no `-wal` |
| 5–6 upload | localdir backend copy exists and matches; rclone (`:local:` on-the-fly remote): `--check`, upload, archive + sidecar on the remote, `--list-remote` |
| 7 download | `--fetch latest` downloads and validates; byte-identical to the original |
| 8 restore | `--dry-run` creates nothing; restore into a temp target; 700/`go-rwx`; correct owner; exec bits kept; no `.env` created |
| 9 compare | `diff -r` of every restored item vs. source (minus excluded names); SQLite `.dump` equality for both databases |
| 10 overwrite | refuses to replace existing data non-interactively without `--yes` (exit 6, nothing changed); with `--yes --only` replaces one item, old copy kept in `.pre-restore-*`; existing `.env` untouched |
| 11 validation | corrupted archive → exit 5 and nothing created; `--require-checksum` without sidecar → 5; path-traversal and absolute-symlink archives → 5 |
| 12 ops | concurrent run → 75; `--no-upload` → 3; world-writable config → 2; failed upload → 3 with `UPLOAD_FAILED`; local retention; missing config → 2 |

rclone tests are skipped (not failed) if rclone is not installed.

---

## B. Manual procedure against real data

Nothing here writes to `~/.hermes`. Scratch space: `T=$(mktemp -d ~/hb-test.XXXXXX)`.

### 1. Create a test backup

```bash
B=~/jafar-infra-/backup
T=$(mktemp -d ~/hb-test.XXXXXX)
$B/backup-hermes.sh --no-upload; echo "exit=$?"     # expect 3 (local only, by design)
A=$(ls -1 ~/hermes-backups/hermes-backup-*.tar.gz | tail -n1); echo "$A"
tail -n 30 ~/.local/state/hermes-backup/logs/backup.log   # read the WARN lines
```

### 2. Inspect its contents

```bash
$B/restore-hermes.sh --inspect "$A" | less
tar -tzf "$A" | less
```

Check the items list matches what you expect (config, SOUL.md, memories,
skills, cron, sessions, state.db, profiles).

### 3. Confirm excluded secrets are absent

```bash
tar -tzf "$A" | grep -E '(^|/)(\.env[^/]*|auth\.json|auth|mcp-tokens|pairing|whatsapp|google_token\.json|\.anthropic_oauth\.json|credentials(\.json)?|[^/]*\.(pem|key))(/|$)' \
  && echo "!!! SECRET-LIKE PATH FOUND" || echo "OK: no secret-like paths"

# Take a distinctive value from your real .env (e.g. the last 12 characters
# of one API key) and make sure it appears nowhere in the archive.
# `read -s` keeps it out of your shell history and the screen:
read -rs -p "fragment of a real secret: " FRAG; echo
mkdir "$T/x" && tar -C "$T/x" -xzf "$A"
grep -rqaF -- "$FRAG" "$T/x" && echo "!!! SECRET FOUND IN ARCHIVE" || echo "OK: not found"
unset FRAG
```

(If a secret you once pasted into a chat shows up in `state.db` or
`sessions/`, that is conversation data, not a leak of `.env` — it is why the
remote should be `crypt`-encrypted, and why you should rotate such keys.)

### 4. Validate archive integrity

```bash
gzip -t "$A" && echo "gzip OK"
(cd "$(dirname "$A")" && sha256sum -c "$(basename "$A").sha256")
(cd "$T/x/hermes-backup" && sha256sum -c --quiet --strict MANIFEST.sha256 && echo "manifest OK")
sqlite3 "$T/x/hermes-backup/home/state.db" 'PRAGMA integrity_check;'    # expect: ok
```

### 5. Upload it to the configured rclone remote

```bash
$B/backup-hermes.sh --check; echo "exit=$?"   # expect 0
$B/backup-hermes.sh; echo "exit=$?"           # full run: expect 0
cat ~/.local/state/hermes-backup/last-status  # expect "... OK rc=0"
```

### 6. Confirm it exists remotely

```bash
source ~/.config/hermes-backup/config
rclone lsl "$RCLONE_REMOTE"
$B/restore-hermes.sh --list-remote
```

The newest name must match `cat ~/.local/state/hermes-backup/last-success`.

### 7. Download a copy

```bash
$B/restore-hermes.sh --fetch latest --download-dir "$T/dl" --inspect
# or by hand:  rclone copy "$RCLONE_REMOTE" "$T/dl2" --include "$(awk '{print $2}' ~/.local/state/hermes-backup/last-success)*"
cmp "$T/dl/$(awk '{print $2}' ~/.local/state/hermes-backup/last-success)" \
    ~/hermes-backups/"$(awk '{print $2}' ~/.local/state/hermes-backup/last-success)" && echo "identical"
```

### 8. Restore into a temporary location

```bash
D="$T/dl/$(awk '{print $2}' ~/.local/state/hermes-backup/last-success)"
$B/restore-hermes.sh --dry-run --target "$T/restored/.hermes" "$D"
mkdir -p "$T/restored"
$B/restore-hermes.sh --target "$T/restored/.hermes" "$D"      # type: restore
```

A temp target is not the live home, so running Hermes processes only cause
a warning.

### 9. Compare restored data with the source

```bash
for i in config.yaml SOUL.md memories skills cron sessions hooks; do
  [ -e ~/.hermes/$i ] || continue
  diff -rq -x .env -x '.env.*' -x .hub -x __pycache__ ~/.hermes/$i "$T/restored/.hermes/$i" \
    && echo "same: $i"
done
sqlite3 ~/.hermes/state.db "select count(*) from sqlite_master;"
sqlite3 "$T/restored/.hermes/state.db" "select count(*) from sqlite_master;"
```

Differences in `sessions/` or `state.db` row counts are expected if Hermes
was used since the backup. `diff` also reports any file matching an exclude
pattern — confirm each is intentional.

### 10. Disaster-recovery drill without touching the live install

**Option A — same machine, isolated home (quick).** Hermes resolves its home
from `HERMES_HOME`, so you can point a Hermes command at the restored copy:

```bash
HERMES_HOME="$T/restored/.hermes" hermes config show     # restored config visible?
HERMES_HOME="$T/restored/.hermes" hermes status
```

Do **not** start the gateway against the restored copy while the live one
runs (two bots on the same accounts). There is no `.env` in the copy, so no
API calls or platform logins happen unless you add one.

**Option B — full rehearsal (recommended once).** Use a spare SD card/SSD,
another Pi, or a Debian VM (`dietpi` user, no access to your live keys):
follow the runbook in README §6 end-to-end with `--fetch latest`, including
reinstalling Hermes, creating a *test* `.env` and starting Hermes. Time it,
and note anything you had to look up — that is what your password manager is
missing.

### Clean up

```bash
rm -r -- "$T"      # only the scratch dir you created in step 1
```

The `--no-upload` archive from step 1 stays in `~/hermes-backups/` and is
pruned by normal retention.
