package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
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
//   - a measure over the whole scenario, whose line gives the limit;
//   - a check of the time since an event, in "has been ... since the
//     <event>".
//
// A line whose thing and word are not here fails the run.
type word struct {
	mark    string
	event   func(context.Context, *scenario, args) error
	state   func(context.Context, *scenario, args) error
	longest func(context.Context, *scenario) (time.Duration, error)
	since   func(context.Context, *scenario, args, time.Time) error
	// A measure whose limit in always.feature a scenario's own line sets.
	scenarioLimit bool
}

var vocabulary = map[string]word{
	// Events.
	"<role> | promoted":      {mark: "promote", event: promote},
	"writing | stops":        {event: stopWriting},
	"<role>'s node | killed": {mark: "kill", event: killNodeOf},
	"the node | starts":      {mark: "start", event: startKilled},

	// States.
	"the cluster | healthy":        {state: clusterHealthy},
	"<role> | primary":             {state: rolePrimary},
	"<role> | still primary":       {state: rolePrimary},
	"no acknowledged write | lost": {state: noneLost},
	"the alerts | healthy":         {state: alertsHealthy},
	"the dashboard | healthy":      {state: dashboardHealthy},
	"the exporters | healthy":      {state: exportersAnswer},

	// Since an event.
	"the exporters of <role> and <role> | healthy": {since: exportersKept},

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

// killNodeOf: the node of the instance stops at once, as a lost VM.
func killNodeOf(ctx context.Context, s *scenario, a args) error {
	if a.pods[0] == anotherInstance {
		return errors.New("kill the node of a named instance")
	}
	node, err := killNode(ctx, a.pods[0], s.down)
	if err == nil {
		s.down = append(s.down, node)
	}
	return err
}

// startKilled: the killed node starts again.
func startKilled(ctx context.Context, s *scenario, _ args) error {
	if len(s.down) != 1 {
		return fmt.Errorf("the node starts: %d nodes are down", len(s.down))
	}
	if err := restartNode(ctx, s.down[0]); err != nil {
		return err
	}
	s.down = nil
	return nil
}

// alertsHealthy: no alert fires, every alert the scenario says fired or
// fires fired, and no other did but those it says may fire.
func alertsHealthy(ctx context.Context, s *scenario, _ args) error {
	firing, err := s.w.mon.firing(ctx)
	if err != nil {
		return err
	}
	if len(firing) > 0 {
		return fmt.Errorf("still firing: %s", strings.Join(slices.Sorted(maps.Keys(firing)), ", "))
	}
	fired, err := s.w.mon.fired(ctx, s.started)
	if err != nil {
		return err
	}
	var missing, other []string
	for key, must := range s.alerts {
		if must && !fired[key] {
			missing = append(missing, key)
		}
	}
	for key := range fired {
		if _, named := s.alerts[key]; !named {
			other = append(other, key)
		}
	}
	slices.Sort(missing)
	slices.Sort(other)
	if len(missing) > 0 || len(other) > 0 {
		return fmt.Errorf("did not fire: %v; fired, not named by the scenario: %v", missing, other)
	}
	s.detail = "fired: " + strings.Join(slices.Sorted(maps.Keys(fired)), ", ")
	return nil
}

// dashboardHealthy: every panel of the dashboard has data in Grafana.
func dashboardHealthy(ctx context.Context, s *scenario, _ args) error {
	return s.w.mon.dashboardHasData(ctx)
}

// The two query metrics the exporter checks read: the chart's cn_mapping
// check and CNPG's in_recovery.
var queryMetrics = []string{
	`cnpg_compliance_violations{namespace="` + namespace + `", check="cn_mapping"}`,
	`cnpg_pg_replication_in_recovery{namespace="` + namespace + `"}`,
}

// exportersAnswer: every instance's exporter answered with both query
// metrics in the last 30 s.
func exportersAnswer(ctx context.Context, s *scenario, _ args) error {
	pods, err := instances(ctx)
	if err != nil {
		return err
	}
	for _, metric := range queryMetrics {
		fresh, err := s.w.mon.pods(ctx, "time() - timestamp("+metric+") < 30")
		if err != nil {
			return err
		}
		for _, pod := range pods {
			if !fresh[pod] {
				return fmt.Errorf("the exporter of %s did not answer with %s in the last 30 s", pod, metric)
			}
		}
	}
	return nil
}

// exportersKept: the exporters of the instances kept their query metrics
// from the event to now: in every 15 s in which one answered, at least one
// answer had both, and none went 60 s without answering. A change of the
// Cluster gives each exporter new, empty query results, so one answer
// right after one can lack them.
func exportersKept(ctx context.Context, s *scenario, a args, from time.Time) error {
	window := int(time.Since(from).Seconds())
	for _, pod := range a.pods {
		if pod == anotherInstance {
			return errors.New("name the instances")
		}
		up := fmt.Sprintf(`cnpg_collector_up{namespace=%q, pod=%q}`, namespace, pod)
		silent := fmt.Sprintf(`min_over_time((sum(count_over_time(%s[60s])) or vector(0))[%ds:5s]) == 0`, up, window)
		if err := s.w.mon.none(ctx, silent); err != nil {
			return fmt.Errorf("the exporter of %s did not answer for 60 s or longer: %w", pod, err)
		}
		for _, metric := range queryMetrics {
			metric = strings.Replace(metric, "{", fmt.Sprintf("{pod=%q, ", pod), 1)
			without := fmt.Sprintf(`max_over_time((sum(count_over_time(%s[15s])) > 0 unless on () sum(count_over_time(%s[15s])))[%ds:5s])`,
				up, metric, window)
			if err := s.w.mon.none(ctx, without); err != nil {
				return fmt.Errorf("the exporter of %s answered for 15 s or longer without %s: %w", pod, metric, err)
			}
		}
	}
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
