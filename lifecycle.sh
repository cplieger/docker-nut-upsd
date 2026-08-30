#!/bin/sh
# lifecycle.sh — NUT service lifecycle utility functions.
# Sourced, never executed. The Dockerfile HEALTHCHECK sources this file
# ALONE, so the top level must only DEFINE: no call into another helper,
# nothing that runs at source time, no reliance on the caller's `set -eu`.

readonly PIDFILE_POLL_INTERVAL="0.1"
readonly PIDFILE_POLL_MAX=50 # nominal wait = POLL_MAX × POLL_INTERVAL = 5s (each poll's pidfile read adds its own <=1s bound; see read_pidfile)
readonly DBUS_PROBE_REPLY_TIMEOUT_MS=3000
# Per-command bound for the stop_services control calls: 3 commands x 3s = 9s
# worst case, inside Docker's default 10s stop budget before SIGKILL.
readonly STOP_CMD_TIMEOUT=3

# Shared temp-file capture lifecycle for bounded subprocess output. Capture via
# a regular file, never $(): a TERM-ignoring child can hold a pipe's write end
# open past timeout's signal and block the reader forever. Files live in the
# root-only /var/run/nut-secrets; if mktemp fails the caller still runs with
# output discarded to /dev/null. The prefixes are constants because the
# entrypoint's leaked-temp cleanup globs "$PREFIX".* — a literal respelled
# there would silently stop matching if a label changed (same rationale as the
# password.sh cache-path constants that cleanup already uses).
readonly STOP_CMD_CAPTURE_PREFIX=/var/run/nut-secrets/stop-cmd
readonly WD_RESTART_CAPTURE_PREFIX=/var/run/nut-secrets/wd-restart
# upsmon's POWERDOWNFLAG, for the same reason: the generator writes the
# directive and three lifecycle paths read the flag, so the path has one owner.
readonly POWERDOWNFLAG_FILE=/var/run/nut-secrets/killpower
capture_tmpfile() {
  mktemp "$1.XXXXXX" 2>/dev/null || printf '/dev/null'
}
capture_head() {
  head -c 512 "$1" 2>/dev/null || true
}
capture_cleanup() {
  # Deliberately status-neutral: both callers publish a best-effort contract an
  # unlink failure must not abort (the pidfile unlink warns instead — that state
  # is read by the next bounce, this temp file is not).
  [ "$1" = "/dev/null" ] || rm -f "$1" 2>/dev/null || true
}

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
  # -s KILL at the deadline, not TERM: a TERM-ignoring control client would
  # hold PID 1 inside the signal trap past it (Docker's 10s SIGKILL the only
  # backstop) and stretch the 3x3=9s budget. Capture helpers own file-not-$().
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
# decide the final exit status. Each control call is time-bounded (see
# stop_nut_cmd) so the combined worst case fits the container stop budget.
stop_services() {
  printf 'level=info msg="stopping NUT services"\n' >&2
  stop_nut_cmd "upsmon" /usr/sbin/upsmon -c stop
  stop_nut_cmd "upsd" /usr/sbin/upsd -c stop
  stop_nut_cmd "upsdrvctl" /usr/sbin/upsdrvctl stop
  printf 'level=info msg="NUT services stopped"\n' >&2
}

# read_pidfile: bounded, race-safe read of a NUT pidfile from the nut-writable
# /var/run/nut. Refuses symlinks and non-regular files, prints at most 64 bytes
# or nothing, and always returns 0. Opens the file only after dropping to the
# unprivileged nut user, so a symlink raced in after the check cannot leak
# root-only content (BusyBox su: Alpine's setpriv applet implements no
# --reuid/--regid). The hard bound (timeout -s KILL 1) keeps a raced FIFO from
# blocking the caller, and the path travels as a positional parameter, never
# interpolated into the -c string.
read_pidfile() {
  _rp_path=$1
  [ ! -L "$_rp_path" ] && [ -f "$_rp_path" ] || return 0
  timeout -s KILL 1 su -s /bin/sh -c "exec head -c 64 \"\$1\"" nut sh "$_rp_path" \
    2>/dev/null || true
}

# Bounded poll for a NUT daemon PID file. NUT drivers/daemons write a PID
# file at /var/run/nut/<name>.pid after a successful fork+daemonize, which
# is the canonical completion signal upstream relies on (upsdrvctl itself
# checks for it). Using the PID file avoids BusyBox pgrep quirks around
# `-x` matching argv[0] of daemonized processes whose comm is truncated or
# changed. Polls every PIDFILE_POLL_INTERVAL up to total timeout. Returns 0
# on success, 1 on timeout.
wait_for_pidfile() {
  # $1 = label, $2 = absolute PID file path, $3 = expected daemon binary.
  : "${3:?wait_for_pidfile requires an expected binary path}"
  _wf_i=0
  while [ "$_wf_i" -lt "$PIDFILE_POLL_MAX" ]; do
    # Pidfiles live in the nut-writable /var/run/nut; only trust strictly
    # numeric content (mirrors restart_ups_driver's confused-deputy guard).
    _wf_pid=$(read_pidfile "$2")
    case "$_wf_pid" in
      '' | *[!0-9]*) ;; # empty, partial write, or untrusted content: keep polling
      *[!0]*)
        # Live PID verified as the expected daemon (pid_matches_binary) —
        # a planted PID of some unrelated live process must not satisfy the
        # startup gate (completes restart_ups_driver's trust boundary).
        if kill -0 "$_wf_pid" 2>/dev/null \
          && pid_matches_binary "$_wf_pid" "$3"; then
          return 0
        fi
        ;;
      *) ;; # all-zero PID: `kill -0 0` signals the caller's own process group — refuse
    esac
    sleep "$PIDFILE_POLL_INTERVAL"
    _wf_i=$((_wf_i + 1))
  done
  printf 'level=error msg="%s did not write a valid PID file in time" path=%s polls=%d interval=%s\n' \
    "$1" "$2" "$PIDFILE_POLL_MAX" "$PIDFILE_POLL_INTERVAL" >&2
  return 1
}

# ---------------------------------------------------------------------------
# USB comms recovery watchdog
# ---------------------------------------------------------------------------
# A UPS that resets its own USB link re-enumerates to a new root:root node
# (NUT issue networkupstools/nut#1786) and the nut-user driver then sits "Data
# stale" until the container is recreated. This watchdog detects sustained
# stale comms and re-homes the driver onto the current node. The README ("USB
# hotplug & comms recovery") owns the prerequisites and what an operator sees.

# upsd_probe_host: host for the loopback protocol probes. upsd binds the LISTEN
# address in upsd.conf, which is generated from API_ADDRESS unless
# upsd.conf.user is mounted — then the operator owns it and must keep the two in
# step (the README's override list). A specific bind address must therefore be
# probed at that address — probing 127.0.0.1 would fail
# permanently (driver bounced forever by the watchdog, container fatally
# exited by the supervision loop). Only the wildcard binds map to loopback;
# every specific bind passes through and is probed exactly where upsd listens
# — 127.0.0.2-style loopback addresses, which a 127.0.0.1 probe cannot reach,
# and "localhost", which upsd binds to the FIRST address the name resolves to
# and warns as much, while upsc tries every resolved address. Every IPv6
# literal is bracketed (the wildcard as [::1], specific addresses as [<addr>])
# because NUT's host:port syntax requires brackets around any colon-bearing host.
upsd_probe_host() {
  case "$API_ADDRESS" in
    0.0.0.0) printf '127.0.0.1' ;;
    ::) printf '[::1]' ;;
    *:*) printf '[%s]' "${API_ADDRESS}" ;;
    *) printf '%s' "${API_ADDRESS}" ;;
  esac
}

# comms_fresh: return 0 when upsd is serving fresh data, non-zero on
# stale/unreachable. upsc prints the requested variable on fresh data and an
# error ("Data stale" / connection refused) otherwise.
comms_fresh() {
  timeout 3 upsc "${UPS_NAME}@$(upsd_probe_host):${API_PORT}" ups.status >/dev/null 2>&1
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

# driver_binary: installed driver path (--with-drvpath=/usr/lib/nut in the
# Dockerfile). Centralized like driver_pidfile: the process-identity
# checks in restart_ups_driver and the entrypoint's wait_for_pidfile gate must
# compare against the same literal.
driver_binary() {
  printf '/usr/lib/nut/%s' "$UPS_DRIVER"
}

# pid_matches_binary PID BINARY: verify the live process PID is an instance of
# BINARY. Prefers the kernel-truth /proc/<pid>/exe symlink; when exe is
# unreadable, falls back to the world-readable /proc/<pid>/comm against the
# truncated basename of BINARY. The cause of that fallback, and the threat
# argument for it, are in CONTRIBUTING ("/proc/<pid>/exe is unreadable for the
# NUT daemons"): a NUT daemon setuid()s without exec-ing, which clears its
# dumpable flag. comm is self-reported, so the fallback is deliberately the
# weaker of the two.
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
  # The pidfile lives in the nut-writable /var/run/nut: read_pidfile caps the
  # bytes root will ingest/log, refuses symlinks/special files, and drops to
  # nut before opening so a raced symlink cannot leak root-only content.
  _ksd_pid=$(read_pidfile "$_ksd_pf")
  # Confused-deputy guard: the pidfile lives in the nut-writable /var/run/nut,
  # so a compromised nut process can plant an arbitrary PID (1, upsmon, or
  # "-1" = every process) and turn this root SIGKILL into a kill of any
  # container process. Only signal a strictly numeric PID verified as an
  # instance of the expected driver binary (pid_matches_binary;
  # --with-drvpath=/usr/lib/nut in the Dockerfile); otherwise log, refuse to
  # signal, and let the unconditional rm below drop the untrusted pidfile.
  case "$_ksd_pid" in
    '') ;; # no pidfile: nothing to hard-kill
    *[!0-9]*)
      printf 'level=error msg="comms watchdog refusing non-numeric PID from pidfile" ups=%s pidfile=%s pid="%s"\n' \
        "$UPS_NAME" "$_ksd_pf" "$(log_value "$_ksd_pid")" >&2
      _ksd_pid=""
      ;;
    *[!0]*) ;; # numeric with a nonzero digit: candidate for the verified hard-kill below
    *)
      # All-zero PID: `kill -0 0` probes the caller's own process group instead
      # of a specific PID, so refuse it outright (mirrors wait_for_pidfile's
      # zero-PID guard) rather than relying on the pid_matches_binary check.
      printf 'level=error msg="comms watchdog refusing all-zero PID from pidfile" ups=%s pidfile=%s\n' \
        "$UPS_NAME" "$_ksd_pf" >&2
      _ksd_pid=""
      ;;
  esac
  if [ -n "$_ksd_pid" ] && kill -0 "$_ksd_pid" 2>/dev/null; then
    # Verify identity, then re-check existence immediately before signaling
    # to narrow the PID-reuse window as far as plain sh allows.
    if pid_matches_binary "$_ksd_pid" "$(driver_binary)" \
      && kill -0 "$_ksd_pid" 2>/dev/null; then
      kill -9 "$_ksd_pid" 2>/dev/null || true
    else
      printf 'level=error msg="comms watchdog refusing to kill PID not verified as the UPS driver" ups=%s pid=%s expected=%s\n' \
        "$UPS_NAME" "$_ksd_pid" "$(driver_binary)" >&2
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
  # 90s > NUT's 75s default maxstartdelay, so timeout only fires on a genuine wedge.
  # -k 5 hard-kills a TERM-ignoring upsdrvctl as the boot path does. The
  # write-end holder that makes the file capture necessary here is a wedged
  # pre-daemonize driver grandchild. Capture helpers own file-not-$().
  _srd_out_file=$(capture_tmpfile "$WD_RESTART_CAPTURE_PREFIX")
  if timeout -k 5 90 /usr/sbin/upsdrvctl start "$UPS_NAME" >"$_srd_out_file" 2>&1; then
    printf 'level=info msg="comms watchdog driver restart issued" ups=%s\n' "$UPS_NAME" >&2
  else
    # Capture the exit status so a silent failure still names its class. On
    # this BusyBox image `timeout -k 5 90` reports expiry as 143 (128+TERM),
    # or 137 (128+KILL) when upsdrvctl ignored the TERM through the grace —
    # never coreutils' 124. log_value flattens CR/tab/control bytes that the
    # previous LF-only sanitizer let split or corrupt the logfmt record.
    _srd_rc=$?
    _srd_out=$(capture_head "$_srd_out_file")
    printf 'level=error msg="comms watchdog driver restart failed" ups=%s rc=%d detail="%s"\n' \
      "$UPS_NAME" "$_srd_rc" "$(log_value "$_srd_out")" >&2
  fi
  capture_cleanup "$_srd_out_file"
}

# restart_ups_driver: re-home the driver onto the (possibly re-enumerated) USB
# node. Runs as root (PID 1 lineage): re-asserts the nut group on the bus so
# the driver's own reconnect can open a freshly created root:root node, then
# bounces the driver. upsdrvctl re-opens the device while still root and the
# driver drops to nut only AFTER opening, which is why the restart succeeds
# whatever the new node's group. A wedged driver is hard-killed by pidfile
# because `upsdrvctl stop` alone has been observed to fail to reap it
# ("Stopping ...pid failed: Permission denied"). Non-USB: no group re-assert.
restart_ups_driver() {
  _attempt=${1:-1}
  # Stand down only when a real host poweroff is in progress. upsmon (primary)
  # writes POWERDOWNFLAG on EVERY FSD, including the log-only noop path, so
  # gating on the flag alone would latch USB recovery OFF for the container's
  # life. In the default configuration the container is EXITING from that point
  # (upsmon's parent runs SHUTDOWNCMD and exits 0), so the conjunct's live case
  # is a mounted upsmon.conf.user that keeps the generated flag path with a
  # non-poweroff SHUTDOWNCMD. generate-config.sh's POWERDOWNFLAG directive owns
  # who touches the flag. Return non-zero so a stand-down is not counted.
  if [ "${SHUTDOWN_ON_BATTERY_CRITICAL:-false}" = "true" ] && [ -e "$POWERDOWNFLAG_FILE" ]; then
    printf 'level=warn msg="comms watchdog standing down; forced shutdown (killpower) in progress" ups=%s\n' "$UPS_NAME" >&2
    return 1
  fi
  # From the FINAL fast retry onward (attempt >= COMMS_FAST_RETRIES) the UPS is
  # likely genuinely absent or the driver unstartable, so escalate to error --
  # deliberately ON the last fast attempt, not after it (see README 'USB hotplug
  # & comms recovery' for sizing this against an alert window).
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
  timeout -k 5 30 /usr/sbin/upsdrvctl stop "$UPS_NAME" >/dev/null 2>&1 || true
  kill_stale_driver_from_pidfile "$(driver_pidfile)"
  start_recovered_driver
  # Signal that a real restart was attempted (distinct from the killpower
  # stand-down's non-zero return) so comms_watchdog counts it against the budget.
  return 0
}

# comms_watchdog: probe upsd every COMMS_CHECK_INTERVAL seconds and re-home the
# driver after sustained stale comms, in two stages: COMMS_FAST_RETRIES fast
# attempts, then a COMMS_BACKOFF_FACTOR-multiplied threshold with the log at
# error, so a genuinely-absent UPS stops thrashing host USB perms while staying
# visible. Each window is monotonic elapsed time since its first stale probe
# (watchdog_epoch, not summed intervals), re-armed only at the first stale probe
# AFTER a bounce -- so one fast retry costs COMMS_RECOVERY_TIMEOUT plus up to one
# check interval plus the bounce itself. README "USB hotplug & comms recovery" sizes it.
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
# -> nut-shutdown.sh -> D-Bus PowerOff) is otherwise first exercised during a
# real forced shutdown — a mount that broke after boot would surface exactly
# when it can no longer be fixed. The README ("Alerting") owns the cadence and
# the operator-facing contract.

# dbus_poweroff_path_ok: return 0 when the host D-Bus socket is mounted and
# logind's own CanPowerOff answers yes. That method carries the same polkit
# action as the PowerOff nut-shutdown.sh calls and has no side effect, where a
# Peer.Ping is answered before object resolution and proves only that some
# process owns the name. `no` and `challenge` come back as SUCCESSFUL method
# returns, so the reply STRING is the verdict and never dbus-send's exit status;
# `challenge` is a refusal here because the real call is non-interactive. The
# reply text is left in _dbus_detail for the caller's log line.
dbus_poweroff_path_ok() {
  _dbus_detail=""
  [ -S /run/dbus/system_bus_socket ] || {
    _dbus_detail="socket missing"
    return 1
  }
  # $() capture is safe here for the same reason nut-shutdown.sh gives: dbus-send
  # spawns no fd-holding grandchildren.
  _dbus_reply=$(timeout 5 dbus-send --system --print-reply \
    --reply-timeout="$DBUS_PROBE_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.CanPowerOff 2>&1) || {
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
