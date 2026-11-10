package main

import (
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/testcontainers/testcontainers-go"
)

// Three k3s servers with embedded etcd, each a privileged container, as the
// three VMs of production.
const (
	nodeCount = 3
	k3sImage  = "rancher/k3s@sha256:ada5ff2e138120efe877f76d514dedda65b304122112b982eab532732c028c89" // v1.33.13+k3s2
	k3sToken  = "example-token"
	domain    = "example.test"
)

func nodeName(i int) string { return fmt.Sprintf("k3s-%d", i+1) }
func nodeHost(i int) string { return nodeName(i) + "." + domain }
func nodeIP(i int) string   { return fmt.Sprintf("10.77.0.%d", 11+i) }

// The first process of each node: it runs k3s and starts it again when it
// exits, so the pods outlive k3s as on a VM.
//
//go:embed node-init.sh
var nodeInit string

// startNodes starts the three nodes one after another, each joining the
// first, and waits until each is Ready. It writes the kubeconfig of the
// first node's API server to workDir/kubeconfig.
func startNodes(ctx context.Context, nw *testcontainers.DockerNetwork) error {
	for i := range nodeCount {
		// Each node needs its own files: a file's reader is read once.
		files, err := k3sFiles()
		if err != nil {
			return err
		}
		c, err := startNode(ctx, nw, i, files)
		if err != nil {
			return err
		}
		if i == 0 {
			if err := writeKubeconfig(ctx, c); err != nil {
				return err
			}
		}
		name := nodeName(i)
		err = poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
			return nodeReady(ctx, name)
		})
		if err != nil {
			return fmt.Errorf("node %s Ready: %w", name, err)
		}
		logf("node %s is Ready", name)
	}
	return nil
}

// k3sFiles are the files of the mounted k3s directory, placed where k3s
// reads them: config.yaml as /etc/rancher/k3s/config.yaml, each file of
// manifests/ in the server's manifests directory, which k3s applies.
func k3sFiles() ([]testcontainers.ContainerFile, error) {
	dir := filepath.Join(benchDir, "k3s")
	config, err := os.ReadFile(filepath.Join(dir, "config.yaml"))
	if err != nil {
		return nil, err
	}
	files := []testcontainers.ContainerFile{
		file("/etc/rancher/k3s/config.yaml", string(config)),
		file("/node-init.sh", nodeInit),
		// The bench's DNS, for the kubelet and so for the pods. Without it k3s
		// sees docker's loopback resolver and gives the pods public ones.
		file("/etc/bench-resolv.conf", "nameserver "+dnsIP+"\n"),
	}
	manifests, err := filepath.Glob(filepath.Join(dir, "manifests", "*.yaml"))
	if err != nil {
		return nil, err
	}
	for _, m := range manifests {
		data, err := os.ReadFile(m)
		if err != nil {
			return nil, err
		}
		files = append(files, file("/var/lib/rancher/k3s/server/manifests/"+filepath.Base(m), string(data)))
	}
	return files, nil
}

// startNode starts node i. The /tmp tmpfs is there because containerd tests
// idmapped mounts under /tmp at start, which fail on overlayfs; pods with
// hostUsers: false need them. The node's data is a volume on the bench's
// disk.
func startNode(ctx context.Context, nw *testcontainers.DockerNetwork, i int, files []testcontainers.ContainerFile) (*testcontainers.DockerContainer, error) {
	join := []string{"--cluster-init"}
	if i > 0 {
		join = []string{"--server", "https://" + nodeIP(0) + ":6443"}
	}
	name := nodeName(i)
	args := append(join, "--node-ip", nodeIP(i), "--tls-san", nodeIP(i), "--resolv-conf", "/etc/bench-resolv.conf")
	c, err := start(ctx, testcontainers.ContainerRequest{
		Name:       name,
		Image:      k3sImage,
		Entrypoint: []string{"/bin/sh", "/node-init.sh"},
		Cmd:        args,
		Env:        map[string]string{"K3S_TOKEN": k3sToken},
		Mounts:     testcontainers.ContainerMounts{testcontainers.VolumeMount(name, "/var/lib/rancher/k3s")},
		Files:      files,
		HostConfigModifier: func(hc *container.HostConfig) {
			hc.Privileged = true
			hc.Tmpfs = map[string]string{"/run": "", "/var/run": "", "/tmp": ""}
			hc.Ulimits = []*container.Ulimit{
				{Name: "nproc", Soft: 65535, Hard: 65535},
				{Name: "nofile", Soft: 65535, Hard: 65535},
			}
		},
	}, on(nw, nodeIP(i), name))
	if err != nil {
		return nil, err
	}
	logf("node %s started", name)
	return c, nil
}

// writeKubeconfig waits for k3s to write its kubeconfig on the first node
// and keeps a copy that reaches its API server.
func writeKubeconfig(ctx context.Context, c *testcontainers.DockerContainer) error {
	var config string
	err := poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		r, err := c.CopyFileFromContainer(ctx, "/etc/rancher/k3s/k3s.yaml")
		if err != nil {
			return err
		}
		data, err := io.ReadAll(r)
		if err := closeWith(err, r); err != nil {
			return err
		}
		if len(data) == 0 {
			return fmt.Errorf("the kubeconfig of %s is empty", nodeName(0))
		}
		config = string(data)
		return nil
	})
	if err != nil {
		return err
	}
	ip := nodeIP(0)
	config = strings.ReplaceAll(config, "https://127.0.0.1:6443", "https://"+ip+":6443")
	return os.WriteFile(kubeconfig, []byte(config), 0o600)
}

func nodeReady(ctx context.Context, name string) error {
	status, err := kubectl(ctx, "get", "node", name, "-o", `jsonpath={.status.conditions[?(@.type=="Ready")].status}`)
	if err != nil {
		return err
	}
	if status != "True" {
		return fmt.Errorf("node %s Ready: %q", name, status)
	}
	return nil
}
