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
  COMMS_FAST_RETRIES=3 COMMS_BACKOFF_FACTOR=5

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

# 3. Validation rejects config-injection attempts (run_validations exits non-
#    zero on failure, so each negative case runs in a subshell).
if (
  UPS_NAME='bad]name'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: bracket-injection UPS_NAME was accepted"
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

# 4. Comms-recovery watchdog helpers are defined (sourced from lifecycle.sh).
for fn in comms_fresh restart_ups_driver comms_watchdog stop_watchdog; do
  # stop_watchdog lives in entrypoint.sh (not sourced here); only assert the
  # lifecycle.sh helpers.
  case "$fn" in stop_watchdog) continue ;; esac
  if ! command -v "$fn" >/dev/null 2>&1; then
    err "FAIL: comms watchdog function missing: $fn"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && log "nut-upsd smoke: ok"
exit "$fail"
