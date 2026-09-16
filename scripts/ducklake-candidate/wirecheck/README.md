# Local binary COPY wire qualification

This small Go program uses the repository's existing pgx dependency. It sends a
real PostgreSQL `COPY FROM STDIN (FORMAT BINARY)` stream through the candidate
server, checks three rows, flushes only its fixture table, verifies non-empty S3
data files, and rereads the values through a new PostgreSQL connection.

It does not start containers, build images, use Compose, or connect to production.
Run it only against an already running, disposable local candidate fixture.

## Inputs and invocation

From the Duckgres repository root, using the fixture's actual ephemeral port:

```sh
DUCKGRES_BUNDLE_TEST_HOST=127.0.0.1 \
DUCKGRES_BUNDLE_TEST_PORT=32770 \
DUCKGRES_BUNDLE_TEST_USER=ducklake \
DUCKGRES_BUNDLE_TEST_DATABASE=ducklake \
DUCKGRES_BUNDLE_TEST_PASSWORD='<fixture-password>' \
just --command go run ./scripts/ducklake-candidate/wirecheck
```

All five inputs are required. Only literal `127.0.0.1`, a canonical port in
`1..65535` other than `5432`, and user/database `ducklake` are accepted. The
password must be explicitly non-empty; there are no credentials in the program.
Unset non-empty `PG*` environment variables first. DSN/URL overrides and command
arguments are rejected. TLS is required with the local self-signed certificate;
there is no DNS, alternate-host, or plaintext fallback.

Before writes, and again after reconnecting, the checker requires core
`697fa6fb44` and loaded candidate versions `6768849c-inline-null1` (DuckLake),
`575da0b-core697fa1` (HTTPFS), and `a3516c0-core697fa1` (PostgreSQL scanner).
It also checks the DuckLake settings previously affected by the index collision.
These unpublished local version guards are not a substitute for identifying a
disposable local endpoint: never point the checker at a production tunnel.

The sole fixture is
`ducklake.main.__duckgres_bundle_binary_copy_wirecheck`. An existing table with
that name is refused, not replaced. Cleanup compares the persistent DuckLake
table UUID before dropping the table in a transaction, and reports failure if
ownership cannot be established or has changed. It never drops a database or
schema, expires snapshots, deletes S3 objects, or cleans other fixtures. Normal
DuckLake snapshot retention may retain the dropped fixture's historical files.

## Coverage and limits

- Binary COPY uses explicit columns in a different order from the table and
  leaves one column to its default. Cases include NULL versus empty values,
  Unicode text, arbitrary BLOB bytes, BIGINT, BOOLEAN, DOUBLE, DATE, TIMESTAMP,
  TIMESTAMPTZ, pre-2000 values, and microsecond precision.
- The low-level pgx COPY API deliberately avoids pgx's OID-discovery layer; this
  qualifies Duckgres' PostgreSQL binary-COPY protocol and scanner path, not all
  pgx `CopyFrom` type inference behavior.
- This is not an exhaustive COPY suite: decimal rewrites, arrays, huge payloads,
  malformed streams, COPY rollback, and concurrent writers remain covered by
  their separate tests. It does not qualify schema changes or a process restart.
- A targeted flush followed by S3-file and row checks also accepts data written
  directly to S3 by COPY. It does not claim that this particular COPY was inlined.
- The main run times out after two minutes; cleanup has its own 30-second budget.
  An interrupted process or unavailable server may leave the dedicated fixture
  for inspection; a later run will refuse it.

The database-free tests and compile check are:

```sh
just --command go test ./scripts/ducklake-candidate/wirecheck
just --command go build -o /dev/null ./scripts/ducklake-candidate/wirecheck
```
