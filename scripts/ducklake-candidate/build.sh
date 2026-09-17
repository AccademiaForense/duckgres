#!/bin/sh
set -eu

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        file_hash=$(sha256sum "$1")
    else
        file_hash=$(shasum -a 256 "$1")
    fi
    printf '%s\n' "${file_hash%% *}"
}

check_only=false
if [ "${1:-}" = --check ]; then check_only=true; shift; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    fail 'Usage: sh scripts/ducklake-candidate/build.sh [--check] BASE_IMAGE [duckgres:ducklake-inline-local]'
fi
base_image=$1
candidate_image=${2:-duckgres:ducklake-inline-local}
case "$base_image" in
    -*|*[!a-zA-Z0-9._/@:-]*) fail 'invalid base image reference' ;;
esac
case "${base_image##*/}" in
    *:latest|*:|sha256:*) fail 'base image requires an explicit non-latest tag (not an image ID)' ;;
    *:*) ;;
    *) fail 'base image requires an explicit non-latest tag' ;;
esac
case "$candidate_image" in
    duckgres:ducklake-?*) ;;
    *) fail 'candidate tag must start with duckgres:ducklake-' ;;
esac
case "$candidate_image" in
    *[!a-zA-Z0-9._:-]*) fail 'invalid local candidate tag' ;;
esac
[ "$base_image" != "$candidate_image" ] || fail 'base and candidate must differ'

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
# shellcheck source=scripts/ducklake-candidate/pins.env
. "$script_dir/pins.env"
# shellcheck source=scripts/ducklake-candidate/scanner-pins.env
. "$script_dir/scanner-pins.env"
sh "$script_dir/check-pins.sh" "$repo_root/go.mod"
patch_sha256=$(sh "$script_dir/patch-digest.sh")

# Never use a remote Docker endpoint for this local qualification workflow.
if [ -n "${DOCKER_HOST:-}" ]; then
    case "$DOCKER_HOST" in unix://*|npipe://*) ;; *) fail 'a local Docker endpoint is required' ;; esac
fi
docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
case "$docker_endpoint" in unix://*|npipe://*) ;; *) fail 'a local Docker endpoint is required' ;; esac
base_id=$(docker image inspect --format '{{.Id}}' "$base_image" 2>/dev/null) || fail 'base image must exist locally; build it explicitly first'
base_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$base_image")
[ "$base_platform" = linux/amd64 ] || fail "base image must be linux/amd64, got $base_platform"
printf 'Preflight passed: base=%s (%s), candidate=%s, patch=%s\n' \
    "$base_image" "$base_id" "$candidate_image" "$patch_sha256"
if "$check_only"; then exit 0; fi

artifact_root="$repo_root/artifacts/ducklake-candidate"
mkdir -p "$artifact_root"
run_dir=$(mktemp -d "$artifact_root/run.XXXXXX")
printf 'Build log: %s/build.log\n' "$run_dir"
if ! docker build --pull=false --platform linux/amd64 \
    --file "$script_dir/Dockerfile" \
    --build-arg "BASE_IMAGE=$base_image" \
    --build-arg "BASE_IMAGE_ID=$base_id" \
    --build-arg "PATCH_SHA256=$patch_sha256" \
    --tag "$candidate_image" "$repo_root" >"$run_dir/build.log" 2>&1; then
    tail -n 80 "$run_dir/build.log" >&2
    fail "candidate build failed; full log: $run_dir/build.log"
fi
[ "$(docker image inspect --format '{{.Id}}' "$base_image")" = "$base_id" ] || fail 'base tag changed during build'
candidate_id=$(docker image inspect --format '{{.Id}}' "$candidate_image")

# Only stopped containers are created to extract build evidence; none is run.
base_container=
candidate_container=
cleanup() {
    if [ -n "$base_container" ]; then docker rm "$base_container" >/dev/null || true; fi
    if [ -n "$candidate_container" ]; then docker rm "$candidate_container" >/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
base_container=$(docker create --pull=never --label duckgres.qualify=ducklake-candidate "$base_id")
candidate_container=$(docker create --pull=never --label duckgres.qualify=ducklake-candidate "$candidate_id")
docker cp "$base_container:/app/duckgres" "$run_dir/base-duckgres"
docker cp "$candidate_container:/app/duckgres" "$run_dir/candidate-duckgres"
base_binary_sha256=$(sha256_file "$run_dir/base-duckgres")
candidate_binary_sha256=$(sha256_file "$run_dir/candidate-duckgres")
[ "$base_binary_sha256" = "$candidate_binary_sha256" ] || fail 'candidate unexpectedly changed the Duckgres binary'
extension_dir="/app/extensions/v$DUCKDB_VERSION/linux_amd64"
docker cp "$candidate_container:$extension_dir/ducklake.duckdb_extension" "$run_dir/ducklake.duckdb_extension"
docker cp "$candidate_container:$extension_dir/ducklake-build-manifest.txt" "$run_dir/extension-manifest.txt"
docker cp "$candidate_container:$extension_dir/build-inputs.sha256" "$run_dir/build-inputs.sha256"
for extension in httpfs postgres_scanner json; do
    docker cp "$candidate_container:$extension_dir/$extension.duckdb_extension" "$run_dir/$extension.duckdb_extension"
    extension_hash=$(sha256_file "$run_dir/$extension.duckdb_extension")
    grep -Fx "${extension}_sha256=$extension_hash" "$run_dir/extension-manifest.txt" >/dev/null || fail "$extension manifest hash mismatch"
done
docker cp "$candidate_container:/app/ducklake-candidate/native-tests" "$run_dir/native-tests"
docker cp "$candidate_container:/app/ducklake-candidate/vcpkg-status.txt" "$run_dir/vcpkg-status.txt"
extension_sha256=$(sha256_file "$run_dir/ducklake.duckdb_extension")
grep -Fx "extension_sha256=$extension_sha256" "$run_dir/extension-manifest.txt" >/dev/null || fail 'extension manifest hash mismatch'
grep -Fx "patch_sha256=$patch_sha256" "$run_dir/extension-manifest.txt" >/dev/null || fail 'patch manifest hash mismatch'
grep -Fx 'native_tests=PASS' "$run_dir/extension-manifest.txt" >/dev/null || fail 'native test gate did not pass'
cp "$run_dir/extension-manifest.txt" "$run_dir/manifest.txt"
printf '%s\n' "base_image=$base_image" "base_image_id=$base_id" \
    "candidate_image=$candidate_image" "candidate_image_id=$candidate_id" \
    "duckgres_binary_sha256=$candidate_binary_sha256" >>"$run_dir/manifest.txt"
# These exact files are disposable copies created above; keep the extension/evidence.
rm -f "$run_dir/base-duckgres" "$run_dir/candidate-duckgres"
printf 'Candidate built: %s\nManifest: %s/manifest.txt\nRuntime qualification has NOT been run.\n' "$candidate_image" "$run_dir"
