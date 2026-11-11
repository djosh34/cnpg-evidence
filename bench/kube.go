package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// The cluster the chart makes, as samples/desired.yaml names it, and its
// release in charts/releases.yaml.
const (
	namespace      = "databases"
	clusterName    = "pg"
	clusterRelease = "pg"
)

var kubeconfig = workDir + "/kubeconfig"

// kubectl runs kubectl with a time limit of 30 s per try. The API server
// rejects requests while etcd elects a new leader, as after a node is
// killed, and applies none of them; such a request is tried again until 30 s
// after the first try, so a call can take up to about 60 s.
func kubectl(ctx context.Context, args ...string) (string, error) {
	end := time.Now().Add(30 * time.Second)
	for {
		once, cancel := context.WithTimeout(ctx, 30*time.Second)
		out, err := command(once, "kubectl", args...)
		cancel()
		if err == nil || !strings.Contains(err.Error(), "etcdserver: leader changed") || time.Now().After(end) {
			return out, err
		}
		select {
		case <-ctx.Done():
			return "", errors.Join(err, ctx.Err())
		case <-time.After(2 * time.Second):
		}
	}
}

// psql runs SQL as postgres on an instance, in database db.
func psql(ctx context.Context, pod, db, sql string) (string, error) {
	return kubectl(ctx, "exec", "-n", namespace, pod, "-c", "postgres", "--",
		"psql", "-U", "postgres", "-d", db, "-XqAt", "-v", "ON_ERROR_STOP=1", "-c", sql)
}

// status is a field of the status of a cluster, such as currentPrimary.
func status(ctx context.Context, cluster, field string) (string, error) {
	return kubectl(ctx, "get", "cluster", cluster, "-n", namespace, "-o", "jsonpath={.status."+field+"}")
}

// instances are the instance pods of a cluster, by name.
func instances(ctx context.Context, cluster string) ([]string, error) {
	out, err := kubectl(ctx, "get", "pods", "-n", namespace, "-l", "cnpg.io/cluster="+cluster+",cnpg.io/podRole=instance",
		"-o", "jsonpath={.items[*].metadata.name}")
	if err != nil {
		return nil, err
	}
	pods := strings.Fields(out)
	slices.Sort(pods)
	return pods, nil
}

// healthy: the cluster has three ready instances, the phase healthy, and two
// replicas streaming from the primary.
func healthy(ctx context.Context, cluster string) error {
	ready, err := status(ctx, cluster, "readyInstances")
	if err != nil {
		return err
	}
	if ready != "3" {
		return fmt.Errorf("ready instances: %q", ready)
	}
	phase, err := status(ctx, cluster, "phase")
	if err != nil {
		return err
	}
	if phase != "Cluster in healthy state" {
		return fmt.Errorf("phase: %q", phase)
	}
	primary, err := status(ctx, cluster, "currentPrimary")
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
	primary, err := status(ctx, clusterName, "currentPrimary")
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

// nodeOf is the node an instance runs on.
func nodeOf(ctx context.Context, pod string) (string, error) {
	return kubectl(ctx, "get", "pod", pod, "-n", namespace, "-o", "jsonpath={.spec.nodeName}")
}
