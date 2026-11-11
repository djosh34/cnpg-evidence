package main

import (
	"strings"
	"testing"
	"time"
)

var testRW = []string{"k3s-1:5432", "k3s-2:5432"}

// A primary lost at 1000: rw is down from 1100 to 5000, the client uses a
// read address in between and goes back to rw.
const lostPrimary = `900 950 connect k3s-1:5432 ok
900 960 connect k3s-2:5432 ok
950 990 read k3s-1:5432 ok 10.42.0.1 recovery=false
1000 1100 connect k3s-1:5432 fail dial error: timeout
1000 1100 connect k3s-2:5432 fail dial error: refused
1050 1200 write - fail write error
1300 1400 write - fail write error
1500 1600 write k3s-2:5433 fail ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006)
1500 1700 read k3s-2:5433 ok 10.42.0.2 recovery=true
4900 5000 connect k3s-2:5432 ok
4900 4900 read-attempt - started
5100 5100 read-attempt k3s-2:5432 worked
5500 5600 read k3s-2:5433 ok 10.42.0.2 recovery=true
7000 7100 read k3s-2:5432 ok 10.42.0.2 recovery=false
7000 7200 write k3s-2:5432 ok 2 10.42.0.2
`

func runReport(t *testing.T, log string) (string, error) {
	t.Helper()
	return fallbackReport(parseLog(log), time.UnixMilli(1000), testRW, []string{"read", "write"})
}

func wantLines(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("no line %q in\n%s", w, out)
		}
	}
}

func TestReportLostPrimary(t *testing.T) {
	out, err := runReport(t, lostPrimary)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	wantLines(t, out,
		"| rw took no connection | from 0.0 to 4.0 |",
		"| rw on k3s-1:5432 alone took no connection | from 0.0, not back |",
		"| rw on k3s-2:5432 alone took no connection | from 0.0 to 4.0 |",
		"| writes work again | failed from 0.1, work again at 6.2 |",
		"| reads work again | never failed |",
		"| last read or write on a read address once rw was back | 4.6, 0.6 s after rw was back: read on k3s-2:5433 |",
		"| reads and writes on a read address that rw should have taken | 0 |",
		"| failed reads and writes | 3 |",
		"| read pool's attempt at rw that worked | started at 3.9, worked at 4.1 |",
		"| write pool's attempt at rw that worked | none |",
		"- write on -, 2 times, started from 0.1 to 0.3: `` write error ``",
		"- write on k3s-2:5433, started at 0.5: `` ERROR: cannot execute INSERT in a read-only transaction (SQLSTATE 25006) ``",
	)
}

func TestReportNotBackOnRW(t *testing.T) {
	log := strings.Replace(lostPrimary, "7000 7200 write k3s-2:5432 ok", "7000 7200 write k3s-2:5433 ok", 1)
	if _, err := runReport(t, log); err == nil || !strings.Contains(err.Error(), "the last write did not work on rw") {
		t.Fatalf("report did not fail for the last write: %v", err)
	}
}

// A connect that waits for its timeout fails only at its end, but rw took
// no connection from its start: a read address may serve a read that
// started in between.
func TestReportConnectTimeout(t *testing.T) {
	log := `900 950 connect k3s-1:5432 ok
900 960 connect k3s-2:5432 ok
1000 3000 connect k3s-1:5432 fail timeout
1000 3000 connect k3s-2:5432 fail timeout
1500 7500 read k3s-1:5433 ok 10.42.0.1 recovery=true
3000 3100 connect k3s-2:5432 ok
9000 9100 read k3s-2:5432 ok 10.42.0.2 recovery=false
9000 9100 write k3s-2:5432 ok 2 10.42.0.2
`
	out, err := runReport(t, log)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	wantLines(t, out, "| rw took no connection | from 0.0 to 2.1 |")
}

// A read that was running at the event and failed counts as a failure.
func TestReportFailureSpanningEvent(t *testing.T) {
	log := `900 950 connect k3s-1:5432 ok
990 1100 read k3s-1:5432 fail unexpected EOF
1200 1300 read k3s-1:5432 ok 10.42.0.1 recovery=false
9000 9100 read k3s-1:5432 ok 10.42.0.1 recovery=false
9000 9100 write k3s-1:5432 ok 2 10.42.0.1
`
	out, err := runReport(t, log)
	if err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	wantLines(t, out, "| reads work again | failed from 0.0, work again at 0.3 |")
}

func TestReportRWNotBack(t *testing.T) {
	log := `900 950 connect k3s-1:5432 ok
1000 1100 connect k3s-1:5432 fail refused
1200 1300 read k3s-1:5433 ok 10.42.0.1 recovery=true
`
	out, err := runReport(t, log)
	if err == nil {
		t.Fatalf("report did not fail:\n%s", out)
	}
	wantLines(t, out, "| last read or write on a read address once rw was back | rw not back |")
}

// Without an attempt that worked, a read address may serve only for 1 s
// after rw was back.
func TestReportNoAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, "4900 4900 read-attempt - started\n5100 5100 read-attempt k3s-2:5432 worked\n", "", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed for a read 0.5 s after rw was back: %v\n%s", err, out)
	}
	log = strings.Replace(log, "5500 5600 read k3s-2:5433", "6050 6100 read k3s-2:5433", 1)
	if out, err := runReport(t, log); err == nil {
		t.Fatalf("report did not fail for a read 1.05 s after rw was back:\n%s", out)
	}
}

// An attempt of a later outage does not count for an earlier recovery.
func TestReportTwoOutages(t *testing.T) {
	log := strings.Replace(lostPrimary, "4900 4900 read-attempt - started\n5100 5100 read-attempt k3s-2:5432 worked\n", "", 1)
	log = strings.Replace(log, "5500 5600 read k3s-2:5433", "6300 6350 read k3s-2:5433", 1)
	log += `7500 7600 connect k3s-2:5432 fail refused
7700 7800 read k3s-2:5433 ok 10.42.0.2 recovery=true
8000 8000 read-attempt - started
9500 9600 connect k3s-2:5432 ok
10100 10100 read-attempt k3s-2:5432 worked
11000 11100 read k3s-2:5432 ok 10.42.0.2 recovery=false
11000 11100 write k3s-2:5432 ok 3 10.42.0.2
`
	out, err := runReport(t, log)
	if err == nil {
		t.Fatalf("report did not fail for a read 1.3 s after the first recovery:\n%s", out)
	}
	wantLines(t, out, "- read on k3s-2:5433 at 5.3, 1.3 s after rw was back at 4.0, limit 1.0 s")
}

// rw is back at 5000 and the read pool's attempt worked at 5100: a read
// address may serve reads until 1 s after rw was back.
func TestReportWrongRead(t *testing.T) {
	log := strings.Replace(lostPrimary, "5500 5600 read k3s-2:5433", "6150 6200 read k3s-2:5433", 1)
	out, err := runReport(t, log)
	if err == nil {
		t.Fatalf("report did not fail:\n%s", out)
	}
	wantLines(t, out, "- read on k3s-2:5433 at 5.2, 1.1 s after rw was back at 4.0, limit 1.0 s")
	log = strings.Replace(lostPrimary, "5500 5600 read k3s-2:5433", "5950 6000 read k3s-2:5433", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
}

// The read pool's attempt that was running when rw came back waited on
// addresses it dialed before, failed, and the next one worked at 6500: a
// read address may serve reads until then.
func TestReportSlowAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, "4900 4900 read-attempt - started\n5100 5100 read-attempt k3s-2:5432 worked",
		"3500 3500 read-attempt - started\n6400 6400 read-attempt - started\n6500 6500 read-attempt k3s-2:5432 worked", 1)
	log = strings.Replace(log, "5500 5600 read k3s-2:5433", "6550 6600 read k3s-2:5433", 1)
	if out, err := runReport(t, log); err != nil {
		t.Fatalf("report failed: %v\n%s", err, out)
	}
	log = strings.Replace(log, "6550 6600 read k3s-2:5433", "6650 6700 read k3s-2:5433", 1)
	if out, err := runReport(t, log); err == nil {
		t.Fatalf("report did not fail for a read after the attempt worked:\n%s", out)
	}
}

// An attempt that works more than 1 s plus connect_timeout per rw address
// and one more after rw was back fails the report, also when the client
// used no read address then. The test addresses are two: 1 s plus 6 s.
func TestReportLateAttempt(t *testing.T) {
	log := strings.Replace(lostPrimary, "4900 4900 read-attempt - started\n5100 5100 read-attempt k3s-2:5432 worked",
		"12000 12000 read-attempt - started\n12100 12100 read-attempt k3s-2:5432 worked", 1)
	log = strings.Replace(log, "5500 5600 read k3s-2:5433", "5500 5600 read k3s-2:5432", 1)
	out, err := runReport(t, log)
	if err == nil || !strings.Contains(err.Error(), "the attempt at rw of the read pool worked only 7.1 s after rw was back at 4.0, more than 7.0 s") {
		t.Fatalf("report did not fail for a late attempt: %v\n%s", err, out)
	}
}

// A read that started a moment before rw went down and landed on a read
// address is not wrong, although rw had been up for more than 1 s, also when
// it ended before the connects alone saw rw down.
func TestReportReadAsRWGoesDown(t *testing.T) {
	log := "0 50 connect k3s-1:5432 ok\n0 50 connect k3s-2:5432 ok\n" + lostPrimary
	log = strings.Replace(log, "1000 1100 connect k3s-1:5432 fail", "1100 1200 connect k3s-1:5432 fail", 1)
	log = strings.Replace(log, "1000 1100 connect k3s-2:5432 fail", "1100 1200 connect k3s-2:5432 fail", 1)
	for _, read := range []string{
		// Running when the connects alone saw rw down.
		"1095 1300 read k3s-2:5433 ok 10.42.0.2 recovery=true\n",
		// Over just before they did.
		"1060 1090 read k3s-2:5433 ok 10.42.0.2 recovery=true\n",
	} {
		if out, err := runReport(t, log+read); err != nil {
			t.Fatalf("report failed for %q: %v\n%s", read, err, out)
		}
	}
}
