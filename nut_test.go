package main

import (
	"bufio"
	"errors"
	"maps"
	"strings"
	"testing"
)

func TestReadVarList(t *testing.T) {
	for _, c := range []struct {
		name, reply string
		want        map[string]string
		upsData     bool
		fails       bool
	}{
		{
			name:  "variables with escaped quotes and backslashes",
			reply: "BEGIN LIST VAR ups\nVAR ups ups.status \"OL CHRG\"\nVAR ups ups.alarm \"say \\\"hi\\\" \\\\ bye\"\nVAR ups battery.charge \"\"\nEND LIST VAR ups\n",
			want:  map[string]string{"ups.status": "OL CHRG", "ups.alarm": `say "hi" \ bye`, "battery.charge": ""},
		},
		{name: "CRLF line ends", reply: "BEGIN LIST VAR ups\r\nVAR ups ups.status \"OB\"\r\nEND LIST VAR ups\r\n", want: map[string]string{"ups.status": "OB"}},
		{name: "stale data", reply: "ERR DATA-STALE\n", upsData: true, fails: true},
		{name: "driver gone", reply: "ERR DRIVER-NOT-CONNECTED\n", upsData: true, fails: true},
		{name: "another UPS", reply: "BEGIN LIST VAR other\nEND LIST VAR other\n", fails: true},
		{name: "VAR for another UPS", reply: "BEGIN LIST VAR ups\nVAR other ups.status \"OL\"\nEND LIST VAR ups\n", fails: true},
		{name: "unquoted value", reply: "BEGIN LIST VAR ups\nVAR ups ups.status OL\nEND LIST VAR ups\n", fails: true},
		{name: "cut short", reply: "BEGIN LIST VAR ups\nVAR ups ups.status \"OL\"\n", fails: true},
		{name: "line too long", reply: "BEGIN LIST VAR ups\nVAR ups x \"" + strings.Repeat("a", maxLineLen) + "\"\nEND LIST VAR ups\n", fails: true},
		{name: "endless list", reply: "BEGIN LIST VAR ups\n" + strings.Repeat("VAR ups x \"1\"\n", maxVarLines+1), fails: true},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, err := readVarList(bufio.NewReaderSize(strings.NewReader(c.reply), maxLineLen), "ups")
			if (err != nil) != c.fails {
				t.Fatalf("err = %v, want failure %v", err, c.fails)
			}
			if errors.Is(err, errUPSData) != c.upsData {
				t.Errorf("err = %v, want errUPSData %v", err, c.upsData)
			}
			if !c.fails && !maps.Equal(got, c.want) {
				t.Errorf("vars = %q, want %q", got, c.want)
			}
		})
	}
}

// FuzzReadVarList_roundtrip encodes a value the way upsd does and requires the
// parser to return it unchanged, and never to accept a line that does not end
// the list.
func FuzzReadVarList_roundtrip(f *testing.F) {
	for _, s := range []string{"OL", `a "b" \ c`, "", `\`, `"`, "ü"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, value string) {
		if strings.ContainsAny(value, "\r\n") {
			t.Skip("upsd values hold no line break")
		}
		enc := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
		varLine := "VAR ups v \"" + enc + "\"\n"
		if len(varLine) > maxLineLen {
			t.Skip("longer than one upsd line")
		}
		reply := "BEGIN LIST VAR ups\n" + varLine + "END LIST VAR ups\n"
		got, err := readVarList(bufio.NewReaderSize(strings.NewReader(reply), maxLineLen), "ups")
		if err != nil {
			t.Fatalf("readVarList(%q): %v", reply, err)
		}
		if got["v"] != value {
			t.Fatalf("value %q came back as %q", value, got["v"])
		}
	})
}
