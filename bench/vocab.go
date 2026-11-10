package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
)

// The vocabulary: every thing a line can name, and what each word does to
// it. A line's roles are replaced by <role> before the lookup, so "replica 1
// is promoted" looks up "<role> | promoted". A word is one of three kinds:
//
//   - an event, which the bench does, in a Given or When line; mark names it
//     for later lines, as in "after the promote";
//   - a state, which the bench checks in a Given or Then line: now, waiting
//     up to the line's limit, or for the line's time;
//   - a measure over the whole scenario, whose line gives the limit.
//
// A line whose thing and word are not here fails the run.
type word struct {
	mark    string
	event   func(context.Context, *scenario, args) error
	state   func(context.Context, *scenario, args) error
	longest func(context.Context, *scenario) (time.Duration, error)
	// A measure whose limit in always.feature a scenario's own line sets.
	scenarioLimit bool
}

var vocabulary = map[string]word{
	// Events.
	"<role> | promoted": {mark: "promote", event: promote},
	"writing | stops":   {event: stopWriting},

	// States.
	"the cluster | healthy":        {state: clusterHealthy},
	"<role> | primary":             {state: rolePrimary},
	"no acknowledged write | lost": {state: noneLost},

	// Measures, on the client: the longest time without a successful read,
	// and without an acknowledged write while the client writes.
	"reading | healthy": {longest: longestReadGap},
	"writing | healthy": {longest: longestWriteGap, scenarioLimit: true},
}

// promote: kubectl cnpg promote; the instance is then the new primary.
func promote(ctx context.Context, s *scenario, a args) error {
	pod := a.pods[0]
	if pod == anotherInstance {
		return errors.New("promote a named instance")
	}
	if _, err := kubectl(ctx, "cnpg", "promote", clusterName, pod, "-n", namespace); err != nil {
		return err
	}
	s.roles["the new primary"] = pod
	return nil
}

// stopWriting: the client stops writing and goes on reading. The write
// measure ends here.
func stopWriting(ctx context.Context, s *scenario, _ args) error {
	return s.cl.stopWrites(ctx)
}

// clusterHealthy: three ready instances, the phase healthy, and two
// replicas streaming from the primary.
func clusterHealthy(ctx context.Context, _ *scenario, _ args) error {
	return healthy(ctx)
}

// rolePrimary: the instance is the cluster's current primary and out of
// recovery. For another instance, any instance but the primary, which is
// then the new primary.
func rolePrimary(ctx context.Context, s *scenario, a args) error {
	if a.pods[0] != anotherInstance {
		_, err := isPrimary(ctx, a.pods[0], "")
		return err
	}
	primary, err := isPrimary(ctx, "", s.roles["the primary"])
	if err == nil {
		s.roles["the new primary"] = primary
	}
	return err
}

// noneLost: every write the client got acknowledged is in bench_writes on
// the primary. It stops the client first, so every write it started has
// ended.
func noneLost(ctx context.Context, s *scenario, _ args) error {
	if s.cl == nil {
		return errors.New("the client did not run: the scenario has no When line")
	}
	if err := s.stopClient(ctx); err != nil {
		return err
	}
	log, err := s.cl.log(ctx)
	if err != nil {
		return err
	}
	acked := log.acknowledged()
	if len(acked) == 0 && s.writes {
		return errors.New("the client got no write acknowledged")
	}
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	out, err := psql(ctx, primary, "orders", "select n from bench_writes")
	if err != nil {
		return err
	}
	present := strings.Fields(out)
	slices.Sort(present)
	var lost []string
	for _, n := range acked {
		if _, found := slices.BinarySearch(present, n); !found {
			lost = append(lost, n)
		}
	}
	if len(lost) > 0 {
		return fmt.Errorf("%d of %d acknowledged writes are not on %s, the first: %s",
			len(lost), len(acked), primary, strings.Join(lost[:min(5, len(lost))], " "))
	}
	s.detail = fmt.Sprintf("%d acknowledged writes, all on %s", len(acked), primary)
	return nil
}

func longestReadGap(ctx context.Context, s *scenario) (time.Duration, error) {
	return s.longestGap(ctx, "read")
}

// longestWriteGap: in a scenario with no writes there is nothing to measure.
func longestWriteGap(ctx context.Context, s *scenario) (time.Duration, error) {
	if !s.writes {
		return 0, nil
	}
	return s.longestGap(ctx, "write")
}

// longestGap is the longest time without an ok line of what, from the
// client's first one to now, to when the client ended, or for writes to
// when they stopped.
func (s *scenario) longestGap(ctx context.Context, what string) (time.Duration, error) {
	if s.cl == nil {
		return 0, errors.New("the client did not run: the scenario has no When line")
	}
	log, err := s.cl.log(ctx)
	if err != nil {
		return 0, err
	}
	from, ok := log.first(what)
	if !ok {
		return 0, fmt.Errorf("the client has no %s", what)
	}
	to := time.Now()
	if !s.clientEnded.IsZero() {
		to = s.clientEnded
	}
	if stopped, ok := log.writesStopped(); ok && what == "write" {
		to = stopped
	}
	return log.longestGap(what, from, to), nil
}

// stopClient stops the client once.
func (s *scenario) stopClient(ctx context.Context) error {
	if s.cl == nil || !s.clientEnded.IsZero() {
		return nil
	}
	s.clientEnded = time.Now()
	return s.cl.stop(ctx)
}
