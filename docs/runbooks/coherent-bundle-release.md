# Coherent all-in-one bundle: build, qualify, publish

The fork's ordinary `Dockerfile` now builds DuckLake, HTTPFS, PostgreSQL scanner
and JSON against the same pinned PostHog DuckDB core. It no longer downloads a
mixed set of precompiled extension releases. Sources, static-core archive/hash,
dependency pins and patches live in `scripts/ducklake-candidate/`; the directory
name is historical. The `*-inline-null1` / `*-core697fa1` versions identify this
fork's builds, not published upstream releases. No separate DuckLake release or
running DuckLake service is required to build this image.

This applies only to the **all-in-one `duckgres` image, linux/amd64**. The separate
`Dockerfile.worker` and other images are not changed or qualified by this lane.
Native development is unaffected, but Docker builds on ARM hosts must explicitly
select linux/amd64. Unsupported bundle architectures fail closed.

## CI contract

`.github/workflows/duckgres-image.yml` runs on PRs to main, pushes to main and
manual dispatch. Dispatching a branch other than main validates only.

1. The `validate` job has read-only repository permissions, no registry login
   and no package-write permission. It checks build/workflow contracts, source
   pins, guard regressions, shell scripts, transpiler and binary-checker tests.
2. BuildKit builds the ordinary Dockerfile once and loads the image into the
   runner. The build requires all six native regressions (275 assertions),
   linkage checks and the existing Go binary-COPY regression with the rebuilt
   scanner. `build_recipe_sha256` records the actual root Dockerfile; source
   input hashes and extension hashes travel inside the image.
3. `scripts/bundle-ci/qualify.sh` tests that exact local image on disposable,
   separately labelled PostgreSQL/S3 fixtures. It checks actual wire versions,
   settings and extension hashes, single/multi-ALTER migration and native
   errors, inline flush, binary COPY and readback after a graceful Duckgres
   restart. It requires explicit inputs and refuses remote Docker endpoints
   or ambient connection overrides. No Compose or production tunnel is used.
4. After a successful main run, `export.sh` requires a PASS record bound to the
   image ID, saves the image and returns its archive SHA-256 as a job output.
   PRs retain evidence but do not upload a publication image.
5. Only `publish` receives `packages: write`. It downloads the artifact from the
   same successful workflow run, verifies the expected SHA-256 from job outputs,
   loads the archive and verifies the image ID again. It does **not rebuild**.
6. The job logs into GHCR and promotes the verified image to `sha-<full commit>`
   and the backward-compatible `sha-<7 characters>` alias. Existing commit tags
   pointing to another image are refused, not overwritten. Registry/network/auth
   errors are not interpreted as missing tags. `latest` changes only if the
   qualified commit is still main's HEAD when checked; an old rerun leaves it
   untouched. Main runs are serialized rather than interrupted mid-publication.

Image sharing follows Docker's documented
[artifact-based export/load pattern](https://docs.docker.com/build/ci/github-actions/share-image-jobs/).
The workflow downloads only its named image artifact, not unrelated build records.

The publication summary records the registry `image@sha256:...` reference. Use
that digest for deployment identity; a commit-shaped tag is still a mutable
registry name outside this workflow's guard. The image/config ID and the registry
manifest digest are different identifiers. A rerun of the same commit may produce
a different image because OS packages, base images and build timestamps are not
all byte-for-byte reproducible; publication then refuses to replace its old SHA
tag. Review the new inputs and make an explicit new commit/release instead.

## Local verification

Prerequisites: local Docker with BuildKit, Go matching `go.mod`, `psql`, Python3,
`just`, ShellCheck and actionlint. The runtime runner fetches only the explicitly
pinned fixture images if needed; it never pulls the candidate image.

```sh
just test-bundle-build

# On an ARM host, the explicit platform is required.
DOCKER_DEFAULT_PLATFORM=linux/amd64 just build-k8s-image duckgres:bundle-local

# Must be a NEW/empty absolute directory; replace the example with your path.
just qualify-duckdb-bundle duckgres:bundle-local /absolute/new/bundle-evidence
```

`DOCKER_CONTEXT=orbstack` can select an explicitly local engine. The runner owns
only its labelled network and containers; cleanup never prunes other resources.
PostgreSQL/S3 fixture data is temporary and regenerable. Source data, existing
volumes, candidate images and evidence are not removed.

`just build-ducklake-candidate BASE_IMAGE [LOCAL_TAG]` remains an optional overlay
for experiments against a pre-existing local base; it is not the publication
path. Both Dockerfiles share source/build scripts and their small dependency
stage definitions are checked for drift by a regression.

## Evidence and failure handling

- `bundle-qualification`: retained for 14 days, including failed runtime checks.
  Source/build manifests and the loaded file hashes must agree. The authoritative
  image manifest lives in `/app/extensions`, not the persistent extension cache.
  Startup currently refreshes the three external DuckLake/HTTPFS/scanner files;
  JSON is static in the running bindings and cached JSON/manifest files can be old.
- `qualified-duckgres-image`: main only, retained for 2 days to pass the checked
  image to publication. Archive checksums are verified against job outputs, not
  merely an untrusted sidecar file. Evidence files are parsed as data, never sourced.
- A compile, native-test, wire-gate, flush, restart, cleanup, hash or archive error
  blocks publication. Keep the evidence; do not bypass the failing assertion or
  replace it with a production write experiment.
- If interrupted, inspect the runner's recorded resource IDs and labels before
  cleanup. Do not use global container/image/volume prune commands. A hard-killed
  local runner can leave its own disposable resources until explicitly cleaned.
- Native `runtime_qualification=NOT_RUN` in the build manifest remains unchanged;
  the runner writes its separate `qualification.env` PASS only after runtime checks.

## Scope and rollout boundary

The [earlier artifact-specific qualification](../../scripts/ducklake-candidate/QUALIFICATION.md)
also covers a consuming raw-ingestion pipeline and a real source archive; this
fork's generic CI does not import another repository or certify its consumer.
The broader native suite's three VARIANT-default differences remain documented;
the focused build gate is not a claim that every DuckDB test passes.

This lane does not qualify crash recovery, the full CNPG/multi-tenant deployment,
scanner OAuth/credential rotation, pgx high-level OID inference, or every COPY
case. Native transaction regressions are distinct from wrapper COMMIT-error
propagation. The nullability patch prevents new stale inline schemas; it does not
repair already-corrupted inline history.

Publication is not deployment. Before changing an existing environment, verify
its actual runtime/catalog versions read-only, prepare a consistent recoverable
backup, qualify any catalog upgrade on an isolated copy, and coordinate writers.
An automatic catalog migration can make rollback more than an image swap. Update
the infrastructure repository's reviewed image reference through its sanctioned
deployment play. Consumer compatibility and operational backfill remain separate
release steps. No production lifecycle, schema write, or acquisition is performed
by this workflow.
