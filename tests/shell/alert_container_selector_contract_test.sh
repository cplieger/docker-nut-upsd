#!/usr/bin/env bash
# The alert rules' consumer label against compose.yaml's container_name.
#
# WHY THIS IS A CONTRACT: every rule in alerts/logql.yaml selects its log stream with
# {container="<name>"} and groups by that label, and the only place the name is
# published is the shipped compose example. Rename it on one side, change a
# sum-by label, or add a rule with no selector at all, and the rules keep parsing,
# keep evaluating, and match nothing.
#
# The expected value is READ from compose.yaml rather than spelled a second time
# here, so renaming both sides together stays green -- which it should.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

compose_name=$(awk '$1 == "container_name:" { print $2; exit }' "$REPO_ROOT/compose.yaml")
if [ -z "$compose_name" ]; then
  printf 'harness error: compose.yaml has no container_name\n' >&2
  exit 1
fi

if detail=$(awk -v want="$compose_name" '
  function finish_rule() {
    if (in_rule && selectors == 0) {
      missing = missing " " alert
    }
  }
  /^[[:space:]]*- alert:/ {
    finish_rule()
    in_rule = 1
    in_expr = 0
    selectors = 0
    alert = $3
    next
  }
  in_rule && /^[[:space:]]*expr:[[:space:]]*\|/ {
    in_expr = 1
    next
  }
  in_expr && /^[[:space:]]*for:/ {
    in_expr = 0
    next
  }
  in_expr && /\{container="/ {
    value = $0
    sub(/^.*container="/, "", value)
    sub(/".*$/, "", value)
    selectors++
    if (value != want) {
      wrong = wrong " " alert "=" value
    }
  }
  in_expr && /sum by \(/ && $0 !~ /sum by \(container\)/ {
    grouping = grouping " " alert
  }
  END {
    finish_rule()
    if (!in_rule || missing != "" || wrong != "" || grouping != "") {
      printf "missing selectors:%s; wrong selectors:%s; wrong grouping:%s", missing, wrong, grouping
      exit 1
    }
  }
' "$REPO_ROOT/alerts/logql.yaml" 2>&1); then
  ok 'every alert rule selects and groups the container named by compose.yaml'
else
  no 'alert container selector contract' "$detail"
fi

report
