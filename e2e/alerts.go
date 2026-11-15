package main

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The words of the vocabulary that cause the conditions of the alert
// scenarios: a full data disk, held sessions, an unapproved role, the
// exporter without its grants and short certificates; and the check of the
// metric CNPGTransactionIDWraparound reads.

// The ballast file on a node's data filesystem (disks.go), next to the
// local-path volumes.
const ballastName = "e2e-ballast"

// fillDisk: a ballast file on the data filesystem of the instance's node
// fills it to N % used, as the kubelet counts it. A second line grows the
// same file.
func fillDisk(ctx context.Context, s *scenario, a args) error {
	pod, percent := a.pods[0], a.ns[0]
	if pod == anotherInstance {
		return errors.New("fill the disk of a named instance")
	}
	node, err := nodeOf(ctx, pod)
	if err != nil {
		return err
	}
	dir := diskMount(node)
	path := filepath.Join(dir, ballastName)
	if s.ballast != "" && s.ballast != path {
		return fmt.Errorf("the ballast is on another disk: %s", s.ballast)
	}
	used, size, err := usedBytes(dir)
	if err != nil {
		return err
	}
	want := size / 100 * uint64(percent)
	if used >= want {
		return fmt.Errorf("the data filesystem of %s holds %s already", node, share(used, size))
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	s.ballast = path
	info, err := f.Stat()
	if err == nil {
		// Allocated, not written: the blocks count as used at once.
		err = syscall.Fallocate(int(f.Fd()), 0, 0, info.Size()+int64(want-used))
	}
	if err := errors.Join(err, f.Close()); err != nil {
		return err
	}
	used, size, err = usedBytes(dir)
	s.detail = node + ": " + share(used, size)
	return err
}

// removeBallast: the ballast file is gone.
func removeBallast(_ context.Context, s *scenario, _ args) error {
	if s.ballast == "" {
		return errors.New("no disk was filled")
	}
	if err := os.Remove(s.ballast); err != nil {
		return err
	}
	used, size, err := usedBytes(filepath.Dir(s.ballast))
	s.detail = share(used, size)
	s.ballast = ""
	return err
}

// The application name of the held sessions.
const heldApp = "e2e_held"

// held are the sessions holdSessions holds on an instance.
type held struct {
	pod string
	run *background
}

// holdSessions: psql sessions as postgres on the instance, each in
// pg_sleep, bring the sessions CNPG's backends query counts up to N % of
// max_connections. They go on until "the held sessions are ended".
func holdSessions(ctx context.Context, s *scenario, a args) error {
	pod, percent := a.pods[0], a.ns[0]
	if pod == anotherInstance {
		return errors.New("hold the sessions of a named instance")
	}
	if s.held != nil {
		return errors.New("sessions are held already")
	}
	// As cnpg_backends_total counts them: every session with a user and a state.
	out, err := psql(ctx, pod, "postgres", "select current_setting('max_connections') || ' ' || count(*) "+
		"from pg_stat_activity where usename is not null and state is not null")
	if err != nil {
		return err
	}
	var maxConn, open int
	if _, err := fmt.Sscan(out, &maxConn, &open); err != nil {
		return fmt.Errorf("max_connections and the sessions of %s: %q: %w", pod, out, err)
	}
	n := (maxConn*percent+99)/100 - open
	if n <= 0 {
		return fmt.Errorf("%s has %d sessions of max_connections %d already", pod, open, maxConn)
	}
	const hold = `i=0; while [ "$i" -lt "$1" ]; do
		PGAPPNAME=` + heldApp + ` psql -XqAt -U postgres -d postgres -c "select pg_sleep(3600)" >/dev/null 2>&1 &
		i=$((i+1)); done; wait`
	s.held = &held{pod: pod, run: inBackground(ctx, "kubectl", "exec", "-n", namespace, pod, "-c", "postgres", "--",
		"sh", "-c", hold, "sh", strconv.Itoa(n))}
	s.detail = fmt.Sprintf("%d sessions held, %d of max_connections %d", n, open+n, maxConn)
	return poll(ctx, time.Now().Add(2*time.Minute), func(ctx context.Context) error {
		got, err := psql(ctx, pod, "postgres", "select count(*) from pg_stat_activity where application_name = '"+heldApp+"'")
		if err == nil && got != strconv.Itoa(n) {
			err = fmt.Errorf("%s of %d sessions held on %s", got, n, pod)
		}
		return err
	})
}

// endSessions: the held sessions end, and with them their psql.
func endSessions(ctx context.Context, s *scenario, _ args) error {
	if s.held == nil {
		return errors.New("no sessions are held")
	}
	_, err := psql(ctx, s.held.pod, "postgres",
		"select count(pg_terminate_backend(pid)) from pg_stat_activity where application_name = '"+heldApp+"'")
	if err != nil {
		return err
	}
	err = poll(ctx, time.Now().Add(time.Minute), func(context.Context) error { return s.held.run.finished() })
	if err != nil {
		return err
	}
	s.held = nil
	return nil
}

// A role the compliance query does not expect.
const unapprovedRole = "e2e_unapproved"

func createRole(ctx context.Context, _ *scenario, a args) error {
	_, err := psql(ctx, a.pods[0], "postgres", "create role "+unapprovedRole)
	return err
}

func dropRole(ctx context.Context, _ *scenario, _ args) error {
	primary, err := clusterStatus(ctx, clusterName, "currentPrimary")
	if err != nil {
		return err
	}
	_, err = psql(ctx, primary, "postgres", "drop role "+unapprovedRole)
	return err
}

// The grants the chart's postInitSQL gives the exporter, so that the
// compliance query can read pg_ident; without them the query fails.
const exporterGrants = "%[1]s select on pg_ident_file_mappings %[2]s cnpg_metrics_exporter; " +
	"%[1]s execute on function pg_ident_file_mappings() %[2]s cnpg_metrics_exporter"

func revokeGrants(ctx context.Context, _ *scenario, a args) error {
	_, err := psql(ctx, a.pods[0], "postgres", fmt.Sprintf(exporterGrants, "revoke", "from"))
	return err
}

func giveGrants(ctx context.Context, _ *scenario, a args) error {
	_, err := psql(ctx, a.pods[0], "postgres", fmt.Sprintf(exporterGrants, "grant", "to"))
	return err
}

// reissue: cert-manager issues the chart's Certificate <cluster>-<kind>
// again, as cmctl renew asks it to, and CNPG reloads it. With N days, the
// company CA's ACME role gives N days for it, and its own lifetime again
// right after, also when the issuance failed: cert-manager asks for no
// lifetime, and OpenBao gives the role's. Without, the new certificate has
// the role's own lifetime.
func reissue(kind string) func(context.Context, *scenario, args) error {
	return func(ctx context.Context, s *scenario, a args) (err error) {
		name := clusterName + "-" + kind
		old, err := certificateOf(ctx, name)
		if err != nil {
			return err
		}
		want, err := time.ParseDuration(acmeTTL)
		if err != nil {
			return err
		}
		if len(a.ns) > 0 {
			want = time.Duration(a.ns[0]) * 24 * time.Hour
			ttl := fmt.Sprintf("%dh", a.ns[0]*24)
			if err := s.w.bao.call(ctx, http.MethodPatch, acmeRole, map[string]any{"ttl": ttl, "max_ttl": ttl}, nil); err != nil {
				return err
			}
			defer func() {
				back := map[string]any{"ttl": acmeTTL, "max_ttl": acmeTTL}
				err = errors.Join(err, s.w.bao.call(ctx, http.MethodPatch, acmeRole, back, nil))
			}()
		}
		if err := triggerIssuing(ctx, name); err != nil {
			return err
		}
		var cert *x509.Certificate
		err = poll(ctx, time.Now().Add(5*time.Minute), func(ctx context.Context) error {
			var err error
			if cert, err = certificateOf(ctx, name); err == nil && cert.SerialNumber.Cmp(old.SerialNumber) == 0 {
				err = fmt.Errorf("%s still has its certificate of serial %x", name, old.SerialNumber)
			}
			return err
		})
		if err != nil {
			return err
		}
		life := time.Until(cert.NotAfter)
		s.detail = fmt.Sprintf("%s ends in %.1f days", name, life.Hours()/24)
		if life < want-time.Hour || life > want {
			return fmt.Errorf("the new certificate of %s ends in %.1f days", name, life.Hours()/24)
		}
		_, err = kubectl(ctx, "cnpg", "reload", clusterName, "-n", namespace)
		return err
	}
}

// triggerIssuing sets the Certificate's condition Issuing, which makes
// cert-manager issue it again now.
func triggerIssuing(ctx context.Context, name string) error {
	out, err := kubectl(ctx, "get", "certificate", name, "-n", namespace, "-o", "jsonpath={.status.conditions}")
	if err != nil {
		return err
	}
	var conditions []map[string]any
	if out != "" {
		if err := json.Unmarshal([]byte(out), &conditions); err != nil {
			return fmt.Errorf("the conditions of the Certificate %s: %w", name, err)
		}
	}
	conditions = slices.DeleteFunc(conditions, func(c map[string]any) bool { return c["type"] == "Issuing" })
	conditions = append(conditions, map[string]any{
		"type": "Issuing", "status": "True", "reason": "ManuallyTriggered", "message": "Reissued by the e2e test",
		"lastTransitionTime": time.Now().UTC().Format(time.RFC3339),
	})
	patch, err := json.Marshal(map[string]any{"status": map[string]any{"conditions": conditions}})
	if err != nil {
		return err
	}
	_, err = kubectl(ctx, "patch", "certificate", name, "-n", namespace, "--subresource=status", "--type=merge", "-p", string(patch))
	return err
}

// certificateOf is the certificate in the Secret of the Certificate.
func certificateOf(ctx context.Context, name string) (*x509.Certificate, error) {
	secret, err := kubectl(ctx, "get", "certificate", name, "-n", namespace, "-o", "jsonpath={.spec.secretName}")
	if err != nil {
		return nil, err
	}
	data, err := kubectl(ctx, "get", "secret", secret, "-n", namespace, "-o", `jsonpath={.data.tls\.crt}`)
	if err != nil {
		return nil, err
	}
	der, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		return nil, fmt.Errorf("the Secret %s: %w", secret, err)
	}
	block, _ := pem.Decode(der)
	if block == nil {
		return nil, fmt.Errorf("the Secret %s has no certificate", secret)
	}
	return x509.ParseCertificate(block.Bytes)
}

// xidAgeExported: on every instance, cnpg_pg_database_xid_age arrived in
// the last 60 s for each database that takes connections, as CNPG's query
// reads them, and for no other.
func xidAgeExported(ctx context.Context, s *scenario, _ args) error {
	pods, err := instances(ctx, clusterName)
	if err != nil {
		return err
	}
	for _, pod := range pods {
		out, err := psql(ctx, pod, "postgres", "select datname from pg_database where datallowconn order by 1")
		if err != nil {
			return err
		}
		metric := fmt.Sprintf(`cnpg_pg_database_xid_age{namespace=%q, pod=%q}`, namespace, pod)
		result, err := s.w.mon.query(ctx, metric+" and time() - timestamp("+metric+") < 60", false)
		if err != nil {
			return err
		}
		var got []string
		for _, r := range result {
			got = append(got, r.Metric["datname"])
		}
		slices.Sort(got)
		want := strings.Fields(out)
		if !slices.Equal(got, want) {
			return fmt.Errorf("cnpg_pg_database_xid_age of %s has the databases %v, not %v", pod, got, want)
		}
		s.detail = strings.Join(want, ", ")
	}
	return nil
}
