// Command pgfallback-live is the application of the pgfallback scenarios
// (live/pgfallback.sh): it uses github.com/djosh34/cnpg-evidence/pgfallback
// as an application outside the cluster would, and reports what it saw.
//
// Usage:
//
//	pgfallback-live run <certs dir> <node>=<ip>[,<node>=<ip>...]
//	pgfallback-live report <log> <event unix ms> <node>=<ip>[,<node>=<ip>...]
//
// run logs in with the client certificate that live/up.sh writes, as orders
// to the database orders, with sslmode=verify-full. The connection string
// lists the nodes by name on the rw port 5432, and pgfallback adds them on
// the read port 5433. pgx's LookupFunc maps the names to the IPs given, so
// the server certificate is checked against the node names. It runs a
// pgxpool.Pool and a GORM DB at the same time, each with a query every
// 0.25 s and a write every second, and connects to each rw address alone
// every 0.25 s, until it gets SIGTERM or SIGINT. It prints one line per
// attempt on stdout:
//
//	<start unix ms> <end unix ms> <client> <what> <address> ok|fail <detail>
//
// client is pgx, gorm, or rw for the connects alone; what is query, write or
// connect; address is the <node>:<port> that served it, or - when no
// connection was made. A query's detail is whether the server was in
// recovery and the last write of that client it saw, a write's is its n, a
// failure's is the error.
//
// report reads such a log and prints, in Markdown, what happened from the
// event on (see report.go). It exits 1 when the client did what pgfallback
// must not do.
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/djosh34/cnpg-evidence/pgfallback"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

const (
	rwPort   = 5432
	readPort = 5433
	// connect_timeout of the connection string, per address.
	connectTimeout = 2 * time.Second
	// The time one query, write or connect may take, connecting included.
	// After a lost primary node a new connection can wait connect_timeout on
	// each rw address and on the lost node's read address (docs/pgfallback.md).
	attemptTimeout = 10 * time.Second
	queryEvery     = 250 * time.Millisecond
	writeEvery     = time.Second
	connectEvery   = 250 * time.Millisecond
)

const createTable = `CREATE TABLE IF NOT EXISTS pgfallback_writes (
	client text NOT NULL,
	n bigint NOT NULL,
	PRIMARY KEY (client, n)
)`

var out = struct {
	sync.Mutex
	f *os.File
}{f: os.Stdout}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "pgfallback-live:", err)
		var check checkFailed
		if errors.As(err, &check) {
			os.Exit(1)
		}
		os.Exit(2)
	}
}

const usage = "usage: pgfallback-live run <certs dir> <node>=<ip>[,...] | report <log> <event unix ms> <node>=<ip>[,...]"

func run(args []string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	switch {
	case args[0] == "run" && len(args) == 3:
		nodes, err := parseNodes(args[2])
		if err != nil {
			return err
		}
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		return runClients(ctx, args[1], nodes)
	case args[0] == "report" && len(args) == 4:
		nodes, err := parseNodes(args[3])
		if err != nil {
			return err
		}
		event, err := strconv.ParseInt(args[2], 10, 64)
		if err != nil {
			return fmt.Errorf("event time %q: %w", args[2], err)
		}
		f, err := os.Open(args[1])
		if err != nil {
			return err
		}
		entries, err := parseLog(f)
		if err := errors.Join(err, f.Close()); err != nil {
			return fmt.Errorf("reading %s: %w", args[1], err)
		}
		return report(os.Stdout, entries, event, nodes)
	default:
		return errors.New(usage)
	}
}

type node struct {
	name string
	ip   netip.Addr
}

// parseNodes reads "<node>=<ip>[,<node>=<ip>...]", in the order of the
// connection string's hosts.
func parseNodes(s string) ([]node, error) {
	var nodes []node
	for item := range strings.SplitSeq(s, ",") {
		name, ip, found := strings.Cut(item, "=")
		addr, err := netip.ParseAddr(ip)
		if !found || name == "" || err != nil {
			return nil, fmt.Errorf("%q is not <node>=<ip>", item)
		}
		nodes = append(nodes, node{name: name, ip: addr})
	}
	return nodes, nil
}

func dsn(certs string, hosts []string) string {
	return fmt.Sprintf("host=%s port=%d user=orders dbname=orders sslmode=verify-full"+
		" sslrootcert=%s sslcert=%s sslkey=%s connect_timeout=%d",
		strings.Join(hosts, ","), rwPort,
		filepath.Join(certs, "ca.crt"), filepath.Join(certs, "tls.crt"), filepath.Join(certs, "tls.key"),
		int(connectTimeout.Seconds()))
}

type clients struct {
	nodes []node
	pool  *pgxpool.Pool
	gorm  *gorm.DB
	// One config per rw address, for the connects alone.
	alone []*pgx.ConnConfig
}

func runClients(ctx context.Context, certs string, nodes []node) (err error) {
	names := make([]string, len(nodes))
	reads := make([]string, len(nodes))
	ips := map[string]string{}
	for i, n := range nodes {
		names[i] = n.name
		reads[i] = net.JoinHostPort(n.name, strconv.Itoa(readPort))
		ips[n.name] = n.ip.String()
	}
	lookup := func(_ context.Context, host string) ([]string, error) {
		ip, ok := ips[host]
		if !ok {
			return nil, fmt.Errorf("no node %q", host)
		}
		return []string{ip}, nil
	}
	c := &clients{nodes: nodes}

	poolConfig, err := pgxpool.ParseConfig(dsn(certs, names))
	if err != nil {
		return err
	}
	poolConfig.ConnConfig.LookupFunc = lookup
	if err := pgfallback.Pool(poolConfig, reads...); err != nil {
		return err
	}
	c.pool, err = pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return err
	}
	defer c.pool.Close()

	// GORM on a *sql.DB from stdlib.OpenDB, as a DSN cannot carry a
	// LookupFunc.
	stdConfig, err := pgx.ParseConfig(dsn(certs, names))
	if err != nil {
		return err
	}
	stdConfig.LookupFunc = lookup
	opts, err := pgfallback.Stdlib(reads...)
	if err != nil {
		return err
	}
	db := stdlib.OpenDB(*stdConfig, opts...)
	defer func() {
		err = errors.Join(err, db.Close())
	}()
	c.gorm, err = gorm.Open(postgres.New(postgres.Config{Conn: db}), &gorm.Config{Logger: logger.Discard})
	if err != nil {
		return fmt.Errorf("opening GORM: %w", err)
	}

	for _, n := range nodes {
		cc, err := pgx.ParseConfig(dsn(certs, []string{n.name}))
		if err != nil {
			return err
		}
		cc.LookupFunc = lookup
		c.alone = append(c.alone, cc)
	}

	if err := c.ensureTable(ctx); err != nil {
		return fmt.Errorf("creating pgfallback_writes: %w", err)
	}

	var wg sync.WaitGroup
	wg.Go(func() { every(ctx, queryEvery, "pgx", "query", c.pgxQuery) })
	wg.Go(func() { every(ctx, writeEvery, "pgx", "write", c.pgxWrite) })
	wg.Go(func() { every(ctx, queryEvery, "gorm", "query", c.gormQuery) })
	wg.Go(func() { every(ctx, writeEvery, "gorm", "write", c.gormWrite) })
	for i := range nodes {
		wg.Go(func() {
			every(ctx, connectEvery, "rw", "connect", func(ctx context.Context) (string, string, error) {
				return c.connectAlone(ctx, i)
			})
		})
	}
	wg.Wait()
	return nil
}

func (c *clients) ensureTable(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, attemptTimeout)
	defer cancel()
	_, err := c.pool.Exec(ctx, createTable)
	return err
}

// every runs do every d until ctx ends, and logs each attempt. do returns
// the address that served the attempt, "" when none did, and the detail.
func every(ctx context.Context, d time.Duration, client, what string, do func(context.Context) (string, string, error)) {
	tick := time.NewTicker(d)
	defer tick.Stop()
	for {
		start := time.Now()
		attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
		addr, detail, err := do(attemptCtx)
		cancel()
		if ctx.Err() != nil {
			return // stopped: this attempt says nothing about the cluster
		}
		result := "ok"
		if err != nil {
			result, detail = "fail", oneLine(err)
		}
		if addr == "" {
			addr = "-"
		}
		logLine(start, time.Now(), client, what, addr, result, detail)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func logLine(start, end time.Time, client, what, addr, result, detail string) {
	out.Lock()
	defer out.Unlock()
	// A lost line would hide an acknowledged commit, so a failed write ends the run.
	if _, err := fmt.Fprintf(out.f, "%d %d %s %s %s %s %s\n",
		start.UnixMilli(), end.UnixMilli(), client, what, addr, result, detail); err != nil {
		fmt.Fprintln(os.Stderr, "pgfallback-live: writing stdout:", err)
		os.Exit(2)
	}
}

func oneLine(err error) string {
	return strings.Join(strings.Fields(err.Error()), " ")
}

// addrOf names the address a connection went to as <node>:<port>.
func (c *clients) addrOf(pgConn *pgconn.PgConn) string {
	remote := pgConn.Conn().RemoteAddr().String()
	ap, err := netip.ParseAddrPort(remote)
	if err != nil {
		return remote
	}
	for _, n := range c.nodes {
		if n.ip == ap.Addr().Unmap() {
			return net.JoinHostPort(n.name, strconv.Itoa(int(ap.Port())))
		}
	}
	return remote
}

func (c *clients) pgxQuery(ctx context.Context) (string, string, error) {
	conn, err := c.pool.Acquire(ctx)
	if err != nil {
		return "", "", err
	}
	defer conn.Release()
	addr := c.addrOf(conn.Conn().PgConn())
	var recovery bool
	var last int64
	err = conn.QueryRow(ctx,
		`SELECT pg_is_in_recovery(), (SELECT coalesce(max(n), 0) FROM pgfallback_writes WHERE client = 'pgx')`,
	).Scan(&recovery, &last)
	return addr, fmt.Sprintf("in_recovery=%t last=%d", recovery, last), err
}

func (c *clients) pgxWrite(ctx context.Context) (string, string, error) {
	conn, err := c.pool.Acquire(ctx)
	if err != nil {
		return "", "", err
	}
	defer conn.Release()
	addr := c.addrOf(conn.Conn().PgConn())
	n := time.Now().UnixMicro()
	_, err = conn.Exec(ctx, `INSERT INTO pgfallback_writes (client, n) VALUES ('pgx', $1)`, n)
	return addr, strconv.FormatInt(n, 10), err
}

// onGORM runs do on one GORM connection and returns that connection's
// address with do's detail.
func (c *clients) onGORM(ctx context.Context, do func(tx *gorm.DB) (string, error)) (string, string, error) {
	var addr, detail string
	err := c.gorm.WithContext(ctx).Connection(func(tx *gorm.DB) error {
		conn, ok := tx.Statement.ConnPool.(*sql.Conn)
		if !ok {
			return fmt.Errorf("the GORM connection is a %T, not a *sql.Conn", tx.Statement.ConnPool)
		}
		err := conn.Raw(func(driverConn any) error {
			std, ok := driverConn.(*stdlib.Conn)
			if !ok {
				return fmt.Errorf("the driver connection is a %T, not a *stdlib.Conn", driverConn)
			}
			addr = c.addrOf(std.Conn().PgConn())
			return nil
		})
		if err != nil {
			return err
		}
		detail, err = do(tx)
		return err
	})
	return addr, detail, err
}

func (c *clients) gormQuery(ctx context.Context) (string, string, error) {
	return c.onGORM(ctx, func(tx *gorm.DB) (string, error) {
		var r struct {
			Recovery bool
			Last     int64
		}
		err := tx.Raw(`SELECT pg_is_in_recovery() AS recovery,` +
			` (SELECT coalesce(max(n), 0) FROM pgfallback_writes WHERE client = 'gorm') AS last`).Scan(&r).Error
		return fmt.Sprintf("in_recovery=%t last=%d", r.Recovery, r.Last), err
	})
}

func (c *clients) gormWrite(ctx context.Context) (string, string, error) {
	return c.onGORM(ctx, func(tx *gorm.DB) (string, error) {
		n := time.Now().UnixMicro()
		err := tx.Exec(`INSERT INTO pgfallback_writes (client, n) VALUES ('gorm', ?)`, n).Error
		return strconv.FormatInt(n, 10), err
	})
}

// connectAlone connects to the rw address of node i alone and closes the
// connection at once.
func (c *clients) connectAlone(ctx context.Context, i int) (string, string, error) {
	addr := net.JoinHostPort(c.nodes[i].name, strconv.Itoa(rwPort))
	conn, err := pgx.ConnectConfig(ctx, c.alone[i])
	if err != nil {
		return addr, "", err
	}
	return addr, "connected", conn.Close(ctx)
}
