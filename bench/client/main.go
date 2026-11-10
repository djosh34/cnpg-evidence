// Command client is the application host of the bench. It gets its own
// certificate from the company CA by ACME, then reads and writes through
// pgfallback, as an application outside the cluster does, until it gets
// SIGTERM. It prints one line per read and write on stdout:
//
//	<start unix ms> <end unix ms> read|write ok|fail <detail>
//
// A read is a query every 0.25 s, a write an insert every 0.25 s. Each starts
// on time, also while earlier ones still wait, and may take 10 s. A read's
// detail is the address of the server and whether it is in recovery, a
// write's is its n and the address of the server, a failure's is the error.
//
// SIGUSR1 stops the writes, and the line "<ms> <ms> writes stopped" says when.
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
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/go-acme/lego/v4/certcrypto"
	"github.com/go-acme/lego/v4/certificate"
	"github.com/go-acme/lego/v4/challenge/http01"
	"github.com/go-acme/lego/v4/lego"
	"github.com/go-acme/lego/v4/registration"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/djosh34/cnpg-evidence/pgfallback"
)

const (
	rwPort   = "5432"
	readPort = "5433"
	// connect_timeout of the connection string, per address.
	connectTimeout = 2
	// The time one read or write may take, connecting included. A new
	// connection can wait connect_timeout on each rw address before it
	// tries a read address.
	attemptTimeout = 10 * time.Second
	every          = 250 * time.Millisecond
	// Where the certificate, its key and the CA go.
	certDir = "/tmp/certs"
)

const createTable = `CREATE TABLE IF NOT EXISTS bench_writes (
	n bigint PRIMARY KEY,
	at timestamptz NOT NULL DEFAULT now()
)`

const (
	insertRow = `INSERT INTO bench_writes (n) VALUES ($1) RETURNING host(inet_server_addr())`
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
	hosts := flag.String("hosts", "", "the database hosts, separated by commas")
	writes := flag.Bool("writes", true, "write every 0.25 s")
	flag.Parse()
	if *name == "" || *directory == "" || *caFile == "" || *hosts == "" || flag.NArg() != 0 {
		flag.Usage()
		return errors.New("-name, -acme, -ca and -hosts are needed")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := obtainCertificate(*name, *directory, *caFile); err != nil {
		return fmt.Errorf("certificate of %s: %w", *name, err)
	}
	pool, err := newPool(ctx, strings.Split(*hosts, ","))
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ensureTable(ctx, pool); err != nil {
		return err
	}

	stopWrites := make(chan os.Signal, 1)
	signal.Notify(stopWrites, syscall.SIGUSR1)
	var attempts sync.WaitGroup
	attempts.Go(func() { every250ms(ctx, nil, &attempts, func() { read(pool) }) })
	if *writes {
		attempts.Go(func() { every250ms(ctx, stopWrites, &attempts, func() { write(pool) }) })
	}
	attempts.Wait()
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

func newPool(ctx context.Context, hosts []string) (*pgxpool.Pool, error) {
	reads := make([]string, len(hosts))
	for i, host := range hosts {
		reads[i] = net.JoinHostPort(host, readPort)
	}
	dsn := fmt.Sprintf("host=%s port=%s user=orders dbname=orders sslmode=verify-full"+
		" sslrootcert=%s sslcert=%s sslkey=%s connect_timeout=%d",
		strings.Join(hosts, ","), rwPort,
		filepath.Join(certDir, "ca.crt"), filepath.Join(certDir, "tls.crt"), filepath.Join(certDir, "tls.key"),
		connectTimeout)
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	// Enough for every attempt of the last 10 s while connects wait.
	config.MaxConns = 20
	if err := pgfallback.Pool(config, reads...); err != nil {
		return nil, err
	}
	return pgxpool.NewWithConfig(ctx, config)
}

// ensureTable creates the table of the writes, trying once a second.
func ensureTable(ctx context.Context, pool *pgxpool.Pool) error {
	for {
		attempt, cancel := context.WithTimeout(ctx, attemptTimeout)
		_, err := pool.Exec(attempt, createTable)
		cancel()
		if err == nil {
			return nil
		}
		warn("client: creating bench_writes: %s", oneLine(err))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// every250ms starts attempt every 0.25 s, each in its own goroutine, until
// ctx ends or stop gets a signal. The attempts are not canceled: each ends
// within attemptTimeout and logs what it got.
func every250ms(ctx context.Context, stop <-chan os.Signal, attempts *sync.WaitGroup, attempt func()) {
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		attempts.Go(attempt)
		select {
		case <-ctx.Done():
			return
		case <-stop:
			now := time.Now()
			logLine(now, now, "writes", "stopped", "")
			return
		case <-tick.C:
		}
	}
}

func read(pool *pgxpool.Pool) {
	ctx, cancel := context.WithTimeout(context.Background(), attemptTimeout)
	defer cancel()
	start := time.Now()
	var server string
	var recovery bool
	err := pool.QueryRow(ctx, readRow).Scan(&server, &recovery)
	if err != nil {
		logLine(start, time.Now(), "read", "fail", oneLine(err))
		return
	}
	logLine(start, time.Now(), "read", "ok", fmt.Sprintf("%s recovery=%t", server, recovery))
}

func write(pool *pgxpool.Pool) {
	ctx, cancel := context.WithTimeout(context.Background(), attemptTimeout)
	defer cancel()
	start := time.Now()
	n := start.UnixMicro()
	var server string
	err := pool.QueryRow(ctx, insertRow, n).Scan(&server)
	if err != nil {
		logLine(start, time.Now(), "write", "fail", oneLine(err))
		return
	}
	logLine(start, time.Now(), "write", "ok", fmt.Sprintf("%d %s", n, server))
}

var out sync.Mutex

func logLine(start, end time.Time, what, result, detail string) {
	out.Lock()
	defer out.Unlock()
	// A lost line would hide an acknowledged write, so a failed print ends the client.
	if _, err := fmt.Printf("%d %d %s %s %s\n", start.UnixMilli(), end.UnixMilli(), what, result, detail); err != nil {
		warn("client: writing stdout: %v", err)
		os.Exit(1)
	}
}

func oneLine(err error) string {
	return strings.Join(strings.Fields(err.Error()), " ")
}
