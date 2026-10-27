package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// The unpacked payload:
//
//	chrome/  chrome-headless-shell, its own files, and ld-linux-x86-64.so.2,
//	         which must sit beside them so Chrome finds its resources
//	lib/     every other library, glibc included
//	page/    the page, its fonts in page/fonts, and fonts.conf at the root
const (
	loader = "chrome/ld-linux-x86-64.so.2"
	chrome = "chrome/chrome-headless-shell"
)

// The page is drawn in this viewport, as by report/dev/render.js.
const (
	viewWidth   = 3200
	viewHeight  = 1600
	scaleFactor = 2
)

type image struct {
	file string
	png  []byte
}

// chromeArgv is the command line that starts Chrome through the bundled
// loader, so Chrome uses only the payload's libraries.
func chromeArgv(root string, args []string) []string {
	return append([]string{
		filepath.Join(root, loader),
		"--inhibit-cache",
		"--library-path", filepath.Join(root, "lib") + ":" + filepath.Join(root, "chrome"),
		filepath.Join(root, chrome),
	}, args...)
}

// execChrome replaces this process with a Chrome subprocess. Chrome starts its
// subprocesses through this binary, as they too must start through the loader.
func execChrome(root string, args []string) error {
	argv := chromeArgv(root, args)
	return syscall.Exec(argv[0], argv, os.Environ())
}

// render draws the documents on the page and returns the images. docs holds
// the document and, for an actual document, its desired document.
func render(ctx context.Context, root string, docs []json.RawMessage) ([]image, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	home := filepath.Join(root, "home")
	if err := os.Mkdir(home, 0o700); err != nil {
		return nil, err
	}

	// Chrome reads CDP commands from fd 3 and writes replies to fd 4.
	cmdRead, cmdWrite, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	replyRead, replyWrite, err := os.Pipe()
	if err != nil {
		return nil, errors.Join(err, cmdRead.Close(), cmdWrite.Close())
	}

	argv := chromeArgv(root, []string{
		"--headless",
		"--no-sandbox",
		"--no-zygote",
		"--disable-gpu",
		"--disable-dev-shm-usage",
		"--disable-extensions",
		"--no-first-run",
		"--hide-scrollbars",
		"--remote-debugging-pipe",
		"--user-data-dir=" + filepath.Join(root, "profile"),
		"--browser-subprocess-path=" + self,
		"about:blank",
	})
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = []string{
		rootEnv + "=" + root,
		"HOME=" + home,
		"TMPDIR=" + home,
		"XDG_CONFIG_HOME=" + filepath.Join(home, ".config"),
		"XDG_CACHE_HOME=" + filepath.Join(home, ".cache"),
		"FONTCONFIG_SYSROOT=" + root,
		"FONTCONFIG_FILE=/fonts.conf",
		"FONTCONFIG_PATH=/",
	}
	cmd.ExtraFiles = []*os.File{cmdRead, replyWrite}
	stderr := &tailWriter{}
	cmd.Stderr = stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, errors.Join(fmt.Errorf("start Chrome: %w", err),
			cmdRead.Close(), cmdWrite.Close(), replyRead.Close(), replyWrite.Close())
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	running := true

	// Chrome holds its own copies of its ends of the pipes.
	err = errors.Join(cmdRead.Close(), replyWrite.Close())
	var images []image
	if err == nil {
		images, err = drawAndShoot(ctx, newClient(cmdWrite, replyRead), root, docs)
	}
	if err == nil {
		select {
		case waitErr := <-exited:
			running = false
			if waitErr != nil {
				err = fmt.Errorf("Chrome exited after Browser.close: %w", waitErr)
			}
		case <-time.After(10 * time.Second):
			err = errors.New("Chrome did not exit after Browser.close")
		}
	}
	// Chrome's subprocesses share its process group; none may outlive this
	// call, since their files are removed next.
	if killErr := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); killErr != nil && !errors.Is(killErr, syscall.ESRCH) {
		err = errors.Join(err, killErr)
	}
	if running {
		// err already says why Chrome was killed; its exit status after the
		// kill adds nothing.
		<-exited
	}
	err = errors.Join(err, cmdWrite.Close(), replyRead.Close())
	if err == nil {
		return images, nil
	}
	var pageErr pageError
	if tail := stderr.String(); tail != "" && !errors.As(err, &pageErr) {
		err = fmt.Errorf("%w\nChrome output:\n%s", err, tail)
	}
	return nil, err
}

// pageError is an error thrown on the page, such as a missing key. Chrome's
// own output does not explain it.
type pageError string

func (e pageError) Error() string { return string(e) }

// drawAndShoot draws the documents, takes every image and closes Chrome.
func drawAndShoot(ctx context.Context, c *client, root string, docs []json.RawMessage) ([]image, error) {
	var target struct{ TargetID string }
	if err := c.call(ctx, "", "Target.createTarget", map[string]any{"url": "about:blank"}, &target); err != nil {
		return nil, err
	}
	var attached struct{ SessionID string }
	if err := c.call(ctx, "", "Target.attachToTarget", map[string]any{"targetId": target.TargetID, "flatten": true}, &attached); err != nil {
		return nil, err
	}
	s := attached.SessionID

	if err := c.call(ctx, s, "Page.enable", nil, nil); err != nil {
		return nil, err
	}
	metrics := map[string]any{"width": viewWidth, "height": viewHeight, "deviceScaleFactor": scaleFactor, "mobile": false}
	if err := c.call(ctx, s, "Emulation.setDeviceMetricsOverride", metrics, nil); err != nil {
		return nil, err
	}
	page := "file://" + filepath.Join(root, "page", "index.html")
	var nav struct{ ErrorText string }
	if err := c.call(ctx, s, "Page.navigate", map[string]any{"url": page}, &nav); err != nil {
		return nil, err
	}
	if nav.ErrorText != "" {
		return nil, fmt.Errorf("load the page: %s", nav.ErrorText)
	}
	if err := c.wait(ctx, s, "Page.loadEventFired"); err != nil {
		return nil, err
	}

	args := make([]string, len(docs))
	for i, doc := range docs {
		args[i] = string(doc)
	}
	var files []struct{ File, Selector string }
	if err := c.evaluate(ctx, s, "draw("+strings.Join(args, ",")+")", &files); err != nil {
		return nil, err
	}

	images := []image{}
	seen := map[string]bool{}
	for _, f := range files {
		if f.File != filepath.Base(f.File) || !strings.HasSuffix(f.File, ".png") || seen[f.File] {
			return nil, fmt.Errorf("the page returned a bad file name %q", f.File)
		}
		seen[f.File] = true
		png, err := screenshot(ctx, c, s, f.Selector)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f.File, err)
		}
		images = append(images, image{file: f.File, png: png})
	}
	if err := c.call(ctx, "", "Browser.close", nil, nil); err != nil {
		return nil, err
	}
	return images, nil
}

// screenshot takes the element of selector as a PNG.
func screenshot(ctx context.Context, c *client, s, selector string) ([]byte, error) {
	sel, err := json.Marshal(selector)
	if err != nil {
		return nil, err
	}
	// The box in page pixels, rounded outward so no edge is cut.
	var box struct{ X, Y, Width, Height float64 }
	expr := fmt.Sprintf(`(() => {
		const r = document.querySelector(%s).getBoundingClientRect();
		const x = Math.floor(r.left + scrollX), y = Math.floor(r.top + scrollY);
		return { x, y, width: Math.ceil(r.right + scrollX) - x, height: Math.ceil(r.bottom + scrollY) - y };
	})()`, sel)
	if err := c.evaluate(ctx, s, expr, &box); err != nil {
		return nil, err
	}
	params := map[string]any{
		"format":                "png",
		"captureBeyondViewport": true,
		"clip":                  map[string]any{"x": box.X, "y": box.Y, "width": box.Width, "height": box.Height, "scale": 1},
	}
	var shot struct{ Data string }
	if err := c.call(ctx, s, "Page.captureScreenshot", params, &shot); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(shot.Data)
}

// client speaks the Chrome DevTools Protocol over Chrome's pipe: one JSON
// message per write, ended by a NUL byte.
type client struct {
	out    *os.File
	in     chan message
	readEr chan error
	nextID int
	events []message
}

type message struct {
	ID        int             `json:"id,omitempty"`
	SessionID string          `json:"sessionId,omitempty"`
	Method    string          `json:"method,omitempty"`
	Params    any             `json:"params,omitempty"`
	Result    json.RawMessage `json:"result,omitempty"`
	Error     *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func newClient(out, in *os.File) *client {
	c := &client{out: out, in: make(chan message), readEr: make(chan error, 1)}
	go func() {
		r := bufio.NewReader(in)
		for {
			data, err := r.ReadBytes(0)
			if err != nil {
				c.readEr <- fmt.Errorf("read from Chrome: %w", err)
				return
			}
			var msg message
			if err := json.Unmarshal(data[:len(data)-1], &msg); err != nil {
				c.readEr <- fmt.Errorf("read from Chrome: %w", err)
				return
			}
			c.in <- msg
		}
	}()
	return c
}

// next returns the next message from Chrome.
func (c *client) next(ctx context.Context) (message, error) {
	select {
	case msg := <-c.in:
		return msg, nil
	case err := <-c.readEr:
		return message{}, err
	case <-ctx.Done():
		return message{}, ctx.Err()
	}
}

// call sends one command and reads messages until its reply, keeping the
// events that come before it. result may be nil.
func (c *client) call(ctx context.Context, session, method string, params, result any) error {
	c.nextID++
	id := c.nextID
	data, err := json.Marshal(message{ID: id, SessionID: session, Method: method, Params: params})
	if err != nil {
		return err
	}
	if _, err := c.out.Write(append(data, 0)); err != nil {
		return fmt.Errorf("%s: write to Chrome: %w", method, err)
	}
	for {
		msg, err := c.next(ctx)
		if err != nil {
			return fmt.Errorf("%s: %w", method, err)
		}
		if msg.ID != id {
			if msg.Method != "" {
				c.events = append(c.events, msg)
			}
			continue
		}
		if msg.Error != nil {
			return fmt.Errorf("%s: %s", method, msg.Error.Message)
		}
		if result == nil {
			return nil
		}
		return json.Unmarshal(msg.Result, result)
	}
}

// wait returns once the event method of session has come.
func (c *client) wait(ctx context.Context, session, method string) error {
	for i, msg := range c.events {
		if msg.SessionID == session && msg.Method == method {
			c.events = c.events[i+1:]
			return nil
		}
	}
	c.events = nil
	for {
		msg, err := c.next(ctx)
		if err != nil {
			return fmt.Errorf("wait for %s: %w", method, err)
		}
		if msg.SessionID == session && msg.Method == method {
			return nil
		}
	}
}

// evaluate runs a JS expression on the page, awaits its promise, and decodes
// its value into result. A thrown error comes back as the error.
func (c *client) evaluate(ctx context.Context, session, expr string, result any) error {
	params := map[string]any{"expression": expr, "awaitPromise": true, "returnByValue": true}
	var reply struct {
		Result struct {
			Value json.RawMessage `json:"value"`
		} `json:"result"`
		ExceptionDetails *struct {
			Text      string `json:"text"`
			Exception struct {
				Description string `json:"description"`
			} `json:"exception"`
		} `json:"exceptionDetails"`
	}
	if err := c.call(ctx, session, "Runtime.evaluate", params, &reply); err != nil {
		return err
	}
	if e := reply.ExceptionDetails; e != nil {
		text := e.Exception.Description
		if text == "" {
			text = e.Text
		}
		first, _, _ := strings.Cut(text, "\n")
		return pageError(strings.TrimPrefix(first, "Error: "))
	}
	return json.Unmarshal(reply.Result.Value, result)
}

// tailWriter keeps the last 4 KiB written to it.
type tailWriter struct {
	mu  sync.Mutex
	buf []byte
}

func (w *tailWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	if len(w.buf) > 4096 {
		w.buf = w.buf[len(w.buf)-4096:]
	}
	return len(p), nil
}

func (w *tailWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return strings.TrimSpace(string(w.buf))
}
