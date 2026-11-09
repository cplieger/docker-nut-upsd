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
	Kind string `json:"kind"`
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
		Name  string          `json:"name"`
		Query json.RawMessage `json:"query"`
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
)

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
		for _, problem := range selectorProblems(expr, exported, []string{"job", "instance"}) {
			t.Errorf("%s %s", where, problem)
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
	if gate == nil || len(gate.Spec.Items) != 1 || gate.Spec.Items[0].Kind != "ConditionalRenderingVariable" ||
		gate.Spec.Items[0].Spec.Value != "^[1-9]" {
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
		if cr == nil || cr.Spec.Condition != "or" ||
			!slices.Equal(conds, []string{"ConditionalRenderingData", "ConditionalRenderingTimeRangeSize"}) ||
			p.Spec.Data.Spec.QueryOptions.MaxDataPoints <= 0 {
			t.Errorf("%q can show before its query answers: want a has-data rule or'ed with a 0s range rule and a maxDataPoints pin", p.Spec.Title)
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
