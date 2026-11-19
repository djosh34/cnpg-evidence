package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
	"go.yaml.in/yaml/v3"
)

func TestNotInManifest(t *testing.T) {
	m, err := versions.Load("../versions/" + defaultManifest)
	if err != nil {
		t.Fatal(err)
	}
	pg, pgDigest, _ := strings.Cut(m.PostgreSQL.ImageName, "@")
	images, err := parseImages(`{"images": [
		{"id": "sha256:1", "repoTags": ["` + m.K3s.Images[0] + `"], "repoDigests": ["docker.io/rancher/x@sha256:9"], "pinned": true},
		{"id": "sha256:5", "repoTags": ["` + m.K3s.Images[1] + `"], "repoDigests": ["docker.io/rancher/y@sha256:6"], "pinned": false},
		{"id": "sha256:2", "repoTags": [], "repoDigests": ["` + versions.Repository(pg) + "@" + pgDigest + `"]},
		{"id": "sha256:3", "repoTags": ["docker.io/library/busybox:1.37"], "repoDigests": ["docker.io/library/busybox@sha256:8"]},
		{"id": "sha256:4", "repoTags": [], "repoDigests": ["` + versions.Repository(pg) + `@sha256:7"]}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	got := notInManifest(images, m)
	want := []string{
		m.K3s.Images[1] + " docker.io/rancher/y@sha256:6 (sha256:5)",
		"docker.io/library/busybox:1.37 docker.io/library/busybox@sha256:8 (sha256:3)",
		versions.Repository(pg) + "@sha256:7 (sha256:4)",
	}
	if !slices.Equal(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestSetDependencies(t *testing.T) {
	file := filepath.Join(t.TempDir(), "Chart.yaml")
	write := func(content string) {
		if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	charts := map[string]versions.Chart{"otel": {Repository: "https://charts.example", Version: "1.2.3"}}
	write("name: wrapper\ndependencies:\n  - name: otel\n    alias: agent\n  - name: otel\n    alias: cluster\n")
	if err := setDependencies(file, charts); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var chart struct {
		Dependencies []map[string]string `yaml:"dependencies"`
	}
	if err := yaml.Unmarshal(data, &chart); err != nil {
		t.Fatal(err)
	}
	for _, d := range chart.Dependencies {
		if d["repository"] != "https://charts.example" || d["version"] != "1.2.3" || d["name"] != "otel" {
			t.Errorf("a dependency: %v", d)
		}
	}
	if len(chart.Dependencies) != 2 || chart.Dependencies[1]["alias"] != "cluster" {
		t.Errorf("the dependencies: %v", chart.Dependencies)
	}
	write("name: wrapper\ndependencies:\n  - name: other\n")
	if err := setDependencies(file, charts); err == nil {
		t.Error("a chart the manifest does not have: no error")
	}
}

// Every wrapper chart of the samples and the variants depends only on
// charts the default manifest has, and names no version itself.
func TestWrapperDependencies(t *testing.T) {
	m, err := versions.Load("../versions/" + defaultManifest)
	if err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob("../*/charts/*/Chart.yaml")
	if err != nil {
		t.Fatal(err)
	}
	more, err := filepath.Glob("../variants/*/charts/*/Chart.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range append(files, more...) {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		var chart struct {
			Dependencies []map[string]string `yaml:"dependencies"`
		}
		if err := yaml.Unmarshal(data, &chart); err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		for _, d := range chart.Dependencies {
			if _, ok := m.Charts[d["name"]]; !ok {
				t.Errorf("%s: %s has no chart in the manifest", file, d["name"])
			}
			if d["version"] != "" || d["repository"] != "" {
				t.Errorf("%s: %s names a version or repository; the manifest has them", file, d["name"])
			}
		}
	}
}

// e2e.yml runs with the manifest TestScenario takes by default.
func TestWorkflowManifest(t *testing.T) {
	data, err := os.ReadFile("../.github/workflows/e2e.yml")
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		On struct {
			Dispatch struct {
				Inputs map[string]struct {
					Default any `yaml:"default"`
				} `yaml:"inputs"`
			} `yaml:"workflow_dispatch"`
		} `yaml:"on"`
	}
	if err := yaml.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	if got := workflow.On.Dispatch.Inputs["manifest"].Default; got != defaultManifest {
		t.Errorf("e2e.yml's default manifest is %v, TestScenario's %s", got, defaultManifest)
	}
}
