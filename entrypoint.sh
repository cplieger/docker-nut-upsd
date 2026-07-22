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
# STARTTLS on the upsd listener (opportunistic: clients that never request it
# keep talking cleartext, so legacy clients are unaffected). Serves an
# operator-mounted /etc/nut/upsd.pem, else a boot-generated self-signed cert
# — see resolve_tls_cert (password.sh).
: "${API_TLS:=true}"
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
# The internal upsmon credential only exists when both upsd.users and
# upsmon.conf are generated (see the credential-topology block in
# generate-config.sh); with an override mounted for either file, the
# generated half uses the legacy API pair and no internal secret is needed.
if local_upsmon_credential_active; then
  resolve_local_upsmon_password
fi

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

# Normalize API_TLS the same way. Fail loud on an unrecognized value: a
# security toggle that quietly fell back to either mode would betray whichever
# posture the operator thought they configured.
API_TLS=$(normalize_bool API_TLS "$API_TLS") || exit 1

# Canonicalize watchdog integers to base-10 before they reach $(( )) in lifecycle.sh
# (leading zeros are otherwise parsed as octal — see strip_leading_zeros).
COMMS_CHECK_INTERVAL=$(strip_leading_zeros "$COMMS_CHECK_INTERVAL")
COMMS_RECOVERY_TIMEOUT=$(strip_leading_zeros "$COMMS_RECOVERY_TIMEOUT")
COMMS_FAST_RETRIES=$(strip_leading_zeros "$COMMS_FAST_RETRIES")
COMMS_BACKOFF_FACTOR=$(strip_leading_zeros "$COMMS_BACKOFF_FACTOR")
DBUS_PROBE_INTERVAL=$(strip_leading_zeros "$DBUS_PROBE_INTERVAL")

# ---------------------------------------------------------------------------
# TLS certificate provisioning (from password.sh)
# ---------------------------------------------------------------------------
# Runs whenever API_TLS=true, even when a mounted upsd.conf.user will skip
# upsd.conf generation: the override owns the TLS directives, and its author
# may point CERTFILE at either the mounted or the self-signed path (README),
# so the cert must exist either way. Must precede generate_all_configs, which
# writes the resolved TLS_CERT_PATH into upsd.conf.
if [ "$API_TLS" = "true" ]; then
  resolve_tls_cert || exit 1
else
  if [ -e /etc/nut/upsd.conf.user ]; then
    printf 'level=info msg="API_TLS=false: no certificate provisioned; mounted upsd.conf.user owns the TLS directives (an override referencing the self-signed PEM needs API_TLS=true)"\n' >&2
  else
    printf 'level=info msg="TLS disabled (API_TLS=false); upsd serves cleartext only"\n' >&2
  fi
fi

# ---------------------------------------------------------------------------
# Generate NUT config files (from generate-config.sh)
# ---------------------------------------------------------------------------
generate_all_configs

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
# upsd.pem (the operator-mounted TLS PEM) is excluded like the *.user
# overrides: it is typically a read-only bind mount, where chown/chmod fail
# with EROFS and would abort the boot under set -e. resolve_tls_cert
# (password.sh) already handled its permissions best-effort.
find /etc/nut ! -name '*.user' ! -name upsd.pem -exec chown root:nut {} +
find /etc/nut -type d ! -name '*.user' ! -name upsd.pem -exec chmod 750 {} +
find /etc/nut -type f ! -name '*.user' ! -name upsd.pem -exec chmod 640 {} +
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

# stop_bg_pid: kill and reap one background loop by PID; no-op for an empty
# PID (not started / already stopped).
stop_bg_pid() {
  [ -n "$1" ] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# Background comms-watchdog PID (empty until started below). stop_watchdog is
# safe to call before the watchdog starts and after it has exited.
WATCHDOG_PID=""
stop_watchdog() {
  # Reap the watchdog subshell before the caller runs stop_services. Note: a SIGTERM
  # that lands while the subshell is mid-`upsdrvctl start` kills the subshell
  # immediately and orphans that child, so `wait` reaps the subshell but the orphan
  # may briefly race stop_services' `upsdrvctl stop`. Harmless at teardown —
  # next boot clears stale pidfiles.
  stop_bg_pid "${WATCHDOG_PID:-}"
  WATCHDOG_PID=""
}

# Background D-Bus poweroff-path probe PID (empty unless host shutdown is
# enabled). Same lifecycle contract as stop_watchdog above.
DBUS_PROBE_PID=""
stop_dbus_probe() {
  stop_bg_pid "${DBUS_PROBE_PID:-}"
  DBUS_PROBE_PID=""
}

# teardown_all: the one teardown sequence every exit path shares (signal
# trap, upsd-unresponsive exit, upsmon-exit path) - reap both background
# loops, then stop the NUT daemons. Exit codes stay with the callers.
teardown_all() {
  stop_watchdog
  stop_dbus_probe
  stop_services
}

# Signal handler: clean up, then exit 0 (signal-initiated stop).
# shellcheck disable=SC2317,SC2329 # invoked via trap; shellcheck cannot see the call site
graceful_shutdown() {
  printf 'level=info msg="received shutdown signal"\n' >&2
  teardown_all
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

# Clear temp files leaked by a kill that landed between mktemp and rm -f/mv
# in lifecycle.sh's capture helpers (start_recovered_driver, stop_nut_cmd) or
# the password/TLS-certificate resolvers (password.sh); they live in the
# writable layer and would otherwise accumulate across container restarts.
# Safe here: this run's own password and TLS temps were already renamed or
# removed by the resolve_* calls above, and the capture temps are created
# later.
rm -f /var/run/nut-secrets/wd-restart.* /var/run/nut-secrets/stop-cmd.* \
  /var/run/nut-secrets/admin_password.tmp.* \
  /var/run/nut-secrets/local_upsmon_password.tmp.* \
  /var/run/nut-secrets/upsd-selfsigned.pem.tmp.* \
  /etc/nut/upsd-selfsigned.pem.tmp.*

# Clear a stale POWERDOWNFLAG (killpower) from a previous lifecycle. upsmon
# creates it on FSD; /var/run/nut-secrets is the writable layer so it survives
# a `docker restart`, and nothing in this container consumes it (host poweroff
# is via D-Bus, not the NUT kill-power path). A latched flag would otherwise
# make the comms watchdog stand down indefinitely (see restart_ups_driver), so
# clear it at a fresh start. The flag lives in the root-only nut-secrets dir
# so the nut user cannot plant it (see generate-config.sh).
if [ -e /var/run/nut-secrets/killpower ]; then
  printf 'level=info msg="clearing stale killpower flag from previous lifecycle" path=/var/run/nut-secrets/killpower\n' >&2
  rm -f /var/run/nut-secrets/killpower
fi

# start_nut_daemon LABEL TIMEOUT CMD...: start one NUT daemon bounded by
# `timeout -k 5 TIMEOUT` (hard bound past NUT's own start delays; -k 5 hard-kills
# a child that ignores TERM at expiry). Background + wait (mirroring the
# supervision loop's sleep) so a SIGTERM during boot interrupts `wait` and runs
# graceful_shutdown at once instead of being deferred for up to the full
# timeout — past Docker's 10s stop budget. On failure: log, stop services,
# exit 1.
start_nut_daemon() {
  _sd_label="$1"
  _sd_timeout="$2"
  shift 2
  printf 'level=info msg="starting %s"\n' "$_sd_label" >&2
  timeout -k 5 "$_sd_timeout" "$@" &
  if wait $!; then
    :
  else
    _sd_rc=$?
    printf 'level=error msg="%s start failed or timed out at boot" rc=%d\n' "$_sd_label" "$_sd_rc" >&2
    stop_services
    exit 1
  fi
}

# timeout 90 > NUT's 75s default maxstartdelay (matches the watchdog's restart
# path), so it only fires on a genuine wedge.
start_nut_daemon "upsdrvctl" 90 /usr/sbin/upsdrvctl start
# NUT drivers write /var/run/nut/<driver>-<ups>.pid on successful start.
wait_for_pidfile "UPS driver" "$(driver_pidfile)" "$(driver_binary)" || {
  stop_services
  exit 1
}

start_nut_daemon "upsd" 30 /usr/sbin/upsd
wait_for_pidfile "upsd" "/var/run/nut/upsd.pid" /usr/sbin/upsd || {
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

# ---------------------------------------------------------------------------
# Supervise upsmon and upsd
# ---------------------------------------------------------------------------
# upsd responsiveness probe cadence and consecutive-failure threshold. The
# probe (`upsc -l`) only asks upsd to list its configured UPSes, so it
# succeeds even while driver data is stale — it isolates upsd protocol
# failure from the data-freshness signal the comms watchdog acts on.
# 4 x 15s ~= 60s of sustained failure exits BEFORE the comms watchdog's first
# driver bounce (COMMS_RECOVERY_TIMEOUT, default 90s), so a dead upsd cannot
# strand the container in endless driver-restart churn that never repairs
# the actual failed dependency.
readonly UPSD_PROBE_INTERVAL=15
readonly UPSD_PROBE_MAX_FAILURES=4

# Wait for upsmon while probing upsd. upsmon exiting remains the fatal-child
# signal (loop breaks, exit code propagated below). A sustained upsd failure
# is ALSO fatal: upsmon survives it (reporting NOCOMM) and the comms watchdog
# can only bounce the driver, which cannot repair upsd — without this exit
# the container would stay running-but-unhealthy indefinitely. Exiting
# non-zero hands recovery to the container restart policy, which rebuilds
# the full stack.
upsd_failures=0
while kill -0 "$UPSMON_PID" 2>/dev/null; do
  # Sleep in the background and `wait` on it: `wait` is the one place POSIX
  # guarantees a trapped signal interrupts immediately, so `docker stop`'s
  # SIGTERM runs graceful_shutdown at once instead of after up to 15s of
  # foreground sleep (past Docker's default 10s stop budget). `|| true`: the
  # signal-interrupted wait must not kill PID 1 under set -e.
  sleep "$UPSD_PROBE_INTERVAL" &
  wait $! || true
  kill -0 "$UPSMON_PID" 2>/dev/null || break
  if upsd_responsive; then
    upsd_failures=0
  else
    upsd_failures=$((upsd_failures + 1))
    if [ "$upsd_failures" -ge "$UPSD_PROBE_MAX_FAILURES" ]; then
      printf 'level=error msg="upsd unresponsive; stopping services and exiting so the restart policy rebuilds the stack" consecutive_failures=%d probe_interval=%ss\n' \
        "$upsd_failures" "$UPSD_PROBE_INTERVAL" >&2
      teardown_all
      exit 1
    fi
    printf 'level=warn msg="upsd not responding to protocol probe" consecutive_failures=%d threshold=%d\n' \
      "$upsd_failures" "$UPSD_PROBE_MAX_FAILURES" >&2
  fi
done

# Reap upsmon and propagate its exit code so Docker restart policies and
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
teardown_all
exit "$rc"
