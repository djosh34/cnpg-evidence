package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
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
//	<thing> starts|stops|runs|passes
//	N s pass [after the <event>]
//	no writes
//
// "< N s" counts from the line above, "< N s after the <event>" from that
// event, and "for N s" watches the state for the next N s.
const (
	within    = ` < (\d+) s(?: after the (\w+))?`
	isLine    = `^(.+?) (?:is|are) (.+?)(?:` + within + `| for (\d+) s)?$`
	verbLine  = `^(.+?) (starts?|stops|runs|passes)$`
	passLine  = `^(\d+) s pass(?: after the (\w+))?$`
	quietLine = `^no writes$`
)

func (s *scenario) bind(sc *godog.ScenarioContext) {
	sc.StepContext().Before(s.beforeStep)
	sc.StepContext().After(s.afterStep)

	sc.Step(isLine, s.is)
	sc.Step(verbLine, s.verb)
	sc.Step(passLine, s.pass)
	sc.Step(quietLine, s.noWrites)
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
	case w.event != nil:
		if n != "" || forN != "" {
			return fmt.Errorf("an event takes no limit: %s", key)
		}
		return s.event(key, w, a)
	case s.kind == messages.PickleStepType_ACTION:
		return fmt.Errorf("a check in a When line: %s", key)
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

func (s *scenario) event(key string, w word, a args) error {
	if s.kind == messages.PickleStepType_OUTCOME {
		return fmt.Errorf("an event in a Then line: %s", key)
	}
	at := time.Now()
	if err := w.event(s.ctx, s, a); err != nil {
		return err
	}
	if w.mark != "" {
		s.marks[w.mark], s.last = at, w.mark
	}
	return nil
}

// measure checks a measure over the whole scenario against the line's
// limit. A scenario's own line sets the limit that always.feature then
// uses for the same line.
func (s *scenario) measure(key string, w word, n, after, forN string) error {
	if n == "" || after != "" || forN != "" {
		return fmt.Errorf("%s takes only a limit, < N s", key)
	}
	limit, err := strconv.Atoi(n)
	if err != nil {
		return err
	}
	if !s.inAlways {
		s.limits[key] = limit
	} else if own, ok := s.limits[key]; ok {
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
// primary; "the new primary" is the instance that became primary last.
var roleNames = []string{"the new primary", "the primary", "replica 1", "replica 2", "another instance"}

const anotherInstance = ""

// args are what lookup took out of a line: the pods of its roles, in order.
type args struct {
	pods []string
}

// lookup turns thing and word into a vocabulary key, replacing each role
// with <role> and keeping its pod.
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
		key += text[i : i+1]
		i++
	}
	if _, ok := vocabulary[key]; !ok {
		return "", a, fmt.Errorf("not in the vocabulary: %q", key)
	}
	return key, a, nil
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
			Format: "progress", Output: io.Discard, Strict: true, NoColors: true,
			Paths: []string{filepath.Join(benchDir, "features", "always.feature")},
		},
	}
	if suite.Run() != 0 && failed == nil {
		failed = errors.New("always.feature: a line did not bind to exactly one step")
	}
	return failed
}
