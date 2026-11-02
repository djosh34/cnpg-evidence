// Command client is the database client of the live scenarios. It logs in
// with the client certificate that live/up.sh writes, as orders to the
// database orders, and prints one line per attempt on stdout:
//
//	<unix ms> <host> ok|fail <detail>
//
// Usage:
//
//	client write <certs dir> <host>[,<host>...]
//	client write-once <certs dir> <host>[,<host>...]
//	client read <certs dir> <host>[,<host>...]
//
// write keeps one pooled connection to port 5432 of the hosts, the rw
// LoadBalancer, and inserts one row every 0.25 s until it gets SIGTERM or
// SIGINT. An ok line is an acknowledged commit; its detail is the row's n and
// the address of the instance that took it. write-once inserts one row and
// exits 0 when it was acknowledged. read opens a new connection to port 5433
// of each host, the read LoadBalancer, once per second, and prints whether
// that node's instance answered and whether it is in recovery.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	writePort = 5432
	readPort  = 5433
	// The time one write or read may take, connecting included.
	attemptTimeout = 5 * time.Second
	writeEvery     = 250 * time.Millisecond
	readEvery      = time.Second
)

const createTable = `CREATE TABLE IF NOT EXISTS live_writes (
	n bigint PRIMARY KEY,
	at timestamptz NOT NULL DEFAULT now()
)`

const insertRow = `INSERT INTO live_writes (n) VALUES ($1) RETURNING host(inet_server_addr())`

var out = struct {
	sync.Mutex
	f *os.File
}{f: os.Stdout}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "client:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: client write|write-once|read <certs dir> <host>[,<host>...]")
	}
	mode, certs, hosts := args[0], args[1], strings.Split(args[2], ",")
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	switch mode {
	case "write":
		return write(ctx, certs, hosts)
	case "write-once":
		return writeOnce(ctx, certs, hosts)
	case "read":
		read(ctx, certs, hosts)
		return nil
	default:
		return fmt.Errorf("unknown mode %q", mode)
	}
}

// dsn lists the hosts in order: a new connection takes the first that answers.
func dsn(certs string, hosts []string, port int) string {
	return fmt.Sprintf("host=%s port=%d user=orders dbname=orders sslmode=verify-ca"+
		" sslrootcert=%s sslcert=%s sslkey=%s connect_timeout=2",
		strings.Join(hosts, ","), port,
		filepath.Join(certs, "ca.crt"), filepath.Join(certs, "tls.crt"), filepath.Join(certs, "tls.key"))
}

func logLine(host, result, detail string) {
	out.Lock()
	defer out.Unlock()
	// A lost line would hide an acknowledged commit, so a failed write ends the run.
	if _, err := fmt.Fprintf(out.f, "%d %s %s %s\n", time.Now().UnixMilli(), host, result, detail); err != nil {
		fmt.Fprintln(os.Stderr, "client: writing stdout:", err)
		os.Exit(1)
	}
}

func oneLine(err error) string {
	return strings.Join(strings.Fields(err.Error()), " ")
}

func newPool(ctx context.Context, certs string, hosts []string) (*pgxpool.Pool, error) {
	config, err := pgxpool.ParseConfig(dsn(certs, hosts, writePort))
	if err != nil {
		return nil, err
	}
	config.MaxConns = 1
	return pgxpool.NewWithConfig(ctx, config)
}

// insert writes one row with a new n and logs the attempt. It returns whether
// the commit was acknowledged.
func insert(ctx context.Context, pool *pgxpool.Pool) bool {
	ctx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()
	n := time.Now().UnixMicro()
	var server string
	err := pool.QueryRow(ctx, insertRow, n).Scan(&server)
	if err == nil {
		logLine("rw", "ok", fmt.Sprintf("%d %s", n, server))
		return true
	}
	if !errors.Is(ctx.Err(), context.Canceled) { // canceled: the client is stopping
		logLine("rw", "fail", oneLine(err))
	}
	return false
}

func ensureTable(ctx context.Context, pool *pgxpool.Pool) error {
	ctx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()
	_, err := pool.Exec(ctx, createTable)
	return err
}

func write(ctx context.Context, certs string, hosts []string) error {
	pool, err := newPool(ctx, certs, hosts)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ensureTable(ctx, pool); err != nil {
		return fmt.Errorf("creating live_writes: %w", err)
	}
	tick := time.NewTicker(writeEvery)
	defer tick.Stop()
	for {
		insert(ctx, pool)
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
		}
	}
}

func writeOnce(ctx context.Context, certs string, hosts []string) error {
	pool, err := newPool(ctx, certs, hosts)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ensureTable(ctx, pool); err != nil {
		return fmt.Errorf("creating live_writes: %w", err)
	}
	if !insert(ctx, pool) {
		return errors.New("the write was not acknowledged")
	}
	return nil
}

func read(ctx context.Context, certs string, hosts []string) {
	var wg sync.WaitGroup
	for _, host := range hosts {
		wg.Go(func() { readHost(ctx, certs, host) })
	}
	wg.Wait()
}

func readHost(ctx context.Context, certs, host string) {
	tick := time.NewTicker(readEvery)
	defer tick.Stop()
	for {
		recovery, err := readOnce(ctx, certs, host)
		if ctx.Err() != nil {
			return // stopped: this attempt says nothing about the node
		}
		if err != nil {
			logLine(host, "fail", oneLine(err))
		} else {
			logLine(host, "ok", fmt.Sprintf("in_recovery=%t", recovery))
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func readOnce(ctx context.Context, certs, host string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn(certs, []string{host}, readPort))
	if err != nil {
		return false, err
	}
	var recovery bool
	err = conn.QueryRow(ctx, "SELECT pg_is_in_recovery()").Scan(&recovery)
	return recovery, errors.Join(err, conn.Close(ctx))
}
