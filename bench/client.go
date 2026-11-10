package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/testcontainers/testcontainers-go"
)

// The application host: the client image, outside k3s, with its own name
// and its own certificate from the company CA. The bench reads only its log.
const (
	clientIP   = "10.77.0.40"
	clientName = "orders-app.test"
)

// The client image the bench starts, set when the bench image is built.
var clientImage = os.Getenv("BENCH_CLIENT_IMAGE")

type client struct {
	c *testcontainers.DockerContainer
}

// startClient starts the client with a new EAB key. It returns once the
// client has read and, when it writes, written.
func startClient(ctx context.Context, nw *testcontainers.DockerNetwork, root *ca, key eab, writes bool) (*client, error) {
	if clientImage == "" {
		return nil, fmt.Errorf("BENCH_CLIENT_IMAGE is not set")
	}
	hosts := make([]string, nodeCount)
	for i := range nodeCount {
		hosts[i] = nodeHost(i)
	}
	c, err := start(ctx, testcontainers.ContainerRequest{
		Name:  "client",
		Image: clientImage,
		Cmd: []string{"-name", clientName, "-acme", acmeDirectory, "-ca", "/ca.crt",
			"-hosts", strings.Join(hosts, ","), "-writes=" + strconv.FormatBool(writes)},
		Env:   map[string]string{"EAB_KID": key.id, "EAB_HMAC": key.key},
		Files: []testcontainers.ContainerFile{file("/ca.crt", string(root.certPEM))},
	}, on(nw, clientIP, clientName))
	if err != nil {
		return nil, err
	}
	cl := &client{c: c}
	err = poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		log, err := cl.log(ctx)
		if err != nil {
			return err
		}
		if _, ok := log.first("read"); !ok {
			return fmt.Errorf("no read yet; the client's log ends: %s", log.tail)
		}
		if _, ok := log.first("write"); writes && !ok {
			return fmt.Errorf("no write yet; the client's log ends: %s", log.tail)
		}
		return nil
	})
	return cl, err
}

// stopWrites makes the client stop writing, and returns once every write it
// started has ended: no write is acknowledged after this.
func (cl *client) stopWrites(ctx context.Context) error {
	code, _, err := cl.c.Exec(ctx, []string{"kill", "-USR1", "1"})
	if err == nil && code != 0 {
		err = fmt.Errorf("kill -USR1 in the client: exit code %d", code)
	}
	if err != nil {
		return err
	}
	return poll(ctx, time.Now().Add(30*time.Second), func(ctx context.Context) error {
		log, err := cl.log(ctx)
		if err != nil {
			return err
		}
		if _, ok := log.writesStopped(); !ok {
			return errors.New("the client has not stopped writing yet")
		}
		return nil
	})
}

// stop stops the client; it ends the reads and writes it has started.
func (cl *client) stop(ctx context.Context) error {
	limit := 20 * time.Second
	return cl.c.Stop(ctx, &limit)
}

func (cl *client) rawLog(ctx context.Context) (string, error) {
	r, err := cl.c.Logs(ctx)
	if err != nil {
		return "", err
	}
	data, err := io.ReadAll(r)
	return string(data), closeWith(err, r)
}

func (cl *client) log(ctx context.Context) (clientLog, error) {
	raw, err := cl.rawLog(ctx)
	if err != nil {
		return clientLog{}, err
	}
	return parseLog(raw), nil
}

// One line of the client's log: "<start ms> <end ms> <what> <result> <detail>".
type logLine struct {
	start, end time.Time
	what       string // read, write or writes
	result     string // ok or fail for read and write, stopped for writes
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
	fields := strings.SplitN(text, " ", 5)
	if len(fields) < 4 {
		return logLine{}, false
	}
	start, err1 := strconv.ParseInt(fields[0], 10, 64)
	end, err2 := strconv.ParseInt(fields[1], 10, 64)
	if err1 != nil || err2 != nil {
		return logLine{}, false
	}
	line := logLine{start: time.UnixMilli(start), end: time.UnixMilli(end), what: fields[2], result: fields[3]}
	if len(fields) == 5 {
		line.detail = fields[4]
	}
	return line, true
}

// first is the end of the first ok line of what.
func (l clientLog) first(what string) (time.Time, bool) {
	for _, line := range l.lines {
		if line.what == what && line.result == "ok" {
			return line.end, true
		}
	}
	return time.Time{}, false
}

// writesStopped is when the client stopped writing, if it did.
func (l clientLog) writesStopped() (time.Time, bool) {
	for _, line := range l.lines {
		if line.what == "writes" && line.result == "stopped" {
			return line.start, true
		}
	}
	return time.Time{}, false
}

// longestGap is the longest time from from to to without an ok line of
// what, by the time each ended: the application got its answer then.
func (l clientLog) longestGap(what string, from, to time.Time) time.Duration {
	ends := []time.Time{from}
	for _, line := range l.lines {
		if line.what == what && line.result == "ok" && !line.end.Before(from) && !line.end.After(to) {
			ends = append(ends, line.end)
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
		if line.what == "write" && line.result == "ok" {
			n, _, _ := strings.Cut(line.detail, " ")
			ns = append(ns, n)
		}
	}
	return ns
}
