package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

// A release of charts/releases.yaml.
type release struct {
	Name      string   `yaml:"name"`
	Namespace string   `yaml:"namespace"`
	Chart     string   `yaml:"chart"`
	Values    []string `yaml:"values"`
}

func readReleases(file string) ([]release, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	var releases []release
	if err := yaml.Unmarshal(data, &releases); err != nil {
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	for _, r := range releases {
		if r.Name == "" || r.Namespace == "" || r.Chart == "" {
			return nil, fmt.Errorf("%s: every release needs name, namespace and chart", file)
		}
	}
	return releases, nil
}

// installCharts installs the releases of charts/releases.yaml of the run's
// settings in their order. helm dependency build writes the values charts'
// dependencies next to them, so the charts are copied out of the settings
// first and the settings stay as they are. Each release gets its values
// files from the settings, then values/<release>.yaml when it exists. It
// returns the chart and values of the cluster's release.
func installCharts(ctx context.Context) (chartValues, error) {
	charts := filepath.Join(workDir, "charts")
	if err := os.CopyFS(charts, os.DirFS(filepath.Join(settingsDir(), "charts"))); err != nil {
		return chartValues{}, fmt.Errorf("copying the charts: %w", err)
	}
	releases, err := readReleases(filepath.Join(charts, "releases.yaml"))
	if err != nil {
		return chartValues{}, err
	}
	var cluster chartValues
	for _, r := range releases {
		chart := filepath.Join(charts, r.Chart)
		if _, err := helm(ctx, 5*time.Minute, "dependency", "build", "--skip-refresh", chart); err != nil {
			return chartValues{}, err
		}
		var values []string
		for _, v := range r.Values {
			values = append(values, "--values", filepath.Join(settingsDir(), v))
		}
		own := filepath.Join(settingsDir(), "values", r.Name+".yaml")
		switch _, err := os.Stat(own); {
		case err == nil:
			values = append(values, "--values", own)
		case !errors.Is(err, fs.ErrNotExist):
			return chartValues{}, err
		}
		logf("installing %s from charts/%s", r.Name, r.Chart)
		args := append([]string{"upgrade", "--install", r.Name, chart, "--namespace", r.Namespace,
			"--create-namespace", "--wait", "--timeout", "15m"}, values...)
		if _, err := helm(ctx, 16*time.Minute, args...); err != nil {
			return chartValues{}, err
		}
		if r.Name == clusterRelease {
			cluster = chartValues{chart: chart, values: values}
		}
	}
	if cluster.chart == "" {
		return chartValues{}, fmt.Errorf("charts/releases.yaml has no release %s", clusterRelease)
	}
	return cluster, nil
}

// chartValues are the directory of a release's chart in the e2e test's copy,
// and its --values arguments.
type chartValues struct {
	chart  string
	values []string
}

func helm(ctx context.Context, limit time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	return command(ctx, "helm", args...)
}

// A patch of k3s/patches.yaml: kubectl patch --type=merge of an object of
// k3s's own manifests, as a person runs it once on a new cluster.
type k3sPatch struct {
	Target    string         `yaml:"target"` // such as deployment/coredns
	Namespace string         `yaml:"namespace"`
	Patch     map[string]any `yaml:"patch"`
}

func readK3sPatches(file string) ([]k3sPatch, error) {
	data, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var patches []k3sPatch
	if err := yaml.Unmarshal(data, &patches); err != nil {
		return nil, fmt.Errorf("%s: %w", file, err)
	}
	for _, p := range patches {
		if strings.Count(p.Target, "/") != 1 || p.Namespace == "" || len(p.Patch) == 0 {
			return nil, fmt.Errorf("%s: every patch needs a target kind/name, a namespace and a patch", file)
		}
	}
	return patches, nil
}

// patchK3s applies the settings' k3s/patches.yaml, such as one CoreDNS pod
// per node, and waits for each patched object and for Traefik, which answers
// the http-01 challenges: a DaemonSet or a Deployment, as the settings'
// k3s/manifests say.
func patchK3s(ctx context.Context) error {
	patches, err := readK3sPatches(filepath.Join(settingsDir(), "k3s", "patches.yaml"))
	if err != nil {
		return err
	}
	type object struct{ target, namespace string }
	var wait []object
	for _, p := range patches {
		patch, err := json.Marshal(p.Patch)
		if err != nil {
			return fmt.Errorf("the patch of %s: %w", p.Target, err)
		}
		// k3s creates its objects a little after the node is Ready.
		err = poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
			_, err := kubectl(ctx, "patch", p.Target, "-n", p.Namespace, "--type=merge", "-p", string(patch))
			return err
		})
		if err != nil {
			return err
		}
		wait = append(wait, object{p.Target, p.Namespace})
	}
	var traefik string
	err = poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
		var err error
		traefik, err = kubectl(ctx, "get", "daemonset,deployment", "-n", "kube-system",
			"-l", "app.kubernetes.io/name=traefik", "-o", "name")
		if err == nil && strings.Count(traefik, "/") != 1 {
			err = fmt.Errorf("not one Traefik DaemonSet or Deployment: %q", traefik)
		}
		return err
	})
	if err != nil {
		return err
	}
	for _, o := range append(wait, object{strings.TrimSpace(traefik), "kube-system"}) {
		rollout, cancel := context.WithTimeout(ctx, 5*time.Minute)
		_, err := command(rollout, "kubectl", "rollout", "status", o.target, "-n", o.namespace, "--timeout=5m")
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}

// secret is a Secret the e2e test makes before the charts, with what only the
// run knows: the EAB keys and the CA of the company CA, and the store's keys.
type secret struct {
	namespace, name string
	data            map[string]string
}

// eabSecrets are the Secrets with an EAB key of the company CA that a run
// makes, one per ACME account, since a key is good for one account: the
// samples' ClusterIssuer, and for a variant with one Issuer per Certificate
// the Issuers of the cluster's and pg-restore's server and replication
// certificates and of the collectors' client certificate. A key that no
// Issuer uses does no harm.
var eabSecrets = []struct{ namespace, name string }{
	{"cert-manager", "company-acme-eab"},
	{namespace, clusterName + "-server-acme-eab"},
	{namespace, clusterName + "-replication-acme-eab"},
	{namespace, restoredCluster + "-server-acme-eab"},
	{namespace, restoredCluster + "-replication-acme-eab"},
	{"otel", "otel-client-acme-eab"},
}

// runSecrets are the Secrets of the run, with keys[i], a new EAB key, in
// eabSecrets[i].
func runSecrets(root *ca, keys []eab) []secret {
	ca := map[string]string{"ca.crt": string(root.certPEM)}
	secrets := []secret{
		{"cert-manager", "company-ca", ca},
		{namespace, "client-ca", ca},
		{namespace, "s3-ca", ca},
		{namespace, "company-ca", ca},
		{"otel", "company-ca", ca},
		{namespace, "backup-creds", map[string]string{"ACCESS_KEY_ID": s3Access, "ACCESS_SECRET_KEY": s3Secret}},
	}
	for i, s := range eabSecrets {
		secrets = append(secrets, secret{s.namespace, s.name, map[string]string{"keyID": keys[i].id, "secret": keys[i].key}})
	}
	return secrets
}

func createSecrets(ctx context.Context, secrets []secret) error {
	made := map[string]bool{}
	for _, s := range secrets {
		if !made[s.namespace] {
			if _, err := kubectl(ctx, "create", "namespace", s.namespace); err != nil {
				return err
			}
			made[s.namespace] = true
		}
		args := []string{"create", "secret", "generic", s.name, "-n", s.namespace}
		for k, v := range s.data {
			args = append(args, "--from-literal="+k+"="+v)
		}
		if _, err := kubectl(ctx, args...); err != nil {
			return err
		}
	}
	return nil
}
