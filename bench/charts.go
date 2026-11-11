package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
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

// installCharts installs the releases of charts/releases.yaml in their
// order. The charts are copied out of the read-only mounted directory first,
// since helm dependency build writes the values charts' dependencies next to
// them. Each release gets its values files from the mounted directory, then
// values/<release>.yaml when it exists.
func installCharts(ctx context.Context) error {
	charts := filepath.Join(workDir, "charts")
	if err := os.CopyFS(charts, os.DirFS(filepath.Join(benchDir, "charts"))); err != nil {
		return fmt.Errorf("copying the charts: %w", err)
	}
	releases, err := readReleases(filepath.Join(charts, "releases.yaml"))
	if err != nil {
		return err
	}
	for _, r := range releases {
		dir := filepath.Join(charts, r.Chart)
		if _, err := helm(ctx, 5*time.Minute, "dependency", "build", "--skip-refresh", dir); err != nil {
			return err
		}
		values, err := valuesOf(r)
		if err != nil {
			return err
		}
		args := append([]string{"upgrade", "--install", r.Name, dir, "--namespace", r.Namespace, "--create-namespace",
			"--wait", "--timeout", "15m"}, values...)
		logf("installing %s from charts/%s", r.Name, r.Chart)
		if _, err := helm(ctx, 16*time.Minute, args...); err != nil {
			return err
		}
	}
	return nil
}

// valuesOf are the --values arguments of a release: its values files from
// the mounted directory, then values/<release>.yaml when it exists.
func valuesOf(r release) ([]string, error) {
	var args []string
	for _, v := range r.Values {
		args = append(args, "--values", filepath.Join(benchDir, v))
	}
	own := filepath.Join(benchDir, "values", r.Name+".yaml")
	switch _, err := os.Stat(own); {
	case err == nil:
		args = append(args, "--values", own)
	case !errors.Is(err, fs.ErrNotExist):
		return nil, err
	}
	return args, nil
}

// clusterChart is the release of the cluster, and the directory of its
// chart in the bench's copy of the charts.
func clusterChart() (release, string, error) {
	charts := filepath.Join(workDir, "charts")
	releases, err := readReleases(filepath.Join(charts, "releases.yaml"))
	if err != nil {
		return release{}, "", err
	}
	for _, r := range releases {
		if r.Name == clusterRelease {
			return r, filepath.Join(charts, r.Chart), nil
		}
	}
	return release{}, "", fmt.Errorf("charts/releases.yaml has no release %s", clusterRelease)
}

// upgradeCluster changes the cluster's release: helm upgrade with the values
// it has, and more.
func upgradeCluster(ctx context.Context, more ...string) error {
	_, dir, err := clusterChart()
	if err != nil {
		return err
	}
	args := append([]string{"upgrade", clusterRelease, dir, "--namespace", namespace, "--reuse-values"}, more...)
	_, err = helm(ctx, 5*time.Minute, args...)
	return err
}

// installRestore installs the cluster's chart with the cluster's values as a
// new cluster that restores the cluster's backups from the store, as
// docs/samples.md says. It gets its own rw LoadBalancer and no read
// LoadBalancer.
func installRestore(ctx context.Context, name string) error {
	r, dir, err := clusterChart()
	if err != nil {
		return err
	}
	values, err := valuesOf(r)
	if err != nil {
		return err
	}
	args := append([]string{"install", name, dir, "--namespace", namespace}, values...)
	args = append(args, "--set", "cluster.name="+name, "--set", "recovery.enabled=true",
		"--set", "recovery.sourceCluster="+clusterName, "--set", "rwLoadBalancer.name="+name+"-rw-lb",
		"--set", "readLoadBalancer=null")
	_, err = helm(ctx, 5*time.Minute, args...)
	return err
}

func helm(ctx context.Context, limit time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	return command(ctx, nil, "helm", args...)
}

// spreadK3sServices runs one pod of CoreDNS and metrics-server on every
// node, as docs/samples.md does on production's nodes: they come from k3s's
// own manifests, not from a chart. It waits for them and for Traefik, which
// k3s runs as a DaemonSet from k3s/manifests and which answers the http-01
// challenges.
func spreadK3sServices(ctx context.Context) error {
	err := poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
		if _, err := kubectl(ctx, "scale", "deployment", "coredns", "-n", "kube-system", "--replicas=3"); err != nil {
			return err
		}
		_, err := kubectl(ctx, "patch", "deployment", "metrics-server", "-n", "kube-system", "--type=merge", "-p",
			`{"spec": {"replicas": 3, "template": {"spec": {"affinity": {"podAntiAffinity": {
			"requiredDuringSchedulingIgnoredDuringExecution": [{"topologyKey": "kubernetes.io/hostname",
			"labelSelector": {"matchLabels": {"k8s-app": "metrics-server"}}}]}}}}}}`)
		if err != nil {
			return err
		}
		_, err = kubectl(ctx, "get", "daemonset", "traefik", "-n", "kube-system")
		return err
	})
	if err != nil {
		return err
	}
	for _, d := range []string{"deployment/coredns", "deployment/metrics-server", "daemonset/traefik"} {
		rollout, cancel := context.WithTimeout(ctx, 5*time.Minute)
		_, err := command(rollout, nil, "kubectl", "rollout", "status", d, "-n", "kube-system", "--timeout=5m")
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}

// secret is a Secret the bench makes before the charts, with what only the
// run knows: the EAB key and the CA of the company CA, and the store's keys.
type secret struct {
	namespace, name string
	data            map[string]string
}

func runSecrets(root *ca, issuerKey eab) []secret {
	ca := map[string]string{"ca.crt": string(root.certPEM)}
	return []secret{
		{"cert-manager", "company-acme-eab", map[string]string{"keyID": issuerKey.id, "secret": issuerKey.key}},
		{"cert-manager", "company-ca", ca},
		{namespace, "client-ca", ca},
		{namespace, "s3-ca", ca},
		{"otel", "company-ca", ca},
		{namespace, "backup-creds", map[string]string{"ACCESS_KEY_ID": s3Access, "ACCESS_SECRET_KEY": s3Secret}},
	}
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
