// Package versions reads a version manifest of versions/: every version of
// the system under test that an e2e run uses. Helm reads the same file as
// a values file for every release, so each upstream chart finds its images
// under its wrapper's dependency name. docs/e2e.md describes the file.
package versions

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Manifest is what the e2e run reads from a manifest besides the charts'
// own values, which only Helm reads.
type Manifest struct {
	K3s        K3s              `yaml:"k3s"`
	Tools      Tools            `yaml:"tools"`
	Charts     map[string]Chart `yaml:"charts"`
	PostgreSQL PostgreSQL       `yaml:"postgresql"`

	// pinned are the images the manifest pins by digest, as
	// repository@digest with the repository in its full form.
	pinned []string
}

// K3s is the k3s release of the nodes.
type K3s struct {
	Version string `yaml:"version"`
	Image   string `yaml:"image"` // rancher/k3s by tag and digest
	// The airgap image tarball of each architecture, which k3s imports at
	// start.
	Airgap map[string]Download `yaml:"airgap"`
	// The images in the tarballs, the release's k3s-images.txt.
	Images []string `yaml:"images"`
}

// Download is a file of a release and its sha256.
type Download struct {
	URL    string `yaml:"url"`
	SHA256 string `yaml:"sha256"`
}

// Tools are the tools of the e2e image that have to match the cluster.
type Tools struct {
	Kubectl     Tool   `yaml:"kubectl"`
	KubectlCNPG Tool   `yaml:"kubectl-cnpg"`
	RotateCA    Script `yaml:"rotate-default-ca-certs.sh"`
}

// Tool is a binary with the sha256 of its download for each architecture.
type Tool struct {
	Version string            `yaml:"version"`
	SHA256  map[string]string `yaml:"sha256"`
}

// Script is a script of the k3s release, the same for every architecture.
type Script struct {
	URL    string `yaml:"url"`
	SHA256 string `yaml:"sha256"`
}

// Chart is where Helm pulls an upstream chart from.
type Chart struct {
	Repository string `yaml:"repository"`
	Version    string `yaml:"version"`
}

// PostgreSQL are the instance images. The cnpg-cluster charts read
// ImageName; RolloutFrom is the image the rollout scenario starts on.
type PostgreSQL struct {
	ImageName   string `yaml:"imageName"`
	RolloutFrom string `yaml:"rolloutFrom"`
}

// Architectures are the architectures a manifest covers, as Go and k3s
// name them.
var Architectures = []string{"amd64", "arm64"}

var (
	sha256Hex = regexp.MustCompile(`^[0-9a-f]{64}$`)
	// An exact chart version, not a range: Helm would pick a newer chart.
	exactVersion = regexp.MustCompile(`^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$`)
)

// Load reads a manifest and checks that every part the run reads is there.
func Load(file string) (*Manifest, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	m, err := Parse(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	return m, nil
}

// Parse reads a manifest from its content.
func Parse(data []byte) (*Manifest, error) {
	var m Manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	var all any
	if err := yaml.Unmarshal(data, &all); err != nil {
		return nil, err
	}
	var w images
	w.visit(all, "")
	slices.Sort(w.pinned)
	m.pinned = slices.Compact(w.pinned)
	slices.Sort(w.unpinned)
	errs := []error{m.check()}
	for _, path := range w.unpinned {
		errs = append(errs, fmt.Errorf("the image %s has no digest", path))
	}
	for _, c := range chartImages {
		if !c.pinnedIn(all) {
			errs = append(errs, fmt.Errorf("no image %s with its digest in %s", strings.Join(c.keys, "."), c.field))
		}
	}
	return &m, errors.Join(errs...)
}

func (m *Manifest) check() error {
	var errs []error
	need := func(ok bool, what string) {
		if !ok {
			errs = append(errs, fmt.Errorf("no %s", what))
		}
	}
	need(m.K3s.Version != "", "k3s.version")
	need(strings.Contains(m.K3s.Image, "@sha256:"), "k3s.image with a digest")
	need(len(m.K3s.Images) > 0, "k3s.images")
	for _, arch := range Architectures {
		a := m.K3s.Airgap[arch]
		need(a.URL != "" && sha256Hex.MatchString(a.SHA256), "k3s.airgap."+arch+" with url and sha256")
		need(sha256Hex.MatchString(m.Tools.Kubectl.SHA256[arch]), "tools.kubectl.sha256."+arch)
		need(sha256Hex.MatchString(m.Tools.KubectlCNPG.SHA256[arch]), "tools.kubectl-cnpg.sha256."+arch)
	}
	need(m.Tools.Kubectl.Version != "", "tools.kubectl.version")
	need(m.Tools.KubectlCNPG.Version != "", "tools.kubectl-cnpg.version")
	need(m.Tools.RotateCA.URL != "" && sha256Hex.MatchString(m.Tools.RotateCA.SHA256),
		"tools.rotate-default-ca-certs.sh with url and sha256")
	need(len(m.Charts) > 0, "charts")
	for name, c := range m.Charts {
		need(c.Repository != "" && exactVersion.MatchString(c.Version), "charts."+name+" with repository and an exact version")
	}
	need(strings.Contains(m.PostgreSQL.ImageName, "@sha256:"), "postgresql.imageName with a digest")
	need(strings.Contains(m.PostgreSQL.RolloutFrom, "@sha256:"), "postgresql.rolloutFrom with a digest")
	return errors.Join(errs...)
}

// Pinned are the images the manifest pins by digest, each as
// repository@digest with the repository in its full form, such as
// docker.io/library/busybox. They are the images of every string such as
// registry.example/name:tag@sha256:…, and of every image block of a chart's
// values: a map with repository (after registry when there is one) and
// either digest or a tag that ends in @sha256:….
func (m *Manifest) Pinned() []string { return m.pinned }

// chartImage is an image block of an upstream chart: its keys in the
// manifest, and the field the chart reads its digest from: digest, or tag
// for a chart without a digest field.
type chartImage struct {
	keys  []string
	field string
}

// chartImages are the image blocks the upstream charts read. Each must be
// there with its digest where its chart reads it: a chart without one runs
// its own default image, by tag only.
var chartImages = []chartImage{
	{[]string{"cert-manager", "image"}, "digest"},
	{[]string{"cert-manager", "webhook", "image"}, "digest"},
	{[]string{"cert-manager", "cainjector", "image"}, "digest"},
	{[]string{"cert-manager", "acmesolver", "image"}, "digest"},
	{[]string{"cert-manager", "startupapicheck", "image"}, "digest"},
	{[]string{"cloudnative-pg", "image"}, "tag"},
	{[]string{"plugin-barman-cloud", "image"}, "tag"},
	{[]string{"plugin-barman-cloud", "sidecarImage"}, "tag"},
	{[]string{"agent", "image"}, "digest"},
	{[]string{"cluster", "image"}, "digest"},
}

// pinnedIn says whether the manifest has the block, by its nested keys,
// with a digest in its field.
func (c chartImage) pinnedIn(manifest any) bool {
	node := manifest
	for _, k := range c.keys {
		m, ok := node.(map[string]any)
		if !ok {
			return false
		}
		node = m[k]
	}
	block, ok := node.(map[string]any)
	if !ok {
		return false
	}
	value, ok := block[c.field].(string)
	if !ok {
		return false
	}
	if c.field == "tag" {
		_, value, _ = strings.Cut(value, "@")
	}
	return strings.HasPrefix(value, "sha256:")
}

// images walks the manifest for its images: those it pins, and the paths
// of the image blocks without a digest. charts holds chart repositories,
// not images.
type images struct {
	pinned, unpinned []string
}

func (w *images) visit(node any, path string) {
	switch n := node.(type) {
	case string:
		if name, digest, ok := strings.Cut(n, "@"); ok && strings.HasPrefix(digest, "sha256:") {
			w.pinned = append(w.pinned, Repository(name)+"@"+digest)
		}
	case []any:
		for i, v := range n {
			w.visit(v, fmt.Sprintf("%s[%d]", path, i))
		}
	case map[string]any:
		if repo, ok := n["repository"].(string); ok && repo != "" {
			if registry, ok := n["registry"].(string); ok && registry != "" {
				repo = registry + "/" + repo
			}
			var digest string
			if d, ok := n["digest"].(string); ok {
				digest = d
			}
			if tag, ok := n["tag"].(string); ok && digest == "" {
				_, digest, _ = strings.Cut(tag, "@")
			}
			if strings.HasPrefix(digest, "sha256:") {
				w.pinned = append(w.pinned, Repository(repo)+"@"+digest)
			} else {
				w.unpinned = append(w.unpinned, path)
			}
		}
		for k, v := range n {
			// A tag with a digest belongs to the block above.
			if k == "tag" || (path == "" && k == "charts") {
				continue
			}
			w.visit(v, strings.TrimPrefix(path+"."+k, "."))
		}
	}
}

// Repository is the full form of an image name, with its tag cut off:
// docker.io and library/ where the name leaves them out, as containerd
// writes them.
func Repository(name string) string {
	// A tag is after the last colon, unless that colon is in the registry's
	// host:port.
	if i := strings.LastIndex(name, ":"); i > strings.LastIndex(name, "/") {
		name = name[:i]
	}
	first, rest, ok := strings.Cut(name, "/")
	if !ok {
		return "docker.io/library/" + name
	}
	if !strings.ContainsAny(first, ".:") && first != "localhost" {
		return "docker.io/" + name
	}
	if first == "docker.io" && !strings.Contains(rest, "/") {
		return "docker.io/library/" + rest
	}
	return name
}

// Reference is the full form of an image reference by tag, such as
// docker.io/rancher/mirrored-pause:3.10.2.
func Reference(ref string) string {
	if i := strings.LastIndex(ref, ":"); i > strings.LastIndex(ref, "/") {
		return Repository(ref) + ref[i:]
	}
	return Repository(ref)
}
