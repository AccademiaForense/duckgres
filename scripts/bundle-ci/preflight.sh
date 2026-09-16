# shellcheck shell=sh disable=SC2154
# Sourced by qualify.sh with candidate/evidence. Validation is read-only.
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
is_id() { printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; }
preflight() {
    case "$candidate" in
        ''|-*|*[!a-zA-Z0-9._/@:-]*) fail 'invalid local image reference' ;;
        sha256:*) is_id "${candidate#sha256:}" || fail 'image ID must be a full sha256' ;;
        *) case "${candidate##*/}" in
            *:latest|*:|*[!a-zA-Z0-9._:@-]*) fail 'image must have an explicit non-latest tag' ;;
            *:*) ;;
            *) fail 'image must have an explicit non-latest tag' ;;
        esac ;;
    esac
    [ -n "$evidence" ] || fail 'evidence directory is required'
    case "$evidence" in /*) ;; *) fail 'evidence directory must be an absolute path' ;; esac
    [ ! -L "$evidence" ] || fail 'evidence directory must not be a symlink'
    if [ -e "$evidence" ]; then
        [ -d "$evidence" ] || fail 'evidence path must be a directory'
        [ -z "$(ls -A -- "$evidence")" ] || fail 'evidence directory must be empty'
    else
        [ -d "$(dirname -- "$evidence")" ] || fail 'evidence parent directory must exist'
    fi
    if env | LC_ALL=C grep -Eq '^(PG[^=]*|DUCKGRES_BUNDLE_TEST_[^=]*)=.+'; then
        fail 'unset ambient PG* and DUCKGRES_BUNDLE_TEST_* connection variables'
    fi
    for tool in docker go psql; do
        command -v "$tool" >/dev/null 2>&1 || fail "required host tool: $tool"
    done
    case "${DOCKER_HOST:-}" in
        ''|unix://*|npipe://*) ;;
        *) fail 'only a local Docker socket is permitted' ;;
    esac
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') || fail 'cannot inspect local Docker context'
    case "$endpoint" in unix://*|npipe://*) ;; *) fail 'only a local Docker context is permitted' ;; esac
    image_id=$(docker image inspect --format '{{.Id}}' "$candidate" 2>/dev/null) || fail 'candidate image must already exist locally; it will not be pulled'
    case "$image_id" in sha256:*) ;; *) fail 'invalid local image ID' ;; esac
    is_id "${image_id#sha256:}" || fail 'invalid local image ID'
    platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_id")
    [ "$platform" = linux/amd64 ] || fail 'candidate image must be linux/amd64'
    volumes=$(docker image inspect --format '{{json .Config.Volumes}}' "$image_id")
    case "$volumes" in null|'{}') ;; *) fail 'candidate image must not declare implicit volumes' ;; esac
}
