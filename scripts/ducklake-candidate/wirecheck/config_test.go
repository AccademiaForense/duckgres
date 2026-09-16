package main

import (
	"slices"
	"strings"
	"testing"
)

func fixtureEnv() []string {
	return []string{
		"DUCKGRES_BUNDLE_TEST_HOST=127.0.0.1",
		"DUCKGRES_BUNDLE_TEST_PORT=32770",
		"DUCKGRES_BUNDLE_TEST_USER=ducklake",
		"DUCKGRES_BUNDLE_TEST_PASSWORD=fixture-password",
		"DUCKGRES_BUNDLE_TEST_DATABASE=ducklake",
	}
}

func replaceEnv(env []string, name, value string) []string {
	env = slices.DeleteFunc(slices.Clone(env), func(entry string) bool {
		return strings.HasPrefix(entry, name+"=")
	})
	return append(env, name+"="+value)
}

func TestConfigAcceptsOnlyExplicitLocalFixture(t *testing.T) {
	got, err := configFromEnv(fixtureEnv())
	if err != nil {
		t.Fatal(err)
	}
	want := config{"127.0.0.1", "ducklake", "fixture-password", "ducklake", 32770}
	if got != want {
		t.Fatal("configuration differs from explicit local fixture")
	}
}

func TestConfigRejectsMissingFixtureInputs(t *testing.T) {
	for _, entry := range fixtureEnv() {
		name, _, _ := strings.Cut(entry, "=")
		t.Run(name, func(t *testing.T) {
			if _, err := configFromEnv(replaceEnv(fixtureEnv(), name, "")); err == nil {
				t.Fatal("missing fixture input accepted")
			}
		})
	}
}

func TestConfigRejectsUnsafeEndpointOrCredentials(t *testing.T) {
	cases := map[string][]string{
		"HOST":     {"localhost", "::1", "/tmp", "127.0.0.1,example.test", "example.test", "127.0.0.2", " 127.0.0.1"},
		"PORT":     {"5432", "0", "65536", "-1", "+32770", "032770", "32770 ", "abc", "32770,5432"},
		"USER":     {"postgres", "ducklake ", "ducklake host=example.test"},
		"PASSWORD": {" ", "\t"},
		"DATABASE": {"postgres", "ducklake ", "ducklake sslmode=disable"},
	}
	for key, values := range cases {
		for _, value := range values {
			t.Run(key+"/"+value, func(t *testing.T) {
				_, err := configFromEnv(replaceEnv(fixtureEnv(), "DUCKGRES_BUNDLE_TEST_"+key, value))
				if err == nil {
					t.Fatal("unsafe fixture input accepted")
				}
				if key == "PASSWORD" && strings.Contains(err.Error(), "fixture-password") {
					t.Fatal("configuration error disclosed password")
				}
			})
		}
	}
}

func TestConfigKeepsExplicitPasswordVerbatim(t *testing.T) {
	password := "fixture ' \\ = value"
	got, err := configFromEnv(replaceEnv(fixtureEnv(), "DUCKGRES_BUNDLE_TEST_PASSWORD", password))
	if err != nil || got.password != password {
		t.Fatal("explicit non-empty password was not preserved")
	}
}

func TestConfigRejectsLibpqEnvironmentAndGenericDSN(t *testing.T) {
	for _, name := range []string{"PGHOST", "PGPORT", "PGSERVICE", "PGOPTIONS", "PGPASSFILE", "PGSSLCERT", "PGUNKNOWN", "DUCKGRES_BUNDLE_TEST_DSN", "DUCKGRES_BUNDLE_TEST_URL"} {
		t.Run(name, func(t *testing.T) {
			if _, err := configFromEnv(append(fixtureEnv(), name+"=unsafe")); err == nil {
				t.Fatal("ambient connection override accepted")
			}
		})
	}
}
