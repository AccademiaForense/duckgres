package manifests_test

import (
	"strings"
	"testing"
)

func TestDefaultDockerfileBuildsCoherentBundle(t *testing.T) {
	dockerfile := readManifest(t, "Dockerfile")
	for _, want := range []string{
		"AS bundle_dependencies", "AS extension_builder",
		"sh /build/candidate/prepare-deps.sh", "sh /build/candidate/prepare-scanner.sh",
		"sh /build/candidate/build-extension.sh",
		"sh /build/candidate/check-pins.sh /build/go.mod",
		"COPY --from=extension_builder /out/ /build/duckdb-extensions/v1.5.5/linux_amd64/",
		"COPY --from=extension_builder /out/native-tests/ /app/ducklake-candidate/native-tests/",
		"COPY --from=extension_builder /out/vcpkg-status.txt /app/ducklake-candidate/vcpkg-status.txt",
		"TestDoCopyFromStdinIngestsPostgresBinaryWithBundledScanner",
	} {
		if !strings.Contains(dockerfile, want) {
			t.Errorf("ordinary Dockerfile must include %q", want)
		}
	}
	for _, forbidden := range []string{
		"HTTPFS_EXTENSION_TAG", "DUCKLAKE_EXTENSION_TAG", "POSTGRES_SCANNER_TAG",
		"extensions.duckdb.org", "curl -fsSL",
	} {
		if strings.Contains(dockerfile, forbidden) {
			t.Errorf("ordinary build must not fall back to old binary downloads: %s", forbidden)
		}
	}
}

func TestBundleBuildUsesSameDependencyStagesAsQualifiedCandidate(t *testing.T) {
	// Dockerfiles cannot include a shared stage definition. Keep the small stage
	// boilerplate identical; actual source fetch/build/test logic is shared code.
	dependencyStages := func(path ...string) string {
		t.Helper()
		content := readManifest(t, path...)
		start := strings.Index(content, "FROM debian:bookworm-slim@sha256:")
		end := strings.Index(content, "ARG PATCH_SHA256")
		if start < 0 || end <= start {
			t.Fatalf("missing pinned bundle dependency stages in %v", path)
		}
		return content[start:end]
	}
	if dependencyStages("Dockerfile") != dependencyStages("scripts", "ducklake-candidate", "Dockerfile") {
		t.Fatal("ordinary and overlay build dependency stages drifted")
	}
}

func TestDockerContextExcludesLocalBuildEvidence(t *testing.T) {
	ignore := readManifest(t, ".dockerignore")
	for _, want := range []string{"artifacts/", "tmp/", "**/node_modules/", ".branch-artifacts/"} {
		found := false
		for _, line := range strings.Split(ignore, "\n") {
			found = found || line == want
		}
		if !found {
			t.Errorf("Docker context must exclude %s", want)
		}
	}
}
