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
// they were called; kubectl answers that every pod runs on k3s-1. more are
// further shell case branches, for calls that answer otherwise. It returns
// what they were called with since the last call.
func fakeTools(t *testing.T, more ...string) func() []string {
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	tool := "#!/bin/sh\necho \"${0##*/} $*\" >>" + calls + "\ncase \"$*\" in *spec.nodeName*) echo k3s-1 ;; " +
		strings.Join(more, " ") + " esac\n"
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
// starts the node, waits for the API server, then unfences the instance,
// and does nothing else. An
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
	want := []string{"docker start k3s-1", "kubectl get --raw /readyz", "kubectl cnpg fencing off " + clusterName + " pg-2 -n " + namespace}
	if got := calls(); !slices.Equal(got, want) {
		t.Errorf("after the failed line: got %q, want %q", got, want)
	}
	if done != "started k3s-1; the API server answered; unfenced pg-2" {
		t.Errorf("what it did: %q", done)
	}
	if done, err := s.endOutages(ctx); err != nil || done != "" {
		t.Errorf("a second time: %q %v", done, err)
	}
	if got := calls(); !slices.Equal(got, []string{""}) {
		t.Errorf("a second time it called %q", got)
	}
}

// A store stop that fails halfway, with the store stopped and no stand-in
// at its address, still leaves the store to bring back.
func TestEndOutagesAfterAHalfStoppedStore(t *testing.T) {
	calls := fakeTools(t,
		`"create --name s3-gone"*) echo no address >&2; exit 1 ;;`,
		`"rm -f s3-gone") echo "Error response from daemon: No such container: s3-gone" >&2; exit 1 ;;`)
	ctx := context.Background()
	s := &scenario{}
	if breakStore("stopped")(ctx, s, args{}) == nil {
		t.Fatal("the stand-in failed, and the stop passed")
	}
	calls()
	if _, err := s.endOutages(ctx); err != nil {
		t.Fatal(err)
	}
	want := []string{"docker rm -f " + storeGone, "docker start s3"}
	if got := calls(); !slices.Equal(got, want) {
		t.Errorf("after the failed line: got %q, want %q", got, want)
	}
}

// A kill whose stop failed before the node stopped leaves the node and its
// pod's paused replay alone: the cleanup resumes the replay, and does not
// start the node.
func TestEndOutagesAfterAFailedKill(t *testing.T) {
	calls := fakeTools(t,
		`"stop -t 0 k3s-1") exit 1 ;;`,
		`"inspect -f {{.State.Running}} k3s-1") echo true ;;`)
	ctx := context.Background()
	s := &scenario{}
	if err := replay("pause")(ctx, s, args{pods: []string{"pg-1"}}); err != nil {
		t.Fatal(err)
	}
	if killNodes(ctx, s, args{pods: []string{"pg-1"}}) == nil {
		t.Fatal("the stop failed, and the kill passed")
	}
	calls()
	if _, err := s.endOutages(ctx); err != nil {
		t.Fatal(err)
	}
	want := []string{"kubectl exec -n " + namespace + " pg-1 -c postgres -- psql -U postgres -d postgres -XqAt -v ON_ERROR_STOP=1 -c " +
		"select pg_wal_replay_resume() where pg_is_in_recovery()"}
	if got := calls(); !slices.Equal(got, want) {
		t.Errorf("after the failed kill: got %q, want %q", got, want)
	}
}
