# pgfallback

`pgfallback` is a Go package for pgx and GORM applications outside the cluster. The application lists every node on the rw port 5432 as usual. The package adds every node's read port and uses those addresses only while no rw address takes a new connection. Once one does again, it goes back to rw. Each node forwards 5432 to the primary and its read port to its own instance ([LoadBalancers](samples.md#loadbalancers)).

The client of every scenario reads and writes through it, and the `pgfallback-*` scenarios check it during a drain and a lost node ([the pgfallback report](e2e.md#the-pgfallback-report)).

```bash
go get github.com/djosh34/cnpg-evidence/pgfallback@<tag>
```

`<tag>` is a release of this repository. It needs Go 1.25 and adds pgx v5; it does not import GORM.

## What it does

- **A new connection** tries the rw hosts in order, then the read addresses. The first that lets it in serves it. Nothing asks the server for its role, so the read port of the primary's node reaches the primary and writes work there.
- **A connection on a read address is a read connection.** While any are in use, the package tries a full connect to rw in the background, at most once a second, and closes it at once. A failed attempt only means rw is not back.
- **Once an attempt works,** read connections are closed instead of reused. pgxpool closes one when it is handed out or released, after the running query ends. database/sql and GORM close one the next time it is handed out. An idle one stays open, unused, until the pool's idle limit.
- About 2 s after rw takes connections again, no query goes to a read address, as long as the down rw addresses refuse. When they do not answer at all, add `connect_timeout` per rw address and one more.
- After an idle spell of over 2 s with no attempt, a read connection that is handed out is closed, so the next query tries rw first.

It does not check a server's role, retry anything, change any error, send reads to the read port while rw works, or reorder the hosts.

## Connection string

```
host=node1.example.com,node2.example.com,node3.example.com port=5432 dbname=orders user=orders
sslmode=verify-full sslrootcert=ca.crt sslcert=orders-app.crt sslkey=orders-app.key connect_timeout=2
```

- TLS on every host: `sslmode` `require`, `verify-ca` or `verify-full`. Use `verify-full`, with the node names in `replication.dnsNames` of `desired.yaml`; the certificate has no IP addresses.
- `connect_timeout` is required; use 2.
- `target_session_attrs` unset or `any`. Any other value makes pgx check each server's role.

`Pool` refuses a config that breaks one of these. With `Stdlib`, the error comes from the first connect: `db.PingContext`, or `gorm.Open`.

## Set up

Each example uses the read port 5433 of the example `desired.yaml`. `TestDocExamples` checks that each block is in `pgfallback/example_test.go`, where it compiles.

### pgx

```go
// connectPool opens a pgxpool.Pool that falls back to the read port.
func connectPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	// Set the pool's own hooks and limits on cfg before this call.
	err = pgfallback.Pool(cfg, "node1.example.com:5433", "node2.example.com:5433", "node3.example.com:5433")
	if err != nil {
		return nil, err
	}
	return pgxpool.NewWithConfig(ctx, cfg)
}
```

`Pool` keeps the config's hooks and calls them too. A change to the config after the call reaches neither.

### database/sql

```go
// connectDB opens a *sql.DB that falls back to the read port.
func connectDB(dsn string) (*sql.DB, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	opts, err := pgfallback.Stdlib("node1.example.com:5433", "node2.example.com:5433", "node3.example.com:5433")
	if err != nil {
		return nil, err
	}
	return stdlib.OpenDB(*cfg, opts...), nil
}
```

### GORM

```go
// connectGORM opens a *gorm.DB that falls back to the read port.
func connectGORM(dsn string) (*gorm.DB, error) {
	opts, err := pgfallback.Stdlib("node1.example.com:5433", "node2.example.com:5433", "node3.example.com:5433")
	if err != nil {
		return nil, err
	}
	return gorm.Open(postgres.New(postgres.Config{DSN: dsn, OptionOpenDB: opts}), &gorm.Config{})
}
```

`Stdlib` returns `stdlib.OptionBeforeConnect` and `stdlib.OptionResetSession`. The later option of each kind wins, so pass no option of your own of those two kinds.

### A short dial timeout

A lost node never answers a TCP connect, so each new connection waits `connect_timeout` per address that is down. A dialer with a shorter timeout passes them quickly; set it before `pgfallback.Pool`, which copies the config for its attempts:

```go
cfg.ConnConfig.DialFunc = (&net.Dialer{Timeout: 500 * time.Millisecond}).DialContext
```

After a lost primary node, every rw address times out until Kubernetes marks the lost pod not ready, 47 to 67 s in tests. A new connection then reaches a read address after 1.5 to 2 s with this dialer, instead of 6 to 8 s with `connect_timeout=2` alone. The scenarios' client uses 500 ms. Pick a value above the network's normal connect time.

## Errors while there is no primary

The package passes every error on as it is.

- A write on a replica fails with SQLSTATE 25006. `pgfallback.NoPrimary(err)` is true for it. It checks only the SQLSTATE, so a read-only transaction on the primary gives true too.
- A pgx transaction with `AccessMode: pgx.ReadWrite` fails on a replica at `BEGIN` with SQLSTATE 0A000; `NoPrimary` is false for it.
- Whether a commit under way when its connection broke went through is not known.
- Retries are the application's, a whole transaction at a time.

## How far behind a fallback read can be

There is no bound. Each commit waits until one replica has applied it; the other can be any number of commits behind, and a fallback connection can land on it.

- **Switchover, drain or rollout:** the old primary stops only once every replica has its WAL on disk, but one may still be applying it.
- **A lost primary node:** the replica that did not confirm may lack the last commits until it streams from the new primary, about a minute later. With [one node left](samples.md#writes-reads-and-failover), until the other nodes return.
- **A replica that comes back** can serve reads before it has caught up.
- **A query on a replica** can hold back its replay by up to `max_standby_streaming_delay`, 30 s.

An application that must read its own last commit has that only on the primary.
