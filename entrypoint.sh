#!/bin/sh
set -eu

# shellcheck source-path=SCRIPTDIR source=validate.sh
. /usr/local/bin/validate.sh
# shellcheck source-path=SCRIPTDIR source=generate-config.sh
. /usr/local/bin/generate-config.sh
# shellcheck source-path=SCRIPTDIR source=lifecycle.sh
. /usr/local/bin/lifecycle.sh
# shellcheck source-path=SCRIPTDIR source=secrets.sh
. /usr/local/bin/secrets.sh

# Reclaim artifacts a crashed previous run left in the writable layer, before
# any new temp/config write (a late cleanup is unreachable under set -e
# exactly when needed most).

# stale_nut_pid_paths: every reserved *.pid path in /var/run/nut. Matches every
# object type, not just files. upsdrvctl overwrites a leftover FILE only when the
# PID it names is dead in THIS namespace (warns, then overwrites — v2.8.5
# drivers/main.c:2891-2935); a `docker restart` keeps the writable layer while PIDs
# restart near 1, so a recorded PID can be live and unrelated in the new namespace,
# and upsdrvctl reports "Duplicate driver instance detected" instead. A symlink/
# FIFO/socket/directory redirects or blocks the root daemon's pidfile write, whose
# fopen has no O_NOFOLLOW (common/common.c:2180).
stale_nut_pid_paths() {
  find /var/run/nut -maxdepth 1 -name '*.pid' "$@" 2>/dev/null || true
}
# `head -c 1`/`-c 513` below bound the BYTES PID 1 retains from this nut-writable
# directory (513, not 512: log_value marks truncation only above 512 — see
# capture_head); the scan itself is unbounded and cheap. The re-scan re-checks the
# pathname postcondition because BusyBox find exits 0 even when a directory at a
# *.pid path survives -delete.
if [ -n "$(stale_nut_pid_paths | head -c 1)" ]; then
  printf 'level=info msg="clearing stale NUT PID paths from previous lifecycle" path=/var/run/nut\n' >&2
  stale_nut_pid_paths -delete
  _stale_pids=$(stale_nut_pid_paths | head -c 513)
  if [ -n "$_stale_pids" ]; then
    printf 'level=error msg="failed to clear a stale NUT PID path; refusing to start" path=/var/run/nut surviving="%s"\n' \
      "$(log_value "$_stale_pids")" >&2
    exit 1
  fi
fi

# Clear temps leaked by a kill between mktemp and rm -f/mv. The secrets
# directory is app-owned; in operator-mountable /etc/nut cleanup is limited to the
# names this app stages: the generated configs, plus the two TLS working copies
# named through the constants that own their destinations so a rename carries.
_clt_etc=''
for _clt_name in $NUT_STAGED_CONFIGS "${TLS_CERT_RUNTIME##*/}" "${TLS_CERT_MOUNTED_RUNTIME##*/}"; do
  _clt_etc="$_clt_etc /etc/nut/$_clt_name.tmp.*"
done
# Word splitting expands the staged-config inventory into distinct rm arguments.
# shellcheck disable=SC2086
if ! _clt_err=$(rm -f "$WD_RESTART_CAPTURE_PREFIX".* "$STOP_CMD_CAPTURE_PREFIX".* \
  /var/run/nut-secrets/*.tmp.* $_clt_etc 2>&1); then
  printf 'level=warn msg="could not remove a crash-leaked temp file from a previous lifecycle; continuing" err="%s"\n' \
    "$(log_value "$_clt_err")" >&2
fi

# Clear a stale POWERDOWNFLAG (killpower) from a previous lifecycle. upsmon
# unlinks a flag it wrote itself at startup (v2.8.5 clients/upsmon.c:4140-4142);
# a flag WITHOUT the magic string it only disables (:3375-3391), and
# restart_ups_driver stands down on a bare `-e` test, so that residue would
# disarm comms recovery for the container's life.
if [ -e "$POWERDOWNFLAG_FILE" ]; then
  printf 'level=info msg="clearing stale killpower flag from previous lifecycle" path=%s\n' "$POWERDOWNFLAG_FILE" >&2
  rm -f "$POWERDOWNFLAG_FILE" || {
    printf 'level=error msg="failed to clear the stale killpower flag; refusing to start" path=%s\n' "$POWERDOWNFLAG_FILE" >&2
    exit 1
  }
fi

# Must precede the := defaults below: an LF-only value (env-file artifact) is
# non-empty raw, so it would dodge the documented default and then fail
# validation instead of defaulting. See validate.sh canonicalize_validated_values.
canonicalize_validated_values

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
# STARTTLS on the upsd listener (opportunistic; legacy clients that never
# request it keep talking cleartext). See resolve_tls_cert (secrets.sh).
: "${API_TLS:=true}"
# The seven timing directives below restate NUT v2.8.5's own defaults
# (clients/upsmon.c:59-118) instead of leaving them unset: pinning keeps the
# FSD sequence and the notification intervals deterministic across a NUT bump,
# and validate.sh's DEADTIME >= max(POLLFREQ, POLLFREQALERT) check needs values.
: "${POLLFREQ:=5}"
: "${POLLFREQALERT:=5}"
: "${DEADTIME:=15}"
: "${FINALDELAY:=5}"
: "${HOSTSYNC:=15}"
: "${NOCOMMWARNTIME:=300}"
: "${RBWARNTIME:=43200}"

# USB comms-recovery watchdog cadence (mechanism: lifecycle.sh comms_watchdog;
# bus prerequisites: README "USB hotplug & comms recovery").
: "${COMMS_WATCHDOG:=true}"
: "${COMMS_CHECK_INTERVAL:=15}"
: "${COMMS_RECOVERY_TIMEOUT:=90}"
# Two-stage recovery cadence, stage 2 backing off by COMMS_BACKOFF_FACTOR —
# see lifecycle.sh comms_watchdog.
: "${COMMS_FAST_RETRIES:=3}"
: "${COMMS_BACKOFF_FACTOR:=5}"

# Host shutdown support via D-Bus (requires /run/dbus mount)
: "${SHUTDOWN_ON_BATTERY_CRITICAL:=false}"
# Poweroff-path liveness probe cadence in seconds (0 disables); only runs when
# SHUTDOWN_ON_BATTERY_CRITICAL=true — see lifecycle.sh dbus_liveness_probe.
: "${DBUS_PROBE_INTERVAL:=300}"

# ---------------------------------------------------------------------------
# Password resolution (from secrets.sh)
# ---------------------------------------------------------------------------
decide_user_overrides
if ! user_override_present upsd.users; then
  resolve_admin_password
fi
# The internal upsmon credential only exists when both upsd.users and
# upsmon.conf are generated (generate-config.sh); with an override mounted for
# either file, the generated half uses the legacy API pair instead.
if local_upsmon_credential_active; then
  resolve_local_upsmon_password
fi
withdraw_unused_credential_caches

warn_weak_api_password

# ---------------------------------------------------------------------------
# Input validation (from validate.sh)
# ---------------------------------------------------------------------------
run_validations

# ---------------------------------------------------------------------------
# USB device validation (when the USB bus is required: every USB transport,
# plus a dual-mode driver using `auto` or a /dev/bus/usb node; see
# usb_bus_required)
# ---------------------------------------------------------------------------
if usb_bus_required && [ ! -d /dev/bus/usb ]; then
  printf 'level=error msg="/dev/bus/usb not found; this app requires it for USB drivers and treats drivers not categorised as serial-only or USB as requiring it while UPS_PORT is auto; bind-mount the host /dev/bus/usb directory into the container or set UPS_PORT to the serial device node" driver=%s port=%s\n' \
    "$UPS_DRIVER" "$UPS_PORT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine SHUTDOWNCMD
# ---------------------------------------------------------------------------
# Default: noop shutdown (log-only on FSD). See nut-shutdown-noop.sh for why
# a script rather than an inlined printf.
export SHUTDOWN_ON_BATTERY_CRITICAL
SHUTDOWN_CMD="/usr/local/bin/nut-shutdown-noop.sh"

# Normalize the toggle (accepted spellings: normalize_bool, validate.sh)
# so a non-canonical spelling ARMS host shutdown instead of silently
# getting the disabled default. An unrecognized value is a
# misconfiguration on a safety-critical knob: fail loudly rather than
# degrading quietly to off.
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
  printf 'level=info msg="host shutdown disabled; an FSD logs and then ends this container through upsmon exit, leaving the restart policy to decide"\n' >&2
fi

# Normalize COMMS_WATCHDOG, mirroring SHUTDOWN_ON_BATTERY_CRITICAL: fail
# loud on an unrecognized value rather than silently disabling the watchdog.
COMMS_WATCHDOG=$(normalize_bool COMMS_WATCHDOG "$COMMS_WATCHDOG") || exit 1

# Normalize API_TLS the same way; a security toggle must not silently fall
# back to either mode.
API_TLS=$(normalize_bool API_TLS "$API_TLS") || exit 1

# Canonicalize watchdog integers to base-10 before $(( )) in lifecycle.sh
# (leading zeros parse as octal — see strip_leading_zeros).
COMMS_CHECK_INTERVAL=$(strip_leading_zeros "$COMMS_CHECK_INTERVAL")
COMMS_RECOVERY_TIMEOUT=$(strip_leading_zeros "$COMMS_RECOVERY_TIMEOUT")
COMMS_FAST_RETRIES=$(strip_leading_zeros "$COMMS_FAST_RETRIES")
COMMS_BACKOFF_FACTOR=$(strip_leading_zeros "$COMMS_BACKOFF_FACTOR")
DBUS_PROBE_INTERVAL=$(strip_leading_zeros "$DBUS_PROBE_INTERVAL")

# TLS certificate provisioning. Runs whenever API_TLS=true, even with a
# mounted upsd.conf.user: the override's TLS directives may point CERTFILE at
# either path, so the cert must exist either way. Must precede
# generate_all_configs, which writes the resolved TLS_CERT_PATH.
if [ "$API_TLS" = "true" ]; then
  resolve_tls_cert || exit 1
  if user_override_present upsd.conf; then
    printf 'level=info msg="TLS certificate provisioned; mounted upsd.conf.user owns the TLS directives, and upsd serves this certificate only when the override names it in CERTFILE"\n' >&2
  fi
else
  if user_override_present upsd.conf; then
    printf 'level=info msg="API_TLS=false: no certificate provisioned; mounted upsd.conf.user owns the TLS directives (an override referencing the self-signed PEM needs API_TLS=true)"\n' >&2
  else
    printf 'level=info msg="TLS disabled (API_TLS=false); upsd serves cleartext only"\n' >&2
  fi
fi

# Always, even with an upsd.conf.user override mounted:
# resolve_tls_cert provisions exactly one source per boot, so any unselected
# working copy is withdrawn key material from a previous lifecycle. Withdrawing
# it makes an override naming the wrong path fail visibly at upsd startup
# instead of silently serving stale key material.
reconcile_tls_working_copies

# ---------------------------------------------------------------------------
# Generate NUT config files (from generate-config.sh)
# ---------------------------------------------------------------------------
generate_all_configs

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
if usb_bus_required; then
  if _chg_err=$(chgrp -R nut /dev/bus/usb 2>&1); then
    printf 'level=info msg="chgrp nut:/dev/bus/usb applied (host device nodes)"\n' >&2
  else
    printf 'level=warn msg="could not chgrp nut on /dev/bus/usb; generated configuration starts the driver as nut, so it may be unable to open the device; NUT will report the failure" err="%s"\n' \
      "$(log_value "$_chg_err")" >&2
  fi
else
  printf 'level=info msg="non-USB transport; skipping USB bus group setup" driver=%s port=%s\n' "$UPS_DRIVER" "$UPS_PORT" >&2
fi

# ---------------------------------------------------------------------------
# Start NUT services with signal handling
# ---------------------------------------------------------------------------

# stop_bg_pid: kill and reap one background loop by PID; no-op for an empty
# PID.
stop_bg_pid() {
  [ -n "$1" ] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

WATCHDOG_PID=""
DBUS_PROBE_PID=""

# teardown_all: the one teardown sequence every exit path shares - reap both
# background loops, then stop the NUT daemons. Exit codes stay with the callers.
teardown_all() {
  trap '' TERM INT QUIT HUP
  # Fail-soft so diagnostics cannot skip any stop control.
  set +e
  stop_bg_pid "${WATCHDOG_PID:-}"
  stop_bg_pid "${DBUS_PROBE_PID:-}"
  stop_services
}

# shellcheck disable=SC2317,SC2329 # invoked via trap; shellcheck cannot see the call site
graceful_shutdown() {
  printf 'level=info msg="received shutdown signal"\n' >&2 || :
  teardown_all
  exit 0
}
trap graceful_shutdown TERM INT QUIT HUP

printf 'level=info msg="starting NUT services" ups=%s driver=%s port=%s listen=%s:%s\n' \
  "$UPS_NAME" "$UPS_DRIVER" "$UPS_PORT" "$API_ADDRESS" "$API_PORT" >&2

# start_nut_daemon LABEL TIMEOUT CMD...: start one NUT daemon bounded by
# `timeout -k 5 TIMEOUT` (-k 5 hard-kills a child that ignores TERM at
# expiry). Background + wait so a SIGTERM during boot interrupts `wait` and
# runs graceful_shutdown at once rather than being deferred up to the full
# timeout. On failure: log, stop services, exit 1.
start_nut_daemon() {
  _sd_label="$1"
  _sd_timeout="$2"
  shift 2
  printf 'level=info msg="starting %s"\n' "$_sd_label" >&2
  timeout -k 5 "$_sd_timeout" "$@" &
  if wait "$!"; then
    :
  else
    _sd_rc=$?
    printf 'level=error msg="%s start failed or timed out at boot" rc=%d\n' "$_sd_label" "$_sd_rc" >&2 || :
    teardown_all
    exit 1
  fi
}

# 90s outer bound on upsdrvctl wedging, sized above NUT's own default
# maxstartdelay (75s). Not redundant with it: at v2.8.5 a maxstartdelay of 0 or
# below skips the alarm() and then blocks in waitpid() forever
# (drivers/upsdrvctl.c:879-906), so a mounted ups.conf.user can remove NUT's
# bound entirely, or raise it past this one (README, custom config override).
start_nut_daemon "upsdrvctl" 90 /usr/sbin/upsdrvctl start
# NUT drivers write /var/run/nut/<driver>-<ups>.pid on successful start.
wait_for_pidfile "UPS driver" "$(driver_pidfile)" "$(driver_binary)" || {
  teardown_all
  exit 1
}

start_nut_daemon "upsd" 30 /usr/sbin/upsd
wait_for_pidfile "upsd" "/var/run/nut/upsd.pid" /usr/sbin/upsd || {
  teardown_all
  exit 1
}

# Run upsmon in the background so the trap can fire
printf 'level=info msg="starting upsmon"\n' >&2
/usr/sbin/upsmon -F &
UPSMON_PID=$!

printf 'level=info msg="NUT services started; supervising upsmon"\n' >&2

# Start the comms watchdog (any transport; motivated by USB re-enumeration).
if [ "$COMMS_WATCHDOG" = "true" ] && [ "$COMMS_CHECK_INTERVAL" -ge 1 ]; then
  printf 'level=info msg="starting comms watchdog" interval=%ss recovery_timeout=%ss\n' \
    "$COMMS_CHECK_INTERVAL" "$COMMS_RECOVERY_TIMEOUT" >&2 || :
  comms_watchdog &
  WATCHDOG_PID=$!
else
  printf 'level=info msg="comms watchdog disabled" watchdog=%s interval=%ss\n' \
    "$COMMS_WATCHDOG" "$COMMS_CHECK_INTERVAL" >&2
fi

# Start the D-Bus poweroff-path probe (host shutdown enabled only) so a
# broken mount alerts in advance instead of failing during a forced shutdown.
if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" = "true" ]; then
  if [ "$DBUS_PROBE_INTERVAL" -ge 1 ]; then
    printf 'level=info msg="starting D-Bus poweroff-path probe" interval=%ss\n' "$DBUS_PROBE_INTERVAL" >&2 || :
    dbus_liveness_probe &
    DBUS_PROBE_PID=$!
  else
    printf 'level=info msg="D-Bus poweroff-path probe disabled"\n' >&2
  fi
fi

# ---------------------------------------------------------------------------
# Supervise upsmon and upsd
# ---------------------------------------------------------------------------
# `upsc -l` only lists configured UPSes, so the probe succeeds while driver
# data is stale — it isolates upsd protocol failure from the freshness signal
# the comms watchdog acts on. 4x15s ~= 60s of sustained failure exits before
# the watchdog's first driver bounce (COMMS_RECOVERY_TIMEOUT default 90s).
readonly UPSD_PROBE_INTERVAL=15
readonly UPSD_PROBE_MAX_FAILURES=4

# upsmon exiting is the fatal-child signal. A sustained upsd failure is also
# fatal: upsmon survives it (reporting NOCOMM) and the comms watchdog can only
# bounce the driver, which cannot repair upsd — without this exit the
# container would stay running-but-unhealthy indefinitely.
upsd_failures=0
while kill -0 "$UPSMON_PID" 2>/dev/null; do
  # Sleep in the background and `wait` on it: `wait` is where POSIX guarantees
  # a trapped signal interrupts immediately, so SIGTERM runs graceful_shutdown
  # at once instead of after up to 15s of foreground sleep. `|| true` because
  # the signal-interrupted wait must not kill PID 1 under set -e.
  sleep "$UPSD_PROBE_INTERVAL" &
  wait "$!" || true
  kill -0 "$UPSMON_PID" 2>/dev/null || break
  # Both background workers are supervised here too: an external SIGKILL (a
  # host OOM kill) takes a documented capability away for the container's
  # life, with upsd still answering and the healthcheck still green. The
  # respawn is fresh: both loops keep state in process-local variables, so the
  # cadence restarts from zero.
  if [ -n "${WATCHDOG_PID:-}" ] && ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    _wd_rc=0
    wait "$WATCHDOG_PID" 2>/dev/null || _wd_rc=$?
    printf 'level=error msg="comms watchdog exited; starting a fresh one, whose recovery cadence restarts from zero" rc=%d\n' "$_wd_rc" >&2 || :
    comms_watchdog &
    WATCHDOG_PID=$!
  fi
  if [ -n "${DBUS_PROBE_PID:-}" ] && ! kill -0 "$DBUS_PROBE_PID" 2>/dev/null; then
    _dp_rc=0
    wait "$DBUS_PROBE_PID" 2>/dev/null || _dp_rc=$?
    printf 'level=error msg="D-Bus poweroff-path probe exited; starting a fresh one, whose unreachable/recovered state restarts from zero" rc=%d\n' "$_dp_rc" >&2 || :
    dbus_liveness_probe &
    DBUS_PROBE_PID=$!
  fi
  if upsd_responsive; then
    upsd_failures=0
  else
    upsd_failures=$((upsd_failures + 1))
    if [ "$upsd_failures" -ge "$UPSD_PROBE_MAX_FAILURES" ]; then
      printf 'level=error msg="upsd unresponsive; stopping services and exiting so the restart policy rebuilds the stack" consecutive_failures=%d probe_interval=%ss probe=%s\n' \
        "$upsd_failures" "$UPSD_PROBE_INTERVAL" "$(upsd_probe_host):${API_PORT}" >&2 || :
      teardown_all
      exit 1
    fi
    printf 'level=warn msg="upsd not responding to protocol probe" consecutive_failures=%d threshold=%d probe=%s\n' \
      "$upsd_failures" "$UPSD_PROBE_MAX_FAILURES" "$(upsd_probe_host):${API_PORT}" >&2
  fi
done

# Reap upsmon and propagate its exit code so restart policies and log-based
# alerting see the real failure. Status 0 is not a clean stop: it is an
# executed SHUTDOWNCMD (upsmon's privileged parent, clients/upsmon.c runparent).
rc=0
wait "$UPSMON_PID" || rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'level=warn msg="upsmon parent exited after running SHUTDOWNCMD; a forced shutdown (FSD) was executed" rc=0\n' >&2 || :
else
  printf 'level=error msg="upsmon exited unexpectedly" rc=%d\n' "$rc" >&2 || :
fi
teardown_all
exit "$rc"
