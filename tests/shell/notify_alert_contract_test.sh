#!/usr/bin/env bash
# nut-notify.sh: the NOTIFYCMD upsmon runs for every UPS event, and the only
# source of the log lines three of this repo's four alert rules match.
#
# WHY THIS IS A CONTRACT AND NOT A FORMATTING PREFERENCE: alerts.yaml keys on
# literal substrings of these lines -- `event=LOWBATT`, `event=(FSD|SHUTDOWN)`,
# `event=NOCOMM`. Rename the field, reorder the printf, or drop the default case
# arm, and UPSLowBattery / UPSForcedShutdown / UPSCommsLost stop firing SILENTLY:
# nothing errors, no test fails, the dashboards stay green, and the gap is
# discovered during a real outage. The matchers below are copied VERBATIM from
# alerts.yaml rather than paraphrased, so a divergence between the two files
# fails here.
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

# --- 1. the three LogQL matchers, read FROM alerts.yaml ----------------------------
# The matcher literal is extracted from the rule file at run time, so EITHER side
# of the contract failing fails here: rename the log field and the emitted line
# stops matching; edit the alert expression and the extracted literal changes out
# from under the emitter. A hard-coded copy of the matcher would only ever see the
# first half.
ALERTS="$REPO_ROOT/alerts.yaml"

# matcher_for <alert-name> -> the backtick-quoted LogQL line filter in that rule.
#
# The range ends at the NEXT rule (or EOF), not at a `[5m]` literal: keying the end
# on the window would make a window change overrun the range into the following
# rule, and the extraction would then depend on which backtick pair `head -1`
# happens to reach first. Correct today by luck; not a property to rely on.
matcher_for() {
  awk -v want="- alert: $1" '
    $0 ~ want { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule { print }
  ' "$ALERTS" | grep -o '`[^`]*`' | tr -d '`' | head -1
}

M_LOWBATT=$(matcher_for UPSLowBattery)
M_FSD=$(matcher_for UPSForcedShutdown)
M_NOCOMM=$(matcher_for UPSCommsLost)
# Non-emptiness is not enough: an empty matcher would make `grep -F -- ""` match
# every line (a total false green dressed as rigour), and a matcher extracted from
# the WRONG rule would be non-empty but meaningless. Every one of these three rules
# filters on an `event=` field, so the SHAPE is the guard that catches both.
for _m in "$M_LOWBATT" "$M_FSD" "$M_NOCOMM"; do
  case "$_m" in
    *event=*) ;;
    *)
      printf 'harness error: extracted matcher %s from %s does not filter on event= (lowbatt=%s fsd=%s nocomm=%s)\n' \
        "${_m:-<empty>}" "$ALERTS" "$M_LOWBATT" "$M_FSD" "$M_NOCOMM" >&2
      exit 1
      ;;
  esac
done

notify LOWBATT | grep -qF -- "$M_LOWBATT" \
  && ok "a LOWBATT event emits '$M_LOWBATT', the literal UPSLowBattery matches in alerts.yaml" \
  || no 'UPSLowBattery matcher' "alerts.yaml wants '$M_LOWBATT', line: $(notify LOWBATT)"

notify FSD | grep -Eq -- "$M_FSD" \
  && notify SHUTDOWN | grep -Eq -- "$M_FSD" \
  && ok "FSD and SHUTDOWN both match UPSForcedShutdown's regex '$M_FSD' from alerts.yaml" \
  || no 'UPSForcedShutdown matcher' "alerts.yaml wants '$M_FSD', FSD: $(notify FSD) / SHUTDOWN: $(notify SHUTDOWN)"

notify NOCOMM | grep -qF -- "$M_NOCOMM" \
  && ok "a NOCOMM event emits '$M_NOCOMM', the literal UPSCommsLost matches in alerts.yaml" \
  || no 'UPSCommsLost matcher' "alerts.yaml wants '$M_NOCOMM', line: $(notify NOCOMM)"

# --- 2. the record fields the logfmt parser and the matchers both depend on --------
#
# Field PRESENCE, not order: the alert matchers are substring/regex line filters,
# so `event=X` firing does not depend on where in the line it sits, and pinning the
# order would turn a harmless field reorder into a false CI failure while saying
# nothing more about the alerts. One line, every field, each in logfmt shape.
_line=$(notify LOWBATT ups 'UPS ups battery low')
printf '%s\n' "$_line" | grep -q '^level=warn ' \
  && printf '%s' "$_line" | grep -q 'msg="UPS event"' \
  && printf '%s' "$_line" | grep -q 'event=LOWBATT' \
  && printf '%s' "$_line" | grep -q 'ups=ups' \
  && printf '%s' "$_line" | grep -q 'detail="UPS ups battery low"' \
  && [ "$(printf '%s\n' "$_line" | wc -l)" -eq 1 ] \
  && ok 'the record carries level, msg, event, ups and detail as one logfmt line' \
  || no 'record shape' "line: $_line"

# --- 3. severity classification, per class ----------------------------------------
#
# The severity is what routes the alert; a class that silently degrades to warn
# (or escalates to error) changes who gets paged for what.
all_match '^level=info ' ONLINE COMMOK \
  && ok 'ONLINE and COMMOK classify as level=info' \
  || no 'info class' 'an info-class event did not log at level=info'

all_match '^level=warn ' ONBATT LOWBATT COMMBAD NOCOMM REPLBATT \
  && ok 'ONBATT, LOWBATT, COMMBAD, NOCOMM and REPLBATT classify as level=warn' \
  || no 'warn class' 'a warn-class event did not log at level=warn'

all_match '^level=error ' FSD SHUTDOWN \
  && ok 'FSD and SHUTDOWN classify as level=error (the forced-shutdown pair)' \
  || no 'error class' 'a forced-shutdown event did not log at level=error'

# --- 4. the default arm: an event this image has never seen still reports ----------
#
# NUT adds notification types across releases. Without the catch-all arm, `level`
# would be unset and the line would either abort or lose its severity -- so a new
# upstream event would go unreported rather than merely unclassified.
notify BATTERYCHARGED | grep -q '^level=warn msg="UPS event" event=BATTERYCHARGED ' \
  && ok 'an unrecognized NOTIFYTYPE still emits a complete warn-level record (default arm)' \
  || no 'default arm' "line: $(notify BATTERYCHARGED)"

# --- 5. absent inputs degrade to named placeholders, never to an empty field -------
#
# `event=` with nothing after it matches none of the alert rules and parses as an
# empty label; "unknown" is at least visible in a log search.
notify_no_type | grep -q 'event=unknown ' \
  && ok 'a missing NOTIFYTYPE logs event=unknown rather than an empty field' \
  || no 'missing NOTIFYTYPE' "line: $(notify_no_type)"

NOTIFYTYPE=ONBATT sh "$ENTRYPOINT" 'no ups name' 2>&1 | grep -q 'ups=unknown ' \
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

# The BusyBox-tr behaviour of the sanitizer itself stays unasserted here, and the
# reason is the DIALECT, not coverage elsewhere: under this harness's GNU tr the
# shipped octal range and the forbidden class produce byte-identical output, so an
# assertion would pass with the guard simplified away and prove nothing about the
# image. The parity case above is what makes smoke.sh's validate.sh coverage
# transfer to this copy.
skip 'the detail="..." sanitizer flattening a crafted NOTIFYMSG' \
  'GNU tr on this runner cannot distinguish the shipped guard from a simplified one; parity with the smoke-covered validate.sh copy is asserted above instead'

report
