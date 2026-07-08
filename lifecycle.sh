#!/bin/sh
# lifecycle.sh — NUT service lifecycle utility functions.
# Sourced by entrypoint.sh; not executed directly.

readonly PIDFILE_POLL_INTERVAL="0.1"
readonly PIDFILE_POLL_MAX=50 # total wait = POLL_MAX × POLL_INTERVAL = 5s

# ---------------------------------------------------------------------------
# Service lifecycle functions
# ---------------------------------------------------------------------------

# Stop all NUT daemons. Logs warnings on failure but does not exit — callers
# decide the final exit status.
stop_services() {
  printf 'level=info msg="stopping NUT services"\n' >&2
  if ! /usr/sbin/upsmon -c stop 2>&1; then
    printf 'level=warn msg="upsmon stop failed (may already be stopped)"\n' >&2
  fi
  if ! /usr/sbin/upsd -c stop 2>&1; then
    printf 'level=warn msg="upsd stop failed (may already be stopped)"\n' >&2
  fi
  if ! /usr/sbin/upsdrvctl stop 2>&1; then
    printf 'level=warn msg="upsdrvctl stop failed (driver may already be stopped)"\n' >&2
  fi
  printf 'level=info msg="NUT services stopped"\n' >&2
}

# Bounded poll for a NUT daemon PID file. NUT drivers/daemons write a PID
# file at /var/run/nut/<name>.pid after a successful fork+daemonize, which
# is the canonical completion signal upstream relies on (upsdrvctl itself
# checks for it). Using the PID file avoids BusyBox pgrep quirks around
# `-x` matching argv[0] of daemonized processes whose comm is truncated or
# changed. Polls every PIDFILE_POLL_INTERVAL up to total timeout. Returns 0
# on success, 1 on timeout.
wait_for_pidfile() {
  # Required variables — fail fast if caller forgot to set them.
  : "${PIDFILE_POLL_INTERVAL:?wait_for_pidfile requires PIDFILE_POLL_INTERVAL}"
  : "${PIDFILE_POLL_MAX:?wait_for_pidfile requires PIDFILE_POLL_MAX}"
  # $1 = label, $2 = absolute PID file path
  i=0
  while [ $i -lt "$PIDFILE_POLL_MAX" ]; do
    if [ -s "$2" ] && kill -0 "$(cat "$2")" 2>/dev/null; then
      return 0
    fi
    sleep "$PIDFILE_POLL_INTERVAL"
    i=$((i + 1))
  done
  printf 'level=error msg="%s did not write a valid PID file in time" path=%s polls=%d interval=%s\n' \
    "$1" "$2" "$PIDFILE_POLL_MAX" "$PIDFILE_POLL_INTERVAL" >&2
  return 1
}

# ---------------------------------------------------------------------------
# USB comms recovery watchdog
# ---------------------------------------------------------------------------
# Devices like the CyberPower Elite PFC drop and re-establish their USB link on
# their own firmware resets (NUT issue networkupstools/nut#1786). Each reset
# re-enumerates the UPS to a NEW /dev/bus/usb node (a fresh device number =>
# new minor, owned root:root by the kernel). The running driver — which dropped
# to the unprivileged "nut" user after init — can neither see the new node
# (unless the bus is bind-mounted live) nor open it (wrong group), so it sits
# "Data stale" until the container is recreated. That is the flip-flop behind
# the UPSDataAbsent alert. This watchdog detects sustained stale comms and
# re-homes the driver onto the current node, recovering before the alert fires.
# It REQUIRES the bus to be passed as a live bind mount plus a cgroup rule for
# the USB major (c 189:* rmw) — see the README ("USB hotplug").

# comms_fresh: return 0 when upsd is serving fresh data, non-zero on
# stale/unreachable. upsc prints the requested variable on fresh data and an
# error ("Data stale" / connection refused) otherwise.
comms_fresh() {
  timeout 3 upsc "${UPS_NAME}@127.0.0.1:${API_PORT:-3493}" ups.status >/dev/null 2>&1
}

# driver_pidfile: NUT writes the driver PID file as <driver>-<ups>.pid under
# /var/run/nut. Centralized so the path convention lives in one place.
driver_pidfile() {
  printf '/var/run/nut/%s-%s.pid' "$UPS_DRIVER" "$UPS_NAME"
}

# restart_ups_driver: re-home the driver onto the (possibly re-enumerated) USB
# node. Runs as root (PID 1 lineage). Re-asserts the nut group on the bus so
# the driver's own reconnect attempts can also open a freshly created
# root:root node (the default 0664 node mode already grants the group rw),
# then bounces the driver. The restart re-opens the device
# while still root (upsdrvctl runs as root and the driver drops to nut only
# AFTER opening), so it succeeds regardless of the new node's group. A wedged
# driver is hard-killed by pidfile because `upsdrvctl stop` alone has been
# observed to fail to reap it ("Stopping ...pid failed: Permission denied").
restart_ups_driver() {
  _attempt=${1:-1}
  # h-f8 guard: stand down ONLY when a REAL host poweroff is in progress. upsmon
  # (primary) writes POWERDOWNFLAG (/var/run/nut/killpower) on every FSD, including
  # the log-only noop path (SHUTDOWN_ON_BATTERY_CRITICAL=false) where the host stays
  # up and the container keeps running — gating on killpower alone would latch USB
  # recovery OFF for the container's life. Requiring SHUTDOWN_ON_BATTERY_CRITICAL=true
  # scopes the stand-down to the only case with a poweroff to protect (the flag is
  # also cleared at entrypoint startup). Return non-zero so a stand-down is not
  # counted as a restart attempt by comms_watchdog.
  if [ "${SHUTDOWN_ON_BATTERY_CRITICAL:-false}" = "true" ] && [ -e /var/run/nut/killpower ]; then
    printf 'level=warn msg="comms watchdog standing down; forced shutdown (killpower) in progress" ups=%s\n' "$UPS_NAME" >&2
    return 1
  fi
  # Past the fast-retry budget the UPS is likely genuinely absent or the driver
  # unstartable, so escalate to error (a sustained outage an operator should see).
  if [ "$_attempt" -ge "$COMMS_FAST_RETRIES" ]; then
    printf 'level=error msg="comms watchdog still restarting driver; UPS likely absent or driver unstartable" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  else
    printf 'level=warn msg="comms watchdog re-homing UPS driver after stale comms" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  fi
  if ! chgrp -R nut /dev/bus/usb 2>/dev/null; then
    printf 'level=warn msg="comms watchdog could not re-assert nut group on USB nodes" ups=%s\n' "$UPS_NAME" >&2
  fi
  /usr/sbin/upsdrvctl stop "$UPS_NAME" >/dev/null 2>&1 || true
  _pf="$(driver_pidfile)"
  # Read the PID once: re-cat'ing after `upsdrvctl stop` risks acting on a
  # pidfile whose process already exited (and whose PID may have been reused).
  _pid=$(cat "$_pf" 2>/dev/null || true)
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    kill -9 "$_pid" 2>/dev/null || true
  fi
  rm -f "$_pf"
  if /usr/sbin/upsdrvctl start "$UPS_NAME" >/dev/null 2>&1; then
    printf 'level=info msg="comms watchdog driver restart issued" ups=%s\n' "$UPS_NAME" >&2
  else
    printf 'level=error msg="comms watchdog driver restart failed" ups=%s\n' "$UPS_NAME" >&2
  fi
  # Signal that a real restart was attempted (distinct from the killpower
  # stand-down's non-zero return) so comms_watchdog counts it against the budget.
  return 0
}

# comms_watchdog: probe upsd every COMMS_CHECK_INTERVAL seconds and re-home the
# driver after sustained stale comms, in two stages. Stage 1 retries every
# COMMS_RECOVERY_TIMEOUT for the first COMMS_FAST_RETRIES attempts so a transient
# USB re-enumeration self-heals fast — inside the upstream UPSDataAbsent alert
# window (keep COMMS_FAST_RETRIES x COMMS_RECOVERY_TIMEOUT <= that window; default
# 3x90s = 4.5m vs the 5m alert). Stage 2 (once fast retries are exhausted) backs
# off to COMMS_RECOVERY_TIMEOUT x COMMS_BACKOFF_FACTOR and escalates to error, so a
# genuinely-absent UPS stops thrashing host USB perms / flooding logs while a
# sustained outage stays visible and still self-heals if the UPS returns.
comms_watchdog() {
  : "${UPS_NAME:?comms_watchdog requires UPS_NAME}"
  : "${UPS_DRIVER:?comms_watchdog requires UPS_DRIVER}"
  : "${COMMS_CHECK_INTERVAL:?comms_watchdog requires COMMS_CHECK_INTERVAL}"
  : "${COMMS_RECOVERY_TIMEOUT:?comms_watchdog requires COMMS_RECOVERY_TIMEOUT}"
  : "${COMMS_FAST_RETRIES:?comms_watchdog requires COMMS_FAST_RETRIES}"
  : "${COMMS_BACKOFF_FACTOR:?comms_watchdog requires COMMS_BACKOFF_FACTOR}"
  _stale=0
  _restarts=0
  # `while true; do sleep` (not `while sleep`): a signal-interrupted sleep must
  # not silently terminate the loop and disable USB recovery for the container's life.
  while true; do
    sleep "$COMMS_CHECK_INTERVAL" || true
    if comms_fresh; then
      if [ "$_restarts" -gt 0 ]; then
        printf 'level=info msg="comms watchdog UPS comms recovered" ups=%s stale_secs=%d restarts=%d\n' \
          "$UPS_NAME" "$_stale" "$_restarts" >&2
      fi
      _stale=0
      _restarts=0
    else
      _stale=$((_stale + COMMS_CHECK_INTERVAL))
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
        _stale=0
      fi
    fi
  done
}
