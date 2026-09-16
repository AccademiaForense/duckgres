"""Database-free lifecycle ownership and readiness regressions."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class LifecycleGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bundle-ci-cleanup-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, TEST_SOURCE=str(SOURCE), TEST_EVIDENCE=str(self.root))

    def run_shell(self, script):
        return subprocess.run(["sh", "-c", '''
set -eu
evidence=$TEST_EVIDENCE
owner=fixture-owner
. "$TEST_SOURCE/preflight.sh"
. "$TEST_SOURCE/lifecycle.sh"
docker() {
    printf '%s\\n' "$*" >>"$evidence/docker.log"
    case "$1 $2" in
        "inspect --format"|"network inspect") printf '%s\\n' "${TEST_LABEL:-fixture-owner}" ;;
        "rm -f"|"network rm") ;;
        *) return 90 ;;
    esac
}
''' + script], env=self.env, capture_output=True, text=True, check=False)

    def test_cleanup_removes_only_recorded_labeled_ids(self):
        ids = {name: char * 64 for name, char in
               (("duckgres", "a"), ("postgres", "b"), ("minio", "c"), ("network", "d"))}
        for name, value in ids.items():
            (self.root / (name + ".id")).write_text(value + "\n")
        result = self.run_shell("cleanup_owned")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "docker.log").read_text().splitlines()
        mutations = [call for call in calls if call.startswith(("rm ", "network rm "))]
        self.assertEqual(mutations, ["rm -f " + ids[n] for n in ("duckgres", "postgres", "minio")]
                         + ["network rm " + ids["network"]])

    def test_cleanup_refuses_foreign_or_invalid_ids(self):
        for value in ("a" * 64, "some-container-name"):
            with self.subTest(value=value):
                (self.root / "duckgres.id").write_text(value + "\n")
                self.env["TEST_LABEL"] = "somebody-else"
                result = self.run_shell("cleanup_owned")
                self.assertNotEqual(result.returncode, 0)
                calls = (self.root / "docker.log").read_text()
                self.assertNotIn("rm -f", calls)

    def test_pull_allowlist_rejects_any_other_image_before_docker(self):
        result = self.run_shell('''
. "$TEST_SOURCE/fixture-pins.env"
fixture_image postgres:latest
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unapproved fixture", result.stderr)
        self.assertFalse((self.root / "docker.log").exists())

    def test_postgres_readiness_requires_final_tcp_listener(self):
        result = self.run_shell('''
postgres_id=postgres
minio_id=minio
docker() { case "$*" in
    "exec postgres pg_isready -h 127.0.0.1 -U ducklake -d ducklake") return 0 ;;
    "exec minio curl "*) return 0 ;;
    *) return 90 ;;
esac; }
fixtures_ready
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bridge_allows_loopback_publishing_without_internal_mode(self):
        result = self.run_shell('''
docker() {
    [ "$*" = "network create --driver bridge --opt com.docker.network.bridge.host_binding_ipv4=127.0.0.1 --label org.duckgres.bundle-ci=fixture-owner duckgres-bundle-fixture-owner" ] || return 90
    printf '%064d\\n' 1
}
create_network
[ "$network_id" = "$(printf '%064d' 1)" ]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wire_port_rejects_non_loopback_or_multiple_bindings(self):
        for binding in ("0.0.0.0:32000", "127.0.0.1:5432", "127.0.0.1:0",
                        "127.0.0.1:32000\n[::]:32000"):
            with self.subTest(binding=binding):
                self.env["TEST_BINDING"] = binding
                result = self.run_shell('''
. "$TEST_SOURCE/sql.sh"
duckgres_id=fixture
assert_owned_container() { :; }
docker() { printf '%s\\n' "$TEST_BINDING"; }
discover_port
''')
                self.assertNotEqual(result.returncode, 0)
