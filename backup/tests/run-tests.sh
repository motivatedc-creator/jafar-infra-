#!/usr/bin/env bash
# Automated end-to-end tests for backup-hermes.sh / restore-hermes.sh.
#
# Fully sandboxed: builds a FAKE Hermes home (with fake secrets) in a temp
# directory and never reads or writes ~/.hermes, ~/.config/hermes-backup or
# your real rclone remote. Safe to run on the live server.
#
#   backup/tests/run-tests.sh            # run everything
#   KEEP_SANDBOX=1 backup/tests/run-tests.sh   # keep temp files for inspection
#
# rclone-specific tests use an rclone on-the-fly local remote (":local:...")
# and are skipped if rclone is not installed.

set -Euo pipefail
umask 077
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BK="$(dirname -- "$TESTS_DIR")"
BACKUP="${BK}/backup-hermes.sh"
RESTORE="${BK}/restore-hermes.sh"
ME="$(id -un)"
SENTINEL="HB_TEST_SECRET_SENTINEL_$$"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/hermes-backup-test.XXXXXXXX")
cleanup() {
    if [[ "${KEEP_SANDBOX:-0}" == 1 ]]; then
        echo "Sandbox kept at ${SANDBOX}"
    elif [[ -d "$SANDBOX" && "$(basename -- "$SANDBOX")" == hermes-backup-test.* ]]; then
        rm -rf --one-file-system -- "$SANDBOX"
    fi
}
trap cleanup EXIT

PASS=0 FAIL=0 SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n== %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
db_dump() {
    if have sqlite3; then sqlite3 "$1" .dump
    else python3 -c 'import sqlite3,sys; [print(l) for l in sqlite3.connect(sys.argv[1]).iterdump()]' "$1"; fi
}
db_exec() {
    if have sqlite3; then sqlite3 "$1" "$2" >/dev/null
    else python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit()' "$1" "$2"; fi
}

# --------------------------------------------------------------------------
# Fake Hermes home
# --------------------------------------------------------------------------
H="${SANDBOX}/home/.hermes"
mkdir -p "$H"/{memories,skills/demo/scripts,skills/.hub,skills/demo/__pycache__,cron/output,sessions,hooks} \
         "$H"/{logs,cache,image_cache,mcp-tokens,pairing,whatsapp/session,hermes-agent,node,bin,auth} \
         "$H"/profiles/work/{memories,skills,sessions} "$H"/mystery-dir \
         "$H"/kanban/workspaces/w1 "$H"/kanban/boards/other
printf 'model:\n  default: some/model\n' >"$H/config.yaml"
printf '# Soul\nBe helpful.\n' >"$H/SOUL.md"
printf 'env note\n' >"$H/memories/MEMORY.md"
printf 'user likes tea\n' >"$H/memories/USER.md"
printf -- '---\nname: demo\n---\nDemo skill\n' >"$H/skills/demo/SKILL.md"
printf '#!/bin/sh\necho hi\n' >"$H/skills/demo/scripts/run.sh"; chmod 755 "$H/skills/demo/scripts/run.sh"
printf 'cache\n' >"$H/skills/.hub/index.json"
printf 'bytecode\n' >"$H/skills/demo/__pycache__/x.pyc"
printf '{"jobs": []}\n' >"$H/cron/jobs.json"
printf 'run output\n' >"$H/cron/output/run1.md"
printf '{"id": "s1"}\n' >"$H/sessions/session_s1.json"
printf 'echo hook\n' >"$H/hooks/on_start.sh"
printf 'log line\n' >"$H/logs/agent.log"
printf 'work config\n' >"$H/profiles/work/config.yaml"
printf 'work memory\n' >"$H/profiles/work/memories/MEMORY.md"
printf 'work session\n' >"$H/profiles/work/sessions/s.json"
printf 'mystery\n' >"$H/mystery-dir/file"
printf 'scratch worker output\n' >"$H/kanban/workspaces/w1/scratch.txt"
# Fake secrets, everywhere they could plausibly appear:
for f in .env auth.json .anthropic_oauth.json google_token.json mcp-tokens/linear.json \
         pairing/telegram-approved.json whatsapp/session/creds.json auth/google_oauth.json \
         skills/demo/.env skills/demo/credentials.json skills/demo/server.pem \
         skills/demo/scripts/id_ed25519 profiles/work/.env profiles/work/auth.json \
         sessions/.env.local; do
    printf 'KEY=%s\n' "$SENTINEL" >"$H/$f"
done
db_exec "$H/state.db" "PRAGMA journal_mode=WAL; CREATE TABLE sessions(id TEXT, title TEXT); CREATE TABLE messages(sid TEXT, body TEXT); INSERT INTO sessions VALUES('s1','hello'); INSERT INTO messages VALUES('s1','hi there');"
db_exec "$H/profiles/work/state.db" "CREATE TABLE t(x); INSERT INTO t VALUES(42);"
db_exec "$H/kanban.db" "PRAGMA journal_mode=WAL; CREATE TABLE tasks(id TEXT, title TEXT); INSERT INTO tasks VALUES('t1','write the docs');"
db_exec "$H/shared-state.db" "CREATE TABLE hosted_rooms(id TEXT, name TEXT); INSERT INTO hosted_rooms VALUES('r1','ops-room');"
db_exec "$H/kanban/boards/other/kanban.db" "CREATE TABLE tasks(id TEXT); INSERT INTO tasks VALUES('other-board-task');"

mkcfg() {  # mkcfg FILE BACKEND [extra lines...]
    local f="$1" backend="$2"; shift 2
    {
        echo "HERMES_USER=${ME}"
        echo "HERMES_HOME=${H}"
        echo "LOCAL_BACKUP_DIR=${SANDBOX}/staging"
        echo "STATE_DIR=${SANDBOX}/state"
        echo "UPLOAD_BACKEND=${backend}"
        echo "LOCALDIR_DEST=${SANDBOX}/offbox"
        echo "LOCALDIR_ALLOW_SAME_FS=yes"
        echo "RCLONE_REMOTE=:local:${SANDBOX}/rclone-remote"
        echo "LOCAL_KEEP=2"
        printf '%s\n' "$@"
    } >"$f"
    chmod 600 "$f"
}
mkdir -p "${SANDBOX}/offbox"
CFG="${SANDBOX}/config"
mkcfg "$CFG" localdir
export HERMES_BACKUP_CONFIG="$CFG"
LOG="${SANDBOX}/state/logs/backup.log"

latest_archive() { find "${SANDBOX}/staging" -maxdepth 1 -name 'hermes-backup-*.tar.gz' | sort | tail -n1; }

# --------------------------------------------------------------------------
section "1. Create a test backup"
"$BACKUP" >/dev/null 2>&1; rc=$?
check "backup exits 0 (localdir backend)" test "$rc" -eq 0
A=$(latest_archive)
if [[ -z "$A" ]]; then
    echo "First backup failed; log tail:"; tail -n 30 "$LOG"
    exit 1
fi
check "archive exists in staging" test -f "$A"
check "checksum sidecar exists" test -f "${A}.sha256"
check "archive mode is 600" test "$(stat -c %a "$A")" = 600
check "staging dir mode is 700" test "$(stat -c %a "${SANDBOX}/staging")" = 700
check "no scratch dirs left behind" test -z "$(find "${SANDBOX}/staging" -name '.hb-work.*')"
check "last-status is OK" grep -q ' OK ' "${SANDBOX}/state/last-status"
check "log warns about unknown top-level entry" grep -q 'unknown entry.*mystery-dir' "$LOG"
check "log does not warn about kanban/ (known-excluded, not an unknown entry)" bash -c "! grep -qF -- '): kanban -' \"\$1\"" _ "$LOG"
check "log does not contain the secret sentinel" bash -c "! grep -rq '$SENTINEL' '${SANDBOX}/state'"

# --------------------------------------------------------------------------
section "2. Inspect contents"
LIST=$(tar -tzf "$A")
for p in config.yaml SOUL.md memories/MEMORY.md memories/USER.md skills/demo/SKILL.md \
         skills/demo/scripts/run.sh cron/jobs.json cron/output/run1.md sessions/session_s1.json \
         hooks/on_start.sh state.db profiles/work/config.yaml profiles/work/memories/MEMORY.md \
         profiles/work/state.db kanban.db shared-state.db; do
    check "archive contains ${p}" grep -Fxq "hermes-backup/home/${p}" <<<"$LIST"
done
"$RESTORE" --inspect "$A" >"${SANDBOX}/inspect.out" 2>&1
check "restore --inspect succeeds" test $? -eq 0
check "--inspect lists state.db" grep -q 'state.db' "${SANDBOX}/inspect.out"
check "--inspect lists kanban.db" grep -q 'kanban.db' "${SANDBOX}/inspect.out"
check "--inspect lists shared-state.db" grep -q 'shared-state.db' "${SANDBOX}/inspect.out"

# --------------------------------------------------------------------------
section "3. Excluded secrets and disposable data are absent"
for p in .env auth.json .anthropic_oauth.json google_token.json mcp-tokens pairing whatsapp auth/ \
         logs/ cache/ image_cache/ hermes-agent/ node/ bin/ skills/.hub __pycache__ \
         skills/demo/.env credentials.json server.pem id_ed25519 profiles/work/.env \
         profiles/work/auth.json .env.local state.db-wal state.db-shm mystery-dir \
         kanban/workspaces kanban/boards; do
    check "archive has no '${p}'" bash -c "! grep -Fq -- '/${p}' <<<\"\$1\"" _ "$LIST"
done
X="${SANDBOX}/extract"; mkdir -p "$X"; tar -C "$X" -xzf "$A"
check "no file in the archive contains the secret sentinel" bash -c "! grep -rqa '$SENTINEL' '$X'"

# --------------------------------------------------------------------------
section "4. Archive integrity"
check "gzip -t passes" gzip -t "$A"
check "sidecar sha256sum -c passes" bash -c "cd '$(dirname "$A")' && sha256sum -c --quiet '$(basename "$A").sha256'"
check "internal manifest verifies" bash -c "cd '$X/hermes-backup' && sha256sum -c --quiet --strict MANIFEST.sha256"
if have sqlite3 || have python3; then
    check "snapshot state.db has the data" grep -q 'hi there' <(db_dump "$X/hermes-backup/home/state.db")
    check "snapshot state.db is self-contained (no -wal in archive)" bash -c "! grep -q 'state.db-wal' <<<\"\$1\"" _ "$LIST"
    check "snapshot kanban.db has the data" grep -q 'write the docs' <(db_dump "$X/hermes-backup/home/kanban.db")
    check "snapshot shared-state.db has the data" grep -q 'ops-room' <(db_dump "$X/hermes-backup/home/shared-state.db")
fi

# --------------------------------------------------------------------------
section "5+6. Off-box copy exists and matches (localdir backend)"
N=$(basename "$A")
check "off-box copy exists" test -f "${SANDBOX}/offbox/${N}"
check "off-box copy hash matches" cmp -s "$A" "${SANDBOX}/offbox/${N}"

section "5+6+7. rclone backend (on-the-fly :local: remote)"
if have rclone; then
    RCFG="${SANDBOX}/config-rclone"; mkcfg "$RCFG" rclone "RCLONE_VERIFY=download"
    "$BACKUP" --config "$RCFG" --check >/dev/null 2>&1
    check "backup --check reaches the remote" test $? -eq 0
    sleep 1
    "$BACKUP" --config "$RCFG" >/dev/null 2>&1
    check "backup via rclone exits 0" test $? -eq 0
    RA=$(latest_archive); RN=$(basename "$RA")
    check "rclone remote has the archive" test -f "${SANDBOX}/rclone-remote/${RN}"
    check "rclone remote has the sidecar" test -f "${SANDBOX}/rclone-remote/${RN}.sha256"
    check "restore --list-remote shows it" bash -c "'$RESTORE' --config '$RCFG' --list-remote 2>/dev/null | grep -Fxq '$RN'"
    "$RESTORE" --config "$RCFG" --fetch latest --download-dir "${SANDBOX}/dl" --inspect >/dev/null 2>&1
    check "restore --fetch latest downloads and validates" test $? -eq 0
    check "downloaded copy is byte-identical" cmp -s "$RA" "${SANDBOX}/dl/${RN}"

    BADCFG="${SANDBOX}/config-badremote"; touch "${SANDBOX}/not-a-dir"
    mkcfg "$BADCFG" rclone "RCLONE_REMOTE=:local:${SANDBOX}/not-a-dir/sub"
    sleep 1
    "$BACKUP" --config "$BADCFG" >/dev/null 2>&1; rc=$?
    check "failed upload exits 3 (never silent success)" test "$rc" -eq 3
    check "last-status records UPLOAD_FAILED" grep -q 'UPLOAD_FAILED' "${SANDBOX}/state/last-status"
else
    skip "rclone not installed"
fi

# --------------------------------------------------------------------------
section "7. Download a copy (simulated: copy from off-box dir)"
DL="${SANDBOX}/downloaded"; mkdir -p "$DL"
cp "${SANDBOX}/offbox/${N}" "${SANDBOX}/offbox/${N}.sha256" "$DL/"
check "downloaded copy passes sidecar check" bash -c "cd '$DL' && sha256sum -c --quiet '${N}.sha256'"

# --------------------------------------------------------------------------
section "8. Restore into a temporary location"
T="${SANDBOX}/restore-target/.hermes"; mkdir -p "$(dirname "$T")"
"$RESTORE" --dry-run --target "$T" --owner "$ME" "$DL/$N" >/dev/null 2>&1
check "--dry-run succeeds" test $? -eq 0
check "--dry-run created nothing" test ! -e "$T"
"$RESTORE" --target "$T" --owner "$ME" "$DL/$N" </dev/null >"${SANDBOX}/restore.out" 2>&1
check "restore into empty target succeeds" test $? -eq 0
check "restored home is mode 700" test "$(stat -c %a "$T")" = 700
check "restored files are not group/world readable" test -z "$(find "$T" -perm /077 ! -type l)"
check "restored files owned by ${ME}" test -z "$(find "$T" ! -user "$ME")"
check "executable bit kept on skill script" test -x "$T/skills/demo/scripts/run.sh"
check "restore did not create .env" test ! -e "$T/.env"

# --------------------------------------------------------------------------
section "9. Compare restored data with the source"
EXCL=(-x .env -x '.env.*' -x .hub -x __pycache__ -x credentials.json -x server.pem -x id_ed25519 -x auth.json -x 'state.db*')
for it in config.yaml SOUL.md memories skills cron sessions hooks profiles/work/config.yaml profiles/work/memories profiles/work/sessions; do
    check "identical: ${it}" diff -r "${EXCL[@]}" "$H/$it" "$T/$it"
done
check "identical data: state.db" cmp -s <(db_dump "$H/state.db") <(db_dump "$T/state.db")
check "identical data: profiles/work/state.db" cmp -s <(db_dump "$H/profiles/work/state.db") <(db_dump "$T/profiles/work/state.db")
check "identical data: kanban.db" cmp -s <(db_dump "$H/kanban.db") <(db_dump "$T/kanban.db")
check "identical data: shared-state.db" cmp -s <(db_dump "$H/shared-state.db") <(db_dump "$T/shared-state.db")
check "restore did not create kanban/ (workspaces/boards are not covered by this backup)" test ! -e "$T/kanban"

# --------------------------------------------------------------------------
section "10. Overwrite protection"
printf 'CHANGED\n' >"$T/SOUL.md"; printf 'MY_REAL_KEY=x\n' >"$T/.env"
"$RESTORE" --target "$T" --owner "$ME" "$DL/$N" </dev/null >/dev/null 2>&1; rc=$?
check "non-interactive restore over existing data refuses without --yes (exit 6)" test "$rc" -eq 6
check "refused restore changed nothing" grep -q CHANGED "$T/SOUL.md"
"$RESTORE" --target "$T" --owner "$ME" --yes --only SOUL.md "$DL/$N" </dev/null >/dev/null 2>&1
check "--yes --only SOUL.md succeeds" test $? -eq 0
check "SOUL.md restored" cmp -s "$H/SOUL.md" "$T/SOUL.md"
SAFE=$(find "$(dirname "$T")" -maxdepth 1 -name '.hermes.pre-restore-*' | head -n1)
check "previous SOUL.md kept in pre-restore dir" grep -q CHANGED "${SAFE}/SOUL.md"
check "existing .env left untouched" grep -q MY_REAL_KEY "$T/.env"

# --------------------------------------------------------------------------
section "11. Validation failures are fatal and change nothing"
C="${SANDBOX}/corrupt"; mkdir -p "$C"; cp "$DL/$N" "$C/$N"
printf '\x00\x00\x00\x00' | dd of="$C/$N" bs=1 seek=200 conv=notrunc status=none
T2="${SANDBOX}/t2/.hermes"; mkdir -p "$(dirname "$T2")"
"$RESTORE" --target "$T2" --owner "$ME" --yes "$C/$N" >/dev/null 2>&1; rc=$?
check "corrupted archive is rejected (exit 5)" test "$rc" -eq 5
check "rejected restore created nothing" test ! -e "$T2"
cp "$DL/$N" "$C/nosidecar.tar.gz"
"$RESTORE" --inspect --require-checksum "$C/nosidecar.tar.gz" >/dev/null 2>&1
check "--require-checksum fails without sidecar" test $? -eq 5
if have python3; then
    python3 - "$C/evil.tar.gz" "$C/abslink.tar.gz" <<'PY'
import io, sys, tarfile
def add(t, name, data=b"x"):
    ti = tarfile.TarInfo(name); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
with tarfile.open(sys.argv[1], "w:gz") as t:
    for n in ("hermes-backup/BACKUP_INFO", "hermes-backup/ITEMS", "hermes-backup/MANIFEST.sha256"):
        add(t, n)
    add(t, "hermes-backup/home/../../escaped")
with tarfile.open(sys.argv[2], "w:gz") as t:
    for n in ("hermes-backup/BACKUP_INFO", "hermes-backup/ITEMS", "hermes-backup/MANIFEST.sha256"):
        add(t, n)
    ti = tarfile.TarInfo("hermes-backup/home/link"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc"
    t.addfile(ti)
PY
    "$RESTORE" --inspect "$C/evil.tar.gz" >/dev/null 2>&1
    check "path-traversal archive rejected" test $? -eq 5
    "$RESTORE" --inspect "$C/abslink.tar.gz" >/dev/null 2>&1
    check "absolute-symlink archive rejected" test $? -eq 5
    check "nothing escaped the scratch dir" test ! -e "${SANDBOX}/escaped"
fi

# --------------------------------------------------------------------------
section "12. Operational safety"
exec 8>"${SANDBOX}/state/backup.lock"; flock -n 8
"$BACKUP" >/dev/null 2>&1; rc=$?
exec 8>&-
check "overlapping run is refused (exit 75)" test "$rc" -eq 75
"$BACKUP" --no-upload >/dev/null 2>&1
check "--no-upload exits 3 (local-only is not success)" test $? -eq 3
WW="${SANDBOX}/config-ww"; cp "$CFG" "$WW"; chmod 666 "$WW"
"$BACKUP" --config "$WW" >/dev/null 2>&1
check "world-writable config is refused (exit 2)" test $? -eq 2
sleep 1; "$BACKUP" >/dev/null 2>&1; sleep 1; "$BACKUP" >/dev/null 2>&1
check "local retention keeps LOCAL_KEEP=2 archives" test "$(find "${SANDBOX}/staging" -maxdepth 1 -name '*.tar.gz' | wc -l)" -eq 2

section "12. Remote pruning rejects invalid names"
PRUNE_DIR="${SANDBOX}/prune-remote"; mkdir -p "$PRUNE_DIR"
for f in hermes-backup-host-20240101T000000Z.tar.gz hermes-backup-host-20240102T000000Z.tar.gz hermes-backup-host-20240103T000000Z.tar.gz; do
    : >"${PRUNE_DIR}/${f}"
done
: >"${PRUNE_DIR}/hermes-backup-host-invalid.tar.gz"
remote_prune_test() {
    (
        LOCALDIR_DEST="$1"
        # shellcheck disable=SC1091  # runtime path resolves from the suite's discovered repository root.
        source "${BK}/lib/common.sh"
        # shellcheck disable=SC1091  # runtime path resolves from the suite's discovered repository root.
        source "${BK}/lib/backend-localdir.sh"
        prune_remote_backups hermes-backup-host- 1 &&
            test ! -e "$LOCALDIR_DEST/hermes-backup-host-20240101T000000Z.tar.gz" &&
            test ! -e "$LOCALDIR_DEST/hermes-backup-host-20240102T000000Z.tar.gz" &&
            test -e "$LOCALDIR_DEST/hermes-backup-host-20240103T000000Z.tar.gz" &&
            test -e "$LOCALDIR_DEST/hermes-backup-host-invalid.tar.gz"
    )
}
check "remote pruning removes old valid archive but keeps newest and invalid names" remote_prune_test "$PRUNE_DIR"
"$BACKUP" --config /nonexistent/config >/dev/null 2>&1
check "missing explicit config exits 2" test $? -eq 2

# --------------------------------------------------------------------------
section "13. restore-hermes.sh required-entry check is pipefail-safe on a large archive"
# Regression test for: `printf '%s\n' "${NAMES[@]}" | grep -Fxq -- "$req"` in
# restore-hermes.sh. With `set -o pipefail`, grep -q can exit (successfully,
# having found the match) before printf finishes writing a NAMES list bigger
# than a pipe buffer, killing printf with SIGPIPE; the pipeline then reports
# that nonzero status and restore-hermes.sh reports a false "missing
# hermes-backup/BACKUP_INFO" validation failure even though the archive is
# valid. A real Hermes install's sessions/skills easily produce enough tar
# entries to hit this. Reproduced directly against restore-hermes.sh (not a
# hand-built archive) using a fake home with 6000 session files, which
# reliably overflows the pipe buffer before grep reaches the required names
# (BACKUP_INFO/ITEMS/MANIFEST.sha256 sort before "home/..." in the listing).
LARGE_H="${SANDBOX}/home-large/.hermes"
mkdir -p "${LARGE_H}/sessions"
printf 'model:\n  default: some/model\n' >"${LARGE_H}/config.yaml"
printf '# Soul\n' >"${LARGE_H}/SOUL.md"
for i in $(seq -w 1 6000); do
    printf '{"id":"session_%s"}\n' "$i" >"${LARGE_H}/sessions/session_${i}.json"
done
LARGE_STAGING="${SANDBOX}/staging-large"; mkdir -p "$LARGE_STAGING"
LARGE_CFG="${SANDBOX}/config-large"
mkcfg "$LARGE_CFG" localdir "HERMES_HOME=${LARGE_H}" "LOCAL_BACKUP_DIR=${LARGE_STAGING}" \
    "STATE_DIR=${SANDBOX}/state-large" "LOCAL_KEEP=1"
"$BACKUP" --config "$LARGE_CFG" >/dev/null 2>&1
check "backup of the large fake home exits 0" test $? -eq 0
LARGE_A=$(find "$LARGE_STAGING" -maxdepth 1 -name 'hermes-backup-*.tar.gz' | sort | tail -n1)
check "large archive exists" test -f "$LARGE_A"
check "large archive has enough entries to exceed a pipe buffer (>6000)" \
    bash -c "test \"\$(tar -tzf \"\$1\" | wc -l)\" -gt 6000" _ "$LARGE_A"
"$RESTORE" --inspect "$LARGE_A" >"${SANDBOX}/inspect-large.out" 2>&1
check "restore --inspect on the large archive exits 0 (would be 5 under the pipefail bug)" test $? -eq 0
check "large-archive inspect reports no false 'missing hermes-backup/...' failure" \
    bash -c "! grep -q 'missing hermes-backup/' \"\$1\"" _ "${SANDBOX}/inspect-large.out"

# --------------------------------------------------------------------------
printf '\nResult: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
