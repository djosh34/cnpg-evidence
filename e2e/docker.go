package main

import (
	"archive/tar"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// The inner dockerd's log. The inner docker keeps its data in the image's
// volume /var/lib/docker, which goes with the container.
const dockerLog = "/var/log/dockerd.log"

// startDocker starts the inner dockerd through the dind script of the
// docker image, which first sets up the cgroups for nested containers. It
// returns once docker answers.
func startDocker(ctx context.Context) error {
	logf("starting docker")
	log, err := os.Create(dockerLog)
	if err != nil {
		return err
	}
	dockerd := exec.Command("dind", "dockerd", "--host=unix:///var/run/docker.sock")
	dockerd.Stdout, dockerd.Stderr = log, log
	if err := dockerd.Start(); err != nil {
		return fmt.Errorf("starting dockerd: %w", err)
	}
	exited := make(chan error, 1)
	go func() { exited <- dockerd.Wait() }()
	deadline := time.Now().Add(60 * time.Second)
	for {
		if err := exec.CommandContext(ctx, "docker", "info").Run(); err == nil {
			return nil
		}
		select {
		case err := <-exited:
			return fmt.Errorf("dockerd exited (%w); its log: %s", err, tail(dockerLog))
		case <-time.After(time.Second):
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("docker did not answer in 60 s; its log: %s", tail(dockerLog))
		}
	}
}

// tail is the end of a log file, for an error message.
func tail(file string) string {
	data, err := os.ReadFile(file)
	if err != nil {
		return err.Error()
	}
	const most = 4000
	if len(data) > most {
		data = data[len(data)-most:]
	}
	return string(data)
}

// What runs outside k3s in production runs here as a container next to the
// nodes, on one network, at fixed addresses that the DNS container names.
const (
	network = "e2e"
	subnet  = "10.77.0.0/24"
	// The run's own address on the network.
	gatewayIP = "10.77.0.1"
)

func createNetwork(ctx context.Context) error {
	_, err := command(ctx, "docker", "network", "create", "--subnet", subnet, "--gateway", gatewayIP, network)
	return err
}

// container is a container on the e2e network.
type container struct {
	name  string // the container's name and host name
	ip    string
	files map[string]string // the content of each file the container gets, by its path
	dirs  []string          // the empty directories it gets
	opts  []string          // more docker run options
	image string
	args  []string
}

// run creates the container with the DNS container as its resolver, copies
// its files and directories in, then starts it. The DNS container itself
// keeps docker's resolver, to which it forwards every other name.
func (c container) run(ctx context.Context) error {
	args := []string{"create", "--name", c.name, "--hostname", c.name, "--network", network, "--ip", c.ip}
	if c.ip != dnsIP {
		args = append(args, "--dns", dnsIP)
	}
	args = append(append(append(args, c.opts...), c.image), c.args...)
	if _, err := command(ctx, "docker", args...); err != nil {
		return fmt.Errorf("creating %s: %w", c.name, err)
	}
	if len(c.files)+len(c.dirs) > 0 {
		if err := copyIn(ctx, c.name, c.files, c.dirs); err != nil {
			return fmt.Errorf("copying the files of %s: %w", c.name, err)
		}
	}
	if _, err := command(ctx, "docker", "start", c.name); err != nil {
		return fmt.Errorf("starting %s: %w", c.name, err)
	}
	return nil
}

// copyIn copies files and empty directories into a container with docker
// cp, as one tar archive of only them: docker creates the directories above
// them, and leaves those that exist as they are.
func copyIn(ctx context.Context, name string, files map[string]string, dirs []string) error {
	var archive bytes.Buffer
	tw := tar.NewWriter(&archive)
	for _, dir := range dirs {
		if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: strings.TrimPrefix(dir, "/"), Mode: 0o755}); err != nil {
			return err
		}
	}
	for path, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: strings.TrimPrefix(path, "/"), Mode: 0o644, Size: int64(len(content))}); err != nil {
			return err
		}
		if _, err := tw.Write([]byte(content)); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, "docker", "cp", "-", name+":/")
	cmd.Stdin = &archive
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker cp: %w: %s", err, out)
	}
	return nil
}
