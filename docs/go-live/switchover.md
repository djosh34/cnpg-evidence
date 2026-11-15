# Switchovers and rollouts stay short

A switchover moves the primary on purpose, for example before patching its node. A rollout restarts the instances, for a new image or a parameter that needs a restart.

## smartShutdownTimeout: 0

**Problem.** A stopping primary first waits up to `smartShutdownTimeout` (180 s by default) for its sessions to end. A connection pool, such as pgx's or GORM's, never ends its sessions, so every switchover and every rollout of the primary stops writes for the full 180 seconds. A rollout with one pooled session open stopped writes for about 3 minutes.

**What changes.** The primary ends open sessions at once. A switchover stops writes for about 11 seconds; the pool reconnects to the new primary.

**How.** In the `Cluster`:

```yaml
spec:
  smartShutdownTimeout: 0
```

## primaryUpdateMethod: restart

**Problem.** With `primaryUpdateMethod: switchover`, a rollout moves the primary to a replica instead of restarting it. In CNPG 1.30.1, a switchover during a rollout can name one replica as the new primary and then another. The first keeps trying for the primary lease, and the next switchover, a manual `kubectl cnpg promote` included, never ends: no instance is primary, and it stays that way until a person deletes a replica pod. This happened in 5 of 119 switchovers after a rollout. The fix, [cloudnative-pg#11677](https://github.com/cloudnative-pg/cloudnative-pg/pull/11677), is not in a 1.30 release; it first ships in 1.31.0.

**What changes.** A rollout restarts the primary in place instead of switching over, so it never changes which replica is the target. None of 144 switchovers after such a rollout hung. A rollout for a parameter change restarts the primary in its pod and stopped writes for about 6 seconds; a new image recreates the pod, which was not measured. Right after that restart, PostgreSQL starts with CNPG's own pg_ident lines only; the cluster's lines return within seconds, and until then certificate logins and commits wait.

**How.** `restart` is CNPG's default. Check that nothing, a chart value or a patch, sets `switchover`:

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.primaryUpdateMethod}'   # restart
```

If it says `switchover`, remove the line or set `primaryUpdateMethod: restart`.
