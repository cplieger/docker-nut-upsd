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

report
