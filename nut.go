package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// errUPSData is upsd answering LIST VAR with an ERR reply, such as DATA-STALE
// or DRIVER-NOT-CONNECTED: the server is up and the UPS data is not usable.
var errUPSData = errors.New("upsd has no usable data for the UPS")

const (
	upsdTimeout = 3 * time.Second
	// maxVarLines bounds one LIST VAR answer; a driver reports well under 200.
	maxVarLines = 4096
	maxLineLen  = 4096
)

// upsdClient reads one UPS's variables from upsd over the NUT network
// protocol (RFC 9271), one connection per read.
type upsdClient struct {
	addr string
	ups  string
}

// listVars returns every variable upsd holds for the UPS. It wraps errUPSData
// when upsd answered with an ERR reply; any other error means upsd did not
// answer the protocol.
func (c upsdClient) listVars(ctx context.Context) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(ctx, upsdTimeout)
	defer cancel()
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", c.addr)
	if err != nil {
		return nil, fmt.Errorf("connect to upsd: %w", err)
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	if _, err = fmt.Fprintf(conn, "LIST VAR %s\n", c.ups); err != nil {
		return nil, fmt.Errorf("send LIST VAR: %w", err)
	}
	vars, err := readVarList(bufio.NewReaderSize(conn, maxLineLen), c.ups)
	if err == nil || errors.Is(err, errUPSData) {
		_, _ = fmt.Fprint(conn, "LOGOUT\n")
	}
	return vars, err
}

// readVarList parses the answer to LIST VAR <ups>, RFC 9271:
// BEGIN LIST VAR, one VAR line per variable, END LIST VAR, or one ERR line.
func readVarList(r *bufio.Reader, ups string) (map[string]string, error) {
	line, err := readLine(r)
	if err != nil {
		return nil, err
	}
	if code, ok := strings.CutPrefix(line, "ERR "); ok {
		return nil, fmt.Errorf("%w: %s", errUPSData, code)
	}
	if line != "BEGIN LIST VAR "+ups {
		return nil, fmt.Errorf("unexpected upsd reply %q", line)
	}
	vars := make(map[string]string)
	for range maxVarLines {
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		if line == "END LIST VAR "+ups {
			return vars, nil
		}
		name, value, err := parseVarLine(line, ups)
		if err != nil {
			return nil, err
		}
		vars[name] = value
	}
	return nil, fmt.Errorf("upsd listed more than %d variables", maxVarLines)
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadSlice('\n')
	if err != nil {
		if errors.Is(err, bufio.ErrBufferFull) {
			return "", fmt.Errorf("upsd line longer than %d bytes", maxLineLen)
		}
		return "", fmt.Errorf("read upsd reply: %w", err)
	}
	return strings.TrimRight(string(line), "\r\n"), nil
}

// parseVarLine splits VAR <ups> <name> "<value>", where the value escapes a
// double quote and a backslash with a backslash (RFC 9271).
func parseVarLine(line, ups string) (name, value string, err error) {
	rest, ok := strings.CutPrefix(line, "VAR "+ups+" ")
	if !ok {
		return "", "", fmt.Errorf("unexpected upsd line %q", line)
	}
	name, quoted, ok := strings.Cut(rest, " ")
	if !ok || name == "" || len(quoted) < 2 || quoted[0] != '"' || quoted[len(quoted)-1] != '"' {
		return "", "", fmt.Errorf("malformed upsd VAR line %q", line)
	}
	var b strings.Builder
	body := quoted[1 : len(quoted)-1]
	for i := 0; i < len(body); i++ {
		if body[i] == '\\' && i+1 < len(body) {
			i++
		}
		b.WriteByte(body[i])
	}
	return name, b.String(), nil
}
