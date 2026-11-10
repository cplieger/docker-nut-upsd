package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// startExporter runs the exporter against upsdAddr and returns its listen address once the ready file exists.
func startExporter(t *testing.T, upsdAddr string) string {
	t.Helper()
	dir := t.TempDir()
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := probe.Addr().String()
	_ = probe.Close()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- run(ctx, []string{"-listen", addr, "-upsd", upsdAddr, "-ups", "ups", "-state-dir", dir}, newLogger(io.Discard))
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Error("run did not return after cancel")
		}
	})
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, readyFile)); err == nil {
			return addr
		}
		if time.Now().After(deadline) {
			t.Fatal("no ready file within 5s")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type healthzBody struct {
	Status  string   `json:"status"`
	Reasons []string `json:"reasons"`
}

type healthzReply struct {
	header http.Header
	body   healthzBody
	code   int
}

func getHealthz(t *testing.T, method, addr string) healthzReply {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), method, "http://"+addr+"/healthz", http.NoBody)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s /healthz: %v", method, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		t.Fatalf("read /healthz body: %v", err)
	}
	reply := healthzReply{header: resp.Header, code: resp.StatusCode}
	if method == http.MethodGet {
		if err := json.Unmarshal(raw, &reply.body); err != nil {
			t.Fatalf("/healthz body %q is not JSON: %v", raw, err)
		}
	}
	return reply
}

// The image's HEALTHCHECK is comms_fresh, `upsc <ups> ups.status` with a
// 3-second bound: it passes only while upsd answers with the UPS's status.
// /healthz must give the same verdict for each of upsd's answers.
func TestHealthzFollowsTheUPSStatusFreshness(t *testing.T) {
	cases := []struct {
		name    string
		vars    [][2]string
		errCode string
		healthy bool
	}{
		{name: "fresh status", vars: [][2]string{{"ups.status", "OL"}, {"battery.charge", "100"}}, healthy: true},
		{name: "fresh status on battery", vars: [][2]string{{"ups.status", "OB DISCHRG LB"}}, healthy: true},
		{name: "stale data", errCode: "DATA-STALE"},
		{name: "driver not connected", errCode: "DRIVER-NOT-CONNECTED"},
		{name: "unknown UPS", errCode: "UNKNOWN-UPS"},
		{name: "no ups.status variable", vars: [][2]string{{"battery.charge", "100"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			upsd := newFakeUpsd(t, "ups")
			upsd.set(tc.vars, tc.errCode)
			addr := startExporter(t, upsd.ln.Addr().String())

			assertHealthz(t, getHealthz(t, http.MethodGet, addr), tc.healthy)
		})
	}
}

func TestHealthzIsUnhealthyWhileUpsdDoesNotAnswer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	gone := ln.Addr().String()
	_ = ln.Close()
	addr := startExporter(t, gone)

	assertHealthz(t, getHealthz(t, http.MethodGet, addr), false)
}

func TestHealthzTurnsUnhealthyWhenTheStatusGoesStaleAndBack(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	upsd.set([][2]string{{"ups.status", "OL"}}, "")
	addr := startExporter(t, upsd.ln.Addr().String())

	assertHealthz(t, getHealthz(t, http.MethodGet, addr), true)
	upsd.set(nil, "DATA-STALE")
	assertHealthz(t, getHealthz(t, http.MethodGet, addr), false)
	upsd.set([][2]string{{"ups.status", "OL"}}, "")
	assertHealthz(t, getHealthz(t, http.MethodGet, addr), true)
}

func TestHealthzMethods(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	upsd.set([][2]string{{"ups.status", "OL"}}, "")
	addr := startExporter(t, upsd.ln.Addr().String())

	t.Run("HEAD", func(t *testing.T) {
		if code := getHealthz(t, http.MethodHead, addr).code; code != http.StatusOK {
			t.Errorf("HEAD /healthz: status %d, want 200", code)
		}
	})
	t.Run("POST", func(t *testing.T) {
		if code := getHealthz(t, http.MethodPost, addr).code; code != http.StatusMethodNotAllowed {
			t.Errorf("POST /healthz: status %d, want 405", code)
		}
	})
}

func assertHealthz(t *testing.T, r healthzReply, healthy bool) {
	t.Helper()
	for header, want := range map[string]string{
		"Content-Type":           "application/json",
		"Cache-Control":          "no-store",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := r.header.Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
	if healthy {
		if r.code != http.StatusOK || r.body.Status != "ok" || r.body.Reasons != nil {
			t.Errorf("/healthz = %d %+v, want 200 {status:ok}", r.code, r.body)
		}
		return
	}
	if r.code != http.StatusServiceUnavailable || r.body.Status != "unhealthy" {
		t.Errorf("/healthz = %d %+v, want 503 unhealthy", r.code, r.body)
	}
	if want := []string{upsStatusStaleReason}; !slices.Equal(r.body.Reasons, want) {
		t.Errorf("reasons = %q, want %q", r.body.Reasons, want)
	}
}
