#!/usr/bin/env bash
# Offline tests for bootstrap/bootstrap.sh. Safe anywhere, including the
# live server: every system command bootstrap.sh uses (sudo, apt-get,
# dpkg-query, systemctl, loginctl, curl, rclone, id, the Tailscale and
# Hermes installers, the hermes CLI) is replaced by a stub that only writes
# into a temporary sandbox, and bootstrap.sh runs from a fake repo copy
# against a fake home.
#
#   bash bootstrap/tests/run-tests.sh
#   KEEP_SANDBOX=1 bash bootstrap/tests/run-tests.sh

set -Euo pipefail
umask 077
export LC_ALL=C

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BOOT="$(dirname -- "$TESTS_DIR")"
REAL_REPO="$(dirname -- "$BOOT")"

SB=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXXXX")
cleanup() {
    if [[ "${KEEP_SANDBOX:-0}" == 1 ]]; then echo "Sandbox kept at ${SB}"
    elif [[ -d "$SB" && "$(basename -- "$SB")" == bootstrap-test.* ]]; then rm -rf --one-file-system -- "$SB"; fi
}
trap cleanup EXIT

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n== %s\n' "$1"; }
has() { grep -qF -- "$2" <<<"$1"; }          # has "$output" "text"
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
step_line() { grep -E "^\[ ?$2/10\]" <<<"$1" | sed -n 1p; }

# --------------------------------------------------------------------------
# Fake repo: the real bootstrap/ and docs/, stub backup/ and item folders.
# --------------------------------------------------------------------------
REPO="${SB}/repo"
mkdir -p "$REPO"/{bootstrap/tests,docs,backup,watchdog,guard,skills/b,skills/a}
cp "$BOOT"/{bootstrap.sh,packages.txt,install.sh,uninstall.sh,test.sh} "$REPO/bootstrap/"
cp "$REAL_REPO/docs/hermes-facts.md" "$REPO/docs/"
cp "$REAL_REPO/backup/config.example" "$REPO/backup/"
BS="$REPO/bootstrap/bootstrap.sh"

ST="${SB}/state"; mkdir -p "$ST/run"   # everything the stubs record lives here
cat >"$REPO/backup/hermes-restore.sh" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/restore.log"
SH
item_stub() {  # item_stub <path> <name>: a conforming install.sh with --dry-run
    cat >"$1" <<SH
#!/bin/sh
m="\$FAKE_STATE/item-$2.installed"
if [ "\${1:-}" = --dry-run ]; then
    if [ -f "\$m" ]; then echo "$2: already done"; else echo "$2: would run"; fi
    exit 0
fi
echo "$2" >>"\$FAKE_STATE/items.log"; : >"\$m"
SH
}
item_stub "$REPO/backup/install.sh" backup
item_stub "$REPO/watchdog/install.sh" watchdog
item_stub "$REPO/guard/install.sh" guard
item_stub "$REPO/skills/a/install.sh" skills-a
item_stub "$REPO/skills/b/install.sh" skills-b

# --------------------------------------------------------------------------
# Stub commands
# --------------------------------------------------------------------------
BIN="${SB}/bin"; mkdir -p "$BIN"
mksock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
export -f mksock 2>/dev/null || true
cat >"$BIN/id" <<'SH'
#!/bin/sh
case "$*" in
    -u) echo "${FAKE_UID:-1000}" ;;
    -un) echo dietpi ;;
    *) exec /usr/bin/id "$@" ;;
esac
SH
cat >"$BIN/dpkg-query" <<'SH'
#!/bin/sh
for p; do :; done   # last argument = package name
if grep -qx "$p" "$FAKE_STATE/installed" 2>/dev/null; then printf 'install ok installed'; else exit 1; fi
SH
cat >"$BIN/sudo" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/sudo.log"
exec "$@"
SH
cat >"$BIN/apt-get" <<'SH'
#!/bin/sh
[ "$1" = install ] || exit 0
shift; [ "$1" = -y ] && shift
for p; do echo "$p" >>"$FAKE_STATE/installed"; done
SH
cat >"$BIN/systemctl" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/systemctl.log"
S="$FAKE_STATE"
case "$*" in
    "--user"*)
        [ -n "$XDG_RUNTIME_DIR" ] && [ -n "$DBUS_SESSION_BUS_ADDRESS" ] \
            || echo "$*" >>"$FAKE_STATE/systemctl-no-dbus-env.log" ;;
esac
case "$*" in
    "is-enabled systemd-logind") cat "$S/logind.enabled" ;;
    "is-active systemd-logind") a=$(cat "$S/logind.active"); echo "$a"; [ "$a" = active ] ;;
    "unmask systemd-logind") echo static >"$S/logind.enabled" ;;
    "start systemd-logind") echo active >"$S/logind.active" ;;
    "enable systemd-logind") : ;;
    "start user@"*) python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$BOOTSTRAP_USER_BUS" ;;
    "--user is-active --quiet hermes-gateway") [ -f "$S/gateway.active" ] ;;
    *) echo "stub systemctl: unexpected: $*" >&2; exit 1 ;;
esac
SH
cat >"$BIN/loginctl" <<'SH'
#!/bin/sh
case "$1" in
    show-user) echo "Linger=$(cat "$FAKE_STATE/linger")" ;;
    enable-linger) echo yes >"$FAKE_STATE/linger"
        [ -e "$BOOTSTRAP_USER_BUS" ] || python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$BOOTSTRAP_USER_BUS" ;;
    *) exit 1 ;;
esac
SH
cat >"$BIN/curl" <<'SH'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; --proto|--tlsv1.2) [ "$1" = --proto ] && shift; shift ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >>"$FAKE_STATE/curl.log"
case "$url" in
    https://tailscale.com/install.sh) cat >"$out" <<'EOF'
printf '#!/bin/sh\n[ "$1" = status ] && exit 1\nexit 0\n' >"$FAKE_BIN/tailscale"; chmod 755 "$FAKE_BIN/tailscale"
EOF
    ;;
    https://hermes-agent.nousresearch.com/install.sh) cat >"$out" <<'EOF'
echo "$*" >>"$FAKE_STATE/hermes-installer.args"
mkdir -p "$HOME/.local/bin" "$HOME/.hermes/hermes-agent"
cp "$FAKE_STATE/hermes.stub" "$HOME/.local/bin/hermes"; chmod 755 "$HOME/.local/bin/hermes"
EOF
    ;;
    *) exit 22 ;;
esac
SH
cat >"$ST/hermes.stub" <<'SH'
#!/bin/sh
echo "$*" >>"$FAKE_STATE/hermes.log"
case "$*" in
    --version) echo "Hermes Agent v0-test" ;;
    "gateway install") mkdir -p "$HOME/.config/systemd/user"; : >"$HOME/.config/systemd/user/hermes-gateway.service" ;;
    "gateway start") : >"$FAKE_STATE/gateway.active" ;;
    "config check") echo "config ok" ;;
esac
SH
cat >"$BIN/rclone" <<'SH'
#!/bin/sh
[ "$1" = listremotes ] && cat "$FAKE_STATE/remotes" 2>/dev/null
exit 0
SH
chmod 755 "$BIN"/* "$REPO"/backup/*.sh "$REPO"/*/install.sh "$REPO"/skills/*/install.sh "$REPO"/bootstrap/*.sh

HOMEDIR="${SB}/home"
fresh_box() {  # reset to a freshly flashed DietPi
    rm -rf "$HOMEDIR" "$ST"/*.log "$ST"/*.installed "$ST/installed" "$ST/gateway.active" \
           "$ST/remotes" "$ST/hermes-installer.args" "$ST/run" "$BIN/tailscale"
    mkdir -p "$HOMEDIR" "$ST/run"
    printf '%s\n' git curl dbus >"$ST/installed"   # a few already present
    echo masked >"$ST/logind.enabled"; echo inactive >"$ST/logind.active"
    echo no >"$ST/linger"
}
bs() {  # run bootstrap.sh in the sandbox; sets OUT and RC
    OUT=$(env HOME="$HOMEDIR" PATH="${BIN}:${PATH}" FAKE_STATE="$ST" FAKE_BIN="$BIN" \
          BOOTSTRAP_USER_BUS="$ST/run/bus" FAKE_UID="${FAKE_UID:-1000}" \
          bash "$BS" "$@" </dev/null 2>&1)
    RC=$?
}
# Everything a run could change. hermes --version is read-only, so it is left out.
snapshot() { (cd "$ST" && for f in sudo.log curl.log restore.log items.log hermes.log installed; do
    printf '== %s\n' "$f"; grep -vx -- '--version' "$f" 2>/dev/null; done) }

# --------------------------------------------------------------------------
section "1. Fresh box, --dry-run: reports every step, changes nothing"
fresh_box
bs --dry-run
check "dry-run exits 1 (final checks cannot pass on a fresh box)" test "$RC" -eq 1
check "announces a dry run" has "$OUT" "DRY RUN, nothing will be changed"
check "step 1 would install only the missing packages" has "$(step_line "$OUT" 1)" "would run: sudo apt-get update && sudo apt-get install -y jq sqlite3 shellcheck rclone age xz-utils libatomic1 dbus-user-session libpam-systemd"
check "step 2 would unmask and start logind" has "$(step_line "$OUT" 2)" "would run: sudo systemctl unmask systemd-logind; sudo systemctl start systemd-logind"
check "step 3 would enable linger" has "$(step_line "$OUT" 3)" "would run: sudo loginctl enable-linger dietpi"
check "step 4 would run the Tailscale installer" has "$(step_line "$OUT" 4)" "would run: official Tailscale installer (https://tailscale.com/install.sh)"
check "step 4 names the manual 'sudo tailscale up'" has "$OUT" "sudo tailscale up"
check "step 5 uses the V11 URL from docs/hermes-facts.md" has "$(step_line "$OUT" 5)" "would run: official Hermes installer https://hermes-agent.nousresearch.com/install.sh --non-interactive --skip-setup"
check "step 6 would pause for the re-auth checklist" has "$(step_line "$OUT" 6)" "would pause: re-auth checklist"
check "step 6 lists the Codex login" has "$OUT" "hermes auth add openai-codex"
check "step 6 lists the Photon setup" has "$OUT" "hermes photon setup --phone"
check "step 7 would pause for the missing rclone.conf" has "$(step_line "$OUT" 7)" "would pause:"
check "step 7 points to backup/README.md" has "$OUT" "backup/README.md section 4.3"
check "step 8 would restore latest with --force" has "$OUT" "restore: would run: bash backup/hermes-restore.sh latest --force"
check "step 8 would install and start the gateway" has "$OUT" "gateway: would run: hermes gateway start"
check "step 9 would run the pending item installers" has "$(step_line "$OUT" 9)" "would run: 5 of 5 item install.sh"
check "step 10 reports FAIL" has "$(step_line "$OUT" 10)" "FAIL"
check "dry-run called no sudo" test ! -e "$ST/sudo.log"
check "dry-run downloaded nothing" test ! -e "$ST/curl.log"
check "dry-run restored nothing" test ! -e "$ST/restore.log"
check "dry-run ran no item installer" test ! -e "$ST/items.log"
check "dry-run created nothing in the home" test -z "$(find "$HOMEDIR" -mindepth 1)"

section "2. Missing Hermes installer URL stops at step 5"
grep -v '^| V11' "$REAL_REPO/docs/hermes-facts.md" >"$REPO/docs/hermes-facts.md"
bs --dry-run --from-step 5
check "exits 2" test "$RC" -eq 2
check "says the URL is missing and where to add it" has "$OUT" "no official Hermes installer URL in docs/hermes-facts.md (row V11)"
check "never reaches step 6" hasnt "$OUT" "[ 6/10]"
rm -f "$REPO/docs/hermes-facts.md"
bs --dry-run --from-step 5
check "a missing facts file also stops (exit 2)" test "$RC" -eq 2
cp "$REAL_REPO/docs/hermes-facts.md" "$REPO/docs/"

section "3. Real run on a fresh box: steps 1-5, then pause at the re-auth checklist"
fresh_box
bs
check "pauses with exit 20" test "$RC" -eq 20
check "installed the missing packages with sudo apt-get" grep -q '^apt-get install -y jq sqlite3 shellcheck rclone age xz-utils libatomic1 dbus-user-session libpam-systemd$' "$ST/sudo.log"
check "unmasked systemd-logind" grep -qx 'systemctl unmask systemd-logind' "$ST/sudo.log"
check "started systemd-logind" grep -qx 'systemctl start systemd-logind' "$ST/sudo.log"
check "enabled linger for dietpi" grep -qx 'loginctl enable-linger dietpi' "$ST/sudo.log"
check "the user bus exists afterwards" test -S "$ST/run/bus"
check "downloaded the official Tailscale installer" grep -qx 'https://tailscale.com/install.sh' "$ST/curl.log"
check "printed 'now run: sudo tailscale up'" has "$OUT" "now run: sudo tailscale up"
check "never ran 'tailscale up'" bash -c "! grep -q 'tailscale up' \"\$1\"" _ "$ST/sudo.log"
check "downloaded the Hermes installer from the V11 URL" grep -qx 'https://hermes-agent.nousresearch.com/install.sh' "$ST/curl.log"
check "ran it with --non-interactive --skip-setup" grep -qx -- '--non-interactive --skip-setup' "$ST/hermes-installer.args"
check "hermes CLI installed in ~/.local/bin" test -x "$HOMEDIR/.local/bin/hermes"
check "pause says how to continue (--from-step 7)" has "$OUT" "bootstrap.sh --from-step 7"
check "no restore yet" test ! -e "$ST/restore.log"

section "4. Continue from step 7 without rclone.conf: pause, pointing to backup/README.md"
bs --from-step 7
check "pauses with exit 20" test "$RC" -eq 20
check "names the missing rclone.conf" has "$OUT" ".config/rclone/rclone.conf is missing"
check "points to backup/README.md section 4.3" has "$OUT" "backup/README.md section 4.3"
check "steps 1-6 are skipped" has "$(step_line "$OUT" 1)" "skipped (--from-step 7)"
check "still no restore" test ! -e "$ST/restore.log"

section "5. rclone ready, continue from step 7: restore, gateway, items, final checks"
mkdir -p "$HOMEDIR/.config/rclone"; : >"$HOMEDIR/.config/rclone/rclone.conf"
printf 'gdrive:\njafar-encrypted:\n' >"$ST/remotes"
bs --from-step 7
check "exits 0" test "$RC" -eq 0
check "step 7 already done" has "$(step_line "$OUT" 7)" "already done"
check "restored latest with --force, exactly once" test "$(cat "$ST/restore.log")" = "latest --force"
check "wrote the restore marker" test -f "$HOMEDIR/.local/state/jafar/bootstrap-restored"
check "marker folder is private (700)" test "$(stat -c %a "$HOMEDIR/.local/state/jafar")" = 700
check "ran hermes config check after the restore (V15)" grep -qx 'config check' "$ST/hermes.log"
check "installed the gateway service" grep -qx 'gateway install' "$ST/hermes.log"
check "started the gateway" grep -qx 'gateway start' "$ST/hermes.log"
check "item installers ran in plan folder order" test "$(tr '\n' ' ' <"$ST/items.log")" = "backup watchdog guard skills-a skills-b "
check "final checks all PASS" has "$(step_line "$OUT" 10)" "already done (all checks PASS)"
check "prints bootstrap: PASS" has "$OUT" "bootstrap: PASS"

section "6. Idempotency: dry-run says 'already done' for all 10 steps; a real run changes nothing"
bs --dry-run
check "dry-run exits 0" test "$RC" -eq 0
for n in 1 2 3 4 5 6 7 8 9 10; do
    check "step ${n} already done" has "$(step_line "$OUT" "$n")" "already done"
done
check "no 'would run' anywhere" hasnt "$OUT" "would run"
T_OUT=$(env HOME="$HOMEDIR" PATH="${BIN}:${PATH}" FAKE_STATE="$ST" FAKE_BIN="$BIN" \
        BOOTSTRAP_USER_BUS="$ST/run/bus" bash "$REPO/bootstrap/test.sh" 2>&1); T_RC=$?
check "bootstrap/test.sh (the plan's test) exits 0" test "$T_RC" -eq 0
check "bootstrap/test.sh prints 10 PASS lines" test "$(grep -c '^PASS' <<<"$T_OUT")" -eq 10
before=$(snapshot)
bs
check "second real run exits 0" test "$RC" -eq 0
check "second real run changed nothing (no sudo, download, restore or install)" test "$(snapshot)" = "$before"
check "second real run: every step already done" test "$(grep -cE '^\[ ?[0-9]+/10\].*already done' <<<"$OUT")" -eq 10

section "7. Live data is never overwritten by step 8"
rm -f "$HOMEDIR/.local/state/jafar/bootstrap-restored" "$ST/restore.log"
mkdir -p "$HOMEDIR/.hermes"
sqlite3 "$HOMEDIR/.hermes/state.db" "CREATE TABLE sessions(id TEXT); INSERT INTO sessions VALUES('s1');"
bs --dry-run
check "no marker but 1 conversation: step 8 already done" has "$(step_line "$OUT" 8)" "already done (restore skipped:"
check "the reason names the conversation count" has "$(step_line "$OUT" 8)" "holds 1 conversation(s)"
bs
check "real run does not restore" test ! -e "$ST/restore.log"
sqlite3 "$HOMEDIR/.hermes/state.db" "DELETE FROM sessions;"
bs --dry-run
check "no marker and 0 conversations: step 8 would restore" has "$OUT" "restore: would run: bash backup/hermes-restore.sh latest --force"
: >"$HOMEDIR/.local/state/jafar/bootstrap-restored"
bs --dry-run
check "marker present: step 8 already done again" has "$(step_line "$OUT" 8)" "already done"

section "8. Items: a pending item runs; one without --dry-run support counts as pending"
rm -f "$ST/item-guard.installed" "$ST/items.log"
bs --dry-run
check "dry-run marks only guard as would run" has "$OUT" "guard/install.sh: would run"
check "dry-run marks backup as already done" has "$OUT" "backup/install.sh: already done"
bs --from-step 9
check "real run exits 0" test "$RC" -eq 0
check "only guard was installed" test "$(cat "$ST/items.log")" = guard
cat >"$REPO/watchdog/install.sh" <<'SH'
#!/bin/sh
[ "$1" = --dry-run ] && { echo "unknown option" >&2; exit 2; }
echo legacy >>"$FAKE_STATE/items.log"
SH
bs --dry-run --from-step 9
check "an install.sh that rejects --dry-run is reported as would run" has "$OUT" "watchdog/install.sh: would run"
item_stub "$REPO/watchdog/install.sh" watchdog; chmod 755 "$REPO/watchdog/install.sh"

section "8b. systemctl --user works even without an ambient dbus session"
rm -f "$ST/systemctl-no-dbus-env.log"
OUT=$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS HOME="$HOMEDIR" PATH="${BIN}:${PATH}" \
      FAKE_STATE="$ST" FAKE_BIN="$BIN" BOOTSTRAP_USER_BUS="$ST/run/bus" \
      bash "$BS" --dry-run </dev/null 2>&1); RC=$?
check "runs fine with no XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS in the caller's env" test "$RC" -eq 0
check "every systemctl --user call still had both variables set" test ! -e "$ST/systemctl-no-dbus-env.log"

section "9. Guards: root, bad arguments, Docker in packages.txt"
FAKE_UID=0 bs --dry-run
check "refuses to run as root (exit 2)" test "$RC" -eq 2
check "says to run as dietpi" has "$OUT" "Run bootstrap.sh as dietpi"
bs --from-step 11
check "--from-step 11 is rejected (exit 2)" test "$RC" -eq 2
bs --bogus
check "unknown option is rejected (exit 2)" test "$RC" -eq 2
cp "$REPO/bootstrap/packages.txt" "${SB}/packages.bak"
echo docker.io >>"$REPO/bootstrap/packages.txt"
bs --dry-run
check "docker in packages.txt is refused (exit 2)" test "$RC" -eq 2
check "says Docker is never installed" has "$OUT" "Docker and OpenHands are never installed"
cp "${SB}/packages.bak" "$REPO/bootstrap/packages.txt"
check "packages.txt matches the plan's list exactly" \
    test "$(grep -v '^#' "$BOOT/packages.txt" | tr '\n' ' ')" = "git curl jq sqlite3 shellcheck rclone age xz-utils libatomic1 dbus dbus-user-session libpam-systemd "

section "10. install.sh / uninstall.sh never change anything"
for f in install.sh uninstall.sh; do
    for a in "" --dry-run; do
        o=$(bash "$BOOT/$f" $a 2>&1); r=$?
        check "${f} ${a:-(no args)} exits 0 and says already done" bash -c "[[ $r -eq 0 ]] && grep -q 'already done' <<<\"\$1\"" _ "$o"
    done
done

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
