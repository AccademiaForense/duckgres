# shellcheck shell=sh disable=SC2154
# Caller provides evidence, owner, image_id, runner_dir and fixture image pins.
# All destructive operations require both a recorded full ID and our random label.
label_key=org.duckgres.bundle-ci
owned_id() {
    [ -f "$evidence/$1.id" ] || return 1
    recorded_id=$(tr -d '\n' <"$evidence/$1.id")
    is_id "$recorded_id" || return 1
    printf '%s\n' "$recorded_id"
}
assert_owned_container() {
    actual_owner=$(docker inspect --format "{{index .Config.Labels \"$label_key\"}}" "$1")
    [ "$actual_owner" = "$owner" ] || fail 'container ownership label mismatch'
}
fixture_image() {
    case "$1" in "$POSTGRES_FIXTURE_IMAGE"|"$MINIO_FIXTURE_IMAGE") ;; *) fail 'unapproved fixture image' ;; esac
    case "$1" in *@sha256:*) is_id "${1##*@sha256:}" || fail 'invalid fixture digest' ;; *) fail 'fixture must be digest-pinned' ;; esac
    docker image inspect "$1" >/dev/null 2>&1 || docker pull --platform linux/amd64 "$1"
    [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1")" = linux/amd64 ] || fail 'fixture must be linux/amd64'
}
fixtures_ready() {
    docker exec "$postgres_id" pg_isready -h 127.0.0.1 -U ducklake -d ducklake && \
        docker exec "$minio_id" curl --fail --silent http://127.0.0.1:9000/minio/health/live
}
create_network() {
    # An internal-only bridge suppresses host port publishing in Docker 29.
    docker network create --driver bridge \
        --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 \
        --label "$label_key=$owner" "duckgres-bundle-$owner" >"$evidence/network.id"
    network_id=$(owned_id network)
}
create_fixtures() {
    fixture_image "$POSTGRES_FIXTURE_IMAGE"
    fixture_image "$MINIO_FIXTURE_IMAGE"
    create_network
    docker create --pull=never --platform linux/amd64 --cidfile "$evidence/postgres.id" \
        --label "$label_key=$owner" --network "$network_id" --network-alias bundle-pg \
        --tmpfs /var/lib/postgresql:rw,size=536870912 --memory 768m \
        -e POSTGRES_USER=ducklake -e POSTGRES_DB=ducklake -e POSTGRES_PASSWORD=bundle-fixture-password \
        "$POSTGRES_FIXTURE_IMAGE"
    docker create --pull=never --platform linux/amd64 --cidfile "$evidence/minio.id" \
        --label "$label_key=$owner" --network "$network_id" --network-alias bundle-s3 \
        --tmpfs /data:rw,size=536870912 --memory 768m \
        -e MINIO_ROOT_USER=bundlefixture -e MINIO_ROOT_PASSWORD=bundle-fixture-secret \
        "$MINIO_FIXTURE_IMAGE" server /data --address :9000
    postgres_id=$(owned_id postgres)
    minio_id=$(owned_id minio)
    docker start "$postgres_id" "$minio_id"
    attempt=0
    until fixtures_ready; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 90 ] || fail 'PostgreSQL/MinIO fixture readiness timed out'
        sleep 2
    done
    docker exec "$minio_id" mc alias set fixture http://127.0.0.1:9000 bundlefixture bundle-fixture-secret
    docker exec "$minio_id" mc mb fixture/bundle-fixture
    docker create --pull=never --platform linux/amd64 --cidfile "$evidence/duckgres.id" \
        --label "$label_key=$owner" --network "$network_id" --publish 127.0.0.1::5432 \
        --memory 1536m --entrypoint /app/duckgres "$image_id" --config /app/bundle-fixture.yaml
    duckgres_id=$(owned_id duckgres)
    docker cp "$runner_dir/fixture.yaml" "$duckgres_id:/app/bundle-fixture.yaml"
    docker start "$duckgres_id"
}
collect_logs() {
    for role in duckgres postgres minio; do
        id=$(owned_id "$role") || continue
        label=$(docker inspect --format "{{index .Config.Labels \"$label_key\"}}" "$id" 2>/dev/null) || continue
        [ "$label" = "$owner" ] || continue
        docker logs "$id" >"$evidence/$role.log" 2>&1 || true
    done
}
cleanup_owned() {
    cleanup_status=0
    for role in duckgres postgres minio; do
        [ -f "$evidence/$role.id" ] || continue
        id=$(owned_id "$role") || { cleanup_status=1; continue; }
        label=$(docker inspect --format "{{index .Config.Labels \"$label_key\"}}" "$id" 2>/dev/null) || { cleanup_status=1; continue; }
        if [ "$label" = "$owner" ]; then
            docker rm -f "$id" >>"$evidence/cleanup.log" 2>&1 || cleanup_status=1
        else
            printf 'Refusing cleanup of %s: ownership mismatch\n' "$role" >&2
            cleanup_status=1
        fi
    done
    if [ -f "$evidence/network.id" ]; then
        id=$(owned_id network) || return 1
        label=$(docker network inspect --format "{{index .Labels \"$label_key\"}}" "$id" 2>/dev/null) || return 1
        [ "$label" = "$owner" ] || return 1
        docker network rm "$id" >>"$evidence/cleanup.log" 2>&1 || cleanup_status=1
    fi
    return "$cleanup_status"
}
