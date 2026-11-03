package main

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// A slow attempt does not delay the next one.
func TestEveryStartsOnTime(t *testing.T) {
	f, err := os.Create(filepath.Join(t.TempDir(), "log"))
	if err != nil {
		t.Fatal(err)
	}
	out.f = f
	t.Cleanup(func() {
		out.f = os.Stdout
		if err := f.Close(); err != nil {
			t.Error(err)
		}
	})
	var started atomic.Int32
	ctx, cancel := context.WithTimeout(context.Background(), 210*time.Millisecond)
	defer cancel()
	every(ctx, 20*time.Millisecond, "pgx", "query", func(ctx context.Context) (string, string, error) {
		started.Add(1)
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
		return "", "", nil
	})
	// One at a time, about 3 would start; on time, about 11.
	if n := started.Load(); n < 7 {
		t.Errorf("%d attempts started in 210 ms at one every 20 ms", n)
	}
}
