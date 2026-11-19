package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"time"
)

// Three k3s servers with embedded etcd, each a privileged container of the
// manifest's k3s image, as the three VMs of production.
const (
	nodeCount = 3
	k3sToken  = "example-token"
	domain    = "example.test"
	// Where k3s finds image tarballs to import when it starts.
	airgapDir = "/var/lib/rancher/k3s/agent/images"
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
	airgap, err := downloadAirgap(ctx)
	if err != nil {
		return err
	}
	for i := range nodeCount {
		if err := startNode(ctx, i, airgap); err != nil {
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
			traceNode(ctx, name)
			return fmt.Errorf("node %s Ready: %w", name, err)
		}
		logf("node %s is Ready", name)
	}
	return nil
}

// traceStuck writes to the node's log, the stderr of its first process,
// where its k3s is stuck: the kernel's stack of each thread of k3s that
// waits in the kernel, then the stack of every goroutine, which Go prints
// when k3s gets SIGQUIT. node-init.sh starts k3s again after that.
const traceStuck = `read -r pid <` + k3sPIDFile + `
{
  for task in "/proc/$pid"/task/*; do
    if grep -q '^State:[[:space:]]*D' "$task/status"; then
      echo "e2e: thread ${task##*/} of k3s waits in the kernel:"
      cat "$task/stack"
    fi
  done
  echo "e2e: the goroutines of k3s follow"
} >/proc/1/fd/2 2>&1
kill -QUIT "$pid"`

// traceNode leaves in the log of a node that never turned Ready where its
// k3s is stuck, then gives Go 5 s to print the goroutines.
func traceNode(ctx context.Context, node string) {
	if _, err := command(ctx, "docker", "exec", node, "sh", "-c", traceStuck); err != nil {
		logf("tracing k3s on %s: %v", node, err)
		return
	}
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
	}
}

// downloadAirgap downloads the manifest's airgap image tarball of this
// machine's architecture into workDir, checks its sha256 and returns its
// path.
func downloadAirgap(ctx context.Context) (string, error) {
	a, ok := manifest.K3s.Airgap[runtime.GOARCH]
	if !ok {
		return "", fmt.Errorf("the manifest has no k3s airgap tarball for %s", runtime.GOARCH)
	}
	file := filepath.Join(workDir, path.Base(a.URL))
	logf("downloading the k3s images, %s", a.URL)
	download, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	if _, err := command(download, "retry", "wget", "-q", "-O", file, a.URL); err != nil {
		return "", err
	}
	f, err := os.Open(file)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	_, err = io.Copy(h, f)
	if err := errors.Join(err, f.Close()); err != nil {
		return "", err
	}
	if sum := fmt.Sprintf("%x", h.Sum(nil)); sum != a.SHA256 {
		return "", fmt.Errorf("%s has the sha256 %s, the manifest says %s", a.URL, sum, a.SHA256)
	}
	return file, nil
}

// startNode starts node i, with k3s/ of the settings at /e2e/k3s: k3s reads
// config.yaml there, and node-init.sh copies the files of manifests/ into
// the server's manifests directory, which k3s applies. The airgap tarball
// is in airgapDir before k3s starts, so k3s imports its own images from it
// instead of pulling them. The node's k3s data is a volume, and its
// local-path volumes are on its own data filesystem (disks.go). The /tmp
// tmpfs is there because containerd tests idmapped mounts under /tmp at
// start, which fail on overlayfs; pods with hostUsers: false need them.
func startNode(ctx context.Context, i int, airgap string) error {
	name := nodeName(i)
	join := []string{"--cluster-init"}
	if i > 0 {
		join = []string{"--server", "https://" + nodeIP(0) + ":6443"}
	}
	files, err := dirFiles(filepath.Join(settingsDir(), "k3s"), "/e2e/k3s")
	if err != nil {
		return err
	}
	files["/node-init.sh"] = nodeInit
	// The run's DNS, for the kubelet and so for the pods. Without it k3s
	// sees docker's loopback resolver and gives the pods public ones.
	files["/etc/e2e-resolv.conf"] = "nameserver " + dnsIP + "\n"
	err = container{
		name: name, ip: nodeIP(i), image: manifest.K3s.Image, files: files,
		dirs: []string{airgapDir}, hostFiles: map[string]string{filepath.Join(airgapDir, filepath.Base(airgap)): airgap},
		opts: []string{
			"--privileged", "--tmpfs", "/run", "--tmpfs", "/var/run", "--tmpfs", "/tmp",
			"--ulimit", "nproc=65535:65535", "--ulimit", "nofile=65535:65535",
			"--env", "K3S_TOKEN=" + k3sToken, "--entrypoint", "/bin/sh",
			"--volume", name + ":/var/lib/rancher/k3s",
			"--mount", "type=bind,src=" + diskMount(name) + ",dst=" + storageDir,
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
