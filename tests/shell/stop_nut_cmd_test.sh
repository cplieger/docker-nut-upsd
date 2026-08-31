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
report
