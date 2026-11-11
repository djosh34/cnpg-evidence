// Command e2e runs one scenario of the feature files in /samples on a new
// three-node k3s cluster, all inside this one privileged container, and
// prints each step with its time:
//
//	e2e <scenario>
//
// The scenario is the tag of one scenario, without the @. TestScenario of
// scenario_test.go copies samples/ of the checkout to /samples before the
// container starts; the run never writes into it. The run writes its files
// into a new directory of /results, which TestScenario copies out at the
// end. The exit code is 0 when the scenario passed, 1 when it failed, and 2
// when it could not run.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
)

const (
	// samples/ of the checkout.
	samplesDir = "/samples"
	// Where a run keeps its own files: the copied charts, the kubeconfig and
	// helm's caches.
	workDir = "/work"
)

func main() {
	if len(os.Args) != 2 {
		say(os.Stderr, "usage: e2e <scenario>\n")
		os.Exit(2)
	}
	os.Exit(run(os.Args[1]))
}

func run(scenario string) int {
	if err := checkInotify(); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
		return 2
	}
	if !scenarioTag.MatchString(scenario) {
		say(os.Stderr, "e2e: %q is not a scenario tag\n", scenario)
		return 2
	}
	results, err := newResults(scenario)
	if err != nil {
		say(os.Stderr, "e2e: results: %v\n", err)
		return 2
	}
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
		return 2
	}
	if err := startDocker(context.Background()); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
		return 2
	}
	return runScenario(scenario, results)
}

// A run needs this many inotify instances. The limit is the host's, for
// every container and user alike, and each k3s node takes many.
const inotifyNeeded = 1024

func checkInotify() error {
	const file = "/proc/sys/fs/inotify/max_user_instances"
	var limit int
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	if _, err := fmt.Sscan(string(data), &limit); err != nil {
		return fmt.Errorf("%s: %w", file, err)
	}
	if limit < inotifyNeeded {
		return fmt.Errorf("the host's fs.inotify.max_user_instances is %d; the three k3s nodes need at least %d. "+
			"Raise it on the host with e2e/inotify.sh of github.com/djosh34/cnpg-evidence, "+
			"or with: sudo sysctl -w fs.inotify.max_user_instances=%d",
			limit, inotifyNeeded, inotifyNeeded)
	}
	return nil
}

var errNoScenario = errors.New("no scenario has that tag")
