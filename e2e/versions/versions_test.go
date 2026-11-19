package versions

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestRepository(t *testing.T) {
	for name, want := range map[string]string{
		"busybox":                      "docker.io/library/busybox",
		"busybox:1.37":                 "docker.io/library/busybox",
		"otel/opentelemetry-collector": "docker.io/otel/opentelemetry-collector",
		"docker.io/rancher/k3s:v1":     "docker.io/rancher/k3s",
		"docker.io/busybox":            "docker.io/library/busybox",
		"ghcr.io/cloudnative-pg/cloudnative-pg:1.30.1": "ghcr.io/cloudnative-pg/cloudnative-pg",
		"localhost:5000/app:1":                         "localhost:5000/app",
		"registry.example:5000/app":                    "registry.example:5000/app",
	} {
		if got := Repository(name); got != want {
			t.Errorf("Repository(%q) = %q, want %q", name, got, want)
		}
	}
	if got := Reference("rancher/mirrored-pause:3.10.2"); got != "docker.io/rancher/mirrored-pause:3.10.2" {
		t.Errorf("Reference: %q", got)
	}
}

const digest = "sha256:0000000000000000000000000000000000000000000000000000000000000001"

func TestImages(t *testing.T) {
	var w images
	w.visit(map[string]any{
		"postgresql": map[string]any{"imageName": "registry.example/pg:18@" + digest},
		"chart": map[string]any{
			"image":   map[string]any{"repository": "quay.io/a/b", "tag": "v1", "digest": digest},
			"inTag":   map[string]any{"registry": "ghcr.io", "repository": "c/d", "tag": "v2@" + digest},
			"byTag":   map[string]any{"repository": "quay.io/e/f", "tag": "v3"},
			"list":    []any{"busybox@" + digest, "busybox:1"},
			"comment": "not an image",
		},
		"charts": map[string]any{"c": map[string]any{"repository": "https://charts.example", "version": "1.0.0"}},
	}, "")
	slices.Sort(w.pinned)
	if want := []string{"chart.byTag"}; !slices.Equal(w.unpinned, want) {
		t.Errorf("unpinned: got %q, want %q", w.unpinned, want)
	}
	got := w.pinned
	want := []string{
		"docker.io/library/busybox@" + digest,
		"ghcr.io/c/d@" + digest,
		"quay.io/a/b@" + digest,
		"registry.example/pg@" + digest,
	}
	if !slices.Equal(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

// Every manifest of versions/ has what a run reads, and Pinned has its k3s
// and PostgreSQL images.
func TestManifests(t *testing.T) {
	files, err := filepath.Glob("../../versions/*.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no manifest in versions/")
	}
	for _, file := range files {
		m, err := Load(file)
		if err != nil {
			t.Error(err)
			continue
		}
		for _, image := range []string{m.K3s.Image, m.PostgreSQL.ImageName, m.PostgreSQL.RolloutFrom} {
			name, d, _ := strings.Cut(image, "@")
			if !slices.Contains(m.Pinned(), Repository(name)+"@"+d) {
				t.Errorf("%s: %s is not in Pinned", file, image)
			}
		}
	}
}

func TestCheck(t *testing.T) {
	if _, err := Parse([]byte("k3s: {version: v1}\n")); err == nil || !strings.Contains(err.Error(), "no k3s.image") {
		t.Errorf("a manifest with only k3s.version: %v", err)
	}
	data, err := os.ReadFile("../../versions/v1.33.yaml")
	if err != nil {
		t.Fatal(err)
	}
	// The agent's image without its digest, as a tag only.
	agent := strings.Index(string(data), "\nagent:")
	noDigest := string(data[:agent]) + strings.Replace(string(data[agent:]), "    digest: sha256:", "    # digest: sha256:", 1)
	if _, err := Parse([]byte(noDigest)); err == nil || !strings.Contains(err.Error(), "the image agent.image has no digest") {
		t.Errorf("a chart image without a digest: %v", err)
	}
	// The ACME solver's image left out: the chart would run its own.
	solver := strings.Index(string(data), "  acmesolver:\n")
	end := strings.Index(string(data)[solver:], "  startupapicheck:")
	if _, err := Parse([]byte(string(data[:solver]) + string(data[solver+end:]))); err == nil ||
		!strings.Contains(err.Error(), "no image cert-manager.acmesolver.image with a repository and its digest in digest") {
		t.Errorf("a chart image left out: %v", err)
	}
	// The solver's block under a literal dotted key, which Helm does not read.
	dotted := string(data[:solver]) + string(data[solver+end:]) +
		"\"cert-manager.acmesolver.image\":\n  repository: quay.io/jetstack/cert-manager-acmesolver\n  digest: sha256:" + strings.Repeat("0", 64) + "\n"
	if _, err := Parse([]byte(dotted)); err == nil || !strings.Contains(err.Error(), "no image cert-manager.acmesolver.image") {
		t.Errorf("a chart image under a dotted key: %v", err)
	}
	// A second digest next to the sidecar's tag, which its chart ignores.
	twoDigests := strings.Replace(string(data), "    repository: cloudnative-pg/plugin-barman-cloud-sidecar\n",
		"    repository: cloudnative-pg/plugin-barman-cloud-sidecar\n    digest: sha256:"+strings.Repeat("1", 64)+"\n", 1)
	if _, err := Parse([]byte(twoDigests)); err == nil ||
		!strings.Contains(err.Error(), "the image plugin-barman-cloud.sidecarImage has a digest in digest and in tag") {
		t.Errorf("an image with two digests: %v", err)
	}
	// The solver's block without its repository.
	noRepo := strings.Replace(string(data), "      repository: quay.io/jetstack/cert-manager-acmesolver\n", "", 1)
	if _, err := Parse([]byte(noRepo)); err == nil || !strings.Contains(err.Error(), "no image cert-manager.acmesolver.image with a repository") {
		t.Errorf("a chart image without its repository: %v", err)
	}
	// CNPG's digest in a digest field, which its chart does not read.
	cnpgAt := strings.Index(string(data), "\ncloudnative-pg:\n")
	if cnpgAt < 0 {
		t.Fatal("v1.33.yaml has no top-level cloudnative-pg key")
	}
	cnpg := string(data[:cnpgAt]) + strings.Replace(string(data[cnpgAt:]), `@sha256:`, `"
    digest: "sha256:`, 1)
	if _, err := Parse([]byte(cnpg)); err == nil || !strings.Contains(err.Error(), "no image cloudnative-pg.image with a repository and its digest in tag") {
		t.Errorf("CNPG's digest outside its tag: %v", err)
	}
	for version, exact := range map[string]bool{"0.29.1": true, "v1.21.3": true, "1.0.0-rc.1": true, "0.29.x": false, "~0.29.1": false, ">=1.0.0": false, "0.29": false} {
		if exactVersion.MatchString(version) != exact {
			t.Errorf("%s: exact %v", version, !exact)
		}
	}
}
