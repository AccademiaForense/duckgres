package main

import (
	"encoding/binary"
	"math"
	"time"
)

const fixtureName = "__duckgres_bundle_binary_copy_wirecheck"
const fixtureTable = "ducklake.main." + fixtureName

const createSQL = `CREATE TABLE ` + fixtureTable + ` (
 id BIGINT, untouched TEXT DEFAULT 'kept', label TEXT, payload BYTEA,
 enabled BOOLEAN, ratio DOUBLE PRECISION, event_date DATE,
 event_time TIMESTAMP, received_at TIMESTAMPTZ)`

const copySQL = `COPY ` + fixtureTable + `
 (label, id, payload, enabled, ratio, event_date, event_time, received_at)
 FROM STDIN (FORMAT BINARY)`

const verifyRowsSQL = `SELECT count(*) = 3
 AND count(*) FILTER (WHERE id = 42 AND untouched = 'kept'
  AND label = 'Costituzione – libertà ⚖' AND hex(payload) = '005C2EFF'
  AND enabled = true AND ratio = -123.5 AND event_date = DATE '1999-12-31'
  AND event_time = TIMESTAMP '1999-12-31 23:59:59.999999'
  AND received_at = TIMESTAMPTZ '2000-01-01 00:00:01.000001+00') = 1
 AND count(*) FILTER (WHERE id = -7 AND untouched = 'kept' AND label IS NULL
  AND payload IS NULL AND enabled IS NULL AND ratio IS NULL AND event_date IS NULL
  AND event_time IS NULL AND received_at IS NULL) = 1
 AND count(*) FILTER (WHERE id = 99 AND untouched = 'kept' AND label = ''
  AND octet_length(payload) = 0 AND enabled = false AND ratio = 0
  AND event_date = DATE '2000-01-01' AND event_time = TIMESTAMP '2000-01-01 00:00:00'
  AND received_at = TIMESTAMPTZ '2024-02-29 12:34:56.123456+00') = 1
 FROM ` + fixtureTable

func int64Bytes(value int64) []byte { return binary.BigEndian.AppendUint64(nil, uint64(value)) }
func int32Bytes(value int32) []byte { return binary.BigEndian.AppendUint32(nil, uint32(value)) }

func fixturePayload() []byte {
	epoch := time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
	recent := time.Date(2024, 2, 29, 12, 34, 56, 123456000, time.UTC)
	rows := [][][]byte{
		{[]byte("Costituzione – libertà ⚖"), int64Bytes(42), {0x00, '\\', '.', 0xff}, {1},
			binary.BigEndian.AppendUint64(nil, math.Float64bits(-123.5)), int32Bytes(-1), int64Bytes(-1), int64Bytes(1_000_001)},
		{nil, int64Bytes(-7), nil, nil, nil, nil, nil, nil},
		{{}, int64Bytes(99), {}, {0}, binary.BigEndian.AppendUint64(nil, math.Float64bits(0)),
			int32Bytes(0), int64Bytes(0), int64Bytes(recent.Sub(epoch).Microseconds())},
	}
	data := append([]byte("PGCOPY\n\xff\r\n\x00"), make([]byte, 8)...)
	for _, row := range rows {
		data = binary.BigEndian.AppendUint16(data, uint16(len(row)))
		for _, field := range row {
			if field == nil {
				data = binary.BigEndian.AppendUint32(data, math.MaxUint32)
				continue
			}
			data = binary.BigEndian.AppendUint32(data, uint32(len(field)))
			data = append(data, field...)
		}
	}
	return binary.BigEndian.AppendUint16(data, math.MaxUint16)
}
