// Package pgfallback lets a pgx or GORM application use the read addresses
// of a database only while none of its rw addresses takes a connection, and
// go back to rw as soon as one does.
//
// The application keeps its own connection string with the rw hosts. Pool
// adds the read addresses to a pgxpool.Config, Stdlib to database/sql and
// GORM through stdlib.OpenDB options:
//
//	cfg, err := pgxpool.ParseConfig(dsn)
//	...
//	err = pgfallback.Pool(cfg, "vm1:5433", "vm2:5433", "vm3:5433")
//
// For each new connection pgx tries the rw hosts first, as it always does,
// and then the read addresses in the order given. A connection that landed on
// a read address is a read connection. While read connections are in use, the
// package tries a full connect to the rw hosts in the background, at most once
// a second. Once one works, read connections are closed when they are handed
// out or released, so new connections go to rw again. Nothing asks the server
// for its role.
//
// The config must use TLS on every host, set connect_timeout, and leave
// target_session_attrs at any.
package pgfallback

import (
	"context"
	"database/sql/driver"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
)

// The CustomData key that marks a connection on a read address.
const readKey = "github.com/djosh34/cnpg-evidence/pgfallback.read"

// The least time between the starts of two attempts at rw.
const attemptEvery = time.Second

// Pool adds the read addresses, each "host:port", to cfg. It keeps every
// hook cfg already has (BeforeConnect, AfterConnect, PrepareConn,
// BeforeAcquire, AfterRelease, and the AfterConnect of its ConnConfig) and
// calls it too.
func Pool(cfg *pgxpool.Config, read ...string) error {
	reads, err := parseReads(read)
	if err != nil {
		return err
	}
	if err := checkConfig(cfg.ConnConfig); err != nil {
		return err
	}

	beforeConnect := cfg.BeforeConnect
	f := &fallback{reads: reads, rw: cfg.ConnConfig.Copy(), beforeConnect: beforeConnect}

	cfg.BeforeConnect = func(ctx context.Context, cc *pgx.ConnConfig) error {
		if beforeConnect != nil {
			if err := beforeConnect(ctx, cc); err != nil {
				return err
			}
		}
		return f.addReads(cc)
	}

	// pgxpool ignores BeforeAcquire once PrepareConn is set.
	prepare := cfg.PrepareConn
	if prepare == nil && cfg.BeforeAcquire != nil {
		beforeAcquire := cfg.BeforeAcquire
		prepare = func(ctx context.Context, conn *pgx.Conn) (bool, error) {
			return beforeAcquire(ctx, conn), nil
		}
	}
	cfg.PrepareConn = func(ctx context.Context, conn *pgx.Conn) (bool, error) {
		if !f.use(conn.PgConn()) {
			return false, nil
		}
		if prepare != nil {
			return prepare(ctx, conn)
		}
		return true, nil
	}

	afterRelease := cfg.AfterRelease
	cfg.AfterRelease = func(conn *pgx.Conn) bool {
		keep := f.use(conn.PgConn())
		if afterRelease != nil {
			return afterRelease(conn) && keep
		}
		return keep
	}
	return nil
}

// Stdlib returns the stdlib.OpenDB options that add the read addresses, each
// "host:port", for database/sql, or for GORM through
// postgres.Config.OptionOpenDB. They set OptionBeforeConnect and
// OptionResetSession. The config is checked when a connection is opened.
func Stdlib(read ...string) ([]stdlib.OptionOpenDB, error) {
	reads, err := parseReads(read)
	if err != nil {
		return nil, err
	}
	f := &fallback{reads: reads}
	return []stdlib.OptionOpenDB{
		stdlib.OptionBeforeConnect(func(_ context.Context, cc *pgx.ConnConfig) error {
			f.setRW(cc.Copy())
			return f.addReads(cc)
		}),
		stdlib.OptionResetSession(func(_ context.Context, conn *pgx.Conn) error {
			if !f.use(conn.PgConn()) {
				return driver.ErrBadConn
			}
			return nil
		}),
	}, nil
}

// NoPrimary reports whether err is or wraps a PostgreSQL error with SQLSTATE
// 25006, read_only_sql_transaction, which a write gets on a standby.
func NoPrimary(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "25006"
}

type readAddr struct {
	host string
	port uint16
}

func parseReads(read []string) ([]readAddr, error) {
	if len(read) == 0 {
		return nil, errors.New("pgfallback: no read addresses")
	}
	reads := make([]readAddr, 0, len(read))
	for _, a := range read {
		host, port, err := net.SplitHostPort(a)
		if err != nil {
			return nil, fmt.Errorf("pgfallback: read address %q is not host:port: %w", a, err)
		}
		n, err := strconv.ParseUint(port, 10, 16)
		if err != nil {
			return nil, fmt.Errorf("pgfallback: read address %q is not host:port: %w", a, err)
		}
		if host == "" || n == 0 {
			return nil, fmt.Errorf("pgfallback: read address %q is not host:port", a)
		}
		reads = append(reads, readAddr{host: host, port: uint16(n)})
	}
	return reads, nil
}

func checkConfig(cc *pgx.ConnConfig) error {
	if cc.TLSConfig == nil || slices.ContainsFunc(cc.Fallbacks, func(fb *pgconn.FallbackConfig) bool { return fb.TLSConfig == nil }) {
		return errors.New("pgfallback: the config must use TLS on every host: sslmode require, verify-ca or verify-full")
	}
	if cc.ConnectTimeout <= 0 {
		return errors.New("pgfallback: the config must set connect_timeout")
	}
	if cc.ValidateConnect != nil {
		return errors.New("pgfallback: the config must leave target_session_attrs at any")
	}
	return nil
}

type fallback struct {
	reads []readAddr
	// The application's BeforeConnect, for the attempts at rw of Pool.
	beforeConnect func(context.Context, *pgx.ConnConfig) error

	mu sync.Mutex
	// The application's config, without the read addresses.
	rw *pgx.ConnConfig
	// An attempt at rw worked, and no connection landed on read since.
	back       bool
	attempting bool
	lastStart  time.Time
}

func (f *fallback) setRW(cc *pgx.ConnConfig) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rw = cc
}

// addReads puts the read addresses after the rw hosts of cc, the copy pgx is
// about to connect with. The read names are resolved by pgx itself, through
// cc's LookupFunc, so the IP:port pairs of a connection's own resolution tell
// whether it landed on read. It checks cc again, since the application's
// BeforeConnect may have changed it.
func (f *fallback) addReads(cc *pgx.ConnConfig) error {
	if err := checkConfig(cc); err != nil {
		return err
	}
	ports := map[string][]uint16{}
	fallbacks := slices.Clone(cc.Fallbacks)
	for _, r := range f.reads {
		ports[r.host] = append(ports[r.host], r.port)
		tlsConfig := cc.TLSConfig.Clone()
		tlsConfig.ServerName = r.host
		fallbacks = append(fallbacks, &pgconn.FallbackConfig{Host: r.host, Port: r.port, TLSConfig: tlsConfig})
	}
	cc.Fallbacks = fallbacks

	pairs := map[netip.AddrPort]bool{}
	lookup := cc.LookupFunc
	if lookup == nil {
		lookup = net.DefaultResolver.LookupHost
	}
	cc.LookupFunc = func(ctx context.Context, host string) ([]string, error) {
		addrs, err := lookup(ctx, host)
		if err != nil {
			return nil, err
		}
		for _, port := range ports[host] {
			for _, a := range addrs {
				if ap, ok := addrPort(a, port); ok {
					pairs[ap] = true
				}
			}
		}
		return addrs, nil
	}

	afterConnect := cc.AfterConnect
	cc.AfterConnect = func(ctx context.Context, pgConn *pgconn.PgConn) error {
		if afterConnect != nil {
			if err := afterConnect(ctx, pgConn); err != nil {
				return err
			}
		}
		remote, err := netip.ParseAddrPort(pgConn.Conn().RemoteAddr().String())
		if err == nil && pairs[unmap(remote)] {
			pgConn.CustomData()[readKey] = true
			f.landedOnRead()
		}
		return nil
	}
	return nil
}

// addrPort turns one result of a LookupFunc, an IP or an IP:port, into the
// pair pgx dials.
func addrPort(a string, port uint16) (netip.AddrPort, bool) {
	if ap, err := netip.ParseAddrPort(a); err == nil {
		return unmap(ap), true
	}
	ip, err := netip.ParseAddr(a)
	if err != nil {
		return netip.AddrPort{}, false
	}
	return unmap(netip.AddrPortFrom(ip, port)), true
}

func unmap(ap netip.AddrPort) netip.AddrPort {
	return netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port())
}

// landedOnRead clears the "rw is back" state: rw did not take this new
// connection, so read connections must stay in use.
func (f *fallback) landedOnRead() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.back = false
	f.startAttempt()
}

// use reports whether a connection that is handed out or released may stay
// in use. A read connection may until an attempt at rw worked; until then it
// starts the next attempt.
func (f *fallback) use(pgConn *pgconn.PgConn) bool {
	if _, read := pgConn.CustomData()[readKey]; !read {
		return true
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.back {
		return false
	}
	f.startAttempt()
	return true
}

// startAttempt starts one attempt at rw unless one runs or the last one
// started less than a second ago. f.mu must be held.
func (f *fallback) startAttempt() {
	if f.rw == nil || f.attempting || time.Since(f.lastStart) < attemptEvery {
		return
	}
	f.attempting = true
	f.lastStart = time.Now()
	cc := f.rw.Copy()
	go f.attempt(cc)
}

// attempt connects to rw with the application's config and closes the
// connection at once. pgx ends each try within connect_timeout per rw
// address. A failed connect or close only means rw is not back.
func (f *fallback) attempt(cc *pgx.ConnConfig) {
	ctx := context.Background()
	err := f.connect(ctx, cc)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.attempting = false
	if err == nil {
		f.back = true
	}
}

func (f *fallback) connect(ctx context.Context, cc *pgx.ConnConfig) error {
	if f.beforeConnect != nil {
		if err := f.beforeConnect(ctx, cc); err != nil {
			return err
		}
	}
	conn, err := pgx.ConnectConfig(ctx, cc)
	if err != nil {
		return err
	}
	return conn.Close(ctx)
}
