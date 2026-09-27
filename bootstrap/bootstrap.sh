#!/usr/bin/env bash
# bootstrap.sh - item #2, rebuild from zero: turn a fresh DietPi (Debian)
# install into Jafar. Run as dietpi over SSH, with network. Uses sudo only
# for the root steps (1-3, and the Tailscale installer in step 4); sudo asks
# for the password.
#
#   bash bootstrap/bootstrap.sh              run every step
#   bash bootstrap/bootstrap.sh --dry-run    change nothing; print what would run
#   bash bootstrap/bootstrap.sh --from-step N
#
# Every step checks first and prints "already done", or runs. Steps:
#    1 apt packages from bootstrap/packages.txt
#    2 systemd-logind unmasked and running
#    3 linger for dietpi, and the user bus /run/user/<uid>/bus
#    4 Tailscale (official installer); you run "sudo tailscale up" yourself
#    5 Hermes (official installer URL from docs/hermes-facts.md, V11)
#    6 PAUSE: re-auth checklist (Codex login, Photon setup)
#    7 PAUSE if the rclone remote for backups is missing
#    8 restore the newest backup into ~/.hermes, then the gateway service
#    9 every other item's install.sh, in the plan's folder order
#   10 final checks: gateway active, Linger=yes, user bus; PASS/FAIL
#
# Docker and OpenHands are never installed.
#
# Exit codes: 0 all done and every final check PASS; 1 a step or a final
# check failed; 2 usage error or a required fact is missing; 20 paused for
# the operator (the message says what to do and how to continue).

set -Eeuo pipefail
# 022, not 077: sudo combines this umask with its own, and apt/Tailscale must
# not create system files that only root can read. Private files made here
# get explicit modes.
umask 022
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
export PATH="${HOME}/.local/bin:${PATH}"   # the hermes CLI lives here

PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
FACTS_FILE="${REPO_ROOT}/docs/hermes-facts.md"
JAFAR_STATE="${HOME}/.local/state/jafar"
RESTORE_MARKER="${JAFAR_STATE}/bootstrap-restored"
HERMES_HOME_DIR="${HOME}/.hermes"
GATEWAY=hermes-gateway
GATEWAY_UNIT_FILE="${HOME}/.config/systemd/user/${GATEWAY}.service"
TAILSCALE_URL="https://tailscale.com/install.sh"
EXIT_PAUSED=20
# Folder order from the build plan's repo layout (bootstrap itself excluded).
ITEM_ORDER=(backup watchdog update guard secrets models evals dashboard digest skills mcp)
STEP_NAMES=("" packages logind linger tailscale hermes re-auth rclone restore items checks)

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRY_RUN=no
FROM_STEP=1
while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=yes; shift ;;
        --from-step)
            [[ $# -ge 2 && "$2" =~ ^([1-9]|10)$ ]] || { echo "--from-step needs a number from 1 to 10" >&2; exit 2; }
            FROM_STEP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$(id -u)" != 0 ]] || { echo "Run bootstrap.sh as dietpi, not as root; it calls sudo itself where needed." >&2; exit 2; }
ME="$(id -un)"
MY_UID="$(id -u)"
USER_BUS="${BOOTSTRAP_USER_BUS:-/run/user/${MY_UID}/bus}"

TMP=""
cleanup() {
    if [[ -n "$TMP" && -d "$TMP" && "$(basename -- "$TMP")" == jafar-bootstrap.* ]]; then
        rm -rf --one-file-system -- "$TMP"
    fi
}
trap cleanup EXIT
tmpdir() { [[ -n "$TMP" ]] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/jafar-bootstrap.XXXXXXXX"); printf '%s' "$TMP"; }

# --- output helpers ----------------------------------------------------------
CUR=0
header() { printf '[%2d/10] %-9s %s\n' "$CUR" "${STEP_NAMES[$CUR]}" "$*"; }
detail() { printf '        %s\n' "$*"; }
die() { local code="$1"; shift; printf '[%2d/10] %-9s FAILED: %s\n' "$CUR" "${STEP_NAMES[$CUR]}" "$*" >&2; exit "$code"; }
# Run a command that changes the system, showing it first.
run() { printf '        $ %s\n' "$*"; "$@"; }
# Stop so the operator can act; in --dry-run just report and carry on.
pause() {
    local resume="$1"; shift
    if [[ "$DRY_RUN" == yes ]]; then
        header "would pause: $1"
        shift; local l; for l in "$@"; do detail "$l"; done
        return 0
    fi
    header "PAUSED: $1"
    shift; local l; for l in "$@"; do detail "$l"; done
    detail ""
    detail "When that is done, continue with:"
    detail "bash ${SCRIPT_DIR}/bootstrap.sh --from-step ${resume}"
    exit "$EXIT_PAUSED"
}

# Membership test without a pipe (printf | grep -q can SIGPIPE under pipefail).
in_list() { local n="$1" x; shift; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

gateway_active() { systemctl --user is-active --quiet "$GATEWAY" 2>/dev/null; }

# Download to a file first, then execute it: nothing runs from a partial download.
fetch() { local url="$1" out="$2"; curl -fsSL --proto '=https' --tlsv1.2 -o "$out" "$url"; }

# --- 1 packages ------------------------------------------------------------------
step_1() {
    local pkgs=() missing=() p status
    while IFS= read -r p || [[ -n "$p" ]]; do
        p="${p%%#*}"; p="${p//[[:space:]]/}"
        [[ -n "$p" ]] && pkgs+=("$p")
    done <"$PACKAGES_FILE"
    (( ${#pkgs[@]} )) || die 2 "no packages listed in ${PACKAGES_FILE}"
    for p in "${pkgs[@]}"; do
        case "$p" in
            docker*|containerd*|podman*|*openhands*) die 2 "packages.txt lists '${p}'; Docker and OpenHands are never installed" ;;
        esac
        [[ "$p" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || die 2 "not a valid package name in packages.txt: '${p}'"
    done
    for p in "${pkgs[@]}"; do
        status=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
        [[ "$status" == "install ok installed" ]] || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        header "already done (${#pkgs[@]} packages installed)"
    elif [[ "$DRY_RUN" == yes ]]; then
        header "would run: sudo apt-get update && sudo apt-get install -y ${missing[*]}"
    else
        header "running: installing ${missing[*]}"
        run sudo apt-get update
        run sudo apt-get install -y "${missing[@]}"
        for p in "${missing[@]}"; do
            status=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
            [[ "$status" == "install ok installed" ]] || die 1 "package ${p} is still not installed"
        done
        detail "done"
    fi
}

# --- 2 systemd-logind -------------------------------------------------------------
step_2() {
    local enabled active
    enabled=$(systemctl is-enabled systemd-logind 2>/dev/null || true)
    active=$(systemctl is-active systemd-logind 2>/dev/null || true)
    if [[ "$enabled" != masked* && "$active" == active ]]; then
        header "already done (systemd-logind ${enabled:-unknown}, active)"
        return 0
    fi
    local actions=()
    [[ "$enabled" == masked* ]] && actions+=("sudo systemctl unmask systemd-logind")
    [[ "$enabled" == disabled ]] && actions+=("sudo systemctl enable systemd-logind")
    [[ "$active" == active ]] || actions+=("sudo systemctl start systemd-logind")
    if [[ "$DRY_RUN" == yes ]]; then
        local joined; joined=$(printf '%s; ' "${actions[@]}")
        header "would run: ${joined%; }"
        return 0
    fi
    header "running: ${enabled:-unknown}/${active:-unknown} -> unmasked, running"
    [[ "$enabled" == masked* ]] && run sudo systemctl unmask systemd-logind
    # A "static" unit has no install section, so "enable" does nothing for it.
    [[ "$enabled" == disabled ]] && run sudo systemctl enable systemd-logind
    [[ "$active" == active ]] || run sudo systemctl start systemd-logind
    [[ "$(systemctl is-active systemd-logind 2>/dev/null || true)" == active ]] \
        || die 1 "systemd-logind is still not active"
    detail "done"
}

# --- 3 linger + user bus --------------------------------------------------------
linger_on() { [[ "$(loginctl show-user "$ME" -p Linger 2>/dev/null || true)" == "Linger=yes" ]]; }
wait_for_bus() { local i; for (( i = 0; i < 10; i++ )); do [[ -S "$USER_BUS" ]] && return 0; sleep 1; done; [[ -S "$USER_BUS" ]]; }
step_3() {
    if linger_on && [[ -S "$USER_BUS" ]]; then
        header "already done (Linger=yes, ${USER_BUS} present)"
        return 0
    fi
    if [[ "$DRY_RUN" == yes ]]; then
        if linger_on; then
            header "would run: sudo systemctl start user@${MY_UID}.service (user bus ${USER_BUS} missing)"
        else
            header "would run: sudo loginctl enable-linger ${ME}; then confirm ${USER_BUS}"
        fi
        return 0
    fi
    header "running: linger and user bus"
    linger_on || run sudo loginctl enable-linger "$ME"
    if ! wait_for_bus; then
        run sudo systemctl start "user@${MY_UID}.service"
        wait_for_bus || die 1 "user bus ${USER_BUS} still missing after enabling linger"
    fi
    linger_on || die 1 "Linger is still not 'yes' for ${ME}"
    detail "done (Linger=yes, ${USER_BUS} present)"
}

# --- 4 Tailscale ----------------------------------------------------------------
step_4() {
    if command -v tailscale >/dev/null 2>&1; then
        header "already done (tailscale installed)"
        tailscale status >/dev/null 2>&1 || detail "note: Tailscale is not up yet; run by hand: sudo tailscale up"
        return 0
    fi
    if [[ "$DRY_RUN" == yes ]]; then
        header "would run: official Tailscale installer (${TAILSCALE_URL})"
        detail "then you run by hand: sudo tailscale up"
        return 0
    fi
    header "running: official Tailscale installer (it uses sudo itself)"
    local f; f="$(tmpdir)/tailscale-install.sh"
    run fetch "$TAILSCALE_URL" "$f"
    run sh "$f"
    command -v tailscale >/dev/null 2>&1 || die 1 "tailscale is still not installed"
    detail "done"
    detail "now run: sudo tailscale up"
}

# --- 5 Hermes ---------------------------------------------------------------------
hermes_installer_url() {
    # The V11 row of docs/hermes-facts.md holds the official install command.
    local row url
    [[ -f "$FACTS_FILE" ]] || return 1
    row=$(grep -m1 -E '^\|[[:space:]]*V11\b' "$FACTS_FILE" || true)
    url=$(grep -oE 'https://[A-Za-z0-9./_-]+/install\.sh' <<<"$row" | sed -n 1p || true)
    [[ -n "$url" ]] || return 1
    printf '%s' "$url"
}
step_5() {
    if [[ -x "${HOME}/.local/bin/hermes" && -d "${HERMES_HOME_DIR}/hermes-agent" ]]; then
        header "already done ($(hermes --version 2>/dev/null | sed -n 1p || echo 'hermes installed'))"
        return 0
    fi
    local url
    url=$(hermes_installer_url) \
        || die 2 "no official Hermes installer URL in docs/hermes-facts.md (row V11). Add it, then run: bash ${SCRIPT_DIR}/bootstrap.sh --from-step 5"
    if [[ "$DRY_RUN" == yes ]]; then
        header "would run: official Hermes installer ${url} --non-interactive --skip-setup"
        return 0
    fi
    header "running: official Hermes installer (${url})"
    local f; f="$(tmpdir)/hermes-install.sh"
    run fetch "$url" "$f"
    run bash "$f" --non-interactive --skip-setup
    [[ -x "${HOME}/.local/bin/hermes" ]] || die 1 "hermes CLI not found at ~/.local/bin/hermes after the installer"
    detail "done"
}

# --- 6 re-auth checklist -----------------------------------------------------------
step_6() {
    if gateway_active; then
        header "already done (${GATEWAY} is running, so the logins are in place)"
        return 0
    fi
    pause 7 "re-auth checklist. Secrets are not in the backup; redo these logins now" \
        "1. hermes auth add openai-codex" \
        "   (Codex / ChatGPT login: open the printed link on your phone, enter the code)" \
        "2. hermes photon setup --phone <your number in +971... format>" \
        "   (Photon / iMessage login)" \
        "Do not start the gateway yourself: step 8 starts it after the restore."
}

# --- 7 rclone remote ---------------------------------------------------------------
backup_remote() {
    local cfg="${HOME}/.config/hermes-backup/config"
    [[ -f "$cfg" ]] || cfg="${REPO_ROOT}/backup/config.example"
    # shellcheck disable=SC2016  # expanded by the inner bash
    bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${RCLONE_REMOTE:-}"' _ "$cfg" 2>/dev/null || true
}
step_7() {
    local conf="${HOME}/.config/rclone/rclone.conf" remote name remotes
    remote=$(backup_remote); name="${remote%%:*}"
    if [[ ! -f "$conf" ]]; then
        pause 7 "${conf} is missing" \
            "Recreate the rclone remotes (gdrive and the crypt remote ${name:-jafar-encrypted})" \
            "exactly as in backup/README.md section 4.3. The crypt passwords are in the vault."
        return 0
    fi
    remotes=$(rclone listremotes 2>/dev/null || true)
    if [[ -n "$name" ]] && grep -qxF -- "${name}:" <<<"$remotes"; then
        header "already done (${conf} has the ${name}: remote)"
        return 0
    fi
    pause 7 "rclone has no '${name:-?}:' remote (the backup destination)" \
        "Create it as in backup/README.md section 4.3, then continue."
}

# --- 8 restore + gateway -----------------------------------------------------------
session_count() {
    local db="${HERMES_HOME_DIR}/state.db" n
    [[ -f "$db" ]] || { echo 0; return; }
    n=$(sqlite3 -readonly "$db" 'SELECT count(*) FROM sessions;' 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}
step_8() {
    local restore_why="" sessions gw_unit=no gw_active=no
    sessions=$(session_count)
    if [[ -f "$RESTORE_MARKER" ]]; then
        restore_why="bootstrap restored on $(sed -n 1p "$RESTORE_MARKER")"
    elif (( sessions > 0 )); then
        restore_why="${HERMES_HOME_DIR}/state.db already holds ${sessions} conversation(s); restoring would overwrite live data"
    fi
    [[ -f "$GATEWAY_UNIT_FILE" ]] && gw_unit=yes
    gateway_active && gw_active=yes

    if [[ -n "$restore_why" && "$gw_unit" == yes && "$gw_active" == yes ]]; then
        header "already done (restore skipped: ${restore_why}; ${GATEWAY} active)"
        return 0
    fi
    if [[ "$DRY_RUN" == yes ]]; then
        header "would run: the parts below"
        if [[ -n "$restore_why" ]]; then detail "restore: already done (${restore_why})"
        else detail "restore: would run: bash backup/hermes-restore.sh latest --force"; fi
        [[ "$gw_unit" == yes ]] || detail "gateway: would run: hermes gateway install"
        [[ "$gw_active" == yes ]] || detail "gateway: would run: hermes gateway start"
        return 0
    fi
    header "running: restore and gateway"
    if [[ -n "$restore_why" ]]; then
        detail "restore: already done (${restore_why})"
    else
        run bash "${REPO_ROOT}/backup/hermes-restore.sh" latest --force </dev/null \
            || die 1 "restore failed; nothing was deleted (replaced items are in ~/.hermes.pre-restore-*)"
        mkdir -p -- "$JAFAR_STATE"
        chmod 700 -- "$JAFAR_STATE"
        date -u +%Y-%m-%dT%H:%M:%SZ >"$RESTORE_MARKER"
        detail "restore: done"
        # V15: config options may differ between Hermes versions. Report only.
        local out l rc=0
        out=$(hermes config check 2>&1) || rc=$?
        while IFS= read -r l; do detail "config check: ${l}"; done <<<"$out"
        (( rc == 0 )) || detail "config check reported problems; if options are missing run: hermes config migrate"
    fi
    if [[ "$gw_unit" != yes ]]; then
        run hermes gateway install || die 1 "hermes gateway install failed"
    fi
    if ! gateway_active; then
        run hermes gateway start || die 1 "hermes gateway start failed"
    fi
    detail "gateway: done"
}

# --- 9 other items' install.sh -----------------------------------------------------
item_installers() {
    local d f
    for d in "${ITEM_ORDER[@]}"; do
        if [[ "$d" == skills ]]; then
            for f in "${REPO_ROOT}"/skills/*/install.sh; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
        elif [[ -f "${REPO_ROOT}/${d}/install.sh" ]]; then
            printf '%s\n' "${REPO_ROOT}/${d}/install.sh"
        fi
    done
}
step_9() {
    local items=() f out rc rel pending=()
    mapfile -t items < <(item_installers)
    if (( ${#items[@]} == 0 )); then
        header "already done (no item install.sh in the repo yet)"
        return 0
    fi
    # Every item's install.sh supports --dry-run; ask each one first.
    for f in "${items[@]}"; do
        rc=0; out=$(bash "$f" --dry-run 2>&1) || rc=$?
        if (( rc != 0 )) || grep -q 'would run' <<<"$out"; then pending+=("$f"); fi
    done
    if (( ${#pending[@]} == 0 )); then
        header "already done (${#items[@]} item(s) report nothing to do)"
        for f in "${items[@]}"; do detail "${f#"${REPO_ROOT}"/}: already done"; done
        return 0
    fi
    if [[ "$DRY_RUN" == yes ]]; then
        header "would run: ${#pending[@]} of ${#items[@]} item install.sh"
        for f in "${items[@]}"; do
            rel="${f#"${REPO_ROOT}"/}"
            if in_list "$f" "${pending[@]}"; then detail "${rel}: would run"; else detail "${rel}: already done"; fi
        done
        return 0
    fi
    header "running: ${#pending[@]} item install.sh, in plan order"
    for f in "${items[@]}"; do
        rel="${f#"${REPO_ROOT}"/}"
        if in_list "$f" "${pending[@]}"; then
            run bash "$f" || die 1 "${rel} failed"
        else
            detail "${rel}: already done"
        fi
    done
    detail "done"
}

# --- 10 final checks ---------------------------------------------------------------
FINAL_FAIL=0
step_10() {
    local lines=() fails=0
    if gateway_active; then lines+=("PASS  ${GATEWAY} is active")
    else lines+=("FAIL  ${GATEWAY} is not active (systemctl --user status ${GATEWAY})"); fails=$((fails + 1)); fi
    if linger_on; then lines+=("PASS  Linger=yes for ${ME}")
    else lines+=("FAIL  Linger is not yes for ${ME}"); fails=$((fails + 1)); fi
    if [[ -S "$USER_BUS" ]]; then lines+=("PASS  user bus ${USER_BUS} present")
    else lines+=("FAIL  user bus ${USER_BUS} missing"); fails=$((fails + 1)); fi
    if (( fails == 0 )); then header "already done (all checks PASS)"
    else header "FAIL (${fails} of 3 checks failed)"; FINAL_FAIL=1; fi
    local l; for l in "${lines[@]}"; do detail "$l"; done
}

# --- main --------------------------------------------------------------------------
[[ "$DRY_RUN" == yes ]] && echo "bootstrap: DRY RUN, nothing will be changed"
for (( CUR = 1; CUR <= 10; CUR++ )); do
    if (( CUR < FROM_STEP )); then
        header "skipped (--from-step ${FROM_STEP})"
        continue
    fi
    "step_${CUR}"
done

if (( FINAL_FAIL == 0 )); then
    echo "bootstrap: PASS"
else
    echo "bootstrap: FAIL"
    exit 1
fi
