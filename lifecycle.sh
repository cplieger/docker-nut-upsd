#!/bin/sh
# lifecycle.sh — NUT service lifecycle utility functions.
# Sourced, never executed. PID 1 sources this before configuration defaults;
# the Dockerfile HEALTHCHECK sources it ALONE and calls comms_fresh. The top
# level must only DEFINE (nothing runs at source time, no reliance on the
# caller's `set -eu`), and nothing reachable from comms_fresh may name a helper
# defined in another file - log_value and usb_bus_required are both such helpers.

readonly PIDFILE_POLL_INTERVAL="0.1"
readonly PIDFILE_POLL_MAX=50 # nominal wait = POLL_MAX x POLL_INTERVAL = 5s
# Keep this below the outer timeout 5 at dbus_poweroff_path_ok: past it that
# bound kills dbus-send first, and detail= carries the shell's bare signal-death
# line instead of dbus-send's own cause.
readonly DBUS_PROBE_REPLY_TIMEOUT_MS=3000
# 3 stop_services commands x 3s = 9s worst case, inside Docker's default 10s
# stop budget before SIGKILL.
readonly STOP_CMD_TIMEOUT=3
# Root-only dir so a nut-user process cannot plant the flag and latch
# restart_ups_driver's stand-down; entrypoint.sh clears it at boot.
readonly POWERDOWNFLAG_FILE=/var/run/nut-secrets/killpower

# Shared temp-file capture lifecycle for bounded subprocess output. Capture via
# a regular file, never $(): timeout signals only the program it exec'd, so a
# descendant that program leaves running (upsdrvctl's driver) keeps the pipe's
# write end open past the bound and blocks the reader. The prefixes are
# constants because the entrypoint's leaked-temp cleanup globs "$PREFIX".*.
readonly STOP_CMD_CAPTURE_PREFIX=/var/run/nut-secrets/stop-cmd
readonly WD_RESTART_CAPTURE_PREFIX=/var/run/nut-secrets/wd-restart
capture_tmpfile() {
  # mktemp writes its own cause to stderr; carry it, never re-derive one.
  if _ct_out=$(mktemp "$1.XXXXXX" 2>&1); then
    printf '%s' "$_ct_out"
    return 0
  fi
  printf 'level=warn msg="bounded capture allocation failed; command output will be discarded" prefix=%s detail="%s"\n' \
    "$1" "$(log_value "$_ct_out")" >&2 || :
  printf '/dev/null'
}
capture_head() {
  # 513, not 512: log_value marks truncation only above 512 characters.
  head -c 513 "$1" 2>/dev/null || true
}
capture_cleanup() {
  # Deliberately status-neutral: every caller publishes a best-effort contract
  # an unlink failure must not abort.
  [ "$1" = "/dev/null" ] && return 0
  _cc_err=$(rm -f "$1" 2>&1) && return 0
  printf 'level=warn msg="bounded capture cleanup failed; temp file left for the entrypoint sweep" path=%s detail="%s"\n' \
    "$1" "$(log_value "$_cc_err")" >&2 || :
  return 0
}

# stop_nut_cmd: run one NUT stop control bounded by STOP_CMD_TIMEOUT so a
# wedged daemon or control client cannot hold PID 1 inside the signal trap
# until Docker SIGKILLs the container. Best-effort: on timeout or non-zero
# exit, emit a structured warn and return 0 so the caller continues to the
# next daemon. $1 = label, rest = command.
stop_nut_cmd() {
  _stop_label="$1"
  shift
  # -s KILL at the deadline, not TERM: a TERM-ignoring control client would
  # hold PID 1 inside the signal trap past it.
  _stop_out_file=$(capture_tmpfile "$STOP_CMD_CAPTURE_PREFIX")
  if timeout -s KILL "$STOP_CMD_TIMEOUT" "$@" >"$_stop_out_file" 2>&1; then
    :
  else
    _stop_rc=$?
    _stop_out=$(capture_head "$_stop_out_file")
    printf 'level=warn msg="%s stop failed (may already be stopped)" rc=%d detail="%s"\n' \
      "$_stop_label" "$_stop_rc" "$(log_value "$_stop_out")" >&2
  fi
  capture_cleanup "$_stop_out_file"
  return 0
}

# Stop all NUT daemons. Logs warnings on failure but does not exit — callers
# decide the final exit status. $1 is the supervised upsmon's PID, empty when
# there is none to signal: upsmon is already gone on the forced-shutdown path,
# where its own exit is what starts this sequence, and was never started on a
# failed boot. `upsmon -c stop` can only fail then, so issuing it would accuse
# the daemon whose exit triggered the teardown on the two paths an operator reads.
stop_services() {
  printf 'level=info msg="stopping NUT services"\n' >&2
  if [ -n "${1:-}" ]; then
    stop_nut_cmd "upsmon" /usr/sbin/upsmon -c stop
  fi
  stop_nut_cmd "upsd" /usr/sbin/upsd -c stop
  stop_nut_cmd "upsdrvctl" /usr/sbin/upsdrvctl stop
  printf 'level=info msg="NUT service stop sequence completed"\n' >&2
}

# read_pidfile: bounded, race-safe read of a NUT pidfile from the nut-writable
# /var/run/nut. Refuses symlinks and non-regular files, prints at most 64 bytes
# or nothing, and always returns 0. Opens the file only after dropping to the
# unprivileged nut user, so a symlink raced in after the check cannot leak
# root-only content (BusyBox su implements no --reuid/--regid). The hard
# bound (timeout -s KILL 1) keeps a raced FIFO from blocking the caller.
read_pidfile() {
  _rp_path=$1
  [ ! -L "$_rp_path" ] && [ -f "$_rp_path" ] || return 0
  timeout -s KILL 1 su -s /bin/sh -c "exec head -c 64 \"\$1\"" nut sh "$_rp_path" \
    2>/dev/null || true
}

# Bounded poll for a NUT daemon PID file — the canonical completion signal
# upstream relies on (upsdrvctl itself checks for it), which avoids BusyBox
# pgrep quirks around `-x` matching a daemonized process's truncated comm.
# Polls every PIDFILE_POLL_INTERVAL up to total timeout. Returns 0 on
# success, 1 on timeout.
wait_for_pidfile() {
  # $1 = label, $2 = absolute PID file path, $3 = expected daemon binary.
  : "${3:?wait_for_pidfile requires an expected binary path}"
  # Poll in a background subshell and `wait` on it, as start_nut_daemon does
  # and for the same reason: a boot-time SIGTERM must reach PID 1's trap at
  # once. Both the sleep and read_pidfile's bounded `su` open are foreground
  # here, so the wrapper belongs at the poll, not at one command inside it.
  (
    _wf_i=0
    while [ "$_wf_i" -lt "$PIDFILE_POLL_MAX" ]; do
      # Only trust strictly numeric content (mirrors restart_ups_driver's
      # confused-deputy guard).
      _wf_pid=$(read_pidfile "$2")
      case "$_wf_pid" in
        '' | *[!0-9]*) ;; # empty, partial write, or untrusted content: keep polling
        *[!0]*)
          # pid_matches_binary is the whole gate: a planted PID of some unrelated
          # live process must not satisfy it, and it refuses a dead PID too.
          if pid_matches_binary "$_wf_pid" "$3"; then
            exit 0
          fi
          ;;
        *) ;; # an all-zero PID cannot name a process or pass pid_matches_binary
      esac
      sleep "$PIDFILE_POLL_INTERVAL"
      _wf_i=$((_wf_i + 1))
    done
    exit 1
  ) &
  if wait "$!"; then
    return 0
  else
    _wf_rc=$?
  fi
  # A status above 1 is a trapped signal; the teardown trap owns that outcome.
  case "$_wf_rc" in
    1)
      printf 'level=error msg="%s did not confirm a live PID for the expected binary in time" path=%s polls=%d interval=%s\n' \
        "$1" "$2" "$PIDFILE_POLL_MAX" "$PIDFILE_POLL_INTERVAL" >&2
      ;;
  esac
  return "$_wf_rc"
}

# ---------------------------------------------------------------------------
# USB comms recovery watchdog
# ---------------------------------------------------------------------------
# A UPS that resets its own USB link re-enumerates to a new root:root node
# (networkupstools/nut#1786), and the nut-user driver then sits "Data stale"
# until the container is recreated. This watchdog keys on sustained stale
# comms rather than on USB, so it bounces the driver on any transport. README
# "USB hotplug & comms recovery" owns the operator-facing contract.

# upsd_probe_host: the host the loopback protocol probes must use. Only the
# wildcard binds map to loopback; a specific bind is probed where upsd
# actually listens, or a 127.0.0.1 probe would fail permanently and the
# watchdog would bounce the driver forever. "localhost" is a specific bind:
# upsd binds the FIRST resolved address while upsc tries every one.
# Colon-bearing hosts are bracketed per NUT's host:port syntax.
upsd_probe_host() {
  case "$API_ADDRESS" in
    0.0.0.0) printf '127.0.0.1' ;;
    ::) printf '[::1]' ;;
    *:*) printf '[%s]' "${API_ADDRESS}" ;;
    *) printf '%s' "${API_ADDRESS}" ;;
  esac
}

# comms_fresh: return 0 when upsd is serving fresh data, non-zero on
# stale/unreachable.
comms_fresh() {
  timeout 3 upsc "${UPS_NAME}@$(upsd_probe_host):${API_PORT}" ups.status
}

# upsd_responsive: return 0 when upsd answers the NUT protocol (LIST UPS),
# regardless of driver data freshness. Distinct from comms_fresh, which
# fails on "Data stale" and drives driver-only recovery.
upsd_responsive() {
  # Background + wait so a trapped SIGTERM interrupts immediately instead of
  # after up to 5s of foreground upsc.
  timeout 5 upsc -l "$(upsd_probe_host):${API_PORT}" >/dev/null 2>&1 &
  wait "$!"
}

# watchdog_epoch: monotonic seconds since boot (/proc/uptime), so an NTP clock
# step cannot stretch or shrink the stale window. A function so the smoke
# test can stub the clock and drive threshold crossings deterministically.
watchdog_epoch() {
  cut -d. -f1 /proc/uptime
}

# driver_pidfile: NUT writes the driver PID file as <driver>-<ups>.pid under
# /var/run/nut.
driver_pidfile() {
  printf '/var/run/nut/%s-%s.pid' "$UPS_DRIVER" "$UPS_NAME"
}

# driver_binary: installed driver path (--with-drvpath=/usr/lib/nut in the
# Dockerfile).
driver_binary() {
  printf '/usr/lib/nut/%s' "$UPS_DRIVER"
}

# pid_matches_binary PID BINARY: verify PID is a LIVE instance of BINARY —
# both probes read /proc/<pid>, so a PID with no process is refused and
# callers need no separate liveness check. Prefers the kernel-truth
# /proc/<pid>/exe symlink; falls back to the
# world-readable /proc/<pid>/comm when exe is unreadable — a NUT daemon
# setuid()s without exec-ing, which clears its dumpable flag (CONTRIBUTING
# "/proc/<pid>/exe is unreadable for the NUT daemons"). comm is self-reported,
# so the fallback is deliberately the weaker of the two.
pid_matches_binary() {
  _pm_pid=$1
  _pm_bin=$2
  _pm_exe=$(readlink -f "/proc/$_pm_pid/exe" 2>/dev/null) || _pm_exe=""
  if [ -n "$_pm_exe" ]; then
    _pm_want=$(readlink -f "$_pm_bin" 2>/dev/null) || _pm_want="$_pm_bin"
    [ "$_pm_exe" = "$_pm_want" ]
    return
  fi
  # Bounded read (comm is <=16 bytes by contract; head caps a raced special
  # file); $() strips the trailing newline.
  _pm_comm=$(head -c 64 "/proc/$_pm_pid/comm" 2>/dev/null) || return 1
  [ -n "$_pm_comm" ] || return 1
  [ "$_pm_comm" = "$(printf '%.15s' "${_pm_bin##*/}")" ]
}

# kill_stale_driver_from_pidfile: hard-kill the wedged driver named by the
# pidfile ($1), then drop the pidfile. A wedged driver is hard-killed by
# pidfile because `upsdrvctl stop` alone has been observed to fail to reap it
# ("Stopping ...pid failed: Permission denied").
kill_stale_driver_from_pidfile() {
  _ksd_pf=$1
  # Read the PID once: re-cat'ing after `upsdrvctl stop` risks acting on a
  # pidfile whose process already exited (and whose PID may have been reused).
  _ksd_pid=$(read_pidfile "$_ksd_pf")
  # Confused-deputy guard: the pidfile lives in the nut-writable /var/run/nut,
  # so a compromised nut process can plant an arbitrary PID (1, upsmon, "-1")
  # and turn this root SIGKILL into a kill of any container process. Only
  # signal a strictly numeric PID verified as an instance of the expected
  # driver binary; otherwise log, refuse to signal, and let the unconditional
  # rm below drop the untrusted pidfile.
  case "$_ksd_pid" in
    '') ;; # no pidfile: nothing to hard-kill
    *[!0-9]*)
      printf 'level=error msg="comms watchdog refusing non-numeric PID from pidfile" ups=%s pidfile=%s pid="%s"\n' \
        "$UPS_NAME" "$_ksd_pf" "$(log_value "$_ksd_pid")" >&2
      _ksd_pid=""
      ;;
    *[!0]*) ;; # numeric with a nonzero digit: candidate for the verified hard-kill below
    *)
      # All-zero PID: `kill -0 0` probes the caller's own process group, so
      # refuse it outright (mirrors wait_for_pidfile's zero-PID guard).
      printf 'level=error msg="comms watchdog refusing all-zero PID from pidfile" ups=%s pidfile=%s\n' \
        "$UPS_NAME" "$_ksd_pf" >&2
      _ksd_pid=""
      ;;
  esac
  if [ -n "$_ksd_pid" ] && kill -0 "$_ksd_pid" 2>/dev/null; then
    if ! pid_matches_binary "$_ksd_pid" "$(driver_binary)"; then
      printf 'level=error msg="comms watchdog refusing to kill PID not verified as the UPS driver" ups=%s pid=%s expected=%s\n' \
        "$UPS_NAME" "$_ksd_pid" "$(driver_binary)" >&2
    # No probe before the signal: `kill -9` refuses an absent PID exactly as
    # `kill -0` does, so one here only widens the identity-to-signal window.
    # What remains is unclosable in POSIX sh (PID wraparound prices it).
    elif kill -9 "$_ksd_pid" 2>/dev/null; then
      printf 'level=warn msg="comms watchdog force-killed the UPS driver that survived upsdrvctl stop" ups=%s pid=%s\n' \
        "$UPS_NAME" "$_ksd_pid" >&2
    fi
  fi
  if ! rm -f "$_ksd_pf"; then
    printf 'level=warn msg="comms watchdog could not drop the stale driver pidfile" ups=%s pidfile=%s\n' \
      "$UPS_NAME" "$_ksd_pf" >&2
  fi
}

# start_recovered_driver: bounded restart of the UPS driver with captured,
# size-bounded output.
start_recovered_driver() {
  # 90s outer bound catches upsdrvctl itself wedging; -k 5 hard-kills a
  # TERM-ignoring upsdrvctl.
  _srd_out_file=$(capture_tmpfile "$WD_RESTART_CAPTURE_PREFIX")
  if timeout -k 5 90 /usr/sbin/upsdrvctl start "$UPS_NAME" >"$_srd_out_file" 2>&1; then
    printf 'level=info msg="comms watchdog driver restart issued" ups=%s\n' "$UPS_NAME" >&2
  else
    # On this BusyBox image `timeout -k 5 90` reports expiry as 143 or 137
    # (never coreutils' 124).
    _srd_rc=$?
    _srd_out=$(capture_head "$_srd_out_file")
    printf 'level=error msg="comms watchdog driver restart failed" ups=%s rc=%d detail="%s"\n' \
      "$UPS_NAME" "$_srd_rc" "$(log_value "$_srd_out")" >&2
  fi
  capture_cleanup "$_srd_out_file"
}

# restart_ups_driver: re-home the driver onto the (possibly re-enumerated) USB
# node. Runs as root: re-asserts the nut group on the bus so the driver's own
# reconnect can open a freshly created root:root node, then bounces the
# driver. The chgrp is load-bearing, not belt-and-braces: the driver drops
# to nut at NUT v2.8.5 drivers/main.c:2538 and opens the device only in
# upsdrv_initups() at :2997, so it must reach the node AS nut.
restart_ups_driver() {
  _attempt=${1:-1}
  # Stand down only when a real host poweroff is in progress. upsmon writes
  # POWERDOWNFLAG on EVERY FSD, so the flag alone would also disarm recovery
  # after the log-only noop FSD that no poweroff follows; the
  # SHUTDOWN_ON_BATTERY_CRITICAL conjunct excludes that case. It still
  # latches while host shutdown is enabled and a mounted upsmon.conf.user
  # points SHUTDOWNCMD away from this image's scripts. Return non-zero so a
  # stand-down is not counted.
  if [ "${SHUTDOWN_ON_BATTERY_CRITICAL:-false}" = "true" ] && [ -e "$POWERDOWNFLAG_FILE" ]; then
    printf 'level=warn msg="comms watchdog standing down; forced shutdown (killpower) in progress" ups=%s\n' "$UPS_NAME" >&2
    return 1
  fi
  # Log at error from the final fast retry onward so a prolonged outage is
  # visible while the last fast recovery attempt runs. The cause arrives in
  # the restart-failed detail below; never infer one from the attempt count.
  if [ "$_attempt" -ge "$COMMS_FAST_RETRIES" ]; then
    printf 'level=error msg="comms watchdog still restarting driver after repeated attempts" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  else
    printf 'level=warn msg="comms watchdog restarting UPS driver after stale comms" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  fi
  if usb_bus_required; then
    if ! _rud_chg_err=$(chgrp -R nut /dev/bus/usb 2>&1); then
      printf 'level=warn msg="comms watchdog could not re-assert nut group on USB nodes" ups=%s err="%s"\n' \
        "$UPS_NAME" "$(log_value "$_rud_chg_err")" >&2
    fi
  fi
  _rud_stop_out_file=$(capture_tmpfile "$WD_RESTART_CAPTURE_PREFIX")
  if timeout -k 5 30 /usr/sbin/upsdrvctl stop "$UPS_NAME" >"$_rud_stop_out_file" 2>&1; then
    # upsdrvctl exits zero after its own SIGKILL escalation (v2.8.5
    # drivers/upsdrvctl.c: "Stopping %s failed, retrying harder" at LOG_ERR,
    # then SIGKILL, then clean_return without exec_error++), so the wedged
    # case is indistinguishable from a clean stop by exit status alone.
    # Match that record: the capture is not empty on an ordinary stop --
    # upsdrvctl banners to stdout unconditionally and this captures both streams.
    _rud_stop_out=$(capture_head "$_rud_stop_out_file")
    case "$_rud_stop_out" in
      *'retrying harder'*)
        printf 'level=warn msg="comms watchdog driver stop escalated to SIGKILL upstream" ups=%s detail="%s"\n' \
          "$UPS_NAME" "$(log_value "$_rud_stop_out")" >&2
        ;;
    esac
  else
    _rud_stop_rc=$?
    _rud_stop_out=$(capture_head "$_rud_stop_out_file")
    printf 'level=warn msg="comms watchdog driver stop failed" ups=%s rc=%d detail="%s"\n' \
      "$UPS_NAME" "$_rud_stop_rc" "$(log_value "$_rud_stop_out")" >&2
  fi
  capture_cleanup "$_rud_stop_out_file"
  if [ "${SHUTDOWN_ON_BATTERY_CRITICAL:-false}" = "true" ] && [ -e "$POWERDOWNFLAG_FILE" ]; then
    printf 'level=warn msg="comms watchdog standing down; forced shutdown (killpower) in progress" ups=%s phase=post-stop\n' "$UPS_NAME" >&2
    return 1
  fi
  kill_stale_driver_from_pidfile "$(driver_pidfile)"
  start_recovered_driver
  # Signal that a real restart was attempted (distinct from the killpower
  # stand-down's non-zero return) so comms_watchdog counts it against the budget.
  return 0
}

# comms_watchdog: probe upsd every COMMS_CHECK_INTERVAL seconds and re-home the
# driver after sustained stale comms, in two stages: COMMS_FAST_RETRIES fast
# attempts, at error level from the last of them onward, then a
# COMMS_BACKOFF_FACTOR-multiplied threshold, so a genuinely-absent UPS stops
# thrashing host USB perms while staying
# visible. Each window is monotonic elapsed time since its first stale probe
# (watchdog_epoch, not summed intervals). README "USB hotplug & comms
# recovery" sizes it.
comms_watchdog() {
  : "${UPS_NAME:?comms_watchdog requires UPS_NAME}"
  : "${UPS_DRIVER:?comms_watchdog requires UPS_DRIVER}"
  : "${COMMS_CHECK_INTERVAL:?comms_watchdog requires COMMS_CHECK_INTERVAL}"
  : "${COMMS_RECOVERY_TIMEOUT:?comms_watchdog requires COMMS_RECOVERY_TIMEOUT}"
  : "${COMMS_FAST_RETRIES:?comms_watchdog requires COMMS_FAST_RETRIES}"
  : "${COMMS_BACKOFF_FACTOR:?comms_watchdog requires COMMS_BACKOFF_FACTOR}"
  _stale_since=""
  _outage_since=""
  _restarts=0
  # `while true; do sleep` (not `while sleep`): a signal-interrupted sleep must
  # not silently terminate the loop and disable USB recovery for the container's life.
  while true; do
    sleep "$COMMS_CHECK_INTERVAL" || true
    if comms_fresh >/dev/null 2>&1; then
      if [ "$_restarts" -gt 0 ]; then
        # Total outage = elapsed since the FIRST stale probe of the outage,
        # not the last post-restart window (_stale_since resets on every bounce).
        _total=unknown
        if [ -n "$_outage_since" ] && _now=$(watchdog_epoch); then
          _total=$((_now - _outage_since))
        fi
        printf 'level=info msg="comms watchdog UPS comms recovered" ups=%s stale_secs=%s restarts=%d\n' \
          "$UPS_NAME" "$_total" "$_restarts" >&2
      fi
      _stale_since=""
      _outage_since=""
      _restarts=0
    else
      # Skip the tick rather than die under set -e if the clock read fails —
      # a dead watchdog silently disables USB recovery.
      _now=$(watchdog_epoch) || {
        printf 'level=warn msg="comms watchdog clock read failed; skipping tick" ups=%s\n' "$UPS_NAME" >&2
        continue
      }
      if [ -z "$_stale_since" ]; then
        _stale_since="$_now"
        [ -n "$_outage_since" ] || _outage_since="$_now"
      fi
      _stale=$((_now - _stale_since))
      if [ "$_restarts" -lt "$COMMS_FAST_RETRIES" ]; then
        _threshold="$COMMS_RECOVERY_TIMEOUT"
      else
        _threshold=$((COMMS_RECOVERY_TIMEOUT * COMMS_BACKOFF_FACTOR))
      fi
      if [ "$_stale" -ge "$_threshold" ]; then
        # Count an attempt only when the driver was actually bounced; a
        # stand-down (restart_ups_driver returns non-zero) must not consume
        # the fast-retry budget or inflate the restarts log.
        if restart_ups_driver "$((_restarts + 1))"; then
          _restarts=$((_restarts + 1))
        fi
        _stale_since=""
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# D-Bus poweroff-path liveness probe
# ---------------------------------------------------------------------------
# With SHUTDOWN_ON_BATTERY_CRITICAL=true the poweroff path (upsmon SHUTDOWNCMD
# -> nut-shutdown.sh -> D-Bus PowerOff) is otherwise first exercised during a
# real forced shutdown. README "Alerting" owns the operator-facing contract.

# dbus_poweroff_path_ok: return 0 when the host D-Bus socket is mounted and
# logind's own CanPowerOff answers yes — same polkit action as the PowerOff
# call, no side effect. `no` and `challenge` come back as SUCCESSFUL method
# returns, so the reply STRING is the verdict, never dbus-send's exit status;
# `challenge` is a refusal here because the real call is non-interactive.
dbus_poweroff_path_ok() {
  _dbus_detail=""
  # dbus-send spawns no fd-holding grandchildren, so this capture cannot wait
  # past the bounded command. The redirect is on the brace group so that past
  # `timeout 5` the reporting shell's signal-death line still lands in detail=.
  _dbus_reply=$({ timeout 5 dbus-send --system --print-reply \
    --reply-timeout="$DBUS_PROBE_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.CanPowerOff; } 2>&1) || {
    _dbus_detail="$_dbus_reply"
    return 1
  }
  case "$_dbus_reply" in
    *'string "yes"'*) return 0 ;;
    *)
      _dbus_detail="$_dbus_reply"
      return 1
      ;;
  esac
}

# dbus_liveness_probe: background loop started by the entrypoint when host
# shutdown is enabled. Same loop shape as comms_watchdog (`sleep || true` so a
# signal-interrupted sleep cannot silently end the loop). Logs error on every
# failed probe while broken (recurring lines keep the Loki alert firing) and
# info once on recovery.
dbus_liveness_probe() {
  : "${DBUS_PROBE_INTERVAL:?dbus_liveness_probe requires DBUS_PROBE_INTERVAL}"
  _dbus_broken=0
  while true; do
    if dbus_poweroff_path_ok; then
      if [ "$_dbus_broken" -eq 1 ]; then
        printf 'level=info msg="D-Bus poweroff path recovered"\n' >&2
      fi
      _dbus_broken=0
    else
      printf 'level=error msg="D-Bus poweroff path unreachable; host poweroff on battery critical would fail" socket=/run/dbus/system_bus_socket detail="%s"\n' \
        "$(log_value "${_dbus_detail:-}")" >&2
      _dbus_broken=1
    fi
    sleep "$DBUS_PROBE_INTERVAL" || true
  done
}
