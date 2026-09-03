#!/usr/bin/env bash
# A signal received while a daemon starter is still running must interrupt the
# background wait, run the real graceful handler, and finish before the starter.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

SUBJECT="$REPO_ROOT/entrypoint.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
START_FN=$(extract_function start_nut_daemon "$WORK/start_nut_daemon.sh") || exit 1
SHUTDOWN_FN=$(extract_function graceful_shutdown "$WORK/graceful_shutdown.sh") || exit 1

cat >"$WORK/slow-starter.sh" <<'STARTER'
#!/usr/bin/env bash
set -u
printf '%s\n' "$BASHPID" >"$STARTER_PID"
trap 'exit 0' TERM INT
sleep 10
printf 'completed\n' >"$COMPLETION"
STARTER
chmod +x "$WORK/slow-starter.sh"

# This bash harness proves less about signal timing than shipped BusyBox ash,
# which runs a pending trap only after the current foreground command returns.
cat >"$WORK/drive-start.sh" <<'DRIVER'
#!/usr/bin/env bash
set -eu
stop_services() { :; }
teardown_all() { printf 'teardown\n' >"$TEARDOWN"; }
timeout() {
  printf '%s\n' "$*" >"$TIMEOUT_ARGV"
  shift 3
  "$@"
}
. "$START_FN"
. "$SHUTDOWN_FN"
trap graceful_shutdown TERM INT QUIT HUP
start_nut_daemon upsd 30 "$STARTER"
DRIVER
chmod +x "$WORK/drive-start.sh"

: >"$WORK/stderr"
env START_FN="$START_FN" SHUTDOWN_FN="$SHUTDOWN_FN" \
  STARTER="$WORK/slow-starter.sh" STARTER_PID="$WORK/starter.pid" \
  COMPLETION="$WORK/completed" TEARDOWN="$WORK/teardown" \
  TIMEOUT_ARGV="$WORK/timeout-argv" \
  bash "$WORK/drive-start.sh" >"$WORK/stdout" 2>"$WORK/stderr" &
driver_pid=$!

started=0
for _ in $(seq 1 40); do
  if [ -s "$WORK/starter.pid" ]; then
    started=1
    break
  fi
  sleep 0.05
done

if [ "$started" -eq 1 ]; then
  kill -TERM "$driver_pid"
fi

finished=0
for _ in $(seq 1 40); do
  if ! jobs -pr | grep -qx "$driver_pid"; then
    finished=1
    break
  fi
  sleep 0.05
done

if [ "$finished" -eq 1 ]; then
  if wait "$driver_pid"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
else
  kill -KILL "$driver_pid" 2>/dev/null || true
  wait "$driver_pid" 2>/dev/null || true
  RUN_RC=137
fi

if [ -s "$WORK/starter.pid" ]; then
  starter_pid=$(cat "$WORK/starter.pid")
  kill -TERM "$starter_pid" 2>/dev/null || true
fi

[ "$started" -eq 1 ] && [ "$finished" -eq 1 ] && [ "$RUN_RC" -eq 0 ] \
  && grep -q 'level=info msg="received shutdown signal"' "$WORK/stderr" \
  && [ -s "$WORK/teardown" ] && [ ! -e "$WORK/completed" ] \
  && grep -Fqx -- "-k 5 30 $WORK/slow-starter.sh" "$WORK/timeout-argv" \
  && ok 'SIGTERM interrupts the boot-time wait, tears down, and exits before the starter completes' \
  || no 'boot-time SIGTERM responsiveness' "started=$started finished=$finished rc=$RUN_RC stderr=$(cat "$WORK/stderr")"

BOOT_BLOCK=$(extract_range '^trap graceful_shutdown TERM INT QUIT HUP$' '^# Run upsmon in the background' "$WORK/boot-failure-block.sh") || exit 1

cat >"$WORK/drive-boot-failure.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
UPS_NAME=ups
UPS_DRIVER=usbhid-ups
UPS_PORT=auto
API_ADDRESS=0.0.0.0
API_PORT=3493

graceful_shutdown() { exit 0; }
teardown_all() { printf 'teardown\n' >>"$TEARDOWN_LOG"; }
driver_pidfile() { printf '/var/run/nut/usbhid-ups-ups.pid'; }
driver_binary() { printf '/usr/lib/nut/usbhid-ups'; }
timeout() {
  printf '%s\n' "$*" >>"$TIMEOUT_CALLS"
  case "$*" in
    '-k 5 90 /usr/sbin/upsdrvctl start' | '-k 5 30 /usr/sbin/upsd') ;;
    *) return 96 ;;
  esac
  _call=$(wc -l <"$TIMEOUT_CALLS")
  if [ "$MODE" = starter-failure ] && [ "$_call" -eq 1 ]; then
    return 9
  fi
  return 0
}
wait_for_pidfile() {
  printf '%s\n' "$*" >>"$PIDFILE_CALLS"
  _call=$(wc -l <"$PIDFILE_CALLS")
  case "$MODE:$_call" in
    driver-pid-failure:1 | upsd-pid-failure:2) return 1 ;;
    *) return 0 ;;
  esac
}

. "$BOOT_BLOCK"
DRIVER
chmod +x "$WORK/drive-boot-failure.sh"

run_boot_failure() {
  : >"$WORK/boot-teardown"
  : >"$WORK/boot-timeout-calls"
  : >"$WORK/boot-pidfile-calls"
  : >"$WORK/boot-stderr"
  if env MODE="$1" BOOT_BLOCK="$BOOT_BLOCK" \
    TEARDOWN_LOG="$WORK/boot-teardown" \
    TIMEOUT_CALLS="$WORK/boot-timeout-calls" \
    PIDFILE_CALLS="$WORK/boot-pidfile-calls" \
    bash "$WORK/drive-boot-failure.sh" \
    >"$WORK/boot-stdout" 2>"$WORK/boot-stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

run_boot_failure starter-failure
[ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$WORK/boot-teardown")" -eq 1 ] \
  && [ ! -s "$WORK/boot-pidfile-calls" ] \
  && grep -Fq 'level=error msg="upsdrvctl start failed or timed out at boot" rc=9' "$WORK/boot-stderr" \
  && ok 'a bounded starter failure tears down the partial stack before exiting 1' \
  || no 'bounded starter failure cleanup' "rc=$RUN_RC teardown=$(wc -l <"$WORK/boot-teardown") stderr=$(cat "$WORK/boot-stderr")"

run_boot_failure driver-pid-failure
[ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$WORK/boot-teardown")" -eq 1 ] \
  && [ "$(wc -l <"$WORK/boot-pidfile-calls")" -eq 1 ] \
  && ok 'a missing driver PID file tears down the partial stack before exiting 1' \
  || no 'driver PID-file failure cleanup' "rc=$RUN_RC teardown=$(wc -l <"$WORK/boot-teardown") pidfile_calls=$(wc -l <"$WORK/boot-pidfile-calls")"

run_boot_failure upsd-pid-failure
[ "$RUN_RC" -eq 1 ] \
  && [ "$(wc -l <"$WORK/boot-teardown")" -eq 1 ] \
  && [ "$(wc -l <"$WORK/boot-pidfile-calls")" -eq 2 ] \
  && ok 'a missing upsd PID file tears down the partial stack before exiting 1' \
  || no 'upsd PID-file failure cleanup' "rc=$RUN_RC teardown=$(wc -l <"$WORK/boot-teardown") pidfile_calls=$(wc -l <"$WORK/boot-pidfile-calls")"

entry_bound=$(sed -n \
  's/^start_nut_daemon "upsdrvctl" \([0-9][0-9]*\) \/usr\/sbin\/upsdrvctl start$/\1/p' \
  "$REPO_ROOT/entrypoint.sh")
readme_bound=$(sed -n \
  "s/.*keep the driver's worst-case start inside \\([0-9][0-9]*\\)s, the outer bound.*/\\1/p" \
  "$REPO_ROOT/README.md")

if [ "$(printf '%s\n' "$entry_bound" | grep -c .)" -ne 1 ] \
  || [ "$(printf '%s\n' "$readme_bound" | grep -c .)" -ne 1 ]; then
  printf 'harness error: expected one upsdrvctl bound in entrypoint.sh and README.md\n' >&2
  exit 1
fi

if [ "$entry_bound" -eq "$readme_bound" ] && [ "$entry_bound" -gt 75 ]; then
  ok "upsdrvctl's ${entry_bound}s outer bound matches README.md and exceeds NUT's 75s maxstartdelay default"
else
  no 'upsdrvctl startup timeout contract' \
    "entrypoint=${entry_bound}s README=${readme_bound}s; both must agree above 75s"
fi

USB_GROUP_BLOCK=$(extract_range '^if usb_bus_required; then$' '^# Start NUT services with signal handling$' "$WORK/usb-group-block.sh") || exit 1

cat >"$WORK/drive-usb-group.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
usb_bus_required() { [ "$MODE" = usb ]; }
chgrp() { printf '%s\n' "$*" >>"$CHGRP_CALLS"; }
log_value() { printf '%s' "$1"; }
. "$USB_GROUP_BLOCK"
DRIVER
chmod +x "$WORK/drive-usb-group.sh"

run_usb_group() {
  : >"$WORK/chgrp-calls"
  : >"$WORK/usb-group-stderr"
  if env MODE="$1" UPS_DRIVER="$2" UPS_PORT="$3" \
    CHGRP_CALLS="$WORK/chgrp-calls" USB_GROUP_BLOCK="$USB_GROUP_BLOCK" \
    bash "$WORK/drive-usb-group.sh" \
    >"$WORK/usb-group-stdout" 2>"$WORK/usb-group-stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

run_usb_group usb usbhid-ups auto
[ "$RUN_RC" -eq 0 ] \
  && [ "$(cat "$WORK/chgrp-calls")" = '-R nut /dev/bus/usb' ] \
  && grep -Fqx 'level=info msg="chgrp nut:/dev/bus/usb applied (host device nodes)"' "$WORK/usb-group-stderr" \
  && ok 'startup recursively assigns the USB bus to group nut when the transport requires it' \
  || no 'startup USB group assignment' \
    "rc=$RUN_RC calls=$(tr '\n' ' ' <"$WORK/chgrp-calls") stderr=$(cat "$WORK/usb-group-stderr")"

run_usb_group non-usb snmp-ups 192.0.2.1
[ "$RUN_RC" -eq 0 ] \
  && [ ! -s "$WORK/chgrp-calls" ] \
  && grep -Fqx 'level=info msg="non-USB transport; skipping USB bus group setup" driver=snmp-ups port=192.0.2.1' "$WORK/usb-group-stderr" \
  && ok 'startup skips USB bus group setup for a non-USB transport' \
  || no 'non-USB startup group setup' \
    "rc=$RUN_RC calls=$(tr '\n' ' ' <"$WORK/chgrp-calls") stderr=$(cat "$WORK/usb-group-stderr")"

report
