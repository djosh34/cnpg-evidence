package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/cucumber/godog"
)

// A scenario's tag: lower-case words with dashes.
var scenarioTag = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// runScenario runs the one scenario tagged @<name> of the feature files, on
// its own new cluster, then always.feature. It returns the exit code.
func runScenario(name string, res *results) int {
	if !scenarioTag.MatchString(name) {
		say(os.Stderr, "bench: %q is not a scenario tag\n", name)
		return 2
	}
	format := "progress"
	if res.dir != "" {
		format += ",cucumber:" + res.path("cucumber.json") + ",junit:" + res.path("junit.xml")
	}
	ran := 0
	suite := godog.TestSuite{
		Name: "bench",
		ScenarioInitializer: func(sc *godog.ScenarioContext) {
			s := &scenario{results: res, writes: true, marks: map[string]time.Time{}, limits: map[string]int{}}
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
			Paths: []string{filepath.Join(benchDir, "features")},
			Tags:  "@" + name,
		},
	}
	status := suite.Run()
	switch {
	case ran == 0:
		say(os.Stderr, "bench: %s: @%s\n", errNoScenario, name)
		return 2
	case ran > 1:
		say(os.Stderr, "bench: %d scenarios have the tag @%s; a run runs one\n", ran, name)
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
	logf("scenario %q: a new cluster from the mounted directory", sn.Name)
	var err error
	if s.w, err = newWorld(s.ctx); err != nil {
		return err
	}
	if s.roles, err = roles(s.ctx); err != nil {
		return err
	}
	logf("the primary is %s, replica 1 %s, replica 2 %s", s.roles["the primary"], s.roles["replica 1"], s.roles["replica 2"])
	return nil
}

// tearDown runs always.feature after a passed scenario, keeps the client's
// log, prints the timing table and, on a failure, the cluster's state.
func (s *scenario) tearDown(sn *godog.Scenario, err error) error {
	if err == nil {
		logf("always.feature")
		err = s.runAlways()
	}
	if s.cl != nil {
		err = errors.Join(err, s.stopClient(s.ctx))
		log, logErr := s.cl.rawLog(s.ctx)
		err = errors.Join(err, logErr, s.results.write("client.log", log))
	}
	table := s.table(sn.Name)
	say(os.Stdout, "\n%s\n", table)
	err = errors.Join(err, s.results.write("timing.md", table))
	if err != nil {
		state := dumpState(s.ctx)
		say(os.Stdout, "\n%s", state)
		err = errors.Join(err, s.results.write("state.txt", state))
	}
	return err
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
	{"docker", "logs", "--tail", "30", "k3s-1"},
	{"docker", "logs", "--tail", "30", "k3s-2"},
	{"docker", "logs", "--tail", "30", "k3s-3"},
	{"docker", "exec", "k3s-1", "ls", "-la", "/run", "/run/flannel"},
	{"kubectl", "get", "nodes", "-o", "wide"},
	{"kubectl", "get", "pods", "-A", "-o", "wide"},
	{"kubectl", "get", "clusters,backups,certificates,certificaterequests,orders,challenges", "-A"},
	{"kubectl", "get", "clusterissuers", "-o", "wide"},
	{"kubectl", "describe", "cluster", clusterName, "-n", namespace},
	{"kubectl", "get", "events", "-A", "--sort-by=.lastTimestamp"},
	{"kubectl", "logs", "-n", "cnpg-system", "-l", "app.kubernetes.io/name=cloudnative-pg", "--tail=100", "--prefix"},
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

// The optional results mount. A run writes into a new directory there.
const resultsMount = "/results"

type results struct {
	dir string // empty when /results is not mounted
}

func newResults(scenario string) (*results, error) {
	switch _, err := os.Stat(resultsMount); {
	case errors.Is(err, fs.ErrNotExist):
		return &results{}, nil
	case err != nil:
		return nil, err
	}
	dir := filepath.Join(resultsMount, scenario+"-"+time.Now().UTC().Format("20060102-150405"))
	return &results{dir: dir}, os.MkdirAll(dir, 0o755)
}

func (r *results) path(name string) string { return filepath.Join(r.dir, name) }

func (r *results) write(name, content string) error {
	if r.dir == "" {
		return nil
	}
	return os.WriteFile(r.path(name), []byte(content), 0o644)
}

// own gives the run's files the owner of /results.
func (r *results) own() error {
	if r.dir == "" {
		return nil
	}
	info, err := os.Stat(resultsMount)
	if err != nil {
		return err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("no owner of %s", resultsMount)
	}
	return filepath.WalkDir(r.dir, func(path string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		return os.Lchown(path, int(owner.Uid), int(owner.Gid))
	})
}
