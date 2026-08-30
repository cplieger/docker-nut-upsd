#!/usr/bin/env bash
# The README's published alert summary against alerts.yaml.
#
# WHY THIS IS A CONTRACT: the README table is what a reader consults before
# loading the rule file, so an alert added, removed, renamed or re-graded on one
# side leaves the published inventory lying with nothing to catch it.
#
# Names and severity labels only: the "Fires when" prose is deliberately not
# pinned, so rewording an explanation stays green.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

alert_pairs=$(awk '
  /^[[:space:]]*- alert:/ { alert = $3; next }
  alert != "" && /^[[:space:]]+severity:/ {
    print alert "|" $2
    alert = ""
  }
' "$REPO_ROOT/alerts.yaml" | sort)

readme_pairs=$(awk -F '|' '
  /^\| Alert \| Fires when \| Severity \|$/ { in_table = 1; next }
  in_table && /^\| --- / { next }
  in_table && /^\|/ {
    name = $2
    severity = $4
    gsub(/[ `]/, "", name)
    gsub(/[ ]/, "", severity)
    print name "|" severity
    next
  }
  in_table { exit }
' "$REPO_ROOT/README.md" | sort)

if [ -z "$alert_pairs" ] || [ -z "$readme_pairs" ]; then
  printf 'harness error: could not extract both alert inventories\n' >&2
  exit 1
fi

if [ "$alert_pairs" = "$readme_pairs" ]; then
  ok 'README alert names and severities match alerts.yaml in both directions'
else
  no 'README alert inventory' "alerts.yaml: $alert_pairs; README.md: $readme_pairs"
fi

report
