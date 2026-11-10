package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

const promqlRules = "alerts/promql.yaml"

// ruleExprs returns each alert of a shipped rule file with its expression,
// read as text: the module carries no YAML parser.
func ruleExprs(t *testing.T, path string) map[string]string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	rules := make(map[string]string)
	for _, block := range strings.Split(string(raw), "- alert: ")[1:] {
		name, rest, _ := strings.Cut(block, "\n")
		_, expr, found := strings.Cut(rest, "expr: ")
		if !found {
			t.Fatalf("%s: %s has no expr", path, name)
		}
		expr, _, _ = strings.Cut(expr, "for:")
		rules[strings.TrimSpace(name)] = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(expr), "|"))
	}
	if len(rules) == 0 {
		t.Fatalf("%s defines no rule", path)
	}
	return rules
}

var (
	labelMatcherRe = regexp.MustCompile(`\{[^}]*\}`)
	groupingRe     = regexp.MustCompile(`\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)`)
	promRangeRe    = regexp.MustCompile(`\[[^\]]*\]`)
	identRe        = regexp.MustCompile(`[a-zA-Z_:][a-zA-Z0-9_:]*`)
	selectorRe     = regexp.MustCompile(`([a-zA-Z_:][a-zA-Z0-9_:]*)\{([^}]*)\}`)
	matcherRe      = regexp.MustCompile(`([a-zA-Z_][a-zA-Z0-9_]*)\s*(=~|!~|!=|=)\s*"([^"]*)"`)
)

// promqlWords are the PromQL keywords and functions the shipped rules may use;
// every other identifier in an expression is a series name.
var promqlWords = []string{
	"and", "or", "unless", "on", "ignoring", "group_left", "group_right", "by", "without", "bool",
	"sum", "min", "max", "avg", "count", "absent", "time", "rate", "increase", "changes", "resets",
	"min_over_time", "max_over_time", "avg_over_time", "sum_over_time", "count_over_time",
	"last_over_time", "present_over_time", "absent_over_time",
}

func seriesNames(expr string) []string {
	expr = labelMatcherRe.ReplaceAllString(expr, " ")
	expr = groupingRe.ReplaceAllString(expr, " ")
	expr = promRangeRe.ReplaceAllString(expr, " ")
	var names []string
	for _, word := range identRe.FindAllString(expr, -1) {
		if !slices.Contains(promqlWords, word) && !slices.Contains(names, word) {
			names = append(names, word)
		}
	}
	return names
}

// exportedSeries builds the exporter the way run does and reads it over a
// UPS that reports every flag and variable, with every wrapper state file
// written, so every family has its samples. It returns each family's label
// values by label name.
func exportedSeries(t *testing.T) map[string]map[string][]string {
	t.Helper()
	upsd := newFakeUpsd(t, "ups")
	vars := [][2]string{{"ups.status", strings.Join(statusFlags[:len(statusFlags)-1], " ")}}
	for _, v := range upsVariables {
		vars = append(vars, [2]string{v.nut, "1"})
	}
	upsd.set(vars, "")
	dir := t.TempDir()
	for name, value := range map[string]string{driverRestartsFile: "1", poweroffPathFile: "1", upsmonPIDFile: "1"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	exp := newExporter(upsdClient{addr: upsd.ln.Addr().String(), ups: "ups"}, wrapperState{dir: dir, proc: "/proc"}, true)
	families := make(map[string]map[string][]string)
	for key := range gather(t, exp) {
		name, labels, _ := strings.Cut(key, "|")
		if families[name] == nil {
			families[name] = make(map[string][]string)
		}
		if labels != "" {
			// ups_status is the one labelled family; its label is flag.
			families[name]["flag"] = append(families[name]["flag"], labels)
		}
	}
	return families
}

// TestPromQLRulesReadOnlyExportedSeries fails when a shipped PromQL rule reads
// a series, a label or a flag the exporter does not serve, so a renamed or
// dropped series fails the build instead of silencing an alert.
func TestPromQLRulesReadOnlyExportedSeries(t *testing.T) {
	exported := exportedSeries(t)
	scrapeLabels := []string{"job", "instance"}
	for alert, expr := range ruleExprs(t, promqlRules) {
		names := seriesNames(expr)
		if len(names) == 0 {
			t.Errorf("%s reads no series: %s", alert, expr)
		}
		for _, name := range names {
			if _, ok := exported[name]; !ok && name != "up" {
				t.Errorf("%s reads %s, which the exporter does not serve", alert, name)
			}
		}
		for _, problem := range selectorProblems(expr, exported, scrapeLabels) {
			t.Errorf("%s %s", alert, problem)
		}
	}
}

// selectorProblems lists each label matcher in expr that names a label the
// exporter does not set on that series, or a value it never serves there. A
// matcher on a scrape label, or one whose value is a dashboard variable, is
// not checked.
func selectorProblems(expr string, exported map[string]map[string][]string, scrapeLabels []string) []string {
	var problems []string
	for _, sel := range selectorRe.FindAllStringSubmatch(expr, -1) {
		labels, ok := exported[sel[1]]
		if !ok {
			continue
		}
		for _, m := range matcherRe.FindAllStringSubmatch(sel[2], -1) {
			values, known := labels[m[1]]
			if !known {
				if !slices.Contains(scrapeLabels, m[1]) {
					problems = append(problems, fmt.Sprintf("matches label %s on %s, which the exporter does not set", m[1], sel[1]))
				}
				continue
			}
			for want := range strings.SplitSeq(m[3], "|") {
				if !strings.HasPrefix(want, "$") && !slices.Contains(values, want) {
					problems = append(problems, fmt.Sprintf("matches %s=%q on %s, which the exporter never serves", m[1], want, sel[1]))
				}
			}
		}
	}
	return problems
}

// TestNutUpsdDownHasBothArms keeps both arms of the down rule: up == 0 for a
// target that fails its scrape, absent for one that is gone.
func TestNutUpsdDownHasBothArms(t *testing.T) {
	expr, ok := ruleExprs(t, promqlRules)["NutUpsdDown"]
	if !ok {
		t.Fatal("alerts/promql.yaml has no NutUpsdDown")
	}
	const want = `up{job="nut-upsd"} == 0 or absent(up{job="nut-upsd"})`
	if expr != want {
		t.Errorf("NutUpsdDown = %q, want %q", expr, want)
	}
}
