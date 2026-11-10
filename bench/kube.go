package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/testcontainers/testcontainers-go"
)

// The cluster the chart makes, as samples/desired.yaml names it.
const (
	namespace   = "databases"
	clusterName = "pg"
)

var kubeconfig = workDir + "/kubeconfig"

// command runs a program with the bench's kubeconfig and returns its output
// without the last newline. A failure's error holds its output.
func command(ctx context.Context, stdin io.Reader, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	cmd.Stdin = stdin
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err,
			strings.TrimSpace(stderr.String()+" "+stdout.String()))
	}
	return strings.TrimSuffix(stdout.String(), "\n"), nil
}

// kubectl runs kubectl with a time limit of 30 s.
func kubectl(ctx context.Context, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return command(ctx, nil, "kubectl", args...)
}

// psql runs SQL as postgres on an instance, in database db.
func psql(ctx context.Context, pod, db, sql string) (string, error) {
	return kubectl(ctx, "exec", "-n", namespace, pod, "-c", "postgres", "--",
		"psql", "-U", "postgres", "-d", db, "-XqAt", "-v", "ON_ERROR_STOP=1", "-c", sql)
}

func clusterField(ctx context.Context, field string) (string, error) {
	return kubectl(ctx, "get", "cluster", clusterName, "-n", namespace, "-o", "jsonpath={.status."+field+"}")
}

// instances are the instance pods of the cluster, by name.
func instances(ctx context.Context) ([]string, error) {
	out, err := kubectl(ctx, "get", "pods", "-n", namespace, "-l", "cnpg.io/cluster="+clusterName+",cnpg.io/podRole=instance",
		"-o", "jsonpath={.items[*].metadata.name}")
	if err != nil {
		return nil, err
	}
	pods := strings.Fields(out)
	slices.Sort(pods)
	return pods, nil
}

// healthy: three ready instances, the phase healthy, and two replicas
// streaming from the primary.
func healthy(ctx context.Context) error {
	ready, err := clusterField(ctx, "readyInstances")
	if err != nil {
		return err
	}
	if ready != "3" {
		return fmt.Errorf("ready instances: %q", ready)
	}
	phase, err := clusterField(ctx, "phase")
	if err != nil {
		return err
	}
	if phase != "Cluster in healthy state" {
		return fmt.Errorf("phase: %q", phase)
	}
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	streaming, err := psql(ctx, primary, "postgres", "select count(*) from pg_stat_replication where state = 'streaming'")
	if err != nil {
		return err
	}
	if streaming != "2" {
		return fmt.Errorf("replicas streaming from %s: %s", primary, streaming)
	}
	return nil
}

// isPrimary: pod is the cluster's current primary and out of recovery. An
// empty pod means any instance but not.
func isPrimary(ctx context.Context, pod, not string) (string, error) {
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return "", err
	}
	if primary == "" || primary == not || (pod != "" && primary != pod) {
		return "", fmt.Errorf("the primary is %q", primary)
	}
	recovery, err := psql(ctx, primary, "postgres", "select pg_is_in_recovery()")
	if err != nil {
		return "", err
	}
	if recovery != "f" {
		return "", fmt.Errorf("%s is in recovery", primary)
	}
	return primary, nil
}

// poll runs check every 2 s until it holds or the deadline passes. A check
// that started in time but held only after the deadline fails too.
func poll(ctx context.Context, deadline time.Time, check func(context.Context) error) error {
	for {
		err := check(ctx)
		late := time.Now().After(deadline)
		switch {
		case err == nil && late:
			return errors.New("it held only after the limit")
		case err == nil:
			return nil
		case late:
			return fmt.Errorf("not within the limit: %w", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// file is a file to copy into a container before it starts.
func file(path, content string) testcontainers.ContainerFile {
	return testcontainers.ContainerFile{Reader: strings.NewReader(content), ContainerFilePath: path, FileMode: 0o644}
}

// closeWith closes c and joins its error to err.
func closeWith(err error, c io.Closer) error {
	return errors.Join(err, c.Close())
}

// logf prints a line of the run's progress.
func logf(format string, args ...any) {
	say(os.Stdout, "== %s %s\n", time.Now().UTC().Format(time.TimeOnly), fmt.Sprintf(format, args...))
}

// say prints to w. A run that cannot print cannot report, so it stops.
func say(w io.Writer, format string, args ...any) {
	if _, err := fmt.Fprintf(w, format, args...); err != nil {
		os.Exit(2)
	}
}
