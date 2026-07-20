#!/bin/sh
# lifecycle.sh — NUT service lifecycle utility functions.
# Sourced by entrypoint.sh; not executed directly.

readonly PIDFILE_POLL_INTERVAL="0.1"
readonly PIDFILE_POLL_MAX=50 # total wait = POLL_MAX × POLL_INTERVAL = 5s
readonly DBUS_PROBE_REPLY_TIMEOUT_MS=3000
# Per-command bound for the stop_services control calls: 3 commands x 3s = 9s
# worst case, inside Docker's default 10s stop budget before SIGKILL.
readonly STOP_CMD_TIMEOUT=3

# ---------------------------------------------------------------------------
# Service lifecycle functions
# ---------------------------------------------------------------------------

# stop_nut_cmd: run one NUT stop control bounded by STOP_CMD_TIMEOUT so a
# wedged daemon or control client cannot hold PID 1 inside the signal trap
# until Docker SIGKILLs the container. Best-effort: on timeout or non-zero
# exit, emit a structured warn (label, rc, sanitized detail) and return 0 so
# the caller continues to the next daemon. $1 = label, rest = command.
stop_nut_cmd() {
  _stop_label="$1"
  shift
  if _stop_out=$(timeout "$STOP_CMD_TIMEOUT" "$@" 2>&1); then
    return 0
  else
    _stop_rc=$?
    printf 'level=warn msg="%s stop failed (may already be stopped)" rc=%d detail="%s"\n' \
      "$_stop_label" "$_stop_rc" "$(log_value "$_stop_out")" >&2
  fi
  return 0
}

# Stop all NUT daemons. Logs warnings on failure but does not exit — callers
# decide the final exit status. Each control call is time-bounded (see
# stop_nut_cmd) so the combined worst case fits the container stop budget.
stop_services() {
  printf 'level=info msg="stopping NUT services"\n' >&2
  stop_nut_cmd "upsmon" /usr/sbin/upsmon -c stop
  stop_nut_cmd "upsd" /usr/sbin/upsd -c stop
  stop_nut_cmd "upsdrvctl" /usr/sbin/upsdrvctl stop
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
    # Pidfiles live in the nut-writable /var/run/nut; only trust strictly
    # numeric content (mirrors restart_ups_driver's confused-deputy guard).
    _wf_pid=$(cat "$2" 2>/dev/null || true)
    case "$_wf_pid" in
      '' | *[!0-9]*) ;; # empty, partial write, or untrusted content: keep polling
      *)
        if kill -0 "$_wf_pid" 2>/dev/null; then
          return 0
        fi
        ;;
    esac
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

# upsd_probe_host: host for the loopback protocol probes. upsd binds ONLY the
# LISTEN address generated from API_ADDRESS (upsd.conf), so a specific bind
# address must be probed at that address — probing 127.0.0.1 would fail
# permanently (driver bounced forever by the watchdog, container fatally
# exited by the supervision loop). Wildcard binds map to loopback.
upsd_probe_host() {
  case "${API_ADDRESS:-0.0.0.0}" in
    0.0.0.0 | 127.* | localhost) printf '127.0.0.1' ;;
    ::) printf '::1' ;;
    *) printf '%s' "${API_ADDRESS}" ;;
  esac
}

# comms_fresh: return 0 when upsd is serving fresh data, non-zero on
# stale/unreachable. upsc prints the requested variable on fresh data and an
# error ("Data stale" / connection refused) otherwise.
comms_fresh() {
  timeout 3 upsc "${UPS_NAME}@$(upsd_probe_host):${API_PORT:-3493}" ups.status >/dev/null 2>&1
}

# upsd_responsive: return 0 when upsd answers the NUT protocol (LIST UPS),
# regardless of driver data freshness. Distinct from comms_fresh
# (lifecycle.sh), which fails on "Data stale" and drives driver-only recovery.
upsd_responsive() {
  # Background + wait so a trapped SIGTERM interrupts immediately instead of
  # after up to 5s of foreground upsc — that 5s would push worst-case teardown
  # to 14s, past Docker's 10s stop budget (see STOP_CMD_TIMEOUT above).
  # The orphaned upsc self-terminates within its own 5s timeout.
  timeout 5 upsc -l "$(upsd_probe_host):${API_PORT}" >/dev/null 2>&1 &
  wait $!
}

# watchdog_epoch: monotonic seconds since boot (/proc/uptime), so an NTP clock
# step cannot stretch or shrink the stale window -- only differences are ever
# computed. A function so the smoke test can stub the clock and drive
# threshold crossings deterministically.
watchdog_epoch() {
  cut -d. -f1 /proc/uptime
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
# For non-USB transports (see usb_bus_required) the group re-assert is
# skipped and the restart is a plain driver bounce.
restart_ups_driver() {
  _attempt=${1:-1}
  # h-f8 guard: stand down ONLY when a REAL host poweroff is in progress. upsmon
  # (primary) writes POWERDOWNFLAG (/var/run/nut-secrets/killpower) on every FSD,
  # including the log-only noop path (SHUTDOWN_ON_BATTERY_CRITICAL=false) where the
  # host stays up and the container keeps running — gating on killpower alone would
  # latch USB recovery OFF for the container's life. Requiring
  # SHUTDOWN_ON_BATTERY_CRITICAL=true scopes the stand-down to the only case with a
  # poweroff to protect (the flag is also cleared at entrypoint startup). The flag
  # lives in the root-only nut-secrets dir so a compromised nut process cannot plant
  # it and suppress recovery (h-f2). Return non-zero so a stand-down is not counted
  # as a restart attempt by comms_watchdog.
  if [ "${SHUTDOWN_ON_BATTERY_CRITICAL:-false}" = "true" ] && [ -e /var/run/nut-secrets/killpower ]; then
    printf 'level=warn msg="comms watchdog standing down; forced shutdown (killpower) in progress" ups=%s\n' "$UPS_NAME" >&2
    return 1
  fi
  # From the FINAL fast retry onward (attempt >= COMMS_FAST_RETRIES) the UPS is
  # likely genuinely absent or the driver unstartable, so escalate to error --
  # deliberately ON the last fast attempt so the error still lands inside the
  # UPSDataAbsent alert window (see README 'USB hotplug & comms recovery').
  if [ "$_attempt" -ge "$COMMS_FAST_RETRIES" ]; then
    printf 'level=error msg="comms watchdog still restarting driver; UPS likely absent or driver unstartable" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  else
    printf 'level=warn msg="comms watchdog re-homing UPS driver after stale comms" ups=%s attempt=%d\n' "$UPS_NAME" "$_attempt" >&2
  fi
  if usb_bus_required; then
    if ! chgrp -R nut /dev/bus/usb 2>/dev/null; then
      printf 'level=warn msg="comms watchdog could not re-assert nut group on USB nodes" ups=%s\n' "$UPS_NAME" >&2
    fi
  fi
  timeout 30 /usr/sbin/upsdrvctl stop "$UPS_NAME" >/dev/null 2>&1 || true
  _pf="$(driver_pidfile)"
  # Read the PID once: re-cat'ing after `upsdrvctl stop` risks acting on a
  # pidfile whose process already exited (and whose PID may have been reused).
  _pid=$(cat "$_pf" 2>/dev/null || true)
  # Confused-deputy guard: the pidfile lives in the nut-writable /var/run/nut,
  # so a compromised nut process can plant an arbitrary PID (1, upsmon, or
  # "-1" = every process) and turn this root SIGKILL into a kill of any
  # container process. Only signal a strictly numeric PID whose
  # /proc/<pid>/exe resolves to the expected driver binary
  # (--with-drvpath=/usr/lib/nut in the Dockerfile); otherwise log, refuse to
  # signal, and let the unconditional rm below drop the untrusted pidfile.
  case "$_pid" in
    '') ;; # no pidfile: nothing to hard-kill
    *[!0-9]*)
      printf 'level=error msg="comms watchdog refusing non-numeric PID from pidfile" ups=%s pidfile=%s pid="%s"\n' \
        "$UPS_NAME" "$_pf" "$(log_value "$_pid")" >&2
      _pid=""
      ;;
  esac
  if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
    # Verify identity, then re-check existence immediately before signaling
    # to narrow the PID-reuse window as far as plain sh allows.
    if [ "$(readlink -f "/proc/$_pid/exe" 2>/dev/null)" = "/usr/lib/nut/$UPS_DRIVER" ] \
      && kill -0 "$_pid" 2>/dev/null; then
      kill -9 "$_pid" 2>/dev/null || true
    else
      printf 'level=error msg="comms watchdog refusing to kill PID not verified as the UPS driver" ups=%s pid=%s expected=/usr/lib/nut/%s\n' \
        "$UPS_NAME" "$_pid" "$UPS_DRIVER" >&2
    fi
  fi
  rm -f "$_pf"
  # 90s > NUT's 75s default maxstartdelay, so timeout only fires on a genuine wedge.
  if _out=$(timeout 90 /usr/sbin/upsdrvctl start "$UPS_NAME" 2>&1); then
    printf 'level=info msg="comms watchdog driver restart issued" ups=%s\n' "$UPS_NAME" >&2
  else
    # Capture the exit status (124 = timeout) so a silent failure still names
    # its class; log_value flattens CR/tab/control bytes that the previous
    # LF-only sanitizer let split or corrupt the logfmt record.
    _rc=$?
    printf 'level=error msg="comms watchdog driver restart failed" ups=%s rc=%d detail="%s"\n' \
      "$UPS_NAME" "$_rc" "$(log_value "$_out")" >&2
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
# Staleness is monotonic elapsed time since the FIRST stale probe of the current
# window (via watchdog_epoch), not a sum of check intervals — each stale probe
# can spend up to 3s inside upsc's timeout, and interval-summing let that
# stretch the real recovery window ~20% past the configured budget.
comms_watchdog() {
  : "${UPS_NAME:?comms_watchdog requires UPS_NAME}"
  : "${UPS_DRIVER:?comms_watchdog requires UPS_DRIVER}"
  : "${COMMS_CHECK_INTERVAL:?comms_watchdog requires COMMS_CHECK_INTERVAL}"
  : "${COMMS_RECOVERY_TIMEOUT:?comms_watchdog requires COMMS_RECOVERY_TIMEOUT}"
  : "${COMMS_FAST_RETRIES:?comms_watchdog requires COMMS_FAST_RETRIES}"
  : "${COMMS_BACKOFF_FACTOR:?comms_watchdog requires COMMS_BACKOFF_FACTOR}"
  _stale=0
  _stale_since=""
  _outage_since=""
  _restarts=0
  # `while true; do sleep` (not `while sleep`): a signal-interrupted sleep must
  # not silently terminate the loop and disable USB recovery for the container's life.
  while true; do
    sleep "$COMMS_CHECK_INTERVAL" || true
    if comms_fresh; then
      if [ "$_restarts" -gt 0 ]; then
        # Total outage = elapsed since the FIRST stale probe of the outage,
        # not the last post-restart window (_stale resets on every bounce).
        _total="$_stale"
        if [ -n "$_outage_since" ] && _now=$(watchdog_epoch); then
          _total=$((_now - _outage_since))
        fi
        printf 'level=info msg="comms watchdog UPS comms recovered" ups=%s stale_secs=%d restarts=%d\n' \
          "$UPS_NAME" "$_total" "$_restarts" >&2
      fi
      _stale=0
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
        _stale=0
        _stale_since=""
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# D-Bus poweroff-path liveness probe
# ---------------------------------------------------------------------------
# With SHUTDOWN_ON_BATTERY_CRITICAL=true the poweroff path (upsmon SHUTDOWNCMD
# -> nut-shutdown.sh -> D-Bus PowerOff) is otherwise checked once at startup
# and first exercised during a real forced shutdown — a D-Bus mount that broke
# after boot would surface exactly when it can no longer be fixed. This probe
# re-checks reachability every DBUS_PROBE_INTERVAL seconds (0 disables) and
# logs level=error while the path is broken, so the UPSPowerOffPathBroken
# alert (alerts.yaml) can fire before an outage; level=info once on recovery.

# dbus_poweroff_path_ok: return 0 when the host D-Bus socket is mounted and
# logind answers a side-effect-free Peer.Ping on the exact destination
# nut-shutdown.sh will call during a forced shutdown.
dbus_poweroff_path_ok() {
  [ -S /run/dbus/system_bus_socket ] || return 1
  dbus-send --system --print-reply --reply-timeout="$DBUS_PROBE_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
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
      printf 'level=error msg="D-Bus poweroff path unreachable; host poweroff on battery critical would fail" socket=/run/dbus/system_bus_socket\n' >&2
      _dbus_broken=1
    fi
    sleep "$DBUS_PROBE_INTERVAL" || true
  done
}
