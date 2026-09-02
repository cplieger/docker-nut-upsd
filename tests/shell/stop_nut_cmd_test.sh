#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2329
set -u
# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null
SUBJECT="$REPO_ROOT/lifecycle.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
load_function stop_nut_cmd
STOP_CMD_TIMEOUT=3
STOP_CMD_CAPTURE_PREFIX="$WORK/stop-cmd"
CALLS="$WORK/calls"
CAPTURE="$WORK/capture"
ERR="$WORK/err"
NEXT="$WORK/next"
capture_tmpfile() { printf '%s' "$CAPTURE"; }
capture_head() { head -c 512 "$1"; }
capture_cleanup() { :; }
log_value() { printf '%s' "$1"; }
timeout() {
  printf '%s\n' "$*" >>"$CALLS"
  printf 'control client did not stop\n'
  return 9
}
export STOP_CMD_TIMEOUT STOP_CMD_CAPTURE_PREFIX CALLS CAPTURE NEXT
export -f stop_nut_cmd capture_tmpfile capture_head capture_cleanup log_value timeout
bash -euf -c '
  stop_nut_cmd upsd /usr/sbin/upsd -c stop
  printf "reached\n" >"$NEXT"
' 2>"$ERR"
STATUS=$?
[ "$STATUS" -eq 0 ] \
  && [ -f "$NEXT" ] \
  && [ "$(cat "$CALLS")" = '-s KILL 3 /usr/sbin/upsd -c stop' ] \
  && grep -q 'level=warn msg="upsd stop failed (may already be stopped)" rc=9 detail="control client did not stop"' "$ERR" \
  && ok 'a failed stop is KILL-bounded, diagnosed, absorbed, and the caller continues under set -euf' \
  || no 'bounded best-effort NUT stop' "status=$STATUS call=$(cat "$CALLS") next=$(test -f "$NEXT" && printf yes || printf no) err=$(cat "$ERR")"

load_function capture_tmpfile
load_function capture_head
load_function capture_cleanup
load_function start_recovered_driver

WD_RESTART_CAPTURE_PREFIX="$WORK/wd-restart"
UPS_NAME=ups
FALLBACK_MKTEMP_CALLS="$WORK/fallback-mktemp-calls"
FALLBACK_TIMEOUT_CALLS="$WORK/fallback-timeout-calls"
FALLBACK_RM_CALLS="$WORK/fallback-rm-calls"
FALLBACK_ERR="$WORK/fallback-err"
FALLBACK_NEXT="$WORK/fallback-next"
: >"$FALLBACK_MKTEMP_CALLS"
: >"$FALLBACK_TIMEOUT_CALLS"
: >"$FALLBACK_RM_CALLS"

mktemp() {
  printf '%s\n' "$*" >>"$FALLBACK_MKTEMP_CALLS"
  return 1
}
timeout() {
  printf '%s\n' "$*" >>"$FALLBACK_TIMEOUT_CALLS"
  return 9
}
rm() {
  printf '%s\n' "$*" >>"$FALLBACK_RM_CALLS"
  return 0
}
log_value() { printf '%s' "$1"; }

export STOP_CMD_TIMEOUT STOP_CMD_CAPTURE_PREFIX WD_RESTART_CAPTURE_PREFIX UPS_NAME
export FALLBACK_MKTEMP_CALLS FALLBACK_TIMEOUT_CALLS FALLBACK_RM_CALLS FALLBACK_NEXT
export -f stop_nut_cmd start_recovered_driver capture_tmpfile capture_head capture_cleanup
export -f mktemp timeout rm log_value
if bash -euf -c '
  stop_nut_cmd upsd /usr/sbin/upsd -c stop
  start_recovered_driver
  printf "reached\n" >"$FALLBACK_NEXT"
' 2>"$FALLBACK_ERR"; then
  FALLBACK_STATUS=0
else
  FALLBACK_STATUS=$?
fi

FALLBACK_EXPECTED_MKTEMP=$(printf '%s\n' \
  "$STOP_CMD_CAPTURE_PREFIX.XXXXXX" \
  "$WD_RESTART_CAPTURE_PREFIX.XXXXXX")
FALLBACK_EXPECTED_TIMEOUT=$(printf '%s\n' \
  '-s KILL 3 /usr/sbin/upsd -c stop' \
  '-k 5 90 /usr/sbin/upsdrvctl start ups')
[ "$FALLBACK_STATUS" -eq 0 ] \
  && [ -f "$FALLBACK_NEXT" ] \
  && [ "$(cat "$FALLBACK_MKTEMP_CALLS")" = "$FALLBACK_EXPECTED_MKTEMP" ] \
  && [ "$(cat "$FALLBACK_TIMEOUT_CALLS")" = "$FALLBACK_EXPECTED_TIMEOUT" ] \
  && [ ! -s "$FALLBACK_RM_CALLS" ] \
  && grep -q 'level=warn msg="upsd stop failed (may already be stopped)" rc=9 detail=""' "$FALLBACK_ERR" \
  && grep -q 'level=error msg="comms watchdog driver restart failed" ups=ups rc=9 detail=""' "$FALLBACK_ERR" \
  && ok 'capture allocation failure leaves both bounded lifecycle commands fail-soft under set -euf' \
  || no 'capture fallback caller continuation' "status=$FALLBACK_STATUS mktemp=$(tr '\n' '|' <"$FALLBACK_MKTEMP_CALLS") timeout=$(tr '\n' '|' <"$FALLBACK_TIMEOUT_CALLS") rm=$(cat "$FALLBACK_RM_CALLS") err=$(tr '\n' '|' <"$FALLBACK_ERR")"

unset -f mktemp timeout rm

report
