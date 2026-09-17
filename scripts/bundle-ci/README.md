# Local bundle qualification

Run from the repository with Docker, Go and `psql` installed (`just` is the local
command wrapper; the CI script does not require it):

```sh
# Read-only guards: an explicit local tag/ID and a new or empty evidence directory.
just --command sh scripts/bundle-ci/qualify.sh --check duckgres:bundle-ci /tmp/bundle-evidence
# The same invocation without --check runs the disposable qualification.
just --command sh scripts/bundle-ci/qualify.sh duckgres:bundle-ci /tmp/bundle-evidence
just --command python3 -B scripts/bundle-ci/test_qualify.py
```

The evidence directory must be absolute, new or empty. The candidate must
already exist locally, be `linux/amd64`, and declare no
volumes. An untagged image, `latest`, remote daemon or nonempty evidence directory
is rejected. `DOCKER_CONTEXT` can select a local Unix-socket context (including
OrbStack); unset ambient `PG*` and `DUCKGRES_BUNDLE_TEST_*` variables first.
No candidate pull, Compose operation, tunnel or external database is supported.

The runner creates one dedicated bridge network and exactly three labeled containers:
PostgreSQL 18.3 and MinIO with tmpfs data, and the candidate with a random
`127.0.0.1` wire port. Only the two digest-pinned amd64 fixtures can be pulled.
PostgreSQL and MinIO publish no host ports. The network also defaults host
bindings to loopback, and the actual Duckgres binding is checked before SQL.
This isolates the fixtures from unrelated Docker networks, but is **not** an
air gap or an egress firewall: the bridge allows outbound networking. An
internal-only bridge cannot be used because Docker can silently suppress its
[requested host port mapping](https://github.com/moby/moby/discussions/53256).
Their public, disposable credentials are in `fixture.yaml`; they are not secrets
or deployment defaults. The pins in `fixture-pins.env` are child manifests from
the [official PostgreSQL image](https://github.com/docker-library/postgres) and
the [MinIO registry](https://quay.io/repository/minio/minio), verified with
`docker buildx imagetools inspect TAG --raw` and the matching amd64 manifest.

Before fixture SQL writes, the existing bundle/version/settings gate must pass,
and hashes from `/app/extensions` must match the actual three mapped cache files.
JSON is statically linked: its bundled file is hashed but not qualified as a
loaded library. The runner then checks single/multi-clause `DROP NOT NULL`, an
exactly-once metadata-conditional retry, native errors, NULL insertion and S3
flushes. Its separate DDL fixtures intentionally survive restart, unlike the
existing mw-dev test lifecycle. The existing Go checker supplies three-row
PostgreSQL binary COPY, NULL/Unicode/temporal/default checks and a fresh reader.
Only Duckgres is restarted; table UUIDs, rows, S3 files and bundle hashes must
remain unchanged.

On success **and successful cleanup**, `qualification.env` contains
`runtime_qualification=PASS_LOCAL_SCOPED` and the full verified `image_id`.
This is scoped fixture coverage, not a full integration/consumer-data test or a
publication decision. Logs, manifest, hashes, identities and COPY evidence stay
in the supplied directory, including on failure. Treat evidence as data, never
source it as shell. No image is pushed or deleted.

Cleanup removes only recorded full container/network IDs bearing this run's
random label; it never prunes or searches by a broad name. An ownership mismatch
fails closed and leaves the resource intact. After a hard kill or daemon loss,
use `owner.txt` and the individual `*.id` files to inspect each resource's
`org.duckgres.bundle-ci` label before explicitly removing that exact ID. Preserve
the evidence and rerun with a different empty directory.
