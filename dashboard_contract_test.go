package main

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
)

const dashboardFile = "grafana-dashboard.json"

type dashQuery struct {
	Spec struct {
		Query struct {
			Spec struct {
				Expr  string `json:"expr"`
				Query string `json:"query"`
			} `json:"spec"`
		} `json:"query"`
	} `json:"spec"`
}

type dashPanel struct {
	Spec struct {
		Title       string `json:"title"`
		Description string `json:"description"`
		Data        struct {
			Spec struct {
				Queries      []dashQuery `json:"queries"`
				QueryOptions struct {
					MaxDataPoints int `json:"maxDataPoints"`
				} `json:"queryOptions"`
			} `json:"spec"`
		} `json:"data"`
		VizConfig struct {
			Group string `json:"group"`
			Spec  struct {
				FieldConfig struct {
					Defaults struct {
						NoValue string `json:"noValue"`
					} `json:"defaults"`
				} `json:"fieldConfig"`
			} `json:"spec"`
		} `json:"vizConfig"`
	} `json:"spec"`
}

type conditionRule struct {
	Kind string `json:"kind"`
	Spec struct {
		Value    any    `json:"value"`
		Variable string `json:"variable"`
		Operator string `json:"operator"`
	} `json:"spec"`
}

type conditionGroup struct {
	Spec struct {
		Visibility string          `json:"visibility"`
		Condition  string          `json:"condition"`
		Items      []conditionRule `json:"items"`
	} `json:"spec"`
}

type gridItem struct {
	Spec struct {
		ConditionalRendering *conditionGroup `json:"conditionalRendering"`
		Element              struct {
			Name string `json:"name"`
		} `json:"element"`
	} `json:"spec"`
}

type layoutNode struct {
	Spec struct {
		Layout               *layoutNode     `json:"layout"`
		ConditionalRendering *conditionGroup `json:"conditionalRendering"`
		Title                string          `json:"title"`
		Tabs                 []layoutNode    `json:"tabs"`
		Rows                 []layoutNode    `json:"rows"`
		Items                []gridItem      `json:"items"`
	} `json:"spec"`
}

type dashVariable struct {
	Kind string `json:"kind"`
	Spec struct {
		Name       string          `json:"name"`
		Definition string          `json:"definition"`
		Regex      string          `json:"regex"`
		Refresh    string          `json:"refresh"`
		Query      json.RawMessage `json:"query"`
	} `json:"spec"`
}

type dashboard struct {
	Spec struct {
		Elements  map[string]dashPanel `json:"elements"`
		Layout    layoutNode           `json:"layout"`
		Variables []dashVariable       `json:"variables"`
		Preload   bool                 `json:"preload"`
	} `json:"spec"`
}

func loadDashboard(t *testing.T) dashboard {
	t.Helper()
	raw, err := os.ReadFile(dashboardFile)
	if err != nil {
		t.Fatalf("reading %s: %v", dashboardFile, err)
	}
	var d dashboard
	if err := json.Unmarshal(raw, &d); err != nil {
		t.Fatalf("decoding %s: %v", dashboardFile, err)
	}
	if len(d.Spec.Elements) == 0 {
		t.Fatalf("%s holds no panel", dashboardFile)
	}
	return d
}

func panelExprs(p *dashPanel) []string {
	var out []string
	for _, q := range p.Spec.Data.Spec.Queries {
		out = append(out, q.Spec.Query.Spec.Expr)
	}
	return out
}

// variableQueries returns each query variable's stored query text, by name.
func variableQueries(d *dashboard) map[string]string {
	out := map[string]string{}
	for _, v := range d.Spec.Variables {
		if v.Kind != "QueryVariable" {
			continue
		}
		var q dashQuery
		if err := json.Unmarshal(v.Spec.Query, &q.Spec.Query); err == nil {
			out[v.Spec.Name] = q.Spec.Query.Spec.Query
		}
	}
	return out
}

// dashboardQueries returns every query variable's and panel's query, keyed by
// where it sits, with its # comments removed so no check reads a comment as
// a query.
func dashboardQueries(d *dashboard) map[string]string {
	queries := map[string]string{}
	for name, q := range variableQueries(d) {
		queries["variable "+name] = withoutComments(q)
	}
	for name, p := range d.Spec.Elements {
		for i, e := range panelExprs(&p) {
			queries[fmt.Sprintf("%s %s query %d", name, p.Spec.Title, i)] = withoutComments(e)
		}
	}
	return queries
}

func tab(t *testing.T, d *dashboard, title string) *layoutNode {
	t.Helper()
	for i := range d.Spec.Layout.Spec.Tabs {
		if tb := &d.Spec.Layout.Spec.Tabs[i]; tb.Spec.Title == title {
			return tb
		}
	}
	t.Fatalf("no tab titled %q", title)
	return nil
}

func row(t *testing.T, tb *layoutNode, title string) *layoutNode {
	t.Helper()
	for i := range tb.Spec.Layout.Spec.Rows {
		if r := &tb.Spec.Layout.Spec.Rows[i]; r.Spec.Title == title {
			return r
		}
	}
	t.Fatalf("tab %q has no row titled %q", tb.Spec.Title, title)
	return nil
}

var (
	quotedRe      = regexp.MustCompile(`"(?:[^"\\]|\\.)*"`)
	functionRe    = regexp.MustCompile(`\b[a-z_]+\s*\(`)
	labelValuesRe = regexp.MustCompile(`label_values\(([^,]+),\s*\w+\)`)
	variableRe    = regexp.MustCompile(`\$\{?\w+(?::\w+)?\}?`)
	alertsRe      = regexp.MustCompile(`ALERTS\{alertname="(\w+)"`)
	// bracedVariableRe matches ${name}, whose braces are no selector.
	bracedVariableRe = regexp.MustCompile(`\$\{\w+(?::\w+)?\}`)
	// absentCallRe matches a call of absent() or absent_over_time(); PromQL
	// lets whitespace stand before a call's parenthesis.
	absentCallRe = regexp.MustCompile(`(?:^|[^\w:])absent(?:_over_time)?\s*\(`)
)

// skipString returns the index just past the string literal opening at s[i].
func skipString(s string, i int) int {
	q := s[i]
	for i++; i < len(s); i++ {
		switch {
		case s[i] == '\\' && q != '`':
			i++
		case s[i] == q:
			return i + 1
		}
	}
	return len(s)
}

// withoutComments drops each # comment from expr, up to its newline. A # inside
// a string literal opens no comment, and a quote inside a comment opens no
// string.
func withoutComments(expr string) string {
	var b strings.Builder
	for i := 0; i < len(expr); {
		switch expr[i] {
		case '#':
			if j := strings.IndexByte(expr[i:], '\n'); j >= 0 {
				i += j
			} else {
				i = len(expr)
			}
		case '"', '\'', '`':
			j := skipString(expr, i)
			b.WriteString(expr[i:j])
			i = j
		default:
			b.WriteByte(expr[i])
			i++
		}
	}
	return b.String()
}

type selectorBlock struct {
	name, text string
}

// selectors returns each {...} block of expr with the series name written
// before it, empty when none, a keyword (x or {...}) or a variable ($v{...})
// is. Quoted strings are skipped, so a brace inside a label value ends no
// block.
func selectors(expr string) []selectorBlock {
	var out []selectorBlock
	start := -1
	for i := 0; i < len(expr); i++ {
		switch c := expr[i]; {
		case c == '"' || c == '\'' || c == '`':
			i = skipString(expr, i) - 1
		case c == '{':
			start = i
		case c == '}' && start >= 0:
			before := strings.TrimRight(expr[:start], " ")
			name := before[len(strings.TrimRightFunc(before, func(r rune) bool {
				return r == '_' || r == ':' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9'
			})):]
			if slices.Contains(promqlWords, name) || strings.HasSuffix(before[:len(before)-len(name)], "$") {
				name = ""
			}
			out = append(out, selectorBlock{name: name, text: name + expr[start:i+1]})
			start = -1
		}
	}
	return out
}

// dashboardSeries returns the series names a panel or variable query reads;
// label_values names a label after its series, which is no series.
func dashboardSeries(expr string) []string {
	expr = labelValuesRe.ReplaceAllString(expr, "$1")
	expr = labelMatcherRe.ReplaceAllString(expr, " ")
	expr = quotedRe.ReplaceAllString(expr, " ")
	expr = variableRe.ReplaceAllString(expr, " ")
	expr = strings.ReplaceAll(expr, "query_result(", "(")
	expr = functionRe.ReplaceAllString(expr, "(")
	return seriesNames(expr)
}

// TestDashboardReadsOnlyExportedSeries fails when a panel or a variable reads
// a series, a label or a flag the exporter does not serve, so a renamed
// series fails the build instead of blanking a panel. It also fails a selector
// with no series name before its braces, which this test and the ALERTS pin
// cannot read. up is the scrape's own series and ALERTS the ruler's.
func TestDashboardReadsOnlyExportedSeries(t *testing.T) {
	d := loadDashboard(t)
	exported := exportedSeries(t)
	for where, expr := range dashboardQueries(&d) {
		for _, sel := range selectors(bracedVariableRe.ReplaceAllString(expr, "$$v")) {
			if sel.name == "" {
				t.Errorf("%s has a selector with no series name before its braces, which this check cannot read: %s", where, sel.text)
			}
		}
		for _, name := range dashboardSeries(expr) {
			if _, ok := exported[name]; !ok && name != "up" && name != "ALERTS" {
				t.Errorf("%s reads %s, which the exporter does not serve", where, name)
			}
		}
		for _, problem := range selectorProblems(expr, exported, []string{"instance"}) {
			t.Errorf("%s %s", where, problem)
		}
	}
}

// TestDashboardInstancePickerListsEveryUPS fails when the instance variable
// reads anything but every UPS's upsd_up series, filters what it reads with a
// regex, or never refreshes, so the picker lists every UPS the query finds.
func TestDashboardInstancePickerListsEveryUPS(t *testing.T) {
	d := loadDashboard(t)
	if got, want := variableQueries(&d)["instance"], "label_values(nut_upsd_upsd_up, instance)"; got != want {
		t.Errorf("the instance variable must read exactly\n%s\nso the picker lists every UPS; it reads\n%s", want, got)
	}
	for _, v := range d.Spec.Variables {
		if v.Spec.Name == "instance" && (v.Spec.Regex != "" || v.Spec.Refresh == "never") {
			t.Errorf("the instance variable has regex %q and refresh %q: a regex, or a refresh of never, hides UPSs its query lists", v.Spec.Regex, v.Spec.Refresh)
		}
	}
}

// TestDashboardVariableDefinitionsMatchTheirQueries fails when a query
// variable's definition, the text Grafana's variable editor shows, differs
// from the query it runs.
func TestDashboardVariableDefinitionsMatchTheirQueries(t *testing.T) {
	d := loadDashboard(t)
	queries := variableQueries(&d)
	for _, v := range d.Spec.Variables {
		if v.Kind == "QueryVariable" && v.Spec.Definition != queries[v.Spec.Name] {
			t.Errorf("variable %s shows definition\n%s\nbut runs\n%s", v.Spec.Name, v.Spec.Definition, queries[v.Spec.Name])
		}
	}
}

// promqlCode is expr with its string literals and # comments blanked, so a
// function name inside one is not read as a call.
func promqlCode(expr string) string {
	b := []byte(expr)
	for i := 0; i < len(b); i++ {
		switch b[i] {
		case '"', '\'', '`':
			end := skipString(expr, i)
			for j := i; j < end; j++ {
				b[j] = ' '
			}
			i = end - 1
		case '#':
			for ; i < len(b) && b[i] != '\n'; i++ {
				b[i] = ' '
			}
		}
	}
	return string(b)
}

type flagRead struct {
	flag  string
	value int
}

// flagTiles holds each tile that tells its rule's flags apart: the aggregation
// and the number each flag's read adds, which the panel's value mappings put
// into words. flag="" reads the rule's arm on a series with no flag label.
var flagTiles = map[string]struct {
	agg   string
	reads []flagRead
}{
	"NutUpsdHardwareFault":         {"sum", []flagRead{{"RB", 1}, {"ALARM", 2}}},
	"NutUpsdProtectionDegraded":    {"max", []flagRead{{"BYPASS", 3}, {"OVER", 2}, {"CAL", 1}}},
	"NutUpsdProtectionUnavailable": {"max", []flagRead{{"OFF", 2}, {"", 1}}},
}

func skipSpace(s string, i int) int {
	for i < len(s) && strings.IndexByte(" \t\r\n", s[i]) >= 0 {
		i++
	}
	return i
}

// matcherToken returns the label name or string literal at s[i], without its
// quotes, whether it was quoted, and the index just past it.
func matcherToken(s string, i int) (tok string, quoted bool, next int, err error) {
	if q := s[i]; q == '"' || q == '\'' || q == '`' {
		end := skipString(s, i)
		if end-i < 2 || s[end-1] != q {
			return "", false, 0, fmt.Errorf("unterminated string %s", s[i:])
		}
		return s[i+1 : end-1], true, end, nil
	}
	j := i
	for j < len(s) && (s[j] == '_' || s[j] >= 'a' && s[j] <= 'z' || s[j] >= 'A' && s[j] <= 'Z' || s[j] >= '0' && s[j] <= '9') {
		j++
	}
	if j == i {
		return "", false, 0, fmt.Errorf("no label name at %q", s[i:])
	}
	return s[i:j], false, j, nil
}

// flaggedSeries is the one exported family with a flag label.
const flaggedSeries = "nut_upsd_ups_status"

// ruleFlags returns the flags expr's flag matchers read, in any PromQL quoting
// and spacing, each =~ value split at |. It fails on a != or !~ flag matcher,
// since a tile cannot mirror a flag set by exclusion; on a =~ value that is not
// a | list of literal flags; on a flaggedSeries read with no flag matcher,
// which matches every flag; on a selector with no series name; and on an
// escape in a quoted label name or a flag, which this reader does not decode.
func ruleFlags(expr string) ([]string, error) {
	var flags []string
	flagged := 0
	for _, sel := range selectors(withoutComments(expr)) {
		if sel.name == "" {
			return nil, fmt.Errorf("%s has no series name before its braces, which this reader cannot read", sel.text)
		}
		body := sel.text[strings.IndexByte(sel.text, '{')+1 : len(sel.text)-1]
		hasFlag := false
		for i := skipSpace(body, 0); i < len(body); i = skipSpace(body, i) {
			name, quoted, next, err := matcherToken(body, i)
			if err != nil {
				return nil, err
			}
			if quoted && strings.Contains(name, `\`) {
				return nil, fmt.Errorf("label name %q holds an escape; write it without one", name)
			}
			if i = skipSpace(body, next); i >= len(body) || body[i] == ',' {
				i++
				continue
			}
			op := "="
			for _, o := range []string{"=~", "!~", "!="} {
				if strings.HasPrefix(body[i:], o) {
					op = o
				}
			}
			if !strings.HasPrefix(body[i:], op) {
				return nil, fmt.Errorf("no matcher operator after %s in %s", name, sel.text)
			}
			i = skipSpace(body, i+len(op))
			value, quoted, next, err := matcherToken(body, i)
			if err != nil || !quoted {
				return nil, fmt.Errorf("no quoted value after %s%s in %s", name, op, sel.text)
			}
			if name == "flag" {
				hasFlag = true
				switch {
				case op[0] == '!':
					return nil, fmt.Errorf("%s matches flag with %s; a tile cannot mirror a flag set by exclusion, so name the flags", sel.text, op)
				case strings.Contains(value, `\`):
					return nil, fmt.Errorf("%s holds an escape in its flag; write the flag without escapes", sel.text)
				case op == "=~":
					for piece := range strings.SplitSeq(value, "|") {
						if piece == "" || strings.ContainsAny(piece, `.*+?()[]{}^$`) {
							return nil, fmt.Errorf("%s matches flag with a regex that is not a | list of flags; write flag=\"RB\" or flag=~\"RB|ALARM\"", sel.text)
						}
						flags = append(flags, piece)
					}
				default:
					flags = append(flags, value)
				}
			}
			if i = skipSpace(body, next); i < len(body) {
				if body[i] != ',' {
					return nil, fmt.Errorf("unexpected %q after a matcher in %s", body[i:], sel.text)
				}
				i++
			}
		}
		if hasFlag && sel.name == flaggedSeries {
			flagged++
		}
	}
	reads := 0
	for _, word := range identRe.FindAllString(labelMatcherRe.ReplaceAllString(promqlCode(expr), " "), -1) {
		if word == flaggedSeries {
			reads++
		}
	}
	if reads != flagged {
		return nil, fmt.Errorf("%d of %d %s reads name a flag; an arm without flag= or flag=~ matches every flag, so name them", flagged, reads, flaggedSeries)
	}
	return flags, nil
}

// attentionReads is every ALERTS selector a query may read the rule name's
// firing alerts with, for the rule expression expr, in its tile's order.
// absent() and absent_over_time() label their alert with only the selector's
// equality matchers, and a shipped rule's selector names no instance, so only
// such a rule's alert is also read with instance="":
// https://prometheus.io/docs/prometheus/latest/querying/functions/#absent
func attentionReads(name, expr string) []string {
	read := `ALERTS{alertname="` + name + `", alertstate="firing", instance=`
	if ft, ok := flagTiles[name]; ok {
		var reads []string
		for _, f := range ft.reads {
			reads = append(reads, read+`"$instance", flag="`+f.flag+`"}`)
		}
		return reads
	}
	if absentCallRe.MatchString(promqlCode(expr)) {
		return []string{read + `"$instance"}`, read + `""}`}
	}
	return []string{read + `"$instance"}`}
}

// attentionTile is the query of the Needs attention tile for the rule name
// with expression expr, which answers while any of its reads does.
func attentionTile(name, expr string) string {
	reads := attentionReads(name, expr)
	if ft, ok := flagTiles[name]; ok {
		parts := make([]string, len(reads))
		for i, r := range reads {
			parts[i] = fmt.Sprintf("%s * 0 + %d", r, ft.reads[i].value)
		}
		return ft.agg + "(" + strings.Join(parts, " or ") + ")"
	}
	if len(reads) == 2 {
		return `0 * max((` + reads[0] + ` or ` + reads[1] + `))`
	}
	return `0 * max(` + reads[0] + `)`
}

// TestDashboardAttentionTilesMirrorEveryShippedRule fails when a rule in
// alerts/promql.yaml has no Needs attention tile, a tile names a rule the file
// does not hold or does not name it in its description, a tile's query is not
// exactly attentionTile's for its rule, a flag tile misses or adds a flag its
// rule reads, the row's variable does not count exactly those tiles in layout
// order, a tile is not hidden until its query answers, any query reads an
// ALERTS selector that is not one of attentionReads' for a shipped rule, or a
// query reads a rule with instance="" but not with instance="$instance".
func TestDashboardAttentionTilesMirrorEveryShippedRule(t *testing.T) {
	d := loadDashboard(t)
	rules := ruleExprs(t, promqlRules)
	for where, expr := range dashboardQueries(&d) {
		sels := selectors(bracedVariableRe.ReplaceAllString(expr, "$$v"))
		var texts []string
		for _, sel := range sels {
			texts = append(texts, sel.text)
		}
		for _, sel := range sels {
			if sel.name != "ALERTS" {
				continue
			}
			name := ""
			if m := alertsRe.FindStringSubmatch(sel.text); m != nil {
				name = m[1]
			}
			rule, ok := rules[name]
			switch {
			case name == "":
				t.Errorf("%s reads %s, which does not start with alertname=\"<rule>\": every ALERTS read is one of attentionReads' texts, alertname first", where, sel.text)
				continue
			case !ok:
				t.Errorf("%s reads %s, whose alertname names no rule in %s", where, sel.text, promqlRules)
				continue
			}
			reads := attentionReads(name, rule)
			switch {
			case !slices.Contains(reads, sel.text):
				t.Errorf("%s reads %s; a read of %s must be exactly one of these, so it shows only the picked UPS's firing alerts:\n%s", where, sel.text, name, strings.Join(reads, "\n"))
			case strings.HasSuffix(sel.text, `instance=""}`) && !slices.Contains(texts, reads[0]):
				t.Errorf("%s reads %s without %s in the same query: a read of only instance=\"\" misses the rule's alerts for the picked UPS", where, sel.text, reads[0])
			}
		}
	}
	for name, ft := range flagTiles {
		expr, ok := rules[name]
		if !ok {
			t.Errorf("flagTiles holds %s, which %s does not hold", name, promqlRules)
			continue
		}
		want, err := ruleFlags(expr)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if slices.ContainsFunc(seriesNames(expr), func(n string) bool { return n != flaggedSeries }) {
			want = append(want, "")
		}
		var got []string
		for _, f := range ft.reads {
			got = append(got, f.flag)
		}
		slices.Sort(want)
		want = slices.Compact(want)
		slices.Sort(got)
		if !slices.Equal(got, want) || absentCallRe.MatchString(promqlCode(expr)) {
			t.Errorf("%s's tile reads flags %q, want %q, the flags its rule reads with \"\" for an arm on a series with no flag label, and no absent() arm", name, got, want)
		}
	}
	attention := row(t, tab(t, &d, "Overview"), "Needs attention")
	gate := attention.Spec.ConditionalRendering
	if gate == nil || gate.Spec.Visibility != "show" || len(gate.Spec.Items) != 1 ||
		gate.Spec.Items[0].Kind != "ConditionalRenderingVariable" ||
		gate.Spec.Items[0].Spec.Operator != "matches" || gate.Spec.Items[0].Spec.Value != "^[1-9]" {
		t.Fatal("Needs attention is not shown by a variable matching ^[1-9]")
	}
	var mirrored, counts []string
	for _, it := range attention.Spec.Layout.Spec.Items {
		p := d.Spec.Elements[it.Spec.Element.Name]
		cr := it.Spec.ConditionalRendering
		var conds []string
		if cr != nil {
			for _, c := range cr.Spec.Items {
				conds = append(conds, c.Kind)
			}
		}
		slices.Sort(conds)
		if cr == nil || cr.Spec.Visibility != "show" || cr.Spec.Condition != "or" ||
			!slices.Equal(conds, []string{"ConditionalRenderingData", "ConditionalRenderingTimeRangeSize"}) ||
			p.Spec.Data.Spec.QueryOptions.MaxDataPoints <= 0 {
			t.Errorf("%q does not show exactly while its query answers: want a shown group or'ing a has-data rule with a 0s range rule, and a maxDataPoints pin", p.Spec.Title)
		}
		exprs := panelExprs(&p)
		if len(exprs) != 1 {
			t.Errorf("%q holds %d queries, want 1", p.Spec.Title, len(exprs))
			continue
		}
		counts = append(counts, fmt.Sprintf(`label_replace(count(%s), "tile", "%s", "", "")`, exprs[0], strings.TrimPrefix(it.Spec.Element.Name, "panel-")))
		m := alertsRe.FindStringSubmatch(exprs[0])
		if m == nil {
			t.Errorf("%q reads no ALERTS series by alertname: %s", p.Spec.Title, exprs[0])
			continue
		}
		name := m[1]
		mirrored = append(mirrored, name)
		if !strings.Contains(p.Spec.Description, name) {
			t.Errorf("%q reads %s, which its description does not name", p.Spec.Title, name)
		}
		expr, ok := rules[name]
		if !ok {
			t.Errorf("a tile mirrors %s, which %s does not hold", name, promqlRules)
			continue
		}
		if want := attentionTile(name, expr); exprs[0] != want {
			t.Errorf("%q must read exactly\n%s\nso it shows only the picked UPS's firing %s alerts; it reads\n%s",
				p.Spec.Title, want, name, exprs[0])
		}
	}
	if got, want := variableQueries(&d)[gate.Spec.Items[0].Spec.Variable], "query_result(count("+strings.Join(counts, " or ")+") or vector(0))"; got != want {
		t.Errorf("the row's variable must count exactly its tiles in layout order:\n%s\nit reads\n%s", want, got)
	}
	for _, name := range slices.Sorted(maps.Keys(rules)) {
		if !slices.Contains(mirrored, name) {
			t.Errorf("%s has no Needs attention tile reading its firing alerts", name)
		}
	}
}

// TestDashboardQueriesAreTheTestedOnes fails when a panel query differs from
// the one alerts/promql_test.yaml evaluates under its anchor, with $instance
// as [::1]:9199 and $__interval as the anchor's slot: 1m, the scrape interval
// where a slot holds one sample, or 5m, where a counter reset can recover
// inside the slot. A change to either runs through promtool in CI.
func TestDashboardQueriesAreTheTestedOnes(t *testing.T) {
	d := loadDashboard(t)
	raw, err := os.ReadFile("alerts/promql_test.yaml")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ title, anchor, slot string }{
		{"Exporter down", "exporter_down", "1m"},
		{"Driver restarts", "driver_restarts", "1m"},
		{"Driver restarts", "driver_restarts_5m", "5m"},
	} {
		t.Run(tc.anchor, func(t *testing.T) {
			var exprs []string
			for _, p := range d.Spec.Elements {
				if p.Spec.Title == tc.title {
					exprs = append(exprs, panelExprs(&p)...)
				}
			}
			if len(exprs) != 1 {
				t.Fatalf("found %d %s queries, want 1", len(exprs), tc.title)
			}
			m := regexp.MustCompile(`(?m)expr: &` + tc.anchor + ` '([^']*)'$`).FindSubmatch(raw)
			if m == nil {
				t.Fatalf("alerts/promql_test.yaml has no expr anchored as %s", tc.anchor)
			}
			fill := strings.NewReplacer(`$instance`, "[::1]:9199", `$__interval`, tc.slot)
			if want := fill.Replace(exprs[0]); string(m[1]) != want {
				t.Errorf("alerts/promql_test.yaml tests\n%s\nthe dashboard reads, with its variables filled in,\n%s", m[1], want)
			}
		})
	}
}

// TestDashboardStatusNamesEveryFlag fails when the status box shows a
// ups.status flag as its raw token instead of words.
func TestDashboardStatusNamesEveryFlag(t *testing.T) {
	d := loadDashboard(t)
	var status string
	for _, it := range row(t, tab(t, &d, "Overview"), "UPS now").Spec.Layout.Spec.Items {
		if p := d.Spec.Elements[it.Spec.Element.Name]; p.Spec.Title == "Status" {
			status = strings.Join(panelExprs(&p), "\n")
		}
	}
	if status == "" {
		t.Fatal("UPS now has no Status panel")
	}
	for _, flag := range statusFlags {
		if !strings.Contains(status, `, "flag", "`+flag+`")`) {
			t.Errorf("Status gives the %s flag no words", flag)
		}
	}
}

func TestDashboardPanelsExplainThemselves(t *testing.T) {
	d := loadDashboard(t)
	if !d.Spec.Preload {
		t.Error("spec.preload = false, want true so a hidden tile below the fold still queries")
	}
	tabs := d.Spec.Layout.Spec.Tabs
	if len(tabs) < 2 || tabs[0].Spec.Title != "Overview" || tabs[len(tabs)-1].Spec.Title != "Exporter health" {
		t.Errorf("tabs must open on Overview and end on Exporter health")
	}
	for name, p := range d.Spec.Elements {
		if strings.TrimSpace(p.Spec.Description) == "" {
			t.Errorf("%s %q has no description", name, p.Spec.Title)
		}
		switch p.Spec.VizConfig.Group {
		case "stat", "gauge", "bargauge", "table":
			if strings.TrimSpace(p.Spec.VizConfig.Spec.FieldConfig.Defaults.NoValue) == "" {
				t.Errorf("%s %q has no no-value text", name, p.Spec.Title)
			}
		}
	}
}
