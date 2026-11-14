# Set when the cluster is created

CNPG takes these only when it creates a cluster. Getting them wrong later means a new cluster and moving the data.

## 1 MB WAL files

**Problem.** PostgreSQL switches to a new WAL file at least every 5 minutes (CNPG's `archive_timeout`), and a switched file keeps its full size. With the default 16 MB files, a cluster with almost no writes still fills about 4.5 GiB a day in `pg_wal` and in the bucket.

**What changes.** With 1 MB files, the same cluster writes about 288 MiB a day, so `wal_keep_size` covers far more time and the bucket grows far slower. Each file is one call to the bucket, so archiving keeps up only below about 2.5 MB/s of WAL; WAL that is not yet archived is never removed.

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
