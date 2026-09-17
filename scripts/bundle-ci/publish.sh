#!/bin/sh
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/bundle-ci/release-common.sh
. "$script_dir/release-common.sh"
[ "$#" = 3 ] || fail 'Usage: publish.sh VERIFIED_IMAGE_ID OWNER/REPOSITORY COMMIT_SHA'
image_id=$1
repository=$2
commit=$3
case "$repository" in */*) ;; *) fail 'repository must be OWNER/NAME' ;; esac
case "$repository" in *[!A-Za-z0-9_./-]*|/*|*/|*/*/*) fail 'invalid repository' ;; esac
[ "${#commit}" = 40 ] || fail 'full commit SHA required'
case "$commit" in *[!0-9a-f]*) fail 'invalid commit SHA' ;; esac
local_docker
check_image "$image_id"
image_repo="ghcr.io/$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')"
short_commit=$(printf '%.7s' "$commit")
publish_tmp=$(mktemp -d)
# Only this script's two small diagnostic files are removed; no Docker cleanup.
cleanup() { rm -f "$publish_tmp/manifest.json" "$publish_tmp/manifest.err"; rmdir "$publish_tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tag_state() {
    if docker manifest inspect "$1" >"$publish_tmp/manifest.json" 2>"$publish_tmp/manifest.err"; then
        remote_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["digest"])' <"$publish_tmp/manifest.json") || fail 'expected a single-platform registry manifest'
        [ "$remote_id" = "$image_id" ] || fail "refusing to replace immutable commit tag $1"
        printf 'exists\n'
    else
        # A registry/network/auth failure is not proof that a tag is absent.
        if grep -Fx "no such manifest: $1" "$publish_tmp/manifest.err" >/dev/null ||
            grep -F 'manifest unknown: manifest unknown' "$publish_tmp/manifest.err" >/dev/null; then
            printf 'missing\n'
        else
            cat "$publish_tmp/manifest.err" >&2
            fail "cannot establish registry state for $1"
        fi
    fi
}

# Validate both names before writing either. Workflow concurrency serializes
# main publications; an existing commit tag is never moved to a different image.
full_state=$(tag_state "$image_repo:sha-$commit")
short_state=$(tag_state "$image_repo:sha-$short_commit")
if [ "$full_state" = missing ]; then
    docker tag "$image_id" "$image_repo:sha-$commit"
    docker push "$image_repo:sha-$commit"
fi
if [ "$short_state" = missing ]; then
    docker tag "$image_id" "$image_repo:sha-$short_commit"
    docker push "$image_repo:sha-$short_commit"
fi
current_main=$(gh api "repos/$repository/git/ref/heads/main" --jq .object.sha)
if [ "$current_main" = "$commit" ]; then
    docker tag "$image_id" "$image_repo:latest"
    docker push "$image_repo:latest"
else
    printf 'Leaving latest unchanged: qualified commit is not current main.\n'
fi
printf 'Published verified image %s as %s:sha-%s\n' "$image_id" "$image_repo" "$commit"
manifest_json=$(docker buildx imagetools inspect "$image_repo:sha-$commit" --format '{{json .Manifest}}')
registry_digest=$(printf '%s\n' "$manifest_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')
image_digest "$registry_digest"
printf 'Deployment reference: %s@%s\n' "$image_repo" "$registry_digest"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # shellcheck disable=SC2016 # Backticks are literal Markdown code delimiters.
    printf 'Qualified image: `%s`\n\nDeployment reference: `%s@%s`\n' \
        "$image_id" "$image_repo" "$registry_digest" >>"$GITHUB_STEP_SUMMARY"
fi
