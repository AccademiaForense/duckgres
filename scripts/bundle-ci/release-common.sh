#!/bin/sh
# Shared release guards. Only source this checked-in script, never evidence files.
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
hex64() {
    [ "${#1}" = 64 ] || fail 'expected a 64-character SHA-256'
    case "$1" in *[!0-9a-f]*) fail 'invalid SHA-256' ;; esac
}
image_digest() {
    case "$1" in sha256:*) hex64 "${1#sha256:}" ;; *) fail 'explicit image ID required' ;; esac
}
local_docker() {
    case "${DOCKER_HOST:-unix:///default}" in unix://*|npipe://*) ;; *) fail 'local Docker endpoint required' ;; esac
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
    case "$endpoint" in unix://*|npipe://*) ;; *) fail 'local Docker endpoint required' ;; esac
}
check_image() {
    image_digest "$1"
    [ "$(docker image inspect --format '{{.Id}}' "$1")" = "$1" ] || fail 'image identity mismatch'
    [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1")" = linux/amd64 ] || fail 'linux/amd64 required'
}
field() {
    # Evidence is data, not executable shell; reject duplicate/malformed fields.
    awk -F= -v key="$1" '$1 == key { n++; value=$2; if (NF != 2) bad=1 }
        END { if (n != 1 || bad || value == "") exit 1; print value }' "$2"
}
check_gate() {
    [ "$(field runtime_qualification "$1")" = PASS_LOCAL_SCOPED ] || fail 'successful runtime qualification required'
    [ "$(field image_id "$1")" = "$2" ] || fail 'qualification refers to a different image'
}
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        hash_line=$(sha256sum "$1") || return 1
    else
        hash_line=$(shasum -a 256 "$1") || return 1
    fi
    printf '%s\n' "${hash_line%% *}"
}
