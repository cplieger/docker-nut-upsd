#!/usr/bin/env bash
# The top-level supervisor counts consecutive upsd failures, restarts a
# background worker that died, and preserves upsmon's status through teardown.
# The image health probe delegates its freshness query to comms_fresh, the same
# owner the watchdog calls.
# SC2015: ok/no always return zero. SC2016: the single-quoted range
# delimiter is a literal sed expression and must not expand the parent's rc.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

SUBJECT="$REPO_ROOT/entrypoint.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
BLOCK=$(extract_range '^readonly UPSD_PROBE_INTERVAL=' '^exit "$rc"$' "$WORK/supervisor-block.sh") || exit 1

cat >"$WORK/drive-supervisor.sh" <<'DRIVER'
#!/usr/bin/env bash
set -eu
UPSMON_PID=4242
# Both worker PID slots are non-empty, as they are in a container with the
# watchdog and the poweroff probe enabled: the supervisor reads them, and a
# driver defining only UPSMON_PID would leave the two relaunch branches
# unexercised while still reporting green.
WATCHDOG_PID=5151
DBUS_PROBE_PID=6262
API_PORT=3493
probe_count=0
upsmon_probes=0
worker_probes=0

sleep() { :; }
upsd_probe_host() { printf '127.0.0.1'; }
kill() {
  case "$MODE" in
    threshold) return 0 ;;
    worker-death)
      if [ "${2:-}" = "$UPSMON_PID" ]; then
        # Four liveness probes: two full iterations, then break.
        upsmon_probes=$((upsmon_probes + 1))
        [ "$upsmon_probes" -lt 4 ]
      else
        # One probe per worker fails (both are dead on first inspection), and
        # every later probe succeeds, so a second relaunch would be a defect.
        worker_probes=$((worker_probes + 1))
        printf '%s\n' "${2:-}" >>"$WORKER_PROBE_LOG"
        [ "$worker_probes" -gt 2 ]
      fi
      ;;
    *) return 1 ;;
  esac
}
wait() {
  if [ "$1" = "$UPSMON_PID" ]; then
    case "$MODE" in
      clean) return 0 ;;
      child-failure) return 7 ;;
    esac
  fi
  return 0
}
comms_watchdog() { :; }
dbus_liveness_probe() { :; }
upsd_responsive() {
  [ "$MODE" = threshold ] || return 0
  probe_count=$((probe_count + 1))
  printf '%s\n' "$probe_count" >>"$PROBE_LOG"
  [ "$probe_count" -eq 3 ]
}
teardown_all() {
  printf 'teardown\n' >>"$TEARDOWN_LOG"
}

. "$BLOCK"
DRIVER
chmod +x "$WORK/drive-supervisor.sh"

run_scenario() {
  : >"$WORK/probes"
  : >"$WORK/teardown"
  : >"$WORK/worker-probes"
  : >"$WORK/stderr"
  if env MODE="$1" BLOCK="$BLOCK" PROBE_LOG="$WORK/probes" \
    TEARDOWN_LOG="$WORK/teardown" WORKER_PROBE_LOG="$WORK/worker-probes" \
    bash "$WORK/drive-supervisor.sh" >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

run_scenario threshold
probe_total=$(wc -l <"$WORK/probes" | tr -d ' ')
reset_warnings=$(grep -c 'consecutive_failures=1 threshold=4' "$WORK/stderr" || true)
[ "$RUN_RC" -eq 1 ] && [ "$probe_total" -eq 7 ] && [ "$reset_warnings" -eq 2 ] \
  && grep -q 'consecutive_failures=4 probe_interval=15s' "$WORK/stderr" \
  && [ "$(wc -l <"$WORK/teardown" | tr -d ' ')" -eq 1 ] \
  && ok 'a successful probe resets the count and the fourth later consecutive failure tears down and exits 1' \
  || no 'consecutive upsd failure state machine' "rc=$RUN_RC probes=$probe_total reset_warnings=$reset_warnings stderr=$(cat "$WORK/stderr")"

# The fatal diagnosis names the address it probed, which is the field that
# separates "upsd is down" from "upsd serves a different LISTEN address".
grep -q 'probe=127.0.0.1:3493' "$WORK/stderr" \
  && ok 'the give-up line names the probe target, not just the failure count' \
  || no 'probe target field' "stderr: $(cat "$WORK/stderr")"

[ "$(grep -c 'starting a fresh one' "$WORK/stderr" || true)" -eq 0 ] \
  && ok 'a live worker is left alone (the relaunch branch tests death, not presence)' \
  || no 'spurious worker relaunch' "stderr: $(cat "$WORK/stderr")"

run_scenario worker-death
relaunched_watchdog=$(grep -c 'msg="comms watchdog exited' "$WORK/stderr" || true)
relaunched_probe=$(grep -c 'msg="D-Bus poweroff-path probe exited' "$WORK/stderr" || true)
[ "$RUN_RC" -eq 0 ] \
  && [ "$relaunched_watchdog" -eq 1 ] \
  && [ "$relaunched_probe" -eq 1 ] \
  && [ "$(wc -l <"$WORK/teardown" | tr -d ' ')" -eq 1 ] \
  && ok 'a background worker that exited is relaunched exactly once, and teardown still runs once' \
  || no 'background worker supervision' "rc=$RUN_RC watchdog=$relaunched_watchdog probe=$relaunched_probe teardown=$(wc -l <"$WORK/teardown") stderr=$(cat "$WORK/stderr")"

run_scenario child-failure
[ "$RUN_RC" -eq 7 ] \
  && [ "$(wc -l <"$WORK/teardown" | tr -d ' ')" -eq 1 ] \
  && ok 'a nonzero upsmon status survives teardown' \
  || no 'nonzero upsmon status propagation' "rc=$RUN_RC stderr=$(cat "$WORK/stderr")"

run_scenario clean
[ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$WORK/teardown" | tr -d ' ')" -eq 1 ] \
  && ok 'a zero upsmon status remains zero after teardown' \
  || no 'clean upsmon status propagation' "rc=$RUN_RC stderr=$(cat "$WORK/stderr")"

run_scenario child-failure
child_exit_record=$(grep -F 'msg="upsmon exited unexpectedly"' "$WORK/stderr" || :)
run_scenario clean
fsd_exit_record=$(grep -F 'msg="upsmon parent exited after running SHUTDOWNCMD' "$WORK/stderr" || :)
if [ "$child_exit_record" = 'level=error msg="upsmon exited unexpectedly" rc=7' ] \
  && [ "$fsd_exit_record" = 'level=warn msg="upsmon parent exited after running SHUTDOWNCMD; a forced shutdown (FSD) was executed" rc=0' ]; then
  ok 'upsmon exit records distinguish an executed FSD from an unexpected failure'
else
  no 'upsmon exit record classification' \
    "child=[$child_exit_record] fsd=[$fsd_exit_record]"
fi

STOP_BG=$(extract_function stop_bg_pid "$WORK/stop_bg_pid.sh") || exit 1
TEARDOWN=$(extract_function teardown_all "$WORK/teardown_all.sh") || exit 1

cat >"$WORK/drive-teardown.sh" <<'DRIVER'
#!/usr/bin/env bash
set -eu
WATCHDOG_PID=5151
DBUS_PROBE_PID=6262

kill() { printf 'kill %s\n' "$1" >>"$EVENTS"; }
wait() { printf 'wait %s\n' "$1" >>"$EVENTS"; }
stop_services() { printf 'stop-services\n' >>"$EVENTS"; }

. "$STOP_BG"
. "$TEARDOWN"
teardown_all
DRIVER
chmod +x "$WORK/drive-teardown.sh"

: >"$WORK/events"
: >"$WORK/stderr"
if env STOP_BG="$STOP_BG" TEARDOWN="$TEARDOWN" EVENTS="$WORK/events" \
  bash "$WORK/drive-teardown.sh" >"$WORK/stdout" 2>"$WORK/stderr"; then
  RUN_RC=0
else
  RUN_RC=$?
fi

cat >"$WORK/expected-teardown-events" <<'EXPECTED'
kill 5151
wait 5151
kill 6262
wait 6262
stop-services
EXPECTED

[ "$RUN_RC" -eq 0 ] \
  && cmp -s "$WORK/expected-teardown-events" "$WORK/events" \
  && ok 'teardown_all signals and reaps workers before services' \
  || no 'teardown_all worker lifecycle ordering' "rc=$RUN_RC events=$(tr '\n' ' ' <"$WORK/events") stderr=$(cat "$WORK/stderr")"

cat >"$WORK/drive-teardown-budget.sh" <<'DRIVER'
#!/usr/bin/env bash
set -eu
WATCHDOG_PID=5151
DBUS_PROBE_PID=6262
elapsed=0

advance_clock() {
  elapsed=$(awk -v current="$elapsed" -v delta="$1" 'BEGIN { print current + delta }')
}
kill() { return 0; }
wait() { return 0; }
sleep() { advance_clock "$1"; }
stop_services() { advance_clock 9; }

. "$STOP_BG"
. "$TEARDOWN"
teardown_all
printf '%s\n' "$elapsed"
DRIVER
chmod +x "$WORK/drive-teardown-budget.sh"

if teardown_elapsed=$(env STOP_BG="$STOP_BG" TEARDOWN="$TEARDOWN" \
  bash "$WORK/drive-teardown-budget.sh" 2>"$WORK/teardown-budget-stderr") \
  && awk -v elapsed="$teardown_elapsed" 'BEGIN { exit !(elapsed < 10) }'; then
  ok 'complete teardown stays inside Docker stop grace'
else
  no 'complete teardown stop budget' \
    "elapsed=${teardown_elapsed:-unknown}s stderr=$(cat "$WORK/teardown-budget-stderr")"
fi

DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"
healthcheck=$(awk '
  /^FROM runtime AS final$/ { final = 1; next }
  final && /^HEALTHCHECK / { in_healthcheck = 1 }
  final && in_healthcheck && /^[A-Z][A-Z0-9_]*[[:space:]]/ && $1 != "HEALTHCHECK" { exit }
  final && in_healthcheck { print }
' "$DOCKERFILE")
if [ -z "$healthcheck" ]; then
  printf 'harness error: final image stage has no HEALTHCHECK in %s\n' "$DOCKERFILE" >&2
  exit 1
fi

health_start_period=$(printf '%s\n' "$healthcheck" | sed -n \
  's/^HEALTHCHECK .*--start-period=\([0-9][0-9]*\)s.*/\1/p')
daemon_start_budget=$(awk '
  /^start_nut_daemon "(upsdrvctl|upsd)" [0-9][0-9]* / {
    total += $3
    count++
  }
  END { if (count == 2) print total }
' "$SUBJECT")
pidfile_poll_interval=$(sed -n \
  's/^readonly PIDFILE_POLL_INTERVAL="\([0-9][0-9.]*\)"$/\1/p' \
  "$REPO_ROOT/lifecycle.sh")
pidfile_poll_max=$(sed -n \
  's/^readonly PIDFILE_POLL_MAX=\([0-9][0-9]*\).*/\1/p' \
  "$REPO_ROOT/lifecycle.sh")

if [ -z "$health_start_period" ] \
  || [ -z "$daemon_start_budget" ] \
  || [ -z "$pidfile_poll_interval" ] \
  || [ -z "$pidfile_poll_max" ]; then
  printf 'harness error: could not derive health or startup timing budgets\n' >&2
  exit 1
fi

required_start_period=$(awk \
  -v daemon="$daemon_start_budget" \
  -v interval="$pidfile_poll_interval" \
  -v polls="$pidfile_poll_max" \
  'BEGIN { print daemon + (2 * interval * polls) }')
if awk -v actual="$health_start_period" -v required="$required_start_period" \
  'BEGIN { exit !(actual >= required) }'; then
  ok "healthcheck start period (${health_start_period}s) covers nominal startup budget (${required_start_period}s)"
else
  no 'healthcheck nominal startup grace' \
    "start-period=${health_start_period}s nominal-required=${required_start_period}s"
fi

healthcheck_command=$(printf '%s\n' "$healthcheck" | awk '
  /^[[:space:]]*CMD[[:space:]]/ {
    sub(/^[[:space:]]*CMD[[:space:]]+/, "")
    in_command = 1
  }
  in_command { print }
')
if [ -z "$healthcheck_command" ]; then
  printf 'harness error: final-stage HEALTHCHECK has no CMD program\n' >&2
  exit 1
fi

cat >"$WORK/drive-healthcheck-command.sh" <<'DRIVER'
#!/bin/sh
set -eu
timeout() {
  [ "$1" = 3 ] || return 2
  shift
  "$@"
}
upsc() {
  printf '%s\n' "$*" >"$PROBE_LOG"
  [ "$#" -eq 2 ] \
    && [ "$1" = 'ups@127.0.0.1:3493' ] \
    && [ "$2" = 'ups.status' ]
}
DRIVER
printf '%s\n' "$healthcheck_command" \
  | sed "s|/usr/local/bin/lifecycle.sh|$REPO_ROOT/lifecycle.sh|" \
  >>"$WORK/drive-healthcheck-command.sh"

HEALTHCHECK_SHELL=$(command -v busybox) || {
  printf 'harness error: busybox is required to execute the image healthcheck dialect\n' >&2
  exit 1
}
: >"$WORK/healthcheck-probe"
if env -u UPS_NAME -u API_ADDRESS -u API_PORT \
  PROBE_LOG="$WORK/healthcheck-probe" \
  "$HEALTHCHECK_SHELL" ash "$WORK/drive-healthcheck-command.sh" \
  >"$WORK/healthcheck-stdout" 2>"$WORK/healthcheck-stderr"; then
  RUN_RC=0
else
  RUN_RC=$?
fi

[ "$RUN_RC" -eq 0 ] \
  && [ "$(cat "$WORK/healthcheck-probe")" = 'ups@127.0.0.1:3493 ups.status' ] \
  && ok 'the final image healthcheck command parses and executes its complete protocol probe' \
  || no 'final image healthcheck command execution' \
    "rc=$RUN_RC probe=$(cat "$WORK/healthcheck-probe") stderr=$(cat "$WORK/healthcheck-stderr")"
printf '%s\n' "$healthcheck" | grep -Eq '^[[:space:]]*comms_fresh$' \
  && ok 'the final image healthcheck delegates the freshness query to comms_fresh' \
  || no 'healthcheck freshness owner' "final-stage HEALTHCHECK: $healthcheck"

VALIDATE=${VALIDATE:-$REPO_ROOT/validate.sh}
canonicalize=$(awk '
  /^canonicalize_validated_values\(\)/ { in_function = 1 }
  in_function { print }
  in_function && /^}/ { exit }
' "$VALIDATE")
if [ -z "$canonicalize" ]; then
  printf 'harness error: canonicalize_validated_values not found in %s\n' "$VALIDATE" >&2
  exit 1
fi

entry_canonical_line=$(awk '
  /^[[:space:]]*canonicalize_validated_values[[:space:]]*$/ { print NR; exit }
' "$SUBJECT")
probe_vars=$(printf '%s\n' "$healthcheck" | awk '
  $1 ~ /^[A-Z][A-Z0-9_]*=\$\(printf$/ {
    var = $1
    sub(/=.*/, "", var)
    print var
  }
' | sort -u)
if [ -z "$probe_vars" ]; then
  printf 'harness error: final-stage HEALTHCHECK has no canonicalized endpoint inputs\n' >&2
  exit 1
fi

parity_failures=""
while IFS= read -r var; do
  entry_default_record=$(awk -v var="$var" '
    index($0, ": \"${" var ":=") {
      value = $0
      sub(/^.*:=/, "", value)
      sub(/}.*/, "", value)
      print NR ":" value
      exit
    }
  ' "$SUBJECT")
  probe_default=$(printf '%s\n' "$healthcheck" | awk -v var="$var" '
    index($0, ": \"${" var ":=") {
      value = $0
      sub(/^.*:=/, "", value)
      sub(/}.*/, "", value)
      print value
      exit
    }
  ')
  source_canonical=$(printf '%s\n' "$canonicalize" | awk -v var="$var" '
    index($0, var "=$(printf '\''%s'\'' \"${" var ":-}\")") { found = 1 }
    END { print found + 0 }
  ')
  # The probe canonicalizes and defaults on ONE physical line, so the order
  # is a character-offset comparison over the whole instruction, not a line
  # number.
  probe_order=$(printf '%s\n' "$healthcheck" | awk -v var="$var" '
    { text = text $0 "\n" }
    END {
      canon = index(text, var "=$(printf '\''%s'\'' \"${" var ":-}\")")
      default_at = index(text, ": \"${" var ":=")
      print (canon > 0 && default_at > canon) ? 1 : 0
    }
  ')

  entry_default_line=${entry_default_record%%:*}
  entry_default=${entry_default_record#*:}
  if [ -n "$entry_canonical_line" ] \
    && [ -n "$entry_default_record" ] \
    && [ -n "$probe_default" ] \
    && [ "$source_canonical" -eq 1 ] \
    && [ "$probe_order" -eq 1 ] \
    && [ "$entry_default" = "$probe_default" ] \
    && [ "$entry_canonical_line" -lt "$entry_default_line" ]; then
    continue
  fi
  parity_failures="${parity_failures}${parity_failures:+, }$var"
done <<<"$probe_vars"

[ -z "$parity_failures" ] \
  && ok 'the healthcheck canonicalizes and defaults its endpoint inputs like the entrypoint' \
  || no 'healthcheck and entrypoint input parity' "mismatched variables: $parity_failures"

WATCHDOG_START_BLOCK=$(extract_range '^if \[ "\$COMMS_WATCHDOG" = "true" \] && \[ "\$COMMS_CHECK_INTERVAL" -ge 1 \]; then$' '^fi$' "$WORK/watchdog-start-block.sh") || exit 1

cat >"$WORK/drive-watchdog-start.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
COMMS_WATCHDOG=true
COMMS_RECOVERY_TIMEOUT=90
WATCHDOG_PID=""
comms_watchdog() { printf 'started\n' >>"$WATCHDOG_CALLS"; }
. "$WATCHDOG_START_BLOCK"
if [ -n "$WATCHDOG_PID" ]; then
  wait "$WATCHDOG_PID"
fi
printf '%s' "$WATCHDOG_PID" >"$WATCHDOG_PID_FILE"
DRIVER
chmod +x "$WORK/drive-watchdog-start.sh"

run_watchdog_start() {
  : >"$WORK/watchdog-calls"
  : >"$WORK/watchdog-stderr"
  env COMMS_CHECK_INTERVAL="$1" WATCHDOG_START_BLOCK="$WATCHDOG_START_BLOCK" \
    WATCHDOG_CALLS="$WORK/watchdog-calls" WATCHDOG_PID_FILE="$WORK/watchdog-pid" \
    bash "$WORK/drive-watchdog-start.sh" >"$WORK/watchdog-stdout" 2>"$WORK/watchdog-stderr"
}

run_watchdog_start 0
[ ! -s "$WORK/watchdog-calls" ] && [ ! -s "$WORK/watchdog-pid" ] \
  && grep -Fq 'level=info msg="comms watchdog disabled" watchdog=true interval=0s' "$WORK/watchdog-stderr" \
  && ok 'a zero comms interval leaves the watchdog disabled and names both deciding values' \
  || no 'zero comms interval' "calls=$(cat "$WORK/watchdog-calls") pid=$(cat "$WORK/watchdog-pid") stderr=$(cat "$WORK/watchdog-stderr")"

run_watchdog_start 1
[ "$(wc -l <"$WORK/watchdog-calls")" -eq 1 ] && [ -s "$WORK/watchdog-pid" ] \
  && grep -Fq 'level=info msg="starting comms watchdog" interval=1s' "$WORK/watchdog-stderr" \
  && ok 'the minimum positive comms interval starts exactly one watchdog worker' \
  || no 'minimum enabled comms interval' "calls=$(cat "$WORK/watchdog-calls") pid=$(cat "$WORK/watchdog-pid") stderr=$(cat "$WORK/watchdog-stderr")"

BUSYBOX=$(command -v busybox) || {
  printf 'harness error: busybox is required to test the image shell dialect\n' >&2
  exit 1
}
SHUTDOWN=$(extract_function graceful_shutdown "$WORK/graceful_shutdown.sh") || exit 1

cat >"$WORK/drive-teardown-signal.sh" <<'DRIVER'
#!/bin/sh
set -eu
WATCHDOG_PID=5151
DBUS_PROBE_PID=6262

kill() { printf 'kill %s\n' "$1" >>"$EVENTS"; }
wait() {
  printf 'wait %s\n' "$1" >>"$EVENTS"
  if [ ! -e "$WAIT_ENTERED" ]; then
    # Hold the first worker's reap until the parent has sent the second signal,
    # so the assertion can never pass because the signal arrived too late.
    # Self-bounded at 5s: a missing handshake must fail this file, not hang it.
    : >"$WAIT_ENTERED"
    _held=0
    while [ ! -e "$SECOND_SENT" ] && [ "$_held" -lt 100 ]; do
      sleep 0.05
      _held=$((_held + 1))
    done
  fi
}
stop_services() { printf 'stop-services\n' >>"$EVENTS"; }

. "$STOP_BG"
. "$TEARDOWN"
. "$SHUTDOWN"
trap graceful_shutdown TERM INT QUIT HUP
: >"$READY"
# A short foreground sleep is required because BusyBox ash runs a pending trap
# only after the current foreground command returns, and wait is stubbed here.
while :; do
  sleep 0.05
done
DRIVER
chmod +x "$WORK/drive-teardown-signal.sh"

: >"$WORK/events"
: >"$WORK/stderr"
env STOP_BG="$STOP_BG" TEARDOWN="$TEARDOWN" SHUTDOWN="$SHUTDOWN" \
  EVENTS="$WORK/events" WAIT_ENTERED="$WORK/wait-entered" \
  SECOND_SENT="$WORK/second-sent" READY="$WORK/ready" \
  "$BUSYBOX" ash "$WORK/drive-teardown-signal.sh" \
  >"$WORK/stdout" 2>"$WORK/stderr" &
driver_pid=$!

ready=0
for _ in $(seq 1 80); do
  if [ -e "$WORK/ready" ]; then
    ready=1
    break
  fi
  sleep 0.025
done
if [ "$ready" -eq 1 ]; then
  kill -TERM "$driver_pid"
fi

entered=0
for _ in $(seq 1 80); do
  if [ -e "$WORK/wait-entered" ]; then
    entered=1
    break
  fi
  sleep 0.025
done
if [ "$entered" -eq 1 ]; then
  kill -TERM "$driver_pid"
  : >"$WORK/second-sent"
fi

finished=0
for _ in $(seq 1 80); do
  if ! kill -0 "$driver_pid" 2>/dev/null; then
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

cat >"$WORK/expected-events" <<'EXPECTED'
kill 5151
wait 5151
kill 6262
wait 6262
stop-services
EXPECTED

shutdown_records=$(grep -cF 'level=info msg="received shutdown signal"' \
  "$WORK/stderr" || true)
if [ "$ready" -eq 1 ] && [ "$entered" -eq 1 ] \
  && [ "$finished" -eq 1 ] && [ "$RUN_RC" -eq 0 ] \
  && [ "$shutdown_records" -eq 1 ] \
  && cmp -s "$WORK/expected-events" "$WORK/events"; then
  ok 'a second TERM during teardown is ignored and every stop action runs once'
else
  no 'teardown signal re-entry guard' \
    "ready=$ready entered=$entered finished=$finished rc=$RUN_RC records=$shutdown_records events=$(tr '\n' ' ' <"$WORK/events") stderr=$(tr '\n' ' ' <"$WORK/stderr")"
fi

cat >"$WORK/drive-nonzero-sleep-wait.sh" <<'DRIVER'
#!/bin/sh
set -eu
UPSMON_PID=4242
WATCHDOG_PID=""
DBUS_PROBE_PID=""
API_PORT=3493

sleep() { :; }
kill() {
  [ "$1" = -0 ] && [ "$2" = "$UPSMON_PID" ] || return 1
  _calls=$(wc -l <"$LIVENESS_CALLS")
  printf '%s\n' "$2" >>"$LIVENESS_CALLS"
  # The loop probes upsmon TWICE per iteration (the while head, then the
  # post-wait `|| break`), so the fifth probe is what ends two full iterations.
  [ "$_calls" -lt 4 ]
}
wait() {
  if [ "$1" = "$UPSMON_PID" ]; then
    return 0
  fi
  printf '%s\n' "$1" >>"$SLEEP_WAITS"
  return 143
}
upsd_responsive() {
  printf 'probe\n' >>"$PROBE_CALLS"
  return 0
}
upsd_probe_host() { printf '127.0.0.1'; }
teardown_all() { printf 'teardown\n' >>"$TEARDOWN_CALLS"; }

. "$BLOCK"
DRIVER
chmod +x "$WORK/drive-nonzero-sleep-wait.sh"

: >"$WORK/nonzero-liveness"
: >"$WORK/nonzero-sleep-waits"
: >"$WORK/nonzero-probes"
: >"$WORK/nonzero-teardown"
: >"$WORK/nonzero-stderr"
if env BLOCK="$BLOCK" LIVENESS_CALLS="$WORK/nonzero-liveness" \
  SLEEP_WAITS="$WORK/nonzero-sleep-waits" PROBE_CALLS="$WORK/nonzero-probes" \
  TEARDOWN_CALLS="$WORK/nonzero-teardown" \
  "$BUSYBOX" ash "$WORK/drive-nonzero-sleep-wait.sh" \
  >"$WORK/nonzero-stdout" 2>"$WORK/nonzero-stderr"; then
  RUN_RC=0
else
  RUN_RC=$?
fi

[ "$RUN_RC" -eq 0 ] \
  && [ "$(wc -l <"$WORK/nonzero-sleep-waits")" -eq 2 ] \
  && [ "$(wc -l <"$WORK/nonzero-probes")" -eq 2 ] \
  && [ "$(wc -l <"$WORK/nonzero-teardown")" -eq 1 ] \
  && ok 'nonzero background-sleep waits do not let errexit bypass supervision or teardown' \
  || no 'nonzero supervision sleep wait' \
    "rc=$RUN_RC waits=$(wc -l <"$WORK/nonzero-sleep-waits") probes=$(wc -l <"$WORK/nonzero-probes") teardown=$(wc -l <"$WORK/nonzero-teardown") stderr=$(cat "$WORK/nonzero-stderr")"

report
