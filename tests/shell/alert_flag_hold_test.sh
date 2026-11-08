#!/usr/bin/env bash
# The flag rules of alerts/logql.yaml, evaluated over a timeline of the lines
# the image really writes: each flag must hold from its raise until its clear,
# a container start must reset it, and a repeating flag must hold while it
# repeats. The evaluator applies Loki's rules for the two forms the file uses:
# last_over_time keeps the latest unwrapped sample in (T-range, T], and
# count_over_time counts the lines in that range.
#
# Lint directive for this whole file, against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

ALERTS="${ALERTS:-$REPO_ROOT/alerts/logql.yaml}"
NOTIFY="${NOTIFY:-$REPO_ROOT/nut-notify.sh}"
ENTRYPOINT_FILE="${ENTRYPOINT_FILE:-$REPO_ROOT/entrypoint.sh}"

# rule_expr <alert> -> the rule's expression, one source line per line.
rule_expr() {
  awk -v want="- alert: $1" '
    $0 ~ want "$" { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule && /^[[:space:]]*expr: \|/ { inexpr = 1; next }
    inexpr && /^[[:space:]]*for:/ { exit }
    inexpr { print }
  ' "$ALERTS"
}

# rule_legs <alert> <dir> -> writes one file per `or` leg of the expression
# into <dir> and prints how many it wrote.
rule_legs() {
  rm -rf "$2"
  mkdir -p "$2"
  rule_expr "$1" | awk -v dir="$2" '
    BEGIN { n = 1 }
    /^[[:space:]]*or[[:space:]]*$/ { n++; next }
    { print > (dir "/" n) }
    END { print n }
  '
}

# leg_spec <leg-file> -> "kind|events|raise|reset|window_seconds|compare".
leg_spec() {
  local text kind events raise reset window number unit compare
  text=$(tr -s '[:space:]' ' ' <"$1")
  case "$text" in
    *last_over_time*) kind=last ;;
    *count_over_time*) kind=count ;;
    *) kind="" ;;
  esac
  events=$(printf '%s\n' "$text" | sed -n 's/.*| logfmt | event=~*"\([^"]*\)".*/\1/p' | tr '|' ' ')
  # shellcheck disable=SC2016 # the backticks are LogQL's raw-string quotes
  raise=$(printf '%s\n' "$text" | sed -n 's/.*label_format raised=`{{ if eq \.event "\([A-Z]*\)" }}1{{ else }}0{{ end }}`.*/\1/p')
  reset=$(printf '%s\n' "$text" | sed -n 's/.*" or msg="\([^"]*\)".*/\1/p')
  window=$(printf '%s\n' "$text" | sed -n 's/.*\[\([0-9][0-9]*\)\([smhd]\)\].*/\1 \2/p')
  number=${window% *}
  unit=${window#* }
  case "$unit" in
    s) window=$number ;;
    m) window=$((number * 60)) ;;
    h) window=$((number * 3600)) ;;
    d) window=$((number * 86400)) ;;
    *) window="" ;;
  esac
  compare=$(printf '%s\n' "$text" | sed -n 's/.*) \(== 1\|> 0\) *$/\1/p')
  printf '%s|%s|%s|%s|%s|%s\n' "$kind" "$events" "$raise" "$reset" "$window" "$compare"
}

# event_line <event> -> the line nut-notify.sh writes for the event.
event_line() {
  NOTIFYTYPE="$1" UPSNAME='ups@127.0.0.1:3493' sh "$NOTIFY" "UPS ups status" 2>&1
}

# The start line the entrypoint writes before it launches upsmon, read from
# the entrypoint itself.
start_msg=$(sed -n 's/^printf '"'"'level=info msg="\(starting upsmon\)"\\n'"'"' >&2$/\1/p' "$ENTRYPOINT_FILE")
start_at=$(grep -n '^printf '"'"'level=info msg="starting upsmon"' "$ENTRYPOINT_FILE" | cut -d: -f1)
upsmon_at=$(grep -n '^/usr/sbin/upsmon -F &$' "$ENTRYPOINT_FILE" | cut -d: -f1)
if [ -z "$start_msg" ] || [ -z "$start_at" ] || [ -z "$upsmon_at" ]; then
  printf 'harness error: the upsmon start line or the upsmon launch was not found in %s\n' "$ENTRYPOINT_FILE" >&2
  exit 1
fi
[ "$start_at" -lt "$upsmon_at" ] \
  && ok "the entrypoint logs \"$start_msg\" before it launches upsmon, so the reset precedes every upsmon event" \
  || no 'start line order' "start line at $start_at, upsmon launch at $upsmon_at"
start_line="level=info msg=\"$start_msg\""

# leg_firing <spec> <timeline> <T> -> exit 0 when the leg fires at T. A timeline
# line is "<seconds>\t<log line>".
leg_firing() {
  awk -F '\t' -v spec="$1" -v at="$3" '
    function field(line, key,   i, n, parts, p, v) {
      n = split(line, parts, " ")
      for (i = 1; i <= n; i++) {
        p = index(parts[i], "=")
        if (p > 0 && substr(parts[i], 1, p - 1) == key) {
          v = substr(parts[i], p + 1)
          gsub(/^"|"$/, "", v)
          return v
        }
      }
      return ""
    }
    BEGIN {
      split(spec, s, "|")
      kind = s[1]; raise = s[3]; reset = s[4]; window = s[5] + 0; compare = s[6]
      ne = split(s[2], evs, " ")
      for (i = 1; i <= ne; i++) want[evs[i]] = 1
      count = 0; have = 0
    }
    {
      t = $1 + 0
      if (t > at || at - t >= window) next
      ev = field($2, "event")
      matched = (ev in want) || (reset != "" && $2 ~ ("msg=\"" reset "\""))
      if (!matched) next
      count++
      if (!have || t >= latest_t) {
        latest_t = t; have = 1
        latest = (ev == raise) ? 1 : 0
      }
    }
    END {
      if (kind == "last") exit !(have && compare == "== 1" && latest == 1)
      if (kind == "count") exit !(compare == "> 0" && count > 0)
      exit 1
    }
  ' "$2"
}

# rule_firing <alert> <timeline> <T> -> exit 0 when any leg fires at T.
rule_firing() {
  local dir="$WORK/legs-$1" n i
  n=$(rule_legs "$1" "$dir")
  for i in $(seq 1 "$n"); do
    leg_firing "$(leg_spec "$dir/$i")" "$2" "$3" && return 0
  done
  return 1
}

# timeline <file> <seconds>:<event|START> ... -> writes the timeline.
timeline() {
  local file=$1 entry t what
  shift
  : >"$file"
  for entry in "$@"; do
    t=${entry%%:*}
    what=${entry#*:}
    if [ "$what" = START ]; then
      printf '%s\t%s\n' "$t" "$start_line" >>"$file"
    else
      printf '%s\t%s\n' "$t" "$(event_line "$what")" >>"$file"
    fi
  done
}

expect() {
  local want=$1 alert=$2 file=$3 at=$4 what=$5
  if rule_firing "$alert" "$file" "$at"; then
    [ "$want" = firing ] && ok "$what" || no "$what" "$alert fires at ${at}s"
  else
    [ "$want" = resolved ] && ok "$what" || no "$what" "$alert does not fire at ${at}s"
  fi
}

# --- 1. every paired leg names a raise and its NOT clear --------------------------
declare -A flag_rule=([ALARM]=NutUpsdHardwareFault [BYPASS]=NutUpsdProtectionDegraded
  [OVER]=NutUpsdProtectionDegraded [CAL]=NutUpsdProtectionDegraded [OFF]=NutUpsdProtectionUnavailable)
pair_windows=()
for flag in "${!flag_rule[@]}"; do
  alert=${flag_rule[$flag]}
  dir="$WORK/legs-$alert"
  n=$(rule_legs "$alert" "$dir")
  found=""
  for i in $(seq 1 "$n"); do
    spec=$(leg_spec "$dir/$i")
    IFS='|' read -r kind events raise reset window compare <<<"$spec"
    [ "$raise" = "$flag" ] || continue
    found=$spec
    if [ "$kind" = last ] && [ "$events" = "$flag NOT$flag" ] && [ "$reset" = "$start_msg" ] \
      && [ -n "$window" ] && [ "$compare" = "== 1" ]; then
      ok "$alert pairs $flag with NOT$flag and the upsmon start line in one last_over_time leg"
      pair_windows+=("$window")
    else
      no "$alert $flag leg shape" "spec=$spec"
    fi
  done
  [ -n "$found" ] || no "$alert $flag leg" "no leg raises $flag"
done
if [ "${#pair_windows[@]}" -eq "${#flag_rule[@]}" ] && [ "$(printf '%s\n' "${pair_windows[@]}" | sort -u | wc -l)" -eq 1 ]; then
  ok "every paired flag holds over the same range (${pair_windows[0]}s)"
else
  no 'paired flag ranges' "ranges: ${pair_windows[*]:-<none>}"
fi

# --- 2. each paired flag holds from its raise until its clear ---------------------
pair_window=${pair_windows[0]:-0}
for flag in "${!flag_rule[@]}"; do
  alert=${flag_rule[$flag]}
  f="$WORK/t-$flag"
  timeline "$f" "0:$flag"
  expect firing "$alert" "$f" 900 "$alert still fires 15 minutes after $flag with no clear"
  expect firing "$alert" "$f" "$((pair_window - 1))" "$alert holds $flag to the end of its range"
  expect resolved "$alert" "$f" "$pair_window" "$alert resolves once $flag leaves its range"

  timeline "$f" "0:$flag" "3600:NOT$flag"
  expect firing "$alert" "$f" 3599 "$alert holds $flag until NOT$flag"
  expect resolved "$alert" "$f" 3600 "$alert resolves on NOT$flag"

  timeline "$f" "0:NOT$flag" "60:$flag"
  expect firing "$alert" "$f" 120 "$alert fires when $flag follows NOT$flag"

  timeline "$f" "0:$flag" "7200:START"
  expect resolved "$alert" "$f" 7201 "$alert resolves when the container starts again with $flag cleared"
  timeline "$f" "0:$flag" "7200:START" "7205:$flag"
  expect firing "$alert" "$f" 7206 "$alert fires again when upsmon reports $flag after the start"
done

# Two flags of one rule are separate legs: one flag's clear leaves the other held.
f="$WORK/t-two"
timeline "$f" "0:BYPASS" "60:OVER" "120:NOTOVER"
expect firing NutUpsdProtectionDegraded "$f" 180 'NutUpsdProtectionDegraded holds BYPASS after OVER clears'

# --- 3. REPLBATT has no clear and repeats every RBWARNTIME ------------------------
# shellcheck disable=SC2016 # matches the literal ${RBWARNTIME:=...} default line
rbwarntime=$(sed -n 's/^: "${RBWARNTIME:=\([0-9][0-9]*\)}"$/\1/p' "$ENTRYPOINT_FILE")
if [ -z "$rbwarntime" ]; then
  printf 'harness error: no RBWARNTIME default in %s\n' "$ENTRYPOINT_FILE" >&2
  exit 1
fi
f="$WORK/t-rb"
timeline "$f" "0:REPLBATT" "$rbwarntime:REPLBATT" "$((2 * rbwarntime)):REPLBATT"
expect firing NutUpsdHardwareFault "$f" "$((2 * rbwarntime + rbwarntime - 1))" 'NutUpsdHardwareFault holds between REPLBATT reminders'
timeline "$f" "0:REPLBATT"
expect firing NutUpsdHardwareFault "$f" "$((2 * rbwarntime + 60))" 'NutUpsdHardwareFault holds across one missed REPLBATT reminder'
timeline "$f" "0:REPLBATT" "600:START"
expect resolved NutUpsdHardwareFault "$f" 601 'NutUpsdHardwareFault resolves when the container starts again after the battery is replaced'
timeline "$f" "0:ALARM" "60:REPLBATT" "120:NOTALARM"
expect firing NutUpsdHardwareFault "$f" 180 'NutUpsdHardwareFault holds REPLBATT after NOTALARM'

# --- 4. NOPARENT repeats every 120 seconds (check_parent, NUT v2.8.5 clients/upsmon.c)
f="$WORK/t-np"
timeline "$f" "0:NOPARENT" "120:NOPARENT" "240:NOPARENT" "360:NOPARENT"
expect firing NutUpsdProtectionUnavailable "$f" 480 'NutUpsdProtectionUnavailable holds while NOPARENT repeats'
timeline "$f" "0:OFF" "60:NOPARENT" "90:NOTOFF"
expect firing NutUpsdProtectionUnavailable "$f" 100 'NutUpsdProtectionUnavailable holds NOPARENT after NOTOFF'

# --- 5. the evaluator itself: a controlled leg it must read both ways -------------
f="$WORK/t-self"
printf '0\t%s\n' "$(event_line CAL)" >"$f"
if leg_firing 'last|CAL NOTCAL|CAL||600|== 1' "$f" 599 \
  && ! leg_firing 'last|CAL NOTCAL|CAL||600|== 1' "$f" 600 \
  && ! leg_firing 'last|CAL NOTCAL|NOTCAL||600|== 1' "$f" 10 \
  && leg_firing 'count|CAL|||600|> 0' "$f" 10 \
  && ! leg_firing 'count|OVER|||600|> 0' "$f" 10; then
  ok 'the evaluator keeps the latest sample in range and counts only matching lines in range'
else
  no 'evaluator self-check' 'a controlled leg read wrong'
fi

report
