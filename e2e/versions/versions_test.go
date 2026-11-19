package versions

import (
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

func TestPinned(t *testing.T) {
	got := pinned(map[string]any{
		"postgresql": map[string]any{"imageName": "registry.example/pg:18@" + digest},
		"chart": map[string]any{
			"image":   map[string]any{"repository": "quay.io/a/b", "tag": "v1", "digest": digest},
			"inTag":   map[string]any{"registry": "ghcr.io", "repository": "c/d", "tag": "v2@" + digest},
			"byTag":   map[string]any{"repository": "quay.io/e/f", "tag": "v3"},
			"list":    []any{"busybox@" + digest, "busybox:1"},
			"comment": "not an image",
		},
	})
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
	for version, exact := range map[string]bool{"0.29.1": true, "v1.21.3": true, "1.0.0-rc.1": true, "0.29.x": false, "~0.29.1": false, ">=1.0.0": false, "0.29": false} {
		if exactVersion.MatchString(version) != exact {
			t.Errorf("%s: exact %v", version, !exact)
		}
	}
}
