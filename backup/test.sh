#!/usr/bin/env bash
# test.sh - verify item #1 on the real server. Run as dietpi. Prints PASS/FAIL
# per check and exits non-zero if any check fails.
#
#   bash backup/test.sh             live check: runs a real backup (uploads it),
#                                   then restores the newest off-box archive into
#                                   a temporary folder and compares it
#   bash backup/test.sh --sandbox   the offline suite in tests/run-tests.sh:
#                                   fake Hermes home, no real data, no uploads
#
# The live check never writes to ~/.hermes. Its temporary folder is removed at
# the end.

set -Euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

case "${1:-}" in
    "") ;;
    --sandbox) exec bash "${SCRIPT_DIR}/tests/run-tests.sh" ;;
    *) echo "Usage: test.sh [--sandbox]" >&2; exit 2 ;;
esac

FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

CONFIG="${HOME}/.config/hermes-backup/config"
HERMES_HOME_LIVE="${HOME}/.hermes"
STATE_DIR="${HOME}/.local/state/hermes-backup"
LOCAL_DIR="${HOME}/hermes-backups"
cfg_value() {  # print one variable as set by the user config (empty if unset)
    # shellcheck disable=SC2016  # expanded by the inner bash, on purpose
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2:-}"' _ "$CONFIG" "$1" 2>/dev/null || true
}
if [[ -r "$CONFIG" ]]; then
    v=$(cfg_value STATE_DIR); [[ -z "$v" ]] || STATE_DIR="$v"
    v=$(cfg_value LOCAL_BACKUP_DIR); [[ -z "$v" ]] || LOCAL_DIR="$v"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hermes-restore-test.XXXXXXXX")
cleanup() {
    if [[ -d "$TMP" && "$(basename -- "$TMP")" == hermes-restore-test.* ]]; then
        rm -rf --one-file-system -- "$TMP"
    fi
}
trap cleanup EXIT

# --- installed state -----------------------------------------------------------
check "config exists: ${CONFIG}" test -f "$CONFIG"
check "config is chmod 600" test "$(stat -c %a "$CONFIG" 2>/dev/null)" = 600
check "nightly cron line installed" bash -c 'crontab -l 2>/dev/null | grep -qF "# hermes-backup:managed"'
check "off-box destination reachable (backup-hermes.sh --check)" "${SCRIPT_DIR}/backup-hermes.sh" --check

# --- a real backup -------------------------------------------------------------
before=$(cat "${STATE_DIR}/last-success" 2>/dev/null || true)
if "${SCRIPT_DIR}/hermes-backup.sh" >/dev/null 2>&1; then
    pass "backup run exits 0 (uploaded and verified off-box)"
else
    fail "backup run exits 0 (see ${STATE_DIR}/logs/backup.log)"
fi
after=$(cat "${STATE_DIR}/last-success" 2>/dev/null || true)
check "success marker updated (${STATE_DIR}/last-success)" test -n "$after" -a "$after" != "$before"
NAME=$(awk '{print $2}' <<<"$after")
ARCHIVE="${LOCAL_DIR}/${NAME}"
check "archive exists locally: ${NAME:-<none>}" test -n "$NAME" -a -f "$ARCHIVE"
sha_ok() { (cd -- "$(dirname -- "$1")" && sha256sum -c --quiet "$(basename -- "$1").sha256"); }
check "archive matches its .sha256" sha_ok "$ARCHIVE"
check "archive tar listing is readable" tar -tzf "$ARCHIVE"

# --- restore drill into a temporary folder ------------------------------------
T="${TMP}/.hermes"
if "${SCRIPT_DIR}/hermes-restore.sh" latest --target "$T" --download-dir "${TMP}/download" </dev/null >"${TMP}/restore.out" 2>&1; then
    pass "restore of latest off-box archive into ${T}"
else
    fail "restore of latest off-box archive into ${T} (output below)"
    sed 's/^/      /' "${TMP}/restore.out" | tail -n 20
fi
check "restored the archive that was just uploaded" test -f "${TMP}/download/${NAME}"

# Files restored vs. the archive's own manifest: must be identical.
if [[ -f "${TMP}/download/${NAME}" && -d "$T" ]]; then
    tar -xzOf "${TMP}/download/${NAME}" hermes-backup/MANIFEST.sha256 2>/dev/null \
        | sed -E 's/^[0-9a-f]{64}  home\///' | sort >"${TMP}/manifest.list"
    (cd -- "$T" && find . -type f -printf '%P\n' | sort) >"${TMP}/restored.list"
    check "restored file list equals the archive manifest ($(wc -l <"${TMP}/restored.list") files)" \
        cmp -s "${TMP}/manifest.list" "${TMP}/restored.list"
    # Restored vs. live: every restored file must still exist in ~/.hermes.
    # Live-only files are expected (excluded secrets, caches, new sessions).
    missing=0
    while IFS= read -r f; do
        [[ -e "${HERMES_HOME_LIVE}/${f}" ]] || missing=$((missing + 1))
    done <"${TMP}/restored.list"
    if (( missing == 0 )); then
        pass "every restored file exists in live ${HERMES_HOME_LIVE}"
    else
        fail "${missing} restored file(s) no longer exist in live ${HERMES_HOME_LIVE} (deleted since the backup?)"
    fi
    no_secrets() { ! grep -Eq '(^|/)(\.env[^/]*|auth\.json|[^/]*token[^/]*\.json|mcp-tokens)(/|$)' "$1"; }
    check "no .env, auth.json or token file was restored" no_secrets "${TMP}/restored.list"
fi

echo
if (( FAILS == 0 )); then
    echo "backup test: all PASS"
else
    echo "backup test: ${FAILS} FAIL"
fi
(( FAILS == 0 ))
