#!/usr/bin/env bash
# dbus_liveness_probe() emits the only line alerts/logql.yaml's
# NutUpsdPowerOffPathBroken matches, and the line must recur while the poweroff
# path stays broken, or the alert resolves before a forced shutdown needs the path.
# Seams: the probe, sleep (exits the shipped `while true` after a fixed tick count)
# and the clock, which steps CLOCK_STEP, not DBUS_PROBE_INTERVAL, so broken_for
# must be read off the clock.

# SC2015: lib.sh's ok/no always return 0. SC2034, SC2329: the variable and the
# stubs are used by the function sourced at run time.
# shellcheck disable=SC2015,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# A caller-set ENTRYPOINT wins (red-check: ENTRYPOINT=/tmp/mut-lifecycle.sh).
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/lifecycle.sh"
load_function dbus_liveness_probe
# The probe's detail field comes from validate.sh's log_value.
ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function log_value

DBUS_PROBE_INTERVAL=300
LOG="$WORK/probe.log"
STATE_LOG="$WORK/state.log"
POWEROFF_PATH_STATE=poweroff-path
# Records the verdict each probe hands the metrics exporter.
write_wrapper_state() { printf '%s=%s\n' "$1" "$2" >>"$STATE_LOG"; }

CLOCK_STEP=307

# run_probe <ticks> <mode>: <ticks> sleeps; the probe fails always (broken), never
# (healthy), first only (recovering), first two (long-recovering) or all but the
# second (flapping).
run_probe() {
  _ticks=$1
  _mode=$2
  : >"$LOG"
  : >"$STATE_LOG"
  (
    TICKS=0
    # $TICKS counts the sleeps already taken, so the first probe sees tick 0.
    dbus_poweroff_path_ok() {
      case "$_mode" in
        broken)
          _dbus_detail='Error org.freedesktop.DBus.Error.AccessDenied'
          return 1
          ;;
        healthy) return 0 ;;
        recovering) [ "$TICKS" -ge 1 ] ;;
        long-recovering) [ "$TICKS" -ge 2 ] ;;
        flapping) [ "$TICKS" -eq 1 ] ;;
      esac
    }
    watchdog_epoch() { printf '%s' $((5000 + TICKS * CLOCK_STEP)); }
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

# broken_for_values <msg prefix>: space-separated broken_for of each matching line.
broken_for_values() {
  grep -F -- "msg=\"$1" "$LOG" | sed -n 's/.* broken_for=\([0-9]*\)\( .*\)\{0,1\}$/\1/p' | tr '\n' ' '
}

# --- 1. the matcher alerts/logql.yaml actually uses ---------------------------
# Read from the one rule, up to the next. The rule's `| logfmt | msg=~` is anchored,
# so the msg value must open with the phrase. The case guard refuses an empty
# pattern (matches every line) or another rule's.
M_DBUS=$(awk '
  /- alert: NutUpsdPowerOffPathBroken$/ { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$REPO_ROOT/alerts/logql.yaml" | sed -n 's/.*| logfmt | msg=~"\([^"]*\)".*/\1/p' | head -1)
case "$M_DBUS" in
  *poweroff*) ;;
  *)
    printf 'harness error: extracted matcher %s from alerts/logql.yaml is not the poweroff-path msg filter\n' \
      "${M_DBUS:-<empty>}" >&2
    exit 1
    ;;
esac
# Drop the rule's trailing `.*` to get the prefix.
M_DBUS_PHRASE=${M_DBUS%.\*}
run_probe 1 broken
grep -qF -- "msg=\"$M_DBUS_PHRASE" "$LOG" \
  && grep -q 'level=error' "$LOG" \
  && grep -q 'socket=/run/dbus/system_bus_socket' "$LOG" \
  && grep -qF 'detail="Error org.freedesktop.DBus.Error.AccessDenied"' "$LOG" \
  && ok "a broken poweroff path logs level=error whose msg opens with '$M_DBUS_PHRASE' (read from alerts/logql.yaml), naming the socket and the probe's reply" \
  || no 'NutUpsdPowerOffPathBroken matcher' "alerts/logql.yaml wants msg=\"$M_DBUS_PHRASE, log: $(head -c 300 "$LOG")"

# --- 2. the line RECURS while broken --------------------------------------------
# The rule counts over 15m, so one line on the transition would let it resolve.
run_probe 3 broken
[ "$(count "$M_DBUS_PHRASE")" -eq 3 ] \
  && ok 'the error line repeats on every failed probe (keeps the 15m alert firing)' \
  || no 'recurring error line' "expected 3 lines, got $(count "$M_DBUS_PHRASE")"

# --- 2b. each repeat says how long the path has been broken ----------------------
run_probe 3 broken
[ "$(broken_for_values "$M_DBUS_PHRASE")" = "0 $CLOCK_STEP $((2 * CLOCK_STEP)) " ] \
  && ok "each repeat carries a growing broken_for read off the clock (0, $CLOCK_STEP, $((2 * CLOCK_STEP)))" \
  || no 'growing broken_for' "broken_for values: $(broken_for_values "$M_DBUS_PHRASE"), log: $(tr '\n' '|' <"$LOG")"

# --- 3. recovery is reported ONCE ------------------------------------------------
run_probe 3 recovering
[ "$(count "$M_DBUS_PHRASE")" -eq 1 ] \
  && [ "$(count 'level=info msg="D-Bus poweroff path recovered"')" -eq 1 ] \
  && ok 'recovery logs one info line across two healthy probes, after one error line' \
  || no 'recovery logged once' "log: $(tr '\n' '|' <"$LOG")"

# --- 3b. the recovery line carries the outage's total ----------------------------
run_probe 4 long-recovering
[ "$(broken_for_values "$M_DBUS_PHRASE")" = "0 $CLOCK_STEP " ] \
  && [ "$(broken_for_values 'D-Bus poweroff path recovered')" = "$((2 * CLOCK_STEP)) " ] \
  && [ "$(count 'level=info msg="D-Bus poweroff path recovered"')" -eq 1 ] \
  && ok "the recovered line carries the outage's total broken_for ($((2 * CLOCK_STEP)))" \
  || no 'recovered broken_for total' "log: $(tr '\n' '|' <"$LOG")"

# --- 3c. a new outage counts from its own start ----------------------------------
run_probe 3 flapping
[ "$(broken_for_values "$M_DBUS_PHRASE")" = "0 0 " ] \
  && [ "$(broken_for_values 'D-Bus poweroff path recovered')" = "$CLOCK_STEP " ] \
  && ok 'a second outage starts broken_for at 0 again, after a recovery that carried the first outage' \
  || no 'broken_for per outage' "log: $(tr '\n' '|' <"$LOG")"

# --- 4. a healthy path is silent -------------------------------------------------
# The control: a probe logging the error unconditionally would pass cases 1 and 2.
run_probe 3 healthy
[ ! -s "$LOG" ] \
  && ok 'a healthy poweroff path logs nothing at all (no false NutUpsdPowerOffPathBroken)' \
  || no 'healthy path silent' "logged: $(head -c 300 "$LOG")"

# --- 4b. every probe records its verdict for the metrics exporter --------------
run_probe 3 recovering
[ "$(tr '\n' ' ' <"$STATE_LOG")" = 'poweroff-path=0 poweroff-path=1 poweroff-path=1 ' ] \
  && ok 'each probe records its verdict for the exporter: 0 while broken, 1 once healthy' \
  || no 'probe verdict record' "records: $(tr '\n' ' ' <"$STATE_LOG")"

# --- 5. the cadence variable is mandatory ----------------------------------------
# `sleep ""` returns at once, so a probe without an interval would spin.
if (
  unset DBUS_PROBE_INTERVAL
  dbus_liveness_probe
) 2>"$LOG"; then
  no 'missing DBUS_PROBE_INTERVAL' 'the probe started with no interval configured'
else
  grep -q 'DBUS_PROBE_INTERVAL' "$LOG" \
    && [ "$(count 'D-Bus poweroff path unreachable')" -eq 0 ] \
    && ok 'the probe refuses to start without DBUS_PROBE_INTERVAL rather than spinning' \
    || no 'missing DBUS_PROBE_INTERVAL' "did not fail cleanly at the required-variable guard: $(head -c 200 "$LOG")"
fi

report
