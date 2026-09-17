package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func qualify(ctx context.Context, cfg config) (result error) {
	conn, err := connect(ctx, cfg)
	if err != nil {
		return fmt.Errorf("connect local fixture: %w", err)
	}
	defer closeConnection(conn)
	if err := candidateGate(ctx, conn); err != nil {
		return err
	}
	var existing int64
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM duckdb_tables()
 WHERE database_name = 'ducklake' AND table_name = '`+fixtureName+`'`).Scan(&existing); err != nil {
		return fmt.Errorf("check fixture absence: %w", err)
	}
	if existing != 0 {
		return errors.New("fixture name already exists; refusing to create, copy, or drop it")
	}
	// CREATE, never CREATE OR REPLACE/IF NOT EXISTS: a concurrent creator must fail.
	if _, err := conn.Exec(ctx, createSQL); err != nil {
		return fmt.Errorf("create dedicated fixture: %w", err)
	}
	uuid, err := fixtureIdentity(ctx, conn)
	if err != nil {
		return fmt.Errorf("created fixture but cannot establish ownership; left for manual inspection: %w", err)
	}
	defer func() {
		if err := cleanupFixture(cfg, uuid); err != nil {
			result = errors.Join(result, fmt.Errorf("fixture cleanup: %w", err))
		}
	}()
	// This emits actual PostgreSQL binary CopyData frames, not INSERT or CSV.
	tag, err := conn.PgConn().CopyFrom(ctx, bytes.NewReader(fixturePayload()), copySQL)
	if err != nil {
		return fmt.Errorf("COPY FROM STDIN FORMAT BINARY: %w", err)
	}
	if tag.RowsAffected() != 3 {
		return fmt.Errorf("COPY affected %d rows, expected 3", tag.RowsAffected())
	}
	if err := verifyRows(ctx, conn); err != nil {
		return err
	}
	if _, err := conn.Exec(ctx, `CALL ducklake_flush_inlined_data('ducklake',
 schema_name => 'main', table_name => '`+fixtureName+`')`); err != nil {
		return fmt.Errorf("targeted fixture flush: %w", err)
	}
	if err := conn.Close(ctx); err != nil {
		return fmt.Errorf("close writer: %w", err)
	}
	reader, err := connect(ctx, cfg)
	if err != nil {
		return fmt.Errorf("open independent reader: %w", err)
	}
	defer closeConnection(reader)
	if err := candidateGate(ctx, reader); err != nil {
		return err
	}
	var files, s3Files int64
	if err := reader.QueryRow(ctx, `SELECT count(*), count(*) FILTER
 (WHERE data_file LIKE 's3://%' AND data_file_size_bytes > 0)
 FROM ducklake_list_files('ducklake', '`+fixtureName+`', schema => 'main')`).Scan(&files, &s3Files); err != nil {
		return fmt.Errorf("inspect fixture Parquet files: %w", err)
	}
	if files == 0 || s3Files != files {
		return errors.New("fixture did not persist entirely to non-empty S3 data files")
	}
	return verifyRows(ctx, reader)
}

func verifyRows(ctx context.Context, conn *pgx.Conn) error {
	var match bool
	if err := conn.QueryRow(ctx, verifyRowsSQL).Scan(&match); err != nil {
		return fmt.Errorf("read fixture values: %w", err)
	}
	if !match {
		return errors.New("fixture row count, values, NULLs, or omitted-column defaults differ")
	}
	return nil
}

func fixtureIdentity(ctx context.Context, conn *pgx.Conn) (string, error) {
	// DuckLake's persistent UUID survives reconnections; duckdb_tables().table_oid
	// is a catalog-entry OID and is not a durable ownership token.
	var count int64
	var uuid *string
	err := conn.QueryRow(ctx, `SELECT count(*), min(CAST(table_uuid AS VARCHAR))
 FROM ducklake_table_info('ducklake') WHERE table_name = '`+fixtureName+`'`).Scan(&count, &uuid)
	if err != nil {
		return "", err
	}
	if count != 1 || uuid == nil || *uuid == "" {
		return "", errors.New("fixture identity is absent or ambiguous")
	}
	return *uuid, nil
}

func cleanupFixture(cfg config, ownedUUID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer closeConnection(conn)
	if err := candidateGate(ctx, conn); err != nil {
		return err
	}
	if _, err := conn.Exec(ctx, "BEGIN"); err != nil {
		return err
	}
	defer func() { _, _ = conn.Exec(ctx, "ROLLBACK") }()
	uuid, err := fixtureIdentity(ctx, conn)
	if err != nil {
		return err
	}
	if uuid != ownedUUID {
		return errors.New("fixture identity changed; refusing DROP")
	}
	if _, err := conn.Exec(ctx, "DROP TABLE "+fixtureTable); err != nil {
		return err
	}
	_, err = conn.Exec(ctx, "COMMIT")
	return err
}

func closeConnection(conn *pgx.Conn) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = conn.Close(ctx)
}
