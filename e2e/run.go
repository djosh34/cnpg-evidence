package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/cucumber/godog"
)

// A scenario's tag: lower-case words with dashes.
var scenarioTag = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// runScenario runs the one scenario tagged @<name> of the feature files, on
// its own new cluster, then always.feature. It returns the exit code: 2
// also when the scenario ran but the run could not keep its files, so such
// a fault never looks like a failed line.
func runScenario(name string, res *results) int {
	format := "progress,cucumber:" + res.path("cucumber.json") + ",junit:" + res.path("junit.xml")
	ran := 0
	var s *scenario
	suite := godog.TestSuite{
		Name: "e2e",
		ScenarioInitializer: func(sc *godog.ScenarioContext) {
			s = &scenario{
				results: res, writes: true,
				marks: map[string]time.Time{}, limits: map[string]int{}, alerts: map[string]bool{},
				needs: map[string]walNeed{}, switched: map[string]string{}, restarts: map[string]int{},
				scripts: map[string]scriptRun{},
			}
			sc.Before(func(ctx context.Context, sn *godog.Scenario) (context.Context, error) {
				ran++
				s.ctx = ctx
				return ctx, s.setUp(sn, name)
			})
			sc.After(func(ctx context.Context, sn *godog.Scenario, err error) (context.Context, error) {
				return ctx, s.tearDown(sn, err)
			})
			s.bind(sc)
		},
		Options: &godog.Options{
			Format: format, Output: io.Discard, Strict: true, NoColors: true,
			Paths: []string{filepath.Join(samplesDir, "features")},
			Tags:  "@" + name + " && ~@always",
		},
	}
	status := suite.Run()
	switch {
	case ran == 0:
		say(os.Stderr, "e2e: %s: @%s\n", errNoScenario, name)
		return 2
	case ran > 1:
		say(os.Stderr, "e2e: %d scenarios have the tag @%s; a run runs one\n", ran, name)
		return 2
	case s.fault != nil:
		say(os.Stderr, "e2e: the run could not keep its files: %v\n", s.fault)
		return 2
	case status != 0:
		logf("FAILED: %s", name)
		return 1
	}
	logf("PASSED: %s", name)
	return 0
}

// The scenario whose cluster starts on the manifest's postgresql.rolloutFrom
// and rolls out to its postgresql.imageName. Every other cluster starts on
// postgresql.imageName.
const rolloutScenario = "rollout"

// setUp builds the scenario's cluster, checks the images on the nodes and
// names the instances.
func (s *scenario) setUp(sn *godog.Scenario, name string) error {
	logf("scenario %q: a new cluster from %s", sn.Name, settingsDir())
	firstImage := manifest.PostgreSQL.ImageName
	if name == rolloutScenario {
		firstImage = manifest.PostgreSQL.RolloutFrom
	}
	var err error
	if s.w, err = newWorld(s.ctx, firstImage); err != nil {
		return err
	}
	seen, err := nodeImagesPinned(s.ctx)
	s.images = append(s.images, seen...)
	if err != nil {
		return err
	}
	if s.roles, err = roles(s.ctx); err != nil {
		return err
	}
	logf("the primary is %s, replica 1 %s, replica 2 %s", s.roles["the primary"], s.roles["replica 1"], s.roles["replica 2"])
	s.started = time.Now()
	return nil
}

// tearDown runs always.feature after the scenario, passed or failed, once
// its cluster was built; after a failed line, it first ends the outages
// still in place. It keeps the client's log, the cluster's state and the
// nodes' logs, prints the timing table and, on a failure, the state. An
// error in keeping them is also in s.fault.
func (s *scenario) tearDown(sn *godog.Scenario, err error) error {
	if s.w != nil {
		if err != nil {
			err = errors.Join(err, s.afterFailure())
		}
		logf("always.feature")
		err = errors.Join(err, s.runAlways())
	}
	var fault error
	if s.clientRan {
		fault = s.stopClient(s.ctx)
		log, logErr := rawClientLog(s.ctx)
		fault = errors.Join(fault, logErr, s.results.write("client.log", log))
	}
	table := s.table(sn.Name)
	say(os.Stdout, "\n%s\n", table)
	state := dumpState(s.ctx)
	if s.w != nil {
		state += "\n" + s.w.mon.history(s.ctx, s.w.built)
	}
	if err != nil || fault != nil {
		say(os.Stdout, "\n%s", state)
	}
	s.images = append(s.images, imagesAtEnd(s.ctx)...)
	if len(s.images) > 0 {
		slices.Sort(s.images)
		fault = errors.Join(fault, s.results.write("images.txt", strings.Join(slices.Compact(s.images), "\n")+"\n"))
	}
	s.fault = errors.Join(fault, s.results.write("timing.md", table), s.results.write("state.txt", state), nodeLogs(s.ctx, s.results))
	return errors.Join(err, s.fault)
}

// nodeLogs writes each node's whole log, k3s's and the kubelet's, to
// <node>.log, so a node that never registers or turns Ready can be traced.
// A node that never started has no log.
func nodeLogs(ctx context.Context, res *results) error {
	var errs []error
	for i := range nodeCount {
		node := nodeName(i)
		ctx, cancel := context.WithTimeout(ctx, time.Minute)
		// docker logs prints the container's stderr on its own stderr.
		out, err := exec.CommandContext(ctx, "docker", "logs", "--timestamps", node).CombinedOutput()
		cancel()
		if err != nil && strings.Contains(string(out), "No such container") {
			continue
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("the log of %s: %w: %s", node, err, out))
			continue
		}
		errs = append(errs, res.write(node+".log", string(out)))
	}
	return errors.Join(errs...)
}

// table is the timing table of the scenario, in Markdown.
func (s *scenario) table(name string) string {
	table := "### " + name + "\n\n| Line | Result | Took | Since | Measured |\n|---|---|---|---|---|\n"
	for _, r := range s.rows {
		table += fmt.Sprintf("| %s | %s | %s | %s | %s |\n", r.line, r.result, r.took, r.after, r.detail)
	}
	return table
}

// What the state dump of a failed scenario shows.
var stateCommands = [][]string{
	{"docker", "ps", "-a"},
	// The kernel's last messages: a task blocked for minutes shows here.
	{"sh", "-c", "set -o pipefail; dmesg | tail -n 50"},
	{"docker", "logs", "--tail", "30", "dns"},
	{"docker", "logs", "--tail", "30", "acme"},
	{"docker", "logs", "--tail", "30", "s3"},
	{"docker", "logs", "--tail", "30", "client"},
	{"docker", "logs", "--tail", "30", "otel"},
	{"docker", "logs", "--tail", "30", "prometheus"},
	{"docker", "logs", "--tail", "30", "alertmanager"},
	{"docker", "logs", "--tail", "30", "grafana"},
	{"docker", "logs", "--tail", "30", "k3s-1"},
	{"docker", "logs", "--tail", "30", "k3s-2"},
	{"docker", "logs", "--tail", "30", "k3s-3"},
	// The newest API audit events, when the settings have an audit log.
	{"docker", "exec", "k3s-1", "tail", "-n", "5", "/var/lib/rancher/k3s/server/logs/audit.log"},
	// The images on each node, also when always.feature stopped before it
	// checked them.
	{"docker", "exec", "k3s-1", "crictl", "images", "--digests"},
	{"docker", "exec", "k3s-2", "crictl", "images", "--digests"},
	{"docker", "exec", "k3s-3", "crictl", "images", "--digests"},
	{"kubectl", "get", "nodes", "-o", "wide"},
	{"kubectl", "get", "pods", "-A", "-o", "wide"},
	{"kubectl", "get", "clusters,backups,certificates,certificaterequests,orders,challenges", "-A"},
	{"kubectl", "get", "clusterissuers,issuers", "-A", "-o", "wide"},
	{"kubectl", "get", "services", "-A"},
	{"kubectl", "describe", "cluster", clusterName, "-n", namespace},
	{"kubectl", "get", "events", "-A", "--sort-by=.lastTimestamp"},
	{"kubectl", "logs", "-n", "cnpg-system", "-l", "app.kubernetes.io/name=cloudnative-pg", "--tail=100", "--prefix"},
	{"kubectl", "logs", "-n", "otel", "-l", "app.kubernetes.io/instance=otel", "--tail=20", "--prefix"},
	{"kubectl", "logs", "-n", "cnpg-system", "-l", "app.kubernetes.io/name=plugin-barman-cloud", "--tail=50", "--prefix"},
	// CNPG's jobs, such as a restore's full-recovery: their pods end and
	// show only as Error otherwise.
	{"kubectl", "logs", "-n", namespace, "-l", "cnpg.io/jobRole", "--all-containers", "--tail=50", "--prefix", "--max-log-requests=20"},
}

func dumpState(ctx context.Context) string {
	state := "State of the cluster:\n"
	for _, c := range stateCommands {
		ctx, cancel := context.WithTimeout(ctx, time.Minute)
		cmd := exec.CommandContext(ctx, c[0], c[1:]...)
		cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
		// docker logs prints the container's stderr on its own stderr.
		out, err := cmd.CombinedOutput()
		cancel()
		state += fmt.Sprintf("\n$ %s\n%s", strings.Join(c, " "), out)
		if err != nil {
			state += err.Error() + "\n"
		}
	}
	return state
}

// Where a run writes its files, in a new directory. TestScenario copies
// them out at the end.
const resultsDir = "/results"

type results struct {
	dir string
}

func newResults(scenario string) (*results, error) {
	r := &results{dir: filepath.Join(resultsDir, scenario+"-"+time.Now().UTC().Format("20060102-150405"))}
	return r, os.MkdirAll(r.dir, 0o755)
}

func (r *results) path(name string) string { return filepath.Join(r.dir, name) }

func (r *results) write(name, content string) error {
	return os.WriteFile(r.path(name), []byte(content), 0o644)
}
