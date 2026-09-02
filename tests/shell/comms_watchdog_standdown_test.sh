#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2329
set -u
# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null
SUBJECT="$REPO_ROOT/lifecycle.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
load_function comms_watchdog
UPS_NAME=ups
UPS_DRIVER=usbhid-ups
COMMS_CHECK_INTERVAL=5
COMMS_RECOVERY_TIMEOUT=10
COMMS_FAST_RETRIES=1
COMMS_BACKOFF_FACTOR=5
CALLS="$WORK/restarts"
(
  NOW=0
  TICKS=0
  ATTEMPTS=0
  watchdog_epoch() { printf '%s' "$NOW"; }
  sleep() {
    NOW=$((NOW + COMMS_CHECK_INTERVAL))
    TICKS=$((TICKS + 1))
    [ "$TICKS" -le 10 ] || exit 0
  }
  comms_fresh() { return 1; }
  restart_ups_driver() {
    ATTEMPTS=$((ATTEMPTS + 1))
    printf '%s %s\n' "$1" "$NOW" >>"$CALLS"
    [ "$ATTEMPTS" -ge 3 ]
  }
  comms_watchdog
) 2>"$WORK/err"
EXPECTED='1 15
1 30
1 45'
[ "$(cat "$CALLS")" = "$EXPECTED" ] \
  && ok 'two stood-down crossings leave the first accepted bounce numbered 1 and on the fast cadence' \
  || no 'stand-down does not spend the restart budget' "calls=$(tr '\n' '|' <"$CALLS") err=$(cat "$WORK/err")"
load_function driver_pidfile
load_function driver_binary
load_function pid_matches_binary
load_function kill_stale_driver_from_pidfile
load_function start_recovered_driver
load_function restart_ups_driver

COMMS_FAST_RETRIES=3
SHUTDOWN_ON_BATTERY_CRITICAL=false
POWERDOWNFLAG_FILE="$WORK/killpower"
WD_RESTART_CAPTURE_PREFIX="$WORK/wd-restart"
TX_CAPTURE="$WORK/capture"
TX_TRACE="$WORK/transaction"
TX_ERR="$WORK/transaction-err"
TX_USB_REQUIRED=1
TX_STOP_RC=9
TX_STOP_OUT='control client did not stop'
TX_START_RC=9
TX_START_OUT='control client did not start'

usb_bus_required() {
  printf 'usb_bus_required\n' >>"$TX_TRACE"
  [ "$TX_USB_REQUIRED" -eq 1 ]
}

chgrp() {
  printf 'chgrp=%s\n' "$*" >>"$TX_TRACE"
}

timeout() {
  printf 'timeout=%s\n' "$*" >>"$TX_TRACE"
  case "$*" in
    '-k 5 30 /usr/sbin/upsdrvctl stop ups')
      printf '%s' "$TX_STOP_OUT"
      return "$TX_STOP_RC"
      ;;
    '-k 5 90 /usr/sbin/upsdrvctl start ups')
      printf '%s' "$TX_START_OUT"
      return "$TX_START_RC"
      ;;
    *) return 99 ;;
  esac
}

read_pidfile() {
  printf 'read_pidfile=%s\n' "$1" >>"$TX_TRACE"
  printf '4242'
}

kill() {
  printf 'kill=%s\n' "$*" >>"$TX_TRACE"
}

readlink() {
  printf 'readlink=%s\n' "$*" >>"$TX_TRACE"
  case "$2" in
    /proc/4242/exe | /usr/lib/nut/usbhid-ups)
      printf '/usr/lib/nut/usbhid-ups'
      return 0
      ;;
  esac
  return 1
}

rm() {
  printf 'rm=%s\n' "$*" >>"$TX_TRACE"
}

capture_tmpfile() {
  printf 'capture_tmpfile=%s\n' "$1" >>"$TX_TRACE"
  printf '%s' "$TX_CAPTURE"
}

capture_head() {
  printf 'capture_head=%s\n' "$1" >>"$TX_TRACE"
  command head -c 512 "$1"
}

capture_cleanup() {
  printf 'capture_cleanup=%s\n' "$1" >>"$TX_TRACE"
  command rm -f "$1"
}

log_value() {
  printf '%s' "$1"
}

: >"$TX_TRACE"
if restart_ups_driver 1 2>"$TX_ERR"; then
  TX_STATUS=0
else
  TX_STATUS=$?
fi
TX_EXPECTED=$(printf '%s\n' \
  'usb_bus_required' \
  'chgrp=-R nut /dev/bus/usb' \
  "capture_tmpfile=$WD_RESTART_CAPTURE_PREFIX" \
  'timeout=-k 5 30 /usr/sbin/upsdrvctl stop ups' \
  "capture_head=$TX_CAPTURE" \
  "capture_cleanup=$TX_CAPTURE" \
  'read_pidfile=/var/run/nut/usbhid-ups-ups.pid' \
  'kill=-0 4242' \
  'readlink=-f /proc/4242/exe' \
  'readlink=-f /usr/lib/nut/usbhid-ups' \
  'kill=-0 4242' \
  'kill=-9 4242' \
  'rm=-f /var/run/nut/usbhid-ups-ups.pid' \
  "capture_tmpfile=$WD_RESTART_CAPTURE_PREFIX" \
  'timeout=-k 5 90 /usr/sbin/upsdrvctl start ups' \
  "capture_head=$TX_CAPTURE" \
  "capture_cleanup=$TX_CAPTURE")
[ "$TX_STATUS" -eq 0 ] \
  && [ "$(cat "$TX_TRACE")" = "$TX_EXPECTED" ] \
  && grep -q 'level=warn msg="comms watchdog driver stop failed" ups=ups rc=9 detail="control client did not stop"' "$TX_ERR" \
  && grep -q 'level=error msg="comms watchdog driver restart failed" ups=ups rc=9 detail="control client did not start"' "$TX_ERR" \
  && [ ! -e "$TX_CAPTURE" ] \
  && ok 'a recovery attempt performs bounded stop, verified stale cleanup, bounded start, diagnosis, and capture cleanup in order' \
  || no 'complete driver restart transaction' "status=$TX_STATUS trace=$(tr '\n' '|' <"$TX_TRACE") err=$(tr '\n' '|' <"$TX_ERR")"

: >"$TX_TRACE"
: >"$TX_ERR"
TX_START_RC=0
TX_START_OUT=""
SHUTDOWN_ON_BATTERY_CRITICAL=false
command touch "$POWERDOWNFLAG_FILE"
if restart_ups_driver 1 2>"$TX_ERR"; then
  TX_STATUS=0
else
  TX_STATUS=$?
fi
command rm -f "$POWERDOWNFLAG_FILE"
[ "$TX_STATUS" -eq 0 ] \
  && grep -q '^chgrp=-R nut /dev/bus/usb$' "$TX_TRACE" \
  && grep -q '^timeout=-k 5 90 /usr/sbin/upsdrvctl start ups$' "$TX_TRACE" \
  && grep -q 'comms watchdog re-homing UPS driver after stale comms' "$TX_ERR" \
  && ! grep -q 'comms watchdog standing down' "$TX_ERR" \
  && ok 'a killpower flag from noop FSD does not disarm recovery while host shutdown is disabled' \
  || no 'killpower flag with host shutdown disabled' "status=$TX_STATUS trace=$(tr '\n' '|' <"$TX_TRACE") err=$(tr '\n' '|' <"$TX_ERR")"

: >"$TX_TRACE"
: >"$TX_ERR"
TX_USB_REQUIRED=0
TX_START_RC=0
TX_START_OUT=""
restart_ups_driver 1 2>"$TX_ERR"
! grep -q '^chgrp=' "$TX_TRACE" \
  && grep -q 'timeout=-k 5 30 /usr/sbin/upsdrvctl stop ups' "$TX_TRACE" \
  && grep -q 'timeout=-k 5 90 /usr/sbin/upsdrvctl start ups' "$TX_TRACE" \
  && grep -q 'level=info msg="comms watchdog driver restart issued" ups=ups' "$TX_ERR" \
  && ok 'a non-USB recovery skips group changes but still completes the stop-cleanup-start transaction' \
  || no 'conditional USB step' "trace=$(tr '\n' '|' <"$TX_TRACE") err=$(tr '\n' '|' <"$TX_ERR")"

# Restore the shadowed builtins/externals: the harness's own EXIT trap scrubs
# $WORK with `rm -rf`, which the trace stub above would otherwise intercept.
unset -f usb_bus_required chgrp timeout read_pidfile kill readlink rm \
  capture_tmpfile capture_head capture_cleanup log_value

report
