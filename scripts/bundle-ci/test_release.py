"""Release guards use fake Docker/GitHub CLIs: never publish or run services."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent
IMAGE_ID = "sha256:" + "1" * 64
COMMIT = "a" * 40


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bundle-release-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / "scripts"
        shutil.copytree(SOURCE, self.scripts)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$MOCK_LOG"\n'
            'case "$1 $2" in\n'
            ' "context inspect") echo "${MOCK_ENDPOINT:-unix:///test/docker.sock}" ;;\n'
            ' "image inspect")\n'
            '  case "$*" in *Architecture*) echo linux/amd64 ;; *) echo "$MOCK_IMAGE_ID" ;; esac ;;\n'
            ' "image save") printf "fake-image-archive" > "$4" ;;\n'
            ' "image load") : ;;\n'
            ' "buildx imagetools") printf \'{"digest":"sha256:%064d"}\\n\' 3 ;;\n'
            ' "manifest inspect")\n'
            '  remote="${MOCK_REMOTE:-absent}"\n'
            '  case "$3" in *:sha-???????) remote="${MOCK_SHORT_REMOTE:-$remote}" ;; esac\n'
            '  case "$remote" in\n'
            '   absent) echo "no such manifest: $3" >&2; exit 1 ;;\n'
            '   denied) echo "unauthorized: access denied" >&2; exit 1 ;;\n'
            '   error) printf "%s\\n" "$MOCK_MANIFEST_ERROR" >&2; exit 1 ;;\n'
            '   *) printf \'{"schemaVersion":2,"config":{"digest":"%s"}}\\n\' "$remote" ;;\n'
            '  esac ;;\n'
            ' "tag "*|"push "*) : ;;\n'
            ' *) echo "unexpected Docker call" >&2; exit 90 ;;\n'
            'esac\n'
        )
        docker.chmod(0o755)
        gh = self.bin / "gh"
        gh.write_text('#!/bin/sh\nprintf "%s\\n" "$MOCK_MAIN"\n')
        gh.chmod(0o755)
        self.env = os.environ.copy()
        for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "GITHUB_OUTPUT"):
            self.env.pop(key, None)
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        MOCK_LOG=str(self.root / "docker.log"),
                        MOCK_IMAGE_ID=IMAGE_ID, MOCK_MAIN=COMMIT)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.gate = self.evidence / "qualification.env"
        self.gate.write_text(f"runtime_qualification=PASS_LOCAL_SCOPED\nimage_id={IMAGE_ID}\n")
        self.archive = self.root / "archive"

    def run_script(self, name, *args):
        return subprocess.run(["sh", str(self.scripts / name), *map(str, args)],
                              env=self.env, capture_output=True, text=True, check=False)

    def calls(self):
        path = self.root / "docker.log"
        return path.read_text() if path.exists() else ""

    def export(self):
        result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
        self.assertEqual(result.returncode, 0, result.stderr)
        return hashlib.sha256((self.archive / "image.tar").read_bytes()).hexdigest()

    def test_export_refuses_missing_or_failed_gate(self):
        for content in ("", f"runtime_qualification=FAIL\nimage_id={IMAGE_ID}\n"):
            with self.subTest(content=content):
                self.gate.write_text(content)
                result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("successful runtime qualification required", result.stderr)
                self.assertNotIn("image save", self.calls())

    def test_export_refuses_a_different_image(self):
        self.env["MOCK_IMAGE_ID"] = "sha256:" + "2" * 64
        result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("image identity mismatch", result.stderr)
        self.assertNotIn("image save", self.calls())

    def test_export_refuses_remote_daemon_and_existing_directory(self):
        self.env["MOCK_ENDPOINT"] = "ssh://example.invalid"
        result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local Docker endpoint required", result.stderr)
        self.env.pop("MOCK_ENDPOINT")
        self.archive.mkdir()
        result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive directory must not exist", result.stderr)
        self.assertNotIn("image save", self.calls())

    def test_export_refuses_dangling_archive_symlink_before_docker(self):
        target = self.root / "missing-archive-target"
        self.archive.symlink_to(target, target_is_directory=True)
        self.assertTrue(self.archive.is_symlink())
        self.assertFalse(self.archive.exists())
        result = self.run_script("export.sh", IMAGE_ID, self.evidence, self.archive)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive directory must not exist", result.stderr)
        self.assertEqual(self.calls(), "")
        self.assertTrue(self.archive.is_symlink())
        self.assertEqual(os.readlink(self.archive), str(target))
        self.assertFalse(target.exists())

    def test_archive_roundtrip_requires_job_output_hash_and_image_id(self):
        digest = self.export()
        result = self.run_script("restore.sh", self.archive, digest, IMAGE_ID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("image load", self.calls())

    def test_tampered_archive_is_not_loaded(self):
        digest = self.export()
        (self.archive / "image.tar").write_bytes(b"tampered")
        result = self.run_script("restore.sh", self.archive, digest, IMAGE_ID)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive checksum mismatch", result.stderr)
        self.assertNotIn("image load", self.calls())

    def test_restore_rejects_loaded_image_identity_mismatch(self):
        digest = self.export()
        self.env["MOCK_IMAGE_ID"] = "sha256:" + "2" * 64
        result = self.run_script("restore.sh", self.archive, digest, IMAGE_ID)
        self.assertNotEqual(result.returncode, 0)

    def test_gate_is_data_not_executable_shell(self):
        marker = self.root / "executed"
        self.gate.write_text(self.gate.read_text() + f"touch {marker}\n")
        self.export()
        self.assertFalse(marker.exists())

    def test_publish_tags_checked_image_with_full_and_short_sha(self):
        result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        for tag in ("sha-" + COMMIT, "sha-" + COMMIT[:7], "latest"):
            self.assertIn(f"tag {IMAGE_ID} ghcr.io/example/duckgres:{tag}", self.calls())
            self.assertIn(f"push ghcr.io/example/duckgres:{tag}", self.calls())
        self.assertNotIn("build ", self.calls())
        self.assertIn("ghcr.io/example/duckgres@sha256:", result.stdout)

    def test_publish_wont_overwrite_existing_sha_with_other_image(self):
        self.env["MOCK_REMOTE"] = "sha256:" + "2" * 64
        result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace immutable commit tag", result.stderr)
        self.assertNotIn("push ", self.calls())

    def test_publish_recognizes_manifest_unknown_messages(self):
        self.env["MOCK_REMOTE"] = "error"
        for message in ("manifest unknown", "manifest unknown: manifest unknown"):
            with self.subTest(message=message):
                self.env["MOCK_MANIFEST_ERROR"] = message
                previous_calls = len(self.calls())
                result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()[previous_calls:]
                for tag in ("sha-" + COMMIT, "sha-" + COMMIT[:7], "latest"):
                    self.assertIn(f"tag {IMAGE_ID} ghcr.io/example/duckgres:{tag}", calls)
                    self.assertIn(f"push ghcr.io/example/duckgres:{tag}", calls)
                self.assertNotIn("build ", calls)

    def test_publish_refuses_registry_errors(self):
        self.env["MOCK_REMOTE"] = "error"
        for message in (
            "unauthorized: access denied",
            "denied: permission_denied: read_package",
            "failed to fetch anonymous token: 401 Unauthorized",
            "403 Forbidden",
            "dial tcp: lookup ghcr.io: no such host",
            "net/http: TLS handshake timeout",
            "x509: certificate signed by unknown authority",
            "unexpected status: 429 Too Many Requests",
            "unexpected status: 503 Service Unavailable",
            "",
            "no such manifest: ghcr.io/example/duckgres:another-tag",
            "unexpected proxy error: manifest unknown: manifest unknown",
            "unauthorized: access denied\nmanifest unknown",
            "manifest unknown: manifest unknown\n503 Service Unavailable",
            f"no such manifest: ghcr.io/example/duckgres:sha-{COMMIT}\nunauthorized",
        ):
            with self.subTest(message=message):
                self.env["MOCK_MANIFEST_ERROR"] = message
                previous_calls = len(self.calls())
                result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot establish registry state", result.stderr)
                calls = self.calls()[previous_calls:]
                self.assertNotIn("tag ", calls)
                self.assertNotIn("push ", calls)

    def test_publish_checks_short_tag_before_any_write(self):
        self.env["MOCK_REMOTE"] = "absent"
        self.env["MOCK_MANIFEST_ERROR"] = "unauthorized: access denied"
        for remote, error in (
            ("error", "cannot establish registry state"),
            ("sha256:" + "2" * 64, "refusing to replace immutable commit tag"),
        ):
            with self.subTest(remote=remote):
                self.env["MOCK_SHORT_REMOTE"] = remote
                previous_calls = len(self.calls())
                result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                calls = self.calls()[previous_calls:]
                for tag in ("sha-" + COMMIT, "sha-" + COMMIT[:7]):
                    self.assertIn(f"manifest inspect ghcr.io/example/duckgres:{tag}", calls)
                self.assertNotIn("tag ", calls)
                self.assertNotIn("push ", calls)

    def test_publish_old_commit_does_not_move_latest_backwards(self):
        self.env["MOCK_MAIN"] = "b" * 40
        result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("push ghcr.io/example/duckgres:latest", self.calls())

    def test_publish_same_image_is_idempotent_for_sha_tags(self):
        self.env["MOCK_REMOTE"] = IMAGE_ID
        result = self.run_script("publish.sh", IMAGE_ID, "Example/duckgres", COMMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("push ghcr.io/example/duckgres:sha-", self.calls())


if __name__ == "__main__":
    unittest.main()
