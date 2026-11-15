package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// endOutages ends the outages a failed scenario left in place, before
// always.feature runs, so that a line that failed partway never makes a
// later line fail. It starts the killed nodes, brings the store back,
// removes the firewall rule of a cut-off instance, unfences, resumes paused
// replay, and ends an unfinished drain and uncordons its node. Nothing else
// is undone, and it does none of CNPG's work: the cluster must get healthy
// on its own. A scenario that passed has ended its own faults in its own
// lines.
//
// It tries every step and returns what it did and what failed. A pod on a
// node that it started lost its firewall rule and its paused replay with
// the node, so those are left alone.
func (s *scenario) endOutages(ctx context.Context) (string, error) {
	var done []string
	var errs []error
	step := func(what string, err error) {
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", what, err))
			return
		}
		done = append(done, what)
	}
	restarted, started := s.downPods, len(s.down) > 0
	if started {
		what := "started " + strings.Join(s.down, " and ")
		err := restartNodes(ctx, s.down...)
		if err == nil {
			s.down, s.downPods = nil, nil
		}
		step(what, err)
	}
	// The next steps need the API server, which waits for etcd's quorum
	// when two nodes were down.
	if started && (len(s.fenced)+len(s.paused)+len(s.cut) > 0 || s.drain != nil) {
		step("the API server answered", poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
			_, err := kubectl(ctx, "get", "--raw", "/readyz")
			return err
		}))
	}
	if s.store != "" {
		what := "the " + s.store + " store back"
		err := restoreStore(ctx, s.store == "stopped")
		if err == nil {
			s.store = ""
		}
		step(what, err)
	}
	for _, pod := range s.cut {
		if !slices.Contains(restarted, pod) {
			step("reconnected "+pod, podFirewall(ctx, pod, "-D"))
		}
	}
	s.cut = nil
	for _, pod := range s.fenced {
		step("unfenced "+pod, fencingOff(ctx, pod))
	}
	s.fenced = nil
	for _, pod := range s.paused {
		if !slices.Contains(restarted, pod) {
			_, err := psql(ctx, pod, "postgres", "select pg_wal_replay_resume() where pg_is_in_recovery()")
			step("resumed replay on "+pod, err)
		}
	}
	s.paused = nil
	if s.drain != nil {
		s.drain.run.stop()
		_, err := kubectl(ctx, "uncordon", s.drain.node)
		step("uncordoned "+s.drain.node, err)
		s.drain = nil
	}
	return strings.Join(done, "; "), errors.Join(errs...)
}

// afterFailure ends the outages of a failed scenario and adds a row for it
// to the timing table.
func (s *scenario) afterFailure() error {
	done, err := s.endOutages(s.ctx)
	r := row{line: "After the failed line: the outages end", result: "passed", detail: done}
	if done == "" {
		r.detail = "none was in place"
	}
	if err != nil {
		r.result, r.detail = "failed", err.Error()
	}
	s.rows = append(s.rows, r)
	logf("%s: %s", r.line, r.detail)
	return err
}
