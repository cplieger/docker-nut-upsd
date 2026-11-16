package main

import (
	"encoding/json"
	"fmt"
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

// variableQueries returns each query variable's PromQL, without the
// label_values or query_result wrapper Grafana adds.
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
	alertsRe      = regexp.MustCompile(`ALERTS\{alertname="([A-Za-z]+)"([^}]*)\}`)
	// bracedVariableRe matches ${name}, whose braces are no selector.
	bracedVariableRe = regexp.MustCompile(`\$\{\w+(?::\w+)?\}`)
	// matcherPartRe matches one label matcher. PromQL lets the label name be
	// quoted and takes a string in any of its three quotings.
	matcherPartRe = regexp.MustCompile(`^([a-zA-Z_][a-zA-Z0-9_]*|` + promqlString + `)\s*(=~|!~|!=|=)\s*(` + promqlString + `)$`)
	stringPartRe  = regexp.MustCompile(`^(?:` + promqlString + `)$`)
)

const promqlString = `"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|` + "`[^`]*`"

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

func unquote(s string) string {
	if s != "" && strings.ContainsRune("\"'`", rune(s[0])) {
		return s[1 : len(s)-1]
	}
	return s
}

type selectorBlock struct {
	text  string
	parts []string
}

// selectors returns each {...} block of expr, as written with its series name,
// split at its commas. Quoted strings are skipped, so a brace or comma inside
// a label value neither ends a block nor splits a matcher.
func selectors(expr string) []selectorBlock {
	var out []selectorBlock
	start, part := -1, 0
	var parts []string
	for i := 0; i < len(expr); i++ {
		switch c := expr[i]; {
		case c == '"' || c == '\'' || c == '`':
			i = skipString(expr, i) - 1
		case c == '{':
			start, part, parts = i, i+1, nil
		case (c == ',' || c == '}') && start >= 0:
			if p := strings.TrimSpace(expr[part:i]); p != "" {
				parts = append(parts, p)
			}
			part = i + 1
			if c == '}' {
				before := strings.TrimRight(expr[:start], " ")
				name := before[len(strings.TrimRightFunc(before, func(r rune) bool {
					return r == '_' || r == ':' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9'
				})):]
				out = append(out, selectorBlock{text: name + expr[start:i+1], parts: parts})
				start = -1
			}
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
// series fails the build instead of blanking a panel. up is the scrape's own
// series and ALERTS the ruler's.
func TestDashboardReadsOnlyExportedSeries(t *testing.T) {
	d := loadDashboard(t)
	exported := exportedSeries(t)
	queries := variableQueries(&d)
	for name, p := range d.Spec.Elements {
		for i, e := range panelExprs(&p) {
			queries[fmt.Sprintf("%s %s query %d", name, p.Spec.Title, i)] = e
		}
	}
	for where, expr := range queries {
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

// TestDashboardScopesEveryQueryToTheInstance fails when a query reads a series
// without the UPS variable's instance, or matches a label the user's scrape or
// log config names (job, hostname, container), so the dashboard works under
// any job name and shows only the picked exporter. The instance is matched
// exactly, never as a regular expression, because Grafana does not escape a
// single-select value: an IPv6 target's brackets or a host name's dots would
// match other instances. instance="" passes only beside instance="$instance",
// for the alert absent() raises with no instance.
func TestDashboardScopesEveryQueryToTheInstance(t *testing.T) {
	d := loadDashboard(t)
	queries := variableQueries(&d)
	for name, p := range d.Spec.Elements {
		for i, e := range panelExprs(&p) {
			queries[fmt.Sprintf("%s %s query %d", name, p.Spec.Title, i)] = e
		}
	}
	for where, expr := range queries {
		type pick struct{ series, matcher string }
		var picks []pick
		pinned := false
		for _, sel := range selectors(bracedVariableRe.ReplaceAllString(expr, "$$v")) {
			matched := false
			for _, part := range sel.parts {
				m := matcherPartRe.FindStringSubmatch(part)
				if m == nil {
					if !stringPartRe.MatchString(part) {
						t.Errorf("%s holds %q in %s, which is no label matcher", where, part, sel.text)
					}
					continue
				}
				switch label := unquote(m[1]); label {
				case "job", "hostname", "container":
					t.Errorf("%s matches %s on %s, a label the user's own config names", where, label, sel.text)
				case "instance":
					p := pick{series: sel.text, matcher: m[2] + `"` + unquote(m[3]) + `"`}
					pinned = pinned || p.matcher == `="$instance"`
					picks = append(picks, p)
					matched = true
				}
			}
			if !matched {
				picks = append(picks, pick{series: sel.text})
			}
		}
		for _, p := range picks {
			if p.matcher != `="$instance"` && (p.matcher != `=""` || !pinned) {
				t.Errorf("%s reads %s with instance matcher %q, want instance=\"$instance\"", where, p.series, p.matcher)
			}
		}
		// The instance variable lists every instance, so it alone reads unscoped.
		if bare := dashboardSeries(selectorRe.ReplaceAllString(expr, " ")); where != "instance" && len(bare) > 0 {
			t.Errorf("%s reads %v without a label matcher", where, bare)
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

// TestDashboardAttentionTilesMirrorEveryShippedRule fails when a rule in
// alerts/promql.yaml has no tile, or a tile names a rule the file does not
// hold. Each tile reads its rule's firing ALERTS series, so it shows exactly
// while the alert fires, and starts hidden until its query answers.
func TestDashboardAttentionTilesMirrorEveryShippedRule(t *testing.T) {
	d := loadDashboard(t)
	rules := ruleExprs(t, promqlRules)
	attention := row(t, tab(t, &d, "Overview"), "Needs attention")
	gate := attention.Spec.ConditionalRendering
	if gate == nil || gate.Spec.Visibility != "show" || len(gate.Spec.Items) != 1 ||
		gate.Spec.Items[0].Kind != "ConditionalRenderingVariable" ||
		gate.Spec.Items[0].Spec.Operator != "matches" || gate.Spec.Items[0].Spec.Value != "^[1-9]" {
		t.Fatal("Needs attention is not shown by a variable matching ^[1-9]")
	}
	counted := variableQueries(&d)[gate.Spec.Items[0].Spec.Variable]
	var mirrored []string
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
		for _, e := range panelExprs(&p) {
			if !strings.Contains(counted, "count("+e+")") {
				t.Errorf("%q query is not counted by the row's variable", p.Spec.Title)
			}
			for _, m := range alertsRe.FindAllStringSubmatch(e, -1) {
				if !strings.Contains(m[2], `alertstate="firing"`) {
					t.Errorf("%q reads %s alerts in any state, want only firing ones", p.Spec.Title, m[1])
				}
				if !strings.Contains(p.Spec.Description, m[1]) {
					t.Errorf("%q reads %s, which its description does not name", p.Spec.Title, m[1])
				}
				if !slices.Contains(mirrored, m[1]) {
					mirrored = append(mirrored, m[1])
				}
			}
		}
	}
	for name := range rules {
		if !slices.Contains(mirrored, name) {
			t.Errorf("%s has no attention tile", name)
		}
	}
	for _, name := range mirrored {
		if _, ok := rules[name]; !ok {
			t.Errorf("a tile mirrors %s, which %s does not hold", name, promqlRules)
		}
	}
}

var (
	// counterCallRe matches the opening of a call that needs two samples in
	// its window.
	counterCallRe = regexp.MustCompile(`\b(increase|rate|irate)\s*\(`)
	// oneSlotRangeRe matches a range or subquery range of exactly one
	// $__interval, in each of Grafana's spellings of it.
	oneSlotRangeRe = regexp.MustCompile(`\[\s*\$(?:__interval|\{__interval\}|\{__interval_ms\}ms)\s*(?::[^\]]*)?\]`)
)

// callArgs returns the arguments of the call whose parenthesis opens at
// expr[open], up to its matching parenthesis, skipping quoted strings.
func callArgs(expr string, open int) string {
	depth := 0
	for i := open; i < len(expr); i++ {
		switch expr[i] {
		case '"', '\'', '`':
			i = skipString(expr, i) - 1
		case '(':
			depth++
		case ')':
			if depth--; depth == 0 {
				return expr[open+1 : i]
			}
		}
	}
	return expr[open+1:]
}

// TestDashboardCountsNeverReadOneSlotRange fails when a query takes a
// counter's increase or rate over [$__interval]: at short ranges Grafana sets
// $__interval to the scrape interval, the window holds one sample, and the
// panel goes empty while the user zooms in on an incident.
func TestDashboardCountsNeverReadOneSlotRange(t *testing.T) {
	d := loadDashboard(t)
	queries := variableQueries(&d)
	for name, p := range d.Spec.Elements {
		for i, e := range panelExprs(&p) {
			queries[fmt.Sprintf("%s %s query %d", name, p.Spec.Title, i)] = e
		}
	}
	for where, expr := range queries {
		for _, loc := range counterCallRe.FindAllStringSubmatchIndex(expr, -1) {
			if oneSlotRangeRe.MatchString(callArgs(expr, loc[1]-1)) {
				t.Errorf("%s takes %s over [$__interval], want [$__rate_interval] or an offset difference", where, expr[loc[2]:loc[3]])
			}
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
