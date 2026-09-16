#!/bin/sh
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/bundle-ci/release-common.sh
. "$script_dir/release-common.sh"
[ "$#" = 3 ] || fail 'Usage: export.sh IMAGE_ID EVIDENCE_DIR NEW_ARCHIVE_DIR'
image_id=$1
evidence=$2
archive=$3
case "$archive" in /*) ;; *) fail 'archive directory must be absolute' ;; esac
[ ! -e "$archive" ] && [ ! -L "$archive" ] || fail 'archive directory must not exist'
local_docker
check_image "$image_id"
check_gate "$evidence/qualification.env" "$image_id"
mkdir "$archive"
docker image save --output "$archive/image.tar" "$image_id"
archive_sha256=$(file_sha256 "$archive/image.tar")
hex64 "$archive_sha256"
cp "$evidence/qualification.env" "$archive/qualification.env"
printf '%s\n' "$archive_sha256" >"$archive/image.tar.sha256"
printf 'image_id=%s\narchive_sha256=%s\n' "$image_id" "$archive_sha256"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'image_id=%s\narchive_sha256=%s\n' "$image_id" "$archive_sha256" >>"$GITHUB_OUTPUT"
fi
