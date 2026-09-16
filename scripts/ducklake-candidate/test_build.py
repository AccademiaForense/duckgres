"""Preflight regressions; Docker is mocked, so these never build or run services."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent


class CandidatePreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ducklake-candidate-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "go.mod").write_text(
            "replace github.com/duckdb/duckdb-go-bindings/lib/linux-amd64 => "
            "github.com/PostHog/duckdb-go-bindings/lib/linux-amd64 v0.10505.0-posthog.3\n"
        )
        self.scripts = self.root / "scripts" / "ducklake-candidate"
        shutil.copytree(SOURCE, self.scripts)
        for name in ("0001-core-expression-map-compatibility.patch", "0002-inline-schema-nullability.patch"):
            patch = self.scripts / "patches" / name
            patch.parent.mkdir(exist_ok=True)
            patch.write_text("test fixture only; never applied or built\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$MOCK_DOCKER_LOG"\n'
            'case "$1 $2" in\n'
            '  "context inspect") printf "%s\\n" "${MOCK_ENDPOINT:-unix:///test/docker.sock}" ;;\n'
            '  "image inspect")\n'
            '    test "${MOCK_MISSING_BASE:-0}" = 0 || exit 1\n'
            '    case "$*" in\n'
            '      *Architecture*) printf "%s\\n" "${MOCK_PLATFORM:-linux/amd64}" ;;\n'
            '      *) printf "sha256:%064d\\n" 1 ;;\n'
            '    esac ;;\n'
            '  *) echo "unexpected Docker mutation" >&2; exit 90 ;;\n'
            'esac\n'
        )
        docker.chmod(0o755)
        self.env = os.environ.copy()
        for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY"):
            self.env.pop(key, None)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.env["MOCK_DOCKER_LOG"] = str(self.root / "docker.log")

    def run_script(self, *args):
        return subprocess.run(
            ["sh", str(self.scripts / "build.sh"), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_rejected(self, args, message):
        result = self.run_script(*args)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.root / "artifacts").exists())

    def test_requires_explicit_base(self):
        self.assert_rejected([], "Usage:")

    def test_rejects_implicit_and_explicit_latest(self):
        for base in ("duckgres", "duckgres:latest"):
            with self.subTest(base=base):
                self.assert_rejected(["--check", base], "explicit non-latest tag")

    def test_requires_different_local_candidate_tag(self):
        self.assert_rejected(
            ["--check", "duckgres:base", "ghcr.io/example/duckgres:latest"],
            "candidate tag must start with duckgres:ducklake-",
        )
        self.assert_rejected(
            ["--check", "duckgres:ducklake-test", "duckgres:ducklake-test"],
            "base and candidate must differ",
        )

    def test_rejects_remote_daemon(self):
        self.env["MOCK_ENDPOINT"] = "ssh://example.invalid"
        self.assert_rejected(["--check", "duckgres:base"], "local Docker endpoint")

    def test_rejects_remote_docker_host_override(self):
        self.env["DOCKER_HOST"] = "tcp://example.invalid:2376"
        self.assert_rejected(["--check", "duckgres:base"], "local Docker endpoint")

    def test_rejects_missing_base_without_pull(self):
        self.env["MOCK_MISSING_BASE"] = "1"
        self.assert_rejected(["--check", "duckgres:base"], "base image must exist locally")

    def test_rejects_wrong_architecture(self):
        self.env["MOCK_PLATFORM"] = "linux/arm64"
        self.assert_rejected(["--check", "duckgres:base"], "linux/amd64")

    def test_requires_patch(self):
        (self.scripts / "patches" / "0002-inline-schema-nullability.patch").unlink()
        self.assert_rejected(["--check", "duckgres:base"], "missing or empty patch")

    def test_rejects_binding_drift(self):
        (self.root / "go.mod").write_text("module example.invalid/other\n")
        self.assert_rejected(["--check", "duckgres:base"], "binding pin does not match")

    def test_rejects_build_version_drift(self):
        pins = self.scripts / "pins.env"
        pins.write_text(pins.read_text().replace("6768849c-inline-null1", "unqualified-build"))
        self.assert_rejected(["--check", "duckgres:base"], "unexpected BUILD_VERSION")

    def test_rejects_httpfs_core_drift(self):
        pins = self.scripts / "pins.env"
        pins.write_text(pins.read_text() + "\nHTTPFS_BUILD_VERSION=stock-core\n")
        self.assert_rejected(["--check", "duckgres:base"], "unexpected HTTPFS_BUILD_VERSION")

    def test_rejects_scanner_core_drift(self):
        pins = self.scripts / "scanner-pins.env"
        pins.write_text(pins.read_text() + "\nPOSTGRES_BUILD_VERSION=stock-core\n")
        self.assert_rejected(["--check", "duckgres:base"], "unexpected POSTGRES_BUILD_VERSION")

    def test_rejects_header_core_drift(self):
        pins = self.scripts / "pins.env"
        pins.write_text(pins.read_text() + "\nDUCKDB_COMMIT=d8cdaa33fda8df955cc76ef58a280f68f4cd43fa\n")
        self.assert_rejected(["--check", "duckgres:base"], "unexpected DuckDB header core")

    def test_patch_digest_covers_order_and_contents(self):
        def digest():
            result = subprocess.run(
                ["sh", str(self.scripts / "patch-digest.sh")],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(len(result.stdout.strip()), 64)
            return result.stdout

        before = digest()
        series = self.scripts / "patches" / "series"
        series.write_text("\n".join(reversed(series.read_text().splitlines())) + "\n")
        reordered = digest()
        self.assertNotEqual(before, reordered)
        patch = self.scripts / "patches" / "0002-inline-schema-nullability.patch"
        patch.write_text("different patch contents\n")
        self.assertNotEqual(reordered, digest())

    def test_rejects_patch_path_traversal(self):
        (self.scripts / "patches" / "series").write_text("../go.mod\n")
        self.assert_rejected(["--check", "duckgres:base"], "invalid patch filename")

    def test_check_only_is_read_only(self):
        result = self.run_script("--check", "duckgres:base")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preflight passed", result.stdout)
        self.assertFalse((self.root / "artifacts").exists())
        calls = (self.root / "docker.log").read_text().splitlines()
        self.assertTrue(calls)
        self.assertTrue(all(c.startswith(("context inspect", "image inspect")) for c in calls))


if __name__ == "__main__":
    unittest.main()
