# shellcheck shell=bash
# Off-box backend: rclone. Works with any rclone remote (Google Drive,
# Dropbox, OneDrive, S3-compatible, SFTP, B2, a `crypt` wrapper around any
# of these, ...). The provider is chosen purely by configuration:
#
#   RCLONE_REMOTE="<remote-name>:<path>"   e.g. "hermes-offsite:hermes-backups"
#   RCLONE_CONFIG_FILE=""                  optional; default is rclone's own
#                                          (~/.config/rclone/rclone.conf)
#   RCLONE_VERIFY="download"|"size"        how to prove the upload landed
#   RCLONE_EXTRA_FLAGS=()                  e.g. (--bwlimit 2M)
#
# Credentials live only in rclone's config file, never in this repository
# and never in our logs. We never run rclone with -vv/--dump.

_rclone() {
    local -a flags=(--log-level NOTICE --retries 3 --low-level-retries 10
                    --contimeout 60s --timeout 5m)
    # Unattended (cron): send rclone's own messages to our log file too.
    if [[ -n "${LOG_FILE:-}" && ! -t 2 ]]; then
        flags+=(--log-file "${LOG_FILE}")
    fi
    if [[ -n "${RCLONE_CONFIG_FILE}" ]]; then
        flags+=(--config "${RCLONE_CONFIG_FILE}")
    fi
    "${RCLONE_BIN}" "${flags[@]}" "${RCLONE_EXTRA_FLAGS[@]}" "$@"
}

# Join the configured remote with a file name. "remote:" + "f" -> "remote:f",
# "remote:dir" + "f" -> "remote:dir/f".
_rclone_path() {
    local base="${RCLONE_REMOTE%/}"
    if [[ "$base" == *: ]]; then
        printf '%s%s' "$base" "$1"
    else
        printf '%s/%s' "$base" "$1"
    fi
}

backend_preflight() {
    command -v "${RCLONE_BIN}" >/dev/null 2>&1 \
        || die 2 "rclone not found (RCLONE_BIN=${RCLONE_BIN}). Install it: see backup/README.md"
    [[ -n "${RCLONE_REMOTE}" ]] \
        || die 2 "RCLONE_REMOTE is not set. Set it in your config, e.g. RCLONE_REMOTE=\"hermes-offsite:hermes-backups\""
    [[ "${RCLONE_REMOTE}" == *:* ]] \
        || die 2 "RCLONE_REMOTE must look like '<remote>:<path>' (got '${RCLONE_REMOTE}')"
    if [[ -n "${RCLONE_CONFIG_FILE}" && ! -r "${RCLONE_CONFIG_FILE}" ]]; then
        die 2 "RCLONE_CONFIG_FILE is set but not readable: ${RCLONE_CONFIG_FILE}"
    fi
    case "${RCLONE_VERIFY}" in
        download|size) ;;
        *) die 2 "RCLONE_VERIFY must be 'download' or 'size' (got '${RCLONE_VERIFY}')" ;;
    esac
}

backend_check() {
    info "rclone: checking destination ${RCLONE_REMOTE}"
    _rclone mkdir "${RCLONE_REMOTE}" || return 1
    _rclone lsf --max-depth 1 "${RCLONE_REMOTE}" >/dev/null || return 1
    info "rclone: destination reachable"
}

upload_backup() {
    local archive="$1" sidecar="$2" name sname
    name=$(basename -- "$archive")
    sname=$(basename -- "$sidecar")
    info "rclone: uploading ${name} to ${RCLONE_REMOTE}"
    _rclone copyto "$archive" "$(_rclone_path "$name")" || return 1
    # Sidecar last: its presence marks a complete upload.
    _rclone copyto "$sidecar" "$(_rclone_path "$sname")" || return 1
}

# Print the size of one remote file, or fail if it does not exist.
_rclone_remote_size() {
    local json size
    json=$(_rclone lsjson --files-only --no-modtime --no-mimetype "$(_rclone_path "$1")") || return 1
    size=$(printf '%s' "$json" | tr -d '\n' | sed -n 's/.*"Size":\([0-9][0-9]*\).*/\1/p')
    [[ -n "$size" ]] || return 1
    printf '%s' "$size"
}

verify_remote_backup() {
    local archive="$1" sidecar="$2" name local_size remote_size want got
    name=$(basename -- "$archive")
    local_size=$(stat -c %s -- "$archive")
    remote_size=$(_rclone_remote_size "$name") || { error "rclone: ${name} not found on remote"; return 1; }
    if [[ "$remote_size" != "$local_size" ]]; then
        error "rclone: size mismatch for ${name}: local ${local_size}, remote ${remote_size}"
        return 1
    fi
    _rclone_remote_size "$(basename -- "$sidecar")" >/dev/null \
        || { error "rclone: checksum sidecar missing on remote"; return 1; }
    info "rclone: remote object exists, size ${remote_size} bytes matches"

    if [[ "${RCLONE_VERIFY}" == download ]]; then
        want=$(cut -d' ' -f1 <"$sidecar")
        got=$(_rclone cat "$(_rclone_path "$name")" | sha256sum | cut -d' ' -f1) || {
            error "rclone: failed to read back ${name} for verification"; return 1; }
        if [[ "$got" != "$want" ]]; then
            error "rclone: SHA-256 mismatch on read-back of ${name}"
            return 1
        fi
        info "rclone: read-back SHA-256 matches (${want})"
    fi
}

list_remote_backups() {
    local prefix="$1"
    _rclone lsf --files-only --max-depth 1 --include "${prefix}*.tar.gz" "${RCLONE_REMOTE}" | LC_ALL=C sort
}

download_backup() {
    local name="$1" dest="$2"
    is_backup_archive_name "$name" || { error "Not a backup archive name: ${name}"; return 1; }
    _rclone copyto "$(_rclone_path "$name")" "${dest}/${name}" || return 1
    _rclone copyto "$(_rclone_path "${name}.sha256")" "${dest}/${name}.sha256" \
        || warn "rclone: no checksum sidecar for ${name} on remote"
}

prune_remote_backups() {
    local prefix="$1" keep="$2" total n name
    if ! is_uint "$keep" || (( keep < 1 )); then error "prune: KEEP must be >= 1"; return 1; fi
    local -a names=()
    mapfile -t names < <(list_remote_backups "$prefix")
    total=${#names[@]}
    (( total > keep )) || return 0
    for (( n = 0; n < total - keep; n++ )); do
        name="${names[$n]}"
        if ! is_backup_archive_name "$name" || [[ "$name" != "$prefix"* ]]; then
            warn "prune: skipping unexpected remote name: ${name}"
            continue
        fi
        info "rclone: pruning old remote backup ${name}"
        _rclone deletefile "$(_rclone_path "$name")" || return 1
        _rclone deletefile "$(_rclone_path "${name}.sha256")" || warn "prune: no sidecar for ${name}"
    done
}
