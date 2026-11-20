// Package lookup finds what the commands of e2e/cmd need on the network:
// files, the digests and tags of images, the appVersion of an OCI chart,
// and the sha256 of kubectl-cnpg. It reads every registry anonymously.
package lookup

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
)

var client = &http.Client{Timeout: 5 * time.Minute}

// Get is the body of a GET of address, which has to answer 200.
func Get(ctx context.Context, address string) ([]byte, error) {
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

// SumOf is the sha256 of file in a sha256sum list.
func SumOf(sums []byte, file string) (string, error) {
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

// KubectlCNPG is the sha256 of the kubectl-cnpg download of a CNPG
// version, for each architecture of versions.Architectures.
func KubectlCNPG(ctx context.Context, version string) (map[string]string, error) {
	sums, err := Get(ctx, fmt.Sprintf("https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v%s/cnpg-%s-checksums.txt", version, version))
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, arch := range versions.Architectures {
		cnpgArch := map[string]string{"amd64": "x86_64", "arm64": "arm64"}[arch]
		if out[arch], err = SumOf(sums, "kubectl-cnpg_"+version+"_linux_"+cnpgArch+".tar.gz"); err != nil {
			return nil, fmt.Errorf("the checksums of kubectl-cnpg %s: %w", version, err)
		}
	}
	return out, nil
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

// Digest is the digest that a pull of the image by tag resolves to, the
// digest of its index, and which containerd lists in repoDigests.
func Digest(ctx context.Context, ref string) (string, error) {
	repo := versions.Repository(ref)
	tag := strings.TrimPrefix(versions.Reference(ref), repo+":")
	if tag == repo {
		return "", fmt.Errorf("%s has no tag", ref)
	}
	resp, _, err := fetch(ctx, http.MethodHead, repo, "manifests/"+tag, manifestKinds)
	if err != nil {
		return "", err
	}
	d := resp.Header.Get("Docker-Content-Digest")
	if !sha256Digest.MatchString(d) {
		return "", fmt.Errorf("%s: the registry gave the digest %q", ref, d)
	}
	return d, nil
}

// Tags are every tag of a repository, such as
// ghcr.io/djosh34/hardened-mirror/postgres, page by page.
func Tags(ctx context.Context, repo string) ([]string, error) {
	_, name, _ := strings.Cut(repo, "/")
	var tags []string
	for page := "tags/list?n=1000"; page != ""; {
		resp, body, err := fetch(ctx, http.MethodGet, repo, page, "application/json")
		if err != nil {
			return nil, err
		}
		var list struct {
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal(body, &list); err != nil {
			return nil, fmt.Errorf("the tags of %s: %w", repo, err)
		}
		tags = append(tags, list.Tags...)
		// The next page is in a Link header: </v2/<name>/tags/list?…>; rel="next".
		page = ""
		if next, ok := strings.CutSuffix(resp.Header.Get("Link"), `>; rel="next"`); ok {
			page = strings.TrimPrefix(next, "</v2/"+name+"/")
		}
	}
	return tags, nil
}

// ChartAppVersion is the appVersion of an OCI chart by its tag, from the
// chart's config, which holds its Chart.yaml as JSON.
func ChartAppVersion(ctx context.Context, repo, tag string) (string, error) {
	_, body, err := fetch(ctx, http.MethodGet, repo, "manifests/"+tag, "application/vnd.oci.image.manifest.v1+json")
	if err != nil {
		return "", err
	}
	var m struct {
		Config struct {
			MediaType string `json:"mediaType"`
			Digest    string `json:"digest"`
		} `json:"config"`
	}
	if err := json.Unmarshal(body, &m); err != nil {
		return "", fmt.Errorf("%s:%s: %w", repo, tag, err)
	}
	if m.Config.MediaType != "application/vnd.cncf.helm.config.v1+json" || !sha256Digest.MatchString(m.Config.Digest) {
		return "", fmt.Errorf("%s:%s is not a Helm chart", repo, tag)
	}
	if _, body, err = fetch(ctx, http.MethodGet, repo, "blobs/"+m.Config.Digest, "*/*"); err != nil {
		return "", err
	}
	var chart struct {
		AppVersion string `json:"appVersion"`
	}
	if err := json.Unmarshal(body, &chart); err != nil {
		return "", fmt.Errorf("the config of %s:%s: %w", repo, tag, err)
	}
	if chart.AppVersion == "" {
		return "", fmt.Errorf("the chart %s:%s has no appVersion", repo, tag)
	}
	return chart.AppVersion, nil
}

// fetch makes a request to the registry API of repo at /v2/<name>/<path>,
// with an anonymous token when the registry wants one, and reads the body
// of its 200 answer.
func fetch(ctx context.Context, method, repo, path, accept string) (*http.Response, []byte, error) {
	host, name, _ := strings.Cut(repo, "/")
	if host == "docker.io" {
		host = "registry-1.docker.io"
	}
	address := "https://" + host + "/v2/" + name + "/" + path
	token := ""
	for range 2 {
		req, err := http.NewRequestWithContext(ctx, method, address, nil)
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("Accept", accept)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, nil, err
		}
		body, err := io.ReadAll(resp.Body)
		if err := errors.Join(err, resp.Body.Close()); err != nil {
			return nil, nil, err
		}
		switch {
		case resp.StatusCode == http.StatusUnauthorized && token == "":
			if token, err = anonymousToken(ctx, resp.Header.Get("WWW-Authenticate"), name); err != nil {
				return nil, nil, fmt.Errorf("%s: %w", repo, err)
			}
			continue
		case resp.StatusCode != http.StatusOK:
			return nil, nil, fmt.Errorf("%s %s: %s", method, address, resp.Status)
		}
		return resp, body, nil
	}
	return nil, nil, fmt.Errorf("%s: the registry refused the token", repo)
}

var challengeParam = regexp.MustCompile(`(\w+)="([^"]*)"`)

// anonymousToken gets a pull token as a WWW-Authenticate Bearer challenge
// says.
func anonymousToken(ctx context.Context, challenge, name string) (string, error) {
	if !strings.HasPrefix(challenge, "Bearer ") {
		return "", fmt.Errorf("no Bearer challenge: %q", challenge)
	}
	params := map[string]string{"scope": "repository:" + name + ":pull"}
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
	body, err := Get(ctx, realm+"?"+q.Encode())
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
