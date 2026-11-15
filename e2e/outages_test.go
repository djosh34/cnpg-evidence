package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// fakeTools puts a docker and a kubectl first on PATH that only record how
// they were called; kubectl answers that every pod runs on k3s-1. It
// returns what they were called with since the last call.
func fakeTools(t *testing.T) func() []string {
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	tool := "#!/bin/sh\necho \"${0##*/} $*\" >>" + calls + "\ncase \"$*\" in *spec.nodeName*) echo k3s-1 ;; esac\n"
	for _, name := range []string{"docker", "kubectl"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(tool), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	old := kubeconfig
	kubeconfig = filepath.Join(dir, "kubeconfig")
	t.Cleanup(func() { kubeconfig = old })
	if err := os.WriteFile(kubeconfig, []byte("server: https://"+nodeIP(0)+":6443\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return func() []string {
		data, err := os.ReadFile(calls)
		if err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if err := os.WriteFile(calls, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		return strings.Split(strings.TrimSpace(string(data)), "\n")
	}
}

// After a failed line with a killed node and a fenced instance, the run
// starts the node, then unfences the instance, and does nothing else. An
// outage the scenario ended itself is not ended again.
func TestEndOutages(t *testing.T) {
	calls := fakeTools(t)
	ctx := context.Background()
	s := &scenario{}
	if err := killNodes(ctx, s, args{pods: []string{"pg-1"}}); err != nil {
		t.Fatal(err)
	}
	if err := fence(ctx, s, args{pods: []string{"pg-2"}}); err != nil {
		t.Fatal(err)
	}
	if err := fence(ctx, s, args{pods: []string{"pg-3"}}); err != nil {
		t.Fatal(err)
	}
	if err := unfence(ctx, s, args{pods: []string{"pg-3"}}); err != nil {
		t.Fatal(err)
	}
	calls()
	done, err := s.endOutages(ctx)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"docker start k3s-1", "kubectl cnpg fencing off " + clusterName + " pg-2 -n " + namespace}
	if got := calls(); !slices.Equal(got, want) {
		t.Errorf("after the failed line: got %q, want %q", got, want)
	}
	if done != "started k3s-1; unfenced pg-2" {
		t.Errorf("what it did: %q", done)
	}
	if done, err := s.endOutages(ctx); err != nil || done != "" {
		t.Errorf("a second time: %q %v", done, err)
	}
	if got := calls(); !slices.Equal(got, []string{""}) {
		t.Errorf("a second time it called %q", got)
	}
}
