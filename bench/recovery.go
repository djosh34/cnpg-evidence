package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

// The words of the vocabulary about WAL, the store, backups and restores,
// and changes of the cluster's release.

const (
	// The backup a scenario takes, and the cluster it restores it into.
	scenarioBackup  = "scenario"
	restoredCluster = "pg-restore"
	// The values file, in the mounted directory, of the second instance image
	// that "the instance image is changed" changes the cluster to.
	newImageValues = "values/new-image.yaml"
)

// walNeed is the WAL an instance that was down needs: the instance more WAL
// was written on, and the WAL file it was writing when that started.
type walNeed struct {
	on, file string
}

// writeRow writes one row on the primary: one WAL record, outside the
// client.
func writeRow(ctx context.Context, _ *scenario, _ args) error {
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	_, err = psql(ctx, primary, "postgres",
		"create table if not exists bench_row (at timestamptz not null default now()); insert into bench_row default values")
	return err
}

// readCatalog reads every catalog table of every database on the instance,
// which sets the hint bits of every catalog row there and so writes their
// pages to WAL now, not later.
func readCatalog(ctx context.Context, _ *scenario, a args) error {
	pod := a.pods[0]
	databases, err := psql(ctx, pod, "postgres", "select datname from pg_database where datallowconn")
	if err != nil {
		return err
	}
	const readAll = `do $$ declare t regclass; begin
		for t in select oid::regclass from pg_class where relnamespace = 'pg_catalog'::regnamespace and relkind = 'r' loop
			execute format('select count(*) from %s', t);
		end loop; end $$`
	for _, db := range strings.Fields(databases) {
		if _, err := psql(ctx, pod, db, readAll); err != nil {
			return err
		}
	}
	return nil
}

// writeWAL writes at least N MB of WAL on the instance: rows of about 1 KB,
// then a truncate, until then. Each instance that is down needs the WAL file
// the instance was writing when this started.
func writeWAL(ctx context.Context, s *scenario, a args) error {
	mb, pod := a.ns[0], a.pods[0]
	start, err := psql(ctx, pod, "postgres", "select pg_current_wal_lsn()")
	if err != nil {
		return err
	}
	file, err := psql(ctx, pod, "postgres", fmt.Sprintf("select pg_walfile_name('%s')", start))
	if err != nil {
		return err
	}
	for _, down := range s.downPods {
		s.needs[down] = walNeed{on: pod, file: file}
	}
	if _, err := psql(ctx, pod, "postgres", "create table if not exists bench_load (n int, pad text)"); err != nil {
		return err
	}
	for written := 0; written < mb; {
		_, err := psql(ctx, pod, "postgres",
			"insert into bench_load select g, repeat(md5(g::text), 30) from generate_series(1, 40000) g; truncate bench_load")
		if err != nil {
			return err
		}
		out, err := psql(ctx, pod, "postgres", fmt.Sprintf("select floor((pg_current_wal_lsn() - '%s') / 1048576)::bigint", start))
		if err != nil {
			return err
		}
		if written, err = strconv.Atoi(out); err != nil {
			return err
		}
		s.detail = fmt.Sprintf("%d MB written", written)
	}
	return nil
}

// switchWAL makes the instance switch to a new WAL file.
func switchWAL(ctx context.Context, s *scenario, a args) error {
	file, err := psql(ctx, a.pods[0], "postgres", "select pg_walfile_name(pg_switch_wal())")
	if err != nil {
		return err
	}
	s.switched[a.pods[0]] = file
	return nil
}

// walArchived: the store has the WAL file the instance switched away from.
func walArchived(ctx context.Context, s *scenario, a args) error {
	pod := a.pods[0]
	file, ok := s.switched[pod]
	if !ok {
		return fmt.Errorf("no WAL switched on %s yet", pod)
	}
	out, err := psql(ctx, pod, "postgres", fmt.Sprintf(
		`select coalesce(last_archived_wal >= '%s' collate "C", false) || ' ' || coalesce(last_archived_wal, 'none') from pg_stat_archiver`, file))
	if err != nil {
		return err
	}
	if archived, last, _ := strings.Cut(out, " "); archived != "true" {
		return fmt.Errorf("%s has not archived %s yet; its last archived WAL file is %s", pod, file, last)
	}
	return nil
}

// walWaiting: the instance has WAL files that wait for the store.
func walWaiting(ctx context.Context, _ *scenario, a args) error {
	n, err := psql(ctx, a.pods[0], "postgres", "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'")
	if err != nil {
		return err
	}
	if n == "0" {
		return fmt.Errorf("no WAL waits for the store on %s", a.pods[0])
	}
	return nil
}

// neededWALGone: the WAL file the first instance needs is gone from the
// pg_wal of the second, on which it was written. Two checkpoints first
// remove the files beyond wal_keep_size.
func neededWALGone(ctx context.Context, s *scenario, a args) error {
	need, ok := s.needs[a.pods[0]]
	switch {
	case !ok:
		return fmt.Errorf("no WAL was written while %s was down", a.pods[0])
	case need.on != a.pods[1]:
		return fmt.Errorf("the WAL %s needs was written on %s, not %s", a.pods[0], need.on, a.pods[1])
	}
	for range 2 {
		if _, err := psql(ctx, need.on, "postgres", "checkpoint"); err != nil {
			return err
		}
	}
	n, err := psql(ctx, need.on, "postgres", fmt.Sprintf("select count(*) from pg_ls_waldir() where name = '%s'", need.file))
	if err != nil {
		return err
	}
	if n != "0" {
		return fmt.Errorf("%s is still in the pg_wal of %s", need.file, need.on)
	}
	return nil
}

// caughtUp: the instance's pod has turned ready, and the instance streams
// and has replayed the primary's WAL up to where it was a moment ago. The
// timing table gives how far behind it was when its pod first turned ready,
// which opens its node's read port.
func caughtUp(ctx context.Context, s *scenario, a args) error {
	pod := a.pods[0]
	primary, err := clusterField(ctx, "currentPrimary")
	if err != nil {
		return err
	}
	lsn, err := psql(ctx, primary, "postgres", "select pg_current_wal_lsn()")
	if err != nil {
		return err
	}
	if s.detail == "" {
		ready, err := kubectl(ctx, "get", "pod", pod, "-n", namespace, "-o", `jsonpath={.status.conditions[?(@.type=="Ready")].status}`)
		if err != nil {
			return err
		}
		if ready == "True" {
			behind, err := psql(ctx, pod, "postgres", fmt.Sprintf(
				"select round((pg_wal_lsn_diff('%s', pg_last_wal_replay_lsn()) / 1048576)::numeric, 1)", lsn))
			if err != nil {
				return err
			}
			s.detail = behind + " MB behind when its pod turned ready"
		}
	}
	if s.detail == "" {
		return fmt.Errorf("the pod of %s is not ready", pod)
	}
	out, err := psql(ctx, pod, "postgres", fmt.Sprintf(
		"select status = 'streaming' and pg_last_wal_replay_lsn() >= '%s' from pg_stat_wal_receiver", lsn))
	if err != nil {
		return err
	}
	if out != "t" {
		return fmt.Errorf("%s does not stream or has not replayed up to %s", pod, lsn)
	}
	return nil
}

// idleAfterSwitch: the instance's insert position is 40 bytes, a page
// header, past its flush position at the start of a WAL file, and stays there
// for 30 s: an idle primary just after a WAL switch, with no checkpoint after
// it. A former primary that rewinds onto it waits for its next WAL record.
func idleAfterSwitch(ctx context.Context, _ *scenario, a args) error {
	const position = `select (pg_current_wal_insert_lsn() - pg_current_wal_flush_lsn())::bigint || ' ' ||
		((pg_current_wal_flush_lsn() - '0/0'::pg_lsn) % setting::bigint)::bigint
		from pg_settings where name = 'wal_segment_size'`
	end := time.Now().Add(30 * time.Second)
	for {
		out, err := psql(ctx, a.pods[0], "postgres", position)
		if err != nil {
			return err
		}
		if out != "40 0" {
			return fmt.Errorf("on %s, the insert position minus the flush position, and the flush position in its WAL file: %s", a.pods[0], out)
		}
		if time.Now().After(end) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

// changeImage: the cluster's release gets the instance image of
// values/new-image.yaml. CNPG restarts every instance on it, the primary
// last, in place.
func changeImage(ctx context.Context, _ *scenario, _ args) error {
	return upgradeCluster(ctx, "--values", filepath.Join(benchDir, newImageValues))
}

// onNewImage: every instance runs the image of values/new-image.yaml and is
// ready.
func onNewImage(ctx context.Context, _ *scenario, _ args) error {
	data, err := os.ReadFile(filepath.Join(benchDir, newImageValues))
	if err != nil {
		return err
	}
	var values struct {
		Cluster struct {
			ImageName string `yaml:"imageName"`
		} `yaml:"cluster"`
	}
	if err := yaml.Unmarshal(data, &values); err != nil {
		return fmt.Errorf("%s: %w", newImageValues, err)
	}
	if values.Cluster.ImageName == "" {
		return fmt.Errorf("%s has no cluster.imageName", newImageValues)
	}
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	if len(pods) != nodeCount {
		return fmt.Errorf("instances: %v", pods)
	}
	for _, pod := range pods {
		out, err := kubectl(ctx, "get", "pod", pod, "-n", namespace, "-o",
			`jsonpath={.spec.containers[?(@.name=="postgres")].image} {.status.containerStatuses[?(@.name=="postgres")].ready}`)
		if err != nil {
			return err
		}
		if out != values.Cluster.ImageName+" true" {
			return fmt.Errorf("the image of %s, and whether it is ready: %s", pod, out)
		}
	}
	return nil
}

// setWalKeepSize: the cluster's release gets wal_keep_size N MB.
func setWalKeepSize(ctx context.Context, _ *scenario, a args) error {
	return upgradeCluster(ctx, "--set", fmt.Sprintf("cluster.walKeepSize=%dMB", a.ns[0]))
}

func walKeepSizeIs(ctx context.Context, _ *scenario, a args) error {
	want := fmt.Sprintf("%dMB", a.ns[0])
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	for _, pod := range pods {
		got, err := psql(ctx, pod, "postgres", "show wal_keep_size")
		if err != nil {
			return err
		}
		if got != want {
			return fmt.Errorf("wal_keep_size on %s: %s", pod, got)
		}
	}
	return nil
}

func backUp(ctx context.Context, _ *scenario, _ args) error {
	return takeBackup(ctx, scenarioBackup)
}

func backupDone(ctx context.Context, _ *scenario, _ args) error {
	return backupCompleted(ctx, scenarioBackup)
}

// restore installs pg-restore, a new cluster restored from the cluster's
// backups and WAL in the store.
func restore(ctx context.Context, _ *scenario, _ args) error {
	return installRestore(ctx, restoredCluster)
}

func restoreHealthy(ctx context.Context, _ *scenario, _ args) error {
	return healthy(ctx, restoredCluster)
}

// noneLostInRestore: every write the client got acknowledged is in
// bench_writes on the primary of pg-restore. The client must have stopped
// writing before.
func noneLostInRestore(ctx context.Context, s *scenario, _ args) error {
	log, err := s.clientLog(ctx)
	if err != nil {
		return err
	}
	if _, stopped := log.writesStopped(); s.writes && !stopped {
		return errors.New("writing must stop before the restore")
	}
	return s.acknowledgedOn(ctx, restoredCluster)
}

// restoreCompliant and compliant: every instance of the cluster, pg-restore
// or the cluster's own, reported each of the four checks of the compliance
// query as 0 in the last 30 s.
func restoreCompliant(ctx context.Context, s *scenario, _ args) error {
	return s.compliant(ctx, restoredCluster)
}

func compliant(ctx context.Context, s *scenario, _ args) error {
	return s.compliant(ctx, clusterName)
}

func (s *scenario) compliant(ctx context.Context, cluster string) error {
	pods, err := instances(ctx, cluster)
	if err != nil {
		return err
	}
	if len(pods) != nodeCount {
		return fmt.Errorf("instances of %s: %v", cluster, pods)
	}
	selector := fmt.Sprintf(`namespace=%q, cluster=%q`, namespace, cluster)
	zero, err := s.w.mon.pods(ctx, fmt.Sprintf(`count by (pod) (
		(cnpg_compliance_violations{%s} == 0)
		and on (pod, rule, check) (time() - timestamp(cnpg_compliance_violations{%s}) < 30)) == 4`, selector, selector))
	if err != nil {
		return err
	}
	for _, pod := range pods {
		if !zero[pod] {
			return fmt.Errorf("%s did not report the four compliance checks as 0 in the last 30 s", pod)
		}
	}
	return nil
}

// breakStore stops or pauses the store; storeStarts brings it back.
func breakStore(how string) func(context.Context, *scenario, args) error {
	return func(ctx context.Context, s *scenario, _ args) error {
		if s.store != "" {
			return fmt.Errorf("the store is %s already", s.store)
		}
		var err error
		if how == "stopped" {
			err = stopStore(ctx, s.w.nw)
		} else {
			err = pauseStore(ctx)
		}
		if err != nil {
			return err
		}
		s.store = how
		logf("the store is %s", how)
		return nil
	}
}

func storeStarts(ctx context.Context, s *scenario, _ args) error {
	if s.store == "" {
		return errors.New("the store is not broken")
	}
	if err := restoreStore(ctx, s.store == "stopped"); err != nil {
		return err
	}
	s.store = ""
	logf("the store is back")
	return nil
}
