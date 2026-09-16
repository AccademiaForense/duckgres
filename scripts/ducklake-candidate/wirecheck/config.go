package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type config struct {
	host, user, password, database string
	port                           uint16
}

func configFromEnv(env []string) (config, error) {
	values := make(map[string]string)
	for _, entry := range env {
		name, value, _ := strings.Cut(entry, "=")
		if value != "" && (strings.HasPrefix(name, "PG") || name == "DUCKGRES_BUNDLE_TEST_DSN" || name == "DUCKGRES_BUNDLE_TEST_URL") {
			return config{}, fmt.Errorf("unset %s: ambient connection overrides are forbidden", name)
		}
		values[name] = value
	}
	get := func(name string) string { return values["DUCKGRES_BUNDLE_TEST_"+name] }
	c := config{host: get("HOST"), user: get("USER"), password: get("PASSWORD"), database: get("DATABASE")}
	if c.host != "127.0.0.1" {
		return config{}, errors.New("DUCKGRES_BUNDLE_TEST_HOST must be explicitly 127.0.0.1")
	}
	port, err := strconv.ParseUint(get("PORT"), 10, 16)
	if err != nil || port == 0 || port == 5432 || strconv.FormatUint(port, 10) != get("PORT") {
		return config{}, errors.New("DUCKGRES_BUNDLE_TEST_PORT must be an explicit canonical port in 1..65535, excluding 5432")
	}
	c.port = uint16(port)
	if c.user != "ducklake" || c.database != "ducklake" {
		return config{}, errors.New("DUCKGRES_BUNDLE_TEST_USER and DATABASE must both be explicitly ducklake")
	}
	if strings.TrimSpace(c.password) == "" {
		return config{}, errors.New("DUCKGRES_BUNDLE_TEST_PASSWORD must be explicitly non-empty")
	}
	return c, nil
}

func (c config) connectionConfig() (*pgx.ConnConfig, error) {
	// No user-provided DSN, .pgpass password, TLS files, or ambient PG* options.
	// configFromEnv has already rejected all non-empty PG* variables.
	pc, err := pgx.ParseConfig("host=127.0.0.1 port=1 user=ducklake dbname=ducklake password=unused-fixture sslmode=disable connect_timeout=10")
	if err != nil {
		return nil, errors.New("cannot initialize isolated fixture connection configuration")
	}
	pc.Host, pc.Port, pc.User, pc.Database, pc.Password = c.host, c.port, c.user, c.database, c.password
	pc.Fallbacks = nil
	// The dedicated loopback fixture uses a self-signed certificate. No plaintext fallback.
	pc.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true} //nolint:gosec // Loopback fixture only.
	pc.RuntimeParams = map[string]string{"application_name": "duckgres_bundle_wirecheck"}
	pc.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	address := net.JoinHostPort(c.host, strconv.Itoa(int(c.port)))
	pc.DialFunc = func(ctx context.Context, network, target string) (net.Conn, error) {
		if network != "tcp" || target != address {
			return nil, errors.New("refusing non-fixture dial target")
		}
		return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, target)
	}
	return pc, nil
}
