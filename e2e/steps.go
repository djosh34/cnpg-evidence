package main

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"maps"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/cucumber/godog"
	messages "github.com/cucumber/messages/go/v34"
)

// The line shapes. Most lines are "<thing> is <word>": the step cuts the line
// into thing, word and limit, and looks them up in the vocabulary
// (vocab.go), which says what the e2e test does. The limits are in the feature
// files.
//
//	<thing> is|are <word> [< N s [after the <event>] | for N s]
//	<thing> has|have been <word> since the <event>
//	<thing> starts|stops|runs|passes
//	N s pass [after the <event>]
//	<ALERT> [<severity>] fired|may fire|fires|resolves|has not fired for <who> [< N s [after the <event>]]
//	Alertmanager gets|sends|mutes [the resolved] <ALERT> [<severity>] for <who> [< N s [after the <event>]]
//	no writes
//	host-check.sh fails these checks on every node:, with a table
//	host-check.sh passes every check on every node but these:, with a table
//
// "< N s" counts from the line above, "< N s after the <event>" from that
// event, "for N s" watches the state for the next N s, and "since the
// <event>" checks the whole time from that event to now. A measure such as
// "writing is healthy" takes "< N s" as its limit over the whole scenario,
// and "< N s after the <event>" as the time by which it is back after that
// event.
const (
	within    = ` < (\d+) s(?: after the (\w+))?`
	isLine    = `^(.+?) (?:is|are) (.+?)(?:` + within + `| for (\d+) s)?$`
	sinceLine = `^(.+?) (?:has|have) been (.+) since the (\w+)$`
	verbLine  = `^(.+?) (starts?|stops|runs|passes)$`
	passLine  = `^(\d+) s pass(?: after the (\w+))?$`
	alertLine = `^([A-Z]\w+)(?: (warning|critical))? (fired|may fire|fires|resolves|has not fired) for (.+?)(?:` + within + `)?$`
	amLine    = `^Alertmanager (gets|sends|mutes) (the resolved )?([A-Z]\w+)(?: (warning|critical))? for (.+?)(?:` + within + `)?$`
	quietLine = `^no writes$`
	failsLine = `^host-check\.sh fails these checks on every node:$`
	butLine   = `^host-check\.sh passes every check on every node but these:$`
)

func (s *scenario) bind(sc *godog.ScenarioContext) {
	sc.StepContext().Before(s.beforeStep)
	sc.StepContext().After(s.afterStep)

	sc.Step(isLine, s.is)
	sc.Step(sinceLine, s.since)
	sc.Step(verbLine, s.verb)
	sc.Step(passLine, s.pass)
	sc.Step(alertLine, s.alert)
	sc.Step(amLine, s.alertmanager)
	sc.Step(quietLine, s.noWrites)
	sc.Step(failsLine, s.hostCheckFails)
	sc.Step(butLine, s.hostCheckPassesBut)
}

// scenario is the state of the run's one scenario.
type scenario struct {
	ctx     context.Context
	w       *world
	results *results

	kind  messages.PickleStepType // Given, When or Then of the line running
	roles map[string]string       // the instances by role: the primary, replica 1, ...
	marks map[string]time.Time    // when each named event happened
	last  string                  // the last named event

	clientRan   bool      // the client was started
	clientEnded time.Time // when the e2e test stopped it
	writes      bool      // false after "Given no writes"

	// The outages in place, which endOutages ends after a failed line.
	down     []string // the nodes killed and not started again
	downPods []string // the instances on them
	fenced   []string // the instances fenced and not unfenced
	paused   []string // the instances whose replay is paused
	cut      []string // the instances cut off and not reconnected

	needs    map[string]walNeed            // what each instance that was down needs of the WAL written meanwhile
	switched map[string]string             // the WAL file each instance switched away from last
	restarts map[string]int                // the restart count of an instance's postgres container before it was killed
	ident    string                        // the pg_ident lines every instance had at the first line about them
	store    string                        // how the store is broken: stopped, paused, or "" when it is not
	drain    *drained                      // the node a drain runs on or cordoned, until it is uncordoned
	commit   *background                   // the commit "a commit is started" started
	scripts  map[string]scriptRun          // what each script gave, by its name and node
	ballast  string                        // the ballast file on a data disk, until it is removed
	held     *held                         // the sessions held on an instance, until they are ended
	newCAs   map[string]x509.VerifyOptions // the new k3s CAs stored in etcd, by name

	started time.Time       // when the scenario started, after the monitoring was ready
	alerts  map[string]bool // the alerts the scenario names, "<alertname> <pod>": true when they must fire, false when they may

	limits        map[string]int // the scenario's own limits of the measures
	alwaysWriting int            // the limit always.feature gives writing
	primaryOut    bool           // the primary changed or stopped in the scenario
	inAlways      bool           // always.feature runs

	stepStart time.Time
	holding   time.Time // when the "for N s" line running started
	detail    string    // what the line running measured, for the timing table
	rows      []row
}

// One line of the timing table.
type row struct {
	line, result, took, after, detail string
}

// beforeStep starts the client at the first event, with its writes unless
// the scenario said "Given no writes".
func (s *scenario) beforeStep(ctx context.Context, st *godog.Step) (context.Context, error) {
	s.kind, s.stepStart, s.detail = st.Type, time.Now(), ""
	logf("%s %s", keyword(st.Type), st.Text)
	if st.Type == messages.PickleStepType_ACTION && !s.clientRan {
		if s.w == nil {
			return ctx, errors.New("the cluster did not start")
		}
		logf("starting the client, writes %t", s.writes)
		s.clientRan = true
		if err := s.w.startClient(ctx, s.writes); err != nil {
			return ctx, fmt.Errorf("the client: %w", err)
		}
	}
	return ctx, nil
}

// afterStep prints how the line went and adds it to the timing table, with
// its time after the last named event.
func (s *scenario) afterStep(ctx context.Context, st *godog.Step, status godog.StepResultStatus, err error) (context.Context, error) {
	r := row{
		line:   keyword(st.Type) + " " + st.Text,
		result: status.String(),
		took:   seconds(time.Since(s.stepStart)),
		detail: s.detail,
	}
	if s.last != "" {
		r.after = seconds(time.Since(s.marks[s.last])) + " after the " + s.last
	}
	s.rows = append(s.rows, r)
	switch {
	case err != nil:
		logf("  %s in %s: %v", r.result, r.took, err)
	case r.detail != "":
		logf("  %s in %s: %s", r.result, r.took, r.detail)
	default:
		logf("  %s in %s", r.result, r.took)
	}
	return ctx, nil
}

func keyword(t messages.PickleStepType) string {
	switch t {
	case messages.PickleStepType_CONTEXT:
		return "Given"
	case messages.PickleStepType_ACTION:
		return "When"
	case messages.PickleStepType_OUTCOME:
		return "Then"
	}
	return "*"
}

func seconds(d time.Duration) string { return fmt.Sprintf("%.1f s", d.Seconds()) }

// is: "<thing> is <word>", with "< N s", "< N s after the <event>" or "for N s".
func (s *scenario) is(thing, word, n, after, forN string) error {
	key, a, err := s.lookup(thing, word)
	if err != nil {
		return err
	}
	w := vocabulary[key]
	switch {
	case w.since != nil:
		return fmt.Errorf("%s takes only \"has been ... since the <event>\"", key)
	case w.event != nil:
		if n != "" || forN != "" {
			return fmt.Errorf("an event takes no limit: %s", key)
		}
		return s.event(key, w, a)
	case s.kind == messages.PickleStepType_ACTION:
		return fmt.Errorf("a check in a When line: %s", key)
	case w.longest != nil && after != "":
		return s.measureBack(key, w, n, after)
	case w.longest != nil:
		return s.measure(key, w, n, after, forN)
	}
	check := func(ctx context.Context) error { return w.state(ctx, s, a) }
	if forN != "" {
		return s.holdsFor(forN, check)
	}
	return s.within(n, after, check)
}

// since: "<thing> has been <word> since the <event>", a check of the whole
// time from that event to now.
func (s *scenario) since(thing, word, event string) error {
	key, a, err := s.lookup(thing, word)
	if err != nil {
		return err
	}
	w := vocabulary[key]
	if w.since == nil {
		return fmt.Errorf("%s takes no \"since\"", key)
	}
	if s.kind == messages.PickleStepType_ACTION {
		return fmt.Errorf("a check in a When line: %s", key)
	}
	from, ok := s.marks[event]
	if !ok {
		return fmt.Errorf("no %s yet", event)
	}
	return w.since(s.ctx, s, a, from)
}

// alert: "<ALERT> fires for <who> < N s" and the other alert words. fires
// and resolves wait up to N s, or check now; fired and has not fired check
// the whole scenario. fired and fires name an alert that must fire, may fire
// one that may; always.feature's "the alerts are healthy" fails on any
// other. A severity limits the check to the alert of that severity.
func (s *scenario) alert(name, severity, verb, who, n, after string) error {
	if s.kind == messages.PickleStepType_ACTION {
		return errors.New("an alert check in a When line")
	}
	labels, err := s.alertLabels(name, severity, who)
	if err != nil {
		return err
	}
	key := alertKey(name, labels["pod"])
	var check func(context.Context) error
	switch verb {
	case "may fire":
		if severity != "" || n != "" {
			return errors.New("may fire takes no severity and no limit")
		}
		if !s.alerts[key] {
			s.alerts[key] = false
		}
		return nil
	case "fires":
		s.alerts[key] = true
		check = s.alertIs(labels, true, false)
	case "resolves":
		check = s.alertIs(labels, false, false)
	case "fired":
		s.alerts[key] = true
		check = s.alertIs(labels, true, true)
	case "has not fired":
		check = s.alertIs(labels, false, true)
	}
	return s.within(n, after, check)
}

// alertLabels are the labels of the alert a line names. who is an instance
// by its role, with its pod; "the cluster", an alert of the whole cluster,
// with the cluster and no pod; or "the server certificate" or "the
// replication certificate", with the Certificate's name and no pod.
func (s *scenario) alertLabels(name, severity, who string) (map[string]string, error) {
	labels := map[string]string{"alertname": name, "pod": ""}
	if severity != "" {
		labels["severity"] = severity
	}
	switch who {
	case "the cluster":
		labels["cluster"] = clusterName
	case "the server certificate", "the replication certificate":
		labels["cluster"] = clusterName
		labels["name"] = clusterName + "-" + strings.Fields(who)[1]
	default:
		pod, err := s.role(who)
		if err == nil && pod == anotherInstance {
			err = errors.New("an alert names one instance, the cluster or a certificate")
		}
		if err != nil {
			return nil, err
		}
		labels["pod"] = pod
	}
	return labels, nil
}

// alertIs checks that an alert with the labels fires now, or fired in the
// scenario, or not.
func (s *scenario) alertIs(labels map[string]string, want, inScenario bool) func(context.Context) error {
	return func(ctx context.Context) error {
		var from time.Time
		what := "fires"
		if inScenario {
			from, what = s.started, "fired in the scenario"
		}
		got, err := s.w.mon.alertFires(ctx, labels, from)
		if err != nil {
			return err
		}
		if got != want {
			all, err := s.w.mon.firing(ctx)
			if inScenario {
				all, err = s.w.mon.fired(ctx, s.started)
			}
			return errors.Join(fmt.Errorf("%s %s: %t; the alerts: %s", selector(labels), what, got,
				strings.Join(slices.Sorted(maps.Keys(all)), ", ")), err)
		}
		return nil
	}
}

// alertmanager: "Alertmanager gets <ALERT> for <role>" sends Alertmanager
// that alert as the rule evaluator would; "sends" waits until the receiver
// got it as firing, or "sends the resolved" as resolved, and "mutes" until
// Alertmanager holds it suppressed.
func (s *scenario) alertmanager(verb, resolved, name, severity, who, n, after string) error {
	labels, err := s.alertLabels(name, severity, who)
	if err != nil {
		return err
	}
	if resolved != "" && verb != "sends" {
		return errors.New("only sends takes the resolved")
	}
	if verb == "gets" {
		if s.kind == messages.PickleStepType_OUTCOME || n != "" || severity != "" || labels["pod"] == "" {
			return errors.New("gets: an event of one instance, with no limit and no severity")
		}
		return s.w.mon.amSend(s.ctx, name, labels["pod"])
	}
	if s.kind == messages.PickleStepType_ACTION {
		return errors.New("an Alertmanager check in a When line")
	}
	status := "firing"
	if resolved != "" {
		status = "resolved"
	}
	check := func(ctx context.Context) error { return s.w.mon.sent(labels, status, s.started) }
	if verb == "mutes" {
		check = func(ctx context.Context) error {
			state, err := s.w.mon.amState(ctx, labels)
			if err == nil && state != "suppressed" {
				err = fmt.Errorf("the state of %s in Alertmanager: %q", selector(labels), state)
			}
			return err
		}
	}
	return s.within(n, after, check)
}

// verb: "<thing> starts", "stops", "runs" or "passes".
func (s *scenario) verb(thing, verb string) error { return s.is(thing, verb, "", "", "") }

// pass: "N s pass", from the line above or after an event.
func (s *scenario) pass(n, after string) error {
	if s.kind == messages.PickleStepType_OUTCOME {
		return errors.New("a wait in a Then line")
	}
	until, err := s.deadline(n, after)
	if err != nil {
		return err
	}
	select {
	case <-s.ctx.Done():
		return s.ctx.Err()
	case <-time.After(time.Until(until)):
		return nil
	}
}

// noWrites: "Given no writes", the only scenarios whose client never writes.
func (s *scenario) noWrites() error {
	if s.clientRan {
		return errors.New("no writes must come before the first event")
	}
	s.writes = false
	return nil
}

// event does an event. Its time, for "after the <event>" and "since the
// <event>", is when the e2e test has done it: a kill, for one, first looks up
// the nodes.
func (s *scenario) event(key string, w word, a args) error {
	if s.kind == messages.PickleStepType_OUTCOME {
		return fmt.Errorf("an event in a Then line: %s", key)
	}
	if err := w.event(s.ctx, s, a); err != nil {
		return err
	}
	if w.mark != "" {
		s.marks[w.mark], s.last = time.Now(), w.mark
	}
	return nil
}

// measure checks a measure over the whole scenario against the line's
// limit. For writing, a scenario's own line sets the limit that
// always.feature then uses; every other limit of always.feature holds for
// every scenario. In a variant run where the primary changed or stopped,
// reading takes the limit of writing: the scenario's own, else that of
// always.feature.
func (s *scenario) measure(key string, w word, n, after, forN string) error {
	if n == "" || after != "" || forN != "" {
		return fmt.Errorf("%s takes only a limit, < N s", key)
	}
	limit, err := strconv.Atoi(n)
	if err != nil {
		return err
	}
	switch own, ok := s.limits[key]; {
	case w.writingLimit && variant != "" && s.primaryOut:
		if limit, ok = s.limits["writing | healthy"]; !ok {
			limit = s.alwaysWriting
		}
		if limit == 0 {
			return fmt.Errorf("%s takes the limit of writing, and no line gave one", key)
		}
	case !w.scenarioLimit:
	case !s.inAlways:
		s.limits[key] = limit
	case ok:
		limit = own
	default:
		s.limits[key] = limit
	}
	got, err := w.longest(s.ctx, s)
	if err != nil {
		return err
	}
	s.detail = "longest " + seconds(got)
	if got >= time.Duration(limit)*time.Second {
		return fmt.Errorf("%s: the longest time without one was %s, not < %d s", key, seconds(got), limit)
	}
	return nil
}

// measureBack waits until the measure is back after the event, by N s after
// it. It counts when the measure came back, not when the e2e test saw it.
func (s *scenario) measureBack(key string, w word, n, after string) error {
	if w.back == nil {
		return fmt.Errorf("%s takes no \"after the <event>\"", key)
	}
	deadline, err := s.deadline(n, after)
	if err != nil {
		return err
	}
	from := s.marks[after]
	var back time.Time
	err = poll(s.ctx, deadline, func(ctx context.Context) error {
		var err error
		back, err = w.back(ctx, s, from)
		return err
	})
	if err != nil && !back.IsZero() && !back.After(deadline) {
		return nil
	}
	return err
}

func (s *scenario) holdsFor(n string, check func(context.Context) error) error {
	secs, err := strconv.Atoi(n)
	if err != nil {
		return err
	}
	s.holding = time.Now()
	defer func() { s.holding = time.Time{} }()
	end := s.holding.Add(time.Duration(secs) * time.Second)
	for {
		if err := check(s.ctx); err != nil {
			return fmt.Errorf("it stopped holding %s before the end: %w", seconds(time.Until(end)), err)
		}
		if time.Now().After(end) {
			return nil
		}
		select {
		case <-s.ctx.Done():
			return s.ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// within checks now without a limit, or waits until the check holds, by N s
// from now or N s after a named event.
func (s *scenario) within(n, after string, check func(context.Context) error) error {
	if n == "" {
		return check(s.ctx)
	}
	deadline, err := s.deadline(n, after)
	if err != nil {
		return err
	}
	return poll(s.ctx, deadline, check)
}

// deadline is N s from now, or N s after a named event.
func (s *scenario) deadline(n, after string) (time.Time, error) {
	secs, err := strconv.Atoi(n)
	if err != nil {
		return time.Time{}, err
	}
	from := time.Now()
	if after != "" {
		var ok bool
		if from, ok = s.marks[after]; !ok {
			return time.Time{}, fmt.Errorf("no %s yet", after)
		}
	}
	return from.Add(time.Duration(secs) * time.Second), nil
}

// keepWritingLimit keeps the limit always.feature gives writing: reading
// can take it before the writing line runs.
func (s *scenario) keepWritingLimit(sn *godog.Scenario) error {
	line := regexp.MustCompile(isLine)
	for _, st := range sn.Steps {
		if m := line.FindStringSubmatch(st.Text); m != nil && m[1] == "writing" && m[2] == "healthy" && m[3] != "" {
			var err error
			s.alwaysWriting, err = strconv.Atoi(m[3])
			return err
		}
	}
	return errors.New(`always.feature has no line "writing is healthy < N s"`)
}

// stops marks the primary as stopped when one of the pods is the primary
// now: the one that became primary last, else the first.
func (s *scenario) stops(pods ...string) {
	primary, ok := s.roles["the new primary"]
	if !ok {
		primary = s.roles["the primary"]
	}
	if slices.Contains(pods, primary) {
		s.primaryOut = true
	}
}

// The roles a line can name. "another instance" is any instance but the
// primary; "the new primary" is the instance that became primary last; "a
// replica" is an instance other than the one that became primary last.
var roleNames = []string{"the new primary", "the primary", "replica 1", "replica 2", "another instance", "a replica"}

const anotherInstance = ""

// args are what lookup took out of a line: the pods of its roles and its
// numbers, in order.
type args struct {
	pods []string
	ns   []int
}

// lookup turns thing and word into a vocabulary key, replacing each role
// with <role> and keeping its pod, and each number with <n>. Digits right
// after a letter are part of a word, as in k3s.
func (s *scenario) lookup(thing, word string) (string, args, error) {
	var a args
	key := ""
	text := thing + " | " + word
next:
	for i := 0; i < len(text); {
		for _, name := range roleNames {
			if strings.HasPrefix(text[i:], name) {
				pod, err := s.role(name)
				if err != nil {
					return "", a, err
				}
				a.pods = append(a.pods, pod)
				key += "<role>"
				i += len(name)
				continue next
			}
		}
		if digits := leadingDigits(text[i:]); digits != "" && (i == 0 || !isLetter(text[i-1])) {
			n, err := strconv.Atoi(digits)
			if err != nil {
				return "", a, err
			}
			a.ns = append(a.ns, n)
			key += "<n>"
			i += len(digits)
			continue
		}
		key += text[i : i+1]
		i++
	}
	if _, ok := vocabulary[key]; !ok {
		return "", a, fmt.Errorf("not in the vocabulary: %q", key)
	}
	return key, a, nil
}

func isLetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

func leadingDigits(text string) string {
	end := 0
	for end < len(text) && text[end] >= '0' && text[end] <= '9' {
		end++
	}
	return text[:end]
}

// newPrimary names the instance that became primary: the new primary, and a
// replica one of the others.
func (s *scenario) newPrimary(pod string) {
	s.roles["the new primary"] = pod
	for _, role := range []string{"the primary", "replica 1", "replica 2"} {
		if other := s.roles[role]; other != pod {
			s.roles["a replica"] = other
			return
		}
	}
}

func (s *scenario) role(name string) (string, error) {
	if name == "another instance" {
		return anotherInstance, nil
	}
	pod, ok := s.roles[name]
	if !ok {
		return "", fmt.Errorf("no %s yet", name)
	}
	return pod, nil
}

// runAlways runs always.feature with godog, bound to the same steps and
// state. Its first failing line fails the scenario.
func (s *scenario) runAlways() error {
	s.inAlways = true
	format := "progress,cucumber:" + s.results.path("always.cucumber.json") + ",junit:" + s.results.path("always.junit.xml")
	var failed error
	suite := godog.TestSuite{
		Name: "always",
		ScenarioInitializer: func(sc *godog.ScenarioContext) {
			sc.Before(func(ctx context.Context, sn *godog.Scenario) (context.Context, error) {
				return ctx, s.keepWritingLimit(sn)
			})
			s.bind(sc)
			sc.StepContext().After(func(ctx context.Context, st *godog.Step, _ godog.StepResultStatus, err error) (context.Context, error) {
				if err != nil && failed == nil {
					failed = fmt.Errorf("always.feature: %s: %w", st.Text, err)
				}
				return ctx, nil
			})
		},
		Options: &godog.Options{
			Format: format, Output: io.Discard, Strict: true, NoColors: true,
			Paths: []string{filepath.Join(samplesDir, "features", "always.feature")},
		},
	}
	if suite.Run() != 0 && failed == nil {
		failed = errors.New("always.feature: a line did not bind to exactly one step")
	}
	return failed
}
