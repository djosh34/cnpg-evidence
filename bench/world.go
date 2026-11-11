package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// world is everything one run starts: the network, the services outside
// k3s, the three nodes, and the releases of the mounted directory on them.
// Nothing of it outlives the bench's container.
type world struct {
	root    *ca
	bao     *openbao
	mon     *monitoring
	cluster installed // the cluster's release

	built time.Time // when the bench started to build it
}

func newWorld(ctx context.Context) (*world, error) {
	root, err := newCA()
	if err != nil {
		return nil, err
	}
	if err := createNetwork(ctx); err != nil {
		return nil, err
	}
	w := &world{root: root, built: time.Now()}
	logf("starting the DNS, the company CA, the store and the monitoring")
	if err := startDNS(ctx); err != nil {
		return nil, err
	}
	if w.bao, err = startACME(ctx, root); err != nil {
		return nil, err
	}
	if err := startStore(ctx, root); err != nil {
		return nil, err
	}
	if w.mon, err = startMonitoring(ctx, root); err != nil {
		return nil, err
	}
	logf("starting k3s")
	if err := startNodes(ctx); err != nil {
		return nil, err
	}
	logf("one CoreDNS, metrics-server and Traefik pod per node")
	if err := spreadK3sServices(ctx); err != nil {
		return nil, err
	}
	key, err := w.bao.newEAB(ctx)
	if err != nil {
		return nil, err
	}
	if err := createSecrets(ctx, runSecrets(root, key)); err != nil {
		return nil, err
	}
	if w.cluster, err = installCharts(ctx); err != nil {
		return nil, err
	}
	logf("waiting up to 15 min for the cluster to be healthy")
	err = poll(ctx, time.Now().Add(15*time.Minute), func(ctx context.Context) error { return healthy(ctx, clusterName) })
	if err != nil {
		return nil, fmt.Errorf("the cluster is not healthy: %w", err)
	}
	// As in a cluster with scheduled backups, so the backup alert sees one.
	logf("taking the first backup")
	if err := takeBackup(ctx, firstBackup); err != nil {
		return nil, err
	}
	logf("waiting up to 10 min for the first backup and for the metrics of every source")
	err = poll(ctx, time.Now().Add(10*time.Minute), func(ctx context.Context) error {
		return errors.Join(backupCompleted(ctx, firstBackup), w.mon.everySource(ctx))
	})
	if err != nil {
		return nil, fmt.Errorf("the monitoring is not ready: %w", err)
	}
	return w, nil
}

const firstBackup = "first"

// takeBackup starts a backup of the cluster to the store, through the
// barman-cloud plugin.
func takeBackup(ctx context.Context, name string) error {
	_, err := kubectl(ctx, "cnpg", "backup", clusterName, "-n", namespace, "--backup-name", name,
		"--method", "plugin", "--plugin-name", "barman-cloud.cloudnative-pg.io")
	return err
}

func backupCompleted(ctx context.Context, name string) error {
	out, err := kubectl(ctx, "get", "backup", name, "-n", namespace, "-o", `jsonpath={.status.phase}{"\t"}{.status.error}`)
	if err != nil {
		return err
	}
	if phase, why, _ := strings.Cut(out, "\t"); phase != "completed" {
		return fmt.Errorf("the backup %s is %q %s", name, phase, why)
	}
	return nil
}

// roles names the instances: the primary, and the replicas by pod name.
// Until a change of primary, a replica is replica 1.
func roles(ctx context.Context) (map[string]string, error) {
	primary, err := status(ctx, clusterName, "currentPrimary")
	if err != nil {
		return nil, err
	}
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return nil, err
	}
	replicas := slices.DeleteFunc(pods, func(p string) bool { return p == primary })
	if len(replicas) != nodeCount-1 {
		return nil, fmt.Errorf("instances besides the primary %s: %v", primary, replicas)
	}
	return map[string]string{
		"the primary": primary, "replica 1": replicas[0], "replica 2": replicas[1], "a replica": replicas[0],
	}, nil
}
