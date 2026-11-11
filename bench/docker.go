package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const (
	// The inner docker keeps everything, the nodes' volumes among them, on
	// an ext4 filesystem of its own in a sparse file, so every host gives
	// the cluster the same empty disk. The file sits in the image's volume
	// /var/lib/docker, which docker run --rm removes with the container.
	diskFile = "/var/lib/docker/bench.ext4"
	diskSize = 40 << 30
	diskDir  = "/var/lib/bench"
	// The inner dockerd's log.
	dockerLog = "/var/log/dockerd.log"
)

// startDocker makes the disk and starts the inner dockerd through the dind
// script of the docker image, which first sets up the cgroups for nested
// containers. It returns once docker answers.
func startDocker(ctx context.Context) error {
	logf("making the bench's own disk and starting docker")
	if err := makeDisk(ctx); err != nil {
		return fmt.Errorf("the bench's disk: %w", err)
	}
	log, err := os.Create(dockerLog)
	if err != nil {
		return err
	}
	dockerd := exec.Command("dind", "dockerd", "--data-root="+diskDir+"/docker", "--host=unix:///var/run/docker.sock")
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

func makeDisk(ctx context.Context) error {
	f, err := os.Create(diskFile)
	if err != nil {
		return err
	}
	if err := errors.Join(f.Truncate(diskSize), f.Close()); err != nil {
		return err
	}
	if err := os.MkdirAll(diskDir, 0o700); err != nil {
		return err
	}
	if _, err := command(ctx, "mkfs.ext4", "-q", "-F", diskFile); err != nil {
		return err
	}
	_, err = command(ctx, "mount", "-o", "loop", diskFile, diskDir)
	return err
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
	network = "bench"
	subnet  = "10.77.0.0/24"
	// The bench's own address on the network.
	gatewayIP = "10.77.0.1"
)

func createNetwork(ctx context.Context) error {
	_, err := command(ctx, "docker", "network", "create", "--subnet", subnet, "--gateway", gatewayIP, network)
	return err
}

// container is a container on the bench network.
type container struct {
	name  string // the container's name and host name
	ip    string
	files map[string]string // the content of each file the container gets, by its path
	opts  []string          // more docker run options
	image string
	args  []string
}

// run starts the container with the DNS container as its resolver. Its
// files are written under workDir and mounted read-only. The DNS container
// itself keeps docker's resolver, to which it forwards every other name.
func (c container) run(ctx context.Context) error {
	args := []string{"run", "-d", "--name", c.name, "--hostname", c.name, "--network", network, "--ip", c.ip}
	if c.ip != dnsIP {
		args = append(args, "--dns", dnsIP)
	}
	for path, content := range c.files {
		local := filepath.Join(workDir, "files", c.name, path)
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(local, []byte(content), 0o644); err != nil {
			return err
		}
		args = append(args, "--volume", local+":"+path+":ro")
	}
	args = append(append(append(args, c.opts...), c.image), c.args...)
	if _, err := command(ctx, "docker", args...); err != nil {
		return fmt.Errorf("starting %s: %w", c.name, err)
	}
	return nil
}
