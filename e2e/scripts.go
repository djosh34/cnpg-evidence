package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/cucumber/godog"
	messages "github.com/cucumber/messages/go/v34"
)

// The words of the vocabulary about the scripts of the repository:
// desired.sh, evidence.sh and prove.sh, run as docs/evidence.md and
// docs/prove.md say, and host-check.sh on every node. The e2e image has
// the scripts under scriptsDir, and under nodeTools a static bash and jq,
// which it copies onto a node for host-check.sh: the k3s image has neither.
const (
	scriptsDir = "/opt/cnpg-evidence/scripts"
	nodeTools  = "/opt/cnpg-evidence/node"
)

// scriptRun is what a script printed and its exit code, 0 or 1.
type scriptRun struct {
	out  string
	code int
}

// runScript runs a program with stdin and the e2e test's kubeconfig. An exit
// code of 0 or 1 is a result; any other, as the scripts' 2 for an error, is
// an error with the end of what the program printed on stderr.
func runScript(ctx context.Context, stdin, name string, args ...string) (scriptRun, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	cmd.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return scriptRun{out: stdout.String()}, nil
	case errors.As(err, &exit) && exit.ExitCode() == 1:
		return scriptRun{out: stdout.String(), code: 1}, nil
	}
	lines := strings.Split(strings.TrimSpace(stderr.String()), "\n")
	return scriptRun{}, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err,
		strings.Join(lines[max(0, len(lines)-5):], " | "))
}

// script runs a script of scriptsDir with bash.
func script(ctx context.Context, stdin, path string, args ...string) (scriptRun, error) {
	return runScript(ctx, stdin, "bash", append([]string{filepath.Join(scriptsDir, path)}, args...)...)
}

// desiredValues are the values of the cluster's release, desired.yaml of
// the settings with the e2e test's own values/pg.yaml on top, as
// JSON, which the scripts take on stdin.
func desiredValues(ctx context.Context) (string, error) {
	return helm(ctx, time.Minute, "get", "values", clusterRelease, "--namespace", namespace, "--output", "json")
}

// clientCA writes the CA certificates of the Secret client-ca, which may
// sign client certificates, to a file, for --ca.
func clientCA(ctx context.Context) (string, error) {
	out, err := kubectl(ctx, "get", "secret", "client-ca", "-n", namespace, "-o", `jsonpath={.data.ca\.crt}`)
	if err != nil {
		return "", err
	}
	pem, err := base64.StdEncoding.DecodeString(out)
	if err != nil {
		return "", fmt.Errorf("ca.crt of client-ca: %w", err)
	}
	file := filepath.Join(workDir, "client-ca.pem")
	return file, os.WriteFile(file, pem, 0o600)
}

// keep keeps what a script gave, for the lines after it and in the results.
func (s *scenario) keep(key, file string, r scriptRun) error {
	s.scripts[key] = r
	return s.results.write(file, r.out)
}

// runDesired: desired.sh makes the desired documents of evidence.sh and
// prove.sh.
func runDesired(ctx context.Context, s *scenario, _ args) error {
	values, err := desiredValues(ctx)
	if err != nil {
		return err
	}
	ca, err := clientCA(ctx)
	if err != nil {
		return err
	}
	for source, args := range map[string][]string{
		"evidence": {"--source", "evidence", "--ca", ca},
		"prove":    {"--source", "prove"},
	} {
		r, err := script(ctx, values, "desired/desired.sh", args...)
		if err == nil && r.code != 0 {
			err = fmt.Errorf("desired.sh --source %s exited with 1", source)
		}
		if err != nil {
			return err
		}
		if err := s.keep("desired.sh "+source, source+".desired.json", r); err != nil {
			return err
		}
	}
	return nil
}

// runEvidence: evidence.sh, from the e2e test, with the CA of client-ca.
func runEvidence(ctx context.Context, s *scenario, _ args) error {
	values, err := desiredValues(ctx)
	if err != nil {
		return err
	}
	ca, err := clientCA(ctx)
	if err != nil {
		return err
	}
	r, err := script(ctx, values, "evidence/evidence.sh", "--ca", ca)
	if err != nil {
		return err
	}
	return s.keep("evidence.sh", "evidence.json", r)
}

// evidencePasses: evidence.sh found no violation.
func evidencePasses(_ context.Context, s *scenario, _ args) error {
	r, ok := s.scripts["evidence.sh"]
	if !ok {
		return errors.New("evidence.sh did not run")
	}
	var doc struct {
		Violations []struct {
			Sentence string `json:"sentence"`
		} `json:"violations"`
	}
	if err := json.Unmarshal([]byte(r.out), &doc); err != nil {
		return fmt.Errorf("the output of evidence.sh: %w", err)
	}
	if r.code != 0 || len(doc.Violations) > 0 {
		var sentences []string
		for _, v := range doc.Violations {
			sentences = append(sentences, v.Sentence)
		}
		return fmt.Errorf("evidence.sh exited with %d, violations: %s", r.code, strings.Join(sentences, "; "))
	}
	s.detail = "no violations"
	return nil
}

// runProve: prove.sh as root on every node, which the e2e test sees through
// /proc/<pid>/root of the node's container.
func runProve(ctx context.Context, s *scenario, _ args) error {
	values, err := desiredValues(ctx)
	if err != nil {
		return err
	}
	for i := range nodeCount {
		node := nodeName(i)
		pid, err := command(ctx, "docker", "inspect", "-f", "{{.State.Pid}}", node)
		if err != nil {
			return err
		}
		r, err := script(ctx, values, "prove/prove.sh", "--node", node, "--node-root", "/proc/"+pid+"/root")
		if err != nil {
			return err
		}
		if err := s.keep("prove.sh "+node, "prove."+node+".json", r); err != nil {
			return err
		}
	}
	return nil
}

// A probe of prove.sh.
type probe struct {
	Probe string `json:"probe"`
	Value any    `json:"value"`
	OK    bool   `json:"ok"`
	Raw   any    `json:"raw"`
}

func probesOf(out string) ([]probe, error) {
	var doc struct {
		Probes []probe `json:"probes"`
	}
	err := json.Unmarshal([]byte(out), &doc)
	return doc.Probes, err
}

// provePasses: on every node, prove.sh passed, with every probe of the
// desired document and its value, and no other.
func provePasses(_ context.Context, s *scenario, _ args) error {
	desired, ok := s.scripts["desired.sh prove"]
	if !ok {
		return errors.New("desired.sh did not run")
	}
	want, err := probesOf(desired.out)
	if err != nil {
		return fmt.Errorf("the desired document of prove.sh: %w", err)
	}
	values := func(probes []probe) string {
		var list []string
		for _, p := range probes {
			value, err := json.Marshal(p.Value)
			if err != nil {
				value = []byte(err.Error())
			}
			list = append(list, p.Probe+"="+string(value))
		}
		return strings.Join(list, ", ")
	}
	for i := range nodeCount {
		node := nodeName(i)
		r, ok := s.scripts["prove.sh "+node]
		if !ok {
			return fmt.Errorf("prove.sh did not run on %s", node)
		}
		got, err := probesOf(r.out)
		if err != nil {
			return fmt.Errorf("the output of prove.sh on %s: %w", node, err)
		}
		if r.code != 0 || values(got) != values(want) {
			var failed []string
			for _, p := range got {
				if !p.OK {
					failed = append(failed, fmt.Sprintf("%s: %v", p.Probe, p.Raw))
				}
			}
			return fmt.Errorf("prove.sh on %s exited with %d; failed: %s; probes and values %s, wanted %s",
				node, r.code, strings.Join(failed, "; "), values(got), values(want))
		}
	}
	s.detail = fmt.Sprintf("%d probes on each node, all as desired", len(want))
	return nil
}

// runHostCheck: host-check.sh as root on every node, with the static bash
// and jq of the e2e image. /tmp of a node is a tmpfs, which docker cp does
// not reach, so the scripts go under /opt.
func runHostCheck(ctx context.Context, s *scenario, _ args) error {
	const dir = "/opt/cnpg-evidence/scripts"
	for i := range nodeCount {
		node := nodeName(i)
		copies := [][]string{
			{"exec", node, "mkdir", "-p", dir},
			{"cp", "-q", filepath.Join(nodeTools, "bash"), node + ":/bin/bash"},
			{"cp", "-q", filepath.Join(nodeTools, "jq"), node + ":/bin/jq"},
			{"cp", "-q", filepath.Join(scriptsDir, "host-check"), node + ":" + dir + "/host-check"},
			{"cp", "-q", filepath.Join(scriptsDir, "lib"), node + ":" + dir + "/lib"},
		}
		for _, c := range copies {
			if _, err := command(ctx, "docker", c...); err != nil {
				return err
			}
		}
		r, err := runScript(ctx, "", "docker", "exec", node, "bash", dir+"/host-check/host-check.sh", "--node", node)
		if err != nil {
			return err
		}
		if err := s.keep("host-check.sh "+node, "host-check."+node+".json", r); err != nil {
			return err
		}
	}
	return nil
}

// hostCheckFails: on every node, each check of the table fails with the
// table's value. The checks the table does not name are not looked at.
func (s *scenario) hostCheckFails(table *godog.Table) error {
	want, err := s.hostCheckTable(table, true)
	if err != nil {
		return err
	}
	for i := range nodeCount {
		node := nodeName(i)
		checks, err := s.hostChecks(node)
		if err != nil {
			return err
		}
		var wrong []string
		for _, id := range slices.Sorted(maps.Keys(want)) {
			c, ok := checks[id]
			switch {
			case !ok:
				wrong = append(wrong, id+" did not run")
			case c.OK:
				wrong = append(wrong, id+" passed: "+c.Value)
			case c.Value != want[id]:
				wrong = append(wrong, id+" failed with "+c.Value+", not "+want[id])
			}
		}
		if len(wrong) > 0 {
			return fmt.Errorf("on %s: %s", node, strings.Join(wrong, "; "))
		}
	}
	s.detail = fmt.Sprintf("%d checks failed on each node with the listed values", len(want))
	return nil
}

// hostCheckPassesBut: on every node, each check the table does not name
// passes. Each check the table names must exist, so a typo shows.
func (s *scenario) hostCheckPassesBut(table *godog.Table) error {
	skip, err := s.hostCheckTable(table, false)
	if err != nil {
		return err
	}
	passed := 0
	for i := range nodeCount {
		node := nodeName(i)
		checks, err := s.hostChecks(node)
		if err != nil {
			return err
		}
		var wrong []string
		for _, id := range slices.Sorted(maps.Keys(skip)) {
			if _, ok := checks[id]; !ok {
				wrong = append(wrong, id+" did not run")
			}
		}
		for _, id := range slices.Sorted(maps.Keys(checks)) {
			if _, skipped := skip[id]; skipped {
				continue
			}
			if !checks[id].OK {
				wrong = append(wrong, id+" failed: "+checks[id].Value)
				continue
			}
			passed++
		}
		if len(wrong) > 0 {
			return fmt.Errorf("on %s: %s", node, strings.Join(wrong, "; "))
		}
	}
	s.detail = fmt.Sprintf("%d other checks passed on %d nodes", passed, nodeCount)
	return nil
}

// hostCheckTable: the rows of a host-check table, the check by its value.
// The first row names the columns: check, value when withValue, and any
// others, such as why.
func (s *scenario) hostCheckTable(table *godog.Table, withValue bool) (map[string]string, error) {
	if s.kind != messages.PickleStepType_OUTCOME {
		return nil, errors.New("a check in a Given or When line")
	}
	if len(table.Rows) < 2 {
		return nil, errors.New("the table has no checks")
	}
	column := map[string]int{}
	for i, cell := range table.Rows[0].Cells {
		column[cell.Value] = i
	}
	checkCol, okCheck := column["check"]
	valueCol, okValue := column["value"]
	if !okCheck {
		return nil, errors.New("the table has no column check")
	}
	if withValue && !okValue {
		return nil, errors.New("the table has no column value")
	}
	rows := map[string]string{}
	for _, row := range table.Rows[1:] {
		value := ""
		if withValue {
			value = row.Cells[valueCol].Value
		}
		rows[row.Cells[checkCol].Value] = value
	}
	return rows, nil
}

// hostCheck is one check of the output of host-check.sh.
type hostCheck struct {
	ID    string `json:"id"`
	OK    bool   `json:"ok"`
	Value string `json:"value"`
}

// hostChecks: the checks host-check.sh gave on a node, by id.
func (s *scenario) hostChecks(node string) (map[string]hostCheck, error) {
	r, ok := s.scripts["host-check.sh "+node]
	if !ok {
		return nil, fmt.Errorf("host-check.sh did not run on %s", node)
	}
	var doc struct {
		Checks []hostCheck `json:"checks"`
	}
	if err := json.Unmarshal([]byte(r.out), &doc); err != nil {
		return nil, fmt.Errorf("the output of host-check.sh on %s: %w", node, err)
	}
	if len(doc.Checks) == 0 {
		return nil, fmt.Errorf("host-check.sh gave no checks on %s", node)
	}
	checks := map[string]hostCheck{}
	for _, c := range doc.Checks {
		checks[c.ID] = c
	}
	return checks, nil
}
