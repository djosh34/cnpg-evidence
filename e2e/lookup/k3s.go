package lookup

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
)

// k3sChannel is k3s's latest channel. It redirects to the release page of
// the newest k3s release, minors included, and never to a release
// candidate.
const k3sChannel = "https://update.k3s.io/v1-release/channels/latest"

var k3sRelease = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$`)

// K3sLatest is the k3s release that k3s's latest channel points to, such as
// v1.37.2+k3s1.
func K3sLatest(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, k3sChannel, nil)
	if err != nil {
		return "", err
	}
	noRedirect := *client
	noRedirect.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := noRedirect.Do(req)
	if err != nil {
		return "", err
	}
	if err := resp.Body.Close(); err != nil {
		return "", err
	}
	location := resp.Header.Get("Location")
	_, release, _ := strings.Cut(location, "/k3s-io/k3s/releases/tag/")
	if resp.StatusCode != http.StatusFound || !k3sRelease.MatchString(release) {
		return "", fmt.Errorf("GET %s: %s to %q, not to a k3s release", k3sChannel, resp.Status, location)
	}
	return release, nil
}

const k3sReleases = "https://github.com/k3s-io/k3s/releases/download/"

// K3s is the k3s image of a release by digest, its airgap tarballs and the
// images in them, from the release's k3s-images.txt.
func K3s(ctx context.Context, release string) (versions.K3s, error) {
	k := versions.K3s{Version: release, Airgap: map[string]versions.Download{}}
	base := k3sReleases + strings.ReplaceAll(release, "+", "%2B") + "/"
	ref := "rancher/k3s:" + strings.ReplaceAll(release, "+", "-")
	digest, err := Digest(ctx, ref)
	if err != nil {
		return k, err
	}
	k.Image = ref + "@" + digest
	for _, arch := range versions.Architectures {
		file := "k3s-airgap-images-" + arch + ".tar.zst"
		sums, err := Get(ctx, base+"sha256sum-"+arch+".txt")
		if err != nil {
			return k, err
		}
		sum, err := SumOf(sums, file)
		if err != nil {
			return k, fmt.Errorf("sha256sum-%s.txt of k3s %s: %w", arch, release, err)
		}
		k.Airgap[arch] = versions.Download{URL: base + file, SHA256: sum}
	}
	list, err := Get(ctx, base+"k3s-images.txt")
	if err != nil {
		return k, err
	}
	k.Images = strings.Fields(string(list))
	if len(k.Images) == 0 {
		return k, errors.New("k3s-images.txt of k3s " + release + " is empty")
	}
	return k, nil
}

// Kubectl is kubectl of a k3s release's Kubernetes version, with its sha256
// for each architecture.
func Kubectl(ctx context.Context, release string) (versions.Tool, error) {
	kube, _, _ := strings.Cut(release, "+")
	t := versions.Tool{Version: kube, SHA256: map[string]string{}}
	for _, arch := range versions.Architectures {
		sum, err := Get(ctx, "https://dl.k8s.io/release/"+kube+"/bin/linux/"+arch+"/kubectl.sha256")
		if err != nil {
			return t, err
		}
		t.SHA256[arch] = strings.TrimSpace(string(sum))
	}
	return t, nil
}

// RotateCA is k3s's CA rotation script of a k3s release, with its sha256.
func RotateCA(ctx context.Context, release string) (versions.Script, error) {
	s := versions.Script{URL: "https://raw.githubusercontent.com/k3s-io/k3s/" + strings.ReplaceAll(release, "+", "%2B") + "/contrib/util/rotate-default-ca-certs.sh"}
	script, err := Get(ctx, s.URL)
	if err != nil {
		return s, err
	}
	s.SHA256 = fmt.Sprintf("%x", sha256.Sum256(script))
	return s, nil
}
