# Set when the cluster is created

CNPG takes these only when it creates a cluster. Getting them wrong later means a new cluster and moving the data again.

## The import from the old cluster

**Problem.** The new cluster takes its data from the old one with `bootstrap.initdb.import`: a `pg_dump` of each database at the moment the new cluster is created. Four things go wrong without an error:
- Writes that reach the old cluster after the dump started are not in the new one.
- `initdb.database` and `owner` (as in the `microservice` examples) make CNPG create an extra empty database and role with those names, and a `<cluster>-app` Secret with its password.
- The dump lies in the new primary's PGDATA during the import, next to the restored data and indexes. A disk sized for the data alone fills.
- Each imported role keeps its password hash from the old cluster, so a password that works there works on the new cluster too.

**What changes.** The new cluster holds the old databases and roles with the same names and owners, nothing else, and no role has a password it should not have.

**How.** In the `Cluster`, a `monolith` import with no `database`, `owner` or `secret` under `initdb`:

```yaml
spec:
  bootstrap:
    initdb:
      walSegmentSize: 1
      import:
        type: monolith
        databases: [<database>, ...]
        roles: [<role>, ...]          # every role the databases need
        source:
          externalCluster: old
  externalClusters:
    - name: old
      connectionParameters:
        host: <old primary>
        user: postgres                # needs to run pg_dump and read the roles
        dbname: postgres
        sslmode: verify-full
      password:
        name: <secret with the old cluster's password>
        key: password
  managed:
    roles:
      - name: <role>                  # every imported role that logs in with a certificate
        ensure: present
        login: true
        disablePassword: true
```

CNPG skips the roles `postgres` and `streaming_replica` and removes `SUPERUSER` from every imported role. Stop the writes to the old cluster before the new `Cluster` is created, and keep them stopped until the clients point to the new one. Give the data disk room for the dump plus the restored data and indexes; CNPG deletes the dump when the import ends.

Check after the import:

```bash
kubectl get secret -n <namespace> <cluster>-app                                    # NotFound
kubectl cnpg psql -n <namespace> <cluster> -- -c '\l'                              # the old databases and owners, no app
kubectl cnpg psql -n <namespace> <cluster> -- -tAc 'select rolname from pg_authid where rolpassword is not null'   # only roles that should have a password
```

## 1 MB WAL files

**Problem.** When there were writes, PostgreSQL switches to a new WAL file at least every 5 minutes (CNPG's `archive_timeout`), and a switched file keeps its full size. With the default 16 MB files, a cluster with a few writes every few minutes makes about 4.5 GiB of WAL files a day, before compression: in `pg_wal` up to `wal_keep_size`, and in the bucket.

**What changes.** With 1 MB files, the same cluster makes about 288 MiB a day, so `wal_keep_size` covers far more time and the bucket grows far slower. Each file is one call to the bucket; against the test store, archiving kept up only below about 2.5 MB/s of WAL. WAL that is not yet archived is never removed.

**How.** In the `Cluster`:

```yaml
spec:
  bootstrap:
    initdb:
      walSegmentSize: 1   # MB
```

CNPG accepts a later change but ignores it. A cluster restored from a backup takes the backup's size. Check on a running instance:

```bash
kubectl exec -n <namespace> <instance pod> -c postgres -- psql -U postgres -tAc 'SHOW wal_segment_size'   # 1MB
```

## The postgres uid and gid of the image

**Problem.** CNPG runs PostgreSQL as uid and gid 26 unless told otherwise, and writes the name the image gives that uid into pg_ident. When the image gives uid 26 another name (one image calls it `postgres_fedora`), the pg_ident line maps that name instead of `postgres`, and a local login without `-U postgres` fails. A uid the image does not know makes initdb fail. CNPG also needs `/bin/sh` in the image: an image without a shell cannot run as an instance.

**What changes.** PostgreSQL runs as the image's own `postgres` user, and CNPG's pg_ident lines name it.

**How.** Read the ids from the image without running it:

```bash
C=$(podman create <image>)
podman cp "$C":/etc/passwd - | tar -xO | grep '^postgres:'   # postgres:x:<uid>:<gid>:...
podman cp "$C":/bin/sh - > /dev/null && echo "has /bin/sh"
podman rm "$C"
```

Then, in the `Cluster`:

```yaml
spec:
  imageName: <image>@sha256:<digest>
  postgresUID: <uid>
  postgresGID: <gid>
```

The webhook refuses any change to these two after creation.
