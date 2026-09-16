# shellcheck shell=sh
# These fixtures survive a Duckgres restart; the owning PG/S3 containers clean them up.
ddl_target() {
    case "$1" in single|multi) ;; *) fail 'invalid DDL fixture' ;; esac
    ddl_name=__bundle_ddl_$1
    ddl_table=ducklake.main.$ddl_name
    nullable_sql="SELECT is_nullable FROM information_schema.columns WHERE table_catalog='ducklake' AND table_schema='public' AND table_name='$ddl_name' AND column_name='effective_on'"
}
ddl_native_error() {
    if error_text=$(bundle_sql "$1" 2>&1); then
        fail "native DDL/constraint error was swallowed: $2"
    fi
    printf '%s\n' "$error_text" | grep -F "$2" >/dev/null || fail "native error did not preserve expected diagnostic: $2"
}
bundle_ddl_prepare() {
    for kind in single multi; do
        ddl_target "$kind"
        [ "$(bundle_sql "SELECT count(*) FROM duckdb_tables() WHERE database_name='ducklake' AND table_name='$ddl_name'")" = 0 ] || fail 'DDL fixture already exists'
        bundle_sql "CREATE TABLE $ddl_table (id INTEGER, effective_on DATE NOT NULL, payload VARCHAR)"
        bundle_sql "CALL ducklake_set_option('ducklake', 'data_inlining_row_limit', 100, table_name => '$ddl_name', schema => 'main')"
        bundle_sql "INSERT INTO $ddl_table VALUES (1, DATE '2000-01-01', 'original')"
        [ "$(bundle_sql "$nullable_sql")" = NO ] || fail 'fixture lacks initial NOT NULL metadata'
        ddl_native_error "INSERT INTO $ddl_table VALUES (0, NULL, 'must-fail')" 'NOT NULL'
        applied=0
        for _retry in 1 2; do
            nullable=$(bundle_sql "$nullable_sql")
            case "$nullable" in
                NO)
                    alteration="ALTER TABLE $ddl_table ALTER COLUMN effective_on DROP NOT NULL"
                    [ "$kind" != multi ] || alteration="$alteration, ADD COLUMN source_id VARCHAR"
                    bundle_sql "$alteration"
                    applied=$((applied + 1)) ;;
                YES) ;;
                *) fail 'conditional retry could not read nullability metadata' ;;
            esac
        done
        [ "$applied" = 1 ] || fail 'conditional retry did not apply exactly once'
        ddl_native_error "ALTER TABLE $ddl_table ALTER COLUMN effective_on DROP NOT NULL" 'no NOT NULL constraint'
        ddl_native_error "ALTER TABLE $ddl_table ALTER COLUMN absent_column DROP NOT NULL" 'absent_column'
        if [ "$kind" = multi ]; then
            bundle_sql "INSERT INTO $ddl_table VALUES (2, NULL, 'migrated', 'new-column')"
        else
            bundle_sql "INSERT INTO $ddl_table VALUES (2, NULL, 'migrated')"
        fi
        bundle_sql "CALL ducklake_flush_inlined_data('ducklake', schema_name => 'main', table_name => '$ddl_name')"
    done
}
bundle_ddl_verify() {
    for kind in single multi; do
        ddl_target "$kind"
        [ "$(bundle_sql "$nullable_sql")" = YES ] || fail 'nullable metadata regressed'
        [ "$(bundle_sql "SELECT count(*), count(*) FILTER (WHERE effective_on IS NULL) FROM $ddl_table")" = '2|1' ] || fail 'DDL row/NULL counts differ'
        [ "$(bundle_sql "SELECT payload, effective_on::VARCHAR FROM $ddl_table WHERE id=1")" = 'original|2000-01-01' ] || fail 'original row changed'
        [ "$(bundle_sql "SELECT payload FROM $ddl_table WHERE id=2 AND effective_on IS NULL")" = migrated ] || fail 'nullable row changed'
        if [ "$kind" = multi ]; then
            [ "$(bundle_sql "SELECT source_id FROM $ddl_table WHERE id=2")" = new-column ] || fail 'multi-ALTER added column changed'
        fi
        [ "$(bundle_sql "SELECT count(*) > 0 AND count(*) = count(*) FILTER (WHERE data_file LIKE 's3://%' AND data_file_size_bytes > 0) FROM ducklake_list_files('ducklake', '$ddl_name', schema => 'main')")" = t ] || fail 'DDL fixture did not flush to nonempty S3 files'
    done
}
bundle_ddl_snapshot() {
    for kind in single multi; do
        ddl_target "$kind"
        identity=$(bundle_sql "SELECT count(*), min(table_uuid::VARCHAR) FROM ducklake_table_info('ducklake') WHERE table_name='$ddl_name'")
        case "$identity" in 1\|?*) ;; *) fail 'DDL table identity absent or ambiguous' ;; esac
        printf '%s|%s\n' "$ddl_name" "$identity"
        columns=id,effective_on::VARCHAR,payload
        [ "$kind" != multi ] || columns=$columns,source_id
        bundle_sql "SELECT $columns FROM $ddl_table ORDER BY id"
    done
}
