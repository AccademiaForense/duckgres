package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

const candidateGateSQL = `SELECT
 (SELECT count(*) FROM pragma_version()
  WHERE source_id = '697fa6fb44' AND library_version = 'v1.5.5') = 1
 AND (SELECT count(*) FROM duckdb_extensions() WHERE loaded AND (
  (extension_name = 'ducklake' AND extension_version = '6768849c-inline-null1') OR
  (extension_name = 'httpfs' AND extension_version = '575da0b-core697fa1') OR
  (extension_name = 'postgres_scanner' AND extension_version = 'a3516c0-core697fa1'))) = 3
 AND system.main.current_setting('ducklake_target_file_size') IS NULL
 AND typeof(system.main.current_setting('ducklake_write_deletion_vectors')) = 'BOOLEAN'
 AND system.main.current_setting('ducklake_write_deletion_vectors') = false`

func candidateGate(ctx context.Context, conn *pgx.Conn) error {
	var valid bool
	if err := conn.QueryRow(ctx, candidateGateSQL).Scan(&valid); err != nil {
		return fmt.Errorf("read-only candidate gate: %w", err)
	}
	if !valid {
		return errors.New("candidate core, extension versions, or settings mismatch; no fixture writes permitted")
	}
	return nil
}

func connect(ctx context.Context, cfg config) (*pgx.Conn, error) {
	pc, err := cfg.connectionConfig()
	if err != nil {
		return nil, err
	}
	return pgx.ConnectConfig(ctx, pc)
}
