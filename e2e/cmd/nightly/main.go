// Command nightly writes the manifest of the nightly e2e run to stdout:
//
//	go -C e2e run ./cmd/nightly -from ../versions/v1.37-hi.yaml >versions/nightly.yaml
//
// It is the -from manifest with every image of the mirror
// ghcr.io/djosh34/hardened-mirror at the newest version the mirror has on
// the image's line, the mirror's own tag such as cloudnative-pg 1, each
// pinned by the digest of its version's tag. An image and its chart move
// together: they take the newest version that the mirror has as a tag of
// each image of the line and as the appVersion of a chart version.
// kubectl-cnpg follows the operator. postgresql.rolloutFrom, k3s and the
// other tools stay as they are. nightly.yml runs it each night
// (docs/e2e.md).
package main

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"flag"
	"fmt"
	"maps"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/djosh34/cnpg-evidence/e2e/lookup"
	"github.com/djosh34/cnpg-evidence/e2e/versions"
	"go.yaml.in/yaml/v3"
)

// mirror is where every chart and image of the manifest comes from, but
// k3s's.
const mirror = "ghcr.io/djosh34/hardened-mirror/"

// line is a set of the mirror's images that move together on one of the
// mirror's tags, such as 1 for cloudnative-pg, and the chart that runs
// them, by its key under charts. postgres has no chart.
type line struct {
	tag    string   // the mirror's tag, a major version and a suffix, such as 0-contrib
	images []string // repositories below mirror
	chart  string
}

var lines = []line{
	{"1", []string{"cert-manager-controller", "cert-manager-webhook", "cert-manager-cainjector",
		"cert-manager-acmesolver", "cert-manager-startupapicheck"}, "cert-manager"},
	{"1", []string{"cloudnative-pg"}, "cloudnative-pg"},
	{"0", []string{"cloudnative-pg-plugin-barman-cloud", "cloudnative-pg-plugin-barman-cloud-sidecar"}, "plugin-barman-cloud"},
	{"0-contrib", []string{"opentelemetry-collector"}, "opentelemetry-collector"},
	{"18", []string{"postgres"}, ""},
}

// The image whose version kubectl-cnpg takes.
const operator = "cloudnative-pg"

func main() {
	from := flag.String("from", "", "the manifest to start from, such as ../versions/v1.37-hi.yaml")
	flag.Parse()
	if *from == "" || flag.NArg() != 0 {
		flag.Usage()
		fail(2, "-from is needed, and no argument")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	out, err := generate(ctx, *from)
	if err == nil {
		_, err = os.Stdout.Write(out)
	}
	if err != nil {
		fail(1, err.Error())
	}
}

// fail prints why the command failed and exits with code.
func fail(code int, why string) {
	if _, err := fmt.Fprintln(os.Stderr, "nightly:", why); err != nil {
		code = max(code, 1)
	}
	os.Exit(code)
}

// pick is the version a line takes: the image tag, the digest of each
// image at that tag, and the version of its chart.
type pick struct {
	tag     string
	version string            // the tag without its suffix, as appVersion gives it
	digests map[string]string // by image
	chart   string            // the chart's version
}

func generate(ctx context.Context, from string) ([]byte, error) {
	data, err := os.ReadFile(from)
	if err != nil {
		return nil, err
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("%s: %w", from, err)
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s is not a YAML map", from)
	}
	root := doc.Content[0]
	picks := map[string]pick{} // by image
	for _, l := range lines {
		p, err := pickLine(ctx, l, root)
		if err != nil {
			return nil, err
		}
		for _, image := range l.images {
			picks[image] = p
		}
	}
	sums, err := lookup.KubectlCNPG(ctx, picks[operator].version)
	if err != nil {
		return nil, err
	}
	if err := apply(root, picks, sums); err != nil {
		return nil, err
	}
	doc.HeadComment = fmt.Sprintf("The manifest of the nightly e2e run of %s: %s with every\n"+
		"image of the mirror at its newest version, by e2e/cmd/nightly (docs/e2e.md).",
		time.Now().UTC().Format(time.DateOnly), from[strings.LastIndex(from, "/")+1:])
	root.HeadComment = ""
	var out bytes.Buffer
	enc := yaml.NewEncoder(&out)
	enc.SetIndent(2)
	if err := errors.Join(enc.Encode(&doc), enc.Close()); err != nil {
		return nil, err
	}
	// What the e2e run reads has to be there.
	if _, err := versions.Parse(out.Bytes()); err != nil {
		return nil, fmt.Errorf("the manifest it made: %w", err)
	}
	return out.Bytes(), nil
}

// pickLine looks up what the mirror has of a line and picks its version.
func pickLine(ctx context.Context, l line, root *yaml.Node) (pick, error) {
	tags := map[string][]string{}
	for _, image := range l.images {
		var err error
		if tags[image], err = lookup.Tags(ctx, mirror+image); err != nil {
			return pick{}, err
		}
	}
	var apps map[string]string // the appVersion of each chart version
	if l.chart != "" {
		repo, err := chartRepository(root, l.chart)
		if err != nil {
			return pick{}, err
		}
		chartTags, err := lookup.Tags(ctx, repo)
		if err != nil {
			return pick{}, err
		}
		apps = map[string]string{}
		for _, t := range chartTags {
			if strings.HasPrefix(t, "sha256-") {
				continue // a signature, not a chart
			}
			if apps[t], err = lookup.ChartAppVersion(ctx, repo, t); err != nil {
				return pick{}, err
			}
		}
	}
	p, err := choose(l, tags, apps)
	if err != nil {
		return pick{}, err
	}
	p.digests = map[string]string{}
	for _, image := range l.images {
		if p.digests[image], err = lookup.Digest(ctx, mirror+image+":"+p.tag); err != nil {
			return pick{}, err
		}
	}
	return p, nil
}

// chartRepository is the mirror's OCI repository of the chart under key in
// charts, from its repository and name.
func chartRepository(root *yaml.Node, key string) (string, error) {
	chart := lookupKey(root, "charts", key)
	repo := lookupKey(chart, "repository")
	if repo == nil || repo.Value != "oci://"+strings.TrimSuffix(mirror, "/") {
		return "", fmt.Errorf("charts.%s is not in the mirror %s", key, mirror)
	}
	name := key
	if n := lookupKey(chart, "name"); n != nil && n.Value != "" {
		name = n.Value
	}
	return mirror + name, nil
}

// choose picks a line's version from the tags of each of its images and
// the appVersion of each version of its chart, nil for no chart: the
// newest version that each image has as a tag on the line, and that a
// chart version has as appVersion, with the newest such chart version.
func choose(l line, tags map[string][]string, apps map[string]string) (pick, error) {
	major, suffix, _ := strings.Cut(l.tag, "-")
	if suffix != "" {
		suffix = "-" + suffix
	}
	onLine := regexp.MustCompile(`^` + regexp.QuoteMeta(major) + `(\.[0-9]+)+` + regexp.QuoteMeta(suffix) + `$`)
	var common []string // versions without the suffix
	for i, image := range l.images {
		var have []string
		for _, t := range tags[image] {
			if onLine.MatchString(t) {
				have = append(have, strings.TrimSuffix(t, suffix))
			}
		}
		if i == 0 {
			common = have
		} else {
			common = slices.DeleteFunc(common, func(v string) bool { return !slices.Contains(have, v) })
		}
	}
	charts := map[string]string{} // the newest chart version of each appVersion
	if l.chart != "" {
		for chart, app := range apps {
			if strings.Contains(chart, "-") {
				continue // a prerelease, such as 0.30.0-rc.1
			}
			app = strings.TrimPrefix(app, "v")
			if old, ok := charts[app]; !ok || compareVersions(chart, old) > 0 {
				charts[app] = chart
			}
		}
		common = slices.DeleteFunc(common, func(v string) bool { _, ok := charts[v]; return !ok })
	}
	if len(common) == 0 {
		what := strings.Join(l.images, ", ")
		if l.chart != "" {
			what += " and the chart " + l.chart
		}
		return pick{}, fmt.Errorf("the mirror has no version on the line %s of %s", l.tag, what)
	}
	v := slices.MaxFunc(common, compareVersions)
	return pick{tag: v + suffix, version: v, chart: charts[v]}, nil
}

// compareVersions compares two versions by each dotted number, so 0.10.0
// is newer than 0.9.1. A part that is no number compares as text.
func compareVersions(a, b string) int {
	pa, pb := strings.Split(strings.TrimPrefix(a, "v"), "."), strings.Split(strings.TrimPrefix(b, "v"), ".")
	for i := range min(len(pa), len(pb)) {
		na, errA := strconv.Atoi(pa[i])
		nb, errB := strconv.Atoi(pb[i])
		c := cmp.Compare(na, nb)
		if errA != nil || errB != nil {
			c = strings.Compare(pa[i], pb[i])
		}
		if c != 0 {
			return c
		}
	}
	return cmp.Compare(len(pa), len(pb))
}

// apply writes the picks into the manifest: each image block of the
// mirror, postgresql.imageName, the version of each chart and
// kubectl-cnpg. An image block of the mirror that no line names is an
// error, so no image keeps an old digest unseen.
func apply(root *yaml.Node, picks map[string]pick, cnpgSums map[string]string) error {
	var errs []error
	seen := map[string]bool{}
	walk(root, func(block *yaml.Node) {
		repo := lookupKey(block, "repository")
		if repo == nil || repo.Kind != yaml.ScalarNode {
			return
		}
		full := repo.Value
		if registry := lookupKey(block, "registry"); registry != nil && registry.Value != "" {
			full = registry.Value + "/" + full
		}
		image, ok := strings.CutPrefix(full, mirror)
		if !ok {
			return
		}
		p, ok := picks[image]
		if !ok {
			errs = append(errs, fmt.Errorf("the image %s is on no line of e2e/cmd/nightly", full))
			return
		}
		seen[image] = true
		tag := lookupKey(block, "tag")
		digest := lookupKey(block, "digest")
		switch {
		case tag == nil:
			errs = append(errs, fmt.Errorf("the image %s has no tag", full))
		case digest != nil:
			setString(tag, p.tag)
			setString(digest, p.digests[image])
		default:
			setString(tag, p.tag+"@"+p.digests[image])
		}
	})
	if name := lookupKey(root, "postgresql", "imageName"); name != nil {
		p := picks["postgres"]
		setString(name, mirror+"postgres:"+p.tag+"@"+p.digests["postgres"])
		seen["postgres"] = true
	}
	for _, image := range slices.Sorted(maps.Keys(picks)) {
		if !seen[image] {
			errs = append(errs, fmt.Errorf("the manifest has no image %s%s", mirror, image))
		}
	}
	for _, l := range lines {
		p := picks[l.images[0]]
		if l.chart == "" {
			continue
		}
		if version := lookupKey(root, "charts", l.chart, "version"); version == nil {
			errs = append(errs, fmt.Errorf("no charts.%s.version", l.chart))
		} else {
			setString(version, p.chart)
		}
	}
	tool := lookupKey(root, "tools", "kubectl-cnpg")
	version, sums := lookupKey(tool, "version"), lookupKey(tool, "sha256")
	if version == nil || sums == nil {
		return errors.Join(append(errs, errors.New("no tools.kubectl-cnpg with version and sha256"))...)
	}
	setString(version, picks[operator].version)
	for _, arch := range versions.Architectures {
		sum := lookupKey(sums, arch)
		if sum == nil {
			errs = append(errs, fmt.Errorf("no tools.kubectl-cnpg.sha256.%s", arch))
			continue
		}
		setString(sum, cnpgSums[arch])
	}
	return errors.Join(errs...)
}

// walk calls f on each map in the tree of node.
func walk(node *yaml.Node, f func(*yaml.Node)) {
	if node.Kind == yaml.MappingNode {
		f(node)
	}
	for _, c := range node.Content {
		walk(c, f)
	}
}

// lookupKey is the value at the path of keys below a map node, or nil.
func lookupKey(node *yaml.Node, keys ...string) *yaml.Node {
	for _, k := range keys {
		if node == nil || node.Kind != yaml.MappingNode {
			return nil
		}
		var next *yaml.Node
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == k {
				next = node.Content[i+1]
			}
		}
		node = next
	}
	return node
}

// setString sets a scalar to a string in its style, and quotes it where
// it would read as another type, as a version such as 18.10 would.
func setString(node *yaml.Node, value string) {
	node.Kind, node.Tag, node.Value = yaml.ScalarNode, "!!str", value
}
