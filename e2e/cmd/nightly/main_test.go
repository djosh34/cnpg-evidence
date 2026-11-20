package main

import (
	"bytes"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
	"go.yaml.in/yaml/v3"
)

func TestCompareVersions(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{
		{"0.10.0", "0.9.1", 1},
		{"1.30.2", "1.30.2", 0},
		{"18.7", "18.10", -1},
		{"v0.16.0", "0.15.1", 1},
		{"1.21", "1.21.3", -1},
	} {
		if got := compareVersions(c.a, c.b); got != c.want {
			t.Errorf("compareVersions(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

// A line takes the newest version that every image has as a tag on the
// line and a chart has as appVersion, and the newest chart of it.
func TestChoose(t *testing.T) {
	cnpg := line{"1", []string{"op", "helper"}, "chart"}
	tags := map[string][]string{
		"op":     {"1", "1.30", "1.30.2", "1.30.2-debian13", "1.31.0", "1.29.9", "2.0.0", "1.30.2-dev"},
		"helper": {"1", "1.30.2", "1.31.0", "1.29.9"},
	}
	// 1.31.0 has no chart yet; 0.29.3 is a newer chart of 1.30.2, and
	// 0.29.4-rc.1 a prerelease.
	apps := map[string]string{"0.29.2": "1.30.2", "0.29.3": "v1.30.2", "0.29.4-rc.1": "1.30.2", "0.28.0": "1.29.9"}
	p, err := choose(cnpg, tags, apps)
	if err != nil {
		t.Fatal(err)
	}
	if p.tag != "1.30.2" || p.version != "1.30.2" || p.chart != "0.29.3" {
		t.Errorf("got %+v, want 1.30.2 with chart 0.29.3", p)
	}

	// A tag suffix: the version is without it, as appVersion gives it.
	otel := line{"0-contrib", []string{"otel"}, "chart"}
	p, err = choose(otel, map[string][]string{"otel": {"0-contrib", "0.165.0-contrib", "0.165.0-debian13-contrib", "0.166.0"}},
		map[string]string{"0.180.0": "0.165.0"})
	if err != nil {
		t.Fatal(err)
	}
	if p.tag != "0.165.0-contrib" || p.version != "0.165.0" || p.chart != "0.180.0" {
		t.Errorf("got %+v, want 0.165.0-contrib with chart 0.180.0", p)
	}

	// No chart: the newest version tag.
	pg := line{"18", []string{"postgres"}, ""}
	p, err = choose(pg, map[string][]string{"postgres": {"18", "18.7", "18.10", "18.6-debian13", "18-alpine", "17.9"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if p.tag != "18.10" {
		t.Errorf("got %+v, want 18.10", p)
	}

	// No version both images and a chart have.
	if _, err := choose(cnpg, tags, map[string]string{"0.30.0": "1.31.1"}); err == nil {
		t.Error("no matching chart: no error")
	}
}

// apply sets every image of the mirror, the charts and kubectl-cnpg, and
// leaves rolloutFrom and k3s as they are.
func TestApply(t *testing.T) {
	data, err := os.ReadFile("../../../versions/latest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	digest := "sha256:" + strings.Repeat("a", 64)
	picks := map[string]pick{}
	for _, l := range lines {
		p := pick{tag: "9.9.9", version: "9.9.9", digests: map[string]string{}, chart: "8.8.8"}
		for _, image := range l.images {
			p.digests[image] = digest
			picks[image] = p
		}
	}
	sums := map[string]string{"amd64": strings.Repeat("b", 64), "arm64": strings.Repeat("c", 64)}
	if err := apply(doc.Content[0], picks, sums); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := yaml.NewEncoder(&out).Encode(&doc); err != nil {
		t.Fatal(err)
	}
	m, err := versions.Parse(out.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	old, err := versions.Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	name, rolloutDigest, _ := strings.Cut(old.PostgreSQL.RolloutFrom, "@")
	picked := 0
	for _, p := range m.Pinned() {
		switch {
		case strings.HasPrefix(p, mirror) && strings.HasSuffix(p, digest):
			picked++
		case strings.HasPrefix(p, mirror) && p != versions.Repository(name)+"@"+rolloutDigest:
			t.Errorf("not the picked digest: %s", p)
		}
	}
	if picked != len(picks) {
		t.Errorf("%d images have the picked digest, want %d", picked, len(picks))
	}
	if m.PostgreSQL.ImageName != mirror+"postgres:9.9.9@"+digest || m.PostgreSQL.RolloutFrom != old.PostgreSQL.RolloutFrom {
		t.Errorf("postgresql: %+v", m.PostgreSQL)
	}
	for key, c := range m.Charts {
		if c.Version != "8.8.8" {
			t.Errorf("charts.%s.version is %s", key, c.Version)
		}
	}
	if m.Tools.KubectlCNPG.Version != "9.9.9" || m.Tools.KubectlCNPG.SHA256["arm64"] != sums["arm64"] {
		t.Errorf("kubectl-cnpg: %+v", m.Tools.KubectlCNPG)
	}
	if m.K3s.Image != old.K3s.Image || m.Tools.Kubectl.Version != old.Tools.Kubectl.Version {
		t.Error("k3s or kubectl changed")
	}

	// A mirror image on no line is an error.
	delete(picks, "cloudnative-pg")
	if err := apply(doc.Content[0], picks, sums); err == nil || !strings.Contains(err.Error(), "cloudnative-pg") {
		t.Errorf("an image on no line: %v", err)
	}
}

// setK3s replaces k3s, kubectl and the rotation script of an older pin
// with those of the newest release, and leaves the rest as it is.
func TestSetK3s(t *testing.T) {
	data, err := os.ReadFile("../../../versions/latest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	k3s := versions.K3s{
		Version: "v1.99.1+k3s2",
		Image:   "rancher/k3s:v1.99.1-k3s2@sha256:" + strings.Repeat("a", 64),
		Airgap: map[string]versions.Download{
			"amd64": {URL: "https://example.com/amd64.tar.zst", SHA256: strings.Repeat("b", 64)},
			"arm64": {URL: "https://example.com/arm64.tar.zst", SHA256: strings.Repeat("c", 64)},
		},
		Images: []string{"docker.io/rancher/mirrored-pause:9.9"},
	}
	tools := versions.Tools{
		Kubectl:  versions.Tool{Version: "v1.99.1", SHA256: map[string]string{"amd64": strings.Repeat("d", 64), "arm64": strings.Repeat("e", 64)}},
		RotateCA: versions.Script{URL: "https://example.com/rotate-default-ca-certs.sh", SHA256: strings.Repeat("f", 64)},
	}
	if err := setK3s(doc.Content[0], k3s, tools); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := yaml.NewEncoder(&out).Encode(&doc); err != nil {
		t.Fatal(err)
	}
	m, err := versions.Parse(out.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	old, err := versions.Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(m.K3s, k3s) {
		t.Errorf("k3s: %+v", m.K3s)
	}
	if !reflect.DeepEqual(m.Tools.Kubectl, tools.Kubectl) || m.Tools.RotateCA != tools.RotateCA {
		t.Errorf("tools: %+v", m.Tools)
	}
	if !reflect.DeepEqual(m.Tools.KubectlCNPG, old.Tools.KubectlCNPG) || !reflect.DeepEqual(m.Charts, old.Charts) || m.PostgreSQL != old.PostgreSQL {
		t.Error("kubectl-cnpg, the charts or postgresql changed")
	}
	if !strings.Contains(out.String(), "# The k3s release of the nodes.") {
		t.Error("the comment on k3s is gone")
	}

	// A manifest without tools is an error.
	if err := setK3s(&yaml.Node{Kind: yaml.MappingNode}, k3s, tools); err == nil || !strings.Contains(err.Error(), "tools.kubectl") {
		t.Errorf("no tools: %v", err)
	}
}
