package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
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
	if err := closeWith(f.Truncate(diskSize), f); err != nil {
		return err
	}
	if err := os.MkdirAll(diskDir, 0o700); err != nil {
		return err
	}
	if _, err := command(ctx, nil, "mkfs.ext4", "-q", "-F", diskFile); err != nil {
		return err
	}
	_, err = command(ctx, nil, "mount", "-o", "loop", diskFile, diskDir)
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
