# shellcheck shell=bash
# Off-box backend: a mounted directory (NFS/SMB share on a NAS, sshfs, ...).
# Only counts as off-box if LOCALDIR_DEST really lives on another machine.
# A USB disk plugged into this server survives an SSD failure but not
# theft/fire/power surge: treat it as a second copy, not your only one.
#
#   UPLOAD_BACKEND=localdir
#   LOCALDIR_DEST=/mnt/nas/hermes-backups
#
# Also used by the automated tests as a stand-in destination.

backend_preflight() {
    [[ -n "${LOCALDIR_DEST}" ]] || die 2 "LOCALDIR_DEST is not set"
    [[ -d "${LOCALDIR_DEST}" && -w "${LOCALDIR_DEST}" ]] \
        || die 2 "LOCALDIR_DEST is not a writable directory (is it mounted?): ${LOCALDIR_DEST}"
    if [[ "${LOCALDIR_ALLOW_SAME_FS}" != yes ]] \
        && [[ "$(stat -c %d -- "${LOCALDIR_DEST}")" == "$(stat -c %d -- "${HERMES_HOME}")" ]]; then
        die 2 "LOCALDIR_DEST is on the same filesystem as HERMES_HOME; that is not off-box"
    fi
}

backend_check() {
    backend_preflight
    info "localdir: destination ${LOCALDIR_DEST} is writable"
}

upload_backup() {
    local archive="$1" sidecar="$2" f name
    for f in "$archive" "$sidecar"; do
        name=$(basename -- "$f")
        cp -- "$f" "${LOCALDIR_DEST}/.${name}.partial" || return 1
        mv -f -- "${LOCALDIR_DEST}/.${name}.partial" "${LOCALDIR_DEST}/${name}" || return 1
    done
    sync -f "${LOCALDIR_DEST}" 2>/dev/null || true
}

verify_remote_backup() {
    local archive="$1" sidecar="$2" name want got
    name=$(basename -- "$archive")
    [[ -f "${LOCALDIR_DEST}/${name}" ]] || { error "localdir: ${name} missing at destination"; return 1; }
    [[ -f "${LOCALDIR_DEST}/${name}.sha256" ]] || { error "localdir: sidecar missing"; return 1; }
    want=$(cut -d' ' -f1 <"$sidecar")
    got=$(sha256sum -- "${LOCALDIR_DEST}/${name}" | cut -d' ' -f1)
    [[ "$got" == "$want" ]] || { error "localdir: SHA-256 mismatch for ${name}"; return 1; }
    info "localdir: destination copy SHA-256 matches (${want})"
}

list_remote_backups() {
    local prefix="$1"
    find "${LOCALDIR_DEST}" -maxdepth 1 -type f -name "${prefix}*.tar.gz" -printf '%f\n' | LC_ALL=C sort
}

download_backup() {
    local name="$1" dest="$2"
    is_backup_archive_name "$name" || { error "Not a backup archive name: ${name}"; return 1; }
    cp -- "${LOCALDIR_DEST}/${name}" "${dest}/${name}" || return 1
    cp -- "${LOCALDIR_DEST}/${name}.sha256" "${dest}/${name}.sha256" \
        || warn "localdir: no checksum sidecar for ${name}"
}

prune_remote_backups() {
    local prefix="$1" keep="$2" total n name
    if ! is_uint "$keep" || (( keep < 1 )); then error "prune: KEEP must be >= 1"; return 1; fi
    local -a names=()
    mapfile -t names < <(list_remote_backups "$prefix")
    total=${#names[@]}
    for (( n = 0; n < total - keep; n++ )); do
        name="${names[$n]}"
        is_backup_archive_name "$name" && [[ "$name" == "$prefix"* ]] || continue
        info "localdir: pruning old backup ${name}"
        rm -f -- "${LOCALDIR_DEST}/${name}" "${LOCALDIR_DEST}/${name}.sha256"
    done
}
