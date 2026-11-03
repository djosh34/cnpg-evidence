package main

import (
	"errors"
	"net/netip"
	"strings"
	"testing"
)

var testNodes = []node{
	{name: "k3s-1", ip: netip.MustParseAddr("10.77.0.11")},
	{name: "k3s-2", ip: netip.MustParseAddr("10.77.0.12")},
}

// A primary lost at 1000: rw is down from 1100 to 5000, the clients use a
// read address in between and go back to rw.
const lostPrimary = `900 950 rw connect k3s-1:5432 ok connected
900 960 rw connect k3s-2:5432 ok connected
950 990 pgx query k3s-1:5432 ok in_recovery=false last=1
1000 1100 rw connect k3s-1:5432 fail dial error: timeout
1000 1100 rw connect k3s-2:5432 fail dial error: refused
1050 1200 pgx write - fail write error
1300 1400 pgx write - fail write error
1500 1600 pgx write k3s-2:5433 fail ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006)
1500 1700 pgx query k3s-2:5433 ok in_recovery=true last=1
1500 1600 gorm query k3s-2:5433 ok in_recovery=true last=1
1500 1600 gorm write k3s-2:5433 fail ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006)
4900 5000 rw connect k3s-2:5432 ok connected
4900 4900 pgx rw-attempt - ok started
5100 5100 pgx rw-attempt k3s-2:5432 ok worked
5500 5600 pgx query k3s-2:5433 ok in_recovery=true last=1
7000 7100 pgx query k3s-2:5432 ok in_recovery=false last=1
7000 7200 pgx write k3s-2:5432 ok 2
7000 7100 gorm query k3s-2:5432 ok in_recovery=false last=1
7000 7200 gorm write k3s-2:5432 ok 2
`

func runReport(t *testing.T, log string) (string, error) {
	t.Helper()
	entries, err := parseLog(strings.NewReader(log))
	if err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	err = report(&b, entries, 1000, testNodes)
	return b.String(), err
}

func TestReportLostPrimary(t *testing.T) {
	out, err := runReport(t, lostPrimary)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	for _, want := range []string{
		"| rw took no connection | from 0.0 to 4.0 |",
		"| rw on k3s-1:5432 alone took no connection | from 0.0, not back |",
		"| rw on k3s-2:5432 alone took no connection | from 0.0 to 4.0 |",
		"| pgx write works again | failed from 0.1, works again at 6.2 |",
		"| pgx query works again | never failed |",
		"| last query or write on a read address once rw was back | 4.6, 0.6 s after rw was back: pgx query on k3s-2:5433 |",
		"| queries and writes on a read address that rw should have taken | 0 |",
		"| failed queries and writes | 4 |",
		"| pgx attempt at rw that worked | started at 3.9, worked at 4.1 |",
		"| gorm attempt at rw that worked | none |",
		"- pgx write on -, 2 times, started from 0.1 to 0.3: `` write error ``",
		"- pgx write on k3s-2:5433, started at 0.5: `` ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006) ``",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("no line %q in\n%s", want, out)
		}
	}
}

func TestReportNotBackOnRW(t *testing.T) {
	log := strings.Replace(lostPrimary, "7000 7200 gorm write k3s-2:5432 ok 2", "7000 7200 gorm write k3s-2:5433 ok 2", 1)
	_, err := runReport(t, log)
	var check checkFailed
	if !errors.As(err, &check) || !strings.Contains(err.Error(), "the last gorm write did not work on rw") {
		t.Fatalf("report did not fail for the last gorm write: %v", err)
	}
}

func TestParseLogRejectsBadLines(t *testing.T) {
	if _, err := parseLog(strings.NewReader("900 950 rw connect k3s-1:5432 maybe\n")); err == nil {
		t.Fatal("parseLog took a line without ok or fail")
	}
}

// A connect that waits for its timeout fails only at its end, but rw took
// no connection from its start: a read address may serve a query that
// started in between.
func TestReportConnectTimeout(t *testing.T) {
	log := `900 950 rw connect k3s-1:5432 ok connected
900 960 rw connect k3s-2:5432 ok connected
1000 3000 rw connect k3s-1:5432 fail timeout
1000 3000 rw connect k3s-2:5432 fail timeout
1500 7500 pgx query k3s-1:5433 ok in_recovery=true last=1
3000 3100 rw connect k3s-2:5432 ok connected
9000 9100 pgx query k3s-2:5432 ok in_recovery=false last=1
9000 9100 pgx write k3s-2:5432 ok 2
9000 9100 gorm query k3s-2:5432 ok in_recovery=false last=1
9000 9100 gorm write k3s-2:5432 ok 2
`
	out, err := runReport(t, log)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	if want := "| rw took no connection | from 0.0 to 2.1 |"; !strings.Contains(out, want) {
		t.Errorf("no line %q in\n%s", want, out)
	}
}

// A query that was running at the event and failed counts as a failure.
func TestReportFailureSpanningEvent(t *testing.T) {
	log := `900 950 rw connect k3s-1:5432 ok connected
990 1100 pgx query k3s-1:5432 fail unexpected EOF
1200 1300 pgx query k3s-1:5432 ok in_recovery=false last=1
9000 9100 pgx query k3s-1:5432 ok in_recovery=false last=1
9000 9100 pgx write k3s-1:5432 ok 2
9000 9100 gorm query k3s-1:5432 ok in_recovery=false last=1
9000 9100 gorm write k3s-1:5432 ok 2
`
	out, err := runReport(t, log)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	if want := "| pgx query works again | failed from 0.0, works again at 0.3 |"; !strings.Contains(out, want) {
		t.Errorf("no line %q in\n%s", want, out)
	}
}

func TestReportRWNotBack(t *testing.T) {
	log := `900 950 rw connect k3s-1:5432 ok connected
1000 1100 rw connect k3s-1:5432 fail refused
1200 1300 pgx query k3s-1:5433 ok in_recovery=true last=1
`
	out, err := runReport(t, log)
	var check checkFailed
	if !errors.As(err, &check) {
		t.Fatalf("report did not fail: %v\n%s", err, out)
	}
	if want := "| last query or write on a read address once rw was back | rw not back |"; !strings.Contains(out, want) {
		t.Errorf("no line %q in\n%s", want, out)
	}
}

// Without an attempt that worked, a read address may serve only for 1 s
// after rw was back.
func TestReportNoAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, `4900 4900 pgx rw-attempt - ok started
5100 5100 pgx rw-attempt k3s-2:5432 ok worked
`, "", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed for a read 0.5 s after rw was back: %v\n%s", err, out)
	}
	log = strings.Replace(log, "5500 5600 pgx query k3s-2:5433", "6050 6100 pgx query k3s-2:5433", 1)
	var check checkFailed
	if out, err := runReport(t, log); !errors.As(err, &check) {
		t.Fatalf("report did not fail for a read 1.05 s after rw was back: %v\n%s", err, out)
	}
}

// An attempt of a later outage does not count for an earlier recovery.
func TestReportTwoOutages(t *testing.T) {
	log := strings.Replace(lostPrimary, `4900 4900 pgx rw-attempt - ok started
5100 5100 pgx rw-attempt k3s-2:5432 ok worked
`, "", 1)
	log = strings.Replace(log, "5500 5600 pgx query k3s-2:5433", "6300 6350 pgx query k3s-2:5433", 1)
	log += `7500 7600 rw connect k3s-2:5432 fail refused
7700 7800 pgx query k3s-2:5433 ok in_recovery=true last=2
8000 8000 pgx rw-attempt - ok started
9500 9600 rw connect k3s-2:5432 ok connected
10100 10100 pgx rw-attempt k3s-2:5432 ok worked
11000 11100 pgx query k3s-2:5432 ok in_recovery=false last=2
11000 11100 pgx write k3s-2:5432 ok 3
11000 11100 gorm query k3s-2:5432 ok in_recovery=false last=2
11000 11100 gorm write k3s-2:5432 ok 3
`
	out, err := runReport(t, log)
	var check checkFailed
	if !errors.As(err, &check) {
		t.Fatalf("report did not fail for a read 1.3 s after the first recovery: %v\n%s", err, out)
	}
	if want := "- pgx query on k3s-2:5433 at 5.3, 1.3 s after rw was back at 4.0, limit 1.0 s"; !strings.Contains(out, want) {
		t.Errorf("no line %q in\n%s", want, out)
	}
}

// rw is back at 5000 and pgx's attempt worked at 5100: a read address may
// serve pgx until 1 s after rw was back.
func TestReportWrongRead(t *testing.T) {
	log := strings.Replace(lostPrimary, "5500 5600 pgx query k3s-2:5433", "6150 6200 pgx query k3s-2:5433", 1)
	out, err := runReport(t, log)
	var check checkFailed
	if !errors.As(err, &check) {
		t.Fatalf("report did not fail: %v\n%s", err, out)
	}
	if want := "- pgx query on k3s-2:5433 at 5.2, 1.1 s after rw was back at 4.0, limit 1.0 s"; !strings.Contains(out, want) {
		t.Errorf("no line %q in\n%s", want, out)
	}
	log = strings.Replace(lostPrimary, "5500 5600 pgx query k3s-2:5433", "5950 6000 pgx query k3s-2:5433", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
}

// pgx's attempt that was running when rw came back waited on addresses it
// dialed before, failed, and the next one worked at 6500: a read address
// may serve pgx until then.
func TestReportSlowAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, `4900 4900 pgx rw-attempt - ok started
5100 5100 pgx rw-attempt k3s-2:5432 ok worked`, `3500 3500 pgx rw-attempt - ok started
6400 6400 pgx rw-attempt - ok started
6500 6500 pgx rw-attempt k3s-2:5432 ok worked`, 1)
	log = strings.Replace(log, "5500 5600 pgx query k3s-2:5433", "6550 6600 pgx query k3s-2:5433", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	log = strings.Replace(log, "6550 6600 pgx query k3s-2:5433", "6650 6700 pgx query k3s-2:5433", 1)
	var check checkFailed
	if out, err := runReport(t, log); !errors.As(err, &check) {
		t.Fatalf("report did not fail for a read after the attempt worked: %v\n%s", err, out)
	}
}

// An attempt that works more than 1 s plus two attempts after rw was back
// fails the report. The test nodes are two: 1 s plus 8 s.
func TestReportLateAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, `4900 4900 pgx rw-attempt - ok started
5100 5100 pgx rw-attempt k3s-2:5432 ok worked`, `14000 14000 pgx rw-attempt - ok started
14100 14100 pgx rw-attempt k3s-2:5432 ok worked`, 1)
	log = strings.Replace(log, "7000 7100 pgx query k3s-2:5432", "15000 15100 pgx query k3s-2:5432", 1)
	log = strings.Replace(log, "5500 5600 pgx query k3s-2:5433", "13000 13100 pgx query k3s-2:5433", 1)
	out, err := runReport(t, log)
	if err == nil || !strings.Contains(err.Error(), "the attempt at rw of pgx worked only 9.1 s after rw was back, more than 9.0 s") {
		t.Fatalf("report did not fail for a late attempt: %v\n%s", err, out)
	}
}
