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
	"strings"
	"time"

	"github.com/cucumber/godog"
)

// A scenario's tag: lower-case words with dashes.
var scenarioTag = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// runScenario runs the one scenario tagged @<name> of the feature files, on
// its own new cluster, then always.feature. It returns the exit code.
func runScenario(name string, res *results) int {
	format := "progress,cucumber:" + res.path("cucumber.json") + ",junit:" + res.path("junit.xml")
	ran := 0
	suite := godog.TestSuite{
		Name: "e2e",
		ScenarioInitializer: func(sc *godog.ScenarioContext) {
			s := &scenario{
				results: res, writes: true,
				marks: map[string]time.Time{}, limits: map[string]int{}, alerts: map[string]bool{},
				needs: map[string]walNeed{}, switched: map[string]string{}, restarts: map[string]int{},
				scripts: map[string]scriptRun{},
			}
			sc.Before(func(ctx context.Context, sn *godog.Scenario) (context.Context, error) {
				ran++
				s.ctx = ctx
				return ctx, s.setUp(sn)
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
	case status != 0:
		logf("FAILED: %s", name)
		return 1
	}
	logf("PASSED: %s", name)
	return 0
}

// setUp builds the scenario's cluster and names the instances.
func (s *scenario) setUp(sn *godog.Scenario) error {
	logf("scenario %q: a new cluster from samples/", sn.Name)
	var err error
	if s.w, err = newWorld(s.ctx); err != nil {
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
// its cluster was built. It keeps the client's log and the cluster's state,
// prints the timing table and, on a failure, the state.
func (s *scenario) tearDown(sn *godog.Scenario, err error) error {
	if s.w != nil {
		logf("always.feature")
		err = errors.Join(err, s.runAlways())
	}
	if s.clientRan {
		err = errors.Join(err, s.stopClient(s.ctx))
		log, logErr := rawClientLog(s.ctx)
		err = errors.Join(err, logErr, s.results.write("client.log", log))
	}
	table := s.table(sn.Name)
	say(os.Stdout, "\n%s\n", table)
	state := dumpState(s.ctx)
	if s.w != nil {
		state += "\n" + s.w.mon.history(s.ctx, s.w.built)
	}
	if err != nil {
		say(os.Stdout, "\n%s", state)
	}
	return errors.Join(err, s.results.write("timing.md", table), s.results.write("state.txt", state))
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
	{"kubectl", "get", "nodes", "-o", "wide"},
	{"kubectl", "get", "pods", "-A", "-o", "wide"},
	{"kubectl", "get", "clusters,backups,certificates,certificaterequests,orders,challenges", "-A"},
	{"kubectl", "get", "clusterissuers", "-o", "wide"},
	{"kubectl", "describe", "cluster", clusterName, "-n", namespace},
	{"kubectl", "get", "events", "-A", "--sort-by=.lastTimestamp"},
	{"kubectl", "logs", "-n", "cnpg-system", "-l", "app.kubernetes.io/name=cloudnative-pg", "--tail=100", "--prefix"},
	{"kubectl", "logs", "-n", "otel", "-l", "app.kubernetes.io/instance=otel", "--tail=20", "--prefix"},
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
