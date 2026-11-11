package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	gherkin "github.com/cucumber/gherkin/go/v42"
	messages "github.com/cucumber/messages/go/v34"
)

func TestParseLog(t *testing.T) {
	log := parseLog(strings.Join([]string{
		"1000 1100 read k3s-1.example.test:5432 ok 10.42.0.5 recovery=false",
		"1000 1200 write k3s-1.example.test:5432 ok 17 10.42.0.5",
		"client: creating bench_writes: no route",
		"1250 1300 write k3s-2.example.test:5433 fail ERROR: cannot execute INSERT in a read-only transaction",
		"1300 1310 connect k3s-3.example.test:5432 ok ",
		"1500 1600 writes - stopped ",
	}, "\n"))
	if len(log.lines) != 5 {
		t.Fatalf("lines: got %d, want 5", len(log.lines))
	}
	if n, server := log.lines[1].write(); n != "17" || server != "10.42.0.5" {
		t.Errorf("write: got %q %q, want 17 10.42.0.5", n, server)
	}
	if !log.connected("k3s-3.example.test:5432") || log.connected("k3s-1.example.test:5432") {
		t.Error("connected: want only k3s-3.example.test:5432")
	}
	if got := log.acknowledged(); len(got) != 1 || got[0] != "17" {
		t.Errorf("acknowledged: got %v, want [17]", got)
	}
	if first, ok := log.first("write"); !ok || first.UnixMilli() != 1200 {
		t.Errorf("first write: got %v %v, want 1200", first.UnixMilli(), ok)
	}
	if stopped, ok := log.writesStopped(); !ok || stopped.UnixMilli() != 1500 {
		t.Errorf("writes stopped: got %v %v, want 1500", stopped.UnixMilli(), ok)
	}
	if log.tail != "client: creating bench_writes: no route" {
		t.Errorf("tail: got %q", log.tail)
	}
}

func TestLongestGap(t *testing.T) {
	ms := func(n int64) time.Time { return time.UnixMilli(n) }
	log := parseLog(strings.Join([]string{
		"0 1000 read h:5432 ok a",
		// Attempts run side by side: this one ended last but is logged first.
		"2000 9000 read h:5432 ok a",
		"3000 3500 read h:5432 ok a",
		"4000 4100 read - fail timeout",
		"4000 4200 write h:5432 ok 1 a",
	}, "\n"))
	tests := []struct {
		name     string
		from, to int64
		want     time.Duration
	}{
		{"between reads", 1000, 9500, 5500 * time.Millisecond},
		{"to the end", 1000, 20000, 11000 * time.Millisecond},
		{"from the start", 0, 1000, time.Second},
		{"nothing in the window", 10000, 12000, 2 * time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := log.longestGap("read", ms(tt.from), ms(tt.to)); got != tt.want {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestReadReleases(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "releases.yaml")
	write := func(content string) {
		if err := os.WriteFile(file, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("- name: pg\n  namespace: databases\n  chart: cnpg-cluster\n  values: [desired.yaml]\n")
	got, err := readReleases(file)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Chart != "cnpg-cluster" || len(got[0].Values) != 1 {
		t.Errorf("got %+v", got)
	}
	write("- name: pg\n  chart: cnpg-cluster\n")
	if _, err := readReleases(file); err == nil {
		t.Error("a release without namespace: no error")
	}
}

func TestLookup(t *testing.T) {
	s := &scenario{roles: map[string]string{"the primary": "pg-1", "replica 1": "pg-2", "replica 2": "pg-3"}}
	key, a, err := s.lookup("replica 1", "promoted")
	if err != nil || key != "<role> | promoted" || len(a.pods) != 1 || a.pods[0] != "pg-2" {
		t.Errorf("replica 1 is promoted: got %q %v %v", key, a.pods, err)
	}
	key, a, err = s.lookup("another instance", "primary")
	if err != nil || key != "<role> | primary" || a.pods[0] != anotherInstance {
		t.Errorf("another instance is primary: got %q %v %v", key, a.pods, err)
	}
	if _, _, err := s.lookup("replica 1", "kiled"); err == nil {
		t.Error("a word not in the vocabulary: no error")
	}
	if _, _, err := s.lookup("the new primary", "primary"); err == nil {
		t.Error("the new primary before any change: no error")
	}
	key, a, err = s.lookup("1229 MB of WAL", "written on the primary")
	if err != nil || key != "<n> MB of WAL | written on <role>" || len(a.ns) != 1 || a.ns[0] != 1229 || a.pods[0] != "pg-1" {
		t.Errorf("1229 MB of WAL is written on the primary: got %q %v %v %v", key, a.ns, a.pods, err)
	}
	key, a, err = s.lookup("wal_keep_size", "set to 64MB")
	if err != nil || key != "wal_keep_size | set to <n>MB" || a.ns[0] != 64 {
		t.Errorf("wal_keep_size is set to 64MB: got %q %v %v", key, a.ns, err)
	}
}

func TestNewPrimary(t *testing.T) {
	s := &scenario{roles: map[string]string{"the primary": "pg-1", "replica 1": "pg-2", "replica 2": "pg-3", "a replica": "pg-2"}}
	s.newPrimary("pg-2")
	if s.roles["the new primary"] != "pg-2" || s.roles["a replica"] != "pg-1" {
		t.Errorf("after pg-2 became primary: %v", s.roles)
	}
	s.newPrimary("pg-1")
	if s.roles["the new primary"] != "pg-1" || s.roles["a replica"] != "pg-2" {
		t.Errorf("after pg-1 became primary: %v", s.roles)
	}
}

// Every line of the feature files in samples/features binds to exactly one
// line shape, every "is", "has been" and verb line is in the vocabulary, and
// every alert line names a role.
func TestFeaturesUseTheVocabulary(t *testing.T) {
	shapes := map[string]*regexp.Regexp{
		"is": regexp.MustCompile(isLine), "since": regexp.MustCompile(sinceLine), "verb": regexp.MustCompile(verbLine),
		"pass": regexp.MustCompile(passLine), "alert": regexp.MustCompile(alertLine),
		"alertmanager": regexp.MustCompile(amLine), "quiet": regexp.MustCompile(quietLine),
		"table": regexp.MustCompile(tableLine),
	}
	files, err := filepath.Glob("../samples/features/*.feature")
	if err != nil || len(files) == 0 {
		t.Fatalf("no feature files: %v", err)
	}
	s := &scenario{roles: map[string]string{
		"the primary": "pg-1", "replica 1": "pg-2", "replica 2": "pg-3", "the new primary": "pg-2", "a replica": "pg-1",
	}}
	id := 0
	newID := func() string { id++; return strconv.Itoa(id) }
	for _, file := range files {
		f, err := os.Open(file)
		if err != nil {
			t.Fatal(err)
		}
		doc, err := gherkin.ParseGherkinDocument(f, newID)
		if err := closeWith(err, f); err != nil {
			t.Fatalf("%s: %v", file, err)
		}
		for _, pickle := range gherkin.Pickles(*doc, file, newID) {
			for _, step := range pickle.Steps {
				var matched []string
				for name, re := range shapes {
					if m := re.FindStringSubmatch(step.Text); m != nil {
						matched = append(matched, name)
						var err error
						switch name {
						case "is", "verb", "since":
							_, _, err = s.lookup(m[1], m[2])
						case "alert":
							_, err = s.alertPod(m[3])
						case "alertmanager":
							_, err = s.role(m[3])
						}
						if err != nil {
							t.Errorf("%s: %q: %v", file, step.Text, err)
						}
					}
				}
				if len(matched) != 1 {
					t.Errorf("%s: %q matches %v, want one line shape", file, step.Text, matched)
				}
				if step.Type == messages.PickleStepType_UNKNOWN {
					t.Errorf("%s: %q has no keyword", file, step.Text)
				}
			}
		}
	}
}
