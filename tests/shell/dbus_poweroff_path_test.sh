#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2034,SC2329
set -u
# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null
SUBJECT="$REPO_ROOT/lifecycle.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
load_function dbus_poweroff_path_ok
DBUS_PROBE_REPLY_TIMEOUT_MS=3000
CALLS="$WORK/calls"
REPLY=""
TIMEOUT_RC=0
function [ {
  case "$*" in
    '-S /run/dbus/system_bus_socket ]') return 0 ;;
  esac
  builtin [ "$@"
}
timeout() {
  printf '%s\n' "$*" >>"$CALLS"
  printf '%s' "$REPLY"
  return "$TIMEOUT_RC"
}
run_reply() {
  : >"$CALLS"
  if dbus_poweroff_path_ok; then
    STATUS=0
  else
    STATUS=$?
  fi
}
REPLY='method return time=1 sender=:1.0
   string "yes"'
run_reply
[ "$STATUS" -eq 0 ] && [ -z "$_dbus_detail" ] \
  && [ "$(cat "$CALLS")" = '5 dbus-send --system --print-reply --reply-timeout=3000 --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.CanPowerOff' ] \
  && ok 'CanPowerOff yes is accepted through the bounded system-bus call' \
  || no 'CanPowerOff yes' "status=$STATUS detail=$_dbus_detail call=$(cat "$CALLS")"
REPLY='method return time=1 sender=:1.0
   string "no"'
run_reply
[ "$STATUS" -ne 0 ] && [ "$_dbus_detail" = "$REPLY" ] \
  && ok 'a successful CanPowerOff no reply is refused and retained as detail' \
  || no 'CanPowerOff no' "status=$STATUS detail=$_dbus_detail"
REPLY='method return time=1 sender=:1.0
   string "challenge"'
run_reply
[ "$STATUS" -ne 0 ] && [ "$_dbus_detail" = "$REPLY" ] \
  && ok 'a successful CanPowerOff challenge reply is refused and retained as detail' \
  || no 'CanPowerOff challenge' "status=$STATUS detail=$_dbus_detail"
REPLY='method return without an authorization string'
run_reply
[ "$STATUS" -ne 0 ] && [ "$_dbus_detail" = "$REPLY" ] \
  && ok 'a malformed successful reply is refused and retained as detail' \
  || no 'malformed CanPowerOff reply' "status=$STATUS detail=$_dbus_detail"
REPLY='Failed to open connection to system bus'
TIMEOUT_RC=9
run_reply
[ "$STATUS" -eq 1 ] && [ "$_dbus_detail" = "$REPLY" ] \
  && ok 'a failed bounded D-Bus call is refused and retains its diagnostic' \
  || no 'failed CanPowerOff call' "status=$STATUS detail=$_dbus_detail"
report
