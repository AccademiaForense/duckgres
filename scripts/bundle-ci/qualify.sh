#!/bin/sh
# shellcheck source-path=SCRIPTDIR
set -eu
runner_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$runner_dir/../.." && pwd)
. "$runner_dir/preflight.sh"
check_only=false
if [ "${1:-}" = --check ]; then check_only=true; shift; fi
[ "$#" = 2 ] || fail 'Usage: qualify.sh [--check] LOCAL_IMAGE NEW_OR_EMPTY_EVIDENCE_DIR'
candidate=$1
evidence=$2
preflight
printf 'Local candidate: %s\n' "$image_id"
$check_only && exit 0
[ -d "$evidence" ] || mkdir -- "$evidence"
evidence=$(CDPATH='' cd -- "$evidence" && pwd -P)
owner=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
printf '%s\n' "$owner" >"$evidence/owner.txt"
qualified=false
. "$runner_dir/fixture-pins.env"
. "$runner_dir/lifecycle.sh"
. "$runner_dir/sql.sh"
. "$runner_dir/evidence.sh"
. "$runner_dir/ddl.sh"
finish() {
    status=$?
    trap - EXIT HUP INT TERM
    collect_logs
    cleanup_owned || status=1
    if [ "$status" = 0 ] && $qualified; then
        printf 'runtime_qualification=PASS_LOCAL_SCOPED\nimage_id=%s\n' "$image_id" >"$evidence/qualification.env"
        printf 'PASS_LOCAL_SCOPED: %s\nEvidence: %s\n' "$image_id" "$evidence"
    else
        printf 'runtime_qualification=FAIL\nimage_id=%s\n' "$image_id" >"$evidence/qualification.env"
        printf 'Qualification failed; evidence retained at %s\n' "$evidence" >&2
        [ "$status" != 0 ] || status=1
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
(cd "$repo_root" && go build -o "$evidence/wirecheck" ./scripts/ducklake-candidate/wirecheck)
create_fixtures >"$evidence/fixture-setup.log" 2>&1
wait_duckgres
verify_runtime before
bundle_ddl_prepare >"$evidence/ddl-prepare.log" 2>&1
bundle_ddl_verify >"$evidence/ddl-before.log" 2>&1
bundle_ddl_snapshot >"$evidence/ddl-before.txt"
DUCKGRES_BUNDLE_TEST_HOST=127.0.0.1 \
DUCKGRES_BUNDLE_TEST_PORT="$wire_port" \
DUCKGRES_BUNDLE_TEST_USER=ducklake \
DUCKGRES_BUNDLE_TEST_DATABASE=ducklake \
DUCKGRES_BUNDLE_TEST_PASSWORD=bundle-fixture-password \
    "$evidence/wirecheck" >"$evidence/binary-copy.log" 2>&1
assert_owned_container "$duckgres_id"
docker restart --timeout 20 "$duckgres_id" >"$evidence/restart.log"
wait_duckgres
verify_runtime after
bundle_ddl_verify >"$evidence/ddl-after.log" 2>&1
bundle_ddl_snapshot >"$evidence/ddl-after.txt"
cmp "$evidence/ddl-before.txt" "$evidence/ddl-after.txt" || fail 'DDL identity or data changed after restart'
cmp "$evidence/hashes-before.txt" "$evidence/hashes-after.txt" || fail 'bundle bytes changed after restart'
qualified=true
