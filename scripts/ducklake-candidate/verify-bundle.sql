-- Read-only preflight for a fresh LOCAL qualification instance with defaults.
-- Run with psql -v ON_ERROR_STOP=1 before any fixture writes.
SELECT CASE
    WHEN library_version = 'v1.5.5' AND source_id = '697fa6fb44'
    THEN 'PASS: pinned DuckDB core'
    ELSE error('Candidate core mismatch: stop qualification')
END AS core_check
FROM pragma_version();

SELECT CASE
    WHEN count(*) = 1 THEN 'PASS: candidate DuckLake loaded'
    ELSE error('Candidate DuckLake missing or version mismatch: stop qualification')
END AS extension_check
FROM duckdb_extensions()
WHERE extension_name = 'ducklake' AND loaded
  AND extension_version = '6768849c-inline-null1';

SELECT CASE
    WHEN count(*) FILTER (WHERE extension_name = 'httpfs'
         AND extension_version = '575da0b-core697fa1' AND loaded) = 1
     AND count(*) FILTER (WHERE extension_name = 'postgres_scanner'
         AND extension_version = 'a3516c0-core697fa1' AND loaded) = 1
    THEN 'PASS: rebuilt HTTPFS and PostgreSQL scanner loaded'
    ELSE error('Mixed-core extension bundle: stop before writes')
END AS bundle_check
FROM duckdb_extensions();

-- Mixed static extension cores can overlap option indices even when every
-- artifact reports v1.5.5. Stock-core HTTPFS overwrites these two DuckLake
-- defaults with http_timeout=30 and http_retries=10, respectively.
SELECT CASE
    WHEN count(*) FILTER (WHERE name = 'ducklake_target_file_size' AND value IS NULL) = 1
     AND count(*) FILTER (WHERE name = 'ducklake_write_deletion_vectors' AND value = 'false') = 1
    THEN 'PASS: DuckLake extension defaults preserved'
    ELSE error('Extension settings collision or non-default test configuration: stop before writes')
END AS settings_check
FROM duckdb_settings();

SELECT CASE
    WHEN system.main.current_setting('ducklake_target_file_size') IS NULL
     AND system.main.current_setting('ducklake_write_deletion_vectors') = false
     AND typeof(system.main.current_setting('ducklake_write_deletion_vectors')) = 'BOOLEAN'
     AND system.main.current_setting('http_timeout') = 30
     AND system.main.current_setting('http_retries') = 10
    THEN 'PASS: native extension values and boolean type preserved'
    ELSE error('Native extension value/type mismatch: stop before writes')
END AS native_settings_check;
