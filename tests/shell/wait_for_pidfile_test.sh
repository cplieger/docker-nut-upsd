#!/usr/bin/env bash
# wait_for_pidfile(): the startup trust gate. The entrypoint waits on it for each
# NUT daemon and only proceeds once it returns 0, so what it ACCEPTS as
# "daemon is up" decides whether the container reports itself started.
#
# The pidfile it reads lives in the nut-writable /var/run/nut, so the gate is a
# trust boundary as much as a readiness check: accepting a planted or garbage PID
# means boot continues past a driver/upsd that never started, with upsd.users and
# upsmon.conf already installed and no working driver behind them. Its refusal
# paths are reached by nothing else -- tests/smoke.sh covers read_pidfile and
# pid_matches_binary in isolation, never this gate.
#
# As in kill_stale_driver_test.sh, pid_matches_binary is stubbed to SUCCEED in the
# content-refusal cases so the identity requirement cannot be what refuses them,
# and `kill -0` answers from a controlled live set rather than the real builtin.
# PIDFILE_POLL_MAX/PIDFILE_POLL_INTERVAL are file-scope readonly in lifecycle.sh
# but plain variables once the function is extracted, so the 5s production wait
# becomes 3 x 0.01s here; they are cadence knobs, not the guards under test.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - PIDFILE_POLL_MAX/PIDFILE_POLL_INTERVAL are the INPUTS to lifecycle.sh
#     code that is extracted and sourced at RUNTIME, so shellcheck cannot see the
#     reads.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-lifecycle.sh bash tests/shell/wait_for_pidfile_test.sh
SUBJECT="$REPO_ROOT/lifecycle.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
load_function wait_for_pidfile

PIDFILE_POLL_MAX=3
PIDFILE_POLL_INTERVAL=0.01
DRIVER_BINARY=/usr/lib/nut/usbhid-ups
PIDFILE=/var/run/nut/usbhid-ups-ups.pid
CONTENT=""
LIVE_PIDS=""
IDENTITY_OK=1
ERR="$WORK/err.log"

# The privileged seam (BusyBox su to the nut user): replaced by the content the
# test plants, which is what the gate's case arms actually inspect.
read_pidfile() {
  printf '%s' "$CONTENT"
}

pid_matches_binary() {
  [ "$IDENTITY_OK" = 1 ]
}

kill() {
  if [ "$1" = "-0" ]; then
    case " $LIVE_PIDS " in
      *" $2 "*) return 0 ;;
    esac
    return 1
  fi
  return 0
}

# gate <pidfile-content> <live-pids> <identity-ok>: returns the gate's own status.
gate() {
  CONTENT="$1"
  LIVE_PIDS="$2"
  IDENTITY_OK="$3"
  wait_for_pidfile "usbhid-ups driver" "$PIDFILE" "$DRIVER_BINARY" 2>"$ERR"
}

timed_out() {
  grep -q 'did not confirm a live PID for the expected binary in time' "$ERR"
}

# --- 1. the positive control, first: a real daemon IS accepted --------------------
#
# Without it, every refusal below would also pass against a gate that rejects
# everything (and a gate that never returns 0 would hang the boot, not open it).
gate '4242' '4242' 1 \
  && ok 'a live PID verified as the expected daemon binary opens the gate' \
  || no 'valid pidfile accepted' "the gate refused a live, verified PID: $(head -c 200 "$ERR")"

# --- 2. an all-zero PID is never accepted as daemon-ready ------------------------
#
# "0" is numeric, so the non-numeric arm cannot fire; only the all-zero arm keeps
# `kill -0 0` (which probes the CALLER's process group and would succeed) from
# reading as a live daemon. Declared live and identity-verified here, so nothing
# downstream can be what refuses it.
! gate '0' '0 4242' 1 && timed_out \
  && ok 'pidfile PID "0" never satisfies the gate (kill -0 0 probes the caller own group)' \
  || no 'all-zero PID "0"' 'the startup gate accepted an all-zero PID as daemon-ready'

! gate '000' '000 4242' 1 && timed_out \
  && ok 'multi-digit all-zero pidfile PID "000" never satisfies the gate' \
  || no 'all-zero PID "000"' 'the startup gate accepted "000" as daemon-ready'

# --- 3. non-numeric content never opens the gate ---------------------------------
#
# "-1" is the bait that isolates the non-numeric arm, and it needs BOTH stubs set
# against it: as root `kill -0 -1` genuinely succeeds (signal 0 to every process
# this caller may signal), so the liveness probe cannot refuse it, and identity is
# stubbed to succeed so the /proc check cannot either. With the arm deleted, "-1"
# reaches the accept path and the gate opens on a pidfile the nut user planted.
! gate '-1' '-1 4242' 1 && timed_out \
  && ok 'pidfile PID "-1" is refused by the non-numeric arm even when liveness and identity both pass' \
  || no 'non-numeric PID "-1"' 'the startup gate accepted "-1" as daemon-ready'

! gate '' '4242' 1 && timed_out \
  && ok 'an empty pidfile (absent, or a partial write) times out instead of opening the gate' \
  || no 'empty pidfile' 'the startup gate accepted an empty pidfile'

# --- 4. identity is REQUIRED, not advisory ---------------------------------------
#
# A numerically valid, LIVE PID planted by the nut user (upsd, upsmon, PID 1, or
# any unrelated process) must not satisfy the gate. This is the one case where
# identity is the guard under test, so it is the only one where the stub fails.
! gate '4242' '4242' 0 && timed_out \
  && ok 'a live PID that is NOT the expected binary is refused (planted-PID gate)' \
  || no 'unverified live PID' 'the startup gate accepted a live PID of the wrong binary'

# --- 5. liveness is required too -------------------------------------------------
#
# A stale pidfile from a crashed daemon holds a numeric, non-zero, plausible PID.
# This fixture stubs identity to succeed, though the shipped pid_matches_binary
# cannot succeed for a dead PID because both probes require its /proc entry.
! gate '4242' '' 1 && timed_out \
  && ok 'a numeric PID that is not alive is refused (stale pidfile from a crashed daemon)' \
  || no 'dead PID' 'the startup gate accepted a PID that no longer exists'

# --- 6. the expected-binary argument is mandatory --------------------------------
#
# The gate cannot verify identity without it, so a call site that forgot it must
# abort rather than degrade to "any live PID will do".
if (wait_for_pidfile 'usbhid-ups driver' "$PIDFILE") 2>"$ERR"; then
  no 'missing expected-binary argument' 'wait_for_pidfile ran without its third argument'
else
  grep -q 'requires an expected binary path' "$ERR" \
    && ok 'omitting the expected-binary argument aborts with its own message' \
    || no 'missing expected-binary argument' "aborted without the :? message: $(command head -c 200 "$ERR")"
fi

# Reload the real identity function after the gate cases that deliberately stub it.
load_function pid_matches_binary
PROC_PID=4242
PROC_COMM=""
PROC_HEAD_RC=0
PROC_CALLS="$WORK/proc-calls"
PROC_EXPECTED_CALLS='readlink=-f /proc/4242/exe
head=-c 64 /proc/4242/comm'

# shellcheck disable=SC2329  # invoked by the extracted pid_matches_binary
readlink() {
  printf 'readlink=%s\n' "$*" >>"$PROC_CALLS"
  return 1
}

# shellcheck disable=SC2329  # invoked by the extracted pid_matches_binary
head() {
  printf 'head=%s\n' "$*" >>"$PROC_CALLS"
  printf '%s' "$PROC_COMM"
  return "$PROC_HEAD_RC"
}

run_comm_match() {
  : >"$PROC_CALLS"
  if pid_matches_binary "$PROC_PID" "$1"; then
    PROC_STATUS=0
  else
    PROC_STATUS=$?
  fi
  if [ "$(cat "$PROC_CALLS")" != "$PROC_EXPECTED_CALLS" ]; then
    printf 'harness error: unexpected proc calls: %s\n' "$(tr '\n' '|' <"$PROC_CALLS")" >&2
    exit 1
  fi
}

PROC_COMM=usbhid-ups
PROC_HEAD_RC=0
run_comm_match /usr/lib/nut/usbhid-ups
[ "$PROC_STATUS" -eq 0 ] \
  && ok 'the comm fallback accepts the expected daemon basename' \
  || no 'matching comm' "status=$PROC_STATUS"

PROC_COMM=123456789012345
run_comm_match /usr/lib/nut/1234567890123456
[ "$PROC_STATUS" -eq 0 ] \
  && ok 'the comm fallback compares a long basename through its 15-byte comm form' \
  || no '15-byte comm truncation' "status=$PROC_STATUS"

PROC_COMM=upsd
run_comm_match /usr/lib/nut/usbhid-ups
[ "$PROC_STATUS" -ne 0 ] \
  && ok 'the comm fallback refuses a different process name' \
  || no 'mismatched comm' 'a different process name was accepted'

PROC_COMM=""
run_comm_match /usr/lib/nut/usbhid-ups
[ "$PROC_STATUS" -ne 0 ] \
  && ok 'the comm fallback refuses an empty process name' \
  || no 'empty comm' 'an empty process name was accepted'

PROC_COMM=usbhid-ups
PROC_HEAD_RC=1
run_comm_match /usr/lib/nut/usbhid-ups
[ "$PROC_STATUS" -ne 0 ] \
  && ok 'the comm fallback refuses an unreadable comm file' \
  || no 'unreadable comm' 'a failed comm read was accepted'

# --- 7. TERM reaches PID 1's trap while the gate is polling ----------------------
#
# The poll's sleep is backgrounded and `wait`ed on (lifecycle.sh:111-112) so a
# SIGTERM during the boot gate reaches the trap immediately; a foreground sleep
# defers the pending trap until it returns. Nothing else in the suite or in
# tests/smoke.sh observes that, so deleting the `&` and the `wait` is invisible.
#
# Every signal here goes through `command kill`, as the earlier cases do with
# `command head`: the file-scope kill stub answers `-0` from LIVE_PIDS and
# swallows every other signal, so the driver would never be signalled and would
# be declared finished before it was.
BUSYBOX=$(command -v busybox) || {
  printf 'harness error: busybox is required to test PID 1 signal timing\n' >&2
  exit 1
}

# The stub sleeps 3s rather than "$1": the assertion must not depend on the
# shipped interval, because a 0.1s foreground sleep also returns inside any
# bound this harness can measure, and the case would then pin nothing.
cat >"$WORK/drive-pidfile-signal.sh" <<'DRIVER'
#!/bin/sh
set -eu
. "$SUBJECT"
read_pidfile() { :; }
sleep() {
  : >"$READY"
  "$BUSYBOX" sleep 3
}
trap 'exit 0' TERM
wait_for_pidfile "signal latency probe" /nonexistent /bin/false >/dev/null 2>&1
DRIVER

env SUBJECT="$SUBJECT" READY="$WORK/pidfile-signal-ready" BUSYBOX="$BUSYBOX" \
  "$BUSYBOX" ash "$WORK/drive-pidfile-signal.sh" \
  >"$WORK/pidfile-signal-stdout" 2>"$WORK/pidfile-signal-stderr" &
signal_driver_pid=$!

ready=0
for _ in $(seq 1 40); do
  if [ -e "$WORK/pidfile-signal-ready" ]; then
    ready=1
    break
  fi
  sleep 0.05
done
if [ "$ready" -eq 1 ]; then
  command kill -TERM "$signal_driver_pid"
fi

# Half a second, then SIGKILL: a deferred handler must fail this case, never hang
# the file. 137 is not a status the green path can produce.
finished=0
for _ in $(seq 1 10); do
  if ! command kill -0 "$signal_driver_pid" 2>/dev/null; then
    finished=1
    break
  fi
  sleep 0.05
done
if [ "$finished" -eq 1 ]; then
  if wait "$signal_driver_pid"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
else
  command kill -KILL "$signal_driver_pid" 2>/dev/null || true
  wait "$signal_driver_pid" 2>/dev/null || true
  RUN_RC=137
fi

[ "$ready" -eq 1 ] && [ "$finished" -eq 1 ] && [ "$RUN_RC" -eq 0 ] \
  && ok 'TERM reaches the trap while the PID-file gate is polling' \
  || no 'PID-file poll signal latency' \
    "ready=$ready finished=$finished rc=$RUN_RC stderr=$(cat "$WORK/pidfile-signal-stderr")"

report
