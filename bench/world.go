package main

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/testcontainers/testcontainers-go"
)

// world is everything one run starts: the network, the services outside
// k3s, the three nodes, and the releases of the mounted directory on them.
// Nothing of it outlives the bench's container.
type world struct {
	nw   *testcontainers.DockerNetwork
	root *ca
	bao  *openbao
}

func newWorld(ctx context.Context) (*world, error) {
	root, err := newCA()
	if err != nil {
		return nil, err
	}
	nw, err := newNetwork(ctx)
	if err != nil {
		return nil, err
	}
	w := &world{nw: nw, root: root}
	logf("starting the DNS, the company CA and the store")
	if err := startDNS(ctx, nw); err != nil {
		return nil, err
	}
	if w.bao, err = startACME(ctx, nw, root); err != nil {
		return nil, err
	}
	if err := startStore(ctx, nw, root); err != nil {
		return nil, err
	}
	logf("starting k3s")
	if err := startNodes(ctx, nw); err != nil {
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
	if err := installCharts(ctx); err != nil {
		return nil, err
	}
	logf("waiting up to 15 min for the cluster to be healthy")
	if err := poll(ctx, time.Now().Add(15*time.Minute), healthy); err != nil {
		return nil, fmt.Errorf("the cluster is not healthy: %w", err)
	}
	return w, nil
}

// roles names the instances: the primary, and the replicas by pod name.
func roles(ctx context.Context) (map[string]string, error) {
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return nil, err
	}
	pods, err := instances(ctx)
	if err != nil {
		return nil, err
	}
	replicas := slices.DeleteFunc(pods, func(p string) bool { return p == primary })
	if len(replicas) != nodeCount-1 {
		return nil, fmt.Errorf("instances besides the primary %s: %v", primary, replicas)
	}
	return map[string]string{"the primary": primary, "replica 1": replicas[0], "replica 2": replicas[1]}, nil
}

func (w *world) startClient(ctx context.Context, writes bool) (*client, error) {
	key, err := w.bao.newEAB(ctx)
	if err != nil {
		return nil, err
	}
	return startClient(ctx, w.nw, w.root, key, writes)
}
