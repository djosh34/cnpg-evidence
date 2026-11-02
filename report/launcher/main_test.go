package main

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// An image that cannot be written leaves the images of an earlier call as
// they were, and no other file.
func TestWriteImagesKeepsOldImagesOnError(t *testing.T) {
	dir := t.TempDir()
	old := filepath.Join(dir, "a.png")
	if err := os.WriteFile(old, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	// No directory sub exists in dir, so the second image cannot be written.
	images := []image{{file: "a.png", png: []byte("new")}, {file: "sub/b.png", png: []byte("new")}}
	if err := writeImages(dir, images); err == nil {
		t.Fatal("writeImages succeeded without the directory sub")
	}
	got, err := os.ReadFile(old)
	if err != nil {
		t.Fatalf("the old image is gone: %v", err)
	}
	if string(got) != "old" {
		t.Fatalf("the old image holds %q, want %q", got, "old")
	}
	assertFiles(t, dir, "a.png")
}

func TestWriteImagesReplacesEveryImage(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.png"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	images := []image{{file: "a.png", png: []byte("new a")}, {file: "b.png", png: []byte("new b")}}
	if err := writeImages(dir, images); err != nil {
		t.Fatal(err)
	}
	for _, img := range images {
		path := filepath.Join(dir, img.file)
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(img.png) {
			t.Fatalf("%s holds %q, want %q", img.file, got, img.png)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o644 {
			t.Fatalf("%s has mode %v, want 0644", img.file, info.Mode().Perm())
		}
	}
	assertFiles(t, dir, "a.png", "b.png")
}

// A directory the call made goes again when the call fails.
func TestWriteImagesRemovesTheDirectoryItMade(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "images")
	if err := writeImages(dir, []image{{file: "sub/b.png", png: []byte("new")}}); err == nil {
		t.Fatal("writeImages succeeded without the directory sub")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("the directory is still there: %v", err)
	}
}

func assertFiles(t *testing.T, dir string, want ...string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if !slices.Equal(names, want) {
		t.Fatalf("%s holds %v, want %v", dir, names, want)
	}
}
