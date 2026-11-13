package main

import (
	"bufio"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/cplieger/go/measure"
)

// fakeUpsd answers LIST VAR for one UPS the way upsd does (RFC 9271): the
// variables in order, or a single ERR line when errCode is set.
type fakeUpsd struct {
	ln      net.Listener
	ups     string
	mu      sync.Mutex
	vars    [][2]string
	errCode string
	got     []string
}

func newFakeUpsd(t *testing.T, ups string) *fakeUpsd {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	f := &fakeUpsd{ln: ln, ups: ups}
	var wg sync.WaitGroup
	wg.Go(func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			f.serve(conn)
		}
	})
	t.Cleanup(func() {
		_ = ln.Close()
		wg.Wait()
	})
	return f
}

func (f *fakeUpsd) set(vars [][2]string, errCode string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.vars, f.errCode = vars, errCode
}

func (f *fakeUpsd) requests() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.got...)
}

func (f *fakeUpsd) serve(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimSpace(line)
		f.mu.Lock()
		f.got = append(f.got, line)
		vars, errCode := f.vars, f.errCode
		f.mu.Unlock()
		switch {
		case line == "LOGOUT":
			_, _ = fmt.Fprint(conn, "OK Goodbye\n")
			return
		case line != "LIST VAR "+f.ups:
			_, _ = fmt.Fprint(conn, "ERR UNKNOWN-COMMAND\n")
		case errCode != "":
			_, _ = fmt.Fprintf(conn, "ERR %s\n", errCode)
		default:
			var b strings.Builder
			fmt.Fprintf(&b, "BEGIN LIST VAR %s\n", f.ups)
			for _, kv := range vars {
				v := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(kv[1])
				fmt.Fprintf(&b, "VAR %s %s \"%s\"\n", f.ups, kv[0], v)
			}
			fmt.Fprintf(&b, "END LIST VAR %s\n", f.ups)
			_, _ = fmt.Fprint(conn, b.String())
		}
	}
}

// registries holds one registry per exporter: a desc registers only once.
var registries sync.Map

// gather runs every collector once and indexes each series by its family name
// and label values, joined by "|".
func gather(t *testing.T, e *exporter) map[string]float64 {
	t.Helper()
	cached, loaded := registries.Load(e)
	if !loaded {
		reg := measure.NewRegistry(metricPrefix)
		if err := e.register(reg); err != nil {
			t.Fatalf("register: %v", err)
		}
		cached, _ = registries.LoadOrStore(e, reg)
	}
	reg := cached.(*measure.Registry)
	families, err := reg.Gather(t.Context())
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	out := make(map[string]float64)
	for _, fam := range families {
		for _, s := range fam.Samples {
			key := fam.Name
			for _, l := range s.Labels {
				key += "|" + l.Value
			}
			out[key] = s.Value
		}
	}
	return out
}
