#!/bin/sh
set -eu

candidate_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/ducklake-candidate/pins.env
. "$candidate_dir/pins.env"
[ "${TARGETARCH:?TARGETARCH is required}" = amd64 ]
[ "$(g++ -dumpversion)" = 12 ]
fetch_commit() {
    git init -q "$3"
    git -C "$3" remote add origin "$1"
    git -C "$3" fetch -q --depth 1 origin "$2"
    git -C "$3" checkout -q --detach FETCH_HEAD
    test "$(git -C "$3" rev-parse HEAD)" = "$2"
}
fetch_commit https://github.com/PostHog/ducklake.git "$DUCKLAKE_COMMIT" /build/ducklake
fetch_commit https://github.com/PostHog/duckdb.git "$DUCKDB_COMMIT" /build/ducklake/duckdb
fetch_commit https://github.com/PostHog/duckdb-httpfs.git "$HTTPFS_COMMIT" /build/httpfs
fetch_commit https://github.com/microsoft/vcpkg.git "$VCPKG_COMMIT" /build/vcpkg
/build/vcpkg/bootstrap-vcpkg.sh -disableMetrics
VCPKG_MAX_CONCURRENCY=2 /build/vcpkg/vcpkg install roaring:x64-linux curl:x64-linux openssl:x64-linux --disable-metrics
installed_roaring=$(awk '/^Package: roaring$/{found=1;next} found && /^Version: /{print $2;exit}' /build/vcpkg/installed/vcpkg/status)
[ "$installed_roaring" = "$ROARING_VERSION" ]
curl -fsSL --retry 3 "$STATIC_LIBS_URL" -o /build/static-libs.zip
printf '%s  %s\n' "$STATIC_LIBS_SHA256" /build/static-libs.zip | sha256sum --check --status
unzip -q /build/static-libs.zip -d /build/prebuilt
printf '%s  %s\n' "$STATIC_CORE_SHA256" /build/prebuilt/libduckdb_static.a | sha256sum --check --status
