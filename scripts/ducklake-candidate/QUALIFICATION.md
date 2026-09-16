# Local coherent-bundle qualification — 2026-09-16

Result: **PASS for the local scope below**, not a published or deployed release.
The earlier mixed-core overlay and the unpatched DuckLake image remain rejected.
The production recipe and pins were unchanged during this recorded run. The
later [fork CI integration](../../docs/runbooks/coherent-bundle-release.md) builds
and qualifies new artifacts separately; it does not inherit this image's result.

## Artifact identity

Candidate tag: `duckgres:ducklake-bundle-local` (local only).

```text
candidate_image_id=sha256:49c7822fa7c77a6aa5126ba1a4386d70396185f6b9a13e2740575177121fe2f3
base_image_id=sha256:88f80a61fff13dad12562674658a4cee1cfd303cf41762b602cf8131be4910bd
duckgres_binary_sha256=3d2cc5bb55013835e20e5a603afbc5f0df3fcf1e283395e332ca0ac2cb29d005
patch_sha256=ac4206228c5edcc5193084207307a96861051f61ba59eebb7b940c7c2b012360
duckdb_commit=697fa6fb44ae14449fb2f3cf509a6a6be79251ac
ducklake_sha256=bdf9851f804c3cfe89a89c5562bfb17c1993d11eab40f0cd9717498d3a7692c9
httpfs_sha256=5fc9b523fd66c8141620781378925a29ba12e231e3bcf9dca984839daf8ea6a7
postgres_scanner_sha256=190c4002dfe969b5bb17f14a46f843c12aa52df0314bd777db71bf873d7a103a
json_sha256=4a3645fe66f75d8ee1b653829557871a9ee9976a7fe6d5c5087fdd762e947596
```

The Duckgres binary is unchanged from the explicitly selected base, which
contains the DROP NOT NULL transpiler correction. The candidate replaces only
the four extension files and adds build evidence. Source pins, dependency
versions and all build inputs are recorded by the build recipe; GCC is 12.2.0,
C++11, platform linux/amd64. A tag alone is not an immutable qualification ID.

## Executed checks

- **Self-contained build:** all four extension targets compiled and passed the
  builder's unresolved-symbol check. Six native tests passed **275 assertions**:
  DROP nullability 48, default changes 55, transaction behavior 54, sparse
  projections 28, existing inlining update 62, extended catalog statistics 28.
- **Actual wire endpoint:** `verify-bundle.sql` passed before fixture writes and
  after restart. Core and loaded extension versions match the pins. DuckLake
  defaults remain NULL / BOOLEAN false, and HTTP timeout/retry values remain
  30 / 10. No manual setting override or load-order workaround was used.
- **Loaded artifacts:** `/proc/1/maps` identified the cached DuckLake, HTTPFS and
  PostgreSQL scanner libraries. Their cached-file SHA-256 values match the
  manifest above. JSON is linked statically in the bindings; no JSON loadable
  was mapped, so the rebuilt JSON file is not independently dlopen-qualified.
- **DDL over PostgreSQL wire:** the same `drop_not_null_migration` assertion from
  the mw-dev harness was extracted and run with local connection wrappers, not
  the full cluster harness. Single/multi-ALTER changes NO to YES, permits NULL,
  flushes inlined rows to S3 and preserves old values. A metadata-conditional
  second migration skips DDL; unconditional repetition and a missing column
  preserve engine errors. Both temporary tables were removed after success.
- **Raw ingestion:** the consuming pipeline's `TestRawXMLWireRuntime` used the
  previously downloaded real 28-member Constitution archive in a fresh lake.
  Backfill affected **2** legacy records; import inserted **27**, deduplicating
  the original to yield **29** raw rows. It checked bytes, checksums, identities,
  dates and provenance before and after S3 flush/reconnect. Repeated backfill
  and import both affected **0**, without changing original rows. Two concurrent
  writers added the same extra synthetic fixture exactly once, for **30** rows.
  This tests the supplied archive, not completeness of all legal historical states.
- **Binary COPY:** the dedicated [wire checker](wirecheck/README.md) sent three
  real PostgreSQL binary rows with reordered/subset columns, defaults, NULLs,
  Unicode, BLOBs and temporal types. Targeted flush, non-empty S3-file checks,
  new-connection reads and UUID-guarded fixture cleanup passed.
- **Graceful restart:** only the same local Duckgres container was restarted;
  PostgreSQL metadata and S3 remained intact. The raw-row count stayed **30**,
  invalid hashes/IDs stayed **0**, and **28** rows retained NULL historical
  request dates (27 archive members plus the concurrent-writer fixture).
  The ordered full-row JSON aggregate had identical SHA-256 before and after:
  `1b626782190cfa3d868af75467baead7ffdbbe45ec468145614f17c42f34b32d`.
  S3-backed files remained present and readable. The new ephemeral host port
  was rediscovered from the same container ID after restart.

Build manifests, native logs, wire test logs and before/after witnesses are
retained locally under `artifacts/ducklake-candidate/run.JSKcVp/`. The build's
`runtime_qualification=NOT_RUN` field is deliberately not rewritten: build and
runtime evidence are separate; `runtime-qualification.txt` records this later run.
The local raw archive SHA-256 is
`8e8152e5704d9b071e92a06c97ccc17003331f3e6d2b935ed23a4edc0d54c011`.
The three disposable fixture containers and their empty network were removed
after verification. Only regenerable fixture data was discarded; source archives,
code, candidate images and evidence were retained. No other services were changed.

## Limits and remaining release work

- The wider native 72-case inlining/statistics run has **69 PASS / 3 VARIANT
  failures** at the pinned PostHog default threshold of 30000; two assertions
  skipped unavailable HTTPFS/PostgreSQL scanner in that runner. Binary A/B shows
  the three failures are unchanged by the statistics patch. The original tests
  pass **269 assertions** with the explicit diagnostic setting
  `variant_minimum_shredding_size=0`; runtime defaults were not changed.
  A separate partition test has emitted both valid GROUP BY row orders without
  ORDER BY. Existing tests were not weakened to hide these observations.
- Native tests cover transaction rollback. The extracted local DDL harness does
  not certify wire rollback, wrapper COMMIT-error propagation, or the full
  CNPG/multi-tenant/control-plane lane. The Compose-managed integration suite
  was not run against this image. SET NOT NULL remains Duckgres' existing no-op.
- The binary checker does not qualify pgx's higher-level OID inference, all COPY
  edge cases, or scanner OAuth/credential rotation. The restart is graceful,
  not a kill/crash-recovery test. There is no claim of a fully green DuckDB suite.
- The inline-schema correction prevents new stale-schema data; it does not
  repair NULLs already written to older inline schemas. Existing-data recovery
  requires separate assessment. No production data was changed here.
- Review, publication, an immutable production pin, sanctioned deployment and
  downstream consumer compatibility remain separate release steps. No push,
  commit, merge, image publication, deployment or production acquisition was
  performed as part of this qualification.
