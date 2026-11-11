package main

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"os"
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

// startNode starts node i, with the mounted k3s directory at /bench/k3s:
// k3s reads config.yaml there, and node-init.sh copies the files of
// manifests/ into the server's manifests directory, which k3s applies. The
// node's data is a volume on the bench's disk. The /tmp tmpfs is there
// because containerd tests idmapped mounts under /tmp at start, which fail
// on overlayfs; pods with hostUsers: false need them.
func startNode(ctx context.Context, i int) error {
	name := nodeName(i)
	join := []string{"--cluster-init"}
	if i > 0 {
		join = []string{"--server", "https://" + nodeIP(0) + ":6443"}
	}
	err := container{
		name: name, ip: nodeIP(i), image: k3sImage,
		opts: []string{
			"--privileged", "--tmpfs", "/run", "--tmpfs", "/var/run", "--tmpfs", "/tmp",
			"--ulimit", "nproc=65535:65535", "--ulimit", "nofile=65535:65535",
			"--env", "K3S_TOKEN=" + k3sToken, "--entrypoint", "/bin/sh",
			"--volume", name + ":/var/lib/rancher/k3s", "--volume", benchDir + "/k3s:/bench/k3s:ro",
		},
		args: append([]string{"/node-init.sh", "--config", "/bench/k3s/config.yaml",
			"--node-ip", nodeIP(i), "--tls-san", nodeIP(i), "--resolv-conf", "/etc/bench-resolv.conf"}, join...),
		files: map[string]string{
			"/node-init.sh": nodeInit,
			// The bench's DNS, for the kubelet and so for the pods. Without it
			// k3s sees docker's loopback resolver and gives the pods public ones.
			"/etc/bench-resolv.conf": "nameserver " + dnsIP + "\n",
		},
	}.run(ctx)
	if err != nil {
		return err
	}
	logf("node %s started", name)
	return nil
}

// writeKubeconfig waits for k3s to write its kubeconfig on the first node
// and keeps a copy that reaches its API server.
func writeKubeconfig(ctx context.Context) error {
	var config string
	err := poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		var err error
		config, err = command(ctx, "docker", "exec", nodeName(0), "cat", "/etc/rancher/k3s/k3s.yaml")
		if err == nil && config == "" {
			err = fmt.Errorf("the kubeconfig of %s is empty", nodeName(0))
		}
		return err
	})
	if err != nil {
		return err
	}
	config = strings.ReplaceAll(config, "https://127.0.0.1:6443", "https://"+nodeIP(0)+":6443")
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

// useRunningAPI points the bench's kubeconfig at the API server of the
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
