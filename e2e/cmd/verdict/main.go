// Command verdict is the last job of e2e.yml. It compares the result of
// each scenario a run picked with the gaps.md of its variant, and exits
// with 1 when one does not match:
//
//	go -C e2e run ./cmd/verdict -variant first-list -scenarios '["rollout"]' -arches X64 -results ../artifacts
//
// A scenario gaps.md lists must fail on the line gaps.md names and on no
// other, with every line of always.feature passed and the runner's exit
// code 1, which means the scenario failed, not that the run could not run
// or clean up. Every other scenario must pass. The samples have no gaps.md:
// every scenario must pass. A scenario without a result does not match.
// Each result is the artifact <scenario>-<arch> of the run: the outcome of
// its Scenario step in outcome, the runner's exit code in exit-code, and
// the run's files. A run's only artifact may be in -results itself.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

func main() {
	variant := flag.String("variant", "", "the variant of the run; the samples when empty")
	scenarios := flag.String("scenarios", "", "the scenarios the run picked, as a JSON list")
	arches := flag.String("arches", "X64", "the runners' architectures, comma-separated, as runner.arch names them")
	results := flag.String("results", "", "the directory with the run's artifacts, one directory each")
	repo := flag.String("repo", "..", "the checkout, for variants/<variant>/gaps.md")
	flag.Parse()
	var picked []string
	if err := json.Unmarshal([]byte(*scenarios), &picked); err != nil || len(picked) == 0 || *results == "" || flag.NArg() != 0 {
		say(os.Stderr, "verdict: -scenarios needs a JSON list of scenarios, and -results a directory\n")
		os.Exit(2)
	}
	gaps := map[string]string{}
	if *variant != "" {
		var err error
		if gaps, err = readGaps(filepath.Join(*repo, "variants", *variant, "gaps.md")); err != nil {
			say(os.Stderr, "verdict: %v\n", err)
			os.Exit(2)
		}
	}
	say(os.Stdout, "| Scenario | Result | gaps.md | Verdict |\n|---|---|---|---|\n")
	ok := true
	archList := strings.Split(*arches, ",")
	for _, arch := range archList {
		for _, s := range picked {
			got := readResult(artifactDir(*results, s+"-"+arch, len(picked)*len(archList) == 1), s)
			match, why := judge(got, gaps[s])
			ok = ok && match
			want := "passes"
			if line, listed := gaps[s]; listed {
				want = "fails on `" + line + "`"
			}
			say(os.Stdout, "| %s on %s | %s | %s | %s |\n", s, arch, got, want, why)
		}
	}
	if !ok {
		say(os.Stdout, "\nA result does not match gaps.md (docs/e2e.md).\n")
		os.Exit(1)
	}
}

// say prints, and exits with 2 when it cannot.
func say(w io.Writer, format string, args ...any) {
	if _, err := fmt.Fprintf(w, format, args...); err != nil {
		os.Exit(2)
	}
}

// readGaps reads the rows of a gaps.md table: each scenario's failed line,
// the first `quoted` text of its second column.
func readGaps(file string) (map[string]string, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	gaps := map[string]string{}
	quoted := regexp.MustCompile("`([^`]+)`")
	for _, line := range strings.Split(string(data), "\n") {
		cells := strings.Split(line, "|")
		if !strings.HasPrefix(line, "| `") || len(cells) < 3 {
			continue
		}
		scenario := strings.Trim(strings.TrimSpace(cells[1]), "`")
		failed := quoted.FindStringSubmatch(cells[2])
		if failed == nil {
			return nil, fmt.Errorf("%s: the row of %s names no failed line", file, scenario)
		}
		gaps[scenario] = failed[1]
	}
	return gaps, nil
}

// result is what a scenario's artifact says.
type result struct {
	outcome  string // of the Scenario step: success or failure
	exitCode string // of the runner: 0 passed, 1 failed, 2 could not run
	// The lines of the scenario that did not pass and were not skipped,
	// each with its status unless it failed, and those of always.feature
	// that did not pass.
	failed, alwaysNotPassed []string
	alwaysRan               bool
	problem                 string // why the result could not be read
}

func (r result) String() string {
	switch {
	case r.problem != "":
		return "no result: " + r.problem
	case r.outcome == "success":
		return "passed"
	}
	s := r.outcome + ", exit code " + r.exitCode
	if len(r.failed) > 0 {
		s += ", on `" + strings.Join(r.failed, "`, `") + "`"
	}
	if !r.alwaysRan {
		s += ", always.feature did not run"
	}
	if len(r.alwaysNotPassed) > 0 {
		s += ", always.feature did not pass `" + strings.Join(r.alwaysNotPassed, "`, `") + "`"
	}
	return s
}

// artifactDir is the directory of the artifact name in results. When a run
// has only one artifact, download-artifact puts its files in results
// itself, with no directory of its name.
func artifactDir(results, name string, only bool) string {
	dir := filepath.Join(results, name)
	if _, err := os.Stat(dir); err != nil && only {
		return results
	}
	return dir
}

func readResult(dir, scenario string) result {
	data, err := os.ReadFile(filepath.Join(dir, "outcome"))
	if err != nil {
		return result{problem: "the artifact has no outcome"}
	}
	r := result{outcome: strings.TrimSpace(string(data))}
	if r.outcome == "success" {
		return r
	}
	if data, err = os.ReadFile(filepath.Join(dir, "exit-code")); err != nil {
		r.problem = r.outcome + ", with no exit code of the runner"
		return r
	}
	r.exitCode = strings.TrimSpace(string(data))
	runs, err := filepath.Glob(filepath.Join(dir, scenario+"-*"))
	if err != nil || len(runs) != 1 {
		r.problem = r.outcome + ", with no run directory"
		return r
	}
	main, err := readSteps(filepath.Join(runs[0], "cucumber.json"))
	if err != nil {
		r.problem = r.outcome + ": " + err.Error()
		return r
	}
	// A line that is neither passed, failed nor skipped, such as undefined,
	// keeps its status, so it never reads as the gap's failed line.
	for _, s := range main {
		switch s.status {
		case "passed", "skipped":
		case "failed":
			r.failed = append(r.failed, s.name)
		default:
			r.failed = append(r.failed, s.name+" ("+s.status+")")
		}
	}
	always, err := readSteps(filepath.Join(runs[0], "always.cucumber.json"))
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		r.problem = r.outcome + ": " + err.Error()
	default:
		r.alwaysRan = len(always) > 0
		for _, s := range always {
			if s.status != "passed" {
				r.alwaysNotPassed = append(r.alwaysNotPassed, s.name)
			}
		}
	}
	return r
}

// step is a line of a cucumber.json of godog, with its status: passed,
// failed, skipped, undefined, pending or ambiguous.
type step struct{ name, status string }

func readSteps(file string) ([]step, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	var features []struct {
		Elements []struct {
			Steps []struct {
				Name   string `json:"name"`
				Result struct {
					Status string `json:"status"`
				} `json:"result"`
			} `json:"steps"`
		} `json:"elements"`
	}
	if err := json.Unmarshal(data, &features); err != nil {
		return nil, fmt.Errorf("%s: %w", filepath.Base(file), err)
	}
	var steps []step
	for _, f := range features {
		for _, e := range f.Elements {
			for _, s := range e.Steps {
				steps = append(steps, step{s.Name, s.Result.Status})
			}
		}
	}
	return steps, nil
}

// judge says whether a result matches gaps.md, which lists gap as the
// scenario's failed line, or does not list it when gap is "".
func judge(r result, gap string) (bool, string) {
	switch {
	case r.problem != "":
		return false, "no result"
	case gap == "" && r.outcome == "success":
		return true, "as expected"
	case gap == "":
		return false, "failed, and gaps.md does not list it"
	case r.outcome == "success":
		return false, "passed, and gaps.md lists it"
	case r.outcome == "failure" && r.exitCode == "1" && len(r.failed) == 1 && r.failed[0] == gap &&
		r.alwaysRan && len(r.alwaysNotPassed) == 0:
		return true, "the gap, as expected"
	}
	return false, "not the failure gaps.md names"
}
