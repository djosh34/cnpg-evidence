package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// command runs a program with the bench's kubeconfig and returns its output
// without the last newline. A failure's error holds its output.
func command(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "KUBECONFIG="+kubeconfig)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err,
			strings.TrimSpace(stderr.String()+" "+stdout.String()))
	}
	return strings.TrimSuffix(stdout.String(), "\n"), nil
}

// poll runs check every 2 s until it holds or the deadline passes. A check
// that started in time but held only after the deadline fails too.
func poll(ctx context.Context, deadline time.Time, check func(context.Context) error) error {
	for {
		err := check(ctx)
		late := time.Now().After(deadline)
		switch {
		case err == nil && late:
			return errors.New("it held only after the limit")
		case err == nil:
			return nil
		case late:
			return fmt.Errorf("not within the limit: %w", err)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// callJSON sends req and decodes the JSON answer into out, when out is not
// nil. An answer other than 2xx is an error with its body.
func callJSON(client *http.Client, req *http.Request, out any) error {
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(resp.Body)
	if err := errors.Join(err, resp.Body.Close()); err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s %s: %s: %s", req.Method, req.URL.Redacted(), resp.Status, bytes.TrimSpace(data))
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	return json.Unmarshal(data, out)
}

// logf prints a line of the run's progress.
func logf(format string, args ...any) {
	say(os.Stdout, "== %s %s\n", time.Now().UTC().Format(time.TimeOnly), fmt.Sprintf(format, args...))
}

// say prints to w. A run that cannot print cannot report, so it stops.
func say(w io.Writer, format string, args ...any) {
	if _, err := fmt.Fprintf(w, format, args...); err != nil {
		os.Exit(2)
	}
}
