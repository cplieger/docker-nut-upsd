package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const (
	metricsGolden = "testdata/metrics.golden"
	regenerate    = "UPDATE_GOLDEN=1 go test -run '^TestMetricsExpositionMatchesGolden$' ."
)

// TestMetricsExpositionMatchesGolden pins every byte of the exporter's own
// families on the /metrics page run serves, over fixed inputs that give every
// family a sample. Dashboards, alert rules and deployments read these lines.
// The Go and process families are left out: their values move between scrapes.
func TestMetricsExpositionMatchesGolden(t *testing.T) {
	values := map[string]string{
		"battery.charge":        "87",
		"battery.charge.low":    "10",
		"battery.runtime":       "1260",
		"battery.runtime.low":   "120",
		"battery.voltage":       "27.3",
		"battery.temperature":   "31.5",
		"input.voltage":         "231.0",
		"input.frequency":       "50.1",
		"output.voltage":        "230.0",
		"output.frequency":      "49.9",
		"ups.load":              "23",
		"ups.realpower":         "184",
		"ups.realpower.nominal": "900",
		"ups.power":             "210",
		"ups.power.nominal":     "1500",
		"ups.temperature":       "35",
	}
	vars := [][2]string{{"ups.status", "OL CHRG ALARM WEIRD"}, {"ups.mfr", "Example"}}
	for _, v := range upsVariables {
		value, ok := values[v.nut]
		if !ok {
			t.Fatalf("no fixed value for %s", v.nut)
		}
		vars = append(vars, [2]string{v.nut, value})
	}
	upsd := newFakeUpsd(t, "ups")
	upsd.set(vars, "")

	dir := t.TempDir()
	writeState(t, dir, driverRestartsFile, "3")
	writeState(t, dir, poweroffPathFile, "1")
	at := time.Unix(1_800_000_000, 0)
	if err := os.Chtimes(filepath.Join(dir, poweroffPathFile), at, at); err != nil {
		t.Fatal(err)
	}
	upsmon := startNamed(t, "upsmon")
	writeState(t, dir, upsmonPIDFile, strconv.Itoa(upsmon.Process.Pid))

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
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("run did not return after cancel")
		}
	})

	// The child can read as a running upsmon only after the first scrape, seen
	// under -race on a loaded host, so the scrape is retried until it does.
	client := &http.Client{Timeout: 5 * time.Second}
	var page []byte
	deadline := time.Now().Add(10 * time.Second)
	for {
		page = scrapeMetrics(t, client, addr)
		if bytes.Contains(page, []byte("\nnut_upsd_upsmon_parent_alive 1\n")) || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	got := withoutRuntimeFamilies(t, page)

	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.MkdirAll(filepath.Dir(metricsGolden), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(metricsGolden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(metricsGolden)
	if err != nil {
		t.Fatalf("read %s (write it with %s): %v", metricsGolden, regenerate, err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("/metrics differs from %s (after reviewing the change, rewrite it with %s)\n--- got\n%s\n--- want\n%s", metricsGolden, regenerate, got, want)
	}
}

// scrapeMetrics GETs /metrics from addr once run has bound it, failing the
// test on anything but a 200 in text format 0.0.4.
func scrapeMetrics(t *testing.T, client *http.Client, addr string) []byte {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		resp, err := client.Get("http://" + addr + "/metrics")
		if err != nil {
			if time.Now().After(deadline) {
				t.Fatalf("GET /metrics: %v", err)
			}
			time.Sleep(10 * time.Millisecond)
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_ = resp.Body.Close()
		if err != nil {
			t.Fatalf("read /metrics: %v", err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET /metrics: status %d", resp.StatusCode)
		}
		if got, want := resp.Header.Get("Content-Type"), "text/plain; version=0.0.4; charset=utf-8"; got != want {
			t.Fatalf("Content-Type = %q, want %q", got, want)
		}
		return body
	}
}

// withoutRuntimeFamilies drops the go_ and process_ families from an
// exposition, keeping every other line in order.
func withoutRuntimeFamilies(t *testing.T, page []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	family := ""
	for line := range strings.SplitAfterSeq(string(page), "\n") {
		if line == "" {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "# HELP "); ok {
			family, _, _ = strings.Cut(rest, " ")
		} else if rest, ok := strings.CutPrefix(line, "# TYPE "); ok {
			family, _, _ = strings.Cut(rest, " ")
		} else if family == "" {
			t.Fatalf("sample before any family header: %q", line)
		}
		if strings.HasPrefix(family, "go_") || strings.HasPrefix(family, "process_") {
			continue
		}
		out.WriteString(line)
	}
	return out.Bytes()
}
