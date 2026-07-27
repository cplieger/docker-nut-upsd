#!/usr/bin/env bash
# dbus_liveness_probe(): the background loop that re-checks the host-poweroff path
# while SHUTDOWN_ON_BATTERY_CRITICAL is on, and the sole source of the line
# alerts.yaml's UPSPowerOffPathBroken matches.
#
# The whole point of the probe is that it reports a broken poweroff path BEFORE a
# real forced shutdown, because during one it can no longer be fixed. That makes
# its log line a contract: UPSPowerOffPathBroken matches the literal
# `D-Bus poweroff path unreachable` (copied verbatim from alerts.yaml below), and
# it matches with count_over_time(...[15m]) > 0 -- so the line must RECUR while the
# path is broken, not fire once and go quiet. Both properties are asserted here.
#
# tests/smoke.sh checks that this function is defined, and covers
# dbus_poweroff_path_ok's negative case; the loop's own state machine and its log
# lines are exercised nowhere.
#
# The two seams are the probe itself and sleep. sleep both bounds the cadence and
# ends the loop here (the shipped loop is `while true`), so each scenario runs in a
# subshell whose sleep stub exits after a fixed number of ticks.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - DBUS_PROBE_INTERVAL is an INPUT to lifecycle.sh code that is extracted
#     and sourced at RUNTIME, so shellcheck cannot see the read.
#   SC2329 - the dbus_poweroff_path_ok and sleep stubs are invoked from that same
#     runtime-sourced function, so shellcheck cannot see those calls either.
#   SC2016 - the backtick pattern that reads the matcher out of alerts.yaml must
#     stay single-quoted: it matches the LITERAL backticks LogQL wraps a line
#     filter in, and double quotes would run it as a command substitution.
# shellcheck disable=SC2015,SC2034,SC2329,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-lifecycle.sh bash tests/shell/dbus_probe_alert_test.sh
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/lifecycle.sh"
load_function dbus_liveness_probe

DBUS_PROBE_INTERVAL=300
LOG="$WORK/probe.log"

# run_probe <ticks> <mode>: run the loop for <ticks> sleeps with the poweroff-path
# probe answering per <mode> -- broken (always fails), healthy (always succeeds),
# or recovering (fails the first probe, succeeds afterwards).
run_probe() {
  _ticks=$1
  _mode=$2
  : >"$LOG"
  (
    TICKS=0
    dbus_poweroff_path_ok() {
      case "$_mode" in
        broken) return 1 ;;
        healthy) return 0 ;;
        # $TICKS counts the sleeps already taken, so the first probe fails and
        # every later one succeeds.
        recovering) [ "$TICKS" -ge 1 ] ;;
      esac
    }
    sleep() {
      TICKS=$((TICKS + 1))
      [ "$TICKS" -lt "$_ticks" ] || exit 0
    }
    dbus_liveness_probe
  ) 2>"$LOG"
}

count() {
  grep -c "$1" "$LOG"
}

# --- 1. the matcher alerts.yaml actually uses ------------------------------------
# The literal is read FROM the rule file, so either side of the contract failing
# fails here: reword the log line and it stops matching; edit the alert expression
# and the extracted literal changes out from under the emitter.
# The range ends at the NEXT rule (or EOF) rather than at a `[15m]` literal, so a
# window change cannot overrun it into a neighbouring rule; and the guard checks the
# matcher's SHAPE, not just non-emptiness -- an empty matcher would make
# `grep -F -- ""` match every line, and a wrong-rule matcher would be non-empty but
# meaningless. This rule filters on the poweroff-path phrase.
M_DBUS=$(awk '
  /- alert: UPSPowerOffPathBroken$/ { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$REPO_ROOT/alerts.yaml" | grep -o '`[^`]*`' | tr -d '`' | head -1)
case "$M_DBUS" in
  *poweroff*) ;;
  *)
    printf 'harness error: extracted matcher %s from alerts.yaml is not the poweroff-path filter\n' \
      "${M_DBUS:-<empty>}" >&2
    exit 1
    ;;
esac
run_probe 1 broken
grep -qF -- "$M_DBUS" "$LOG" \
  && grep -q 'level=error' "$LOG" \
  && grep -q 'socket=/run/dbus/system_bus_socket' "$LOG" \
  && ok "a broken poweroff path logs level=error carrying '$M_DBUS' (read from alerts.yaml), naming the socket" \
  || no 'UPSPowerOffPathBroken matcher' "alerts.yaml wants '$M_DBUS', log: $(head -c 300 "$LOG")"

# --- 2. the line RECURS while broken --------------------------------------------
#
# UPSPowerOffPathBroken is count_over_time(...[15m]) > 0, so a single line on the
# transition would let the alert resolve itself while the path is still broken.
# Three broken ticks must produce three lines.
run_probe 3 broken
[ "$(count 'D-Bus poweroff path unreachable')" -eq 3 ] \
  && ok 'the error line repeats on every failed probe (keeps the 15m alert firing)' \
  || no 'recurring error line' "expected 3 lines, got $(count 'D-Bus poweroff path unreachable')"

# --- 3. recovery is reported ONCE ------------------------------------------------
#
# The state machine's only job: one info line when the path comes back, and silence
# afterwards. Without the _dbus_broken latch the healthy loop would log a recovery
# line every interval forever.
run_probe 3 recovering
[ "$(count 'D-Bus poweroff path unreachable')" -eq 1 ] \
  && [ "$(count 'level=info msg="D-Bus poweroff path recovered"')" -eq 1 ] \
  && ok 'recovery logs one info line across two healthy probes, after one error line' \
  || no 'recovery logged once' "log: $(tr '\n' '|' <"$LOG")"

# --- 4. a healthy path is silent -------------------------------------------------
#
# The positive control: without it, a probe that logged the error unconditionally
# would satisfy cases 1 and 2, and the alert would fire on every healthy container.
run_probe 3 healthy
[ ! -s "$LOG" ] \
  && ok 'a healthy poweroff path logs nothing at all (no false UPSPowerOffPathBroken)' \
  || no 'healthy path silent' "logged: $(head -c 300 "$LOG")"

# --- 5. the cadence variable is mandatory ----------------------------------------
#
# `sleep ""` returns immediately, so a probe started without DBUS_PROBE_INTERVAL
# would spin at full speed and flood both the log and the alert; the :? guard
# refuses to start instead.
if (
  unset DBUS_PROBE_INTERVAL
  dbus_liveness_probe
) 2>"$LOG"; then
  no 'missing DBUS_PROBE_INTERVAL' 'the probe started with no interval configured'
else
  grep -q 'DBUS_PROBE_INTERVAL' "$LOG" \
    && ok 'the probe refuses to start without DBUS_PROBE_INTERVAL rather than spinning' \
    || no 'missing DBUS_PROBE_INTERVAL' "aborted without naming the variable: $(head -c 200 "$LOG")"
fi

report
