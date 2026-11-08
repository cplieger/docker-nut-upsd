#!/usr/bin/env bash
# alerts/logql.yaml holds two groups by role. nut-upsd-events is always loaded,
# because its events leave no series; nut-upsd-state is the alternative to
# alerts/promql.yaml, so every alert in it must exist there under the same name,
# or a Prometheus user who skips the group loses that alert.
#
# Lint directive for this whole file, against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

LOGQL="${LOGQL:-$REPO_ROOT/alerts/logql.yaml}"
PROMQL="${PROMQL:-$REPO_ROOT/alerts/promql.yaml}"
for f in "$LOGQL" "$PROMQL"; do
  if [ ! -r "$f" ]; then
    printf 'harness error: %s is not readable\n' "$f" >&2
    exit 1
  fi
done

# group_names <file> -> the group names in file order.
group_names() {
  sed -n 's/^  - name: \(.*\)$/\1/p' "$1"
}

# group_alerts <file> <group> -> the alert names of one group, sorted.
group_alerts() {
  awk -v want="$2" '
    /^  - name: / { ingroup = ($3 == want); next }
    ingroup && /^      - alert: / { print $3 }
  ' "$1" | sort
}

# role_line <group> -> the comment block directly above the group's name line,
# joined into one line.
role_line() {
  awk -v want="$1" '
    /^  #/ { sub(/^  # ?/, ""); block = block (block == "" ? "" : " ") $0; next }
    /^  - name: / { if ($3 == want) { print block; exit } }
    { block = "" }
  ' "$LOGQL"
}

file_alerts() {
  sed -n 's/^      - alert: \(.*\)$/\1/p' "$1" | sort
}

[ "$(group_names "$LOGQL" | tr '\n' ' ')" = 'nut-upsd-events nut-upsd-state ' ] \
  && ok 'alerts/logql.yaml holds exactly the groups nut-upsd-events and nut-upsd-state' \
  || no 'logql.yaml groups' "groups: $(group_names "$LOGQL" | tr '\n' ' ')"

events_role=$(role_line nut-upsd-events)
case "$events_role" in
  'Role: always load'*) ok "nut-upsd-events states its role: $events_role" ;;
  *) no 'nut-upsd-events role line' "comment above the group: ${events_role:-<none>}" ;;
esac
state_role=$(role_line nut-upsd-state)
case "$state_role" in
  'Role: the alternative to alerts/promql.yaml'*) ok "nut-upsd-state states its role: $state_role" ;;
  *) no 'nut-upsd-state role line' "comment above the group: ${state_role:-<none>}" ;;
esac

header=$(awk '/^groups:/ { exit } { sub(/^# ?/, ""); print }' "$LOGQL" | tr '\n' ' ')
case "$header" in
  *nut-upsd-events*nut-upsd-state*alerts/promql.yaml*) ok 'the file header names both groups and the file the state group stands in for' ;;
  *) no 'logql.yaml header roles' "header: $header" ;;
esac

expected_events=$(printf '%s\n' NutUpsdHostSyncExpired NutUpsdNotifyExecFailed NutUpsdForcedShutdown \
  NutUpsdPowerOffFailed NutUpsdContainerError NutUpsdCommsRepaired | sort)
[ "$(group_alerts "$LOGQL" nut-upsd-events)" = "$expected_events" ] \
  && ok 'nut-upsd-events holds the six event alerts' \
  || no 'nut-upsd-events alerts' "got: $(group_alerts "$LOGQL" nut-upsd-events | tr '\n' ' ')"

state_alerts=$(group_alerts "$LOGQL" nut-upsd-state)
missing=$(comm -23 <(printf '%s\n' "$state_alerts") <(file_alerts "$PROMQL"))
[ -n "$state_alerts" ] && [ -z "$missing" ] \
  && ok "every nut-upsd-state alert exists in alerts/promql.yaml ($(printf '%s' "$state_alerts" | tr '\n' ' '))" \
  || no 'nut-upsd-state alerts in promql.yaml' "missing from alerts/promql.yaml: ${missing:-<no state alerts>}"

# The reverse: alerts/promql.yaml holds no event alert, so loading it with
# nut-upsd-events never pages twice, and its one alert of its own is the
# down rule.
extra=$(comm -13 <(printf '%s\n' "$state_alerts") <(file_alerts "$PROMQL") | tr '\n' ' ')
[ "$extra" = 'NutUpsdDown ' ] \
  && ok 'alerts/promql.yaml adds only NutUpsdDown to the state alerts' \
  || no 'promql.yaml one-sided alerts' "alerts only in promql.yaml: ${extra:-<none>}"

report
