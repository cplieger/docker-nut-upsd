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
	printf 'level=error msg="%s did not write a valid PID file within 5s" path=%s\n' "$1" "$2" >&2
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
	timeout 3 upsc "${UPS_NAME}@127.0.0.1" ups.status > /dev/null 2>&1
}

# restart_ups_driver: re-home the driver onto the (possibly re-enumerated) USB
# node. Runs as root (PID 1 lineage). Re-asserts nut group + rw on the bus so
# the driver's own reconnect attempts can also open a freshly created
# root:root node, then bounces the driver. The restart re-opens the device
# while still root (upsdrvctl runs as root and the driver drops to nut only
# AFTER opening), so it succeeds regardless of the new node's group. A wedged
# driver is hard-killed by pidfile because `upsdrvctl stop` alone has been
# observed to fail to reap it ("Stopping ...pid failed: Permission denied").
restart_ups_driver() {
	printf 'level=warn msg="comms watchdog re-homing UPS driver after stale comms" ups=%s\n' "$UPS_NAME" >&2
	chgrp -R nut /dev/bus/usb 2> /dev/null || true
	chmod -R g+rw /dev/bus/usb 2> /dev/null || true
	/usr/sbin/upsdrvctl stop "$UPS_NAME" > /dev/null 2>&1 || true
	_pf="/var/run/nut/${UPS_DRIVER}-${UPS_NAME}.pid"
	if [ -s "$_pf" ] && kill -0 "$(cat "$_pf")" 2> /dev/null; then
		kill -9 "$(cat "$_pf")" 2> /dev/null || true
	fi
	rm -f "$_pf"
	if /usr/sbin/upsdrvctl start "$UPS_NAME" > /dev/null 2>&1; then
		printf 'level=info msg="comms watchdog driver restart issued" ups=%s\n' "$UPS_NAME" >&2
	else
		printf 'level=error msg="comms watchdog driver restart failed" ups=%s\n' "$UPS_NAME" >&2
	fi
}

# comms_watchdog: probe upsd every COMMS_CHECK_INTERVAL seconds; once comms is
# stale continuously for COMMS_RECOVERY_TIMEOUT seconds, re-home the driver.
# The default timeout (90s) is well inside the upstream UPSDataAbsent alert
# window (for:5m) so a USB reset self-heals before it pages.
comms_watchdog() {
	: "${UPS_NAME:?comms_watchdog requires UPS_NAME}"
	: "${UPS_DRIVER:?comms_watchdog requires UPS_DRIVER}"
	: "${COMMS_CHECK_INTERVAL:?comms_watchdog requires COMMS_CHECK_INTERVAL}"
	: "${COMMS_RECOVERY_TIMEOUT:?comms_watchdog requires COMMS_RECOVERY_TIMEOUT}"
	_stale=0
	while sleep "$COMMS_CHECK_INTERVAL"; do
		if comms_fresh; then
			if [ "$_stale" -gt 0 ]; then
				printf 'level=info msg="comms watchdog UPS comms recovered" ups=%s stale_secs=%d\n' \
					"$UPS_NAME" "$_stale" >&2
			fi
			_stale=0
		else
			_stale=$((_stale + COMMS_CHECK_INTERVAL))
			if [ "$_stale" -ge "$COMMS_RECOVERY_TIMEOUT" ]; then
				restart_ups_driver
				_stale=0
			fi
		fi
	done
}
