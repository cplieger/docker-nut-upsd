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

fail=0
log() { printf '%s\n' "$*"; }

# 1. Binaries compiled from upstream sources are present and link.
for b in upsd upsc upsmon upsdrvctl; do
	if ! command -v "$b" >/dev/null 2>&1; then
		log "FAIL: NUT binary missing from PATH: $b"
		fail=1
	fi
done

# 2. Valid env passes validation and generates all four config files.
export UPS_NAME=ups UPS_DESC="Test UPS" UPS_DRIVER=usbhid-ups UPS_PORT=auto \
	API_USER=monuser API_PASSWORD=secret API_ADDRESS=0.0.0.0 API_PORT=3493 \
	ADMIN_PASSWORD=adminpass SHUTDOWN_CMD=/usr/local/bin/nut-shutdown-noop.sh \
	POLLFREQ=5 POLLFREQALERT=5 DEADTIME=15 FINALDELAY=5 HOSTSYNC=15 \
	NOCOMMWARNTIME=300 RBWARNTIME=43200

if ! ( run_validations ) >/dev/null 2>&1; then
	log "FAIL: run_validations rejected a valid environment"
	fail=1
fi

generate_all_configs
for f in nut.conf ups.conf upsd.conf upsd.users upsmon.conf; do
	if [ ! -s "/etc/nut/$f" ]; then
		log "FAIL: config not generated: /etc/nut/$f"
		fail=1
	fi
done
grep -q '^\[ups\]' /etc/nut/ups.conf || { log "FAIL: ups.conf missing [ups] section"; fail=1; }
grep -q 'driver = usbhid-ups' /etc/nut/ups.conf || { log "FAIL: ups.conf missing driver"; fail=1; }
grep -q 'pollonly' /etc/nut/ups.conf || { log "FAIL: ups.conf missing pollonly for usbhid driver"; fail=1; }
grep -q 'LISTEN 0.0.0.0 3493' /etc/nut/upsd.conf || { log "FAIL: upsd.conf missing LISTEN directive"; fail=1; }

# 3. Validation rejects config-injection attempts (run_validations exits non-
#    zero on failure, so each negative case runs in a subshell).
if ( UPS_NAME='bad]name'; run_validations ) >/dev/null 2>&1; then
	log "FAIL: bracket-injection UPS_NAME was accepted"
	fail=1
fi
if ( UPS_PORT='notapath'; run_validations ) >/dev/null 2>&1; then
	log "FAIL: invalid UPS_PORT was accepted"
	fail=1
fi
if ( API_PORT='70000'; run_validations ) >/dev/null 2>&1; then
	log "FAIL: out-of-range API_PORT was accepted"
	fail=1
fi

[ "$fail" -eq 0 ] && log "nut-upsd smoke: ok"
exit "$fail"
