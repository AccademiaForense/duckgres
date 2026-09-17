#!/bin/sh
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/bundle-ci/release-common.sh
. "$script_dir/release-common.sh"
[ "$#" = 3 ] || fail 'Usage: restore.sh ARCHIVE_DIR EXPECTED_ARCHIVE_SHA256 EXPECTED_IMAGE_ID'
archive=$1
expected_sha256=$2
image_id=$3
hex64 "$expected_sha256"
image_digest "$image_id"
local_docker
check_gate "$archive/qualification.env" "$image_id"
# The trusted expected values come from the successful job outputs, not from
# a checksum file travelling alongside a potentially damaged archive.
[ "$(file_sha256 "$archive/image.tar")" = "$expected_sha256" ] || fail 'archive checksum mismatch'
docker image load --input "$archive/image.tar"
check_image "$image_id"
printf 'Restored qualified image: %s\n' "$image_id"
