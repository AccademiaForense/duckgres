package integration

import (
	"strings"
	"testing"
)

// Exercise the migration's effect, not only ALTER's command-complete response.
// In DuckLake mode the old transpiler returned success while leaving NOT NULL
// enforced, so the subsequent NULL write failed.
func TestDDLDropNotNull(t *testing.T) {
	if !testHarness.useDuckLake {
		t.Skip("DROP NOT NULL regression requires the DuckLake DDL policy and catalog")
	}
	for _, multi := range []bool{false, true} {
		name := "single"
		if multi {
			name = "multi_alter"
		}
		t.Run(name, func(t *testing.T) {
			db := testHarness.DuckgresDB
			const table = "ducklake.main.ddl_drop_not_null"
			mustExec(t, db, "CREATE TABLE "+table+" (id INTEGER, effective_on DATE NOT NULL, payload VARCHAR)")
			t.Cleanup(func() { mustExec(t, db, "DROP TABLE IF EXISTS "+table) })
			mustExec(t, db, `CALL ducklake_set_option('ducklake', 'data_inlining_row_limit', 100,
				schema => 'main', table_name => 'ddl_drop_not_null')`)
			mustExec(t, db, "INSERT INTO "+table+" VALUES (1, DATE '2000-01-01', 'before migration')")

			readNullable := func() string {
				t.Helper()
				var got string
				// The PostgreSQL compatibility view publishes DuckLake's main
				// schema as public, even when DDL uses the physical main name.
				err := db.QueryRow(`SELECT is_nullable FROM information_schema.columns
					WHERE table_catalog = 'ducklake' AND table_schema = 'public'
					AND table_name = 'ddl_drop_not_null'
					AND column_name = 'effective_on'`).Scan(&got)
				if err != nil {
					t.Fatalf("read is_nullable: %v", err)
				}
				return got
			}
			assertNullable := func(want string) {
				t.Helper()
				if got := readNullable(); got != want {
					t.Fatalf("is_nullable = %q; want %q", got, want)
				}
			}
			assertNullable("NO")
			if _, err := db.Exec("INSERT INTO " + table + " VALUES (2, NULL, 'must fail before migration')"); err == nil || !strings.Contains(err.Error(), "NOT NULL") {
				t.Fatalf("fixture must enforce NOT NULL before migration, got %v", err)
			}

			alter := "ALTER TABLE " + table + " ALTER COLUMN effective_on DROP NOT NULL"
			if multi {
				alter += ", ADD COLUMN source_id VARCHAR"
			}
			// A retryable migration checks metadata and skips DDL once nullable;
			// the native DROP command itself is not idempotent.
			migrate := func() bool {
				t.Helper()
				switch got := readNullable(); got {
				case "YES":
					return false
				case "NO":
					mustExec(t, db, alter)
					assertNullable("YES")
					return true
				default:
					t.Fatalf("unexpected is_nullable = %q", got)
					return false
				}
			}
			if !migrate() || migrate() {
				t.Fatal("conditional migration must apply once, then skip DDL")
			}
			if _, err := db.Exec("ALTER TABLE " + table + " ALTER COLUMN effective_on DROP NOT NULL"); err == nil || !strings.Contains(err.Error(), "no NOT NULL constraint") {
				t.Fatalf("repeated native DROP must preserve engine error, got %v", err)
			}
			mustExec(t, db, "INSERT INTO "+table+" (id, effective_on, payload) VALUES (2, NULL, 'after migration')")
			if multi {
				mustExec(t, db, "UPDATE "+table+" SET source_id = 'new column' WHERE id = 2")
			}
			// A nullable catalog and successful INSERT are not sufficient: older
			// DuckLake builds retain the old inlined-data schema (upstream #1383).
			mustExec(t, db, `CALL ducklake_flush_inlined_data('ducklake',
				table_name => 'ddl_drop_not_null', schema_name => 'main')`)
			var rows, populated int
			if err := db.QueryRow("SELECT count(*), count(effective_on) FROM "+table).Scan(&rows, &populated); err != nil {
				t.Fatal(err)
			}
			if rows != 2 || populated != 1 {
				t.Fatalf("rows=%d, non-NULL dates=%d; want 2, 1", rows, populated)
			}
			var original, originalDate string
			if err := db.QueryRow("SELECT payload, effective_on::VARCHAR FROM "+table+" WHERE id = 1").Scan(&original, &originalDate); err != nil || original != "before migration" || originalDate != "2000-01-01" {
				t.Fatalf("original payload=%q, date=%q, err=%v", original, originalDate, err)
			}
			if _, err := db.Exec("ALTER TABLE " + table + " ALTER COLUMN absent_column DROP NOT NULL"); err == nil || !strings.Contains(err.Error(), "absent_column") {
				t.Fatalf("missing column must preserve engine error, got %v", err)
			}
		})
	}
}
