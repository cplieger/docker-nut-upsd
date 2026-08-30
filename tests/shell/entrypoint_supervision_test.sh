#!/usr/bin/env bash
# The top-level supervisor counts consecutive upsd failures, restarts a
# background worker that died, and preserves upsmon's status through teardown.
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

run_scenario worker-death
relaunched_watchdog=$(grep -c 'msg="comms watchdog exited' "$WORK/stderr" || true)
relaunched_probe=$(grep -c 'msg="D-Bus poweroff-path probe exited' "$WORK/stderr" || true)
[ "$RUN_RC" -eq 0 ] \
  && [ "$relaunched_watchdog" -eq 1 ] \
  && [ "$relaunched_probe" -eq 1 ] \
  && [ "$(wc -l <"$WORK/teardown" | tr -d ' ')" -eq 1 ] \
  && ok 'a background worker that exited is relaunched exactly once, and teardown still runs once' \
  || no 'background worker supervision' "rc=$RUN_RC watchdog=$relaunched_watchdog probe=$relaunched_probe teardown=$(wc -l <"$WORK/teardown") stderr=$(cat "$WORK/stderr")"

# A live worker must NOT be relaunched: the threshold scenario keeps every
# kill -0 successful, so a branch testing the wrong direction shows up here.
run_scenario threshold
[ "$(grep -c 'starting a fresh one' "$WORK/stderr" || true)" -eq 0 ] \
  && ok 'a live worker is left alone (the relaunch branch tests death, not presence)' \
  || no 'spurious worker relaunch' "stderr: $(cat "$WORK/stderr")"

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

report
