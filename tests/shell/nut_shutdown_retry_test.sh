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
SETTLE_ARGS='--system --print-reply --reply-timeout=3000 --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.DBus.Properties.Get string:org.freedesktop.login1.Manager string:PreparingForShutdown'
INHIBITOR_ARGS='--system --print-reply --reply-timeout=3000 --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.ListInhibitors'
SETTLE_VALUE=true

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
if [ "$*" = "$SETTLE_ARGS" ]; then
  printf 'method return\n   variant boolean %s\n' "$SETTLE_VALUE"
  exit 0
fi
[ "$*" = "$DBUS_ARGS" ] || exit 95
printf '%s\n' "$*" >>"$DBUS_CALLS"
_call=$(wc -l <"$DBUS_CALLS")
_result=$(sed -n "${_call}p" "$DBUS_RESULTS")
case "$_result" in
  success) printf 'method return\n'; exit 0 ;;
  failure) printf 'D-Bus refused request\n' >&2; exit 1 ;;
  failure:*) printf '%s\n' "${_result#failure:}" >&2; exit 1 ;;
  *) printf 'unexpected D-Bus call %s\n' "$_call" >&2; exit 94 ;;
esac
EOF
cat >"$BIN/sleep" <<'EOF'
#!/bin/sh
[ "$#" -eq 1 ] || exit 93
case "$1" in
  2 | 8)
    printf '%s\n' "$1" >>"$SLEEP_CALLS"
    ;;
  *) exit 93 ;;
esac
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
    SETTLE_ARGS="$SETTLE_ARGS" SETTLE_VALUE="$SETTLE_VALUE" \
    sh "$ENTRYPOINT" >"$OUT" 2>"$ERR" || RUN_RC=$?
}

run_shutdown success
if [ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 1 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 2 ] \
  && [ "$(cat "$SLEEP_CALLS")" = 8 ] \
  && [ ! -s "$RM_CALLS" ] \
  && grep -qF 'host poweroff dispatched via D-Bus" attempt=1' "$ERR" \
  && ! grep -qF 'retrying' "$ERR"; then
  ok 'first-attempt success makes one PowerOff request, waits to settle, and reads the property without retrying'
else
  no 'first-attempt success' "rc=$RUN_RC dbus=$(wc -l <"$DBUS_CALLS") timeout=$(wc -l <"$TIMEOUT_CALLS") sleeps=$(wc -l <"$SLEEP_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

container_error_pattern=$(awk '
  /- alert: UPSContainerError$/ { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$REPO_ROOT/alerts/logql.yaml" \
  | sed -n 's/.*|~ `\([^`]*\)`.*/\1/p' \
  | head -1)
initial_record=$(head -n 1 "$ERR")
if [ -n "$container_error_pattern" ] \
  && [ "$initial_record" = 'level=error msg="UPS forced shutdown triggered; powering off host"' ] \
  && printf '%s\n' "$initial_record" | grep -Eq -- "$container_error_pattern"; then
  ok 'the forced-shutdown opening record matches UPSContainerError'
else
  no 'forced-shutdown opening record' "record=[$initial_record] matcher=[$container_error_pattern]"
fi

run_shutdown failure success
if [ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 2 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 3 ] \
  && [ "$(cat "$SLEEP_CALLS")" = "$(printf '2\n8')" ] \
  && [ ! -s "$RM_CALLS" ] \
  && [ "$(grep -cF 'D-Bus poweroff failed, retrying" attempt=1' "$ERR")" -eq 1 ] \
  && grep -qF 'host poweroff dispatched via D-Bus" attempt=2' "$ERR"; then
  ok 'a transient failure records attempt 1, sleeps once, and stops on attempt 2 success'
else
  no 'failure then success' "rc=$RUN_RC dbus=$(wc -l <"$DBUS_CALLS") timeout=$(wc -l <"$TIMEOUT_CALLS") sleeps=$(tr '\n' ' ' <"$SLEEP_CALLS"); stderr: $(tr '\n' ' ' <"$ERR")"
fi

SETTLE_VALUE=false_long
run_shutdown failure failure failure
failure_line=$(grep -nF 'D-Bus poweroff failed after 3 attempts' "$ERR" | cut -d: -f1)
inhibitor_line=$(grep -nF 'D-Bus poweroff inhibitors at failure' "$ERR" | cut -d: -f1)
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 3 ] \
  && [ "$(wc -l <"$INHIBITOR_CALLS")" -eq 1 ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 5 ] \
  && [ "$(wc -l <"$SLEEP_CALLS")" -eq 3 ] \
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

run_shutdown 'failure:first refusal' 'failure:second refusal' 'failure:third refusal'
if [ "$RUN_RC" -eq 1 ] \
  && grep -qxF 'level=warn msg="D-Bus poweroff failed, retrying" attempt=1 detail="first refusal"' "$ERR" \
  && grep -qxF 'level=warn msg="D-Bus poweroff failed, retrying" attempt=2 detail="second refusal"' "$ERR" \
  && grep -qxF 'level=error msg="D-Bus poweroff failed after 3 attempts; host poweroff NOT confirmed" detail="third refusal"' "$ERR"; then
  ok 'the terminal poweroff failure reports the last attempt detail'
else
  no 'per-attempt poweroff failure detail' "rc=$RUN_RC; stderr: $(tr '\n' '|' <"$ERR")"
fi

poweroff_failed_matcher=$(awk '
  /- alert: UPSPowerOffFailed$/ { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$REPO_ROOT/alerts/logql.yaml" \
  | sed -n 's/.*| logfmt | msg=~"\([^"]*\)".*/\1/p' \
  | head -1)
if [ -z "$poweroff_failed_matcher" ]; then
  printf 'harness error: no parsed-msg matcher extracted for UPSPowerOffFailed\n' >&2
  exit 1
fi

shutdown_messages=$(sed -n 's/^level=[^ ]* msg="\([^"]*\)".*/\1/p' "$ERR")
matched_messages=$(printf '%s\n' "$shutdown_messages" \
  | grep -Ec -- "^${poweroff_failed_matcher}$" || :)
matched_retries=$(grep ' attempt=' "$ERR" \
  | sed -n 's/^level=[^ ]* msg="\([^"]*\)".*/\1/p' \
  | grep -Ec -- "^${poweroff_failed_matcher}$" || :)
if [ "$matched_messages" -eq 1 ] && [ "$matched_retries" -eq 0 ]; then
  ok 'UPSPowerOffFailed matcher selects only the terminal failed-poweroff record'
else
  no 'UPSPowerOffFailed matcher contract' "matched=$matched_messages retry_matches=$matched_retries matcher=$poweroff_failed_matcher"
fi

SETTLE_VALUE=false
run_shutdown success
settle_sleep=$(cat "$SLEEP_CALLS")
settle_message=$(sed -n 's/^level=[^ ]* msg="\([^"]*\)".*/\1/p' "$ERR" \
  | grep -F 'D-Bus poweroff failed after logind accepted the request')
settle_record='level=error msg="D-Bus poweroff failed after logind accepted the request; host poweroff NOT confirmed" attempt=1 detail="method return    variant boolean false"'
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$DBUS_CALLS")" -eq 1 ] \
  && [ ! -s "$INHIBITOR_CALLS" ] \
  && [ "$(wc -l <"$TIMEOUT_CALLS")" -eq 2 ] \
  && [ "$settle_sleep" = 8 ] \
  && [ "$(cat "$RM_CALLS")" = '-f /var/run/nut-secrets/killpower' ] \
  && grep -qxF "$settle_record" "$ERR" \
  && printf '%s\n' "$settle_message" | grep -Eq -- "^${poweroff_failed_matcher}$" \
  && grep -qF 'cleared killpower flag after failed poweroff so USB comms recovery stays armed' "$ERR"; then
  ok 'a rejected settle state waits past logind inhibition, clears killpower, and emits the UPSPowerOffFailed record'
else
  no 'settle-state failure' "rc=$RUN_RC dbus=$(wc -l <"$DBUS_CALLS") timeout=$(wc -l <"$TIMEOUT_CALLS") sleep=$settle_sleep rm=$(tr '\n' ' ' <"$RM_CALLS") matcher=$poweroff_failed_matcher; stderr: $(tr '\n' '|' <"$ERR")"
fi
SETTLE_VALUE=true

cat >"$BIN/rm" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = /var/run/nut-secrets/killpower ] || exit 92
printf '%s\n' "$*" >>"$RM_CALLS"
exit 1
EOF
chmod +x "$BIN/rm"

SETTLE_VALUE=false_long
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
if [ "$*" = "$SETTLE_ARGS" ]; then
  case "$SETTLE_VALUE" in
    true) printf 'method return\n   variant boolean true\n' ;;
    failed) printf 'settle read failed\n' >&2; exit 1 ;;
    empty) exit 0 ;;
    malformed) printf 'method return\n   string "not a boolean"\n' ;;
    valueless) printf 'method return\n   variant boolean\n' ;;
    truncated) printf 'method return\n' ;;
    false_long)
      _body=$(printf '%0600d' 0)
      printf 'method return\n   variant boolean false %s\n' "$_body"
      ;;
    malformed_long)
      _body=$(printf '%0600d' 0)
      printf 'method return\n   string "%s"\n' "$_body"
      ;;
    *) exit 91 ;;
  esac
  exit 0
fi
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
  *) exit 94 ;;
esac
EOF
chmod +x "$BIN/dbus-send"

write_settle_observables() {
  printf 'rc=%s\n' "$RUN_RC"
  for _artifact in "$OUT" "$ERR" "$DBUS_CALLS" "$INHIBITOR_CALLS" \
    "$TIMEOUT_CALLS" "$SLEEP_CALLS" "$RM_CALLS"; do
    printf 'bytes=%s\n' "$(wc -c <"$_artifact")"
    cat "$_artifact"
  done
}

SETTLE_VALUE=true
run_shutdown success
if [ "$RUN_RC" -eq 0 ] \
  && [ ! -s "$RM_CALLS" ] \
  && ! grep -qF 'D-Bus poweroff settle state unreadable' "$ERR"; then
  ok 'canonical true remains a pending poweroff without cleanup or an unreadable-state record'
else
  no 'canonical true pending settle precondition' "$(write_settle_observables | tr '\n' ' ')"
fi

for SETTLE_VALUE in failed empty malformed valueless truncated; do
  run_shutdown success
  unreadable_messages=$(sed -n 's/^level=[^ ]* msg="\([^"]*\)".*/\1/p' "$ERR" \
    | grep '^D-Bus poweroff settle state unreadable' || :)
  if [ "$RUN_RC" -eq 0 ] \
    && [ ! -s "$RM_CALLS" ] \
    && [ ! -s "$INHIBITOR_CALLS" ] \
    && [ "$(printf '%s\n' "$unreadable_messages" | grep -c .)" -eq 1 ] \
    && [ "$(grep -Ec '^level=warn msg="D-Bus poweroff settle state unreadable[^"]*" attempt=[0-9]+ detail="[^"]*"$' "$ERR")" -eq 1 ] \
    && [ "$(grep -cF 'level=info msg="host poweroff dispatched via D-Bus" attempt=1' "$ERR")" -eq 1 ] \
    && ! printf '%s\n' "$unreadable_messages" | grep -Eq -- "^${poweroff_failed_matcher}$"; then
    ok "$SETTLE_VALUE settle reply is reported as unreadable without critical-alert routing or cleanup"
  else
    no "$SETTLE_VALUE unreadable settle reply" "$(write_settle_observables | tr '\n' ' ')"
  fi
done

cat >"$BIN/rm" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = /var/run/nut-secrets/killpower ] || exit 92
printf '%s\n' "$*" >>"$RM_CALLS"
EOF
chmod +x "$BIN/rm"

SETTLE_VALUE=false_long
run_shutdown success
false_long_rc=$RUN_RC
false_long_record=$(grep -F 'D-Bus poweroff failed after logind accepted the request' "$ERR" || :)
false_long_detail=${false_long_record##* detail=\"}
false_long_detail=${false_long_detail%\"}

SETTLE_VALUE=malformed_long
run_shutdown success
malformed_long_rc=$RUN_RC
malformed_long_record=$(grep -F 'D-Bus poweroff settle state unreadable' "$ERR" || :)
malformed_long_detail=${malformed_long_record##* detail=\"}
malformed_long_detail=${malformed_long_detail%\"}

if [ "$false_long_rc" -eq 1 ] \
  && [ "$malformed_long_rc" -eq 0 ] \
  && [ "${#false_long_detail}" -eq 512 ] \
  && [ "${false_long_detail: -3}" = '...' ] \
  && [ "${#malformed_long_detail}" -eq 512 ] \
  && [ "${malformed_long_detail: -3}" = '...' ]; then
  ok 'overlong settle replies stay bounded on both terminal branches'
else
  no 'overlong settle reply bounds' "false_rc=$false_long_rc false_length=${#false_long_detail} malformed_rc=$malformed_long_rc malformed_length=${#malformed_long_detail}"
fi
SETTLE_VALUE=true

for _settle_case in pending refuted unreadable; do
  case "$_settle_case" in
    pending) SETTLE_VALUE=true ;;
    refuted) SETTLE_VALUE=false_long ;;
    unreadable) SETTLE_VALUE=failed ;;
  esac
  run_shutdown failure failure failure
  _settle_alert_matches=$(sed -n 's/^level=[^ ]* msg="\([^"]*\)".*/\1/p' "$ERR" \
    | grep -Ec -- "^${poweroff_failed_matcher}$" || :)
  case "$_settle_case" in
    pending)
      if [ "$RUN_RC" -eq 0 ] \
        && [ ! -s "$RM_CALLS" ] \
        && [ ! -s "$INHIBITOR_CALLS" ] \
        && [ "$_settle_alert_matches" -eq 0 ] \
        && grep -qF 'D-Bus poweroff requests failed but logind reports a pending poweroff; host poweroff NOT refuted' "$ERR"; then
        ok 'a pending settle state after exhausted PowerOff failures avoids critical-alert routing and cleanup'
      else
        no 'failed-PowerOff pending settle state' "$(write_settle_observables | tr '\n' ' ')"
      fi
      ;;
    refuted)
      if [ "$RUN_RC" -eq 1 ] \
        && [ "$(cat "$RM_CALLS")" = '-f /var/run/nut-secrets/killpower' ] \
        && [ "$(wc -l <"$INHIBITOR_CALLS")" -eq 1 ] \
        && [ "$_settle_alert_matches" -eq 1 ]; then
        ok 'a refuted settle state after exhausted PowerOff failures takes the confirmed-failure path'
      else
        no 'failed-PowerOff refuted settle state' "$(write_settle_observables | tr '\n' ' ')"
      fi
      ;;
    unreadable)
      if [ "$RUN_RC" -eq 1 ] \
        && [ "$(cat "$RM_CALLS")" = '-f /var/run/nut-secrets/killpower' ] \
        && [ ! -s "$INHIBITOR_CALLS" ] \
        && [ "$_settle_alert_matches" -eq 1 ]; then
        ok 'an unreadable settle state after exhausted PowerOff failures keeps the terminal failure path without inhibitor reporting'
      else
        no 'failed-PowerOff unreadable settle state' "$(write_settle_observables | tr '\n' ' ')"
      fi
      ;;
  esac
done
SETTLE_VALUE=true

cat >"$BIN/dbus-send" <<'EOF'
#!/bin/sh
_body=$(printf '%0600d' 0)
if [ "$*" = "$SETTLE_ARGS" ]; then
  printf 'method return\n   variant boolean %s\n' "$SETTLE_VALUE"
  exit 0
fi
if [ "$*" = "$INHIBITOR_ARGS" ]; then
  printf '%s\n' "$*" >>"$INHIBITOR_CALLS"
  printf 'method return\n   array [\n      struct { string "shutdown" string "backup writer"\nlevel=error msg="forged by inhibitor output" body=%s\\tail" string "backupd" string "block" uint32 1000 uint32 42 }\n   ]\n' "$_body"
  exit 0
fi
[ "$*" = "$DBUS_ARGS" ] || exit 95
printf '%s\n' "$*" >>"$DBUS_CALLS"
printf 'refused"\nlevel=error msg="forged by dbus output" body=%s\\tail\n' "$_body" >&2
exit 1
EOF
chmod +x "$BIN/dbus-send"

SETTLE_VALUE=false_long
run_shutdown failure failure failure
if [ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$INHIBITOR_CALLS")" -eq 1 ] \
  && [ "$(wc -l <"$ERR")" -eq 6 ] \
  && ! grep -q '^level=error msg="forged by dbus output"' "$ERR" \
  && ! grep -q '^level=error msg="forged by inhibitor output"' "$ERR" \
  && awk '
    / detail="/ {
      if ($0 !~ / detail="[^"]*"$/) exit 1
      detail = $0
      sub(/^.* detail="/, "", detail)
      sub(/"$/, "", detail)
      if (length(detail) > 512 || index(detail, "\\") != 0) exit 1
      seen++
    }
    END { if (seen != 4) exit 1 }
  ' "$ERR"; then
  ok 'hostile D-Bus output stays inside four balanced, bounded detail fields without forging a record'
else
  no 'hostile D-Bus output log safety' "rc=$RUN_RC inhibitors=$(wc -l <"$INHIBITOR_CALLS") lines=$(wc -l <"$ERR"); stderr: $(tr '\n' '|' <"$ERR")"
fi

report
