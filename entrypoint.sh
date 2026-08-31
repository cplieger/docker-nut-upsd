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
# Prior-lifecycle reclamation
# ---------------------------------------------------------------------------
# The blocks below clear artifacts a crashed or force-killed previous run
# left in the writable layer. They run FIRST — before password/TLS resolution
# and config generation — so crash-leaked files are reclaimed before any new
# temp or generated-config write could hit exhausted blocks or inodes (a late
# cleanup is unreachable under set -e exactly when it is needed most). Every
# path constant used here is a readonly top-level definition in the helpers
# sourced above, and no current-run temp can exist yet.

# stale_nut_pid_paths [FIND_ACTION...]: every reserved *.pid path in the
# nut-writable /var/run/nut. One left by a crashed run makes upsdrvctl kill the
# freshly started driver ("Duplicate driver instance detected"). Matches EVERY
# object type, not just regular files: a symlink, FIFO, socket or directory
# planted there by the nut user survives -type f and obstructs — or, followed,
# redirects — the root daemon's later pidfile write. `|| true`: a find failure
# must not abort PID 1 under set -e.
stale_nut_pid_paths() {
  find /var/run/nut -maxdepth 1 -name '*.pid' "$@" 2>/dev/null || true
}
# BusyBox find exits 0 when a non-empty directory at a *.pid path survives
# -delete, so the re-scan enforces the pathname POSTCONDITION rather than
# trusting the exit status. `head -c` bounds only the CAPTURES: this directory
# is nut-writable, so an unbounded substitution would materialize an
# arbitrarily large planted set in PID 1 memory (CWE-400); the SIGPIPE it sends
# find is what the function's `|| true` absorbs (pipefail is not set).
if [ -n "$(stale_nut_pid_paths | head -c 1)" ]; then
  printf 'level=info msg="clearing stale NUT PID paths from previous lifecycle" path=/var/run/nut\n' >&2
  stale_nut_pid_paths -delete
  _stale_pids=$(stale_nut_pid_paths | head -c 512)
  if [ -n "$_stale_pids" ]; then
    printf 'level=error msg="failed to clear a stale NUT PID path; refusing to start" path=/var/run/nut surviving="%s"\n' \
      "$(log_value "$_stale_pids")" >&2
    exit 1
  fi
fi

# Clear temps leaked by a kill between mktemp and rm -f/mv in lifecycle.sh's
# capture helpers, password.sh's resolvers, or generate-config.sh's override
# staging. Root-owned, unlike /var/run/nut above, and everything matched is
# crash-leaked because every producer runs later in this boot. The four
# /etc/nut globs are literals: use_user_override builds its destination from its
# argument. Warn-only, so one undeletable artifact is not an unannotated boot
# abort — the producers that need the space fail with their own structured
# errors if storage is still unavailable.
if ! _clt_err=$(rm -f "$WD_RESTART_CAPTURE_PREFIX".* "$STOP_CMD_CAPTURE_PREFIX".* \
  "${ADMIN_PASSWORD_FILE}.tmp."* \
  "${LOCAL_UPSMON_PASSWORD_FILE}.tmp."* \
  "${TLS_CERT_CACHE}.tmp."* \
  "${TLS_CERT_RUNTIME}.tmp."* \
  "${TLS_CERT_MOUNTED_RUNTIME}.tmp."* \
  /etc/nut/ups.conf.tmp.* /etc/nut/upsd.conf.tmp.* \
  /etc/nut/upsd.users.tmp.* /etc/nut/upsmon.conf.tmp.* 2>&1); then
  printf 'level=warn msg="could not remove a crash-leaked temp file from a previous lifecycle; continuing" err="%s"\n' \
    "$(log_value "$(printf '%s' "$_clt_err" | head -c 512)")" >&2
fi

# Clear a stale POWERDOWNFLAG (killpower) from a previous lifecycle. upsmon
# creates it on FSD; /var/run/nut-secrets is the writable layer so it survives
# a `docker restart`. No NUT kill-power path in this container acts on it (host
# poweroff is via D-Bus). A latched flag would otherwise
# make the comms watchdog stand down indefinitely (see restart_ups_driver), so
# clear it at a fresh start. The flag lives in the root-only nut-secrets dir
# so the nut user cannot plant it (see generate-config.sh).
if [ -e "$POWERDOWNFLAG_FILE" ]; then
  printf 'level=info msg="clearing stale killpower flag from previous lifecycle" path=%s\n' "$POWERDOWNFLAG_FILE" >&2
  rm -f "$POWERDOWNFLAG_FILE" || {
    printf 'level=error msg="failed to clear the stale killpower flag; refusing to start" path=%s\n' "$POWERDOWNFLAG_FILE" >&2
    exit 1
  }
fi

# Must precede the := defaults below: an LF-only value (env-file artifact) is
# non-empty raw, so it would dodge the documented default and then fail
# validation (or reach generate_all_configs' bare :? abort) instead of
# defaulting. The two credentials are exempt — an LF-only ADMIN_PASSWORD is
# refused by the control check rather than stripped — so this need not precede
# password resolution. set -u safe before the defaults exist: every assignment
# inside uses ${VAR:-}. See validate.sh canonicalize_validated_values.
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

# USB comms-recovery watchdog cadence (mechanism: lifecycle.sh comms_watchdog;
# bus live-bind + cgroup-rule prerequisites: README "USB hotplug & comms recovery").
: "${COMMS_WATCHDOG:=true}"
: "${COMMS_CHECK_INTERVAL:=15}"
: "${COMMS_RECOVERY_TIMEOUT:=90}"
# Two-stage recovery cadence, stage 2 backing off by COMMS_BACKOFF_FACTOR: see
# lifecycle.sh comms_watchdog, and the README for sizing it.
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
decide_user_overrides
if local_upsmon_credential_active; then
  resolve_local_upsmon_password
fi

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
# Default: noop shutdown (log-only on FSD). Why a script and not an inlined
# printf: see nut-shutdown-noop.sh.
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
  printf 'level=info msg="host shutdown disabled; an FSD logs and then ends this container through upsmon exit, leaving the restart policy to decide"\n' >&2
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

# Always, even with an upsd.conf.user override mounted: resolve_tls_cert
# provisions exactly one source per boot, so any unselected working copy is
# withdrawn private-key material from a previous lifecycle left nut-readable in
# the writable layer. Withdrawing it makes an override naming it fail visibly
# at upsd startup instead of silently serving stale key material. set -u safe:
# $TLS_CERT_PATH is read only on the API_TLS=true branch.
reconcile_tls_working_copies

# ---------------------------------------------------------------------------
# Generate NUT config files (from generate-config.sh)
# ---------------------------------------------------------------------------
generate_all_configs

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
# upsd.pem (the operator-mounted TLS PEM) is excluded like the *.user
# overrides: it is a bind mount the container must never mutate (chown/chmod
# on a rw mount would rewrite the HOST file's perms; on a read-only mount
# they fail with EROFS and would abort the boot under set -e).
# resolve_tls_cert (password.sh) serves a root:nut 640 working copy inside
# /etc/nut instead, which this sweep normalizes like any generated file.
if ! _perm_err=$(
  find /etc/nut -name '*.user' -prune -o -name "${TLS_CERT_MOUNT##*/}" -prune -o -exec chown root:nut {} + 2>&1 \
    && find /etc/nut -name '*.user' -prune -o -name "${TLS_CERT_MOUNT##*/}" -prune -o -type d -exec chmod 750 {} + 2>&1 \
    && find /etc/nut -name '*.user' -prune -o -name "${TLS_CERT_MOUNT##*/}" -prune -o -type f -exec chmod 640 {} + 2>&1
); then
  printf 'level=error msg="could not normalize /etc/nut ownership and modes; refusing to start" err="%s"\n' \
    "$(log_value "$(printf '%s' "$_perm_err" | head -c 512)")" >&2
  exit 1
fi
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

# Background comms-watchdog PID and background D-Bus poweroff-path probe PID
# (each empty until its loop is started below).
WATCHDOG_PID=""
DBUS_PROBE_PID=""

# teardown_all: the one teardown sequence every exit path shares (signal
# trap, upsd-unresponsive exit, upsmon-exit path) - reap both background
# loops, then stop the NUT daemons. Exit codes stay with the callers.
# stop_bg_pid no-ops on a loop that never started. A SIGTERM landing while
# the watchdog subshell is mid-`upsdrvctl start` orphans that child, so
# `wait` reaps the subshell but the orphan may briefly race stop_services'
# `upsdrvctl stop` - harmless, since the next boot clears stale pidfiles.
teardown_all() {
  # Not restartable from the top by a signal landing inside it: the
  # sequence is bounded at 3 x STOP_CMD_TIMEOUT against Docker's stop
  # budget, and the caller owns the exit status.
  trap '' TERM INT QUIT HUP
  stop_bg_pid "${WATCHDOG_PID:-}"
  stop_bg_pid "${DBUS_PROBE_PID:-}"
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
  if wait "$!"; then
    :
  else
    _sd_rc=$?
    printf 'level=error msg="%s start failed or timed out at boot" rc=%d\n' "$_sd_label" "$_sd_rc" >&2
    teardown_all
    exit 1
  fi
}

# This 90s outer bound catches upsdrvctl itself wedging. At NUT defaults, the
# generated single-section config fits because upsdrvctl bounds each driver
# with maxstartdelay and exits non-zero if it never starts. A mounted ups.conf.user
# with more sections or raised maxstartdelay/maxretry can exceed this bound and
# make a healthy configuration fail boot.
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
# `upsc -l` only lists configured UPSes, so the probe succeeds while driver
# data is stale: it isolates upsd protocol failure from the freshness signal
# the comms watchdog acts on. 4 x 15s ~= 60s of sustained failure exits BEFORE
# the watchdog's first driver bounce (COMMS_RECOVERY_TIMEOUT, default 90s), so
# a dead upsd cannot strand the container in driver-restart churn that repairs
# nothing.
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
  wait "$!" || true
  kill -0 "$UPSMON_PID" 2>/dev/null || break
  # Both background workers are supervised here as well: an external SIGKILL
  # (a host OOM kill; the published compose example sets no memory limit) took
  # a documented capability away for the container's life, with upsd still
  # answering and the healthcheck still green. A non-empty PID slot is proof
  # the start gate passed, so re-launching on it cannot enable a disabled
  # worker. The respawn is FRESH, not resumed: both loops keep their state in
  # process-local variables, so the cadence restarts from zero.
  if [ -n "${WATCHDOG_PID:-}" ] && ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    wait "$WATCHDOG_PID" 2>/dev/null || true
    printf 'level=error msg="comms watchdog exited; starting a fresh one, whose recovery cadence restarts from zero"\n' >&2
    comms_watchdog &
    WATCHDOG_PID=$!
  fi
  if [ -n "${DBUS_PROBE_PID:-}" ] && ! kill -0 "$DBUS_PROBE_PID" 2>/dev/null; then
    wait "$DBUS_PROBE_PID" 2>/dev/null || true
    printf 'level=error msg="D-Bus poweroff-path probe exited; starting a fresh one, whose unreachable/recovered state restarts from zero"\n' >&2
    dbus_liveness_probe &
    DBUS_PROBE_PID=$!
  fi
  if upsd_responsive; then
    upsd_failures=0
  else
    upsd_failures=$((upsd_failures + 1))
    if [ "$upsd_failures" -ge "$UPSD_PROBE_MAX_FAILURES" ]; then
      printf 'level=error msg="upsd unresponsive; stopping services and exiting so the restart policy rebuilds the stack" consecutive_failures=%d probe_interval=%ss probe=%s\n' \
        "$upsd_failures" "$UPSD_PROBE_INTERVAL" "$(upsd_probe_host):${API_PORT}" >&2
      teardown_all
      exit 1
    fi
    printf 'level=warn msg="upsd not responding to protocol probe" consecutive_failures=%d threshold=%d probe=%s\n' \
      "$upsd_failures" "$UPSD_PROBE_MAX_FAILURES" "$(upsd_probe_host):${API_PORT}" >&2
  fi
done

# Reap upsmon and propagate its exit code so Docker restart policies and
# log-based alerting see the real failure. Status 0 from this process is not a
# clean stop: it is an executed SHUTDOWNCMD (upsmon's privileged parent,
# clients/upsmon.c runparent). stop_services is idempotent and does not dictate
# the exit code; the caller decides.
set +e
wait "$UPSMON_PID"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  printf 'level=warn msg="upsmon parent exited after running SHUTDOWNCMD; a forced shutdown (FSD) was executed" rc=0\n' >&2
else
  printf 'level=error msg="upsmon exited unexpectedly" rc=%d\n' "$rc" >&2
fi
teardown_all
exit "$rc"
