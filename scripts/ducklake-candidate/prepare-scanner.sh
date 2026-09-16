#!/bin/sh
set -eu

candidate_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/ducklake-candidate/scanner-pins.env
. "$candidate_dir/scanner-pins.env"
fetch_commit() {
    git init -q "$3"
    git -C "$3" remote add origin "$1"
    git -C "$3" fetch -q --depth 1 origin "$2"
    git -C "$3" checkout -q --detach FETCH_HEAD
    test "$(git -C "$3" rev-parse HEAD)" = "$2"
}
fetch_commit https://github.com/duckdb/duckdb-postgres.git "$POSTGRES_COMMIT" /build/postgres
test "$(git -C /build/postgres ls-tree HEAD database-connector | awk '{print $3}')" = "$CONNECTOR_COMMIT"
fetch_commit https://github.com/duckdb/database-connector.git "$CONNECTOR_COMMIT" /build/postgres/database-connector
VCPKG_MAX_CONCURRENCY=2 /build/vcpkg/vcpkg install libpq:x64-linux \
    --overlay-ports=/build/postgres/vcpkg_ports --disable-metrics
installed_libpq=$(awk '/^Package: libpq$/{found=1;next} found && /^Version: /{print $2;exit}' /build/vcpkg/installed/vcpkg/status)
[ "$installed_libpq" = "$LIBPQ_VERSION" ]
