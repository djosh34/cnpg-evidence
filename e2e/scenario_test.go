package main

import (
	"context"
	"flag"
	"os"
	"os/exec"
	"testing"
	"time"

	moby "github.com/moby/moby/api/types/container"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

var scenarioFlag = flag.String("scenario", "", "the scenario to run: its tag, without the @")

// TestScenario runs one scenario, as ./e2e.sh does. It builds e2e/Dockerfile
// from this checkout for the machine's own architecture, copies samples/ in
// and runs the image as one privileged container. Its last step copies the
// run's files out to results/. testcontainers removes the container and its
// volumes when the test ends, and Ryuk does when the test is killed. Without
// -scenario it skips.
func TestScenario(t *testing.T) {
	if *scenarioFlag == "" {
		t.Skip("no -scenario; ./e2e.sh <scenario> runs one")
	}
	deadline, ok := t.Deadline()
	if !ok {
		t.Fatal("a run needs go test's -timeout")
	}
	ctx := context.Background()
	c, err := testcontainers.Run(ctx, "",
		testcontainers.WithDockerfile(testcontainers.FromDockerfile{
			Context: "..", Dockerfile: "e2e/Dockerfile", BuildLogWriter: os.Stdout,
			// Kept, so that the next build reuses its layers.
			Repo: "cnpg-evidence-e2e", Tag: "local", KeepImage: true,
		}),
		testcontainers.WithFiles(testcontainers.ContainerFile{
			HostFilePath: "../samples", ContainerFilePath: samplesDir, FileMode: 0o755,
		}),
		testcontainers.WithHostConfigModifier(func(h *moby.HostConfig) { h.Privileged = true }),
		testcontainers.WithCmd(*scenarioFlag),
		testcontainers.WithLogConsumers(&testcontainers.StdoutLogConsumer{}),
		// Its clock starts once the container runs, after the image build. It
		// ends at least 15 min before go test's -timeout, which leaves the
		// build and the copy-out of the results their time.
		testcontainers.WithWaitStrategyAndDeadline(time.Until(deadline)-15*time.Minute, wait.ForExit()),
	)
	testcontainers.CleanupContainer(t, c)
	if c != nil {
		// Cleanups run last first, so this one runs before the container goes.
		t.Cleanup(func() { copyResults(t, c.GetContainerID()) })
	}
	if err != nil {
		t.Fatal(err)
	}
	state, err := c.State(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if state.ExitCode != 0 {
		t.Fatalf("the scenario %s exited with %d: 1 when it failed, 2 when it could not run", *scenarioFlag, state.ExitCode)
	}
}

// copyResults copies the run's files out of the container to results/.
func copyResults(t *testing.T, id string) {
	out, err := exec.Command("docker", "cp", id+":"+resultsDir+"/.", "../results").CombinedOutput()
	if err != nil {
		t.Errorf("copying the results out: %v: %s", err, out)
	}
}
