package main

import (
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func testExporter(t *testing.T, upsd *fakeUpsd, stateDir string) *exporter {
	t.Helper()
	return newExporter(upsdClient{addr: upsd.ln.Addr().String(), ups: "ups"},
		wrapperState{dir: stateDir, proc: "/proc"}, false)
}

// The flag names are NUT's ups.status words (docs/new-drivers.txt "Status
// data"), plus ALARM and ECO, which upsmon reads (clients/upsmon.c).
var nutFlags = []string{
	"OL", "OB", "LB", "HB", "RB", "CHRG", "DISCHRG", "BYPASS", "CAL", "OFF",
	"OVER", "TRIM", "BOOST", "FSD", "ALARM", "ECO",
}

func TestEveryStatusFlagMapsToItsSeries(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	exp := testExporter(t, upsd, t.TempDir())
	for _, flag := range nutFlags {
		t.Run(flag, func(t *testing.T) {
			upsd.set([][2]string{{"ups.status", flag}}, "")
			got := gather(t, exp)
			for _, other := range append(nutFlags, "OTHER") {
				want := 0.0
				if other == flag {
					want = 1
				}
				v, ok := got["nut_upsd_ups_status|"+other]
				if !ok || v != want {
					t.Errorf("ups.status %q: nut_upsd_ups_status{flag=%q} = %v (present %v), want %v", flag, other, v, ok, want)
				}
			}
		})
	}
	t.Run("several flags and an unknown word", func(t *testing.T) {
		upsd.set([][2]string{{"ups.status", "ALARM OB DISCHRG LB WEIRD"}}, "")
		got := gather(t, exp)
		for flag, want := range map[string]float64{"ALARM": 1, "OB": 1, "DISCHRG": 1, "LB": 1, "OTHER": 1, "OL": 0, "CHRG": 0} {
			if v := got["nut_upsd_ups_status|"+flag]; v != want {
				t.Errorf("nut_upsd_ups_status{flag=%q} = %v, want %v", flag, v, want)
			}
		}
	})
}

func TestEveryVariableMapsToItsSeries(t *testing.T) {
	// Each NUT variable (docs/nut-names.txt) with the series that serves it in
	// base units: NUT's percentages become ratios.
	cases := []struct {
		nut, value, series string
		want               float64
	}{
		{"battery.charge", "87", "nut_upsd_battery_charge_ratio", 0.87},
		{"battery.charge.low", "10", "nut_upsd_battery_charge_low_ratio", 0.10},
		{"battery.runtime", "1260", "nut_upsd_battery_runtime_seconds", 1260},
		{"battery.runtime.low", "120", "nut_upsd_battery_runtime_low_seconds", 120},
		{"battery.voltage", "27.3", "nut_upsd_battery_voltage_volts", 27.3},
		{"battery.temperature", "31.5", "nut_upsd_battery_temperature_celsius", 31.5},
		{"input.voltage", "231.0", "nut_upsd_input_voltage_volts", 231},
		{"input.frequency", "50.1", "nut_upsd_input_frequency_hertz", 50.1},
		{"output.voltage", "230.0", "nut_upsd_output_voltage_volts", 230},
		{"output.frequency", "49.9", "nut_upsd_output_frequency_hertz", 49.9},
		{"ups.load", "23", "nut_upsd_ups_load_ratio", 0.23},
		{"ups.realpower", "184", "nut_upsd_ups_realpower_watts", 184},
		{"ups.realpower.nominal", "900", "nut_upsd_ups_realpower_nominal_watts", 900},
		{"ups.power", "210", "nut_upsd_ups_power_voltamperes", 210},
		{"ups.power.nominal", "1500", "nut_upsd_ups_power_nominal_voltamperes", 1500},
		{"ups.temperature", "35", "nut_upsd_ups_temperature_celsius", 35},
	}
	vars := [][2]string{{"ups.status", "OL"}, {"ups.mfr", "Example"}}
	for _, c := range cases {
		vars = append(vars, [2]string{c.nut, c.value})
	}
	upsd := newFakeUpsd(t, "ups")
	upsd.set(vars, "")
	got := gather(t, testExporter(t, upsd, t.TempDir()))
	for _, c := range cases {
		v, ok := got[c.series]
		if !ok || math.Abs(v-c.want) > 1e-9 {
			t.Errorf("%s=%s: %s = %v (present %v), want %v", c.nut, c.value, c.series, v, ok, c.want)
		}
	}
	if len(cases) != len(upsVariables) {
		t.Errorf("the exporter serves %d variables, this test checks %d", len(upsVariables), len(cases))
	}

	t.Run("a variable the UPS does not report has no series", func(t *testing.T) {
		upsd.set([][2]string{{"ups.status", "OL"}, {"battery.charge", "not a number"}}, "")
		got := gather(t, testExporter(t, upsd, t.TempDir()))
		for _, name := range []string{"nut_upsd_battery_charge_ratio", "nut_upsd_ups_load_ratio"} {
			if _, ok := got[name]; ok {
				t.Errorf("%s is served with no numeric value from upsd", name)
			}
		}
	})
}

func TestStaleDataServesNoUPSState(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	upsd.set(nil, "DATA-STALE")
	got := gather(t, testExporter(t, upsd, t.TempDir()))
	if got["nut_upsd_upsd_up"] != 1 || got["nut_upsd_ups_data_fresh"] != 0 {
		t.Errorf("stale data: upsd_up=%v ups_data_fresh=%v, want 1 and 0", got["nut_upsd_upsd_up"], got["nut_upsd_ups_data_fresh"])
	}
	if _, ok := got["nut_upsd_ups_status|OL"]; ok {
		t.Error("stale data still serves ups_status")
	}
	// The client closes after LOGOUT without waiting for the reply, so the fake
	// may read it after gather returns.
	deadline := time.Now().Add(5 * time.Second)
	reqs := upsd.requests()
	for len(reqs) < 2 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		reqs = upsd.requests()
	}
	if len(reqs) != 2 || reqs[0] != "LIST VAR ups" || reqs[1] != "LOGOUT" {
		t.Errorf("upsd saw %q, want LIST VAR ups then LOGOUT", reqs)
	}
}

func TestUnreachableUpsd(t *testing.T) {
	ln := newFakeUpsd(t, "ups").ln
	addr := ln.Addr().String()
	_ = ln.Close()
	exp := newExporter(upsdClient{addr: addr, ups: "ups"}, wrapperState{dir: t.TempDir(), proc: "/proc"}, false)
	got := gather(t, exp)
	if got["nut_upsd_upsd_up"] != 0 || got["nut_upsd_ups_data_fresh"] != 0 {
		t.Errorf("closed port: upsd_up=%v ups_data_fresh=%v, want 0 and 0", got["nut_upsd_upsd_up"], got["nut_upsd_ups_data_fresh"])
	}
}

func TestFreshDataIsFresh(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	upsd.set([][2]string{{"ups.status", "OL"}}, "")
	got := gather(t, testExporter(t, upsd, t.TempDir()))
	if got["nut_upsd_upsd_up"] != 1 || got["nut_upsd_ups_data_fresh"] != 1 {
		t.Errorf("fresh data: upsd_up=%v ups_data_fresh=%v, want 1 and 1", got["nut_upsd_upsd_up"], got["nut_upsd_ups_data_fresh"])
	}
}

func writeState(t *testing.T, dir, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(value+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDriverRestartsCountsTheWatchdogRecord(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	dir := t.TempDir()
	exp := testExporter(t, upsd, dir)
	if got := gather(t, exp)["nut_upsd_driver_restarts_total"]; got != 0 {
		t.Errorf("no record: driver_restarts_total = %v, want 0", got)
	}
	writeState(t, dir, driverRestartsFile, "3")
	if got := gather(t, exp)["nut_upsd_driver_restarts_total"]; got != 3 {
		t.Errorf("record 3: driver_restarts_total = %v, want 3", got)
	}
	writeState(t, dir, driverRestartsFile, "garbage")
	if got := gather(t, exp)["nut_upsd_driver_restarts_total"]; got != 0 {
		t.Errorf("unreadable record: driver_restarts_total = %v, want 0", got)
	}
}

func TestPoweroffPathSeries(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	dir := t.TempDir()
	exp := newExporter(upsdClient{addr: upsd.ln.Addr().String(), ups: "ups"}, wrapperState{dir: dir, proc: "/proc"}, true)
	got := gather(t, exp)
	if got["nut_upsd_host_poweroff_enabled"] != 1 {
		t.Errorf("host_poweroff_enabled = %v, want 1", got["nut_upsd_host_poweroff_enabled"])
	}
	if _, ok := got["nut_upsd_poweroff_path_ok"]; ok {
		t.Error("poweroff_path_ok is served before any probe ran")
	}
	writeState(t, dir, poweroffPathFile, "0")
	at := time.Unix(1_800_000_000, 0)
	if err := os.Chtimes(filepath.Join(dir, poweroffPathFile), at, at); err != nil {
		t.Fatal(err)
	}
	got = gather(t, exp)
	if v, ok := got["nut_upsd_poweroff_path_ok"]; !ok || v != 0 {
		t.Errorf("broken probe: poweroff_path_ok = %v (present %v), want 0", v, ok)
	}
	if v := got["nut_upsd_poweroff_path_probe_timestamp_seconds"]; v != 1_800_000_000 {
		t.Errorf("probe timestamp = %v, want 1800000000", v)
	}
	writeState(t, dir, poweroffPathFile, "1")
	if v := gather(t, exp)["nut_upsd_poweroff_path_ok"]; v != 1 {
		t.Errorf("good probe: poweroff_path_ok = %v, want 1", v)
	}
	disabled := newExporter(upsdClient{addr: upsd.ln.Addr().String(), ups: "ups"}, wrapperState{dir: t.TempDir(), proc: "/proc"}, false)
	if v, ok := gather(t, disabled)["nut_upsd_host_poweroff_enabled"]; !ok || v != 0 {
		t.Errorf("host poweroff off: host_poweroff_enabled = %v (present %v), want 0", v, ok)
	}
}

// TestHelperProcess is the child startNamed runs: it blocks until killed. It
// does nothing in a normal test run.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("NUT_EXPORTER_TEST_HELPER") != "block" {
		return
	}
	time.Sleep(time.Minute)
	os.Exit(0)
}

// startNamed runs a copy of this test binary named name, blocked in
// TestHelperProcess, so the kernel's comm for the process is name. A copy of a
// system tool is not used: a multicall coreutils exits at once under a name
// it does not know.
func startNamed(t *testing.T, name string) *exec.Cmd {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(t.TempDir(), name)
	syscall.ForkLock.RLock()
	err = os.WriteFile(bin, src, 0o755)
	syscall.ForkLock.RUnlock()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin, "-test.run=^TestHelperProcess$")
	cmd.Env = append(os.Environ(), "NUT_EXPORTER_TEST_HELPER=block")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	return cmd
}

func TestUpsmonParentAlive(t *testing.T) {
	upsd := newFakeUpsd(t, "ups")
	dir := t.TempDir()
	exp := testExporter(t, upsd, dir)
	alive := func() float64 { return gather(t, exp)["nut_upsd_upsmon_parent_alive"] }

	if got := alive(); got != 0 {
		t.Errorf("no PID recorded: upsmon_parent_alive = %v, want 0", got)
	}
	upsmon := startNamed(t, "upsmon")
	writeState(t, dir, upsmonPIDFile, strconv.Itoa(upsmon.Process.Pid))
	// The first scrape can land before the child reads as a running upsmon,
	// seen under -race on a loaded host, so it gets a bounded wait.
	deadline := time.Now().Add(5 * time.Second)
	got := alive()
	for got != 1 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
		got = alive()
	}
	if got != 1 {
		stat, err := os.ReadFile("/proc/" + strconv.Itoa(upsmon.Process.Pid) + "/stat")
		t.Errorf("running upsmon: upsmon_parent_alive = %v, want 1 (stat %q, %v)", got, stat, err)
	}

	other := startNamed(t, "notupsmon")
	writeState(t, dir, upsmonPIDFile, strconv.Itoa(other.Process.Pid))
	if got := alive(); got != 0 {
		t.Errorf("PID of another program: upsmon_parent_alive = %v, want 0", got)
	}

	writeState(t, dir, upsmonPIDFile, strconv.Itoa(upsmon.Process.Pid))
	if err := upsmon.Process.Signal(syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for {
		stat, err := os.ReadFile("/proc/" + strconv.Itoa(upsmon.Process.Pid) + "/stat")
		if _, state, ok := parseProcStat(stat); err == nil && ok && state == 'Z' {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the killed upsmon never became a zombie")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := alive(); got != 0 {
		t.Errorf("unreaped upsmon: upsmon_parent_alive = %v, want 0", got)
	}
}

func TestParseProcStat(t *testing.T) {
	for _, c := range []struct {
		stat, comm string
		state      byte
		ok         bool
	}{
		{"42 (upsmon) S 1 42", "upsmon", 'S', true},
		{"42 (a) b) Z 1 42", "a) b", 'Z', true},
		{"42 upsmon S", "", 0, false},
		{"42 (upsmon)", "", 0, false},
	} {
		comm, state, ok := parseProcStat([]byte(c.stat))
		if comm != c.comm || state != c.state || ok != c.ok {
			t.Errorf("parseProcStat(%q) = %q, %q, %v; want %q, %q, %v", c.stat, comm, state, ok, c.comm, c.state, c.ok)
		}
	}
}
