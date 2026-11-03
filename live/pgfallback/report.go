package main

import (
	"bufio"
	"cmp"
	"fmt"
	"io"
	"math"
	"net"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The report: everything in seconds after the event.
//
//   - rw took no connection while no rw address's last connect alone worked.
//     rw is back at the end of the first connect that worked after that.
//   - For pgx and GORM, reads and writes work again at the end of the first
//     query or write that worked after the last one that failed, counting
//     the failures that were still running at the event.
//   - The last query or write served by a read address after rw was back.
//   - A query or write is wrong when a read address served it although it
//     started more than 1 s after rw was back, while rw took connections
//     until it ended, and after pgfallback's own attempt at rw had worked:
//     the first attempt of that client that worked since rw went down and
//     before it went down again. Without one, 1 s alone. That attempt must
//     work within 1 s plus connect_timeout per rw address and one more after
//     rw was back: the attempt that was running then can still wait on
//     addresses it dialed before, and the next one connects. Every query and
//     write here is one statement, so none ran inside a transaction that was
//     already open.
//   - Every failed query and write with its error, consecutive ones with the
//     same address and error as one line.
//   - At the end, the last query and write of each client worked on rw.
//
// A wrong query or write, or a client that did not end on rw, makes the
// report fail.

type entry struct {
	start, end int64
	client     string // pgx, gorm or rw
	what       string // query, write or connect
	addr       string // <node>:<port> or -
	ok         bool
	detail     string
}

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

// checkFailed is the error of a report that found something pgfallback must
// not do.
type checkFailed struct{ problems []string }

func (c checkFailed) Error() string {
	return strings.Join(c.problems, "; ")
}

func parseLog(r io.Reader) ([]entry, error) {
	var entries []entry
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 64*1024), 1024*1024)
	for line := 1; s.Scan(); line++ {
		f := strings.SplitN(s.Text(), " ", 7)
		if len(f) < 6 || (f[5] != "ok" && f[5] != "fail") {
			return nil, fmt.Errorf("line %d is not <start> <end> <client> <what> <address> ok|fail <detail>: %q", line, s.Text())
		}
		start, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", line, err)
		}
		end, err := strconv.ParseInt(f[1], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", line, err)
		}
		e := entry{start: start, end: end, client: f[2], what: f[3], addr: f[4], ok: f[5] == "ok"}
		if len(f) == 7 {
			e.detail = f[6]
		}
		entries = append(entries, e)
	}
	return entries, s.Err()
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
		probes[i] = probe{at: known(e), addr: e.addr, ok: e.ok}
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

// known is when a connect alone tells its result, as rwTimeline counts it.
func known(e entry) int64 {
	if e.ok {
		return e.end
	}
	return e.start
}

// pgfallback marks rw back only after it closed the attempt's connection,
// which ends after the attempt's AfterConnect logged that it worked.
const markedBack = 100 * time.Millisecond

// workedAttempt is the first attempt at rw of client that worked from since
// to before until: when it started and when it worked, and false when there
// is none. pgfallback runs one attempt at a time per client, so the attempt
// that worked is the one that started last before.
func workedAttempt(attempts []entry, client string, since, until int64) (int64, int64, bool) {
	for _, e := range attempts {
		if e.client != client || e.detail != "worked" || e.end < since || e.end >= until {
			continue
		}
		start := e.end
		for _, a := range attempts {
			if a.client == client && a.detail == "started" && a.end <= e.end {
				start = a.end
			}
		}
		return start, e.end, true
	}
	return 0, 0, false
}

func report(w io.Writer, entries []entry, event int64, nodes []node) error {
	slices.SortStableFunc(entries, func(a, b entry) int { return cmp.Compare(a.end, b.end) })
	var connects, attempts, ops []entry
	for _, e := range entries {
		switch {
		case e.client == "rw":
			connects = append(connects, e)
		case e.what == "rw-attempt":
			attempts = append(attempts, e)
		default:
			ops = append(ops, e)
		}
	}
	rwAddrs := make([]string, len(nodes))
	for i, n := range nodes {
		rwAddrs[i] = net.JoinHostPort(n.name, strconv.Itoa(rwPort))
	}
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

	// Reads and writes of each client, and the attempt at rw that brought it
	// back.
	for _, client := range []string{"pgx", "gorm"} {
		for _, what := range []string{"query", "write"} {
			row(client+" "+what+" works again", worksAgain(ops, client, what, event, secs))
		}
		if back >= 0 {
			since, until := recovery(states, back)
			if start, worked, ok := workedAttempt(attempts, client, since, until); ok {
				row(client+" attempt at rw that worked", fmt.Sprintf("started at %s, worked at %s", secs(start), secs(worked)))
			} else {
				row(client+" attempt at rw that worked", "none")
			}
		}
	}

	// Each client's attempt that worked in each recovery after the event:
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
		for _, client := range []string{"pgx", "gorm"} {
			if _, worked, ok := workedAttempt(attempts, client, since, until); ok && worked-st.at > bound.Milliseconds() {
				problems = append(problems, fmt.Sprintf("the attempt at rw of %s worked only %.1f s after rw was back at %s, more than %.1f s",
					client, float64(worked-st.at)/1000, secs(st.at), bound.Seconds()))
			}
		}
	}

	// Queries and writes on a read address.
	var lastRead *entry
	var wrong []string
	for i, e := range ops {
		if e.port() != readPort {
			continue
		}
		if back >= 0 && e.end > back && (lastRead == nil || e.end > lastRead.end) {
			lastRead = &ops[i]
		}
		// Only while rw took connections from the start to the end: one
		// that was running when rw went down may land on read.
		s, known := stateAt(states, e.start)
		if end, _ := stateAt(states, e.end); !known || !s.up || end.at != s.at {
			continue
		}
		limit := s.at + 1000
		since, until := recovery(states, s.at)
		if _, worked, ok := workedAttempt(attempts, e.client, since, until); ok {
			limit = max(limit, worked+markedBack.Milliseconds())
		}
		if e.start > limit {
			wrong = append(wrong, fmt.Sprintf("%s %s on %s at %s, %.1f s after rw was back at %s, limit %.1f s",
				e.client, e.what, e.addr, secs(e.start), float64(e.start-s.at)/1000, secs(s.at), float64(limit-s.at)/1000))
		}
	}
	switch {
	case back == -2:
		row("last query or write on a read address once rw was back", "rw not back")
	case back < 0:
		row("last query or write on a read address once rw was back", "rw was not down")
	case lastRead == nil:
		row("last query or write on a read address once rw was back", "none")
	default:
		row("last query or write on a read address once rw was back",
			fmt.Sprintf("%s, %.1f s after rw was back: %s %s on %s", secs(lastRead.end), float64(lastRead.end-back)/1000,
				lastRead.client, lastRead.what, lastRead.addr))
	}
	row("queries and writes on a read address that rw should have taken", strconv.Itoa(len(wrong)))
	if len(wrong) > 0 {
		problems = append(problems, fmt.Sprintf("%d queries and writes on a read address that rw should have taken", len(wrong)))
	}

	// The end: each client's last query and write worked on rw.
	for _, client := range []string{"pgx", "gorm"} {
		for _, what := range []string{"query", "write"} {
			var last *entry
			for i := range ops {
				if ops[i].client == client && ops[i].what == what {
					last = &ops[i]
				}
			}
			if last == nil || !last.ok || last.port() != rwPort {
				problems = append(problems, fmt.Sprintf("the last %s %s did not work on rw", client, what))
			}
		}
	}

	failures := failureLines(ops, secs)
	row("failed queries and writes", strconv.Itoa(countFailed(ops)))

	lines := []string{"| pgfallback, seconds after the event | |", "|---|---|"}
	lines = append(lines, rows...)
	if len(wrong) > 0 {
		lines = append(lines, "", "Queries and writes on a read address that rw should have taken:", "")
		for _, l := range wrong {
			lines = append(lines, "- "+l)
		}
	}
	if len(failures) > 0 {
		lines = append(lines, "", "Failed queries and writes:", "")
		lines = append(lines, failures...)
	}
	for _, l := range lines {
		if _, err := fmt.Fprintln(w, l); err != nil {
			return err
		}
	}
	if len(problems) > 0 {
		return checkFailed{problems: problems}
	}
	return nil
}

// worksAgain says when the queries or writes of client worked again after
// the event: "never failed", or the first failure that was still running at
// the event or started later, and the end of the first success after the
// last failure.
func worksAgain(ops []entry, client, what string, event int64, secs func(int64) string) string {
	var firstFail, lastFail int64 = -1, -1
	for _, e := range ops {
		if e.client == client && e.what == what && e.end >= event && !e.ok {
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
		if e.client == client && e.what == what && e.ok && e.start >= lastFail {
			return fmt.Sprintf("failed from %s, works again at %s", secs(max(firstFail, event)), secs(e.end))
		}
	}
	return fmt.Sprintf("failed from %s, not again", secs(max(firstFail, event)))
}

func countFailed(ops []entry) int {
	n := 0
	for _, e := range ops {
		if !e.ok {
			n++
		}
	}
	return n
}

// failureLines lists every failed query and write, in the order they
// started. Consecutive failures of one client's queries or writes with the
// same address and error are one line.
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
		key := e.client + " " + e.what
		if e.ok {
			delete(open, key)
			continue
		}
		if g := open[key]; g != nil && g.last.addr == e.addr && g.last.detail == e.detail {
			g.last = e
			g.n++
			continue
		}
		g := &group{first: e, last: e, n: 1}
		groups = append(groups, g)
		open[key] = g
	}
	lines := make([]string, 0, len(groups))
	for _, g := range groups {
		when := "started at " + secs(g.first.start)
		if g.n > 1 {
			when = fmt.Sprintf("%d times, started from %s to %s", g.n, secs(g.first.start), secs(g.last.start))
		}
		lines = append(lines, fmt.Sprintf("- %s %s on %s, %s: `` %s ``", g.first.client, g.first.what, g.first.addr, when, g.first.detail))
	}
	return lines
}
