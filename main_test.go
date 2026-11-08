package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunRefusesAMalformedListenAddress(t *testing.T) {
	dir := t.TempDir()
	for _, addr := range []string{"300.1.1.1:9199", "127.0.0.1:99999", "no-colon"} {
		t.Run(addr, func(t *testing.T) {
			err := run(t.Context(), []string{"-listen", addr, "-upsd", "127.0.0.1:3493", "-ups", "ups", "-state-dir", dir}, newLogger(io.Discard))
			if err == nil {
				t.Fatal("run accepted the address")
			}
			if _, statErr := os.Stat(filepath.Join(dir, readyFile)); statErr == nil {
				t.Error("the ready file exists after a failed bind")
			}
		})
	}
}

func TestRunRefusesATakenPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	err = run(t.Context(), []string{"-listen", ln.Addr().String(), "-upsd", "127.0.0.1:3493", "-ups", "ups", "-state-dir", t.TempDir()}, newLogger(io.Discard))
	if err == nil {
		t.Fatal("run bound a port another listener holds")
	}
}

func TestParseArgsRequiresEverySetting(t *testing.T) {
	full := []string{"-listen", ":0", "-upsd", "127.0.0.1:3493", "-ups", "ups", "-state-dir", "/x"}
	if _, err := parseArgs(full); err != nil {
		t.Fatalf("full command line refused: %v", err)
	}
	for i := 0; i < len(full); i += 2 {
		args := append(append([]string{}, full[:i]...), full[i+2:]...)
		if _, err := parseArgs(args); err == nil {
			t.Errorf("command line without %s accepted", full[i])
		}
	}
	if _, err := parseArgs(append(full, "extra")); err == nil {
		t.Error("a stray argument was accepted")
	}
}

func TestRunServesMetricsAfterTheReadyFile(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	upsd.set([][2]string{{"ups.status", "OL"}}, "")
	dir := t.TempDir()
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := probe.Addr().String()
	_ = probe.Close()

	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"-listen", addr, "-upsd", upsd.ln.Addr().String(), "-ups", "ups", "-state-dir", dir, "-host-poweroff"}, newLogger(io.Discard))
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, readyFile)); err == nil {
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("no ready file within 5s; run returned %v", <-done)
		}
		time.Sleep(10 * time.Millisecond)
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://" + addr + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics: %v", err)
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("GET /metrics: status %d", resp.StatusCode)
	}
	for _, line := range []string{`nut_upsd_ups_status{flag="OL"} 1`, "nut_upsd_host_poweroff_enabled 1", "nut_upsd_upsd_up 1"} {
		if !bytes.Contains(body, []byte(line+"\n")) {
			t.Errorf("/metrics lacks %q", line)
		}
	}
	if resp, err := client.Post("http://"+addr+"/metrics", "text/plain", nil); err == nil {
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("POST /metrics: status %d, want 405", resp.StatusCode)
		}
		_ = resp.Body.Close()
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("run after cancel: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("run did not return after cancel")
	}
}

func TestLoggerOpensEachRecordWithItsLevel(t *testing.T) {
	var buf bytes.Buffer
	l := newLogger(&buf)
	l.Error("metrics exporter stopped", "err", "boom")
	l.Info("listening")
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 || lines[0] != `level=error msg="metrics exporter stopped" err=boom` || lines[1] != "level=info msg=listening" {
		t.Errorf("records = %q", lines)
	}
}
