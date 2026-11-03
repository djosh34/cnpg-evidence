# pgfallback

`pgfallback` is a Go package for pgx and GORM applications outside the cluster that connect through the nodes' addresses. Such an application lists every node on the rw port 5432 as usual. The package adds the read port of every node, and uses those read addresses only while no rw address takes a new connection. As soon as one does again, it goes back to rw.

Every rw address reaches the primary: each node forwards 5432 to it (see [LoadBalancers](samples.md#loadbalancers)). The read port of a node reaches the instance on that node, primary or replica.

The `pgfallback-*` scenarios of [live.md](live.md#pgfallback-from-outside-the-cluster) run it this way, with pgxpool and GORM, against a three-node cluster during a drain of the primary's node and the loss of a primary's or a replica's node.

## Get it

```bash
go get github.com/djosh34/cnpg-evidence/pgfallback@<tag>
```

`<tag>` is a release tag of this repository, such as `v0.4.0`; the module is the repository root, `github.com/djosh34/cnpg-evidence`. It needs Go 1.25 or later. `go get` adds pgx v5; the package does not import GORM.

## What it does

- **For each new connection,** pgx tries the rw hosts of the application's own connection string in order, as it always does, and then the read addresses in the order given. The first address that lets the connection in serves it. That is all the package decides on: nothing asks the server for its role. So the read port of the primary's node reaches the primary, and writes work there.
- **A connection that landed on a read address is a read connection.** While read connections are in use, the package tries a full connect to the rw hosts in the background, at most once a second and one at a time, with the application's config, and closes that connection at once. Each attempt ends within `connect_timeout` per rw address. A failed attempt only means rw is not back yet; the application never sees it.
- **Once an attempt works, read connections are closed instead of used again,** and the new connections that replace them go to rw:
  - With pgxpool, a read connection is closed when it is handed out or released. A query or transaction that runs on it finishes first.
  - With database/sql and GORM, a read connection is closed the next time it is handed out. database/sql has no hook when a connection is released.
  - An idle read connection that is not handed out again stays open until the pool's own limits close it: `MaxConnIdleTime` in pgxpool, 30 minutes by default, and `SetConnMaxIdleTime` in database/sql, no limit by default. It serves nothing in that time.
  - From about 2 s after an rw address takes connections again, no query is served by a read address, as long as the rw addresses that are still down refuse. When the first rw address does not answer at all, add `connect_timeout`.
  - After an idle spell of more than 2 s with no attempt, a read connection that is handed out is closed too, so the first query after it tries rw first.
- **A new connection that lands on a read address again,** because rw went away again, keeps read connections in use. One that tried the rw hosts before the attempt that worked started does not: while rw addresses do not answer, it can land on a read address many seconds after it tried them. pgxpool closes it before it serves anything; database/sql and GORM let it serve the query that opened it and close it the next time it is handed out.

It does not:

- check whether a server is a primary or a replica;
- retry a query, a write or a transaction, or change any error;
- send reads to the read port while rw works: then every query goes to the primary;
- remember a node that is down or reorder the hosts.

## Connection string

```
host=node1.example.com,node2.example.com,node3.example.com port=5432 dbname=orders user=orders
sslmode=verify-full sslrootcert=ca.crt sslcert=orders-app.crt sslkey=orders-app.key connect_timeout=2
```

- **TLS on every host is required,** with `sslmode` `require`, `verify-ca` or `verify-full`. Use `verify-full`: it checks that the server certificate names the host that was dialled. Each read address is checked under its own host name.
- **`verify-full` needs the node names in `replication.dnsNames`** in `desired.yaml`, since the server certificate names only those (see [Install](samples.md#install)). The certificate has no IP addresses, so list the nodes by name.
- **`connect_timeout` is required.** Use `connect_timeout=2` (see [A node that is down](#a-node-that-is-down)).
- **`target_session_attrs` must be unset or `any`.** Any other value makes pgx check each server's role, which turns away a replica on a read address or prefers one to rw.

`Pool` returns an error at once for a config that breaks one of these rules. The options from `Stdlib` see the config only when a connection is opened, so the error comes from the first connect: `db.PingContext`, or `gorm.Open`, which pings by default.

## Set up

Each example lists the three nodes on the read port 5433 of the example `desired.yaml`. `TestDocExamples` in `pgfallback/` checks that each block below is in `pgfallback/example_test.go`, where it compiles.

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

`pgfallback.Pool` keeps every hook the config already has (`BeforeConnect`, `AfterConnect`, `PrepareConn`, `BeforeAcquire`, `AfterRelease`, and the `AfterConnect` of its `ConnConfig`) and calls it too. A change to the config after the call reaches neither.

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

`pgfallback.Stdlib` returns two options, `stdlib.OptionBeforeConnect` and `stdlib.OptionResetSession`. pgx applies the options in order, and the later option of each kind wins. So an application's own `OptionBeforeConnect` or `OptionResetSession` and the package's replace each other: whichever comes later is the only one that runs. Pass neither kind next to them. The package does not use `stdlib.OptionAfterConnect`, which GORM sets when its DSN has a time zone.

## Errors while there is no primary

The package passes every error to the application as it is.

- **On a replica, a write fails with SQLSTATE 25006** (`read_only_sql_transaction`): `INSERT`, `UPDATE`, `DELETE`, `SELECT ... FOR UPDATE` and the like. `pgfallback.NoPrimary(err)` is true for an error that is or wraps a PostgreSQL error with that SQLSTATE. It checks the SQLSTATE and nothing else, so it does not prove that there is no primary: the read port of the primary's node reaches the primary and writes work there, and a read-only transaction on the primary gets 25006 too.
- **A pgx transaction begun with `pgx.TxOptions{AccessMode: pgx.ReadWrite}`** sends `BEGIN READ WRITE`, which a replica refuses at `BEGIN` with SQLSTATE 0A000 (`cannot set transaction read-write mode during recovery`). `NoPrimary` is false for it. database/sql and GORM never send `READ WRITE`.
- **Queries and transactions that ran on the primary** get connection errors when the primary goes away. Whether a commit that was under way when its connection broke went through is not known to the application.
- **The package retries nothing.** An application that wants to retry does it itself, a whole transaction at a time.

## How far behind a fallback read can be

There is no bound in any case. Each commit waits until one replica has applied it (`synchronous_commit: remote_apply` with one confirming copy, see [Writes, reads and failover](samples.md#writes-reads-and-failover)). The replica that applied the most has every commit the application got back. The other replica can be behind by any number of commits, and a fallback connection lands on the first read address that lets it in, which can be that one.

- **Switchover,** for a drain, a rollout or by hand, and a restart of the primary in place: the old primary stops only once every connected replica has all its WAL on disk, but not once it has applied it. So both replicas hold every commit. The one that did not confirm can be behind in applying them, so for a moment a fallback read there can miss a commit the application already got back. In a switchover, writes stop for about 11 s while the primary moves.
- **A lost primary node:** nothing drains. The replica that did not confirm may never have received the last commits, and shows them only once it streams from the new primary. CNPG promotes a replica about a minute after the loss. Until then, and until the other replica has caught up with the new primary, reads on that other replica can miss commits the application got back. When no replica can be promoted, as with [one node left](samples.md#one-node-left), that lasts until the other nodes return.
- **A replica that comes back** after its node was down can open the read port before it has caught up (see [Writes, reads and failover](samples.md#writes-reads-and-failover)).
- **A query on a replica** can hold back how far that replica applies, up to `max_standby_streaming_delay`, PostgreSQL's default of 30 s.

PostgreSQL 18 has no way to make a read on a replica wait for a given commit. An application that must see its own last commit has that only on the primary.

## A node that is down

A stopped node does not refuse a connection, so pgx waits `connect_timeout` on each of its addresses before it moves on. Pools reuse connections, so only new connections pay this. A node whose instance is not ready refuses the read port at once, and so costs nothing.

- **A node listed first that is down** adds `connect_timeout` to each new connection: 2 s with `connect_timeout=2`. Listed after an address that answers, it costs nothing.
- **After a lost primary node,** every rw address times out until Kubernetes marks the lost pod not ready, 47 to 67 s after the loss in tests: the remaining nodes still forward 5432 to it. In that time a new connection waits `connect_timeout` on each of the three rw addresses before it tries the read addresses, and once more when the lost node's read address comes first: 6 to 8 s with `connect_timeout=2`. A read connection handed out after an idle spell of more than 2 s is replaced by such a new connection, so in that window the first query after each pause pays this again. A context deadline on a query that opens a new connection must allow for that.
- **The attempts at rw** run in the background and wait the same `connect_timeout` per rw address. They cost the application nothing, but the switch back to rw takes that much longer when the first rw address does not answer.
