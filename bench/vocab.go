package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The vocabulary: every thing a line can name, and what each word does to
// it. A line's roles are replaced by <role> and its numbers by <n> before the
// lookup, so "replica 1 is promoted" looks up "<role> | promoted". A word is
// one of four kinds:
//
//   - an event, which the bench does, in a Given or When line; mark names it
//     for later lines, as in "after the promote";
//   - a state, which the bench checks in a Given or Then line: now, waiting
//     up to the line's limit, or for the line's time;
//   - a measure over the whole scenario, whose line gives the limit; with
//     back, also a state after an event, in "< N s after the <event>";
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
	back    func(context.Context, *scenario, time.Time) (time.Time, error)
	// A measure whose limit in always.feature a scenario's own line sets.
	scenarioLimit bool
}

var vocabulary = map[string]word{
	// Events.
	"<role> | promoted":                         {mark: "promote", event: promote},
	"<role> | fenced":                           {mark: "fence", event: fence},
	"<role> | unfenced":                         {mark: "unfence", event: unfence},
	"writing | stops":                           {event: stopWriting},
	"a row | written":                           {event: writeRow},
	"<role>'s node | killed":                    {mark: "kill", event: killNodes},
	"<role>'s node and <role>'s node | killed":  {mark: "kill", event: killNodes},
	"the node | starts":                         {mark: "start", event: startKilled(1)},
	"the nodes | start":                         {mark: "start", event: startKilled(2)},
	"<role>'s postgres container | killed":      {event: killPostgres},
	"the catalog | read on <role>":              {event: readCatalog},
	"<n> MB of WAL | written on <role>":         {event: writeWAL},
	"<role>'s WAL | switched":                   {event: switchWAL},
	"the instance image | changed":              {mark: "change", event: changeImage},
	"wal_keep_size | set to <n>MB":              {mark: "change", event: setWalKeepSize},
	"a backup | taken":                          {mark: "backup", event: backUp},
	"pg-restore | restored from the store":      {mark: "restore", event: restore},
	"the store | stopped":                       {event: breakStore("stopped")},
	"the store | paused":                        {event: breakStore("paused")},
	"the store | starts":                        {event: storeStarts},

	// States.
	"the cluster | healthy":                          {state: clusterHealthy},
	"<role> | primary":                               {state: rolePrimary},
	"<role> | still primary":                         {state: rolePrimary},
	"no instance | promoted":                         {state: nonePromoted},
	"<role> | down":                                  {state: postgresDown},
	"<role>'s postgres container | running":         {state: postgresRestarted},
	"<role> | caught up":                             {state: caughtUp},
	"<role> | idle after a WAL switch":               {state: idleAfterSwitch},
	"the chart's pg_ident lines | on <role>":         {state: identOn},
	"the chart's pg_ident lines | on every instance": {state: identEverywhere},
	"every instance | on the new image":              {state: onNewImage},
	"wal_keep_size | <n>MB on every instance":        {state: walKeepSizeIs},
	"<role>'s WAL | waiting for the store":           {state: walWaiting},
	"<role>'s WAL | archived":                        {state: walArchived},
	"the WAL <role> needs | gone from <role>":        {state: neededWALGone},
	"the backup | done":                              {state: backupDone},
	"pg-restore | healthy":                           {state: restoreHealthy},
	"no acknowledged write | lost":                   {state: noneLost},
	"no acknowledged write | lost in pg-restore":     {state: noneLostInRestore},
	"compliance on pg-restore | healthy":             {state: restoreCompliant},
	"the alerts | healthy":                           {state: alertsHealthy},
	"the dashboard | healthy":                        {state: dashboardHealthy},
	"the exporters | healthy":                        {state: exportersAnswer},

	// Since an event.
	"the exporters of <role> and <role> | healthy": {since: exportersKept},
	"writing | down":                               {since: writingDown},

	// Measures, on the client: the longest time without a successful read,
	// and without an acknowledged write while the client writes.
	"reading | healthy": {longest: longestReadGap},
	"writing | healthy": {longest: longestWriteGap, back: writingBack, scenarioLimit: true},
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
	s.newPrimary(pod)
	return nil
}

// fence: kubectl cnpg fencing on, which stops the instance's PostgreSQL;
// unfence: off, which starts it again.
func fence(ctx context.Context, _ *scenario, a args) error {
	_, err := kubectl(ctx, "cnpg", "fencing", "on", clusterName, a.pods[0], "-n", namespace)
	return err
}

func unfence(ctx context.Context, _ *scenario, a args) error {
	_, err := kubectl(ctx, "cnpg", "fencing", "off", clusterName, a.pods[0], "-n", namespace)
	return err
}

// killNodes: the nodes of the instances stop at once, as lost VMs. The bench
// then uses the API server of a node that runs.
func killNodes(ctx context.Context, s *scenario, a args) error {
	var nodes []string
	for _, pod := range a.pods {
		if pod == anotherInstance {
			return errors.New("kill the node of a named instance")
		}
		node, err := nodeOf(ctx, pod)
		if err != nil {
			return err
		}
		nodes = append(nodes, node)
	}
	if err := stopNodes(ctx, nodes...); err != nil {
		return err
	}
	s.down = append(s.down, nodes...)
	s.downPods = append(s.downPods, a.pods...)
	return useRunningAPI(s.down)
}

// startKilled: the n killed nodes start again.
func startKilled(n int) func(context.Context, *scenario, args) error {
	return func(ctx context.Context, s *scenario, _ args) error {
		if len(s.down) != n {
			return fmt.Errorf("%d nodes are down, not %d", len(s.down), n)
		}
		if err := restartNodes(ctx, s.down...); err != nil {
			return err
		}
		s.down, s.downPods = nil, nil
		return nil
	}
}

// killPostgres: the instance's postgres container stops at once, as when
// PostgreSQL crashes or is killed for its memory; the kubelet starts it
// again.
func killPostgres(ctx context.Context, s *scenario, a args) error {
	pod := a.pods[0]
	if pod == anotherInstance {
		return errors.New("kill the container of a named instance")
	}
	out, err := kubectl(ctx, "get", "pod", pod, "-n", namespace, "-o", `jsonpath={.spec.nodeName} `+
		`{.status.containerStatuses[?(@.name=="postgres")].containerID} `+
		`{.status.containerStatuses[?(@.name=="postgres")].restartCount}`)
	if err != nil {
		return err
	}
	fields := strings.Fields(out)
	if len(fields) != 3 {
		return fmt.Errorf("the node, postgres container and restart count of %s: %q", pod, out)
	}
	if s.restarts[pod], err = strconv.Atoi(fields[2]); err != nil {
		return err
	}
	id := strings.TrimPrefix(fields[1], "containerd://")
	_, err = command(ctx, nil, "docker", "exec", fields[0], "crictl", "stop", "--timeout", "0", id)
	return err
}

// postgresRestarted: the instance's postgres container runs again after the
// kill.
func postgresRestarted(ctx context.Context, s *scenario, a args) error {
	pod := a.pods[0]
	out, err := kubectl(ctx, "get", "pod", pod, "-n", namespace, "-o",
		`jsonpath={.status.containerStatuses[?(@.name=="postgres")].restartCount} `+
			`{.status.containerStatuses[?(@.name=="postgres")].state.running.startedAt}`)
	if err != nil {
		return err
	}
	count, running, _ := strings.Cut(out, " ")
	restarts, err := strconv.Atoi(count)
	if err != nil {
		return err
	}
	if restarts <= s.restarts[pod] || running == "" {
		return fmt.Errorf("the postgres container of %s: %d restarts, running since %q", pod, restarts, running)
	}
	return nil
}

// nonePromoted: no promotion has started; the target primary is still the
// primary.
func nonePromoted(ctx context.Context, s *scenario, _ args) error {
	target, err := clusterField(ctx, "targetPrimary")
	if err != nil {
		return err
	}
	if target != s.roles["the primary"] {
		return fmt.Errorf("a promotion started: the target primary is %q", target)
	}
	return nil
}

// postgresDown: PostgreSQL on the instance takes no connection: psql exits
// with 2, which kubectl exec passes on. Its other errors exit with 1.
func postgresDown(ctx context.Context, _ *scenario, a args) error {
	_, err := psql(ctx, a.pods[0], "postgres", "select 1")
	var exit *exec.ExitError
	switch {
	case err == nil:
		return fmt.Errorf("PostgreSQL on %s answers", a.pods[0])
	case errors.As(err, &exit) && exit.ExitCode() == 2:
		return nil
	}
	return fmt.Errorf("psql did not fail for no connection: %w", err)
}

// identOn and identEverywhere: the instance, or every instance, has the
// pg_ident lines every instance had at the first such line, the chart's
// included. PostgreSQL starts with CNPG's own lines only; the chart's come
// back at the instance's next reconcile.
func identOn(ctx context.Context, s *scenario, a args) error {
	return s.identIs(ctx, a.pods[0])
}

func identEverywhere(ctx context.Context, s *scenario, _ args) error {
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	for _, pod := range pods {
		if err := s.identIs(ctx, pod); err != nil {
			return err
		}
	}
	return nil
}

func (s *scenario) identIs(ctx context.Context, pod string) error {
	if s.ident == "" {
		want, err := identOf(ctx, s.roles["the primary"])
		if err != nil {
			return err
		}
		if !strings.Contains("\n"+want, "\nclients|") {
			return fmt.Errorf("the primary has none of the chart's pg_ident lines: %s", oneLine(want))
		}
		s.ident = want
	}
	got, err := identOf(ctx, pod)
	if err != nil {
		return err
	}
	if got != s.ident {
		return fmt.Errorf("the pg_ident lines of %s: %s", pod, oneLine(got))
	}
	return nil
}

func identOf(ctx context.Context, pod string) (string, error) {
	return psql(ctx, pod, "postgres", "select map_name, sys_name, pg_username, error from pg_ident_file_mappings order by 1, 2, 3")
}

func oneLine(text string) string { return strings.ReplaceAll(text, "\n", "; ") }

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
// check and CNPG's in_recovery, of every instance, or of one pod.
func queryMetrics(pod string) []string {
	selector := fmt.Sprintf(`namespace=%q`, namespace)
	if pod != "" {
		selector += fmt.Sprintf(`, pod=%q`, pod)
	}
	return []string{
		`cnpg_compliance_violations{` + selector + `, check="cn_mapping"}`,
		`cnpg_pg_replication_in_recovery{` + selector + `}`,
	}
}

// exportersAnswer: every instance's exporter answered with both query
// metrics in the last 30 s.
func exportersAnswer(ctx context.Context, s *scenario, _ args) error {
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	for _, metric := range queryMetrics("") {
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
		for _, metric := range queryMetrics(pod) {
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
	return healthy(ctx, clusterName)
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
		s.newPrimary(primary)
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
	return s.acknowledgedOn(ctx, clusterName)
}

// acknowledgedOn: every write the client got acknowledged is in bench_writes
// on the primary of the cluster.
func (s *scenario) acknowledgedOn(ctx context.Context, cluster string) error {
	log, err := s.clientLog(ctx)
	if err != nil {
		return err
	}
	acked := log.acknowledged()
	if len(acked) == 0 && s.writes {
		return errors.New("the client got no write acknowledged")
	}
	primary, err := fieldOf(ctx, cluster, "currentPrimary")
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

// writingDown: no write the client sent since the event was acknowledged.
func writingDown(ctx context.Context, s *scenario, _ args, from time.Time) error {
	log, err := s.clientLog(ctx)
	if err != nil {
		return err
	}
	for _, line := range log.lines {
		if line.what == "write" && line.result == "ok" && !line.start.Before(from) {
			return fmt.Errorf("a write sent %s after the event was acknowledged: %s", seconds(line.start.Sub(from)), line.detail)
		}
	}
	return nil
}

// writingBack: the cluster's current primary acknowledged a write that the
// client sent after the event, and when. After a promote, the old primary can still
// acknowledge writes for a moment; those do not count.
func writingBack(ctx context.Context, s *scenario, from time.Time) (time.Time, error) {
	if !s.writes {
		return time.Time{}, errors.New("the scenario has no writes")
	}
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return time.Time{}, err
	}
	ip, err := kubectl(ctx, "get", "pod", primary, "-n", namespace, "-o", "jsonpath={.status.podIP}")
	if err != nil {
		return time.Time{}, err
	}
	log, err := s.clientLog(ctx)
	if err != nil {
		return time.Time{}, err
	}
	var first time.Time
	for _, line := range log.lines {
		_, server, _ := strings.Cut(line.detail, " ")
		if line.what == "write" && line.result == "ok" && server == ip && !line.start.Before(from) &&
			(first.IsZero() || line.end.Before(first)) {
			first = line.end
		}
	}
	if first.IsZero() {
		return time.Time{}, fmt.Errorf("no write sent after the event is acknowledged by %s yet", primary)
	}
	s.detail = fmt.Sprintf("first write acknowledged by %s %s after the event", primary, seconds(first.Sub(from)))
	return first, nil
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
	log, err := s.clientLog(ctx)
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

// clientLog is the client's log so far.
func (s *scenario) clientLog(ctx context.Context) (clientLog, error) {
	if s.cl == nil {
		return clientLog{}, errors.New("the client did not run: the scenario has no When line")
	}
	return s.cl.log(ctx)
}

// stopClient stops the client once.
func (s *scenario) stopClient(ctx context.Context) error {
	if s.cl == nil || !s.clientEnded.IsZero() {
		return nil
	}
	s.clientEnded = time.Now()
	return s.cl.stop(ctx)
}
