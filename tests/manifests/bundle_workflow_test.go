package manifests_test

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

type imageWorkflow struct {
	On          map[string]any    `yaml:"on"`
	Permissions map[string]string `yaml:"permissions"`
	Jobs        map[string]struct {
		If          string            `yaml:"if"`
		Needs       string            `yaml:"needs"`
		Permissions map[string]string `yaml:"permissions"`
		Steps       []struct {
			ID              string            `yaml:"id"`
			If              string            `yaml:"if"`
			Uses            string            `yaml:"uses"`
			Run             string            `yaml:"run"`
			With            map[string]string `yaml:"with"`
			ContinueOnError bool              `yaml:"continue-on-error"`
		} `yaml:"steps"`
	} `yaml:"jobs"`
}

func readImageWorkflow(t *testing.T) imageWorkflow {
	t.Helper()
	var workflow imageWorkflow
	if err := yaml.Unmarshal([]byte(readManifest(t, ".github", "workflows", "duckgres-image.yml")), &workflow); err != nil {
		t.Fatal(err)
	}
	return workflow
}

func TestBundleWorkflowValidatesWithoutRegistryWrites(t *testing.T) {
	w := readImageWorkflow(t)
	if _, ok := w.On["pull_request"]; !ok {
		t.Error("pull requests must validate the bundle")
	}
	if _, ok := w.On["pull_request_target"]; ok {
		t.Error("untrusted checkout must not run on pull_request_target")
	}
	if w.Permissions["contents"] != "read" || w.Permissions["packages"] == "write" {
		t.Error("workflow default token must not publish packages")
	}
	job, ok := w.Jobs["validate"]
	if !ok {
		t.Fatal("missing independent validate job")
	}
	if job.Permissions["packages"] == "write" {
		t.Error("validate job must not publish packages")
	}
	buildAt, qualifyAt, exportAt := -1, -1, -1
	for i, step := range job.Steps {
		if step.ContinueOnError {
			t.Error("validation errors must not be ignored")
		}
		if strings.Contains(step.Uses, "login-action") || strings.Contains(step.Run, "docker push") {
			t.Error("validation must not log into or push to a registry")
		}
		if strings.HasPrefix(step.Uses, "docker/build-push-action@") {
			buildAt = i
			if step.With["push"] != "false" || step.With["load"] != "true" || step.With["platforms"] != "linux/amd64" {
				t.Error("load the single-architecture image locally without publishing")
			}
			if step.With["file"] != "" && step.With["file"] != "Dockerfile" {
				t.Error("publication must build the ordinary coherent-bundle Dockerfile")
			}
		}
		if strings.Contains(step.Run, "scripts/bundle-ci/qualify.sh") {
			qualifyAt = i
			if strings.Contains(step.If, "always()") || strings.Contains(step.If, "failure()") {
				t.Error("qualification requires a successful build")
			}
		}
		if step.ID == "export" {
			exportAt = i
			if !strings.Contains(step.Run, "scripts/bundle-ci/export.sh") {
				t.Error("export must use the gate-aware archive helper")
			}
		}
	}
	if buildAt < 0 || qualifyAt <= buildAt || exportAt <= qualifyAt {
		t.Fatalf("expected build -> qualify -> export, got %d -> %d -> %d", buildAt, qualifyAt, exportAt)
	}
}

func TestBundlePublicationOnlyPromotesQualifiedMainArtifact(t *testing.T) {
	w := readImageWorkflow(t)
	job, ok := w.Jobs["publish"]
	if !ok {
		t.Fatal("missing isolated publish job")
	}
	if job.Needs != "validate" || job.Permissions["packages"] != "write" {
		t.Error("publish requires successful validation and explicit packages:write")
	}
	for _, clause := range []string{"github.ref == 'refs/heads/main'", "github.event_name == 'push'", "github.event_name == 'workflow_dispatch'"} {
		if !strings.Contains(job.If, clause) {
			t.Errorf("missing publication condition: %s", clause)
		}
	}
	if strings.Contains(job.If, "always()") {
		t.Error("failed validation must block publication")
	}
	download, verified, published := false, false, false
	for _, step := range job.Steps {
		if strings.HasPrefix(step.Uses, "docker/build-push-action@") || strings.Contains(step.Run, "docker build") {
			t.Error("publish must not rebuild an unqualified image")
		}
		if strings.HasPrefix(step.Uses, "actions/download-artifact@") {
			download = step.With["name"] == "qualified-duckgres-image"
		}
		if strings.Contains(step.Run, "scripts/bundle-ci/restore.sh") {
			verified = download
		}
		if strings.Contains(step.Uses, "login-action") && !verified {
			t.Error("verify archive and image identity before registry login")
		}
		if strings.Contains(step.Run, "scripts/bundle-ci/publish.sh") {
			published = verified
		}
	}
	if !download || !verified || !published {
		t.Fatal("publication must download, verify and promote the already-qualified artifact")
	}
}
