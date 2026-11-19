package main

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/djosh34/cnpg-evidence/e2e/versions"
	moby "github.com/moby/moby/api/types/container"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// The manifest of versions/ a run uses when it names none. e2e.yml has the
// same default.
const defaultManifest = "v1.33.yaml"

var (
	scenarioFlag = flag.String("scenario", "", "the scenario to run: its tag, without the @")
	variantFlag  = flag.String("variant", "", "the variant to apply: a directory of variants/; the samples when empty")
	manifestFlag = flag.String("manifest", "", "the manifest: a file of versions/; "+defaultManifest+" when empty")
)

// TestScenario runs one scenario, as ./e2e.sh does. It builds e2e/Dockerfile
// from this checkout for the machine's own architecture, with the tools of
// the manifest, copies the settings and the manifest in and runs the image
// as one privileged container. The settings are samples/, or
// samples/features and variants/<variant> with -variant. The manifest is
// the one file of versions/ that -manifest names, so it may be a symlink.
// Its last step copies the run's files out to results/. testcontainers
// removes the container and its volumes when the test ends, and Ryuk does
// when the test is killed. Without -scenario it skips.
func TestScenario(t *testing.T) {
	if *scenarioFlag == "" {
		t.Skip("no -scenario; ./e2e.sh <scenario> runs one")
	}
	name := cmp.Or(*manifestFlag, defaultManifest)
	if name != filepath.Base(name) || filepath.Ext(name) != ".yaml" {
		t.Fatalf("%q is not a manifest: the name of a .yaml file of versions/", name)
	}
	manifestPath := filepath.Join("..", "versions", name)
	m, err := versions.Load(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("the manifest %s: k3s %s", manifestPath, m.K3s.Version)
	// One file, so testcontainers follows a symlink such as latest.yaml.
	manifestCopy := testcontainers.ContainerFile{HostFilePath: manifestPath, ContainerFilePath: manifestFile, FileMode: 0o644}
	files := []testcontainers.ContainerFile{
		{HostFilePath: "../samples", ContainerFilePath: samplesDir, FileMode: 0o755}, manifestCopy,
	}
	cmd := []string{*scenarioFlag}
	if *variantFlag != "" {
		dir := filepath.Join("..", "variants", *variantFlag)
		if !scenarioTag.MatchString(*variantFlag) {
			t.Fatalf("%q is not a variant name: lower-case words with dashes", *variantFlag)
		}
		if slices.Contains(notInVariants, *scenarioFlag) {
			t.Fatalf("a variant run leaves out %s; docs/e2e.md says why", *scenarioFlag)
		}
		if _, err := os.Stat(filepath.Join(dir, "charts", "releases.yaml")); err != nil {
			t.Fatalf("no variant %s: %v", *variantFlag, err)
		}
		if err := noSymlinks(dir); err != nil {
			t.Fatal(err)
		}
		// The parents /samples and /variants are in the image, so each
		// directory lands at its own name.
		files = []testcontainers.ContainerFile{
			{HostFilePath: "../samples/features", ContainerFilePath: filepath.Join(samplesDir, "features"), FileMode: 0o755},
			{HostFilePath: dir, ContainerFilePath: filepath.Join(variantsDir, *variantFlag), FileMode: 0o755},
			manifestCopy,
		}
		cmd = append(cmd, *variantFlag)
	}
	deadline, ok := t.Deadline()
	if !ok {
		t.Fatal("a run needs go test's -timeout")
	}
	ctx := context.Background()
	c, err := testcontainers.Run(ctx, "",
		testcontainers.WithDockerfile(testcontainers.FromDockerfile{
			Context: "..", Dockerfile: "e2e/Dockerfile", BuildLogWriter: os.Stdout, BuildArgs: toolArgs(m.Tools),
			// Kept, so that the next build reuses its layers.
			Repo: "cnpg-evidence-e2e", Tag: "local", KeepImage: true,
		}),
		testcontainers.WithFiles(files...),
		testcontainers.WithHostConfigModifier(func(h *moby.HostConfig) { h.Privileged = true }),
		testcontainers.WithCmd(cmd...),
		testcontainers.WithLogConsumers(&testcontainers.StdoutLogConsumer{}),
		// Its clock starts once the container runs, after the image build, so
		// the 15 min it leaves before go test's -timeout are for the build
		// and the copy-out of the results.
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

// toolArgs are the build arguments of e2e/Dockerfile with the manifest's
// tools.
func toolArgs(t versions.Tools) map[string]*string {
	return map[string]*string{
		"KUBECTL_VERSION":      &t.Kubectl.Version,
		"KUBECTL_SHA256_AMD64": ptr(t.Kubectl.SHA256["amd64"]),
		"KUBECTL_SHA256_ARM64": ptr(t.Kubectl.SHA256["arm64"]),
		"CNPG_VERSION":         &t.KubectlCNPG.Version,
		"CNPG_SHA256_AMD64":    ptr(t.KubectlCNPG.SHA256["amd64"]),
		"CNPG_SHA256_ARM64":    ptr(t.KubectlCNPG.SHA256["arm64"]),
		"ROTATE_CA_URL":        &t.RotateCA.URL,
		"ROTATE_CA_SHA256":     &t.RotateCA.SHA256,
	}
}

func ptr(s string) *string { return &s }

// noSymlinks fails on a symlink in dir: testcontainers would leave it out of
// the copy without a word.
func noSymlinks(dir string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && d.Type()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symlink; a variant needs real files", path)
		}
		return err
	})
}

// copyResults copies the run's files out of the container to results/.
func copyResults(t *testing.T, id string) {
	out, err := exec.Command("docker", "cp", id+":"+resultsDir+"/.", "../results").CombinedOutput()
	if err != nil {
		t.Errorf("copying the results out: %v: %s", err, out)
	}
}
