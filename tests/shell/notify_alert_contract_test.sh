#!/usr/bin/env bash
# nut-notify.sh: the NOTIFYCMD upsmon runs for every UPS event, and the source
# of the log lines this repo's alert rules match.
#
# WHY THIS IS A CONTRACT, NOT A FORMATTING PREFERENCE: alerts/logql.yaml parses these
# lines with logfmt and filters on the PARSED event label. Renaming or shadowing
# that field silently disables every rule in the bundle that filters it. The
# rule inventory is derived from alerts/logql.yaml below, and its count is
# asserted there rather than written here.
#
# Not covered by tests/smoke.sh: this script runs standalone (upsmon execs
# it, so it cannot rely on the shared helper already being sourced) and is
# executed here as the real script rather than extracted.
#
# Lint directive for this whole file, against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins (the red-check):
#   ENTRYPOINT=/tmp/mut-notify.sh bash tests/shell/notify_alert_contract_test.sh
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/nut-notify.sh"

if [ ! -f "$ENTRYPOINT" ] || [ ! -r "$ENTRYPOINT" ]; then
  printf 'harness error: ENTRYPOINT is not a readable file: %s\n' "$ENTRYPOINT" >&2
  exit 1
fi

# notify <notifytype> [upsname] [message] -> the emitted log line.
# NOTIFYTYPE and UPSNAME are how upsmon passes the event; the message is $1.
notify() {
  NOTIFYTYPE="$1" UPSNAME="${2-ups}" sh "$ENTRYPOINT" "${3-UPS ups is on battery}" 2>&1
}

# notify_unset <upsname-state> -> the line produced with NOTIFYTYPE absent
# entirely, which is what a NOTIFYCMD wired without NOTIFYFLAG produces.
notify_no_type() {
  UPSNAME=ups sh "$ENTRYPOINT" 'no type' 2>&1
}

all_match() {
  _pattern=$1
  shift
  for _t in "$@"; do
    notify "$_t" | grep -Eq "$_pattern" || return 1
  done
}

# --- 1. the LogQL matchers, read FROM alerts/logql.yaml ---------------------------------
# The matcher literal is extracted from the rule file at run time, so EITHER
# side of the contract failing fails here.
ALERTS="${ALERTS:-$REPO_ROOT/alerts/logql.yaml}"

# rule_events <alert-name> -> every NUT event name that rule's label filter
# selects, deduplicated.
#
# The rules read a PARSED logfmt field (`| logfmt | event="X"`, or
# `event=~"A|B"` for the pairs), so a whole-line grep would no longer prove
# what the rule matches. The range ends at the NEXT rule (or EOF) rather than
# a window literal, so a window change cannot overrun it.
rule_events() {
  awk -v want="- alert: $1" '
    $0 ~ want { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule { print }
  ' "$ALERTS" \
    | sed -n 's/.*| logfmt | event=~*"\([^"]*\)".*/\1/p' \
    | tr '|' '\n' | sort -u
}

# logfmt_field <key> <line> -> the value a logfmt parser binds to <key>. The
# FIRST occurrence wins, which is why field order is load-bearing: a value
# that could inject a second event= keyval must not precede the real field.
logfmt_field() {
  printf '%s\n' "$2" | awk -v k="$1" '{
    for (i = 1; i <= NF; i++) {
      p = index($i, "=")
      if (p > 0 && substr($i, 1, p - 1) == k) {
        v = substr($i, p + 1)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }
  }'
}

# event_rules -> every alert whose expression filters the parsed event field.
event_rules=$(awk '
  /^[[:space:]]*- alert:/ { alert = $3; next }
  alert != "" && /\| logfmt \| event=~*"/ {
    print alert
    alert = ""
  }
' "$ALERTS")
if [ -z "$event_rules" ]; then
  printf 'harness error: no event-bearing alert rules found in %s\n' "$ALERTS" >&2
  exit 1
fi

require_event_count() {
  local alert=$1 events=$2 count=0
  for _event in $events; do
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    printf 'harness error: %s yielded no event names from %s\n' "$alert" "$ALERTS" >&2
    exit 1
  fi
}

_all_rule_events=""
for _rule in $event_rules; do
  _events=$(rule_events "$_rule")
  require_event_count "$_rule" "$_events"
  for _ev in $_events; do
    case "$_ev" in
      '' | *[!A-Z]*)
        printf 'harness error: %s extracted invalid NUT notify type %s from %s\n' \
          "$_rule" "${_ev:-<empty>}" "$ALERTS" >&2
        exit 1
        ;;
    esac
  done
  _all_rule_events="$_all_rule_events $_events"
done
matched_rule_events=$(printf '%s\n' "$_all_rule_events" | tr ' ' '\n' | sed '/^$/d' | sort -u)

# emits_event <event> -> 0 when the handler's record binds that event to the
# parsed event label, not merely a substring anywhere on the line.
emits_event() {
  [ "$(logfmt_field event "$(notify "$1")")" = "$1" ]
}

# all_events_emitted <event-list> -> the events whose record failed to bind.
unbound_events() {
  _ue=""
  for _ev in $1; do
    emits_event "$_ev" || _ue="$_ue $_ev"
  done
  printf '%s' "$_ue"
}

for _rule in $event_rules; do
  _events=$(rule_events "$_rule")
  _unbound=$(unbound_events "$_events")
  [ -z "$_unbound" ] \
    && ok "every event $_rule names ($(printf '%s' "$_events" | tr '\n' ' ')) binds its own event label" \
    || no "$_rule event labels" "not bound:$_unbound"
done

# --- 1b. every matched NUT event is actually routed to this handler ----------------
# This script only runs when upsmon's NOTIFYFLAG for the event carries EXEC
# (generate-config.sh). Read BOTH sides at run time so a new event-bearing rule
# enters this check without another hand-maintained list.
GENERATOR="$REPO_ROOT/generate-config.sh"
_unrouted=""
for _ev in $matched_rule_events; do
  grep -Eq "^NOTIFYFLAG $_ev .*EXEC" "$GENERATOR" || _unrouted="$_unrouted $_ev"
done
[ -z "$_unrouted" ] \
  && ok 'every NUT event the alert rules match carries EXEC in the generated upsmon.conf' \
  || no 'NOTIFYFLAG routing' "alerts/logql.yaml matches these events but $GENERATOR does not route them to NOTIFYCMD:$_unrouted"

# --- 1c. the header's silence list IS the residue, in both directions ------------
# The reverse of 1b in BOTH directions, and it fails silently either way: a rule
# ADDED for an event the header declares deliberately unalerted, or a whole rule
# DELETED for an event the header happens to mention elsewhere. The silence list is
# read out of the except-clause the header publishes and required to EQUAL
# routed-minus-matched, so no count and no exception list is pinned.
routed_events=$(sed -n 's/^NOTIFYFLAG \([A-Z][A-Z0-9_]*\) .*EXEC.*$/\1/p' "$GENERATOR" | sort -u)
matched_events=$(sed -n 's/.*| logfmt | event=~*"\([^"]*\)".*/\1/p' "$ALERTS" | tr '|' '\n' | sort -u)
header_text=$(awk '/^groups:/ { exit } { print }' "$ALERTS")
silence_events=$(printf '%s\n' "$header_text" | sed 's/^# *//' | tr '\n' ' ' \
  | sed -n 's/.*has a rule below except \([^.]*\)\..*/\1/p' \
  | tr ',' ' ' | sed 's/ and / /g' | tr ' ' '\n' \
  | grep -E '^[A-Z][A-Z0-9_]*$' | sort -u)
_residue=$(comm -23 <(printf '%s\n' "$routed_events") \
  <(printf '%s\n' "$matched_events") | sort -u)
[ -n "$silence_events" ] && [ "$silence_events" = "$_residue" ] \
  && ok 'the events the header names as deliberately unalerted are exactly the routed events with no rule' \
  || no 'header silence list' \
    "header=$(printf '%s' "$silence_events" | tr '\n' ' ')| routed-minus-matched=$(printf '%s' "$_residue" | tr '\n' ' ')"

# --- 2. the record fields the logfmt parser and the matchers both depend on --------
#
# Field presence AND, for event, position: logfmt binds the first occurrence
# of a key, so the genuine event= must precede anything an untrusted value
# could add.
_line=$(notify LOWBATT ups 'UPS ups battery low')
printf '%s\n' "$_line" | grep -q '^level=warn ' \
  && printf '%s' "$_line" | grep -q 'msg="UPS event"' \
  && [ "$(logfmt_field event "$_line")" = LOWBATT ] \
  && [ "$(logfmt_field ups "$_line")" = ups ] \
  && printf '%s' "$_line" | grep -q 'detail="UPS ups battery low"' \
  && [ "$(printf '%s\n' "$_line" | wc -l)" -eq 1 ] \
  && ok 'the record carries level, msg, event, ups and detail as one logfmt line' \
  || no 'record shape' "line: $_line"

_upsmon_system='ups@127.0.0.1:3493'
_upsmon_line=$(notify ONBATT "$_upsmon_system" 'UPS ups is on battery')
[ "$(logfmt_field ups "$_upsmon_line")" = ups ] \
  && ok 'upsmon system words bind the bare UPS name in the log record' \
  || no 'UPSNAME system-word normalization' "UPSNAME=$_upsmon_system, line: $_upsmon_line"

_quoted_field_pattern='^level=warn msg="UPS event" event="[^"]*" ups="[^"]*" detail="[^"]*"$'

_hostile_event_line=$(notify 'ALARM" forged=1' ups safe)
printf '%s\n' "$_hostile_event_line" | grep -Eq "$_quoted_field_pattern" \
  && printf '%s\n' "$_hostile_event_line" | grep -Fq 'event="ALARM forged=1"' \
  && [ "$(printf '%s\n' "$_hostile_event_line" | wc -l)" -eq 1 ] \
  && ok 'NOTIFYTYPE quotes stay inside the event field' \
  || no 'NOTIFYTYPE quoted-field boundary' "line: $_hostile_event_line"

_hostile_ups_line=$(notify ALARM 'ups" forged=1' safe)
printf '%s\n' "$_hostile_ups_line" | grep -Eq "$_quoted_field_pattern" \
  && printf '%s\n' "$_hostile_ups_line" | grep -Fq 'ups="ups forged=1"' \
  && [ "$(printf '%s\n' "$_hostile_ups_line" | wc -l)" -eq 1 ] \
  && ok 'UPSNAME quotes stay inside the ups field' \
  || no 'UPSNAME quoted-field boundary' "line: $_hostile_ups_line"

_hostile_detail_line=$(notify ALARM ups 'alarm" forged=1')
printf '%s\n' "$_hostile_detail_line" | grep -Eq "$_quoted_field_pattern" \
  && printf '%s\n' "$_hostile_detail_line" | grep -Fq 'detail="alarm forged=1"' \
  && [ "$(printf '%s\n' "$_hostile_detail_line" | wc -l)" -eq 1 ] \
  && ok 'notification-message quotes stay inside the detail field' \
  || no 'notification-message quoted-field boundary' "line: $_hostile_detail_line"

# --- 3. severity classification, per class ----------------------------------------
#
# The routed set is derived above, but this class table is literal: the bundle
# carries no log level to derive. A new routed event must be classified here.
expected_level() {
  case "$1" in
    ONLINE | COMMOK) printf 'info' ;;
    FSD | SHUTDOWN) printf 'error' ;;
    ONBATT | LOWBATT | COMMBAD | NOCOMM | REPLBATT | NOPARENT | OFF | BYPASS | OVER | CAL | ALARM | OTHER) printf 'warn' ;;
    *) return 1 ;;
  esac
}

_unclassified=""
_misclassified=""
for _ev in $routed_events; do
  if ! _level=$(expected_level "$_ev"); then
    _unclassified="$_unclassified $_ev"
  elif ! notify "$_ev" | grep -q "^level=$_level "; then
    _misclassified="$_misclassified $_ev(want=$_level)"
  fi
done
[ -z "$_unclassified" ] && [ -z "$_misclassified" ] \
  && ok 'every routed event has its literal severity class and logs at that level' \
  || no 'routed-event severity classes' "unclassified:$_unclassified; mismatched:$_misclassified"

# A mounted upsmon.conf.user can route these clear-state twins even though the
# generated file does not. Their membership class stays explicit here.
clear_events=(NOTALARM NOTBYPASS NOTOVER NOTOFF NOTCAL NOTOTHER)
all_match '^level=info ' "${clear_events[@]}" \
  && [ -z "$(unbound_events "${clear_events[*]}")" ] \
  && ok 'mounted-config clear-state twins retain their event names and classify as level=info' \
  || no 'mounted-config clear-state info class' "not bound:$(unbound_events "${clear_events[*]}")"

# --- 4. the default arm: an event this image has never seen still reports ----------
#
# NUT adds notification types across releases. The catch-all gives a new event a
# complete warn-level record instead of opening one with an empty severity.
notify BATTERYCHARGED | grep -q '^level=warn msg="UPS event" event="BATTERYCHARGED" ' \
  && ok 'an unrecognized NOTIFYTYPE still emits a complete warn-level record (default arm)' \
  || no 'default arm' "line: $(notify BATTERYCHARGED)"

# --- 5. absent inputs degrade to named placeholders, never to an empty field -------
#
# `event=` with nothing after it matches none of the alert rules and parses as an
# empty label; "unknown" is at least visible in a log search.
notify_no_type | grep -q 'event="unknown" ' \
  && ok 'a missing NOTIFYTYPE logs event=unknown rather than an empty field' \
  || no 'missing NOTIFYTYPE' "line: $(notify_no_type)"

_self_ups_line=$(notify SHUTDOWN '' 'Auto logout and shutdown proceeding')
_named_ups_line=$(notify SHUTDOWN ups 'Auto logout and shutdown proceeding')
if [ "$(logfmt_field ups "$_self_ups_line")" = upsmon ] \
  && [ "$(logfmt_field ups "$_named_ups_line")" = ups ]; then
  ok 'an empty UPSNAME (upsmon notifying about itself) binds ups=upsmon, and a named UPS binds its own name'
else
  no 'UPSNAME self-notification attribution' "self=[$_self_ups_line] named=[$_named_ups_line]"
fi

# --- 6. the sanitizer's three copies cannot drift apart ---------------------------
# log_value exists in validate.sh, nut-shutdown.sh AND here, byte-identical by
# deliberate design: upsmon execs the standalone handlers, so they cannot rely
# on the shared helper already being sourced. Byte-parity is the contract that
# keeps smoke.sh's validate.sh coverage transferable to this copy.
_lv_notify=$(extract_function log_value "$WORK/lv1.sh")
_lv_validate=$(ENTRYPOINT="$REPO_ROOT/validate.sh" extract_function log_value "$WORK/lv2.sh")
_lv_shutdown=$(ENTRYPOINT="$REPO_ROOT/nut-shutdown.sh" extract_function log_value "$WORK/lv3.sh")
if cmp -s "$_lv_notify" "$_lv_validate" && cmp -s "$_lv_notify" "$_lv_shutdown"; then
  ok 'log_value is byte-identical across nut-notify.sh, validate.sh and nut-shutdown.sh'
else
  no 'log_value parity' "the three deliberate copies drifted: $(
    diff "$_lv_validate" "$_lv_notify" | head -3
    diff "$_lv_validate" "$_lv_shutdown" | head -3
  )"
fi

# The sanitizer's byte behaviour is unasserted here by DIALECT: this harness's
# GNU tr cannot tell the shipped octal range from the simplified class.
# smoke.sh asserts those bytes under the image's BusyBox.

# --- 7. disabled host poweroff has its own operator-facing FSD record -------------
# Distinct from nut-notify.sh's generic event=FSD record above: this states
# that the configured shutdown command deliberately leaves the host powered on.
NOOP_SHUTDOWN="${NOOP_SHUTDOWN:-$REPO_ROOT/nut-shutdown-noop.sh}"
if [ ! -f "$NOOP_SHUTDOWN" ] || [ ! -r "$NOOP_SHUTDOWN" ]; then
  printf 'harness error: NOOP_SHUTDOWN is not a readable file: %s\n' "$NOOP_SHUTDOWN" >&2
  exit 1
fi

OUT="$WORK/noop-stdout"
ERR="$WORK/noop-stderr"
EXPECTED="$WORK/noop-expected"
printf '%s\n' 'level=error msg="UPS forced shutdown (FSD) triggered; host will NOT be powered off" shutdown_on_battery_critical=false' >"$EXPECTED"

NORMAL_RC=0
SHUTDOWN_ON_BATTERY_CRITICAL=false sh "$NOOP_SHUTDOWN" >"$OUT" 2>"$ERR" || NORMAL_RC=$?

if [ "$NORMAL_RC" -eq 0 ] && [ ! -s "$OUT" ] && cmp -s "$EXPECTED" "$ERR"; then
  ok 'disabled host poweroff emits exactly one error record naming FSD, the false toggle and the consequence, and exits 0'
else
  no 'disabled host-poweroff record' "rc=$NORMAL_RC stdout: $(tr '\n' '|' <"$OUT"); stderr: $(tr '\n' '|' <"$ERR")"
fi

EXPECTED_TRUE="$WORK/noop-expected-true"
printf '%s\n' 'level=error msg="UPS forced shutdown (FSD) triggered; host will NOT be powered off" shutdown_on_battery_critical=true' >"$EXPECTED_TRUE"

TRUE_RC=0
SHUTDOWN_ON_BATTERY_CRITICAL=true sh "$NOOP_SHUTDOWN" >"$OUT" 2>"$ERR" || TRUE_RC=$?

if [ "$TRUE_RC" -eq 0 ] && [ ! -s "$OUT" ] && cmp -s "$EXPECTED_TRUE" "$ERR"; then
  ok 'enabled host-poweroff toggle is reported truthfully when the no-op handler is selected'
else
  no 'enabled host-poweroff toggle record' "rc=$TRUE_RC stdout: $(tr '\n' '|' <"$OUT"); stderr: $(tr '\n' '|' <"$ERR")"
fi

# upsmon reads SHUTDOWNCMD's status as "did the command run", so the no-op stays
# successful even when its own diagnostic cannot be written. The premise is
# asserted first: on a /dev/full that accepts bytes the case would pass with the
# handler's `exit 0` deleted.
if [ -c /dev/full ] && ! printf 'x\n' 2>/dev/null >/dev/full; then
  FAILED_WRITE_RC=0
  SHUTDOWN_ON_BATTERY_CRITICAL=false sh "$NOOP_SHUTDOWN" >/dev/null 2>/dev/full || FAILED_WRITE_RC=$?
  if [ "$FAILED_WRITE_RC" -eq 0 ]; then
    ok 'disabled host poweroff stays successful when its diagnostic cannot be written'
  else
    no 'disabled host-poweroff failed-write status' "stderr=/dev/full rc=$FAILED_WRITE_RC"
  fi
else
  skip 'disabled host-poweroff failed-write status' '/dev/full does not reject writes here'
fi

report
