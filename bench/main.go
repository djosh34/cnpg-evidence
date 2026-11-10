// Command bench runs one scenario of the feature files in /bench on a new
// three-node k3s cluster, all inside this one privileged container, and
// prints each step with its time.
//
//	docker run --rm --privileged -v ./samples:/bench:ro [-v ./results:/results] <image> <scenario>
//
// The scenario is the tag of one scenario, without the @. /bench is the
// mounted directory (docs/bench.md), mounted read-only; the bench never
// writes into it. When /results is mounted, the bench writes the run's files
// into a new directory there. The exit code is 0 when the scenario passed, 1
// when it failed, and 2 when it could not run.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

const (
	// The mounted directory.
	benchDir = "/bench"
	// Where the bench keeps its own files: the copied charts, kubeconfig and
	// helm's caches.
	workDir = "/work"
)

func main() {
	if len(os.Args) != 2 {
		say(os.Stderr, "usage: bench <scenario>\n")
		os.Exit(2)
	}
	os.Exit(run(os.Args[1]))
}

func run(scenario string) int {
	if err := checkInotify(); err != nil {
		say(os.Stderr, "bench: %v\n", err)
		return 2
	}
	if !scenarioTag.MatchString(scenario) {
		say(os.Stderr, "bench: %q is not a scenario tag\n", scenario)
		return 2
	}
	results, err := newResults(scenario)
	if err != nil {
		say(os.Stderr, "bench: results: %v\n", err)
		return 2
	}
	// A stopped run still leaves its results to the owner of /results.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-signals
		say(os.Stderr, "bench: %s, stopping\n", sig)
		if err := results.own(); err != nil {
			say(os.Stderr, "bench: results: %v\n", err)
		}
		os.Exit(2)
	}()

	code := 2
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		say(os.Stderr, "bench: %v\n", err)
	} else if err := startDocker(context.Background()); err != nil {
		say(os.Stderr, "bench: %v\n", err)
	} else {
		code = runScenario(scenario, results)
	}
	if err := results.own(); err != nil {
		say(os.Stderr, "bench: results: %v\n", err)
		code = max(code, 1)
	}
	return code
}

// The bench needs this many inotify instances. The limit is the host's, for
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
			"Raise it on the host with bench/host.sh of github.com/djosh34/cnpg-evidence, "+
			"or with: sudo sysctl -w fs.inotify.max_user_instances=%d",
			limit, inotifyNeeded, inotifyNeeded)
	}
	return nil
}

var errNoScenario = errors.New("no scenario has that tag")
