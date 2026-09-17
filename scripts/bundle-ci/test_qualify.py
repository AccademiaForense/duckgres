"""Database-free guard regressions; every Docker command is mocked."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent
IMAGE_ID = "sha256:" + "a" * 64


class QualificationGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bundle-ci-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.evidence = self.root / "evidence"
        bindir = self.root / "bin"
        bindir.mkdir()
        docker = bindir / "docker"
        docker.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$MOCK_LOG"\n'
            'case "$1 $2" in\n'
            ' "context inspect") echo "${MOCK_ENDPOINT:-unix:///fixture/docker.sock}" ;;\n'
            ' "image inspect")\n'
            '  [ "${MOCK_MISSING:-0}" = 0 ] || exit 1\n'
            '  case "$*" in\n'
            '   *Architecture*) echo "${MOCK_PLATFORM:-linux/amd64}" ;;\n'
            '   *Config.Volumes*) printf "%s\\n" "${MOCK_VOLUMES:-null}" ;;\n'
            '   *) echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;\n'
            '  esac ;;\n'
            ' *) echo "unexpected Docker mutation" >&2; exit 90 ;;\n'
            'esac\n'
        )
        docker.chmod(0o755)
        for name in ("go", "psql", "just"):
            tool = bindir / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("PG", "DUCKGRES_BUNDLE_TEST_", "DOCKER_"))}
        self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]
        self.env["MOCK_LOG"] = str(self.root / "docker.log")

    def run_check(self, *args):
        return subprocess.run(["sh", str(SOURCE / "qualify.sh"), *args],
                              env=self.env, capture_output=True, text=True, check=False)

    def reject(self, *args, message):
        result = self.run_check(*args)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.evidence / "qualification.env").exists())

    def test_requires_image_and_evidence(self):
        for args in ((), ("duckgres:fixture",), ("one", "two", "three")):
            with self.subTest(args=args):
                self.reject(*args, message="Usage:")

    def test_rejects_implicit_latest_and_invalid_images(self):
        for image in ("duckgres", "duckgres:latest", "--help", "sha256:abc", "x:tag;false"):
            with self.subTest(image=image):
                self.reject("--check", image, str(self.evidence), message="image")

    def test_accepts_tag_or_full_id_without_mutation(self):
        for image in ("duckgres:bundle-ci", IMAGE_ID):
            with self.subTest(image=image):
                result = self.run_check("--check", image, str(self.evidence))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(IMAGE_ID, result.stdout)
                self.assertFalse(self.evidence.exists())
        calls = Path(self.env["MOCK_LOG"]).read_text().splitlines()
        self.assertTrue(all(c.startswith(("context inspect", "image inspect")) for c in calls))

    def test_rejects_remote_daemon(self):
        for name, value in (("DOCKER_HOST", "ssh://example.invalid"),
                            ("DOCKER_HOST", "tcp://127.0.0.1:2375"),
                            ("MOCK_ENDPOINT", "ssh://example.invalid")):
            with self.subTest(name=name, value=value):
                self.env[name] = value
                self.reject("--check", "duckgres:fixture", str(self.evidence), message="local Docker")
                self.env.pop(name)

    def test_rejects_missing_or_wrong_arch_image_without_pull(self):
        self.env["MOCK_MISSING"] = "1"
        self.reject("--check", "duckgres:fixture", str(self.evidence), message="locally")
        self.env.pop("MOCK_MISSING")
        self.env["MOCK_PLATFORM"] = "linux/arm64"
        self.reject("--check", "duckgres:fixture", str(self.evidence), message="linux/amd64")
        calls = Path(self.env["MOCK_LOG"]).read_text()
        self.assertNotIn("pull", calls)

    def test_rejects_nonempty_file_and_symlink_evidence(self):
        self.evidence.mkdir()
        (self.evidence / "existing").write_text("preserve me")
        self.reject("--check", "duckgres:fixture", str(self.evidence), message="empty")
        self.assertEqual((self.evidence / "existing").read_text(), "preserve me")
        file_path = self.root / "file"
        file_path.write_text("preserve me")
        self.reject("--check", "duckgres:fixture", str(file_path), message="directory")
        link = self.root / "link"
        link.symlink_to(self.evidence, target_is_directory=True)
        self.reject("--check", "duckgres:fixture", str(link), message="symlink")

    def test_rejects_ambient_connections(self):
        for name in ("PGHOST", "PGSERVICE", "PGOPTIONS", "DUCKGRES_BUNDLE_TEST_PORT", "DUCKGRES_BUNDLE_TEST_DSN"):
            with self.subTest(name=name):
                self.env[name] = "unsafe"
                self.reject("--check", "duckgres:fixture", str(self.evidence), message="ambient")
                self.env.pop(name)

    def test_rejects_implicit_image_volumes(self):
        self.env["MOCK_VOLUMES"] = '{"/data":{}}'
        self.reject("--check", "duckgres:fixture", str(self.evidence), message="volumes")

    def test_requires_absolute_evidence_path(self):
        self.reject("--check", "duckgres:fixture", "relative-evidence", message="absolute")

    def test_check_does_not_require_just_on_ci_host(self):
        bindir = self.root / "bin"
        (bindir / "just").unlink()
        for tool in ("dirname", "env", "grep"):
            (bindir / tool).symlink_to(shutil.which(tool))
        self.env["PATH"] = str(bindir)
        result = subprocess.run(["/bin/sh", str(SOURCE / "qualify.sh"), "--check",
                                 "duckgres:fixture", str(self.evidence)],
                                env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)



if __name__ == "__main__":
    from test_qualify_lifecycle import LifecycleGuards

    unittest.main()
