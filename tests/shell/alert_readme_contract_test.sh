#!/usr/bin/env bash
# The README's published alert summary against the alerts/ bundle.
#
# WHY THIS IS A CONTRACT: the README table is what a reader consults before
# loading the rule file, so an alert added, removed, renamed or re-graded on one
# side leaves the published inventory lying with nothing to catch it.
#
# Reads every file in alerts/ rather than one filename. The folder holds one
# file per expression language, and the README table publishes the whole
# bundle, so a rule added in a second language belongs in that table too.
#
# Names and severity labels only: the "Fires when" prose is deliberately not
# pinned, so rewording an explanation stays green.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

# Assert the bundle before reading it: an empty glob and a bundle with no rules
# both yield no pairs, and only the first is a moved or renamed folder.
mapfile -t alert_files < <(find "$REPO_ROOT/alerts" -maxdepth 1 -name '*.yaml' -type f | sort)
if [ "${#alert_files[@]}" -eq 0 ]; then
  printf 'harness error: no rule files under %s/alerts\n' "$REPO_ROOT" >&2
  exit 1
fi

alert_pairs=$(awk '
  /^[[:space:]]*- alert:/ { alert = $3; next }
  alert != "" && /^[[:space:]]+severity:/ {
    print alert "|" $2
    alert = ""
  }
' "${alert_files[@]}" | sort)

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
  ok 'README alert names and severities match the alerts/ bundle in both directions'
else
  no 'README alert inventory' "alerts/: $alert_pairs; README.md: $readme_pairs"
fi

report
