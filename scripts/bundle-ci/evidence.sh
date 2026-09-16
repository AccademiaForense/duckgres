# shellcheck shell=sh disable=SC2154
# Caller provides evidence, duckgres_id, image_id, wire_dsn and repo_root.
manifest_field() {
    awk -F= -v key="$1" '$1 == key { count++; value=substr($0,length(key)+2) } END { if(count != 1) exit 1; print value }' \
        "$evidence/extension-manifest.txt"
}
container_hash() {
    hashed=$(docker exec "$duckgres_id" sha256sum "$1") || return 1
    hashed=${hashed%% *}
    is_id "$hashed" || return 1
    printf '%s\n' "$hashed"
}
verify_runtime() {
    phase=$1
    assert_owned_container "$duckgres_id"
    [ "$(docker inspect --format '{{.Image}}' "$duckgres_id")" = "$image_id" ] || fail 'container image identity differs'
    PGPASSWORD=bundle-fixture-password psql "$wire_dsn" -X -w -v ON_ERROR_STOP=1 \
        -f "$repo_root/scripts/ducklake-candidate/verify-bundle.sql" >"$evidence/gate-$phase.log" 2>&1
    extension_dir=/app/extensions/v1.5.5/linux_amd64
    docker cp "$duckgres_id:$extension_dir/ducklake-build-manifest.txt" "$evidence/extension-manifest.txt"
    docker cp "$duckgres_id:$extension_dir/build-inputs.sha256" "$evidence/build-inputs.sha256"
    [ "$(manifest_field native_tests)" = PASS ] || fail 'native build test gate missing'
    [ "$(manifest_field duckdb_commit)" = 697fa6fb44ae14449fb2f3cf509a6a6be79251ac ] || fail 'manifest core pin mismatch'
    patch_hash=$(sh "$repo_root/scripts/ducklake-candidate/patch-digest.sh")
    [ "$(manifest_field patch_sha256)" = "$patch_hash" ] || fail 'manifest patch digest differs from checkout'
    docker exec "$duckgres_id" cat /proc/1/maps >"$evidence/maps-$phase.txt"
    awk '$NF ~ /\.duckdb_extension$/ { print $NF }' "$evidence/maps-$phase.txt" | LC_ALL=C sort -u >"$evidence/mapped-$phase.txt"
    [ "$(wc -l <"$evidence/mapped-$phase.txt" | tr -d ' ')" = 3 ] || fail 'expected exactly three mapped loadable extensions'
    : >"$evidence/hashes-$phase.txt"
    for extension in ducklake httpfs postgres_scanner json; do
        key=${extension}_sha256
        [ "$extension" != ducklake ] || key=extension_sha256
        expected=$(manifest_field "$key") || fail "missing unique manifest hash for $extension"
        is_id "$expected" || fail "invalid manifest hash for $extension"
        [ "$(container_hash "$extension_dir/$extension.duckdb_extension")" = "$expected" ] || fail "$extension bundled hash differs"
        if [ "$extension" != json ]; then
            cached=/app/data/extensions/v1.5.5/linux_amd64/$extension.duckdb_extension
            grep -Fx "$cached" "$evidence/mapped-$phase.txt" >/dev/null || fail "$extension expected cache file is not mapped"
            [ "$(container_hash "$cached")" = "$expected" ] || fail "$extension mapped cache hash differs"
        fi
        printf '%s_sha256=%s\n' "$extension" "$expected" >>"$evidence/hashes-$phase.txt"
    done
    binary_hash=$(container_hash /app/duckgres) || fail 'cannot hash running server binary'
    printf 'duckgres_binary_sha256=%s\n' "$binary_hash" >>"$evidence/hashes-$phase.txt"
    printf 'JSON is built into Duckgres; its bundled file is hashed but is not qualified as a loaded library.\n' >"$evidence/json-scope.txt"
}
