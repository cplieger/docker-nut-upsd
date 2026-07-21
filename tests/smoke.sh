#!/bin/sh
# Build-time smoke test for docker-nut-upsd.
#
# Runs in the Dockerfile `test` stage (FROM the runtime image, which has the
# compiled NUT binaries and the entrypoint helper scripts), so the centralized
# `ci / validate` docker build-ability gate executes it on every PR and push.
#
# It covers the two things that have no other unit coverage in this shell-only,
# compiled-from-source image: (1) the NUT binaries built from upstream sources
# actually run, and (2) the entrypoint's env -> config generation and its input
# validation (config-injection guards) behave correctly. Daemon startup itself
# still needs a real UPS and is covered by the runtime healthcheck.
#
# Run locally inside the image:  sh /tmp/tests/smoke.sh
set -eu

# shellcheck source=/dev/null
. /usr/local/bin/validate.sh
# shellcheck source=/dev/null
. /usr/local/bin/generate-config.sh
# shellcheck source=/dev/null
. /usr/local/bin/lifecycle.sh

fail=0
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# 1. Binaries compiled from upstream sources are present and link.
for b in upsd upsc upsmon upsdrvctl; do
  if ! command -v "$b" >/dev/null 2>&1; then
    err "FAIL: NUT binary missing from PATH: $b"
    fail=1
  fi
done

# 2. Valid env passes validation and generates all four config files.
export UPS_NAME=ups UPS_DESC="Test UPS" UPS_DRIVER=usbhid-ups UPS_PORT=auto \
  API_USER=monuser API_PASSWORD=secret API_ADDRESS=0.0.0.0 API_PORT=3493 \
  ADMIN_PASSWORD=adminpass SHUTDOWN_CMD=/usr/local/bin/nut-shutdown-noop.sh \
  POLLFREQ=5 POLLFREQALERT=5 DEADTIME=15 FINALDELAY=5 HOSTSYNC=15 \
  NOCOMMWARNTIME=300 RBWARNTIME=43200 \
  COMMS_WATCHDOG=true COMMS_CHECK_INTERVAL=15 COMMS_RECOVERY_TIMEOUT=90 \
  COMMS_FAST_RETRIES=3 COMMS_BACKOFF_FACTOR=5 DBUS_PROBE_INTERVAL=300

if ! out=$( (run_validations) 2>&1); then
  err "FAIL: run_validations rejected a valid environment"
  err "$out"
  fail=1
fi

generate_all_configs
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
  if [ ! -s "/etc/nut/$f" ]; then
    err "FAIL: config not generated: /etc/nut/$f"
    fail=1
  fi
done
grep -q '^\[ups\]' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing [ups] section"
  fail=1
}
grep -q 'driver = usbhid-ups' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing driver"
  fail=1
}
grep -q 'pollonly' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing pollonly for usbhid driver"
  fail=1
}
grep -q 'LISTEN 0.0.0.0 3493' /etc/nut/upsd.conf || {
  err "FAIL: upsd.conf missing LISTEN directive"
  fail=1
}

# A single trailing LF (env-file artifact) is harmless only because the
# entrypoint strips it from every validated var BEFORE validation and config
# generation (validate.sh canonicalize_validated_values). Exercise the real
# production helper — not a hand-rolled copy of the strip — and assert the
# desc directive stays a single well-formed line.
if ! (
  UPS_DESC="$(printf 'desc\nx')"
  UPS_DESC=${UPS_DESC%x}
  canonicalize_validated_values
  run_validations >/dev/null 2>&1 || exit 1
  generate_all_configs >/dev/null 2>&1
  grep -q '^    desc = "desc"$' /etc/nut/ups.conf
); then
  err "FAIL: trailing-LF UPS_DESC did not canonicalize to a one-line desc directive"
  fail=1
fi
# API_PORT is the one var written MID-LINE into a generated config (upsmon.conf's
# MONITOR directive); a surviving trailing LF would split the directive across
# two lines. Assert canonicalization keeps it one well-formed line.
if ! (
  API_PORT="$(printf '3493\nx')"
  API_PORT=${API_PORT%x}
  canonicalize_validated_values
  run_validations >/dev/null 2>&1 || exit 1
  generate_all_configs >/dev/null 2>&1
  grep -q '^MONITOR ups@127.0.0.1:3493 1 "monuser" "secret" primary$' /etc/nut/upsmon.conf
); then
  err "FAIL: trailing-LF API_PORT did not canonicalize to a one-line MONITOR directive"
  fail=1
fi
# Regenerate with the baseline env so later steps see the section-2 configs.
generate_all_configs >/dev/null 2>&1

# 3. Validation rejects config-injection attempts (run_validations exits non-
#    zero on failure, so each negative case runs in a subshell).
if (
  UPS_NAME='bad]name'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: bracket-injection UPS_NAME was accepted"
  fail=1
fi
# A dash-leading UPS_NAME must fail fast at boot: every CLI consumer passes
# the name as the first getopt-parsed argument (healthcheck `upsc -foo@...`,
# comms_fresh, `upsdrvctl stop -foo`), so it parses as options and the
# container would boot into a permanently-broken state.
if (
  UPS_NAME='-foo'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: dash-leading UPS_NAME was accepted"
  fail=1
fi
if (
  UPS_PORT='notapath'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: invalid UPS_PORT was accepted"
  fail=1
fi
if (
  API_PORT='70000'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: out-of-range API_PORT was accepted"
  fail=1
fi
# Digit strings beyond LONG_MAX make BusyBox test(1) error (status 2) instead
# of comparing, and an enclosing `if` swallows that — validate_numeric must
# reject >18 normalized digits before any range comparison runs.
if (
  API_PORT='9999999999999999999'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: overlong API_PORT (>18 digits) was accepted"
  fail=1
fi
# The stage-2 backoff threshold multiplies these two; each fits in 18 digits
# but the product would overflow $(( )), so run_validations must bound the pair.
if (
  COMMS_RECOVERY_TIMEOUT='999999999999999999'
  COMMS_BACKOFF_FACTOR='5'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: COMMS_RECOVERY_TIMEOUT x COMMS_BACKOFF_FACTOR product overflow was accepted"
  fail=1
fi
if (
  COMMS_CHECK_INTERVAL='notanumber'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: non-numeric COMMS_CHECK_INTERVAL was accepted"
  fail=1
fi
if (
  COMMS_BACKOFF_FACTOR='0'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: zero COMMS_BACKOFF_FACTOR was accepted (collapses stage-2 threshold; watchdog thrashes)"
  fail=1
fi
# A bare CR (0x0D) must be rejected: the old wc -l guard counted only LF, so a
# CR-only injection slipped through into a NUT config field unaltered.
if (
  UPS_DESC="$(printf 'desc\rinjected')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: CR-injection UPS_DESC was accepted"
  fail=1
fi
# A trailing backslash must be rejected: in a double-quoted NUT directive a
# backslash escapes the next character, so a trailing one escapes the closing
# quote and breaks out of the quoted context (config-quoting breakout).
if (
  API_PASSWORD="$(printf 'secret\134')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: backslash-injection API_PASSWORD was accepted"
  fail=1
fi
# API_USER is written unquoted as a `[$API_USER]` section header in upsd.users,
# so it gets the same identifier discipline as UPS_NAME.
if (
  API_USER='mon user'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: whitespace API_USER was accepted"
  fail=1
fi
# snmp-ups takes a network endpoint: a host must pass, USB auto-detection must not.
if ! (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='192.168.1.50'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: snmp-ups with a host endpoint was rejected"
  fail=1
fi
if (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='auto'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: snmp-ups with UPS_PORT=auto was accepted (auto is USB-only)"
  fail=1
fi
# A trailing LF on UPS_DRIVER must not dodge the transport check: raw
# "snmp-ups<LF>" fails driver_transport's literal case match and classifies
# as "other" (where auto is allowed), so canonicalization must strip it
# BEFORE run_validations for the network-transport rejection to fire.
if (
  UPS_DRIVER="$(printf 'snmp-ups\nx')"
  UPS_DRIVER=${UPS_DRIVER%x}
  UPS_PORT='auto'
  canonicalize_validated_values
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: trailing-LF snmp-ups with UPS_PORT=auto was accepted (canonicalization bypassed the transport check)"
  fail=1
fi

# 4. Watchdog / transport helpers are defined (sourced from validate.sh and
#    lifecycle.sh). stop_watchdog and stop_dbus_probe live in entrypoint.sh
#    and are not asserted here.
for fn in upsd_probe_host comms_fresh upsd_responsive restart_ups_driver comms_watchdog watchdog_epoch \
  driver_transport usb_bus_required dbus_poweroff_path_ok dbus_liveness_probe read_pidfile; do
  if ! command -v "$fn" >/dev/null 2>&1; then
    err "FAIL: helper function missing: $fn"
    fail=1
  fi
done

#    read_pidfile: race-safe pidfile reads. A regular nut-readable file's
#    content comes back through the BusyBox `su` privilege drop (real NUT
#    pidfiles are nut-owned, so the fixture is chowned to nut explicitly —
#    readability under the drop must not depend on the build stage's umask);
#    a planted symlink and a FIFO are both refused. The FIFO has no writer,
#    so this block completing at all also proves the read path cannot block
#    on a raced special file.
printf '12345' >/var/run/nut/rp-regular.pid
chown nut:nut /var/run/nut/rp-regular.pid
if [ "$(read_pidfile /var/run/nut/rp-regular.pid)" != "12345" ]; then
  err "FAIL: read_pidfile did not return the content of a regular pidfile"
  fail=1
fi
printf 'root-only' >/var/run/nut-secrets/rp-secret
ln -s /var/run/nut-secrets/rp-secret /var/run/nut/rp-symlink.pid
if [ -n "$(read_pidfile /var/run/nut/rp-symlink.pid)" ]; then
  err "FAIL: read_pidfile followed a planted symlink"
  fail=1
fi
mkfifo /var/run/nut/rp-fifo.pid
if [ -n "$(read_pidfile /var/run/nut/rp-fifo.pid)" ]; then
  err "FAIL: read_pidfile read from a FIFO"
  fail=1
fi
rm -f /var/run/nut/rp-regular.pid /var/run/nut/rp-symlink.pid \
  /var/run/nut/rp-fifo.pid /var/run/nut-secrets/rp-secret

#    upsd_probe_host maps ONLY the wildcard binds (and localhost) to loopback;
#    specific IPv4 binds — including 127.0.0.2-style loopback addresses that a
#    127.0.0.1 probe cannot reach — pass through unchanged, specific IPv6
#    literals gain NUT's documented brackets ([::1], [2001:db8::1]), and the
#    :: wildcard maps to the bracketed loopback [::1]. Guards the shared
#    helper against regressing to address-family-wide rewriting (the
#    Dockerfile HEALTHCHECK sources this same helper, so these cases
#    directly cover the healthcheck mapping).
for spec in '0.0.0.0=127.0.0.1' 'localhost=127.0.0.1' '::=[::1]' \
  '::1=[::1]' '2001:db8::1=[2001:db8::1]' \
  '127.0.0.2=127.0.0.2' '192.168.1.5=192.168.1.5'; do
  addr=${spec%%=*}
  want=${spec#*=}
  got=$(API_ADDRESS="$addr" upsd_probe_host)
  if [ "$got" != "$want" ]; then
    err "FAIL: upsd_probe_host mapped API_ADDRESS=$addr to '$got' (want '$want')"
    fail=1
  fi
done

# 5. Watchdog behavior, driven through the injectable seams (comms_fresh,
#    sleep, watchdog_epoch) with a fake clock — no real waiting.
#
#    Cadence and budget with the defaults (check=15, recovery=90,
#    fast_retries=3, backoff=5): stale from t=15 on, fast attempts fire at
#    t=105/210/315, then the stage-2 threshold (450s) delays attempts 4 and 5
#    to t=780/1245.
WATCHDOG_ERR=$(mktemp)
RESTART_LOG=$(mktemp)
# shellcheck disable=SC2329  # the stubs are invoked indirectly by comms_watchdog
(
  _FAKE_NOW=0
  watchdog_epoch() { printf '%s' "$_FAKE_NOW"; }
  # Advance fake time by the check interval (15, matching the exported env)
  # instead of waiting; end the scenario past t=1300.
  sleep() {
    _FAKE_NOW=$((_FAKE_NOW + 15))
    [ "$_FAKE_NOW" -le 1300 ] || exit 0
  }
  comms_fresh() { return 1; }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$_FAKE_NOW" >>"$RESTART_LOG"
    return 0
  }
  comms_watchdog
) 2>"$WATCHDOG_ERR"
attempts=$(($(wc -l <"$RESTART_LOG")))
if [ "$attempts" -ne 5 ]; then
  err "FAIL: watchdog cadence: expected 5 restart attempts by t=1300, got $attempts"
  fail=1
else
  t1=$(awk 'NR==1{print $2}' "$RESTART_LOG")
  t2=$(awk 'NR==2{print $2}' "$RESTART_LOG")
  t3=$(awk 'NR==3{print $2}' "$RESTART_LOG")
  t4=$(awk 'NR==4{print $2}' "$RESTART_LOG")
  if [ $((t2 - t1)) -gt 120 ]; then
    err "FAIL: fast-stage attempts not on the fast cadence (t1=$t1 t2=$t2)"
    fail=1
  fi
  if [ $((t4 - t3)) -lt 450 ]; then
    err "FAIL: stage-2 attempt did not back off (t3=$t3 t4=$t4, want >=450s gap)"
    fail=1
  fi
fi
rm -f "$WATCHDOG_ERR" "$RESTART_LOG"

#    Recovery resets both the stale window and the restart budget: stale from
#    t=15 (attempt 1 at t=105), fresh during t=150-299 (recovery logged),
#    stale again from t=300 — the next attempt must be numbered 1 again.
WATCHDOG_ERR=$(mktemp)
RESTART_LOG=$(mktemp)
# shellcheck disable=SC2329  # the stubs are invoked indirectly by comms_watchdog
(
  _FAKE_NOW=0
  watchdog_epoch() { printf '%s' "$_FAKE_NOW"; }
  sleep() {
    _FAKE_NOW=$((_FAKE_NOW + 15))
    [ "$_FAKE_NOW" -le 400 ] || exit 0
  }
  comms_fresh() { [ "$_FAKE_NOW" -ge 150 ] && [ "$_FAKE_NOW" -lt 300 ]; }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$_FAKE_NOW" >>"$RESTART_LOG"
    return 0
  }
  comms_watchdog
) 2>"$WATCHDOG_ERR"
if ! grep -q 'comms watchdog UPS comms recovered.*restarts=1' "$WATCHDOG_ERR"; then
  err "FAIL: watchdog recovery not logged after comms returned"
  fail=1
fi
second_attempt_no=$(awk 'NR==2{print $1}' "$RESTART_LOG")
if [ "${second_attempt_no:-}" != "1" ]; then
  err "FAIL: restart budget not reset after recovery (second attempt numbered ${second_attempt_no:-none})"
  fail=1
fi
rm -f "$WATCHDOG_ERR" "$RESTART_LOG"

#    Killpower stand-down: with host shutdown armed and NUT's POWERDOWNFLAG
#    present, the real restart_ups_driver must stand down (rc!=0, no driver
#    bounce) so a recovery can't fight a poweroff in progress.
KILLPOWER_ERR=$(mktemp)
if (
  # shellcheck disable=SC2034  # consumed by restart_ups_driver (sourced lifecycle.sh)
  SHUTDOWN_ON_BATTERY_CRITICAL=true
  touch /var/run/nut-secrets/killpower
  restart_ups_driver 1
) 2>"$KILLPOWER_ERR"; then
  err "FAIL: restart_ups_driver did not stand down with killpower set"
  fail=1
fi
rm -f /var/run/nut-secrets/killpower
if ! grep -q 'standing down' "$KILLPOWER_ERR"; then
  err "FAIL: killpower stand-down not logged"
  fail=1
fi
rm -f "$KILLPOWER_ERR"

# 6. Transport classification and device/D-Bus gates.
if ! (
  UPS_DRIVER='snmp-ups'
  [ "$(driver_transport)" = "net" ]
); then
  err "FAIL: snmp-ups not classified as a network transport"
  fail=1
fi
if ! (
  UPS_DRIVER='usbhid-ups'
  [ "$(driver_transport)" = "usb" ]
); then
  err "FAIL: usbhid-ups not classified as a USB transport"
  fail=1
fi
if (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='192.168.1.50'
  usb_bus_required
); then
  err "FAIL: usb_bus_required claims snmp-ups needs the USB bus"
  fail=1
fi
if ! (
  UPS_DRIVER='usbhid-ups'
  UPS_PORT='auto'
  usb_bus_required
); then
  err "FAIL: usb_bus_required denies the bus to usbhid-ups"
  fail=1
fi
if (
  UPS_DRIVER='apc_modbus'
  UPS_PORT='/dev/ttyUSB0'
  usb_bus_required
); then
  err "FAIL: usb_bus_required claims a serial node needs the USB bus"
  fail=1
fi
if ! (
  UPS_DRIVER='apc_modbus'
  UPS_PORT='auto'
  usb_bus_required
); then
  err "FAIL: usb_bus_required denies the bus to a dual-mode driver on auto"
  fail=1
fi
# No D-Bus socket is mounted in the test stage, so the poweroff-path gate
# must report broken.
if dbus_poweroff_path_ok; then
  err "FAIL: dbus_poweroff_path_ok returned success without a mounted D-Bus socket"
  fail=1
fi

[ "$fail" -eq 0 ] && log "nut-upsd smoke: ok"
exit "$fail"
