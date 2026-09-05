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

ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function strip_leading_zeros
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"
CANONICALIZE_WATCHDOG=$(extract_range \
  '^COMMS_CHECK_INTERVAL=\$(strip_leading_zeros "\$COMMS_CHECK_INTERVAL")$' \
  '^DBUS_PROBE_INTERVAL=\$(strip_leading_zeros "\$DBUS_PROBE_INTERVAL")$' \
  "$WORK/canonicalize-watchdog.sh") || exit 1
ENTRYPOINT="$SUBJECT"

COMMS_CHECK_INTERVAL=08
COMMS_RECOVERY_TIMEOUT=090
COMMS_FAST_RETRIES=01
COMMS_BACKOFF_FACTOR=08
DBUS_PROBE_INTERVAL=0300
. "$CANONICALIZE_WATCHDOG"
PADDED_CALLS="$WORK/padded-restarts"
: >"$PADDED_CALLS"
(
  NOW=0
  TICKS=0
  watchdog_epoch() { printf '%s' "$NOW"; }
  sleep() {
    NOW=$((NOW + COMMS_CHECK_INTERVAL))
    TICKS=$((TICKS + 1))
    [ "$TICKS" -le 105 ] || exit 0
  }
  comms_fresh() { return 1; }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$NOW" >>"$PADDED_CALLS"
    return 0
  }
  comms_watchdog
) 2>"$WORK/padded-err"
PADDED_EXPECTED='1 104
2 832'
[ "$COMMS_CHECK_INTERVAL $COMMS_RECOVERY_TIMEOUT $COMMS_FAST_RETRIES $COMMS_BACKOFF_FACTOR $DBUS_PROBE_INTERVAL" = '8 90 1 8 300' ] \
  && [ "$(cat "$PADDED_CALLS")" = "$PADDED_EXPECTED" ] \
  && ok 'zero-padded watchdog timings remain decimal through the backoff threshold' \
  || no 'zero-padded watchdog arithmetic' \
    "values=$COMMS_CHECK_INTERVAL,$COMMS_RECOVERY_TIMEOUT,$COMMS_FAST_RETRIES,$COMMS_BACKOFF_FACTOR,$DBUS_PROBE_INTERVAL calls=$(tr '\n' '|' <"$PADDED_CALLS") err=$(cat "$WORK/padded-err")"

load_function driver_pidfile
load_function watchdog_epoch
BEFORE=$(awk '{ split($1, parts, "."); print parts[1] }' /proc/uptime)
GOT=$(watchdog_epoch)
AFTER=$(awk '{ split($1, parts, "."); print parts[1] }' /proc/uptime)
case "$BEFORE:$GOT:$AFTER" in
  :* | *::* | *: | *[!0-9:]*)
    no 'watchdog monotonic clock' "before=$BEFORE got=$GOT after=$AFTER"
    ;;
  *)
    [ "$GOT" -ge "$BEFORE" ] && [ "$GOT" -le "$AFTER" ] \
      && ok 'watchdog_epoch reports boot-monotonic seconds within the surrounding /proc/uptime reads' \
      || no 'watchdog monotonic clock' "before=$BEFORE got=$GOT after=$AFTER"
    ;;
esac
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

ALERTS=${ALERTS:-$REPO_ROOT/alerts/logql.yaml}
container_error_rule=$(awk -v want='- alert: UPSContainerError' '
  $0 ~ want "$" { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$ALERTS")
container_error_level=$(printf '%s\n' "$container_error_rule" \
  | sed -n 's/.*|~ `\^level=\([a-z][a-z]*\) `.*/\1/p' | head -1)
if [ -z "$container_error_level" ]; then
  printf 'harness error: UPSContainerError has no anchored level matcher in %s\n' "$ALERTS" >&2
  exit 1
fi

TX_START_RC=0
TX_START_OUT=""
: >"$TX_TRACE"
restart_ups_driver "$((COMMS_FAST_RETRIES - 1))" 2>"$WORK/before-escalation"
: >"$TX_TRACE"
restart_ups_driver "$COMMS_FAST_RETRIES" 2>"$WORK/at-escalation"
before_level=$(sed -n '1s/^level=\([^ ]*\).*/\1/p' "$WORK/before-escalation")
escalation_level=$(sed -n '1s/^level=\([^ ]*\).*/\1/p' "$WORK/at-escalation")
if [ -n "$before_level" ] \
  && [ "$before_level" != "$container_error_level" ] \
  && [ "$escalation_level" = "$container_error_level" ]; then
  ok 'the last fast retry is the first watchdog attempt matched by UPSContainerError'
else
  no 'watchdog escalation boundary' \
    "before=$before_level at=$escalation_level alert-matches=$container_error_level"
fi
TX_START_RC=9
TX_START_OUT='control client did not start'

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
TX_STOP_RC=0
TX_STOP_OUT=""
TX_START_RC=0
TX_START_OUT=""
SHUTDOWN_ON_BATTERY_CRITICAL=true
if (
  timeout() {
    printf 'timeout=%s\n' "$*" >>"$TX_TRACE"
    case "$*" in
      '-k 5 30 /usr/sbin/upsdrvctl stop ups')
        command touch "$POWERDOWNFLAG_FILE"
        return 0
        ;;
      '-k 5 90 /usr/sbin/upsdrvctl start ups') return 0 ;;
      *) return 99 ;;
    esac
  }
  restart_ups_driver 1
) 2>"$TX_ERR"; then
  TX_STATUS=0
else
  TX_STATUS=$?
fi
command rm -f "$POWERDOWNFLAG_FILE"
[ "$TX_STATUS" -ne 0 ] \
  && grep -q 'standing down; forced shutdown (killpower) in progress.*phase=post-stop' "$TX_ERR" \
  && ! grep -q '^read_pidfile=' "$TX_TRACE" \
  && ! grep -q 'upsdrvctl start' "$TX_TRACE" \
  && ok 'a killpower flag raised during driver stop stands recovery down before cleanup or start' \
  || no 'post-stop killpower stand-down' "status=$TX_STATUS trace=$(tr '\n' '|' <"$TX_TRACE") err=$(tr '\n' '|' <"$TX_ERR")"

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
  && grep -q 'comms watchdog restarting UPS driver after stale comms' "$TX_ERR" \
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

: >"$TX_TRACE"
: >"$TX_ERR"
TX_USB_REQUIRED=1
TX_STOP_RC=0
TX_STOP_OUT=""
TX_START_RC=0
TX_START_OUT=""
TX_NEXT="$WORK/chgrp-failure-next"
chgrp() {
  printf 'chgrp=%s\n' "$*" >>"$TX_TRACE"
  return 17
}
export UPS_NAME UPS_DRIVER COMMS_FAST_RETRIES SHUTDOWN_ON_BATTERY_CRITICAL
export POWERDOWNFLAG_FILE WD_RESTART_CAPTURE_PREFIX TX_CAPTURE TX_TRACE TX_ERR
export TX_USB_REQUIRED TX_STOP_RC TX_STOP_OUT TX_START_RC TX_START_OUT TX_NEXT
export -f restart_ups_driver start_recovered_driver kill_stale_driver_from_pidfile
export -f driver_pidfile driver_binary pid_matches_binary usb_bus_required chgrp
export -f timeout read_pidfile kill readlink rm capture_tmpfile capture_head
export -f capture_cleanup log_value
if bash -euf -c '
  restart_ups_driver 1
  printf "reached\n" >"$TX_NEXT"
' 2>"$TX_ERR"; then
  TX_STATUS=0
else
  TX_STATUS=$?
fi
[ "$TX_STATUS" -eq 0 ] \
  && [ -f "$TX_NEXT" ] \
  && grep -q '^chgrp=-R nut /dev/bus/usb$' "$TX_TRACE" \
  && grep -q '^timeout=-k 5 30 /usr/sbin/upsdrvctl stop ups$' "$TX_TRACE" \
  && grep -q '^read_pidfile=/var/run/nut/usbhid-ups-ups.pid$' "$TX_TRACE" \
  && grep -q '^kill=-9 4242$' "$TX_TRACE" \
  && grep -q '^timeout=-k 5 90 /usr/sbin/upsdrvctl start ups$' "$TX_TRACE" \
  && grep -q 'level=warn msg="comms watchdog could not re-assert nut group on USB nodes" ups=ups' "$TX_ERR" \
  && ok 'a failed USB group re-assert is diagnosed and remains fail-soft through stop-cleanup-start under set -euf' \
  || no 'fail-soft USB group re-assert' "status=$TX_STATUS trace=$(tr '\n' '|' <"$TX_TRACE") err=$(tr '\n' '|' <"$TX_ERR")"

# Restore the shadowed builtins/externals: the harness's own EXIT trap scrubs
# $WORK with `rm -rf`, which the trace stub above would otherwise intercept.
unset -f usb_bus_required chgrp timeout read_pidfile kill readlink rm \
  capture_tmpfile capture_head capture_cleanup log_value

report
