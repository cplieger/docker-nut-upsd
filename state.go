package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The files lifecycle.sh and entrypoint.sh write into the wrapper state
// directory, one writer each. Renaming one breaks the shell writer silently.
const (
	driverRestartsFile = "driver-restarts"
	upsmonPIDFile      = "upsmon.pid"
	poweroffPathFile   = "poweroff-path"
	readyFile          = "exporter.ready"
)

// maxStateBytes bounds a read of one state file; each holds one short line.
const maxStateBytes = 64

// wrapperState reads the state the image's shell processes record, which no
// exporter reading upsd can see.
type wrapperState struct {
	dir  string
	proc string
}

func (s wrapperState) read(name string) (value string, info os.FileInfo, ok bool) {
	f, err := os.Open(filepath.Join(s.dir, name))
	if err != nil {
		return "", nil, false
	}
	defer f.Close()
	info, err = f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return "", nil, false
	}
	buf := make([]byte, maxStateBytes)
	n, _ := f.Read(buf)
	return strings.TrimSpace(string(buf[:n])), info, true
}

// driverRestarts is 0 until the comms watchdog records its first restart.
func (s wrapperState) driverRestarts() uint64 {
	v, _, ok := s.read(driverRestartsFile)
	if !ok {
		return 0
	}
	n, err := strconv.ParseUint(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// upsmonParent reports whether the PID the entrypoint recorded is a running
// upsmon; recorded is false until the entrypoint has started upsmon. A zombie
// counts as dead: the entrypoint has not reaped it yet.
func (s wrapperState) upsmonParent() (alive, recorded bool) {
	v, _, ok := s.read(upsmonPIDFile)
	if !ok {
		return false, false
	}
	pid, err := strconv.Atoi(v)
	if err != nil || pid < 1 {
		return false, true
	}
	stat, err := os.ReadFile(filepath.Join(s.proc, strconv.Itoa(pid), "stat"))
	if err != nil {
		return false, true
	}
	comm, state, ok := parseProcStat(stat)
	return ok && comm == "upsmon" && state != 'Z' && state != 'X', true
}

// parseProcStat reads the comm and state fields of /proc/<pid>/stat. comm is
// parenthesised and may itself hold ") ", so it ends at the last ")" (proc(5)).
func parseProcStat(stat []byte) (comm string, state byte, ok bool) {
	open := bytes.IndexByte(stat, '(')
	end := bytes.LastIndexByte(stat, ')')
	if open < 0 || end < open || end+2 >= len(stat) {
		return "", 0, false
	}
	return string(stat[open+1 : end]), stat[end+2], true
}

// poweroffPath returns the last D-Bus probe's verdict and when it was
// recorded; found is false until the probe has run.
func (s wrapperState) poweroffPath() (ok bool, at time.Time, found bool) {
	v, info, present := s.read(poweroffPathFile)
	if !present || (v != "0" && v != "1") {
		return false, time.Time{}, false
	}
	return v == "1", info.ModTime(), true
}
