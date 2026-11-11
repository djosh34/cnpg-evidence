package main

import (
	"bytes"
	"context"
	_ "embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
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
func startNodes(ctx context.Context) error {
	for i := range nodeCount {
		if err := startNode(ctx, i); err != nil {
			return err
		}
		if i == 0 {
			if err := writeKubeconfig(ctx); err != nil {
				return err
			}
		}
		name := nodeName(i)
		err := poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
			return nodeReady(ctx, name)
		})
		if err != nil {
			return fmt.Errorf("node %s Ready: %w", name, err)
		}
		logf("node %s is Ready", name)
	}
	return nil
}

// startNode starts node i, with samples/k3s at /e2e/k3s: k3s reads
// config.yaml there, and node-init.sh copies the files of manifests/ into
// the server's manifests directory, which k3s applies. The node's data is a
// volume. The /tmp tmpfs is there because containerd tests idmapped mounts
// under /tmp at start, which fail on overlayfs; pods with hostUsers: false
// need them.
func startNode(ctx context.Context, i int) error {
	name := nodeName(i)
	join := []string{"--cluster-init"}
	if i > 0 {
		join = []string{"--server", "https://" + nodeIP(0) + ":6443"}
	}
	files, err := dirFiles(filepath.Join(samplesDir, "k3s"), "/e2e/k3s")
	if err != nil {
		return err
	}
	files["/node-init.sh"] = nodeInit
	// The run's DNS, for the kubelet and so for the pods. Without it k3s
	// sees docker's loopback resolver and gives the pods public ones.
	files["/etc/e2e-resolv.conf"] = "nameserver " + dnsIP + "\n"
	err = container{
		name: name, ip: nodeIP(i), image: k3sImage, files: files,
		opts: []string{
			"--privileged", "--tmpfs", "/run", "--tmpfs", "/var/run", "--tmpfs", "/tmp",
			"--ulimit", "nproc=65535:65535", "--ulimit", "nofile=65535:65535",
			"--env", "K3S_TOKEN=" + k3sToken, "--entrypoint", "/bin/sh",
			"--volume", name + ":/var/lib/rancher/k3s",
		},
		args: append([]string{"/node-init.sh", "--config", "/e2e/k3s/config.yaml",
			"--node-ip", nodeIP(i), "--tls-san", nodeIP(i), "--resolv-conf", "/etc/e2e-resolv.conf"}, join...),
	}.run(ctx)
	if err != nil {
		return err
	}
	logf("node %s started", name)
	return nil
}

// dirFiles are the files of dir, by their path under into.
func dirFiles(dir, into string) (map[string]string, error) {
	files := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		files[filepath.Join(into, rel)] = string(data)
		return err
	})
	return files, err
}

// writeKubeconfig waits for k3s to write its kubeconfig on the first node
// and keeps a copy that reaches its API server. docker cp starts no process
// in the node, so nothing lands in its cgroups while node-init.sh sets them
// up.
func writeKubeconfig(ctx context.Context) error {
	var config []byte
	err := poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		if _, err := command(ctx, "docker", "cp", nodeName(0)+":/etc/rancher/k3s/k3s.yaml", kubeconfig); err != nil {
			return err
		}
		var err error
		config, err = os.ReadFile(kubeconfig)
		if err == nil && len(config) == 0 {
			err = fmt.Errorf("the kubeconfig of %s is empty", nodeName(0))
		}
		return err
	})
	if err != nil {
		return err
	}
	config = bytes.ReplaceAll(config, []byte("https://127.0.0.1:6443"), []byte("https://"+nodeIP(0)+":6443"))
	return os.WriteFile(kubeconfig, config, 0o600)
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

// stopNodes stops node containers at once, as docker stop -t 0 does, as lost
// VMs.
func stopNodes(ctx context.Context, nodes ...string) error {
	if _, err := command(ctx, "docker", append([]string{"stop", "-t", "0"}, nodes...)...); err != nil {
		return err
	}
	logf("node %s stopped", strings.Join(nodes, " and "))
	return nil
}

// restartNodes starts node containers that stopNodes stopped. k3s and the
// pods of each node start again.
func restartNodes(ctx context.Context, nodes ...string) error {
	if _, err := command(ctx, "docker", append([]string{"start"}, nodes...)...); err != nil {
		return err
	}
	logf("node %s started", strings.Join(nodes, " and "))
	return nil
}

// useRunningAPI points the e2e test's kubeconfig at the API server of the
// first node that is not down.
func useRunningAPI(down []string) error {
	for i := range nodeCount {
		if slices.Contains(down, nodeName(i)) {
			continue
		}
		data, err := os.ReadFile(kubeconfig)
		if err != nil {
			return err
		}
		server := regexp.MustCompile(`https://[0-9.]+:6443`)
		return os.WriteFile(kubeconfig, server.ReplaceAll(data, []byte("https://"+nodeIP(i)+":6443")), 0o600)
	}
	return errors.New("every node is down")
}
