package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"math"
	"os"
	"strings"
	"testing"
	"time"
)

func TestBinaryFixturePreservesNullAndEmptyAndEpochValues(t *testing.T) {
	input := bytes.NewReader(fixturePayload())
	header := make([]byte, 19)
	if _, err := io.ReadFull(input, header); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(header, append([]byte("PGCOPY\n\xff\r\n\x00"), make([]byte, 8)...)) {
		t.Fatal("invalid PostgreSQL binary COPY header")
	}
	var rows [][][]byte
	for {
		var columns int16
		if err := binary.Read(input, binary.BigEndian, &columns); err != nil {
			t.Fatal(err)
		}
		if columns == -1 {
			break
		}
		if columns != 8 {
			t.Fatalf("column count = %d, expected 8", columns)
		}
		row := make([][]byte, columns)
		for i := range row {
			var length int32
			if err := binary.Read(input, binary.BigEndian, &length); err != nil {
				t.Fatal(err)
			}
			if length == -1 {
				continue
			}
			if length < 0 || int(length) > input.Len() {
				t.Fatal("invalid field length")
			}
			row[i] = make([]byte, length)
			if _, err := io.ReadFull(input, row[i]); err != nil {
				t.Fatal(err)
			}
		}
		rows = append(rows, row)
	}
	if len(rows) != 3 || input.Len() != 0 {
		t.Fatal("expected exactly three rows and a final trailer")
	}
	if string(rows[0][0]) != "Costituzione – libertà ⚖" || !bytes.Equal(rows[0][2], []byte{0, '\\', '.', 255}) {
		t.Fatal("UTF-8 or arbitrary BLOB bytes changed")
	}
	for i, id := range []int64{42, -7, 99} {
		if int64(binary.BigEndian.Uint64(rows[i][1])) != id {
			t.Fatal("signed BIGINT changed")
		}
	}
	for i, value := range rows[1] {
		if i != 1 && value != nil {
			t.Fatal("NULL encoded as a non-NULL field")
		}
	}
	if rows[2][0] == nil || rows[2][2] == nil || len(rows[2][0]) != 0 || len(rows[2][2]) != 0 {
		t.Fatal("empty text/BLOB encoded as NULL")
	}
	if rows[0][3][0] != 1 || rows[2][3][0] != 0 || math.Float64frombits(binary.BigEndian.Uint64(rows[0][4])) != -123.5 {
		t.Fatal("BOOLEAN or DOUBLE encoding changed")
	}
	if int32(binary.BigEndian.Uint32(rows[0][5])) != -1 || int64(binary.BigEndian.Uint64(rows[0][6])) != -1 || int64(binary.BigEndian.Uint64(rows[0][7])) != 1_000_001 {
		t.Fatal("date/timestamp PostgreSQL epoch encoding changed")
	}
	recentMicros := int64(binary.BigEndian.Uint64(rows[2][7]))
	got := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC).Add(time.Duration(recentMicros) * time.Microsecond)
	if got.Format("2006-01-02 15:04:05.999999Z07:00") != "2024-02-29 12:34:56.123456Z" {
		t.Fatal("modern timestamp precision changed")
	}
}

func TestConnectionConfigCannotFallbackOrDialElsewhere(t *testing.T) {
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "PG") {
			t.Setenv(name, "")
		}
	}
	cfg, err := configFromEnv(fixtureEnv())
	if err != nil {
		t.Fatal(err)
	}
	pc, err := cfg.connectionConfig()
	if err != nil {
		t.Fatal(err)
	}
	if pc.Host != "127.0.0.1" || pc.Port != 32770 || pc.TLSConfig == nil || len(pc.Fallbacks) != 0 {
		t.Fatal("fixture connection target/TLS/fallback guard missing")
	}
	if pc.Password != cfg.password || strings.Contains(pc.ConnString(), cfg.password) {
		t.Fatal("password was lost or included in diagnostic connection string")
	}
	for _, target := range []struct{ network, address string }{
		{"tcp", "127.0.0.1:5432"}, {"tcp", "example.test:32770"}, {"tcp", "127.0.0.2:32770"}, {"unix", "/tmp/.s.PGSQL.32770"},
	} {
		if _, err := pc.DialFunc(context.Background(), target.network, target.address); err == nil {
			t.Fatal("unexpected dial target accepted")
		}
	}
}
