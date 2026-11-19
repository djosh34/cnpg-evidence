// Command verdict is the last job of e2e.yml. It compares the result of
// each scenario a run picked with the gaps.md of its variant, and exits
// with 1 when one does not match:
//
//	go -C e2e run ./cmd/verdict -variant first-list -scenarios '["rollout"]' -arches X64 -results ../artifacts
//
// A scenario gaps.md lists must fail on the line gaps.md names, with
// always.feature passed. Every other scenario must pass. The samples have
// no gaps.md: every scenario must pass. A scenario without a result does
// not match. Each result is the artifact <scenario>-<arch> of the run: the
// outcome of its Scenario step in outcome, and the run's files.
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
	for _, arch := range strings.Split(*arches, ",") {
		for _, s := range picked {
			got := readResult(filepath.Join(*results, s+"-"+arch), s)
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
	outcome      string   // of the Scenario step: success, failure, or "" without a result
	failed       []string // its failed lines
	alwaysFailed []string // the failed lines of always.feature
	alwaysRan    bool
	problem      string // why the result could not be read
}

func (r result) String() string {
	switch {
	case r.problem != "":
		return "no result: " + r.problem
	case r.outcome == "success":
		return "passed"
	}
	s := r.outcome
	if len(r.failed) > 0 {
		s += " on `" + strings.Join(r.failed, "`, `") + "`"
	}
	if len(r.alwaysFailed) > 0 {
		s += ", always.feature on `" + strings.Join(r.alwaysFailed, "`, `") + "`"
	}
	return s
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
	runs, err := filepath.Glob(filepath.Join(dir, scenario+"-*"))
	if err != nil || len(runs) != 1 {
		r.problem = r.outcome + ", with no run directory"
		return r
	}
	if r.failed, err = failedLines(filepath.Join(runs[0], "cucumber.json")); err != nil {
		r.problem = r.outcome + ": " + err.Error()
		return r
	}
	r.alwaysFailed, err = failedLines(filepath.Join(runs[0], "always.cucumber.json"))
	r.alwaysRan = err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		r.problem = r.outcome + ": " + err.Error()
	}
	return r
}

// failedLines are the failed lines of a cucumber.json of godog.
func failedLines(file string) ([]string, error) {
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
	var failed []string
	for _, f := range features {
		for _, e := range f.Elements {
			for _, s := range e.Steps {
				if s.Result.Status == "failed" {
					failed = append(failed, s.Name)
				}
			}
		}
	}
	return failed, nil
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
	case r.outcome == "failure" && len(r.failed) == 1 && r.failed[0] == gap && r.alwaysRan && len(r.alwaysFailed) == 0:
		return true, "the gap, as expected"
	}
	return false, "not the failure gaps.md names"
}
