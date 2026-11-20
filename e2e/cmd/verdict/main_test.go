package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadGaps(t *testing.T) {
	gaps, err := readGaps("../../../variants/first-list/gaps.md")
	if err != nil {
		t.Fatal(err)
	}
	if len(gaps) != 2 || gaps["evidence-tls"] != "the tls part of evidence.sh passes" {
		t.Errorf("first-list: %q", gaps)
	}
	gaps, err = readGaps("../../../variants/every-item/gaps.md")
	if err != nil || len(gaps) != 0 {
		t.Errorf("every-item: %q %v", gaps, err)
	}
}

// cucumber is a cucumber.json with one scenario of the lines, each with
// its status.
func cucumber(lines ...[2]string) string {
	s := `[{"elements": [{"steps": [`
	for i, l := range lines {
		if i > 0 {
			s += ","
		}
		s += `{"name": "` + l[0] + `", "result": {"status": "` + l[1] + `"}}`
	}
	return s + `]}]}]`
}

func TestResults(t *testing.T) {
	const gap = "the tls part of evidence.sh passes"
	passed := cucumber([2]string{"the cluster is healthy", "passed"}, [2]string{gap, "passed"})
	theGap := cucumber([2]string{"the cluster is healthy", "passed"}, [2]string{gap, "failed"})
	always := cucumber([2]string{"the cluster is healthy", "passed"}, [2]string{"every image on the nodes is from the manifest", "passed"})
	failed := func(code, main, always string) map[string]string {
		f := map[string]string{"outcome": "failure\n", "exit-code": code + "\n", "s-1/cucumber.json": main}
		if always != "" {
			f["s-1/always.cucumber.json"] = always
		}
		return f
	}
	for _, c := range []struct {
		name            string
		files           map[string]string
		gap             string
		match           bool
		result, verdict string
	}{
		{"passed", map[string]string{"outcome": "success\n", "exit-code": "0\n", "s-1/cucumber.json": passed}, "", true, "passed", "as expected"},
		{"no artifact", nil, "", false, "no result: the artifact has no outcome", "no result"},
		{"a listed gap passed", map[string]string{"outcome": "success"}, gap, false, "passed", "passed, and gaps.md lists it"},
		{"the gap", failed("1", theGap, always), gap, true,
			"failure, exit code 1, on `" + gap + "`", "the gap, as expected"},
		{"another line", failed("1", cucumber([2]string{"the cluster is healthy", "failed"}, [2]string{gap, "skipped"}), always), gap, false,
			"failure, exit code 1, on `the cluster is healthy`", "not the failure gaps.md names"},
		{"the gap, and always.feature failed", failed("1", theGap,
			cucumber([2]string{"the cluster is healthy", "failed"}, [2]string{"every image on the nodes is from the manifest", "skipped"})), gap, false,
			"failure, exit code 1, on `" + gap + "`, always.feature did not pass `the cluster is healthy`, `every image on the nodes is from the manifest`",
			"not the failure gaps.md names"},
		{"the gap, and a line of always.feature undefined", failed("1", theGap,
			cucumber([2]string{"a new line", "undefined"}, [2]string{"every image on the nodes is from the manifest", "skipped"})), gap, false,
			"failure, exit code 1, on `" + gap + "`, always.feature did not pass `a new line`, `every image on the nodes is from the manifest`",
			"not the failure gaps.md names"},
		{"the gap line undefined", failed("1", cucumber([2]string{"the cluster is healthy", "passed"}, [2]string{gap, "undefined"}), always), gap, false,
			"failure, exit code 1, on `" + gap + " (undefined)`", "not the failure gaps.md names"},
		{"the gap, and the run could not clean up", failed("2", theGap, always), gap, false,
			"failure, exit code 2, on `" + gap + "`", "not the failure gaps.md names"},
		{"the gap line, before always.feature ran", failed("1", theGap, ""), gap, false,
			"failure, exit code 1, on `" + gap + "`, always.feature did not run", "not the failure gaps.md names"},
		{"an empty always.feature report", failed("1", theGap, cucumber()), gap, false,
			"failure, exit code 1, on `" + gap + "`, always.feature did not run", "not the failure gaps.md names"},
		{"a failure gaps.md does not list", failed("1", theGap, always), "", false,
			"failure, exit code 1, on `" + gap + "`", "failed, and gaps.md does not list it"},
		{"failed with no exit code", map[string]string{"outcome": "failure"}, "", false, "no result: failure, with no exit code of the runner", "no result"},
		{"failed with no run", map[string]string{"outcome": "failure", "exit-code": "2"}, "", false, "no result: failure, with no run directory", "no result"},
	} {
		dir := t.TempDir()
		for name, content := range c.files {
			file := filepath.Join(dir, name)
			if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		r := readResult(dir, "s")
		match, verdict := judge(r, c.gap)
		if match != c.match || r.String() != c.result || verdict != c.verdict {
			t.Errorf("%s: got %v %q %q, want %v %q %q", c.name, match, r, verdict, c.match, c.result, c.verdict)
		}
	}
}

// A run's only artifact may be in the results directory itself.
func TestArtifactDir(t *testing.T) {
	results := t.TempDir()
	if got := artifactDir(results, "s-X64", true); got != results {
		t.Errorf("the only artifact, with no directory: %s", got)
	}
	if got := artifactDir(results, "s-X64", false); got != filepath.Join(results, "s-X64") {
		t.Errorf("one of several artifacts: %s", got)
	}
	if err := os.Mkdir(filepath.Join(results, "s-X64"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := artifactDir(results, "s-X64", true); got != filepath.Join(results, "s-X64") {
		t.Errorf("the only artifact, in its directory: %s", got)
	}
}
