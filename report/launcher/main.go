// cnpg-report turns one JSON document of the evidence scripts into images.
//
// Usage: cnpg-report [--desired <file.json>] --out <dir> <file.json>
//
// It unpacks the embedded payload (Chrome, its libraries, glibc and loader,
// fonts and the page) into a new directory under TMPDIR, draws the images with
// Chrome, writes them into <dir> and removes the unpacked files. Exit 0 when
// every image is written, exit 2 on any error, with no image left in <dir>.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

//go:embed payload.tar.gz
var payload []byte

// rootEnv names the unpacked payload for the Chrome processes that Chrome
// starts through this binary (see execChrome).
const rootEnv = "CNPG_REPORT_ROOT"

// renderTimeout bounds the work of Chrome for one call.
const renderTimeout = 5 * time.Minute

func main() {
	if root := os.Getenv(rootEnv); root != "" && isChromeChild(os.Args[1:]) {
		err := execChrome(root, os.Args[1:])
		fmt.Fprintf(os.Stderr, "cnpg-report: start Chrome: %v\n", err)
		os.Exit(2)
	}

	flags := flag.NewFlagSet("cnpg-report", flag.ContinueOnError)
	flags.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: cnpg-report [--desired <file.json>] --out <dir> <file.json>")
	}
	desiredFile := flags.String("desired", "", "the desired document of an actual document")
	outDir := flags.String("out", "", "the directory the images are written into")
	if err := flags.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	if *outDir == "" || flags.NArg() != 1 {
		flags.Usage()
		os.Exit(2)
	}

	if err := run(flags.Arg(0), *desiredFile, *outDir); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "cnpg-report: %v\n", err)
	os.Exit(2)
}

func run(docFile, desiredFile, outDir string) error {
	docs := []json.RawMessage{}
	for _, file := range []string{docFile, desiredFile} {
		if file == "" {
			continue
		}
		doc, err := readJSON(file)
		if err != nil {
			return err
		}
		docs = append(docs, doc)
	}

	root, err := os.MkdirTemp("", "cnpg-report-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)

	if err := unpack(root); err != nil {
		return fmt.Errorf("unpack: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, renderTimeout)
	defer cancel()
	images, err := render(ctx, root, docs)
	if err != nil {
		return err
	}
	return writeImages(outDir, images)
}

func readJSON(file string) (json.RawMessage, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if !json.Valid(data) {
		return nil, fmt.Errorf("%s is not valid JSON", file)
	}
	return data, nil
}

// unpack writes the payload into root. The payload holds only directories and
// regular files.
func unpack(root string) error {
	gz, err := gzip.NewReader(bytes.NewReader(payload))
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return gz.Close()
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(hdr.Name)
		if name == "." {
			continue
		}
		if !filepath.IsLocal(name) {
			return fmt.Errorf("payload path %q leaves the directory", hdr.Name)
		}
		path := filepath.Join(root, name)
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(path, 0o700); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeFile(path, tr, os.FileMode(hdr.Mode).Perm()); err != nil {
				return err
			}
		default:
			return fmt.Errorf("payload entry %q has unsupported type %c", hdr.Name, hdr.Typeflag)
		}
	}
}

func writeFile(path string, r io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// writeImages writes every image into dir, or none: on an error it removes
// the images it already wrote, and dir if it made it.
func writeImages(dir string, images []image) error {
	_, statErr := os.Stat(dir)
	madeDir := errors.Is(statErr, os.ErrNotExist)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	written := []string{}
	for _, img := range images {
		path := filepath.Join(dir, img.file)
		err := os.WriteFile(path, img.png, 0o644)
		if err == nil {
			written = append(written, path)
			continue
		}
		for _, w := range written {
			if rmErr := os.Remove(w); rmErr != nil {
				err = errors.Join(err, rmErr)
			}
		}
		if madeDir {
			if rmErr := os.Remove(dir); rmErr != nil {
				err = errors.Join(err, rmErr)
			}
		}
		return err
	}
	return nil
}

// isChromeChild tells a Chrome subprocess, which Chrome starts with a --type
// switch, from a call by a person.
func isChromeChild(args []string) bool {
	for _, arg := range args {
		if strings.HasPrefix(arg, "--type=") {
			return true
		}
	}
	return false
}
