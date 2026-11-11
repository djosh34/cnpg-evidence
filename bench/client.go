package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The application host: the client image, outside k3s, with its own name
// and its own certificate from the company CA. The bench reads only its log.
const (
	clientIP   = "10.77.0.40"
	clientName = "orders-app.test"
)

// The client image the bench starts, set when the bench image is built.
var clientImage = os.Getenv("BENCH_CLIENT_IMAGE")

// startClient starts the client with a new EAB key. It returns once the
// client has read and, when it writes, written.
func (w *world) startClient(ctx context.Context, writes bool) error {
	if clientImage == "" {
		return errors.New("BENCH_CLIENT_IMAGE is not set")
	}
	key, err := w.bao.newEAB(ctx)
	if err != nil {
		return err
	}
	hosts := make([]string, nodeCount)
	for i := range nodeCount {
		hosts[i] = nodeHost(i)
	}
	err = container{
		name: "client", ip: clientIP, image: clientImage,
		opts: []string{"--env", "EAB_KID=" + key.id, "--env", "EAB_HMAC=" + key.key},
		args: []string{"-name", clientName, "-acme", acmeDirectory, "-ca", "/ca.crt",
			"-hosts", strings.Join(hosts, ","), "-writes=" + strconv.FormatBool(writes)},
		files: map[string]string{"/ca.crt": string(w.root.certPEM)},
	}.run(ctx)
	if err != nil {
		return err
	}
	return poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		log, err := readClientLog(ctx)
		if err != nil {
			return err
		}
		if _, ok := log.first("read"); !ok {
			return fmt.Errorf("no read yet; the client's log ends: %s", log.tail)
		}
		if _, ok := log.first("write"); writes && !ok {
			return fmt.Errorf("no write yet; the client's log ends: %s", log.tail)
		}
		for _, host := range hosts {
			if !log.connected(net.JoinHostPort(host, "5432")) {
				return fmt.Errorf("no connect to %s:5432 alone yet; the client's log ends: %s", host, log.tail)
			}
		}
		return nil
	})
}

// stopWrites makes the client stop writing, and returns once every write it
// started has ended: no write is acknowledged after this.
func stopWrites(ctx context.Context) error {
	if _, err := command(ctx, "docker", "exec", "client", "kill", "-USR1", "1"); err != nil {
		return err
	}
	return poll(ctx, time.Now().Add(30*time.Second), func(ctx context.Context) error {
		log, err := readClientLog(ctx)
		if err != nil {
			return err
		}
		if _, ok := log.writesStopped(); !ok {
			return errors.New("the client has not stopped writing yet")
		}
		return nil
	})
}

// rawClientLog is what the client printed, on stdout and stderr.
func rawClientLog(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "docker", "logs", "client").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("docker logs client: %w: %s", err, out)
	}
	return string(out), nil
}

func readClientLog(ctx context.Context) (clientLog, error) {
	raw, err := rawClientLog(ctx)
	if err != nil {
		return clientLog{}, err
	}
	return parseLog(raw), nil
}

// One line of the client's log: "<start ms> <end ms> <what> <address>
// <result> <detail>", as bench/client/main.go describes it.
type logLine struct {
	start, end int64  // unix ms
	what       string // read, write, connect, read-attempt, write-attempt or writes
	address    string // the <host>:<port> the client connected to, or -
	result     string // ok or fail; started or worked for an attempt; stopped for writes
	detail     string
}

type clientLog struct {
	lines []logLine
	tail  string // the last lines that are not read and write lines, such as errors
}

func parseLog(raw string) clientLog {
	var log clientLog
	var other []string
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for scanner.Scan() {
		line, ok := parseLine(scanner.Text())
		if !ok {
			other = append(other, scanner.Text())
			continue
		}
		log.lines = append(log.lines, line)
	}
	log.tail = strings.Join(other[max(0, len(other)-5):], " | ")
	return log
}

func parseLine(text string) (logLine, bool) {
	fields := strings.SplitN(text, " ", 6)
	if len(fields) < 5 {
		return logLine{}, false
	}
	start, err1 := strconv.ParseInt(fields[0], 10, 64)
	end, err2 := strconv.ParseInt(fields[1], 10, 64)
	if err1 != nil || err2 != nil {
		return logLine{}, false
	}
	line := logLine{start: start, end: end, what: fields[2], address: fields[3], result: fields[4]}
	if len(fields) == 6 {
		line.detail = fields[5]
	}
	return line, true
}

// first is the end of the first ok line of what.
func (l clientLog) first(what string) (time.Time, bool) {
	for _, line := range l.lines {
		if line.what == what && line.ok() {
			return time.UnixMilli(line.end), true
		}
	}
	return time.Time{}, false
}

// connected: a connect to address alone worked.
func (l clientLog) connected(address string) bool {
	for _, line := range l.lines {
		if line.what == "connect" && line.address == address && line.ok() {
			return true
		}
	}
	return false
}

// writesStopped is when the client stopped writing, if it did.
func (l clientLog) writesStopped() (time.Time, bool) {
	for _, line := range l.lines {
		if line.what == "writes" && line.result == "stopped" {
			return time.UnixMilli(line.start), true
		}
	}
	return time.Time{}, false
}

// longestGap is the longest time from from to to without an ok line of
// what, by the time each ended: the application got its answer then.
func (l clientLog) longestGap(what string, from, to time.Time) time.Duration {
	ends := []time.Time{from}
	for _, line := range l.lines {
		end := time.UnixMilli(line.end)
		if line.what == what && line.ok() && !end.Before(from) && !end.After(to) {
			ends = append(ends, end)
		}
	}
	// Attempts run side by side, so their lines need not come in order.
	slices.SortFunc(ends, time.Time.Compare)
	ends = append(ends, to)
	var gap time.Duration
	for i := 1; i < len(ends); i++ {
		gap = max(gap, ends[i].Sub(ends[i-1]))
	}
	return gap
}

// acknowledged are the n of every acknowledged write.
func (l clientLog) acknowledged() []string {
	var ns []string
	for _, line := range l.lines {
		if line.what == "write" && line.ok() {
			n, _ := line.write()
			ns = append(ns, n)
		}
	}
	return ns
}

func (line logLine) ok() bool { return line.result == "ok" }

// startedBefore: the line started before t. A line's times are whole ms, t
// need not be.
func (line logLine) startedBefore(t time.Time) bool { return time.UnixMilli(line.start).Before(t) }

// port is the port of the address the client connected to, or 0.
func (line logLine) port() int {
	_, port, err := net.SplitHostPort(line.address)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(port)
	if err != nil {
		return 0
	}
	return n
}

// write is the n of an acknowledged write and the server's own address.
func (line logLine) write() (n, server string) {
	n, server, _ = strings.Cut(line.detail, " ")
	return n, server
}
