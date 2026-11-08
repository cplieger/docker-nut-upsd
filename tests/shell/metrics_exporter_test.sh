#!/usr/bin/env bash
# The in-image metrics exporter's settings and supervision: METRICS_PORT=0
# starts no exporter, a METRICS_PORT equal to API_PORT or outside 0 to 65535
# stops the boot, and an address the exporter cannot listen on stops it too.
# The exporter is a stub here: the Go tests (main_test.go) prove the real one
# refuses a malformed address before it writes the ready file this waits for.
#
# Lint directives for this whole file, each against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
#   SC2034 - the env vars assigned here are inputs to code extracted and
#     sourced at runtime, so shellcheck cannot see the reads.
#   SC2329 - stubs are invoked by the extracted code.
# shellcheck disable=SC2015,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null
ERR="$WORK/err.log"
# The files under test; a red-check points one at a mutated /tmp copy.
VALIDATE="${VALIDATE:-$REPO_ROOT/validate.sh}"
LIFECYCLE="${LIFECYCLE:-$REPO_ROOT/lifecycle.sh}"
ENTRY="${ENTRY:-$REPO_ROOT/entrypoint.sh}"

# --- 1. validation ----------------------------------------------------------------
ENTRYPOINT="$VALIDATE"
for fn in log_value strip_leading_zeros validate_no_control_chars validate_identifier \
  validate_no_hash validate_no_quotes validate_no_backslash validate_no_whitespace \
  nut_stored_word validate_nut_word validate_no_brackets validate_numeric validate_positive \
  validate_port validate_port_or_zero validate_percent _dispatch_check _check _check_optional \
  check_required_vars check_optional_vars driver_transport run_validations; do
  load_function "$fn"
done

# validate_with <METRICS_PORT> <METRICS_ADDRESS> -> run_validations' status
# over an otherwise valid environment.
validate_with() (
  UPS_NAME=ups UPS_DESC='Test UPS' UPS_DRIVER=usbhid-ups UPS_PORT=auto
  API_USER=monuser API_PASSWORD=secret API_ADDRESS=0.0.0.0 API_PORT=3493 API_TLS=true
  ADMIN_PASSWORD=adminpass SHUTDOWN_ON_BATTERY_CRITICAL=false DBUS_PROBE_INTERVAL=300
  POLLFREQ=5 POLLFREQALERT=5 DEADTIME=15 FINALDELAY=5 HOSTSYNC=15
  NOCOMMWARNTIME=300 RBWARNTIME=43200 COMMS_WATCHDOG=true COMMS_CHECK_INTERVAL=15
  COMMS_RECOVERY_TIMEOUT=90 COMMS_FAST_RETRIES=3 COMMS_BACKOFF_FACTOR=5
  LOWBATT_PERCENT='' LOWBATT_RUNTIME=''
  METRICS_PORT=$1 METRICS_ADDRESS=$2
  run_validations
)

for port in 0 9199 09199 65535 1; do
  if validate_with "$port" 0.0.0.0 2>"$ERR"; then
    ok "METRICS_PORT=$port is accepted"
  else
    no "METRICS_PORT=$port accepted" "refused: $(head -c 200 "$ERR")"
  fi
done
if validate_with 9199 :: 2>"$ERR" && validate_with 9199 192.0.2.10 2>"$ERR"; then
  ok 'an IPv6 METRICS_ADDRESS without brackets and an IPv4 one are accepted'
else
  no 'METRICS_ADDRESS accepted' "refused: $(head -c 200 "$ERR")"
fi

refused() {
  local what=$1 port=$2 addr=$3 want=$4
  : >"$ERR"
  if validate_with "$port" "$addr" 2>"$ERR"; then
    no "$what" "accepted METRICS_PORT=$port METRICS_ADDRESS=$addr"
  elif grep -Fq "$want" "$ERR"; then
    ok "$what"
  else
    no "$what" "refused without \"$want\": $(head -c 200 "$ERR")"
  fi
}
refused 'METRICS_PORT equal to API_PORT stops the boot' 3493 0.0.0.0 'msg="METRICS_PORT must differ from API_PORT"'
refused 'METRICS_PORT equal to API_PORT with a leading zero stops the boot' 03493 0.0.0.0 'msg="METRICS_PORT must differ from API_PORT"'
refused 'METRICS_PORT above 65535 stops the boot' 65536 0.0.0.0 'msg="env var must be 0-65535" var=METRICS_PORT'
refused 'a negative METRICS_PORT stops the boot' -1 0.0.0.0 'msg="env var must be a non-negative integer" var=METRICS_PORT'
refused 'a non-numeric METRICS_PORT stops the boot' 9199x 0.0.0.0 'msg="env var must be a non-negative integer" var=METRICS_PORT'
refused 'an empty METRICS_PORT stops the boot' '' 0.0.0.0 'msg="env var must be a non-negative integer" var=METRICS_PORT'
refused 'a bracketed METRICS_ADDRESS stops the boot' 9199 '[::1]' 'msg="env var contains bracket characters" var=METRICS_ADDRESS'
refused 'a METRICS_ADDRESS with a space stops the boot' 9199 '0.0.0.0 x' 'msg="env var contains whitespace" var=METRICS_ADDRESS'
# shellcheck disable=SC2016
refused 'a METRICS_ADDRESS with a control character stops the boot' 9199 "$(printf '0.0.0.0\tx')" 'msg="env var contains control characters" var=METRICS_ADDRESS'

# --- 2. METRICS_PORT=0 starts no exporter ----------------------------------------------
ENTRYPOINT="$ENTRY"
# shellcheck disable=SC2016 # the regex matches the literal $METRICS_PORT
start_block=$(extract_range '^if \[ "\$METRICS_PORT" -ne 0 \]; then$' '^fi$' "$WORK/start-block.sh") || exit 1
order_ok=$(awk '
  /^if \[ "\$METRICS_PORT" -ne 0 \]; then$/ { exporter = NR }
  /^start_nut_daemon "upsdrvctl"/ { driver = NR }
  END { print (exporter && driver && exporter < driver) ? "yes" : "no" }
' "$ENTRYPOINT")
[ "$order_ok" = yes ] \
  && ok 'the exporter starts before the NUT daemons, so a bad bind stops the boot before anything else runs' \
  || no 'exporter start order' 'the METRICS_PORT block does not precede the upsdrvctl start'

run_start_block() (
  METRICS_PORT=$1
  METRICS_ADDRESS=${3:-0.0.0.0}
  START_RC=$2
  STARTS="$WORK/starts"
  : >"$STARTS"
  start_metrics_exporter() {
    printf 'start\n' >>"$STARTS"
    return "$START_RC"
  }
  teardown_all() { printf 'teardown\n' >>"$STARTS"; }
  metrics_listen_address() { printf '%s:%s' "$METRICS_ADDRESS" "$METRICS_PORT"; }
  # shellcheck disable=SC1090
  . "$start_block"
  printf 'reached\n' >>"$STARTS"
)

run_start_block 0 0 2>"$ERR"
if [ ! -s "$WORK/starts" ] || [ "$(cat "$WORK/starts")" != reached ]; then
  no 'METRICS_PORT=0 starts no exporter' "calls: $(tr '\n' ' ' <"$WORK/starts")"
elif grep -Fq 'msg="metrics exporter disabled" metrics_port=0' "$ERR"; then
  ok 'METRICS_PORT=0 starts no exporter and says so'
else
  no 'METRICS_PORT=0 record' "stderr: $(head -c 200 "$ERR")"
fi
_rc=0
run_start_block 9199 0 2>"$ERR" || _rc=$?
[ "$_rc" -eq 0 ] && [ "$(tr '\n' ' ' <"$WORK/starts")" = 'start reached ' ] \
  && ok 'METRICS_PORT=9199 starts the exporter and boots on' \
  || no 'METRICS_PORT=9199 start' "rc=$_rc calls: $(tr '\n' ' ' <"$WORK/starts")"
run_start_block 9199 0 'a"b=c' 2>"$ERR" || :
grep -Fxq 'level=info msg="starting metrics exporter" listen="ab=c:9199"' "$ERR" \
  && ok 'the starting record quotes the listen address and drops its double quotes' \
  || no 'starting record listen field' "stderr: $(head -c 200 "$ERR")"
_rc=0
run_start_block 9199 1 2>"$ERR" || _rc=$?
[ "$_rc" -eq 1 ] && [ "$(tr '\n' ' ' <"$WORK/starts")" = 'start teardown ' ] \
  && ok 'an exporter that cannot start tears down and exits 1' \
  || no 'exporter start failure' "rc=$_rc calls: $(tr '\n' ' ' <"$WORK/starts")"

# --- 3. start_metrics_exporter against a stub exporter ----------------------------
ENTRYPOINT="$LIFECYCLE"
for fn in pid_running metrics_listen_address start_metrics_exporter upsd_probe_host \
  write_wrapper_state record_driver_restart; do
  load_function "$fn"
done
ENTRYPOINT="$VALIDATE"
load_function strip_leading_zeros
load_function log_value

constants=$(sed -n '/^WRAPPER_STATE_DIR=/,/^EXPORTER_START_TIMEOUT=/p' "$LIFECYCLE")
if [ -z "$constants" ]; then
  printf 'harness error: the wrapper state constants were not found in lifecycle.sh\n' >&2
  exit 1
fi
eval "$constants"

STUB="$WORK/nut-exporter"
STUB_ARGS="$WORK/stub-args"
# stub_exporter <mode>: ready writes the ready file and stays up; exit fails
# at once with status 3; hang never binds.
stub_exporter() {
  cat >"$STUB" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$STUB_ARGS"
case "$1" in
  ready) : >"$WORK/state/exporter.ready"; exec sleep 30 ;;
  exit) exit 3 ;;
  hang) exec sleep 30 ;;
esac
EOF
  chmod 755 "$STUB"
}

run_exporter() (
  WRAPPER_STATE_DIR="$WORK/state"
  EXPORTER_BIN="$STUB"
  EXPORTER_START_TIMEOUT=1
  METRICS_ADDRESS=$1 METRICS_PORT=9199 API_ADDRESS=0.0.0.0 API_PORT=3493 UPS_NAME=ups
  SHUTDOWN_ON_BATTERY_CRITICAL=true
  mkdir -p "$WRAPPER_STATE_DIR"
  : >"$WRAPPER_STATE_DIR/exporter.ready"
  start_metrics_exporter || exit $?
  # shellcheck disable=SC2153 # start_metrics_exporter sets it
  pid_running "$EXPORTER_PID" || exit 9
  kill "$EXPORTER_PID"
  wait "$EXPORTER_PID" 2>/dev/null || true
  exit 0
)

stub_exporter ready
rm -f "$STUB_ARGS"
if run_exporter :: 2>"$ERR"; then
  expected=$(printf '%s\n' -listen '[::]:9199' -upsd 127.0.0.1:3493 -ups ups -state-dir "$WORK/state" -host-poweroff=true -user nut)
  [ "$(cat "$STUB_ARGS")" = "$expected" ] \
    && ok 'a started exporter gets the bracketed IPv6 listen address, upsd, the UPS, the state dir, the poweroff toggle and the nut user' \
    || no 'exporter argv' "got: $(tr '\n' ' ' <"$STUB_ARGS")"
else
  no 'exporter start with a ready stub' "rc=$? stderr: $(head -c 200 "$ERR")"
fi

stub_exporter exit
_rc=0
run_exporter 300.1.1.1 2>"$ERR" || _rc=$?
[ "$_rc" -eq 1 ] && grep -Fq 'level=error msg="metrics exporter failed to start; check METRICS_ADDRESS and METRICS_PORT" listen="300.1.1.1:9199" rc=3' "$ERR" \
  && ok 'an exporter that exits before binding fails the start, naming the listen address and its status' \
  || no 'exporter exit before bind' "rc=$_rc stderr: $(head -c 300 "$ERR")"

stub_exporter hang
_rc=0
run_exporter 0.0.0.0 2>"$ERR" || _rc=$?
[ "$_rc" -eq 1 ] && grep -Fq 'msg="metrics exporter did not bind its listener in time"' "$ERR" \
  && ok 'an exporter that never binds fails the start after the timeout' \
  || no 'exporter bind timeout' "rc=$_rc stderr: $(head -c 300 "$ERR")"

# --- 4. pid_running reads the process state --------------------------------------
sleep 30 &
live=$!
(exit 0) &
gone=$!
wait "$gone"
pid_running "$live" && ! pid_running "$gone" && ! pid_running '' && ! pid_running abc \
  && ok 'pid_running holds for a live PID and not for a reaped one or a non-number' \
  || no 'pid_running' "live=$live gone=$gone"
kill "$live"
wait "$live" 2>/dev/null || true

# A zombie stays in /proc until its parent waits; it must not count as running.
# sh execs into sleep, which never waits, so the backgrounded child stays a zombie.
sh -c 'sleep 0.1 & printf "%s\n" "$!" >"$1"; exec sleep 3' sh "$WORK/zpid" &
holder=$!
zstate=""
for _ in $(seq 1 40); do
  zpid=$(cat "$WORK/zpid" 2>/dev/null)
  if [ -n "$zpid" ]; then
    zstat=$(head -c 1024 "/proc/$zpid/stat" 2>/dev/null)
    zstate=${zstat##*) }
    [ "${zstate%% *}" = Z ] && break
  fi
  sleep 0.05
done
if [ "${zstate%% *}" != Z ]; then
  skip 'pid_running zombie case' 'could not hold a zombie child for the check'
elif pid_running "$zpid"; then
  no 'pid_running zombie' "the zombie $zpid counted as running"
else
  ok 'pid_running does not count an unreaped zombie as running'
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# --- 5. the restart count the exporter serves -------------------------------------
(
  WRAPPER_STATE_DIR="$WORK/state2"
  mkdir -p "$WRAPPER_STATE_DIR"
  record_driver_restart
  record_driver_restart
  printf '%s\n' "$(cat "$WRAPPER_STATE_DIR/$DRIVER_RESTARTS_STATE")" >"$WORK/count-two"
  printf 'garbage\n' >"$WRAPPER_STATE_DIR/$DRIVER_RESTARTS_STATE"
  record_driver_restart
  printf '%s\n' "$(cat "$WRAPPER_STATE_DIR/$DRIVER_RESTARTS_STATE")" >"$WORK/count-reset"
  printf '007\n' >"$WRAPPER_STATE_DIR/$DRIVER_RESTARTS_STATE"
  record_driver_restart
  printf '%s\n' "$(cat "$WRAPPER_STATE_DIR/$DRIVER_RESTARTS_STATE")" >"$WORK/count-octal"
)
[ "$(cat "$WORK/count-two")" = 2 ] && [ "$(cat "$WORK/count-reset")" = 1 ] && [ "$(cat "$WORK/count-octal")" = 8 ] \
  && ok 'record_driver_restart counts up from the file, restarts from 1 over garbage and reads 007 as decimal' \
  || no 'record_driver_restart' "two=$(cat "$WORK/count-two") reset=$(cat "$WORK/count-reset") octal=$(cat "$WORK/count-octal")"

_rc=0
(
  set -e
  WRAPPER_STATE_DIR="$WORK/no-such-dir"
  write_wrapper_state "$POWEROFF_PATH_STATE" 1
  printf 'continued\n' >"$WORK/continued"
) 2>"$ERR" || _rc=$?
[ "$_rc" -eq 0 ] && [ -s "$WORK/continued" ] && grep -Fq 'level=warn msg="could not record state for the metrics exporter" name=poweroff-path' "$ERR" \
  && ok 'a state write that fails warns and lets a set -e loop continue' \
  || no 'write_wrapper_state failure' "rc=$_rc stderr: $(head -c 200 "$ERR")"

report
