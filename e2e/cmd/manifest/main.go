// Command manifest writes a version manifest of versions/ to stdout, from a
// k3s release, the upstream chart versions and the PostgreSQL images:
//
//	go -C e2e run ./cmd/manifest -k3s v1.33.13+k3s2 -cert-manager v1.21.3 \
//	  -cloudnative-pg 0.29.1 -plugin-barman-cloud 0.9.0 -opentelemetry-collector 0.177.0 \
//	  -postgresql registry.access.redhat.com/hi/postgresql:18.7-1794620596 \
//	  -rollout-from registry.access.redhat.com/hi/postgresql:18.6-1793756462 >versions/v1.33.yaml
//
// It looks everything else up: each chart's images at the chart's own
// default tag, the k3s image, its airgap tarballs and their image list,
// kubectl of the k3s version, kubectl-cnpg of the operator's version and
// k3s's CA rotation script, and every digest and sha256. It needs helm and
// the network. docs/e2e.md says when to run it.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"text/template"
	"time"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
	"go.yaml.in/yaml/v3"
)

// The repository of each upstream chart.
var repositories = map[string]string{
	"cert-manager":            "https://charts.jetstack.io",
	"cloudnative-pg":          "https://cloudnative-pg.github.io/charts",
	"plugin-barman-cloud":     "https://cloudnative-pg.github.io/charts",
	"opentelemetry-collector": "https://open-telemetry.github.io/opentelemetry-helm-charts",
}

// The collector chart names no default image. The collectors run the
// Kubernetes distribution of the collector, at the chart's appVersion.
const otelRepository = "otel/opentelemetry-collector-k8s"

//go:embed manifest.yaml.tmpl
var manifestTemplate string

// The upstream charts, in the order of the command line.
var chartNames = []string{"cert-manager", "cloudnative-pg", "plugin-barman-cloud", "opentelemetry-collector"}

// inputs are what the command line gives.
type inputs struct {
	k3s, postgresql, rolloutFrom string
	charts                       map[string]*string // chart versions, by chart name
}

// command is the command line that makes the manifest of in.
func (in inputs) command() string {
	c := "go -C e2e run ./cmd/manifest -k3s " + in.k3s
	for _, name := range chartNames {
		c += " -" + name + " " + *in.charts[name]
	}
	return c + " -postgresql " + in.postgresql + " -rollout-from " + in.rolloutFrom
}

func main() {
	in := inputs{charts: map[string]*string{}}
	flag.StringVar(&in.k3s, "k3s", "", "the k3s release, such as v1.33.13+k3s2")
	for _, name := range chartNames {
		in.charts[name] = flag.String(name, "", "the version of the "+name+" chart")
	}
	flag.StringVar(&in.postgresql, "postgresql", "", "the instance image by tag")
	flag.StringVar(&in.rolloutFrom, "rollout-from", "", "the instance image by tag that the rollout scenario starts on")
	flag.Parse()
	missing := in.k3s == "" || in.postgresql == "" || in.rolloutFrom == "" || flag.NArg() != 0
	for _, v := range in.charts {
		missing = missing || *v == ""
	}
	if missing {
		flag.Usage()
		fail(2, "every flag is needed, and no argument")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	out, err := generate(ctx, in)
	if err == nil {
		_, err = os.Stdout.Write(out)
	}
	if err != nil {
		fail(1, err.Error())
	}
}

// fail prints why the command failed and exits with code.
func fail(code int, why string) {
	if _, err := fmt.Fprintln(os.Stderr, "manifest:", why); err != nil {
		code = max(code, 1)
	}
	os.Exit(code)
}

// manifest is what the template writes.
type manifest struct {
	Command    string
	K3s        versions.K3s
	Tools      versions.Tools
	Charts     map[string]versions.Chart
	PostgreSQL versions.PostgreSQL

	CertManager     []certManagerImage
	CNPG            image
	Barman, Sidecar image
	Collector       image
}

// image is an image of a chart: its repository (after registry, when the
// chart splits them), its tag and its digest.
type image struct {
	Registry, Repository, Tag, Digest string
}

// certManagerImage is one of cert-manager's images, under key (the
// controller's under none).
type certManagerImage struct {
	Key string
	image
}

func generate(ctx context.Context, in inputs) ([]byte, error) {
	m := manifest{Command: in.command(), Charts: map[string]versions.Chart{}}
	appVersions := map[string]string{}
	values := map[string]map[string]any{}
	for name, version := range in.charts {
		m.Charts[name] = versions.Chart{Repository: repositories[name], Version: *version}
		var err error
		if appVersions[name], values[name], err = showChart(ctx, repositories[name], name, *version); err != nil {
			return nil, err
		}
	}
	var err error
	if m.K3s, err = k3s(ctx, in.k3s); err != nil {
		return nil, err
	}
	if m.Tools, err = tools(ctx, in.k3s, appVersions["cloudnative-pg"]); err != nil {
		return nil, err
	}
	if m.PostgreSQL.ImageName, err = pinned(ctx, in.postgresql); err != nil {
		return nil, err
	}
	if m.PostgreSQL.RolloutFrom, err = pinned(ctx, in.rolloutFrom); err != nil {
		return nil, err
	}

	cm := values["cert-manager"]
	for _, key := range []string{"", "webhook", "cainjector", "acmesolver", "startupapicheck"} {
		path := []string{"image"}
		if key != "" {
			path = []string{key, "image"}
		}
		// Older charts give the whole repository, newer ones a name under
		// imageRegistry and imageNamespace.
		repo := str(cm, append(path, "repository")...)
		if name := str(cm, append(path, "name")...); repo == "" && name != "" {
			repo = str(cm, "imageRegistry") + "/" + str(cm, "imageNamespace") + "/" + name
		}
		if repo == "" {
			return nil, fmt.Errorf("the cert-manager chart has no repository or name in %s", strings.Join(path, "."))
		}
		img := image{Repository: repo, Tag: appVersions["cert-manager"]}
		if img.Digest, err = digest(ctx, repo+":"+img.Tag); err != nil {
			return nil, err
		}
		m.CertManager = append(m.CertManager, certManagerImage{key, img})
	}

	m.CNPG = image{Repository: str(values["cloudnative-pg"], "image", "repository"), Tag: appVersions["cloudnative-pg"]}
	barman := values["plugin-barman-cloud"]
	m.Barman = image{Registry: str(barman, "image", "registry"), Repository: str(barman, "image", "repository"), Tag: appVersions["plugin-barman-cloud"]}
	m.Sidecar = image{Registry: str(barman, "sidecarImage", "registry"), Repository: str(barman, "sidecarImage", "repository"), Tag: appVersions["plugin-barman-cloud"]}
	m.Collector = image{Repository: otelRepository, Tag: appVersions["opentelemetry-collector"]}
	for _, img := range []*image{&m.CNPG, &m.Barman, &m.Sidecar, &m.Collector} {
		ref := img.Repository + ":" + img.Tag
		if img.Registry != "" {
			ref = img.Registry + "/" + ref
		}
		if img.Repository == "" || img.Tag == "" {
			return nil, fmt.Errorf("no repository or tag for %q", ref)
		}
		if img.Digest, err = digest(ctx, ref); err != nil {
			return nil, err
		}
	}

	tmpl, err := template.New("manifest").Funcs(template.FuncMap{"q": strconv.Quote}).Parse(manifestTemplate)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	if err := tmpl.Execute(&out, m); err != nil {
		return nil, err
	}
	// What the e2e run reads has to be there.
	if _, err := versions.Parse(out.Bytes()); err != nil {
		return nil, fmt.Errorf("the manifest it made: %w", err)
	}
	return out.Bytes(), nil
}

// str is the string at the path of keys in a chart's values, or "".
func str(values map[string]any, keys ...string) string {
	var v any = values
	for _, k := range keys {
		m, ok := v.(map[string]any)
		if !ok {
			return ""
		}
		v = m[k]
	}
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// showChart is the appVersion and the default values of a chart version.
func showChart(ctx context.Context, repo, name, version string) (string, map[string]any, error) {
	var chart struct {
		Version    string `yaml:"version"`
		AppVersion string `yaml:"appVersion"`
	}
	var values map[string]any
	for what, into := range map[string]any{"chart": &chart, "values": &values} {
		out, err := exec.CommandContext(ctx, "helm", "show", what, "--repo", repo, name, "--version", version).Output()
		if err != nil {
			return "", nil, fmt.Errorf("helm show %s %s %s: %w", what, name, version, commandError(err))
		}
		if err := yaml.Unmarshal(out, into); err != nil {
			return "", nil, fmt.Errorf("helm show %s %s %s: %w", what, name, version, err)
		}
	}
	if chart.Version != version {
		return "", nil, fmt.Errorf("the chart %s %s is version %s: give its exact version", name, version, chart.Version)
	}
	if chart.AppVersion == "" {
		return "", nil, fmt.Errorf("the chart %s %s has no appVersion", name, version)
	}
	return chart.AppVersion, values, nil
}

func commandError(err error) error {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return fmt.Errorf("%w: %s", err, bytes.TrimSpace(exit.Stderr))
	}
	return err
}

const k3sReleases = "https://github.com/k3s-io/k3s/releases/download/"

// k3s is the k3s image of a release, its airgap tarballs and their images.
func k3s(ctx context.Context, release string) (versions.K3s, error) {
	k := versions.K3s{Version: release, Airgap: map[string]versions.Download{}}
	base := k3sReleases + strings.ReplaceAll(release, "+", "%2B") + "/"
	ref := "rancher/k3s:" + strings.ReplaceAll(release, "+", "-")
	var err error
	if k.Image, err = pinned(ctx, ref); err != nil {
		return k, err
	}
	for _, arch := range versions.Architectures {
		file := "k3s-airgap-images-" + arch + ".tar.zst"
		sums, err := get(ctx, base+"sha256sum-"+arch+".txt")
		if err != nil {
			return k, err
		}
		sum, err := sumOf(sums, file)
		if err != nil {
			return k, fmt.Errorf("sha256sum-%s.txt of k3s %s: %w", arch, release, err)
		}
		k.Airgap[arch] = versions.Download{URL: base + file, SHA256: sum}
	}
	list, err := get(ctx, base+"k3s-images.txt")
	if err != nil {
		return k, err
	}
	k.Images = strings.Fields(string(list))
	return k, nil
}

// tools are kubectl of the k3s release's Kubernetes version, kubectl-cnpg
// of the operator's version and the CA rotation script of the k3s release.
func tools(ctx context.Context, k3sRelease, cnpgVersion string) (versions.Tools, error) {
	kube, _, _ := strings.Cut(k3sRelease, "+")
	t := versions.Tools{
		Kubectl:     versions.Tool{Version: kube, SHA256: map[string]string{}},
		KubectlCNPG: versions.Tool{Version: cnpgVersion, SHA256: map[string]string{}},
	}
	cnpgSums, err := get(ctx, fmt.Sprintf("https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v%s/cnpg-%s-checksums.txt", cnpgVersion, cnpgVersion))
	if err != nil {
		return t, err
	}
	for _, arch := range versions.Architectures {
		sum, err := get(ctx, "https://dl.k8s.io/release/"+kube+"/bin/linux/"+arch+"/kubectl.sha256")
		if err != nil {
			return t, err
		}
		t.Kubectl.SHA256[arch] = strings.TrimSpace(string(sum))
		cnpgArch := map[string]string{"amd64": "x86_64", "arm64": "arm64"}[arch]
		if t.KubectlCNPG.SHA256[arch], err = sumOf(cnpgSums, "kubectl-cnpg_"+cnpgVersion+"_linux_"+cnpgArch+".tar.gz"); err != nil {
			return t, fmt.Errorf("the checksums of kubectl-cnpg %s: %w", cnpgVersion, err)
		}
	}
	t.RotateCA.URL = "https://raw.githubusercontent.com/k3s-io/k3s/" + strings.ReplaceAll(k3sRelease, "+", "%2B") + "/contrib/util/rotate-default-ca-certs.sh"
	script, err := get(ctx, t.RotateCA.URL)
	if err != nil {
		return t, err
	}
	t.RotateCA.SHA256 = fmt.Sprintf("%x", sha256.Sum256(script))
	return t, nil
}

// sumOf is the sha256 of file in a sha256sum list.
func sumOf(sums []byte, file string) (string, error) {
	lines := bufio.NewScanner(bytes.NewReader(sums))
	for lines.Scan() {
		f := strings.Fields(lines.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == file {
			return f[0], nil
		}
	}
	if err := lines.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("no sha256 of %s", file)
}

// pinned is an image reference by tag with its digest added.
func pinned(ctx context.Context, ref string) (string, error) {
	if strings.Contains(ref, "@") {
		return "", fmt.Errorf("%s: give the image by tag; the digest is looked up", ref)
	}
	d, err := digest(ctx, ref)
	return ref + "@" + d, err
}

var client = &http.Client{Timeout: 5 * time.Minute}

func get(ctx context.Context, address string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	body, err := io.ReadAll(resp.Body)
	if err := errors.Join(err, resp.Body.Close()); err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", address, resp.Status)
	}
	return body, nil
}

// The kinds of manifest a registry may answer with: an index, or a single
// manifest when the image has no index.
var manifestKinds = strings.Join([]string{
	"application/vnd.oci.image.index.v1+json",
	"application/vnd.docker.distribution.manifest.list.v2+json",
	"application/vnd.oci.image.manifest.v1+json",
	"application/vnd.docker.distribution.manifest.v2+json",
}, ", ")

var sha256Digest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// digest is the digest that a pull of the image by tag resolves to, the
// digest of its index, and which containerd lists in repoDigests. It asks
// the registry, with an anonymous token when the registry wants one.
func digest(ctx context.Context, ref string) (string, error) {
	repo := versions.Repository(ref)
	tag := strings.TrimPrefix(versions.Reference(ref), repo+":")
	if tag == repo {
		return "", fmt.Errorf("%s has no tag", ref)
	}
	host, path, _ := strings.Cut(repo, "/")
	if host == "docker.io" {
		host = "registry-1.docker.io"
	}
	address := "https://" + host + "/v2/" + path + "/manifests/" + tag
	token := ""
	for range 2 {
		req, err := http.NewRequestWithContext(ctx, http.MethodHead, address, nil)
		if err != nil {
			return "", err
		}
		req.Header.Set("Accept", manifestKinds)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			return "", err
		}
		if err := resp.Body.Close(); err != nil {
			return "", err
		}
		switch {
		case resp.StatusCode == http.StatusUnauthorized && token == "":
			if token, err = anonymousToken(ctx, resp.Header.Get("WWW-Authenticate"), path); err != nil {
				return "", fmt.Errorf("%s: %w", ref, err)
			}
			continue
		case resp.StatusCode != http.StatusOK:
			return "", fmt.Errorf("HEAD %s: %s", address, resp.Status)
		}
		d := resp.Header.Get("Docker-Content-Digest")
		if !sha256Digest.MatchString(d) {
			return "", fmt.Errorf("%s: the registry gave the digest %q", ref, d)
		}
		return d, nil
	}
	return "", fmt.Errorf("%s: the registry refused the token", ref)
}

var challengeParam = regexp.MustCompile(`(\w+)="([^"]*)"`)

// anonymousToken gets a pull token as a WWW-Authenticate Bearer challenge
// says.
func anonymousToken(ctx context.Context, challenge, path string) (string, error) {
	if !strings.HasPrefix(challenge, "Bearer ") {
		return "", fmt.Errorf("no Bearer challenge: %q", challenge)
	}
	params := map[string]string{"scope": "repository:" + path + ":pull"}
	for _, p := range challengeParam.FindAllStringSubmatch(challenge, -1) {
		params[p[1]] = p[2]
	}
	realm := params["realm"]
	if realm == "" {
		return "", fmt.Errorf("no realm in %q", challenge)
	}
	q := url.Values{"scope": {params["scope"]}}
	if s := params["service"]; s != "" {
		q.Set("service", s)
	}
	body, err := get(ctx, realm+"?"+q.Encode())
	if err != nil {
		return "", err
	}
	var answer struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &answer); err != nil {
		return "", fmt.Errorf("the token from %s: %w", realm, err)
	}
	if answer.Token != "" {
		return answer.Token, nil
	}
	if answer.AccessToken != "" {
		return answer.AccessToken, nil
	}
	return "", fmt.Errorf("no token from %s", realm)
}
