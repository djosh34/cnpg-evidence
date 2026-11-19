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
	for _, c := range []struct {
		name            string
		files           map[string]string
		gap             string
		match           bool
		result, verdict string
	}{
		{"passed", map[string]string{"outcome": "success\n"}, "", true, "passed", "as expected"},
		{"no artifact", nil, "", false, "no result: the artifact has no outcome", "no result"},
		{"a listed gap passed", map[string]string{"outcome": "success"}, gap, false, "passed", "passed, and gaps.md lists it"},
		{"the gap", map[string]string{
			"outcome":                  "failure",
			"s-1/cucumber.json":        cucumber([2]string{"the cluster is healthy", "passed"}, [2]string{gap, "failed"}),
			"s-1/always.cucumber.json": cucumber([2]string{"the cluster is healthy", "passed"}),
		}, gap, true, "failure on `" + gap + "`", "the gap, as expected"},
		{"another line", map[string]string{
			"outcome":                  "failure",
			"s-1/cucumber.json":        cucumber([2]string{"the cluster is healthy", "failed"}, [2]string{gap, "skipped"}),
			"s-1/always.cucumber.json": cucumber(),
		}, gap, false, "failure on `the cluster is healthy`", "not the failure gaps.md names"},
		{"the gap, and always.feature failed", map[string]string{
			"outcome":                  "failure",
			"s-1/cucumber.json":        cucumber([2]string{gap, "failed"}),
			"s-1/always.cucumber.json": cucumber([2]string{"every image on the nodes is from the manifest", "failed"}),
		}, gap, false, "failure on `" + gap + "`, always.feature on `every image on the nodes is from the manifest`", "not the failure gaps.md names"},
		{"the gap line, before always.feature ran", map[string]string{
			"outcome":           "failure",
			"s-1/cucumber.json": cucumber([2]string{gap, "failed"}),
		}, gap, false, "failure on `" + gap + "`", "not the failure gaps.md names"},
		{"a failure gaps.md does not list", map[string]string{
			"outcome":           "failure",
			"s-1/cucumber.json": cucumber([2]string{gap, "failed"}),
		}, "", false, "failure on `" + gap + "`", "failed, and gaps.md does not list it"},
		{"failed with no run", map[string]string{"outcome": "failure"}, "", false, "no result: failure, with no run directory", "no result"},
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
