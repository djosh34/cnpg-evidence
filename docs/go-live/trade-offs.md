# To weigh

## Replication slots

CNPG keeps a replication slot on the primary for each replica by default. Both choices have a failure that needs a person; which is likelier depends on how long a node can stay away and how reliable the bucket is.

**Slots on (CNPG's default).**
- **Problem.** A slot keeps every WAL file its replica has not received, with no limit. A replica whose node stays down, for a failed patch or a dead disk, makes the primary keep all WAL from then on. In a test the slots held 3 GB after 7 minutes of writes. When the data disk fills, PostgreSQL stops and CNPG does not fail over. CNPG does not drop the slot by itself.
- **What it gives.** A replica that comes back always finds its WAL on the primary, whatever state the bucket is in.

**Slots off, with `wal_keep_size` (the samples).**
- **What changes.** Every instance keeps `wal_keep_size` of WAL, and no more for a missing replica. A replica further behind reads the rest from the bucket by itself; in tests, replicas and a former primary rejoined after days away without a person, and the primary's `pg_wal` stayed at about 1.5 GB.
- **Problem.** That catch-up needs the bucket, and a [bucket nothing deletes from](disk-and-bucket.md#a-bucket-nothing-can-delete-from). While the bucket is away, a replica beyond `wal_keep_size` waits for it.

**How.** Slots off, in the `Cluster`:

```yaml
spec:
  replicationSlots:
    highAvailability:
      enabled: false
  postgresql:
    parameters:
      wal_keep_size: "30GB"   # about three months of a quiet cluster's WAL with 1 MB files
```

The data disk then needs room for `wal_keep_size` on top of the data ([the data disk](disk-and-bucket.md#the-data-disk)).
