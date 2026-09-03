#!/usr/bin/env bash
# nut-notify.sh: the NOTIFYCMD upsmon runs for every UPS event, and the source
# of the log lines this repo's alert rules match.
#
# WHY THIS IS A CONTRACT, NOT A FORMATTING PREFERENCE: alerts/logql.yaml parses these
# lines with logfmt and filters on the PARSED event label. Rename the field,
# emit a second event= keyval ahead of the real one, or drop the default case
# arm, and UPSOnBattery / UPSLowBattery / UPSForcedShutdown / UPSCommsLost /
# UPSHardwareFault / UPSProtectionDegraded stop firing SILENTLY: nothing errors, no test fails, and
# the gap surfaces during a real outage. Event names are read OUT of
# alerts/logql.yaml rather than named here, so a divergence between the two files
# fails.
#
# Not covered by tests/smoke.sh: this script runs standalone (upsmon execs
# it, so it cannot rely on the shared helper already being sourced) and is
# executed here as the real script rather than extracted.
#
# Lint directives for this whole file, each against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
#   SC2016 - the backtick pattern reading a matcher out of alerts/logql.yaml must stay
#     single-quoted: it matches the LITERAL backticks LogQL wraps a line filter
#     in, and double quotes would run it as a command substitution.
# shellcheck disable=SC2015,SC2016
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
ALERTS="$REPO_ROOT/alerts/logql.yaml"

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

E_LOWBATT=$(rule_events UPSLowBattery)
E_FSD=$(rule_events UPSForcedShutdown)
E_NOCOMM=$(rule_events UPSCommsLost)
E_FAULT=$(rule_events UPSHardwareFault)
E_PROTECTION=$(rule_events UPSProtectionDegraded)
E_ONBATT_PAIR=$(rule_events UPSOnBattery)

# Non-emptiness is not enough: a name extracted from the WRONG rule would be
# non-empty but meaningless. Every NUT notify type is upper-case ASCII, so the
# SHAPE is the guard that catches both.
for _ev in $E_LOWBATT $E_FSD $E_NOCOMM $E_FAULT $E_PROTECTION $E_ONBATT_PAIR; do
  case "$_ev" in
    '' | *[!A-Z]*)
      printf 'harness error: extracted event name %s from %s is not a NUT notify type (lowbatt=%s fsd=%s nocomm=%s fault=%s onbatt-pair=%s)\n' \
        "${_ev:-<empty>}" "$ALERTS" "$E_LOWBATT" "$(printf '%s' "$E_FSD" | tr '\n' ' ')" \
        "$E_NOCOMM" "$(printf '%s' "$E_FAULT" | tr '\n' ' ')" \
        "$(printf '%s' "$E_ONBATT_PAIR" | tr '\n' ' ')" >&2
      exit 1
      ;;
  esac
done

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

emits_event "$E_LOWBATT" \
  && ok "a LOWBATT event binds event=$E_LOWBATT, the label UPSLowBattery filters on in alerts/logql.yaml" \
  || no 'UPSLowBattery event label' "alerts/logql.yaml wants event=$E_LOWBATT, line: $(notify "$E_LOWBATT")"

[ -z "$(unbound_events "$E_FSD")" ] \
  && ok "every event UPSForcedShutdown names ($(printf '%s' "$E_FSD" | tr '\n' ' ')) binds its own event label" \
  || no 'UPSForcedShutdown event labels' "not bound:$(unbound_events "$E_FSD")"

emits_event "$E_NOCOMM" \
  && ok "a NOCOMM event binds event=$E_NOCOMM, the label UPSCommsLost filters on in alerts/logql.yaml" \
  || no 'UPSCommsLost event label' "alerts/logql.yaml wants event=$E_NOCOMM, line: $(notify "$E_NOCOMM")"

[ -z "$(unbound_events "$E_FAULT")" ] \
  && ok "every event UPSHardwareFault names ($(printf '%s' "$E_FAULT" | tr '\n' ' ')) binds its own event label" \
  || no 'UPSHardwareFault event labels' "not bound:$(unbound_events "$E_FAULT")"

# UPSOnBattery needs BOTH halves of the pair to reach the log: with ONLINE
# missing the rule can never resolve, and with ONBATT missing it can never
# fire. The COUNT is pinned too, so a deleted arm cannot quietly reduce this
# to whichever event survived.
_pair_n=0
for _ev in $E_ONBATT_PAIR; do
  _pair_n=$((_pair_n + 1))
done
_pair_seen=$(printf '%s' "$E_ONBATT_PAIR" | tr '\n' ' ')
[ "$_pair_n" -eq 2 ] && [ -z "$(unbound_events "$E_ONBATT_PAIR")" ] \
  && ok "UPSOnBattery's pair from alerts/logql.yaml ($_pair_seen) binds on both events" \
  || no 'UPSOnBattery event pair' "alerts/logql.yaml should name 2 events, got $_pair_n ($_pair_seen); not bound:$(unbound_events "$E_ONBATT_PAIR")"

# --- 1b. every matched NUT event is actually routed to this handler ----------------
# This script only runs when upsmon's NOTIFYFLAG for the event carries EXEC
# (generate-config.sh) -- ALARM was matched by an alert but not wired to EXEC
# before this test existed. Read BOTH sides: event names out of the alert
# matchers, EXEC routing out of the generator, so dropping either fails.
# Scoped per event name, not a file-wide grep for "EXEC".
GENERATOR="$REPO_ROOT/generate-config.sh"
_unrouted=""
for _ev in $E_LOWBATT $E_FSD $E_NOCOMM $E_FAULT $E_PROTECTION $E_ONBATT_PAIR; do
  grep -Eq "^NOTIFYFLAG $_ev .*EXEC" "$GENERATOR" || _unrouted="$_unrouted $_ev"
done
[ -z "$_unrouted" ] \
  && ok 'every NUT event the alert rules match carries EXEC in the generated upsmon.conf' \
  || no 'NOTIFYFLAG routing' "alerts/logql.yaml matches these events but $GENERATOR does not route them to NOTIFYCMD:$_unrouted"

# --- 1c. every routed event is matched or named as deliberately unalerted --------
# The reverse of 1b fails silently: an EXEC-routed event with no rule is
# invisible elsewhere. Read both sets at run time and accept an unmatched event
# only when the header names it; no inventory count or exception list is pinned.
routed_events=$(sed -n 's/^NOTIFYFLAG \([A-Z][A-Z0-9]*\) .*EXEC.*$/\1/p' "$GENERATOR" | sort -u)
matched_events=$(sed -n 's/.*| logfmt | event=~*"\([^"]*\)".*/\1/p' "$ALERTS" | tr '|' '\n' | sort -u)
header_text=$(awk '/^groups:/ { exit } { print }' "$ALERTS")
_unexcused=""
for _ev in $(comm -23 <(printf '%s\n' "$routed_events") <(printf '%s\n' "$matched_events")); do
  printf '%s\n' "$header_text" | grep -qw -- "$_ev" || _unexcused="$_unexcused $_ev"
done
[ -n "$routed_events" ] && [ -z "$_unexcused" ] \
  && ok 'every routed event is matched by an alert rule or named in the header as deliberately unalerted' \
  || no 'routed alert coverage' \
    "routed=$(printf '%s' "$routed_events" | tr '\n' ' ')| unexcused and unmatched:$_unexcused"

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

# --- 3. severity classification, per class ----------------------------------------
#
# The severity is what routes the alert; a class that silently degrades to warn
# (or escalates to error) changes who gets paged for what.
all_match '^level=info ' ONLINE COMMOK \
  && ok 'ONLINE and COMMOK classify as level=info' \
  || no 'info class' 'an info-class event did not log at level=info'

all_match '^level=warn ' ONBATT LOWBATT COMMBAD NOCOMM REPLBATT ALARM \
  && ok 'ONBATT, LOWBATT, COMMBAD, NOCOMM, REPLBATT and ALARM classify as level=warn' \
  || no 'warn class' 'a warn-class event did not log at level=warn'

all_match '^level=error ' FSD SHUTDOWN \
  && ok 'FSD and SHUTDOWN classify as level=error (the forced-shutdown pair)' \
  || no 'error class' 'a forced-shutdown event did not log at level=error'

# --- 4. the default arm: an event this image has never seen still reports ----------
#
# NUT adds notification types across releases. Without the catch-all arm,
# `level` would be unset and a new upstream event would go unreported rather
# than merely unclassified.
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
# deliberate design: the standalone handlers are exec'd by upsmon and cannot
# source the shared helper. Byte-parity is the contract that keeps smoke.sh's
# validate.sh coverage transferable to this copy.
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
