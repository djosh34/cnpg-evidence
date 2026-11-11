package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/cucumber/godog"
	messages "github.com/cucumber/messages/go/v34"
)

// The line shapes. Most lines are "<thing> is <word>": the step cuts the line
// into thing, word and limit, and looks them up in the vocabulary
// (vocab.go), which says what the bench does. The limits are in the feature
// files.
//
//	<thing> is|are <word> [< N s [after the <event>] | for N s]
//	<thing> has|have been <word> since the <event>
//	<thing> starts|stops|runs|passes
//	N s pass [after the <event>]
//	<ALERT> fired|may fire|fires|resolves|has not fired for <role>|the cluster [< N s [after the <event>]]
//	Alertmanager gets|sends|mutes <ALERT> for <role> [< N s [after the <event>]]
//	no writes
//	host-check.sh fails exactly these checks on every node:, with a table
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
	alertLine = `^(CNPG\w+) (fired|may fire|fires|resolves|has not fired) for (.+?)(?:` + within + `)?$`
	amLine    = `^Alertmanager (gets|sends|mutes) (CNPG\w+) for (.+?)(?:` + within + `)?$`
	quietLine = `^no writes$`
	tableLine = `^host-check\.sh fails exactly these checks on every node:$`
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
	sc.Step(tableLine, s.hostCheckFails)
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

	cl          *client
	clientEnded time.Time
	writes      bool // false after "Given no writes"

	down     []string // the nodes killed and not started again
	downPods []string // the instances on them

	needs    map[string]walNeed   // what each instance that was down needs of the WAL written meanwhile
	switched map[string]string    // the WAL file each instance switched away from last
	restarts map[string]int       // the restart count of an instance's postgres container before it was killed
	ident    string               // the pg_ident lines every instance had at the first line about them
	store    string               // how the store is broken: stopped, paused, or "" when it is not
	drain    *drained             // the node a drain runs on, until it is uncordoned
	commit   *background          // the commit "a commit is started" started
	scripts  map[string]scriptRun // what each script gave, by its name and node

	started time.Time       // when the scenario started, after the monitoring was ready
	alerts  map[string]bool // the alerts the scenario names, "<alertname> <pod>": true when they must fire, false when they may

	limits   map[string]int // the scenario's own limits of the measures
	inAlways bool           // always.feature runs

	stepStart time.Time
	detail    string // what the line running measured, for the timing table
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
	if st.Type == messages.PickleStepType_ACTION && s.cl == nil {
		if s.w == nil {
			return ctx, errors.New("the cluster did not start")
		}
		logf("starting the client, writes %t", s.writes)
		cl, err := s.w.startClient(ctx, s.writes)
		s.cl = cl
		if err != nil {
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
	switch {
	case forN != "":
		return s.holdsFor(forN, check)
	case n != "":
		deadline, err := s.deadline(n, after)
		if err != nil {
			return err
		}
		return poll(s.ctx, deadline, check)
	}
	return check(s.ctx)
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

// alert: "<ALERT> fires for <role> < N s" and the other alert words. fires
// and resolves wait up to N s, or check now; fired and has not fired check
// the whole scenario. fired and fires name an alert that must fire, may fire
// one that may; always.feature's "the alerts are healthy" fails on any
// other.
func (s *scenario) alert(name, verb, who, n, after string) error {
	if s.kind == messages.PickleStepType_ACTION {
		return errors.New("an alert check in a When line")
	}
	pod, err := s.alertPod(who)
	if err != nil {
		return err
	}
	key := alertKey(name, pod)
	var check func(context.Context) error
	switch verb {
	case "may fire":
		if !s.alerts[key] {
			s.alerts[key] = false
		}
		return nil
	case "fires":
		s.alerts[key] = true
		check = s.alertIs(key, true, false)
	case "resolves":
		check = s.alertIs(key, false, false)
	case "fired":
		s.alerts[key] = true
		check = s.alertIs(key, true, true)
	case "has not fired":
		check = s.alertIs(key, false, true)
	}
	if n == "" {
		return check(s.ctx)
	}
	deadline, err := s.deadline(n, after)
	if err != nil {
		return err
	}
	return poll(s.ctx, deadline, check)
}

// alertPod is the pod an alert line names: an instance by its role, or ""
// for "the cluster", an alert of the whole cluster such as CNPGDatabaseDown.
func (s *scenario) alertPod(who string) (string, error) {
	if who == "the cluster" {
		return "", nil
	}
	pod, err := s.role(who)
	if err == nil && pod == anotherInstance {
		err = errors.New("an alert names one instance, or the cluster")
	}
	return pod, err
}

// alertIs checks that key fires now, or fired in the scenario, or not.
func (s *scenario) alertIs(key string, want, inScenario bool) func(context.Context) error {
	return func(ctx context.Context) error {
		alerts, err := s.w.mon.firing(ctx)
		what := "fires"
		if inScenario {
			alerts, err = s.w.mon.fired(ctx, s.started)
			what = "fired in the scenario"
		}
		if err != nil {
			return err
		}
		if alerts[key] != want {
			return fmt.Errorf("%s %s: %t; the alerts: %s", key, what, alerts[key], strings.Join(slices.Sorted(maps.Keys(alerts)), ", "))
		}
		return nil
	}
}

// alertmanager: "Alertmanager gets <ALERT> for <role>" sends Alertmanager
// that alert as the rule evaluator would; "sends" waits until the receiver
// got it, "mutes" until Alertmanager holds it suppressed.
func (s *scenario) alertmanager(verb, name, who, n, after string) error {
	pod, err := s.role(who)
	if err != nil {
		return err
	}
	if pod == anotherInstance {
		return errors.New("an alert names one instance")
	}
	if verb == "gets" {
		if s.kind == messages.PickleStepType_OUTCOME || n != "" {
			return errors.New("gets: an event, with no limit")
		}
		return s.w.mon.amSend(s.ctx, name, pod)
	}
	if s.kind == messages.PickleStepType_ACTION {
		return errors.New("an Alertmanager check in a When line")
	}
	check := func(ctx context.Context) error { return s.w.mon.sent(name, pod, s.started) }
	if verb == "mutes" {
		check = func(ctx context.Context) error {
			state, err := s.w.mon.amState(ctx, name, pod)
			if err == nil && state != "suppressed" {
				err = fmt.Errorf("the state of %s for %s in Alertmanager: %q", name, pod, state)
			}
			return err
		}
	}
	if n == "" {
		return check(s.ctx)
	}
	deadline, err := s.deadline(n, after)
	if err != nil {
		return err
	}
	return poll(s.ctx, deadline, check)
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
	if s.cl != nil {
		return errors.New("no writes must come before the first event")
	}
	s.writes = false
	return nil
}

// event does an event. Its time, for "after the <event>" and "since the
// <event>", is when the bench has done it: a kill, for one, first looks up
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
// every scenario.
func (s *scenario) measure(key string, w word, n, after, forN string) error {
	if n == "" || after != "" || forN != "" {
		return fmt.Errorf("%s takes only a limit, < N s", key)
	}
	limit, err := strconv.Atoi(n)
	if err != nil {
		return err
	}
	switch own, ok := s.limits[key]; {
	case !w.scenarioLimit:
	case !s.inAlways:
		s.limits[key] = limit
	case ok:
		limit = own
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
// it. It counts when the measure came back, not when the bench saw it.
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
	end := time.Now().Add(time.Duration(secs) * time.Second)
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
// with <role> and keeping its pod, and each number with <n>.
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
		if digits := leadingDigits(text[i:]); digits != "" {
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
	format := "progress"
	if s.results.dir != "" {
		format += ",cucumber:" + s.results.path("always.cucumber.json") + ",junit:" + s.results.path("always.junit.xml")
	}
	var failed error
	suite := godog.TestSuite{
		Name: "always",
		ScenarioInitializer: func(sc *godog.ScenarioContext) {
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
			Paths: []string{filepath.Join(benchDir, "features", "always.feature")},
		},
	}
	if suite.Run() != 0 && failed == nil {
		failed = errors.New("always.feature: a line did not bind to exactly one step")
	}
	return failed
}
