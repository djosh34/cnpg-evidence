package main

import (
	"bufio"
	"cmp"
	"fmt"
	"io"
	"net"
	"slices"
	"strconv"
	"strings"
)

// The report: everything in seconds after the event.
//
//   - rw took no connection while no rw address's last connect alone worked.
//     rw is back at the end of the first connect that worked after that.
//   - For pgx and GORM, reads and writes work again at the end of the first
//     query or write that worked after the last one that failed.
//   - The last query or write served by a read address after rw was back.
//   - A query or write is wrong when a read address served it although it
//     started more than 1 s plus one attempt at rw after rw was back. One
//     attempt is what a connect to the rw hosts in order took then, from
//     each address's last connect alone: the failed ones before the first
//     that worked, and that one. Every query and write here is one statement,
//     so none ran inside a transaction that was already open.
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

// rwTimeline follows the connects alone in the order they ended: rw is up
// while the last connect of at least one address worked.
func rwTimeline(connects []entry) []rwState {
	last := map[string]bool{}
	var states []rwState
	for _, e := range connects {
		last[e.addr] = e.ok
		up := false
		for _, ok := range last {
			up = up || ok
		}
		if len(states) == 0 || states[len(states)-1].up != up {
			states = append(states, rwState{at: e.end, up: up})
		}
	}
	return states
}

// stateAt is the state at time t, and false when no connect ended by then.
func stateAt(states []rwState, t int64) (rwState, bool) {
	i, _ := slices.BinarySearchFunc(states, t+1, func(s rwState, t int64) int { return cmp.Compare(s.at, t) })
	if i == 0 {
		return rwState{}, false
	}
	return states[i-1], true
}

// attemptAt is how long a connect to the rw hosts in order took at time t,
// from each address's last connect alone that ended by then.
func attemptAt(connects []entry, rwAddrs []string, t int64) int64 {
	var total int64
	for _, a := range rwAddrs {
		var last *entry
		for i := range connects {
			if connects[i].addr == a && connects[i].end <= t {
				last = &connects[i]
			}
		}
		if last == nil {
			total += connectTimeout.Milliseconds()
			continue
		}
		total += last.end - last.start
		if last.ok {
			break
		}
	}
	return total
}

func report(w io.Writer, entries []entry, event int64, nodes []node) error {
	slices.SortStableFunc(entries, func(a, b entry) int { return cmp.Compare(a.end, b.end) })
	var connects, ops []entry
	for _, e := range entries {
		if e.client == "rw" {
			connects = append(connects, e)
		} else {
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

	// rw, as a whole and per address: each spell without rw that was not
	// over before the event, and when rw was last back.
	states := rwTimeline(connects)
	var downs []string
	back := int64(-1)
	for i, s := range states {
		if s.up {
			continue
		}
		if i+1 == len(states) {
			downs = append(downs, "from "+secs(s.at)+", not back")
			break
		}
		end := states[i+1].at
		if end >= event {
			downs = append(downs, "from "+secs(s.at)+" to "+secs(end))
			back = end
		}
	}
	if len(downs) == 0 {
		downs = []string{"never"}
	}
	row("rw took no connection", strings.Join(downs, ", "))
	for _, a := range rwAddrs {
		row("rw on "+a+" alone", downAndBack(connects, a, event, secs))
	}

	// Reads and writes of each client.
	for _, client := range []string{"pgx", "gorm"} {
		for _, what := range []string{"query", "write"} {
			row(client+" "+what+" works again", worksAgain(ops, client, what, event, secs))
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
		s, known := stateAt(states, e.start)
		if !known || !s.up {
			continue
		}
		if limit := s.at + 1000 + attemptAt(connects, rwAddrs, e.start); e.start > limit {
			wrong = append(wrong, fmt.Sprintf("%s %s on %s at %s, %.1f s after rw was back at %s, limit %.1f s",
				e.client, e.what, e.addr, secs(e.start), float64(e.start-s.at)/1000, secs(s.at), float64(limit-s.at)/1000))
		}
	}
	switch {
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

// downAndBack says when the connects alone to address a failed after the
// event: "never down", or the first failure and the first success after the
// last failure.
func downAndBack(connects []entry, a string, event int64, secs func(int64) string) string {
	var down, back int64 = -1, -1
	for _, e := range connects {
		if e.addr != a || e.start < event {
			continue
		}
		switch {
		case !e.ok:
			if down < 0 {
				down = e.start
			}
			back = -1
		case down >= 0 && back < 0:
			back = e.end
		}
	}
	switch {
	case down < 0:
		return "never down"
	case back < 0:
		return "down from " + secs(down) + ", not back"
	default:
		return "down from " + secs(down) + ", back at " + secs(back)
	}
}

// worksAgain says when the queries or writes of client worked again after
// the event: "never failed", or the first failure and the end of the first
// success after the last failure.
func worksAgain(ops []entry, client, what string, event int64, secs func(int64) string) string {
	var firstFail, lastFail int64 = -1, -1
	for _, e := range ops {
		if e.client == client && e.what == what && e.start >= event && !e.ok {
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
			return fmt.Sprintf("failed from %s, works again at %s", secs(firstFail), secs(e.end))
		}
	}
	return fmt.Sprintf("failed from %s, not again", secs(firstFail))
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
		when := "at " + secs(g.first.start)
		if g.n > 1 {
			when = fmt.Sprintf("%d times from %s to %s", g.n, secs(g.first.start), secs(g.last.start))
		}
		lines = append(lines, fmt.Sprintf("- %s %s on %s, %s: `` %s ``", g.first.client, g.first.what, g.first.addr, when, g.first.detail))
	}
	return lines
}
