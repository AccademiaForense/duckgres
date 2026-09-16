# Candidate patch

`series` lists patches in application order. Patches 1–3 target DuckLake commit
`6768849c5b6348452c4bd05688c75085333bb342`; patch 4 targets PostgreSQL scanner
`a3516c0758f41b673bceefc91ca9d0d25887b1a7`:

1. `0001-core-expression-map-compatibility.patch`: compatibility with the pinned
   PostHog DuckDB core's physical-column-keyed `expression_map`, including its
   focused regression, plus explicit unique_ptr conversions for GCC 12/C++11.
   This is not the inline nullability bug fix.
2. `0002-inline-schema-nullability.patch`: inline-schema nullability fix and its
   SQL regressions.
3. `0003-extended-catalog-statistics.patch`: forward the new core's extended
   statistics callback to DuckLake catalog statistics, including nested
   projections; preserves inline and multi-file statistics. Includes a focused
   regression and is separate from the nullability fix.
4. `0004-postgres-unique-ptr-compatibility.patch`: explicit moving conversion to
   `unique_ptr<const BaseSecret>` for GCC 12/C++11. The unpatched source fails
   compilation at `PostgresSecretStorage::DeserializeSecret`.

The build fails closed while any reviewed patch is absent. Do not substitute
an empty patch, a remote pull request, or a fabricated release tag. The aggregate
patch digest covers names, order, and file contents.
