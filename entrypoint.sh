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
: "${UPS_DESC:=UPS}"
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

# Host shutdown support via D-Bus (requires /run/dbus mount)
: "${SHUTDOWN_ON_BATTERY_CRITICAL:=false}"

# ---------------------------------------------------------------------------
# Password resolution (from password.sh)
# ---------------------------------------------------------------------------
resolve_admin_password
warn_weak_api_password

# ---------------------------------------------------------------------------
# Input validation (table-driven, from validate.sh)
# ---------------------------------------------------------------------------
run_validations

# ---------------------------------------------------------------------------
# USB device validation
# ---------------------------------------------------------------------------
if [ ! -d /dev/bus/usb ]; then
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

case "$SHUTDOWN_ON_BATTERY_CRITICAL" in
true)
	if [ ! -S /run/dbus/system_bus_socket ]; then
		printf 'level=error msg="SHUTDOWN_ON_BATTERY_CRITICAL=true but D-Bus socket not mounted"\n' >&2
		exit 1
	fi
	# shellcheck disable=SC2034  # consumed by sourced generate-config.sh
	SHUTDOWN_CMD="/usr/local/bin/nut-shutdown.sh"
	printf 'level=info msg="host shutdown enabled via D-Bus on battery critical"\n' >&2
	;;
false)
	printf 'level=info msg="host shutdown disabled; FSD will only log to stderr"\n' >&2
	;;
*)
	printf 'level=warn msg="unrecognized SHUTDOWN_ON_BATTERY_CRITICAL value, treating as false" value="%s"\n' \
		"$SHUTDOWN_ON_BATTERY_CRITICAL" >&2
	;;
esac

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
chgrp -R nut /dev/bus/usb
printf 'level=info msg="chgrp nut:/dev/bus/usb applied (host device nodes)"\n' >&2

# ---------------------------------------------------------------------------
# Start NUT services with signal handling
# ---------------------------------------------------------------------------

# Signal handler: clean up, then exit 0 (signal-initiated stop).
# shellcheck disable=SC2317,SC2329 # invoked via trap; shellcheck cannot see the call site
graceful_shutdown() {
	printf 'level=info msg="received shutdown signal"\n' >&2
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

printf 'level=info msg="starting upsdrvctl"\n' >&2
/usr/sbin/upsdrvctl start
# NUT drivers write /var/run/nut/<driver>-<ups>.pid on successful start.
wait_for_pidfile "UPS driver" "/var/run/nut/${UPS_DRIVER}-${UPS_NAME}.pid" || exit 1

printf 'level=info msg="starting upsd"\n' >&2
/usr/sbin/upsd
wait_for_pidfile "upsd" "/var/run/nut/upsd.pid" || exit 1

# Run upsmon in the background so the trap can fire
printf 'level=info msg="starting upsmon"\n' >&2
/usr/sbin/upsmon -D &
UPSMON_PID=$!

printf 'level=info msg="NUT services started successfully"\n' >&2

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
stop_services
exit "$rc"
