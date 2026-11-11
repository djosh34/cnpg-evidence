package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The pgfallback report: what the client's reads and writes through
// pgfallback did from an event on, in seconds after the event. The client
// reads through one pool and writes through another, each with its own
// pgfallback, and connects to each rw address alone every 0.25 s.
//
//   - rw took no connection while no rw address's last connect alone worked.
//     rw is back at the end of the first connect that worked after that.
//   - Reads and writes work again at the end of the first one that worked
//     after the last one that failed, counting the failures that were still
//     running at the event.
//   - The last read or write served by a read address after rw was back.
//   - A read or write is wrong when a read address served it although it
//     started more than 1 s after rw was back, while rw took connections
//     until 0.25 s after it ended, and after its pool's own attempt at rw had
//     worked: the first attempt of that pool that worked since rw went down
//     and before it went down again. Without one, 1 s alone. That attempt
//     must work within 1 s plus connect_timeout per rw address and one more
//     after rw was back: the attempt that was running then can still wait
//     on addresses it dialed before, and the next one connects. Every read
//     and write is one statement, so none ran inside a transaction that was
//     already open.
//   - Every failed read and write with its error, consecutive ones with the
//     same address and error as one line.
//   - The last read and write of the log so far worked on rw.
//
// A wrong read or write, a late attempt, or a last read or write not on rw
// makes the report fail.

const (
	rwPort         = 5432
	readPort       = 5433
	connectEvery   = 250 * time.Millisecond
	connectTimeout = 2 * time.Second
	// pgfallback marks rw back only after it closed the attempt's
	// connection, which ends after the attempt's AfterConnect logged that it
	// worked.
	markedBack = 100 * time.Millisecond
)

// pgfallbackKept: the report from the event on finds nothing pgfallback
// must not do. The report goes to pgfallback.md of the results and to the
// run's output.
func pgfallbackKept(ctx context.Context, s *scenario, _ args, from time.Time) error {
	log, err := s.clientLog(ctx)
	if err != nil {
		return err
	}
	pools := []string{"read"}
	if s.writes {
		pools = append(pools, "write")
	}
	rwAddrs := make([]string, nodeCount)
	for i := range rwAddrs {
		rwAddrs[i] = net.JoinHostPort(nodeHost(i), strconv.Itoa(rwPort))
	}
	report, err := fallbackReport(log, from, rwAddrs, pools)
	say(os.Stdout, "%s\n", report)
	s.detail = "the report is in pgfallback.md"
	return errors.Join(err, s.results.write("pgfallback.md", report))
}

// One line of the log, in ms.
type entry struct {
	start, end int64
	what       string // read, write, connect, read-attempt or write-attempt
	addr       string
	result     string
	detail     string
}

func (e entry) ok() bool { return e.result == "ok" }

func (e entry) port() int {
	_, port, err := net.SplitHostPort(e.addr)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(port)
	if err != nil {
		return 0
	}
	return n
}

// rwState is whether rw takes connections from time at on.
type rwState struct {
	at int64
	up bool
}

// rwTimeline follows the connects alone: rw is up while the last connect of
// at least one address worked. A connect that worked counts from its end. One
// that failed counts from its start, since the address did not take a
// connection tried then; a connect that waits for its timeout is known to
// fail only at its end.
func rwTimeline(connects []entry) []rwState {
	type probe struct {
		at   int64
		addr string
		ok   bool
	}
	probes := make([]probe, len(connects))
	for i, e := range connects {
		probes[i] = probe{at: known(e), addr: e.addr, ok: e.ok()}
	}
	slices.SortStableFunc(probes, func(a, b probe) int { return cmp.Compare(a.at, b.at) })
	last := map[string]bool{}
	var states []rwState
	for _, p := range probes {
		last[p.addr] = p.ok
		up := false
		for _, ok := range last {
			up = up || ok
		}
		if len(states) == 0 || states[len(states)-1].up != up {
			states = append(states, rwState{at: p.at, up: up})
		}
	}
	return states
}

// known is when a connect alone tells its result, as rwTimeline counts it.
func known(e entry) int64 {
	if e.ok() {
		return e.end
	}
	return e.start
}

// spells lists each spell of states without rw that was not over before the
// event, "never" when there was none, and returns when rw was last back: -1
// when it was not down, -2 when it is not back.
func spells(states []rwState, event int64, secs func(int64) string) (string, int64) {
	var downs []string
	back := int64(-1)
	for i, s := range states {
		if s.up {
			continue
		}
		if i+1 == len(states) {
			downs = append(downs, "from "+secs(s.at)+", not back")
			back = -2
			break
		}
		end := states[i+1].at
		if end >= event {
			downs = append(downs, "from "+secs(s.at)+" to "+secs(end))
			back = end
		}
	}
	if len(downs) == 0 {
		return "never", back
	}
	return strings.Join(downs, ", "), back
}

// recovery is the spell without rw that ended at up and the spell with rw
// after it: when rw went down, or up when it was not down before, and when
// it went down again, or never.
func recovery(states []rwState, up int64) (int64, int64) {
	since, until := up, int64(math.MaxInt64)
	for i, s := range states {
		if s.at != up {
			continue
		}
		if i > 0 {
			since = states[i-1].at
		}
		if i+1 < len(states) {
			until = states[i+1].at
		}
	}
	return since, until
}

// stateAt is the state at time t, and false when no connect ended by then.
func stateAt(states []rwState, t int64) (rwState, bool) {
	i, _ := slices.BinarySearchFunc(states, t+1, func(s rwState, t int64) int { return cmp.Compare(s.at, t) })
	if i == 0 {
		return rwState{}, false
	}
	return states[i-1], true
}

// workedAttempt is the first attempt at rw of pool that worked from since
// to before until: when it started and when it worked, and false when there
// is none. pgfallback runs one attempt at a time per pool, so the attempt
// that worked is the one that started last before.
func workedAttempt(attempts []entry, pool string, since, until int64) (int64, int64, bool) {
	what := pool + "-attempt"
	for _, e := range attempts {
		if e.what != what || e.result != "worked" || e.end < since || e.end >= until {
			continue
		}
		start := e.end
		for _, a := range attempts {
			if a.what == what && a.result == "started" && a.end <= e.end {
				start = a.end
			}
		}
		return start, e.end, true
	}
	return 0, 0, false
}

// fallbackReport is the report, in Markdown, of the reads and writes of
// pools from the event on. rwAddrs are the rw addresses, in the order of the
// connection string.
func fallbackReport(log clientLog, eventTime time.Time, rwAddrs, pools []string) (string, error) {
	event := eventTime.UnixMilli()
	var connects, attempts, ops []entry
	for _, l := range log.lines {
		e := entry{start: l.start.UnixMilli(), end: l.end.UnixMilli(), what: l.what, addr: l.address, result: l.result, detail: l.detail}
		switch {
		case e.what == "connect":
			connects = append(connects, e)
		case strings.HasSuffix(e.what, "-attempt"):
			attempts = append(attempts, e)
		case slices.Contains(pools, e.what):
			ops = append(ops, e)
		}
	}
	byEnd := func(a, b entry) int { return cmp.Compare(a.end, b.end) }
	slices.SortStableFunc(connects, byEnd)
	slices.SortStableFunc(attempts, byEnd)
	slices.SortStableFunc(ops, byEnd)
	secs := func(t int64) string { return fmt.Sprintf("%.1f", float64(t-event)/1000) }
	var rows, problems []string
	row := func(what, value string) { rows = append(rows, fmt.Sprintf("| %s | %s |", what, value)) }

	// rw, as a whole and per address.
	states := rwTimeline(connects)
	down, back := spells(states, event, secs)
	row("rw took no connection", down)
	for _, a := range rwAddrs {
		var alone []entry
		for _, e := range connects {
			if e.addr == a {
				alone = append(alone, e)
			}
		}
		down, _ := spells(rwTimeline(alone), event, secs)
		row("rw on "+a+" alone took no connection", down)
	}

	// Reads and writes, and the attempt at rw of each pool that brought it
	// back.
	for _, pool := range pools {
		row(pool+"s work again", worksAgain(ops, pool, event, secs))
		if back >= 0 {
			since, until := recovery(states, back)
			if start, worked, ok := workedAttempt(attempts, pool, since, until); ok {
				row(pool+" pool's attempt at rw that worked", fmt.Sprintf("started at %s, worked at %s", secs(start), secs(worked)))
			} else {
				row(pool+" pool's attempt at rw that worked", "none")
			}
		}
	}

	// Each pool's attempt that worked in each recovery after the event:
	// within 1 s plus connect_timeout per rw address and one more. The
	// attempt running when rw came back may still wait on the address that
	// came back and those after it; the next waits on those before it and
	// connects to it.
	bound := time.Second + time.Duration(len(rwAddrs)+1)*connectTimeout
	for i, st := range states {
		if !st.up || i == 0 || st.at < event {
			continue
		}
		since, until := recovery(states, st.at)
		for _, pool := range pools {
			if _, worked, ok := workedAttempt(attempts, pool, since, until); ok && worked-st.at > bound.Milliseconds() {
				problems = append(problems, fmt.Sprintf("the attempt at rw of the %s pool worked only %.1f s after rw was back at %s, more than %.1f s",
					pool, float64(worked-st.at)/1000, secs(st.at), bound.Seconds()))
			}
		}
	}

	// Reads and writes on a read address.
	var lastRead *entry
	var wrong []string
	for i, e := range ops {
		if e.port() != readPort {
			continue
		}
		if back >= 0 && e.end > back && (lastRead == nil || e.end > lastRead.end) {
			lastRead = &ops[i]
		}
		// Only while rw took connections from the start to 0.25 s after the
		// end: one that was running when rw went down may land on read, and
		// the connects alone see rw down up to their interval later.
		s, seen := stateAt(states, e.start)
		if end, _ := stateAt(states, e.end+connectEvery.Milliseconds()); !seen || !s.up || end.at != s.at {
			continue
		}
		limit := s.at + 1000
		since, until := recovery(states, s.at)
		if _, worked, ok := workedAttempt(attempts, e.what, since, until); ok {
			limit = max(limit, worked+markedBack.Milliseconds())
		}
		if e.start > limit {
			wrong = append(wrong, fmt.Sprintf("%s on %s at %s, %.1f s after rw was back at %s, limit %.1f s",
				e.what, e.addr, secs(e.start), float64(e.start-s.at)/1000, secs(s.at), float64(limit-s.at)/1000))
		}
	}
	const lastOnRead = "last read or write on a read address once rw was back"
	switch {
	case back == -2:
		row(lastOnRead, "rw not back")
	case back < 0:
		row(lastOnRead, "rw was not down")
	case lastRead == nil:
		row(lastOnRead, "none")
	default:
		row(lastOnRead, fmt.Sprintf("%s, %.1f s after rw was back: %s on %s", secs(lastRead.end), float64(lastRead.end-back)/1000,
			lastRead.what, lastRead.addr))
	}
	row("reads and writes on a read address that rw should have taken", strconv.Itoa(len(wrong)))
	if len(wrong) > 0 {
		problems = append(problems, fmt.Sprintf("%d reads and writes on a read address that rw should have taken", len(wrong)))
	}

	// The end: the last read and write worked on rw.
	for _, pool := range pools {
		var last *entry
		for i := range ops {
			if ops[i].what == pool {
				last = &ops[i]
			}
		}
		if last == nil || !last.ok() || last.port() != rwPort {
			problems = append(problems, fmt.Sprintf("the last %s did not work on rw", pool))
		}
	}

	failures := failureLines(ops, secs)
	row("failed reads and writes", strconv.Itoa(len(slices.DeleteFunc(slices.Clone(ops), entry.ok))))

	lines := []string{"| pgfallback, seconds after the event | |", "|---|---|"}
	lines = append(lines, rows...)
	if len(wrong) > 0 {
		lines = append(lines, "", "Reads and writes on a read address that rw should have taken:", "")
		for _, l := range wrong {
			lines = append(lines, "- "+l)
		}
	}
	if len(failures) > 0 {
		lines = append(lines, "", "Failed reads and writes:", "")
		lines = append(lines, failures...)
	}
	report := strings.Join(lines, "\n") + "\n"
	if len(problems) > 0 {
		return report, fmt.Errorf("pgfallback did what it must not: %s", strings.Join(problems, "; "))
	}
	return report, nil
}

// worksAgain says when the reads or writes worked again after the event:
// "never failed", or the first failure that was still running at the event
// or started later, and the end of the first success after the last
// failure.
func worksAgain(ops []entry, what string, event int64, secs func(int64) string) string {
	var firstFail, lastFail int64 = -1, -1
	for _, e := range ops {
		if e.what == what && e.end >= event && !e.ok() {
			if firstFail < 0 || e.start < firstFail {
				firstFail = e.start
			}
			lastFail = max(lastFail, e.end)
		}
	}
	if firstFail < 0 {
		return "never failed"
	}
	for _, e := range ops {
		if e.what == what && e.ok() && e.start >= lastFail {
			return fmt.Sprintf("failed from %s, work again at %s", secs(max(firstFail, event)), secs(e.end))
		}
	}
	return fmt.Sprintf("failed from %s, not again", secs(max(firstFail, event)))
}

// failureLines lists every failed read and write, in the order they
// started. Consecutive failures of the reads or of the writes with the same
// address and error are one line.
func failureLines(ops []entry, secs func(int64) string) []string {
	byStart := slices.Clone(ops)
	slices.SortStableFunc(byStart, func(a, b entry) int { return cmp.Compare(a.start, b.start) })
	type group struct {
		first, last entry
		n           int
	}
	var groups []*group
	open := map[string]*group{}
	for _, e := range byStart {
		if e.ok() {
			delete(open, e.what)
			continue
		}
		if g := open[e.what]; g != nil && g.last.addr == e.addr && g.last.detail == e.detail {
			g.last = e
			g.n++
			continue
		}
		g := &group{first: e, last: e, n: 1}
		groups = append(groups, g)
		open[e.what] = g
	}
	lines := make([]string, 0, len(groups))
	for _, g := range groups {
		when := "started at " + secs(g.first.start)
		if g.n > 1 {
			when = fmt.Sprintf("%d times, started from %s to %s", g.n, secs(g.first.start), secs(g.last.start))
		}
		lines = append(lines, fmt.Sprintf("- %s on %s, %s: `` %s ``", g.first.what, g.first.addr, when, g.first.detail))
	}
	return lines
}
