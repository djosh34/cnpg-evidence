#!/usr/bin/env bash
# A backup to the object store, then a new cluster restored from it with the
# chart, as docs/samples.md says under "Restore into a new cluster". The
# backup must complete within 10 min. Then the client stops, and the primary
# switches WAL and archives it, so the store holds every acknowledged commit.
# The restored cluster must have three ready instances with two streaming
# replicas within 15 min, every acknowledged commit, and
# cnpg_compliance_violations 0 for each of its 4 checks on every instance.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

BACKUP=live-backup
RESTORED=pg-restore
AFTER_BACKUP_SECONDS=30  # the client goes on this long after the backup

# WAL file $2 of instance $1 is archived.
archived() {
  [[ $(psql_on "$1" -c "select coalesce(last_archived_wal >= '$2' collate \"C\", false) from pg_stat_archiver") == t ]] ||
    { echo "last archived WAL file: $(psql_on "$1" -c 'select last_archived_wal from pg_stat_archiver')" >&2; return 1; }
}

wait_for 600 "three ready instances, two streaming replicas" settled
start_monitoring "${NODES[0]}"
start_client

T0=$(now_ms)
k cnpg backup "$CLUSTER" -n "$NS" --backup-name "$BACKUP" \
  --method plugin --plugin-name barman-cloud.cloudnative-pg.io >/dev/null
log "backup $BACKUP started"
wait_for 600 "backup $BACKUP completed" backup_completed "$BACKUP"
BACKED_UP=$(now_ms)
sleep "$AFTER_BACKUP_SECONDS"
wait_back
finish

p=$(primary)
wal=$(psql_on "$p" -c 'select pg_walfile_name(pg_switch_wal())')
wait_for 120 "WAL file $wal archived" archived "$p" "$wal"
ARCHIVED=$(now_ms)

log "restoring into the cluster $RESTORED"
timeout 300 helm install "$RESTORED" "$REPO/samples/charts/cnpg-cluster" --namespace "$NS" \
  -f "$REPO/samples/desired.yaml" -f "$LIVE_DIR/values.yaml" \
  --set cluster.name="$RESTORED" --set recovery.enabled=true --set recovery.sourceCluster="$CLUSTER" \
  --set rwLoadBalancer.name="$RESTORED-rw-lb" --set readLoadBalancer=null >/dev/null
CLUSTER=$RESTORED
wait_for 900 "three ready instances of $RESTORED, two streaming replicas" settled
RESTORED_AT=$(now_ms)
RESTORED_COMMITS=$(check_commits)
pods=$(instance_pods)
for pod in $pods; do
  wait_for 120 "cnpg_compliance_violations 0 for 4 checks on $pod" compliance_zero "$pod"
done
METRICS=$(now_ms)

summary "### backup-restore, writer $WRITER"
summary ""
row "Seconds after kubectl cnpg backup of pg" ""
summary "|---|---|"
row "backup $BACKUP completed" "$(secs "$BACKED_UP")"
common_rows
row "WAL file $wal archived" "$(secs "$ARCHIVED")"
row "$RESTORED restored: three ready instances, two streaming replicas" "$(secs "$RESTORED_AT")"
row "acknowledged commits, all in $RESTORED" "$RESTORED_COMMITS"
row "cnpg_compliance_violations 0 for 4 checks on every instance of $RESTORED" "$(secs "$METRICS")"
print_summary
