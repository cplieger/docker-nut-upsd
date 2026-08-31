#!/usr/bin/env bash
# The shutdown helper's retry state machine: call count, early success, retry
# records, and sleeps between failed attempts.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/nut-shutdown.sh"
if [ ! -f "$ENTRYPOINT" ] || [ ! -r "$ENTRYPOINT" ]; then
  printf 'harness error: ENTRYPOINT is not a readable file: %s\n' "$ENTRYPOINT" >&2
  exit 1
fi

HOST_TIMEOUT=$(command -v timeout) || exit 1
BIN="$WORK/bin"
mkdir "$BIN"
DBUS_CALLS="$WORK/dbus.calls"
INHIBITOR_CALLS="$WORK/inhibitor.calls"
TIMEOUT_CALLS="$WORK/timeout.calls"
SLEEP_CALLS="$WORK/sleep.calls"
RM_CALLS="$WORK/rm.calls"
DBUS_RESULTS="$WORK/dbus.results"
ERR="$WORK/stderr"
OUT="$WORK/stdout"
DBUS_ARGS='--system --print-reply --reply-timeout=3000 --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.PowerOff boolean:false'
INHIBITOR_ARGS='--system --print-reply --reply-timeout=3000 --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.ListInhibitors'

cat >"$BIN/timeout" <<'EOF'
#!/bin/sh
[ "$#" -ge 2 ] && [ "$1" = 5 ] || exit 96
printf '%s\n' "$*" >>"$TIMEOUT_CALLS"
shift
exec "$@"
EOF
cat >"$BIN/dbus-send" <<'EOF'
#!/bin/sh
if [ "$*" = "$INHIBITOR_ARGS" ]; then
  printf '%s\n' "$*" >>"$INHIBITOR_CALLS"
  printf 'method return\n   array [\n      struct { string "shutdown" string "backup writer" string "backupd" string "block" uint32 1000 uint32 42 }\n   ]\n'
  exit 0
fi
[ "$*" = "$DBUS_ARGS" ] || exit 95
printf '%s\n' "$*" >>"$DBUS_CALLS"
_call=$(wc -l <"$DBUS_CALLS")
_result=$(sed -n "${_call}p" "$DBUS_RESULTS")
case "$_result" in
  success) printf 'method return\n'; exit 0 ;;
  failure) printf 'D-Bus refused request\n' >&2; exit 1 ;;
  *) printf 'unexpected D-Bus call %s\n' "$_call" >&2; exit 94 ;;
esac
EOF
cat >"$BIN/sleep" <<'EOF'
#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = 2 ] || exit 93
printf '%s\n' "$1" >>"$SLEEP_CALLS"
EOF
cat >"$BIN/rm" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = /var/run/nut-secrets/killpower ] || exit 92
printf '%s\n' "$*" >>"$RM_CALLS"
EOF
chmod +x "$BIN/timeout" "$BIN/dbus-send" "$BIN/sleep" "$BIN/rm"

run_shutdown() {
  : >"$DBUS_CALLS"
  : >"$INHIBITOR_CALLS"
  : >"$TIMEOUT_CALLS"
  : >"$SLEEP_CALLS"
  : >"$RM_CALLS"
  printf '%s\n' "$@" >"$DBUS_RESULTS"
  RUN_RC=0
  "$HOST_TIMEOUT" 3 env PATH="$BIN:$PATH" DBUS_CALLS="$DBUS_CALLS" \
    INHIBITOR_CALLS="$INHIBITOR_CALLS" INHIBITOR_ARGS="$INHIBITOR_ARGS" \
    TIMEOUT_CALLS="$TIMEOUT_CALLS" SLEEP_CALLS="$SLEEP_CALLS" \
    RM_CALLS="$RM_CALLS" DBUS_RESULTS="$DBUS_RESULTS" DBUS_ARGS="$DBUS_ARGS" \
    sh "$ENTRYPOINT" >"$OUT" 2>"$ERR" || RUN_RC=$?
}

run_shutdown success
if [ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 1 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 1 ] \
  && [ ! -s "$SLEEP_CALLS" ] \
  && [ ! -s "$RM_CALLS" ] \
  && grep -qF 'host poweroff dispatched via D-Bus" attempt=1' "$ERR" \
  && ! grep -qF 'retrying' "$ERR"; then
  ok 'first-attempt success exits after one bounded D-Bus call without retrying'
else
  no 'first-attempt success' "rc=$RUN_RC dbus=$(wc -l <"$DBUS_CALLS") timeout=$(wc -l <"$TIMEOUT_CALLS") sleeps=$(wc -l <"$SLEEP_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

run_shutdown failure success
if [ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 2 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 2 ] \
  && [ "$(cat "$SLEEP_CALLS")" = 2 ] \
  && [ ! -s "$RM_CALLS" ] \
  && [ "$(grep -cF 'D-Bus poweroff failed, retrying" attempt=1' "$ERR")" -eq 1 ] \
  && grep -qF 'host poweroff dispatched via D-Bus" attempt=2' "$ERR"; then
  ok 'a transient failure records attempt 1, sleeps once, and stops on attempt 2 success'
else
  no 'failure then success' "rc=$RUN_RC dbus=$(wc -l <"$DBUS_CALLS") timeout=$(wc -l <"$TIMEOUT_CALLS") sleeps=$(tr '\n' ' ' <"$SLEEP_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

run_shutdown failure failure failure
failure_line=$(grep -nF 'D-Bus poweroff failed after 3 attempts' "$ERR" | cut -d: -f1)
inhibitor_line=$(grep -nF 'D-Bus poweroff inhibitors at failure' "$ERR" | cut -d: -f1)
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 3 ] \
  && [ "$(wc -l <"$INHIBITOR_CALLS")" -eq 1 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 4 ] \
  && [ "$(wc -l <"$SLEEP_CALLS")" -eq 2 ] \
  && [ "$(cat "$RM_CALLS")" = '-f /var/run/nut-secrets/killpower' ] \
  && [ "$(grep -cF 'D-Bus poweroff failed, retrying"' "$ERR")" -eq 2 ] \
  && [ -n "$failure_line" ] && [ -n "$inhibitor_line" ] \
  && [ "$failure_line" -lt "$inhibitor_line" ] \
  && grep -qF 'failed after 3 attempts' "$ERR" \
  && grep -qF 'backup writer' "$ERR" \
  && grep -qF 'cleared killpower flag after failed poweroff so USB comms recovery stays armed' "$ERR" \
  && ! grep -qF 'failed to clear killpower flag' "$ERR"; then
  ok 'three failed attempts clear killpower and report that comms recovery is re-armed'
else
  no 'terminal-failure killpower cleanup' "rc=$RUN_RC rm=$(tr '\n' ' ' <"$RM_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

cat >"$BIN/rm" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = /var/run/nut-secrets/killpower ] || exit 92
printf '%s\n' "$*" >>"$RM_CALLS"
exit 1
EOF
chmod +x "$BIN/rm"

run_shutdown failure failure failure
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(cat "$RM_CALLS")" = '-f /var/run/nut-secrets/killpower' ] \
  && grep -qF 'failed to clear killpower flag after failed poweroff; USB comms recovery may stay disarmed' "$ERR" \
  && ! grep -qF 'cleared killpower flag after failed poweroff so USB comms recovery stays armed' "$ERR"; then
  ok 'a refused killpower clear stays fail-soft and reports that recovery may remain disarmed'
else
  no 'refused terminal-failure cleanup' "rc=$RUN_RC rm=$(tr '\n' ' ' <"$RM_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

cat >"$BIN/dbus-send" <<'EOF'
#!/bin/sh
[ "$*" = "$DBUS_ARGS" ] || exit 95
printf '%s\n' "$*" >>"$DBUS_CALLS"
_body=$(printf '%0600d' 0)
printf 'refused"\nlevel=error msg="forged by dbus output" body=%s\\tail\n' "$_body" >&2
exit 1
EOF
chmod +x "$BIN/dbus-send"

run_shutdown failure failure failure
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$ERR")" -eq 6 ] \
  && ! grep -q '^level=error msg="forged by dbus output"' "$ERR" \
  && awk '
    /D-Bus poweroff failed/ {
      if ($0 !~ / detail="[^"]*"$/) exit 1
      detail = $0
      sub(/^.* detail="/, "", detail)
      sub(/"$/, "", detail)
      if (length(detail) > 512 || index(detail, "\\") != 0) exit 1
      seen++
    }
    END { if (seen != 3) exit 1 }
  ' "$ERR"; then
  ok 'hostile D-Bus output stays inside three balanced, bounded detail fields without forging a record'
else
  no 'hostile D-Bus output log safety' "rc=$RUN_RC lines=$(wc -l <"$ERR"); stderr: $(tr '\n' '|' <"$ERR")"
fi

report
