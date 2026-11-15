package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Each node keeps its local-path volumes, the instances' data and WAL, on a
// filesystem of its own, as a node's data disk in production: a 4 GiB ext4
// image, allocated in full up front, mounted on a loop device in the e2e
// container and bound into the node at k3s's storage directory before k3s
// starts. etcd, the images and the logs stay on the node's own volume. The
// mount outlives a node's docker stop and start, so its data does too. A
// full data filesystem stops only that node's PostgreSQL: the runner's disk
// gave the images their space at the start.
const (
	// A volume of the e2e image, so on the runner's disk.
	disksDir = "/e2e-disks"
	diskSize = 4 << 30
	// What the rest of a run takes of the runner's disk at most: the images
	// of the containers and pods, the nodes' etcd and logs, the results.
	otherSpace = 8 << 30
	storageDir = "/var/lib/rancher/k3s/storage"
)

func diskImage(node string) string { return filepath.Join(disksDir, node+".img") }
func diskMount(node string) string { return filepath.Join(disksDir, node) }

// dataDisks are the nodes' data filesystems of a run, and the most each
// held while the run went on.
type dataDisks struct {
	made    []string // the nodes whose image exists
	mounted []string // the nodes whose filesystem is mounted
	free    uint64   // the runner's free bytes before the images

	stop, done chan struct{}
	mu         sync.Mutex
	most       map[string]diskUse
	err        error // the first failed sample
}

type diskUse struct {
	used, size uint64
	at         time.Time
}

// prepare checks that the runner's disk has room for the images and the
// rest of the run, then makes and mounts one filesystem per node.
func (d *dataDisks) prepare(ctx context.Context) error {
	free, err := freeBytes(disksDir)
	if err != nil {
		return err
	}
	d.free = free
	disks, need := uint64(nodeCount*diskSize), uint64(nodeCount*diskSize+otherSpace)
	if free < need {
		return fmt.Errorf("the runner's disk has %s free; a run needs %s: %s for the nodes' data filesystems and %s for the rest",
			gib(free), gib(need), gib(disks), gib(otherSpace))
	}
	logf("the runner's disk has %s free; making a data filesystem of %s for each node", gib(free), gib(diskSize))
	for i := range nodeCount {
		node := nodeName(i)
		image, dir := diskImage(node), diskMount(node)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		d.made = append(d.made, node)
		if _, err := command(ctx, "fallocate", "-l", strconv.Itoa(diskSize), image); err != nil {
			return err
		}
		// nodiscard: mkfs would give the image's blocks back to the runner.
		if _, err := command(ctx, "mkfs.ext4", "-q", "-F", "-m", "0",
			"-E", "nodiscard,lazy_itable_init=0,lazy_journal_init=0", image); err != nil {
			return err
		}
		if _, err := command(ctx, "mount", "-t", "ext4", "-o", "loop,nodiscard", image, dir); err != nil {
			return err
		}
		d.mounted = append(d.mounted, node)
	}
	return nil
}

// watch samples how much of each filesystem is used, every 5 s, until
// finish.
func (d *dataDisks) watch() {
	d.most = map[string]diskUse{}
	d.stop, d.done = make(chan struct{}), make(chan struct{})
	go func() {
		defer close(d.done)
		for {
			d.sample()
			select {
			case <-d.stop:
				return
			case <-time.After(5 * time.Second):
			}
		}
	}()
}

func (d *dataDisks) sample() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, node := range d.mounted {
		used, size, err := usedBytes(diskMount(node))
		if err != nil {
			if d.err == nil {
				d.err = err
			}
			continue
		}
		// The first time it held the most.
		if used > d.most[node].used || d.most[node].at.IsZero() {
			d.most[node] = diskUse{used: used, size: size, at: time.Now()}
		}
	}
}

// finish stops the watch and writes disks.md. Then it removes the nodes,
// unmounts the filesystems and deletes the images.
func (d *dataDisks) finish(ctx context.Context, res *results) error {
	if d.stop != nil {
		close(d.stop)
		<-d.done
		d.sample()
	}
	errs := []error{res.write("disks.md", d.report(ctx)), d.err}
	if len(d.made) > 0 {
		errs = append(errs, removeNodes(ctx))
	}
	for _, node := range d.mounted {
		if _, err := command(ctx, "umount", diskMount(node)); err != nil {
			errs = append(errs, err)
		}
	}
	for _, node := range d.made {
		// mount gave the loop device autoclear: it goes with the last mount.
		loops, err := command(ctx, "losetup", "-j", diskImage(node))
		if err == nil && loops != "" {
			err = fmt.Errorf("a loop device still holds the image of %s: %s", node, loops)
		}
		if err == nil {
			err = os.Remove(diskImage(node))
		}
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// removeNodes removes the node containers that exist, with their mounts of
// the data filesystems.
func removeNodes(ctx context.Context) error {
	out, err := command(ctx, "docker", "ps", "-a", "--format", "{{.Names}}")
	if err != nil {
		return err
	}
	var nodes []string
	for i := range nodeCount {
		if slices.Contains(strings.Fields(out), nodeName(i)) {
			nodes = append(nodes, nodeName(i))
		}
	}
	if len(nodes) == 0 {
		return nil
	}
	_, err = command(ctx, "docker", append([]string{"rm", "-f", "-v"}, nodes...)...)
	return err
}

// report is disks.md: the runner's free space before the images, each
// filesystem's most and last use, and what each volume holds at the end.
func (d *dataDisks) report(ctx context.Context) string {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := fmt.Sprintf("### The nodes' data filesystems\n\nThe runner's disk had %s free before the run made them.\n\n", gib(d.free))
	out += "| Node | Size | Most used | When (UTC) | Used at the end |\n|---|---|---|---|---|\n"
	var volumes string
	for _, node := range d.mounted {
		most := d.most[node]
		used, size, err := usedBytes(diskMount(node))
		end := share(used, size)
		if err != nil {
			end = err.Error()
		}
		out += fmt.Sprintf("| %s | %s | %s | %s | %s |\n", node, gib(most.size), share(most.used, most.size),
			most.at.UTC().Format(time.TimeOnly), end)
		du, err := command(ctx, "sh", "-c", `du -sh "$1"/*`, "du", diskMount(node))
		if err != nil {
			du = err.Error()
		}
		volumes += "\n" + node + ":\n" + du + "\n"
	}
	if d.err != nil {
		out += "\nA sample failed: " + d.err.Error() + "\n"
	}
	return out + "\nWhat each directory holds at the end, du -sh:\n\n```" + volumes + "```\n"
}

// freeBytes are the bytes of the filesystem of path that a user may still
// write; usedBytes the bytes used and the filesystem's size, as statfs and
// so the kubelet count them.
func freeBytes(path string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, fmt.Errorf("statfs %s: %w", path, err)
	}
	return st.Bavail * uint64(st.Bsize), nil
}

func usedBytes(path string) (used, size uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, fmt.Errorf("statfs %s: %w", path, err)
	}
	return (st.Blocks - st.Bfree) * uint64(st.Bsize), st.Blocks * uint64(st.Bsize), nil
}

func gib(bytes uint64) string { return fmt.Sprintf("%.1f GiB", float64(bytes)/(1<<30)) }

func share(used, size uint64) string {
	if size == 0 {
		return "-"
	}
	return fmt.Sprintf("%s (%.0f %%)", gib(used), 100*float64(used)/float64(size))
}
