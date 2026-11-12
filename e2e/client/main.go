// Command client is the application host of the e2e test. It gets its own
// certificate from the company CA by ACME, then reads and writes through
// pgfallback, as an application outside the cluster does, until it is
// killed. pgfallback is https://github.com/djosh34/pgfallback. It prints one
// line per event on stdout:
//
//	<start unix ms> <end unix ms> <what> <address> <result> <detail>
//
// address is the <host>:<port> the client connected to, or - when it has
// none. what is one of:
//
//   - read: a query every 0.25 s, through the read pool. ok or fail; the
//     detail is the server's own address and whether it is in recovery, or
//     the error.
//   - write: an insert every 0.25 s, through the write pool. ok or fail; the
//     detail is the insert's n and the server's own address, or the error.
//   - connect: a connect to the rw port of one host alone, every 0.25 s for
//     each host, which shows whether rw takes connections. ok or fail.
//   - read-attempt, write-attempt: an attempt of pgfallback at rw for that
//     pool. started when it starts, worked when it connected; a failed one
//     logs no end.
//   - writes: stopped, once the writes stopped.
//
// Each read, write and connect starts on time, also while earlier ones still
// wait, and may take 10 s.
//
// SIGUSR1 stops the writes. Once every write it started has ended, the line
// "<ms> <ms> writes - stopped" says when; no write is acknowledged after it.
//
// Usage:
//
//	client -name <name> -acme <directory URL> -ca <file> -hosts <host>[,<host>...] [-writes=false]
//
// The environment variables EAB_KID and EAB_HMAC hold the EAB key of the
// client's ACME account. The client logs in as orders to the database
// orders, with sslmode=verify-full against the rw port 5432 of each host;
// pgfallback adds the read port 5433 of each host.
package main

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/go-acme/lego/v4/certcrypto"
	"github.com/go-acme/lego/v4/certificate"
	"github.com/go-acme/lego/v4/challenge/http01"
	"github.com/go-acme/lego/v4/lego"
	"github.com/go-acme/lego/v4/registration"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/djosh34/pgfallback"
)

const (
	rwPort   = "5432"
	readPort = "5433"
	// connect_timeout of the connection string, per address.
	connectTimeout = 2
	// How long a TCP connect may take, within connect_timeout. A server on
	// the nodes' network answers in milliseconds; a lost node, or a lost
	// primary behind a node's rw port, never does. So a new connection
	// passes the three rw addresses in 1.5 s, not 6 s, before it tries a
	// read address.
	dialTimeout = 500 * time.Millisecond
	// The time one read or write may take, connecting included. A new
	// connection can wait connect_timeout on each rw address before it
	// tries a read address.
	attemptTimeout = 10 * time.Second
	every          = 250 * time.Millisecond
	// Where the certificate, its key and the CA go.
	certDir = "/tmp/certs"
)

const createTable = `CREATE TABLE IF NOT EXISTS e2e_writes (
	n bigint PRIMARY KEY,
	at timestamptz NOT NULL DEFAULT now()
)`

const (
	insertRow = `INSERT INTO e2e_writes (n) VALUES ($1) RETURNING host(inet_server_addr())`
	readRow   = `SELECT host(inet_server_addr()), pg_is_in_recovery()`
)

func main() {
	if err := run(); err != nil {
		warn("client: %v", err)
		os.Exit(1)
	}
}

// warn prints to stderr; a client that cannot print stops.
func warn(format string, args ...any) {
	if _, err := fmt.Fprintf(os.Stderr, format+"\n", args...); err != nil {
		os.Exit(1)
	}
}

func run() error {
	name := flag.String("name", "", "the client's host name, the certificate's only name")
	directory := flag.String("acme", "", "the ACME directory URL of the company CA")
	caFile := flag.String("ca", "", "the company CA, in PEM")
	hostList := flag.String("hosts", "", "the database hosts, separated by commas")
	writes := flag.Bool("writes", true, "write every 0.25 s")
	flag.Parse()
	if *name == "" || *directory == "" || *caFile == "" || *hostList == "" || flag.NArg() != 0 {
		flag.Usage()
		return errors.New("-name, -acme, -ca and -hosts are needed")
	}
	hosts := strings.Split(*hostList, ",")

	if err := obtainCertificate(*name, *directory, *caFile); err != nil {
		return fmt.Errorf("certificate of %s: %w", *name, err)
	}
	// Reads and writes each have their own pool, so writes that wait for a
	// standby to confirm their commit cannot take every connection from the
	// reads.
	readPool, err := newPool(app, hosts, "read")
	if err != nil {
		return err
	}
	defer readPool.Close()
	writePool, err := newPool(app, hosts, "write")
	if err != nil {
		return err
	}
	defer writePool.Close()
	var alone []*pgx.ConnConfig
	for _, host := range hosts {
		cc, err := connConfig([]string{host})
		if err != nil {
			return err
		}
		alone = append(alone, cc)
	}
	if err := ensureTable(app, writePool); err != nil {
		return err
	}

	stopWrites := make(chan os.Signal, 1)
	signal.Notify(stopWrites, syscall.SIGUSR1)
	var loops sync.WaitGroup
	loops.Go(func() { every250ms(nil, func() { read(readPool) }) })
	if *writes {
		loops.Go(func() {
			every250ms(stopWrites, func() { write(writePool) })
			now := time.Now()
			logLine(now, now, "writes", "-", "stopped", "")
		})
	}
	for _, cc := range alone {
		loops.Go(func() { every250ms(nil, func() { connectAlone(cc) }) })
	}
	loops.Wait()
	return nil
}

// obtainCertificate registers an ACME account with the EAB key and gets a
// certificate for name, answering the http-01 challenge on port 80. It
// writes tls.crt, tls.key and ca.crt into certDir.
func obtainCertificate(name, directory, caFile string) error {
	ca, err := os.ReadFile(caFile)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return fmt.Errorf("no certificate in %s", caFile)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	account := &user{key: key}
	config := lego.NewConfig(account)
	config.CADirURL = directory
	config.Certificate.KeyType = certcrypto.EC256
	config.HTTPClient = &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}},
	}
	client, err := lego.NewClient(config)
	if err != nil {
		return err
	}
	if err := client.Challenge.SetHTTP01Provider(http01.NewProviderServer("", "80")); err != nil {
		return err
	}
	account.registration, err = client.Registration.RegisterWithExternalAccountBinding(registration.RegisterEABOptions{
		TermsOfServiceAgreed: true,
		Kid:                  os.Getenv("EAB_KID"),
		HmacEncoded:          os.Getenv("EAB_HMAC"),
	})
	if err != nil {
		return fmt.Errorf("registering the ACME account: %w", err)
	}
	cert, err := client.Certificate.Obtain(certificate.ObtainRequest{Domains: []string{name}})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(certDir, 0o700); err != nil {
		return err
	}
	return errors.Join(
		os.WriteFile(filepath.Join(certDir, "tls.crt"), cert.Certificate, 0o600),
		os.WriteFile(filepath.Join(certDir, "tls.key"), cert.PrivateKey, 0o600),
		os.WriteFile(filepath.Join(certDir, "ca.crt"), ca, 0o600),
	)
}

// user is the ACME account.
type user struct {
	key          crypto.PrivateKey
	registration *registration.Resource
}

func (u *user) GetEmail() string                        { return "" }
func (u *user) GetRegistration() *registration.Resource { return u.registration }
func (u *user) GetPrivateKey() crypto.PrivateKey        { return u.key }

// dsn is the connection to the rw port of the hosts, logging in as orders
// with the certificate.
func dsn(hosts []string) string {
	return fmt.Sprintf("host=%s port=%s user=orders dbname=orders sslmode=verify-full"+
		" sslrootcert=%s sslcert=%s sslkey=%s connect_timeout=%d",
		strings.Join(hosts, ","), rwPort,
		filepath.Join(certDir, "ca.crt"), filepath.Join(certDir, "tls.crt"), filepath.Join(certDir, "tls.key"),
		connectTimeout)
}

// connConfig is the connection to the rw port of the hosts. Each TCP
// connect may take dialTimeout.
func connConfig(hosts []string) (*pgx.ConnConfig, error) {
	cc, err := pgx.ParseConfig(dsn(hosts))
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: dialTimeout}
	cc.DialFunc = dialer.DialContext
	cc.LookupFunc = lookup
	return cc, nil
}

// newPool is a pool through pgfallback: the rw port of the hosts, then
// their read port. It logs the attempts of pgfallback at rw as
// <pool>-attempt.
func newPool(ctx context.Context, hosts []string, pool string) (*pgxpool.Pool, error) {
	config, err := pgxpool.ParseConfig(dsn(hosts))
	if err != nil {
		return nil, err
	}
	if config.ConnConfig, err = connConfig(hosts); err != nil {
		return nil, err
	}
	// Enough for every attempt of the last 10 s, 0.25 s apart, while connects
	// or commits wait.
	config.MaxConns = 40
	// pgx looks up the first rw host first, so a lookup of it outside the
	// client's own contexts is the start of an attempt.
	config.ConnConfig.LookupFunc = func(ctx context.Context, host string) ([]string, error) {
		if host == hosts[0] && !own(ctx) {
			now := time.Now()
			logLine(now, now, pool+"-attempt", "-", "started", "")
		}
		return lookup(ctx, host)
	}
	config.ConnConfig.AfterConnect = func(ctx context.Context, pgConn *pgconn.PgConn) error {
		if !own(ctx) {
			now := time.Now()
			logLine(now, now, pool+"-attempt", address(pgConn), "worked", "")
		}
		return nil
	}
	reads := make([]string, len(hosts))
	for i, host := range hosts {
		reads[i] = net.JoinHostPort(host, readPort)
	}
	if err := pgfallback.Pool(config, reads...); err != nil {
		return nil, err
	}
	return pgxpool.NewWithConfig(ctx, config)
}

// app marks the client's own contexts. pgfallback's attempts at rw run
// without it, so the lookups and connects without it are theirs.
type appKey struct{}

var app = context.WithValue(context.Background(), appKey{}, true)

func own(ctx context.Context) bool { return ctx.Value(appKey{}) != nil }

// hostOf names each IP a lookup gave by its host, so that a connection's
// remote address reads as the <host>:<port> it was for.
var hostOf = struct {
	sync.Mutex
	ip map[string]string
}{ip: map[string]string{}}

func lookup(ctx context.Context, host string) ([]string, error) {
	addrs, err := net.DefaultResolver.LookupHost(ctx, host)
	hostOf.Lock()
	defer hostOf.Unlock()
	for _, a := range addrs {
		hostOf.ip[a] = host
	}
	return addrs, err
}

func address(pgConn *pgconn.PgConn) string {
	remote := pgConn.Conn().RemoteAddr().String()
	ap, err := netip.ParseAddrPort(remote)
	if err != nil {
		return remote
	}
	hostOf.Lock()
	defer hostOf.Unlock()
	host, ok := hostOf.ip[ap.Addr().Unmap().String()]
	if !ok {
		return remote
	}
	return net.JoinHostPort(host, strconv.Itoa(int(ap.Port())))
}

// ensureTable creates the table of the writes, trying once a second.
func ensureTable(ctx context.Context, pool *pgxpool.Pool) error {
	for {
		try, cancel := context.WithTimeout(ctx, attemptTimeout)
		_, err := pool.Exec(try, createTable)
		cancel()
		if err == nil {
			return nil
		}
		warn("client: creating e2e_writes: %s", oneLine(err))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// every250ms starts attempt every 0.25 s, each in its own goroutine, until
// stop gets a signal, and returns once every attempt it started has ended.
// A nil stop never does. The attempts are not canceled: each ends within
// attemptTimeout and logs what it got.
func every250ms(stop <-chan os.Signal, attempt func()) {
	var attempts sync.WaitGroup
	defer attempts.Wait()
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		attempts.Go(attempt)
		select {
		case <-stop:
			return
		case <-tick.C:
		}
	}
}

func read(pool *pgxpool.Pool) {
	run := func(ctx context.Context, conn *pgxpool.Conn) (string, error) {
		var server string
		var recovery bool
		err := conn.QueryRow(ctx, readRow).Scan(&server, &recovery)
		return fmt.Sprintf("%s recovery=%t", server, recovery), err
	}
	attempt(pool, "read", run)
}

func write(pool *pgxpool.Pool) {
	n := time.Now().UnixMicro()
	run := func(ctx context.Context, conn *pgxpool.Conn) (string, error) {
		var server string
		err := conn.QueryRow(ctx, insertRow, n).Scan(&server)
		return fmt.Sprintf("%d %s", n, server), err
	}
	attempt(pool, "write", run)
}

// attempt runs one read or write on a connection of the pool and logs it
// with the address of that connection.
func attempt(pool *pgxpool.Pool, what string, run func(context.Context, *pgxpool.Conn) (string, error)) {
	ctx, cancel := context.WithTimeout(app, attemptTimeout)
	defer cancel()
	start := time.Now()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		logLine(start, time.Now(), what, "-", "fail", oneLine(err))
		return
	}
	defer conn.Release()
	addr := address(conn.Conn().PgConn())
	detail, err := run(ctx, conn)
	if err != nil {
		logLine(start, time.Now(), what, addr, "fail", oneLine(err))
		return
	}
	logLine(start, time.Now(), what, addr, "ok", detail)
}

// connectAlone connects to the rw port of one host and closes the
// connection at once.
func connectAlone(cc *pgx.ConnConfig) {
	ctx, cancel := context.WithTimeout(app, attemptTimeout)
	defer cancel()
	start := time.Now()
	addr := net.JoinHostPort(cc.Host, rwPort)
	conn, err := pgx.ConnectConfig(ctx, cc.Copy())
	if err == nil {
		err = conn.Close(ctx)
	}
	if err != nil {
		logLine(start, time.Now(), "connect", addr, "fail", oneLine(err))
		return
	}
	logLine(start, time.Now(), "connect", addr, "ok", "")
}

var out sync.Mutex

func logLine(start, end time.Time, what, address, result, detail string) {
	out.Lock()
	defer out.Unlock()
	// A lost line would hide an acknowledged write, so a failed print ends the client.
	if _, err := fmt.Printf("%d %d %s %s %s %s\n", start.UnixMilli(), end.UnixMilli(), what, address, result, detail); err != nil {
		warn("client: writing stdout: %v", err)
		os.Exit(1)
	}
}

func oneLine(err error) string {
	return strings.Join(strings.Fields(err.Error()), " ")
}
