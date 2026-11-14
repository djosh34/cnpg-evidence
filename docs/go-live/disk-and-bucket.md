# Disk and bucket

## The data disk

**Problem.** local-path does not enforce a volume's `storageSize`: every instance writes into the node's filesystem under `/var/lib/rancher/k3s/storage`. When that is the root disk, the database shares it with images and logs. In a test, the node disk ran full and the kubelet evicted two instances; the cluster stayed down for about 50 minutes, until someone deleted the evicted pods by hand. A full data disk stops PostgreSQL, and CNPG does not fail over on it. WAL that the bucket has not taken yet is never removed, so a long bucket outage grows `pg_wal` without a limit.

**What changes.** The database grows into a filesystem of its own, with room for the WAL it may have to hold. Its growth never puts the node under disk pressure.

**How.** First the directory the volumes really use, then, on every node, the filesystem under it:

```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,LOCAL:.spec.local.path,HOSTPATH:.spec.hostPath.path
# every instance volume has LOCAL set; a hostPath volume reports no usage to the kubelet
# the directory above LOCAL is k3s's default /var/lib/rancher/k3s/storage, unless --default-local-storage-path is set
findmnt -T <that directory>          # its own filesystem, not /
df -h <that directory>
```

Size the filesystem for the expected data and its growth, the WAL it keeps (`wal_keep_size` when [replication slots are off](trade-offs.md#replication-slots)) and the WAL that piles up while the bucket is away, plus the dump during the [import](new-cluster.md#the-import-from-the-old-cluster). Then add 100 GB on top of all that.

## Short bucket timeouts

**Problem.** A promotion, a switchover and a starting replica all wait for calls to the bucket: the promotion looks up timeline history files there, the old primary archives its last WAL, a replica asks the bucket for each WAL file before it streams. barman-cloud's defaults give each call a 60 s read timeout and 5 attempts. With a bucket that accepts connections and never answers, the first write after losing the primary's node came after about 40 minutes, and a switchover took about an hour. Replication slots change none of these calls.

**What changes.** A call gives up when the bucket stays silent for 5 seconds while it waits for an answer, and makes one attempt. With a hanging bucket over TLS, the same failover took about 9 minutes; with a bucket that refuses connections, about 80 seconds. A bucket that drops connections without any answer, or stalls during the TLS handshake, still costs 60 seconds per call: botocore's connect timeout, which barman-cloud has no option for. 2 seconds failed against a working bucket. With `switchoverDelay: 30`, the old primary also gets 30 seconds instead of CNPG's default 3600 to archive its last WAL before it is stopped: a switchover with a hanging bucket took about 10 minutes instead of 16.

**How.** In the `ObjectStore` (as in [`objectstore.yaml`](../../samples/charts/cnpg-cluster/templates/objectstore.yaml)):

```yaml
spec:
  configuration:
    wal:
      archiveAdditionalCommandArgs: ["--read-timeout=5"]
      restoreAdditionalCommandArgs: ["--read-timeout=5"]
  instanceSidecarConfiguration:
    env:
      - name: AWS_MAX_ATTEMPTS
        value: "1"
```

and in the `Cluster`:

```yaml
spec:
  switchoverDelay: 30
```

## A bucket nothing can delete from

**Problem.** A replica that fell behind reads the WAL it misses from the bucket. When a file it needs is gone, through a retention policy, a lifecycle rule or a hand delete, that replica retries for ever, and CNPG never rebuilds it. With one replica gone, the failover quorum then cannot promote at the next loss of the primary. barman-cloud also overwrites an existing key without checking, so denying deletes alone does not keep a WAL file from being replaced.

**What changes.** No user can delete an object or a version, or change the lifecycle, the versioning or the policy. The store's root or owner account can still replace the bucket policy (on AWS, the account root user always can); only Object Lock in COMPLIANCE mode holds against that. An overwrite only adds a version: the old file stays, but barman-cloud reads only the newest, so getting the old one back takes a person. Backups and WAL stay for as long as the bucket exists.

**How.** The commands use `B=<bucket>`, `K=<PATH>/policy-check` and `E=--endpoint-url=https://<store>`.

1. Set no `retentionPolicy` in the `ObjectStore`. Without one, barman-cloud never deletes.
2. Give the cluster's credentials only what barman-cloud uses without retention:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::BUCKET"},
       {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"],
        "Resource": "arn:aws:s3:::BUCKET/PATH/*"}
     ]
   }
   ```
   `AbortMultipartUpload` only discards the parts of a failed backup upload. Add `s3:PutObjectTagging` only when the `ObjectStore` sets tags.
3. Turn on versioning, and Object Lock if wanted. In COMPLIANCE mode nobody can remove a locked version before its retention ends, so a test cluster's data then stays for that long too.
4. Remove every lifecycle rule. A bucket policy does not stop lifecycle rules from deleting, and after step 5 nobody can remove them:
   ```bash
   aws s3api get-bucket-lifecycle-configuration $E --bucket "$B"    # error NoSuchLifecycleConfiguration
   aws s3api delete-bucket-lifecycle $E --bucket "$B"               # only if it showed rules
   ```
5. Apply this bucket policy last, since it also denies the calls of steps 3 and 4:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {"Effect": "Deny", "Principal": "*",
        "Action": ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:BypassGovernanceRetention",
                   "s3:PutObjectRetention", "s3:PutObjectLegalHold"],
        "Resource": "arn:aws:s3:::BUCKET/*"},
       {"Effect": "Deny", "Principal": "*",
        "Action": ["s3:DeleteBucket", "s3:PutLifecycleConfiguration", "s3:PutBucketVersioning",
                   "s3:PutBucketObjectLockConfiguration", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy"],
        "Resource": "arn:aws:s3:::BUCKET"}
     ]
   }
   ```

Check, read-only, with admin credentials:

```bash
aws s3api get-bucket-versioning $E --bucket "$B"                 # "Status": "Enabled"
aws s3api get-bucket-lifecycle-configuration $E --bucket "$B"    # error NoSuchLifecycleConfiguration
aws s3api get-object-lock-configuration $E --bucket "$B"         # only if used: "ObjectLockEnabled": "Enabled"
aws s3api get-bucket-policy $E --bucket "$B" --query Policy --output text \
  | jq '.Statement[] | select(.Effect=="Deny")'
# exactly the two statements above: "Principal": "*", the same Action lists and Resource, and no Condition
```

The bucket policy itself: run these with an admin user's credentials, which the store's own permissions allow everything (not the root or owner account). Then only the bucket policy can deny them. Each attempt does no harm if it is wrongly allowed:

```bash
aws s3api put-object    $E --bucket "$B" --key "$K" --body /dev/null    # succeeds
aws s3api delete-object $E --bucket "$B" --key "$K"                     # AccessDenied
aws s3api delete-objects $E --bucket "$B" --delete "Objects=[{Key=$K}]" # AccessDenied in Errors
aws s3api put-bucket-versioning $E --bucket "$B" --versioning-configuration Status=Enabled   # AccessDenied
aws s3api put-bucket-lifecycle-configuration $E --bucket "$B" --lifecycle-configuration \
  '{"Rules":[{"ID":"policy-check","Status":"Disabled","Filter":{"Prefix":"policy-check-none/"},"Expiration":{"Days":1}}]}'   # AccessDenied
aws s3api delete-bucket $E --bucket "$B"                                # AccessDenied, not BucketNotEmpty
```

The cluster's credentials: the same commands give the same answers, but they would also without the bucket policy, since step 2 does not allow these actions. They show the credentials are narrow, not that the policy works.

An S3-compatible store that answers `NotImplemented` to versioning, Object Lock or bucket policies does not support that layer; it then has to be enforced in the store itself.
