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
