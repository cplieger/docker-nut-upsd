#!/usr/bin/env bash
# nut-notify.sh: the NOTIFYCMD upsmon runs for every UPS event, and the source
# of the log lines that this repo's alert rules match.
#
# WHY THIS IS A CONTRACT AND NOT A FORMATTING PREFERENCE: alerts.yaml parses
# these lines with logfmt and filters on the PARSED event label -- ONBATT,
# ONLINE, LOWBATT, FSD|SHUTDOWN, NOCOMM, REPLBATT|ALARM. Rename the field, emit
# a second event= keyval ahead of the real one, or drop the default case arm,
# and UPSOnBattery / UPSLowBattery / UPSForcedShutdown / UPSCommsLost /
# UPSHardwareFault stop firing SILENTLY: nothing errors, no test fails, the
# dashboards stay green, and the gap is discovered during a real outage. The
# event names below are read OUT of alerts.yaml rather than named here, so a
# divergence between the two files fails.
#
# This script is not covered by tests/smoke.sh at all. It runs standalone (upsmon
# execs it, so it cannot source the shared helper), needs no privileges, and is
# executed here as the real script rather than extracted -- the whole file IS the
# unit.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2016 - the backtick pattern that reads a matcher out of alerts.yaml must stay
#     single-quoted: it matches the LITERAL backticks LogQL wraps a line filter in,
#     and double quotes would run it as a command substitution.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-notify.sh bash tests/shell/notify_alert_contract_test.sh
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/nut-notify.sh"

# Same validation lib.sh applies before every extraction: a mistyped or stale
# override must name itself instead of surfacing as a script that produced no
# output, which every assertion below would read as a missing field.
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

# --- 1. the LogQL matchers, read FROM alerts.yaml ---------------------------------
# The matcher literal is extracted from the rule file at run time, so EITHER side
# of the contract failing fails here: rename the log field and the emitted line
# stops matching; edit the alert expression and the extracted literal changes out
# from under the emitter. A hard-coded copy of the matcher would only ever see the
# first half.
ALERTS="$REPO_ROOT/alerts.yaml"

# rule_events <alert-name> -> every NUT event name that rule's label filter
# selects, deduplicated (UPSOnBattery names each event once per arm).
#
# The rules read a PARSED logfmt field (`| logfmt | event="X"`, or `event=~"A|B"`
# for the pairs), so there is no backtick line-filter literal left to extract and
# a whole-line grep would no longer prove what the rule matches. The range still
# ends at the NEXT rule (or EOF) rather than at a window literal, so a window
# change cannot overrun it into the following rule.
rule_events() {
  awk -v want="- alert: $1" '
    $0 ~ want { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule { print }
  ' "$ALERTS" |
    sed -n 's/.*| logfmt | event=~*"\([^"]*\)".*/\1/p' |
    tr '|' '\n' | sort -u
}

# logfmt_field <key> <line> -> the value a logfmt parser binds to <key>. The
# FIRST occurrence wins, which is exactly why field order is load-bearing:
# a value that could inject a second event= keyval must not be able to precede
# the real field. Surrounding double quotes are stripped, as the parser does.
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
E_ONBATT_PAIR=$(rule_events UPSOnBattery)

# Non-emptiness is not enough: an empty event name would make the comparison
# below assert nothing, and a name extracted from the WRONG rule would be
# non-empty but meaningless. Every NUT notify type is upper-case ASCII, so the
# SHAPE is the guard that catches both.
for _ev in $E_LOWBATT $E_FSD $E_NOCOMM $E_FAULT $E_ONBATT_PAIR; do
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
# parsed event label. Asserting the FIELD, not a substring: after the matchers
# became label filters, a token sitting anywhere else on the line no longer
# matches, and neither should this test.
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
  && ok "a LOWBATT event binds event=$E_LOWBATT, the label UPSLowBattery filters on in alerts.yaml" \
  || no 'UPSLowBattery event label' "alerts.yaml wants event=$E_LOWBATT, line: $(notify "$E_LOWBATT")"

[ -z "$(unbound_events "$E_FSD")" ] \
  && ok "every event UPSForcedShutdown names ($(printf '%s' "$E_FSD" | tr '\n' ' ')) binds its own event label" \
  || no 'UPSForcedShutdown event labels' "not bound:$(unbound_events "$E_FSD")"

emits_event "$E_NOCOMM" \
  && ok "a NOCOMM event binds event=$E_NOCOMM, the label UPSCommsLost filters on in alerts.yaml" \
  || no 'UPSCommsLost event label' "alerts.yaml wants event=$E_NOCOMM, line: $(notify "$E_NOCOMM")"

[ -z "$(unbound_events "$E_FAULT")" ] \
  && ok "every event UPSHardwareFault names ($(printf '%s' "$E_FAULT" | tr '\n' ' ')) binds its own event label" \
  || no 'UPSHardwareFault event labels' "not bound:$(unbound_events "$E_FAULT")"

# UPSOnBattery needs BOTH halves of the pair to reach the log: with ONLINE
# missing the rule can never resolve, and with ONBATT missing it can never fire.
# The COUNT is pinned too: an arm deleted from the expression would otherwise
# quietly reduce this to whichever event survived.
_pair_n=0
for _ev in $E_ONBATT_PAIR; do
  _pair_n=$((_pair_n + 1))
done
_pair_seen=$(printf '%s' "$E_ONBATT_PAIR" | tr '\n' ' ')
[ "$_pair_n" -eq 2 ] && [ -z "$(unbound_events "$E_ONBATT_PAIR")" ] \
  && ok "UPSOnBattery's pair from alerts.yaml ($_pair_seen) binds on both events" \
  || no 'UPSOnBattery event pair' "alerts.yaml should name 2 events, got $_pair_n ($_pair_seen); not bound:$(unbound_events "$E_ONBATT_PAIR")"

# --- 1b. every matched NUT event is actually routed to this handler ----------------
# This script only runs when upsmon's NOTIFYFLAG for the event carries EXEC, and
# that list lives in generate-config.sh. So an alert can key on a perfectly-shaped
# event= literal that NUT will never hand to the handler -- ALARM was exactly that
# case before it was wired. Read BOTH sides here: the event names out of the alert
# matchers, and the EXEC routing out of the generator, so dropping either one
# fails. Scoped per event name rather than a file-wide grep for "EXEC", which would
# stay green while the specific flag line was deleted.
GENERATOR="$REPO_ROOT/generate-config.sh"
_unrouted=""
for _ev in $E_LOWBATT $E_FSD $E_NOCOMM $E_FAULT $E_ONBATT_PAIR; do
  grep -Eq "^NOTIFYFLAG $_ev .*EXEC" "$GENERATOR" || _unrouted="$_unrouted $_ev"
done
[ -z "$_unrouted" ] \
  && ok 'every NUT event the alert rules match carries EXEC in the generated upsmon.conf' \
  || no 'NOTIFYFLAG routing' "alerts.yaml matches these events but $GENERATOR does not route them to NOTIFYCMD:$_unrouted"

# --- 2. the record fields the logfmt parser and the matchers both depend on --------
#
# Field presence AND, for event, position: logfmt binds the first occurrence of a
# key, so the genuine event= must precede anything an untrusted value could add.
# That is why the event assertions above read the parsed field rather than grep
# the line. One record, every field, each in logfmt shape.
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
# NUT adds notification types across releases. Without the catch-all arm, `level`
# would be unset and the line would either abort or lose its severity -- so a new
# upstream event would go unreported rather than merely unclassified.
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

NOTIFYTYPE=ONBATT sh "$ENTRYPOINT" 'no ups name' 2>&1 | grep -q 'ups="unknown"' \
  && ok 'a missing UPSNAME logs ups=unknown rather than an empty field' \
  || no 'missing UPSNAME' 'the ups field was empty'

# --- 6. the sanitizer's three copies cannot drift apart ---------------------------
# log_value exists in validate.sh, nut-shutdown.sh AND here, byte-identical by
# deliberate design: the standalone handlers are exec'd by upsmon and cannot source
# the shared helper. tests/smoke.sh exercises only validate.sh's copy, so a drifted
# copy HERE would corrupt this script's logfmt records -- and the alert matchers
# with them -- while every other suite stayed green. Byte-parity is the contract
# that keeps the smoke coverage transferable to this copy.
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
# GNU tr cannot tell the shipped octal range from the simplified class, so any
# assertion would stay green with the guard removed. smoke.sh asserts those
# bytes under the image's BusyBox; the parity case above transfers that here.

# --- 7. disabled host poweroff has its own operator-facing FSD record -------------
# This is distinct from nut-notify.sh's generic event=FSD record above: it states
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

SHUTDOWN_ON_BATTERY_CRITICAL=false sh "$NOOP_SHUTDOWN" >"$OUT" 2>"$ERR" || :

if [ ! -s "$OUT" ] && cmp -s "$EXPECTED" "$ERR"; then
  ok 'disabled host poweroff emits exactly one error record naming FSD, the false toggle, and the consequence'
else
  no 'disabled host-poweroff record' "stdout: $(tr '\n' '|' <"$OUT"); stderr: $(tr '\n' '|' <"$ERR")"
fi

report
