// Command e2e runs one scenario of the feature files in /samples/features on
// a new three-node k3s cluster, all inside this one privileged container,
// and prints each step with its time:
//
//	e2e <scenario> [<variant>]
//
// The scenario is the tag of one scenario, without the @. The cluster is
// built from the settings in /samples, or from those in /variants/<variant>
// when a variant is given, with every version from the manifest
// /manifest.yaml. TestScenario of scenario_test.go copies them from the
// checkout before the container starts; the run never writes into them.
// The run writes its files into a new directory of /results, which
// TestScenario copies out at the end. The exit code is 0 when the scenario
// passed, 1 when it failed, and 2 when it could not run.
package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
)

const (
	// samples/ of the checkout. Its features/ are the scenarios of every
	// run, the samples' and each variant's.
	samplesDir = "/samples"
	// variants/ of the checkout, with the one variant a run applies.
	variantsDir = "/variants"
	// The manifest of versions/ the run uses.
	manifestFile = "/manifest.yaml"
	// Where a run keeps its own files: the copied charts, the kubeconfig and
	// helm's caches.
	workDir = "/work"
)

// variant is the variant the run applies, or "" for the samples. main sets
// it once, before the run starts.
var variant string

// manifest holds the versions of the run. run reads it once, before the
// cluster is built.
var manifest *versions.Manifest

// settingsDir is the directory of the settings the run applies: /samples, or
// the variant's directory of /variants.
func settingsDir() string {
	if variant == "" {
		return samplesDir
	}
	return filepath.Join(variantsDir, variant)
}

// The scenarios a variant run leaves out; TestScenario refuses them. A
// variant's client has no pgfallback, so the three that test it do not
// apply. rejoin-from-archive needs the primary to drop WAL that a stopped
// replica needs, which CNPG's replication slots keep when they are on, as
// CNPG has them by default. Every scenario with a lost node or a switchover
// still tests a rejoin, through always.feature.
var notInVariants = []string{
	"pgfallback-drain", "pgfallback-primary-node-loss", "pgfallback-replica-node-loss", "rejoin-from-archive",
}

func main() {
	if len(os.Args) != 2 && len(os.Args) != 3 {
		say(os.Stderr, "usage: e2e <scenario> [<variant>]\n")
		os.Exit(2)
	}
	if len(os.Args) == 3 {
		variant = os.Args[2]
	}
	os.Exit(run(os.Args[1]))
}

func run(scenario string) int {
	if err := checkInotify(); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
		return 2
	}
	if err := checkBrNetfilter(); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
		return 2
	}
	if !scenarioTag.MatchString(scenario) {
		say(os.Stderr, "e2e: %q is not a scenario tag\n", scenario)
		return 2
	}
	if variant != "" && !scenarioTag.MatchString(variant) {
		say(os.Stderr, "e2e: %q is not a variant name\n", variant)
		return 2
	}
	results, err := newResults(scenario)
	if err != nil {
		say(os.Stderr, "e2e: results: %v\n", err)
		return 2
	}
	if manifest, err = versions.Load(manifestFile); err != nil {
		say(os.Stderr, "e2e: the manifest: %v\n", err)
		return 2
	}
	// The results say which versions ran.
	if err := copyFile(manifestFile, results.path("manifest.yaml")); err != nil {
		say(os.Stderr, "e2e: %v\n", err)
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
	disks := &dataDisks{}
	code := 2
	if err := disks.prepare(context.Background()); err != nil {
		say(os.Stderr, "e2e: the nodes' data filesystems: %v\n", err)
	} else {
		disks.watch()
		code = runScenario(scenario, results)
	}
	// A run that cannot clean up is a fault of the run, also when its
	// scenario passed.
	if err := disks.finish(context.Background(), results); err != nil {
		say(os.Stderr, "e2e: cleaning up the nodes' data filesystems: %v\n", err)
		code = max(code, 2)
	}
	return code
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

// checkBrNetfilter checks that the host's kernel has br_netfilter, built in
// or loaded. k3s cannot load the module from inside a node, so otherwise
// the kernel loads it while a node installs its first iptables rule with a
// physdev match. In one run, that load never ended and the node never
// turned Ready (docs/e2e.md).
func checkBrNetfilter() error {
	_, err := os.Stat("/proc/sys/net/bridge/bridge-nf-call-iptables")
	if errors.Is(err, fs.ErrNotExist) {
		return errors.New("the host's kernel has not loaded br_netfilter, which the k3s nodes need. " +
			"Load it on the host with: sudo modprobe br_netfilter")
	}
	return err
}

var errNoScenario = errors.New("no scenario has that tag")

func copyFile(from, to string) error {
	data, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	return os.WriteFile(to, data, 0o644)
}
