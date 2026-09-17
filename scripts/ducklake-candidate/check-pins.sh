#!/bin/sh
set -eu

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$#" = 1 ] || fail 'Usage: check-pins.sh GO_MOD'
candidate_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/ducklake-candidate/pins.env
. "$candidate_dir/pins.env"
# shellcheck source=scripts/ducklake-candidate/scanner-pins.env
. "$candidate_dir/scanner-pins.env"
[ "$BUILD_VERSION" = 6768849c-inline-null1 ] || fail 'unexpected BUILD_VERSION'
[ "$HTTPFS_BUILD_VERSION" = 575da0b-core697fa1 ] || fail 'unexpected HTTPFS_BUILD_VERSION'
[ "$POSTGRES_BUILD_VERSION" = a3516c0-core697fa1 ] || fail 'unexpected POSTGRES_BUILD_VERSION'
[ "$DUCKDB_COMMIT" = 697fa6fb44ae14449fb2f3cf509a6a6be79251ac ] || fail 'unexpected DuckDB header core'
[ "$DUCKDB_VERSION" = 1.5.5 ] || fail 'unexpected DuckDB version'
expected_binding="replace github.com/duckdb/duckdb-go-bindings/lib/linux-amd64 => github.com/PostHog/duckdb-go-bindings/lib/linux-amd64 $BINDINGS_VERSION"
grep -Fx "$expected_binding" "$1" >/dev/null || fail 'go.mod binding pin does not match the candidate core'
sh "$candidate_dir/patch-digest.sh" >/dev/null
