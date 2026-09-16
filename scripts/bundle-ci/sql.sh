# shellcheck shell=sh disable=SC2154
# Caller provides duckgres_id/evidence; discover_port sets wire_port/wire_dsn.
discover_port() {
    assert_owned_container "$duckgres_id"
    published=$(docker port "$duckgres_id" 5432/tcp)
    case "$published" in 127.0.0.1:*) ;; *) fail 'wire port is not exclusively loopback' ;; esac
    wire_port=${published#127.0.0.1:}
    case "$wire_port" in ''|*[!0-9]*) fail 'invalid published wire port' ;; esac
    [ "$wire_port" -gt 0 ] && [ "$wire_port" -le 65535 ] && [ "$wire_port" != 5432 ] || fail 'unsafe published wire port'
    wire_dsn="host=127.0.0.1 port=$wire_port user=ducklake dbname=ducklake sslmode=require connect_timeout=5"
}
bundle_sql() {
    PGPASSWORD=bundle-fixture-password psql "$wire_dsn" -X -w -q -At -v ON_ERROR_STOP=1 -c "$1"
}
wait_duckgres() {
    discover_port
    attempt=0
    until bundle_sql 'SELECT 1' >"$evidence/readiness.log" 2>&1; do
        [ "$(docker inspect --format '{{.State.Running}}' "$duckgres_id")" = true ] || fail 'Duckgres fixture stopped before readiness'
        attempt=$((attempt + 1))
        [ "$attempt" -lt 90 ] || fail 'Duckgres fixture readiness timed out'
        sleep 2
    done
}
