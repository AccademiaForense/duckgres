package transpiler

import (
	"reflect"
	"testing"
)

// Dropping an enforced NOT NULL constraint must reach the engine. A successful
// no-op leaves schema migrations reporting success while NULL inserts fail.
func TestTranspile_DDL_DropNotNull(t *testing.T) {
	for _, profile := range []struct {
		name     string
		lakeMode bool
	}{{"memory", false}, {"ducklake", true}} {
		tr := New(Config{DuckLakeMode: profile.lakeMode})
		for _, query := range []string{
			"ALTER TABLE documents ALTER COLUMN effective_on DROP NOT NULL",
			"ALTER TABLE ducklake.archive.documents ALTER COLUMN effective_on DROP NOT NULL",
			`ALTER TABLE "Document Archive"."Raw Documents" ALTER COLUMN "Effective On" DROP NOT NULL`,
			"ALTER TABLE IF EXISTS documents ALTER COLUMN effective_on DROP NOT NULL",
		} {
			t.Run(profile.name+"/"+query, func(t *testing.T) {
				result, err := tr.Transpile(query)
				if err != nil {
					t.Fatal(err)
				}
				if result.Error != nil || result.IsNoOp {
					t.Fatalf("DROP NOT NULL must execute: error=%v, no-op=%v", result.Error, result.IsNoOp)
				}
				if result.SQL != query {
					t.Errorf("SQL = %q, want %q", result.SQL, query)
				}
				if len(result.Statements) != 0 {
					t.Errorf("single ALTER unexpectedly split into %v", result.Statements)
				}
			})
		}
	}
}

func TestTranspile_DDL_DropNotNullMultiAlter(t *testing.T) {
	tr := New(Config{DuckLakeMode: true})
	result, err := tr.Transpile(`ALTER TABLE ducklake.archive.documents
		ALTER COLUMN effective_on DROP NOT NULL,
		ADD COLUMN source_id TEXT,
		ALTER COLUMN received_on DROP NOT NULL`)
	if err != nil {
		t.Fatal(err)
	}
	if result.Error != nil || result.IsNoOp {
		t.Fatalf("multi-ALTER must execute: error=%v, no-op=%v", result.Error, result.IsNoOp)
	}
	want := []string{
		"BEGIN",
		"ALTER TABLE ducklake.archive.documents ALTER COLUMN effective_on DROP NOT NULL",
		"ALTER TABLE ducklake.archive.documents ADD COLUMN IF NOT EXISTS source_id text",
		"ALTER TABLE ducklake.archive.documents ALTER COLUMN received_on DROP NOT NULL",
	}
	if !reflect.DeepEqual(result.Statements, want) {
		t.Errorf("statements = %q, want %q", result.Statements, want)
	}
	if !reflect.DeepEqual(result.CleanupStatements, []string{"COMMIT"}) {
		t.Errorf("cleanup = %q, want COMMIT", result.CleanupStatements)
	}
}

func TestTranspile_DDL_DropNotNullSurvivesUnsupportedAlter(t *testing.T) {
	tr := New(Config{DuckLakeMode: true})
	result, err := tr.Transpile(`ALTER TABLE documents
		ADD CONSTRAINT documents_pk PRIMARY KEY (id),
		ALTER COLUMN effective_on DROP NOT NULL`)
	if err != nil {
		t.Fatal(err)
	}
	if result.Error != nil || result.IsNoOp {
		t.Fatalf("supported ALTER must execute: error=%v, no-op=%v", result.Error, result.IsNoOp)
	}
	want := "ALTER TABLE documents ALTER COLUMN effective_on DROP NOT NULL"
	if result.SQL != want || len(result.Statements) != 0 {
		t.Errorf("SQL = %q, statements = %q; want single %q", result.SQL, result.Statements, want)
	}
}
