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
//
// With -record, it also writes each result, the verdict and every image the
// runs saw on the nodes, from each run's images.txt, to a YAML file, which
// nightly.yml publishes.
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
	"slices"
	"strings"

	"go.yaml.in/yaml/v3"
)

func main() {
	variant := flag.String("variant", "", "the variant of the run; the samples when empty")
	scenarios := flag.String("scenarios", "", "the scenarios the run picked, as a JSON list")
	arches := flag.String("arches", "X64", "the runners' architectures, comma-separated, as runner.arch names them")
	results := flag.String("results", "", "the directory with the run's artifacts, one directory each")
	repo := flag.String("repo", "..", "the checkout, for variants/<variant>/gaps.md")
	recordFile := flag.String("record", "", "a YAML file to write each result, the verdict and the images to")
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
	var rec record
	archList := strings.Split(*arches, ",")
	for _, arch := range archList {
		for _, s := range picked {
			dir := artifactDir(*results, s+"-"+arch, len(picked)*len(archList) == 1)
			got := readResult(dir, s)
			match, why := judge(got, gaps[s])
			ok = ok && match
			want := "passes"
			if line, listed := gaps[s]; listed {
				want = "fails on `" + line + "`"
			}
			say(os.Stdout, "| %s on %s | %s | %s | %s |\n", s, arch, got, want, why)
			rec.Results = append(rec.Results, row{s, arch, got.String(), want, why})
			images, err := readImages(dir, s)
			if err != nil {
				say(os.Stderr, "verdict: %v\n", err)
				os.Exit(2)
			}
			rec.Images = append(rec.Images, images...)
		}
	}
	if *recordFile != "" {
		rec.Verdict = map[bool]string{true: "green", false: "red"}[ok]
		if err := rec.write(*recordFile); err != nil {
			say(os.Stderr, "verdict: %v\n", err)
			os.Exit(2)
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

// record is what -record writes.
type record struct {
	Verdict string   `yaml:"verdict"` // green when every result matches gaps.md, else red
	Results []row    `yaml:"results"`
	Images  []string `yaml:"images"` // every image the runs saw on the nodes, each tag and digest
}

// row is a row of the table.
type row struct {
	Scenario string `yaml:"scenario"`
	Arch     string `yaml:"arch"`
	Result   string `yaml:"result"`
	Expected string `yaml:"expected"` // what gaps.md says
	Verdict  string `yaml:"verdict"`
}

func (r record) write(file string) error {
	slices.Sort(r.Images)
	r.Images = slices.Compact(r.Images)
	out, err := yaml.Marshal(r)
	if err != nil {
		return err
	}
	return os.WriteFile(file, out, 0o644)
}

// readImages reads the images.txt of a scenario's run in its artifact, one
// image per line: those the run's checks saw and those on the nodes at its
// end. A run that never started a node has none.
func readImages(dir, scenario string) ([]string, error) {
	files, err := filepath.Glob(filepath.Join(dir, scenario+"-*", "images.txt"))
	if err != nil {
		return nil, err
	}
	var images []string
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		for _, line := range strings.Split(string(data), "\n") {
			if line = strings.TrimSpace(line); line != "" {
				images = append(images, line)
			}
		}
	}
	return images, nil
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
