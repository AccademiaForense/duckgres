# Coherent DuckDB extension bundle and optional local overlay

These shared scripts build DuckLake from exact source pins plus the checked-in
patch series, and rebuild HTTPFS, PostgreSQL scanner and JSON against the same
core. The normal all-in-one `Dockerfile` now uses them, with a
[qualified-image publication workflow](../../docs/runbooks/coherent-bundle-release.md).
This folder also retains an optional local overlay that replaces only those four
extension files in an explicitly selected base. Deployment configuration is not
changed by either build path.

`6768849c-inline-null1` is a fork bundle build identifier, **not** a
published upstream tag. Building the image does not qualify or deploy it.

## Qualification history and current status

Local testing on 2026-09-16 established RED on the compatible unpatched source
and GREEN after the inline-schema fix: 157 assertions across three nullability
tests, plus 28 assertions for sparse expression projections. A temporary overlay
with that loadable extension starts, but its **first INSERT fails** when combined
with the existing HTTPFS `575da0b` binary. Do not deploy this combination.

The PostHog core `697fa6fb44` has `GeneratedSettingInfo::MaxSettingIndex=99`,
while that HTTPFS release was built against upstream 1.5.5 with value 97. Their
statically linked setting-registration code overlaps two slots: HTTPFS sets
`ducklake_target_file_size` to `http_timeout=30` and
`ducklake_write_deletion_vectors` to `http_retries=10`. Native values become
UBIGINT despite the declared VARCHAR/BOOLEAN types. Parsing the target file size
then fails with `Unknown unit for memory: ''` (the value 30 has no unit).
Matching the displayed version 1.5.5 is not sufficient for C++ compatibility.

The recipe now rebuilds the coherent bundle. The scanner also used index 97 and
must not be left unchanged when replacing HTTPFS. Do not mask the collision by
setting these options manually or changing extension load order.
`verify-bundle.sql` detects this failure read-only, before
fixture writes. Through Duckgres, use `duckdb_settings()` or the native
`system.main.current_setting(...)`; unqualified `current_setting(...)` is a
PostgreSQL compatibility macro and returns an empty string for these keys.

The inherited `statistics_extended` callback was a second compatibility issue:
the optimizer bypassed DuckLake catalog statistics. A dedicated callback now
preserves inline, multi-file and nested-column statistics. Its new regression
was RED before the fix; it and the existing update/partition tests pass 163
assertions afterward, with existing tests unchanged. The partition test is
order-sensitive (GROUP BY without ORDER BY) and has also emitted the opposite
valid row order in an earlier run.

In the wider 72-case native inlining/statistics run, 69 passed and three VARIANT
tests failed with the default configuration; two assertions skipped unavailable
HTTPFS/PostgreSQL scanner. Binary A/B confirmed those three failures are not
introduced by the new callback. The pinned core defaults
`variant_minimum_shredding_size` to 30000, while these fixtures have only a few
rows and expect shredding. A separate diagnostic run of the unchanged three
tests with `--on-init 'SET variant_minimum_shredding_size=0;'` passes all 269
assertions. This explicit test profile does **not** change runtime defaults or
turn the default suite into an all-green result.

The self-contained coherent image passed the six-test native build gate (275
assertions) and local PostgreSQL/S3 qualification on 2026-09-16. The read-only
bundle gate, single/multi-ALTER migration, real-archive ingestion, idempotency,
concurrent writers, binary COPY and data comparison after a server restart all
passed. [QUALIFICATION.md](QUALIFICATION.md) identifies the exact image, patch
digest, extension hashes and limits; this result is not a blanket qualification
of other images, full CNPG/multi-tenant operation, or every DuckDB feature.
Nothing has been published or deployed. The nullability fix is preventive; it
does not repair NULLs already inserted into old-version inline tables.

## Inputs

- DuckLake base: `6768849c5b6348452c4bd05688c75085333bb342`.
- DuckDB headers/core: `697fa6fb44ae14449fb2f3cf509a6a6be79251ac`, version 1.5.5.
- Prebuilt core: PostHog `v1.5.5-posthog.5` static library, identical to the
  linux-amd64 bindings `v0.10505.0-posthog.3`; archive and library hashes checked.
- HTTPFS source: `575da0b664cafd079f495171b686e5dab7922b87`, local build ID
  `575da0b-core697fa1`.
- PostgreSQL scanner source: **upstream**
  `a3516c0758f41b673bceefc91ca9d0d25887b1a7`, local build ID
  `a3516c0-core697fa1`; database-connector submodule
  `0a8505f775dae7bb30edd37f848d5975bf72884e`. The PostHog mirror release tag is
  not a source commit; it only redistributes the upstream artifact.
- JSON loadable is rebuilt from the exact core source. The actual Duckgres
  bindings already link JSON, ICU, Parquet, core_functions and autocomplete
  statically. The normal wire runtime qualifies **static JSON**, not a dlopen of
  the rebuilt JSON file; `duckdb_extensions().install_path` alone cannot prove
  dynamic loading.
- Debian bookworm image pinned by digest, GCC 12, C++11, vcpkg commit and
  roaring 4.5.0 locked in `pins.env`/`Dockerfile`; parallelism 2. Dependencies
  include curl 8.17.0, OpenSSL 3.6.0#3 and libpq 18.3 from the scanner's pinned
  overlay (not the older distribution libpq). `scanner-pins.env` locks its inputs;
  `vcpkg-status.txt` records the installed dependency versions.
- All four local patches in `patches/series` are required. Expression-map
  compatibility, inline nullability, extended statistics and the scanner's
  GCC12/C++11 const-pointer conversion are separate patches. The latter was
  required by an observed full-build compiler error, not a behavioral workaround.

Sources and artifact inputs are pinned. This is not a claim of byte-for-byte
reproducible output: apt packages still come from the Debian repositories.
Build logs and manifests identify the compiler and resulting extension hash.
No host Go cache, sibling DuckLake checkout, or pre-existing `/tmp` files are used.

## Optional overlay build

For the normal image and automatic runtime gate, use the
[bundle release runbook](../../docs/runbooks/coherent-bundle-release.md).
The overlay below is for local experiments, not the publication path.

Use a local Docker endpoint. No Compose lifecycle is involved. The base must
already exist locally, be linux/amd64, and include the Duckgres DROP NOT NULL fix.
There is deliberately no default base image or implicit `latest`.

```sh
# Build the current checkout (the ordinary image now includes the bundle).
DOCKER_DEFAULT_PLATFORM=linux/amd64 just build-k8s-image duckgres:drop-not-null-local

# Read-only preflight: no build, pull, container creation, or output files.
just check-ducklake-candidate duckgres:drop-not-null-local

# Explicit opt-in candidate build; this can take several minutes.
just build-ducklake-candidate duckgres:drop-not-null-local
```

The candidate tag defaults to `duckgres:ducklake-inline-local`; an optional second
argument must be another local `duckgres:ducklake-*` tag, distinct from the base.
No image is pushed. Only the four extensions and native SQL test runner are compiled;
the core and built-in core_functions/parquet/icu archives are imported. Dependency
layers are cached separately from patches; a core/compiler-specific BuildKit
cache preserves incremental CMake/Ninja objects between build attempts. Sources,
headers, archives and flags remain checked build inputs. Two stopped inspection
containers are briefly created after the build and removed without starting them.

Evidence is written to a new `artifacts/ducklake-candidate/run.*` directory:
build log, extension binary, source-input hashes, native test logs, extension
manifest, and final manifest containing both image IDs, four extension hashes
and the unchanged Duckgres binary hash. The image build runs the three
`data_inlining_nullability_*.test` regressions, expression-projection regression,
existing `data_inlining_update.test` and new `extended_catalog_stats.test`;
all must pass, with
DuckLake/parquet/ICU required so missing extensions cannot silently skip tests.
DuckLake is linked statically into this runner; the separately emitted loadable
extension must still pass the runtime gate below. `native_tests=PASS` and
`runtime_qualification=NOT_RUN` are separate. Artifacts survive build/test
failures for diagnosis; there is no global Docker prune or automatic image removal.

## Qualification gate

Use a fresh isolated **local** PostgreSQL metadata database and S3 test bucket,
with test-only credentials and a loopback-bound random port. Do not point this
candidate at production or a shared development catalog.

1. Retain the native regressions' RED evidence on the compatible unpatched base.
   The candidate build itself gates patched-source GREEN and saves the six logs.
   Compilation alone is insufficient.
2. Query `pragma_version()` through the candidate's actual PostgreSQL-wire
   endpoint: require `library_version='v1.5.5'` and `source_id='697fa6fb44'`.
3. Query `duckdb_extensions()` for DuckLake: require
   `extension_version='6768849c-inline-null1'`; verify the loaded/cached file's
   SHA256 matches the candidate manifest. `duckgres --version` cannot establish
   which DuckDB core or DuckLake extension is running.
4. Before any fixture writes, execute `verify-bundle.sql` with
   `psql -X -w -v ON_ERROR_STOP=1 -f scripts/ducklake-candidate/verify-bundle.sql`
   against the explicitly selected disposable loopback endpoint. It repeats
   the version checks and requires untouched DuckLake defaults. A nonzero exit
   blocks qualification. This is a manual runtime gate, not a production
   startup guard; custom settings also fail and are not accepted in this test.
5. With inlining explicitly enabled, verify initial NOT NULL enforcement,
   single/multiple ALTERs, metadata-conditional retries, NULL insertion, targeted
   inline-data flush to S3, original row preservation and native errors for a
   repeated unconditional DROP or a missing column. Transaction rollback is
   covered by the native regression, not by this local wire harness. Reopen the
   wire connection, then restart only the disposable candidate server and repeat
   the read assertions against the same test metadata/S3 data. Rediscover its
   published loopback port: Docker may assign a different ephemeral port after
   restart. This does not qualify crash recovery or wrapper COMMIT-failure handling.
6. Run the consuming pipeline's ingestion regression separately. For the raw
   Normattiva pipeline this includes byte/hash/provenance preservation, legacy
   backfill, archive import, rerun idempotency, and concurrent-writer behavior.
7. Run the [binary COPY wire checker](wirecheck/README.md), which uses the actual
   PostgreSQL scanner through the wire endpoint, flushes its own fixture to S3,
   rereads through a new connection and drops only its owned fixture. It does
   not start/stop services or certify the higher-level pgx OID-discovery path.

The existing `tests/integration` harness controls Compose and starts its own
server: do not treat running it unmodified as a test of this candidate image.
The existing bootstrap refreshes a cached `ducklake.duckdb_extension` from the
image on startup, but the actual loaded version/hash must still be verified.

The overlay scripts perform no publication. The normal fork workflow publishes
only its separately verified main artifact; production pins, deployment and
backfill remain separate authorized steps.

## Cheap script checks

```sh
just --command python3 -B -m unittest discover -s scripts/ducklake-candidate -p 'test_*.py'
just --command sh -n scripts/ducklake-candidate/build.sh
just --command sh -n scripts/ducklake-candidate/prepare-deps.sh
just --command sh -n scripts/ducklake-candidate/prepare-scanner.sh
just --command sh -n scripts/ducklake-candidate/build-extension.sh
just --command sh -n scripts/ducklake-candidate/patch-digest.sh
just --command sh -n scripts/ducklake-candidate/test-native.sh
just --command shellcheck -x scripts/ducklake-candidate/*.sh
```

The Python tests substitute a fake Docker executable. They cannot build images,
create containers, or access a real database.
