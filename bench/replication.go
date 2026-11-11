package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"
	"time"
)

// The words of the vocabulary about a drained node, a replica cut off from
// its primary, paused replay and the commits that wait for it, and the
// replica lag.

// background is a command that runs on while the scenario goes on.
type background struct {
	done chan struct{}
	err  error
}

func inBackground(ctx context.Context, name string, args ...string) *background {
	b := &background{done: make(chan struct{})}
	go func() {
		_, b.err = command(ctx, nil, name, args...)
		close(b.done)
	}()
	return b
}

// finished is the command's error once it ended, and an error while it
// runs.
func (b *background) finished() error {
	select {
	case <-b.done:
		return b.err
	default:
		return errors.New("it still runs")
	}
}

// drained is a node kubectl drain runs on.
type drained struct {
	node string
	run  *background
}

// drainNode: kubectl drain of the instance's node, which cordons it and
// evicts its pods. It runs on until "the drain is done".
func drainNode(ctx context.Context, s *scenario, a args) error {
	if s.drain != nil {
		return fmt.Errorf("%s is drained already", s.drain.node)
	}
	if a.pods[0] == anotherInstance {
		return errors.New("drain the node of a named instance")
	}
	node, err := nodeOf(ctx, a.pods[0])
	if err != nil {
		return err
	}
	s.drain = &drained{node: node, run: inBackground(ctx, "kubectl", "drain", node, "--ignore-daemonsets", "--delete-emptydir-data")}
	logf("draining %s", node)
	return nil
}

func drainDone(_ context.Context, s *scenario, _ args) error {
	if s.drain == nil {
		return errors.New("no node is drained")
	}
	if err := s.drain.run.finished(); err != nil {
		return fmt.Errorf("the drain of %s: %w", s.drain.node, err)
	}
	return nil
}

// uncordon: kubectl uncordon of the drained node, once the drain is done.
func uncordon(ctx context.Context, s *scenario, a args) error {
	if err := drainDone(ctx, s, a); err != nil {
		return err
	}
	if _, err := kubectl(ctx, "uncordon", s.drain.node); err != nil {
		return err
	}
	s.drain = nil
	return nil
}

// cutOff: in the instance pod's network namespace, a firewall rule rejects
// its connections to port 5432, and the primary ends the instance's WAL
// sender. The replica stops streaming, while its exporter, which others
// connect to, goes on answering.
func cutOff(ctx context.Context, _ *scenario, a args) error {
	pod := a.pods[0]
	if err := podFirewall(ctx, pod, "-I"); err != nil {
		return err
	}
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	_, err = psql(ctx, primary, "postgres", fmt.Sprintf(
		"select pg_terminate_backend(pid) from pg_stat_replication where application_name = '%s'", pod))
	return err
}

// reconnect: the rule of cutOff is gone.
func reconnect(ctx context.Context, _ *scenario, a args) error {
	return podFirewall(ctx, a.pods[0], "-D")
}

var sandboxID = regexp.MustCompile(`^[0-9a-f]+$`)

// podFirewall inserts (-I) or deletes (-D) the rule that rejects the pod's
// connections to port 5432, in the network namespace of its ready sandbox
// on its node.
func podFirewall(ctx context.Context, pod, op string) error {
	if pod == anotherInstance {
		return errors.New("name the instance")
	}
	node, err := nodeOf(ctx, pod)
	if err != nil {
		return err
	}
	id, err := command(ctx, nil, "docker", "exec", node, "crictl", "pods", "-q", "--namespace", namespace, "--name", "^"+pod+"$", "--state", "ready")
	if err != nil {
		return err
	}
	if !sandboxID.MatchString(id) {
		return fmt.Errorf("no single ready pod sandbox of %s on %s: %q", pod, node, id)
	}
	pid, err := command(ctx, nil, "docker", "exec", node, "crictl", "inspectp", "-o", "go-template", "--template", "{{.info.pid}}", id)
	if err != nil {
		return err
	}
	_, err = command(ctx, nil, "docker", "exec", node, "nsenter", "--net=/proc/"+pid+"/ns/net",
		"iptables", op, "OUTPUT", "-p", "tcp", "--dport", "5432", "-j", "REJECT", "--reject-with", "tcp-reset")
	return err
}

// notStreaming: the instance is not in the primary's pg_stat_replication.
func notStreaming(ctx context.Context, _ *scenario, a args) error {
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	n, err := psql(ctx, primary, "postgres", fmt.Sprintf(
		"select count(*) from pg_stat_replication where application_name = '%s'", a.pods[0]))
	if err != nil {
		return err
	}
	if n != "0" {
		return fmt.Errorf("%s is in the pg_stat_replication of %s", a.pods[0], primary)
	}
	return nil
}

// metricsArriving: Prometheus has a sample of cnpg_collector_up 1 of the
// instance from the last 30 s.
func metricsArriving(ctx context.Context, s *scenario, a args) error {
	up := fmt.Sprintf(`cnpg_collector_up{namespace=%q, pod=%q}`, namespace, a.pods[0])
	pods, err := s.w.mon.pods(ctx, fmt.Sprintf(`%s == 1 and time() - timestamp(%s) < 30`, up, up))
	if err != nil {
		return err
	}
	if !pods[a.pods[0]] {
		return fmt.Errorf("no cnpg_collector_up 1 of %s in the last 30 s", a.pods[0])
	}
	return nil
}

// replay pauses or resumes WAL replay on the instances.
func replay(action string) func(context.Context, *scenario, args) error {
	return func(ctx context.Context, _ *scenario, a args) error {
		for _, pod := range a.pods {
			if pod == anotherInstance {
				return errors.New("name the instances")
			}
			if _, err := psql(ctx, pod, "postgres", "select pg_wal_replay_"+action+"()"); err != nil {
				return err
			}
		}
		return nil
	}
}

func rowTable(ctx context.Context, pod string) error {
	_, err := psql(ctx, pod, "postgres", "create table if not exists bench_row (at timestamptz not null default now())")
	return err
}

// longCommit: one transaction on the instance runs a statement of N s, then
// inserts a row and commits.
func longCommit(ctx context.Context, _ *scenario, a args) error {
	n, pod := a.ns[0], a.pods[0]
	if err := rowTable(ctx, pod); err != nil {
		return err
	}
	_, err := psql(ctx, pod, "postgres", fmt.Sprintf(
		"begin; select pg_sleep(%d); insert into bench_row default values; commit", n))
	return err
}

// startCommit: one insert on the instance, outside the client, which runs
// on until "the commit is done": with replay paused on every replica, its
// commit waits.
func startCommit(ctx context.Context, s *scenario, a args) error {
	if s.commit != nil {
		return errors.New("a commit was started already")
	}
	pod := a.pods[0]
	if err := rowTable(ctx, pod); err != nil {
		return err
	}
	s.commit = inBackground(ctx, "kubectl", "exec", "-n", namespace, pod, "-c", "postgres", "--",
		"psql", "-U", "postgres", "-d", "postgres", "-XqAt", "-v", "ON_ERROR_STOP=1", "-c", "insert into bench_row default values")
	return nil
}

func commitDone(_ context.Context, s *scenario, _ args) error {
	if s.commit == nil {
		return errors.New("no commit was started")
	}
	return s.commit.finished()
}

// replicaLagHealthy: with "for N s", the chart's cnpg_replica_lag_seconds
// of each replica stays under 1 s in every sample taken since the line
// started, and every replica has one after 30 s. The timing table gives the
// most each instance reported since the last event, of it and of CNPG's own
// cnpg_pg_replication_lag, which reports minutes on a caught-up replica for
// up to 5 min after its PostgreSQL restarts.
func replicaLagHealthy(ctx context.Context, s *scenario, _ args) error {
	if s.holding.IsZero() {
		return errors.New(`the replica lag takes "for N s"`)
	}
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	selector := fmt.Sprintf(`namespace=%q, cluster=%q`, namespace, clusterName)
	held := time.Since(s.holding)
	most, err := s.w.mon.values(ctx, fmt.Sprintf(`max by (pod) (max_over_time(cnpg_replica_lag_seconds{%s}[%dms]))`,
		selector, max(held.Milliseconds(), 1)))
	if err != nil {
		return err
	}
	for _, pod := range slices.DeleteFunc(pods, func(p string) bool { return p == primary }) {
		value, ok := most[pod]
		switch {
		case !ok && held > 30*time.Second:
			return fmt.Errorf("no cnpg_replica_lag_seconds of %s in the %s since the line started", pod, seconds(held))
		case ok && value >= 1:
			return fmt.Errorf("cnpg_replica_lag_seconds of %s was %.1f s", pod, value)
		}
	}
	window := int(time.Since(s.marks[s.last]).Seconds()) + 1
	var report []string
	for _, metric := range []string{"cnpg_replica_lag_seconds", "cnpg_pg_replication_lag"} {
		values, err := s.w.mon.values(ctx, fmt.Sprintf(`max by (pod) (max_over_time(%s{%s}[%ds]))`, metric, selector, window))
		if err != nil {
			return err
		}
		var each []string
		for _, pod := range slices.Sorted(maps.Keys(values)) {
			each = append(each, fmt.Sprintf("%s %.1f", pod, values[pod]))
		}
		report = append(report, metric+" "+strings.Join(each, ", "))
	}
	s.detail = "most since the " + s.last + ": " + strings.Join(report, "; ")
	return nil
}
