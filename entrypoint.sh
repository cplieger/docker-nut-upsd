#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# Source helper scripts
# ---------------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR source=validate.sh
. /usr/local/bin/validate.sh
# shellcheck source-path=SCRIPTDIR source=generate-config.sh
. /usr/local/bin/generate-config.sh
# shellcheck source-path=SCRIPTDIR source=lifecycle.sh
. /usr/local/bin/lifecycle.sh
# shellcheck source-path=SCRIPTDIR source=password.sh
. /usr/local/bin/password.sh

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
: "${UPS_NAME:=ups}"
: "${UPS_DESC:=My UPS}"
: "${UPS_DRIVER:=usbhid-ups}"
: "${UPS_PORT:=auto}"
: "${API_USER:=monuser}"
: "${API_PASSWORD:=secret}"
: "${API_ADDRESS:=0.0.0.0}"
: "${API_PORT:=3493}"
: "${POLLFREQ:=5}"
: "${POLLFREQALERT:=5}"
: "${DEADTIME:=15}"
: "${FINALDELAY:=5}"
: "${HOSTSYNC:=15}"
: "${NOCOMMWARNTIME:=300}"
: "${RBWARNTIME:=43200}"

# USB comms recovery watchdog. Devices like the CyberPower Elite PFC re-enumerate
# their USB link on their own firmware resets, which leaves the driver "Data
# stale" until the container is recreated. The watchdog (see lifecycle.sh)
# re-homes the driver onto the re-enumerated node after COMMS_RECOVERY_TIMEOUT
# seconds of stale comms. Requires the bus passed as a live bind + a cgroup rule
# (c 189:* rmw) so the new node is visible/accessible — see the README.
: "${COMMS_WATCHDOG:=true}"
: "${COMMS_CHECK_INTERVAL:=15}"
: "${COMMS_RECOVERY_TIMEOUT:=90}"
# Two-stage recovery cadence: retry fast for COMMS_FAST_RETRIES attempts (keep
# COMMS_FAST_RETRIES x COMMS_RECOVERY_TIMEOUT <= the UPSDataAbsent alert window so
# a transient re-enumeration self-heals before it pages), then back off to
# COMMS_RECOVERY_TIMEOUT x COMMS_BACKOFF_FACTOR for a UPS that stays absent. See
# lifecycle.sh comms_watchdog.
: "${COMMS_FAST_RETRIES:=3}"
: "${COMMS_BACKOFF_FACTOR:=5}"

# Host shutdown support via D-Bus (requires /run/dbus mount)
: "${SHUTDOWN_ON_BATTERY_CRITICAL:=false}"
# Poweroff-path liveness probe cadence in seconds (0 disables). Only runs when
# SHUTDOWN_ON_BATTERY_CRITICAL=true — see lifecycle.sh dbus_liveness_probe.
: "${DBUS_PROBE_INTERVAL:=300}"

# ---------------------------------------------------------------------------
# Password resolution (from password.sh)
# ---------------------------------------------------------------------------
resolve_admin_password

# Canonicalize every validated env var BEFORE validation and any raw-value
# interpretation: $() strips trailing newlines, so a value with a trailing LF
# (env-file artifact) is checked, classified (driver_transport reads the raw
# value), and written as the same byte sequence. See validate.sh
# canonicalize_validated_values.
canonicalize_validated_values

warn_weak_api_password

# ---------------------------------------------------------------------------
# Input validation (table-driven, from validate.sh)
# ---------------------------------------------------------------------------
run_validations

# ---------------------------------------------------------------------------
# USB device validation (USB transports only — see usb_bus_required)
# ---------------------------------------------------------------------------
if usb_bus_required && [ ! -d /dev/bus/usb ]; then
  printf 'level=error msg="/dev/bus/usb not found — map a USB device to the container"\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine SHUTDOWNCMD
# ---------------------------------------------------------------------------
# Default: noop shutdown (log-only on FSD). We ship a tiny script instead of
# inlining a `printf` into SHUTDOWNCMD because NUT's parseconf terminates the
# quoted argument at the first unescaped `"` — an inlined multi-quoted printf
# silently loses its log line.
export SHUTDOWN_ON_BATTERY_CRITICAL
SHUTDOWN_CMD="/usr/local/bin/nut-shutdown-noop.sh"

# Normalize the toggle case-insensitively and accept the common boolean
# spellings, so an operator who sets `True`/`1`/`yes` actually ARMS host
# shutdown instead of silently getting the disabled default. An unrecognized
# value is a misconfiguration on a safety-critical knob, so fail loudly
# (exit 1) rather than degrading quietly to off.
SHUTDOWN_ON_BATTERY_CRITICAL=$(normalize_bool SHUTDOWN_ON_BATTERY_CRITICAL "$SHUTDOWN_ON_BATTERY_CRITICAL") || exit 1
if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" = "true" ]; then
  if [ ! -S /run/dbus/system_bus_socket ]; then
    printf 'level=error msg="SHUTDOWN_ON_BATTERY_CRITICAL enabled but D-Bus socket not mounted"\n' >&2
    exit 1
  fi
  # shellcheck disable=SC2034  # consumed by sourced generate-config.sh
  SHUTDOWN_CMD="/usr/local/bin/nut-shutdown.sh"
  printf 'level=info msg="host shutdown enabled via D-Bus on battery critical"\n' >&2
else
  printf 'level=info msg="host shutdown disabled; FSD will only log to stderr"\n' >&2
fi

# Normalize COMMS_WATCHDOG case-insensitively, mirroring SHUTDOWN_ON_BATTERY_CRITICAL.
# Truthy spellings (true/1/yes/on) enable USB comms recovery; fail loud on an
# unrecognized value rather than silently disabling the watchdog.
COMMS_WATCHDOG=$(normalize_bool COMMS_WATCHDOG "$COMMS_WATCHDOG") || exit 1

# Canonicalize watchdog integers to base-10 before they reach $(( )) in lifecycle.sh
# (leading zeros are otherwise parsed as octal — see strip_leading_zeros).
COMMS_CHECK_INTERVAL=$(strip_leading_zeros "$COMMS_CHECK_INTERVAL")
COMMS_RECOVERY_TIMEOUT=$(strip_leading_zeros "$COMMS_RECOVERY_TIMEOUT")
COMMS_FAST_RETRIES=$(strip_leading_zeros "$COMMS_FAST_RETRIES")
COMMS_BACKOFF_FACTOR=$(strip_leading_zeros "$COMMS_BACKOFF_FACTOR")
DBUS_PROBE_INTERVAL=$(strip_leading_zeros "$DBUS_PROBE_INTERVAL")

# ---------------------------------------------------------------------------
# Generate NUT config files (from generate-config.sh)
# ---------------------------------------------------------------------------
generate_all_configs

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
chown -R root:nut /etc/nut
find /etc/nut -type d -exec chmod 750 {} +
find /etc/nut -type f -exec chmod 640 {} +
if usb_bus_required; then
  if chgrp -R nut /dev/bus/usb 2>/dev/null; then
    printf 'level=info msg="chgrp nut:/dev/bus/usb applied (host device nodes)"\n' >&2
  else
    printf 'level=warn msg="could not chgrp nut on /dev/bus/usb; driver will still open the device as root before dropping to nut"\n' >&2
  fi
else
  printf 'level=info msg="non-USB transport; skipping USB bus group setup" driver=%s port=%s\n' "$UPS_DRIVER" "$UPS_PORT" >&2
fi

# ---------------------------------------------------------------------------
# Start NUT services with signal handling
# ---------------------------------------------------------------------------

# Background comms-watchdog PID (empty until started below). stop_watchdog is
# safe to call before the watchdog starts and after it has exited.
WATCHDOG_PID=""
stop_watchdog() {
  [ -n "${WATCHDOG_PID:-}" ] || return 0
  kill "$WATCHDOG_PID" 2>/dev/null || true
  # Reap the watchdog subshell before the caller runs stop_services. Note: a SIGTERM
  # that lands while the subshell is mid-`upsdrvctl start` kills the subshell
  # immediately and orphans that child, so `wait` reaps the subshell but the orphan
  # may briefly race stop_services' `upsdrvctl stop`. Harmless at teardown —
  # next boot clears stale pidfiles.
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=""
}

# Background D-Bus poweroff-path probe PID (empty unless host shutdown is
# enabled). Same lifecycle contract as stop_watchdog above.
DBUS_PROBE_PID=""
stop_dbus_probe() {
  [ -n "${DBUS_PROBE_PID:-}" ] || return 0
  kill "$DBUS_PROBE_PID" 2>/dev/null || true
  wait "$DBUS_PROBE_PID" 2>/dev/null || true
  DBUS_PROBE_PID=""
}

# Signal handler: clean up, then exit 0 (signal-initiated stop).
# shellcheck disable=SC2317,SC2329 # invoked via trap; shellcheck cannot see the call site
graceful_shutdown() {
  printf 'level=info msg="received shutdown signal"\n' >&2
  stop_watchdog
  stop_dbus_probe
  stop_services
  exit 0
}
trap graceful_shutdown TERM INT QUIT HUP

printf 'level=info msg="starting NUT services" ups=%s driver=%s port=%s listen=%s:%s\n' \
  "$UPS_NAME" "$UPS_DRIVER" "$UPS_PORT" "$API_ADDRESS" "$API_PORT" >&2

# Clear stale driver/daemon PID files from a previous container lifecycle.
# /var/run/nut lives in the container's writable layer, so PID files from a
# crashed or force-killed previous run survive a `docker restart` and cause
# upsdrvctl to trigger its "Duplicate driver instance detected" path, which
# kills the freshly started driver seconds after launch. We own this
# directory and no other process can legitimately hold these PIDs at boot.
if find /var/run/nut -maxdepth 1 -name '*.pid' -type f 2>/dev/null | grep -q .; then
  printf 'level=info msg="clearing stale NUT PID files from previous lifecycle" path=/var/run/nut\n' >&2
  find /var/run/nut -maxdepth 1 -name '*.pid' -type f -delete
fi

# Clear a stale POWERDOWNFLAG (killpower) from a previous lifecycle. upsmon
# creates it on FSD; /var/run/nut is the writable layer so it survives a
# `docker restart`, and nothing in this container consumes it (host poweroff is
# via D-Bus, not the NUT kill-power path). A latched flag would otherwise make
# the comms watchdog stand down indefinitely (see restart_ups_driver), so clear
# it at a fresh start.
if [ -e /var/run/nut/killpower ]; then
  printf 'level=info msg="clearing stale killpower flag from previous lifecycle" path=/var/run/nut/killpower\n' >&2
  rm -f /var/run/nut/killpower
fi

printf 'level=info msg="starting upsdrvctl"\n' >&2
/usr/sbin/upsdrvctl start
# NUT drivers write /var/run/nut/<driver>-<ups>.pid on successful start.
wait_for_pidfile "UPS driver" "$(driver_pidfile)" || {
  stop_services
  exit 1
}

printf 'level=info msg="starting upsd"\n' >&2
/usr/sbin/upsd
wait_for_pidfile "upsd" "/var/run/nut/upsd.pid" || {
  stop_services
  exit 1
}

# Run upsmon in the background so the trap can fire
printf 'level=info msg="starting upsmon"\n' >&2
/usr/sbin/upsmon -F &
UPSMON_PID=$!

printf 'level=info msg="NUT services started successfully"\n' >&2

# Start the USB comms watchdog (recovers from UPS-initiated re-enumeration).
# A sub-second interval would busy-loop, so treat <1s as "disabled".
if [ "$COMMS_WATCHDOG" = "true" ] && [ "$COMMS_CHECK_INTERVAL" -ge 1 ]; then
  printf 'level=info msg="starting comms watchdog" interval=%ss recovery_timeout=%ss\n' \
    "$COMMS_CHECK_INTERVAL" "$COMMS_RECOVERY_TIMEOUT" >&2
  comms_watchdog &
  WATCHDOG_PID=$!
else
  printf 'level=info msg="comms watchdog disabled"\n' >&2
fi

# Start the D-Bus poweroff-path probe (host shutdown enabled only) so a D-Bus
# mount that breaks after boot alerts in advance instead of failing during the
# forced shutdown itself.
if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" = "true" ]; then
  if [ "$DBUS_PROBE_INTERVAL" -ge 1 ]; then
    printf 'level=info msg="starting D-Bus poweroff-path probe" interval=%ss\n' "$DBUS_PROBE_INTERVAL" >&2
    dbus_liveness_probe &
    DBUS_PROBE_PID=$!
  else
    printf 'level=info msg="D-Bus poweroff-path probe disabled"\n' >&2
  fi
fi

# Wait for upsmon — propagate its exit code so Docker restart policies and
# log-based alerting see the real failure. stop_services is idempotent and
# does not dictate the exit code; the caller decides.
set +e
wait "$UPSMON_PID"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  printf 'level=info msg="upsmon exited cleanly" rc=0\n' >&2
else
  printf 'level=error msg="upsmon exited unexpectedly" rc=%d\n' "$rc" >&2
fi
stop_watchdog
stop_dbus_probe
stop_services
exit "$rc"
