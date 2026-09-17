#!/bin/sh
set -eu

candidate_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/ducklake-candidate/pins.env
. "$candidate_dir/pins.env"
# shellcheck source=scripts/ducklake-candidate/scanner-pins.env
. "$candidate_dir/scanner-pins.env"
[ "${TARGETARCH:?TARGETARCH is required}" = amd64 ]
[ "$BUILD_VERSION" = 6768849c-inline-null1 ]
[ "$DUCKDB_VERSION" = 1.5.5 ]
[ "$(g++ -dumpversion)" = 12 ]
test "$(sh "$candidate_dir/patch-digest.sh")" = "${PATCH_SHA256:?PATCH_SHA256 is required}"
test "$(git -C /build/ducklake rev-parse HEAD)" = "$DUCKLAKE_COMMIT"
test "$(git -C /build/ducklake/duckdb rev-parse HEAD)" = "$DUCKDB_COMMIT"
test "$(git -C /build/httpfs rev-parse HEAD)" = "$HTTPFS_COMMIT"
test "$(git -C /build/postgres rev-parse HEAD)" = "$POSTGRES_COMMIT"
test "$(git -C /build/postgres/database-connector rev-parse HEAD)" = "$CONNECTOR_COMMIT"
while IFS= read -r patch_file || [ -n "$patch_file" ]; do
    patch_repo=/build/ducklake
    if [ "$patch_file" = 0004-postgres-unique-ptr-compatibility.patch ]; then
        patch_repo=/build/postgres
    fi
    git -C "$patch_repo" apply --check "$candidate_dir/patches/$patch_file"
    git -C "$patch_repo" apply "$candidate_dir/patches/$patch_file"
done <"$candidate_dir/patches/series"
installed_roaring=$(awk '/^Package: roaring$/{found=1;next} found && /^Version: /{print $2;exit}' /build/vcpkg/installed/vcpkg/status)
[ "$installed_roaring" = "$ROARING_VERSION" ]
printf '%s  %s\n' "$STATIC_CORE_SHA256" /build/prebuilt/libduckdb_static.a | sha256sum --check --status

cmake -S /build/ducklake/duckdb -B /build/extension -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=11 \
    -DPREBUILT_BINARY=/build/prebuilt/libduckdb_static.a \
    -DCMAKE_PREFIX_PATH=/build/vcpkg/installed/x64-linux \
    -DCMAKE_TOOLCHAIN_FILE=/build/vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DVCPKG_MANIFEST_MODE=OFF -DVCPKG_TARGET_TRIPLET=x64-linux \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DDUCKDB_EXTENSION_CONFIGS="$candidate_dir/extension-config.cmake" \
    -DDUCKLAKE_LOCAL_BUILD_VERSION="$BUILD_VERSION" \
    -DHTTPFS_LOCAL_BUILD_VERSION="$HTTPFS_BUILD_VERSION" \
    -DPOSTGRES_LOCAL_BUILD_VERSION="$POSTGRES_BUILD_VERSION" \
    -DEXTENSION_STATIC_BUILD=1 -DDISABLE_BUILTIN_EXTENSIONS=OFF \
    -DBUILD_UNITTESTS=ON -DENABLE_UNITTEST_CPP_TESTS=OFF -DBUILD_SHELL=OFF \
    -DENABLE_JEMALLOC=OFF -DUNITTEST_ROOT_DIRECTORY=/build/ducklake \
    -DOVERRIDE_GIT_DESCRIBE=v1.5.5-0-g697fa6fb44 \
    -DDUCKDB_EXPLICIT_PLATFORM=linux_amd64 \
    '-DDUCKDB_EXTRA_LINK_FLAGS=dl;m;pthread;-Wl,-z,defs'
cmake --build /build/extension --target ducklake_loadable_extension httpfs_loadable_extension \
    postgres_scanner_loadable_extension json_loadable_extension unittest --parallel 2
mkdir -p /out
for extension in ducklake httpfs postgres_scanner json; do
    cp "/build/extension/extension/$extension/$extension.duckdb_extension" "/out/$extension.duckdb_extension"
    test -s "/out/$extension.duckdb_extension"
    # No unresolved symbols, nor absent runtime libraries, may escape the build.
    ldd -r "/out/$extension.duckdb_extension" >"/out/$extension-linkage.txt" 2>&1
    if grep -E 'not found|undefined symbol' "/out/$extension-linkage.txt"; then exit 1; fi
done
sh "$candidate_dir/test-native.sh"
cp /build/vcpkg/installed/vcpkg/status /out/vcpkg-status.txt
extension_sha256=$(sha256sum /out/ducklake.duckdb_extension | cut -d ' ' -f 1)
printf '%s\n' "build_version=$BUILD_VERSION" "platform=linux_amd64" \
    "duckdb_version=$DUCKDB_VERSION" "duckdb_commit=$DUCKDB_COMMIT" \
    "ducklake_base_commit=$DUCKLAKE_COMMIT" "patch_sha256=$PATCH_SHA256" \
    "vcpkg_commit=$VCPKG_COMMIT" "roaring_version=$installed_roaring" \
    "bindings_version=$BINDINGS_VERSION" "static_core_sha256=$STATIC_CORE_SHA256" \
    "static_libs_sha256=$STATIC_LIBS_SHA256" "extension_sha256=$extension_sha256" \
    "compiler=$(g++ -dumpfullversion)" 'cxx_standard=11' \
    'native_tests=PASS' 'runtime_qualification=NOT_RUN' >/out/ducklake-build-manifest.txt
printf '%s\n' "httpfs_commit=$HTTPFS_COMMIT" "httpfs_build_version=$HTTPFS_BUILD_VERSION" \
    "postgres_commit=$POSTGRES_COMMIT" "connector_commit=$CONNECTOR_COMMIT" \
    "postgres_build_version=$POSTGRES_BUILD_VERSION" "libpq_version=$LIBPQ_VERSION" \
    'json_commit=697fa6fb44ae14449fb2f3cf509a6a6be79251ac' >>/out/ducklake-build-manifest.txt
for extension in httpfs postgres_scanner json; do
    extension_hash=$(sha256sum "/out/$extension.duckdb_extension" | cut -d ' ' -f 1)
    printf '%s_sha256=%s\n' "$extension" "$extension_hash" >>/out/ducklake-build-manifest.txt
done
(cd "$candidate_dir" && sha256sum pins.env scanner-pins.env Dockerfile build-extension.sh \
    prepare-deps.sh prepare-scanner.sh extension-config.cmake patch-digest.sh test-native.sh \
    verify-bundle.sql prebuilt-extension/CMakeLists.txt) >/out/build-inputs.sha256
# Record the recipe actually used, not merely the optional overlay recipe.
build_recipe=${BUNDLE_BUILD_RECIPE:-$candidate_dir/Dockerfile}
test -s "$build_recipe"
recipe_sha256=$(sha256sum "$build_recipe" | cut -d ' ' -f 1)
printf 'build_recipe_sha256=%s\n' "$recipe_sha256" >>/out/ducklake-build-manifest.txt
if [ -n "${BUNDLE_BUILD_RECIPE:-}" ]; then
    cp "$build_recipe" /out/Dockerfile.bundle-build
    cp /build/go.mod /out/go.mod.bundle-build
    (cd "$candidate_dir" && sha256sum check-pins.sh) >>/out/build-inputs.sha256
    (cd /out && sha256sum Dockerfile.bundle-build go.mod.bundle-build) >>/out/build-inputs.sha256
fi
