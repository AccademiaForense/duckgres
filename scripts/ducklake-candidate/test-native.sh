#!/bin/sh
set -eu

mkdir -p /out/native-tests
cd /build/ducklake
for test_path in \
    test/sql/data_inlining/data_inlining_nullability_drop.test \
    test/sql/data_inlining/data_inlining_nullability_default.test \
    test/sql/data_inlining/data_inlining_nullability_transaction.test \
    test/sql/data_inlining/data_inlining_expression_projection.test \
    test/sql/data_inlining/data_inlining_update.test \
    test/sql/stats/extended_catalog_stats.test; do
    test_name=${test_path##*/}
    test_name=${test_name%.test}
    test -s "$test_path"
    test_log="/out/native-tests/$test_name.log"
    if ! /build/extension/test/unittest \
        --require ducklake --require parquet --require icu \
        --max-threads 2 --max-test-threads 2 \
        --warn NoTests "$test_path" >"$test_log" 2>&1; then
        cat "$test_log" >&2
        exit 1
    fi
    # Catch can otherwise return success when no selected test is registered.
    grep -F 'All tests passed' "$test_log" >/dev/null || {
        cat "$test_log" >&2
        printf 'ERROR: no positive test result for %s\n' "$test_name" >&2
        exit 1
    }
    cat "$test_log"
done
