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
report
