#!/bin/sh
# generate-config.sh — NUT config file generation helpers.
# Sourced by entrypoint.sh; not executed directly.

# ---------------------------------------------------------------------------
# Config generation helpers
# ---------------------------------------------------------------------------
# If /etc/nut/<name>.user exists, copy it over /etc/nut/<name> and return 0
# (caller skips generation). Return 1 otherwise.
use_user_override() {
	[ -e "/etc/nut/$1.user" ] || return 1
	if ! cp "/etc/nut/$1.user" "/etc/nut/$1"; then
		printf 'level=error msg="failed to apply mounted override; aborting" file=%s.user\n' "$1" >&2
		exit 1
	fi
	printf 'level=info msg="using mounted %s.user"\n' "$1" >&2
}

generate_all_configs() {
	# Required variables — fail fast if caller forgot to set them.
	: "${UPS_NAME:?generate_all_configs requires UPS_NAME}"
	: "${UPS_DRIVER:?generate_all_configs requires UPS_DRIVER}"
	: "${UPS_PORT:?generate_all_configs requires UPS_PORT}"
	: "${API_USER:?generate_all_configs requires API_USER}"
	: "${API_PASSWORD:?generate_all_configs requires API_PASSWORD}"
	: "${API_ADDRESS:?generate_all_configs requires API_ADDRESS}"
	: "${API_PORT:?generate_all_configs requires API_PORT}"
	: "${ADMIN_PASSWORD:?generate_all_configs requires ADMIN_PASSWORD}"
	: "${SHUTDOWN_CMD:?generate_all_configs requires SHUTDOWN_CMD}"
	: "${POLLFREQ:?generate_all_configs requires POLLFREQ}"
	: "${POLLFREQALERT:?generate_all_configs requires POLLFREQALERT}"
	: "${DEADTIME:?generate_all_configs requires DEADTIME}"
	: "${FINALDELAY:?generate_all_configs requires FINALDELAY}"
	: "${HOSTSYNC:?generate_all_configs requires HOSTSYNC}"
	: "${NOCOMMWARNTIME:?generate_all_configs requires NOCOMMWARNTIME}"
	: "${RBWARNTIME:?generate_all_configs requires RBWARNTIME}"

	# --- nut.conf — always generated (MODE is not user-configurable) ---
	cat >/etc/nut/nut.conf <<'EOF'
MODE=netserver
EOF

	# --- ups.conf — skip if user-mounted ---
	if ! use_user_override ups.conf; then
		cat >/etc/nut/ups.conf <<UPSEOF
[$UPS_NAME]
    desc = "$UPS_DESC"
    driver = $UPS_DRIVER
    port = $UPS_PORT
UPSEOF

		# pollonly is only meaningful for USB HID drivers; other drivers may
		# ignore it or warn. Emit it only when applicable.
		case "$UPS_DRIVER" in
		usbhid-ups | *_usb)
			printf '    pollonly\n' >>/etc/nut/ups.conf
			;;
		esac

		# Battery overrides (ignorelb tells NUT to use our thresholds instead of
		# hardware).
		if [ -n "${LOWBATT_PERCENT:-}" ] || [ -n "${LOWBATT_RUNTIME:-}" ] ||
			[ -n "${CRITBATT_PERCENT:-}" ] || [ -n "${CRITBATT_RUNTIME:-}" ]; then
			printf '    ignorelb\n' >>/etc/nut/ups.conf
		fi

		# Battery override directives — explicit per-variable to avoid eval.
		[ -n "${LOWBATT_PERCENT:-}" ] &&
			printf '    override.%s = %s\n' "battery.charge.low" "$LOWBATT_PERCENT" >>/etc/nut/ups.conf
		[ -n "${LOWBATT_RUNTIME:-}" ] &&
			printf '    override.%s = %s\n' "battery.runtime.low" "$LOWBATT_RUNTIME" >>/etc/nut/ups.conf
		[ -n "${CRITBATT_PERCENT:-}" ] &&
			printf '    override.%s = %s\n' "battery.charge.critical" "$CRITBATT_PERCENT" >>/etc/nut/ups.conf
		[ -n "${CRITBATT_RUNTIME:-}" ] &&
			printf '    override.%s = %s\n' "battery.runtime.critical" "$CRITBATT_RUNTIME" >>/etc/nut/ups.conf

		if [ -n "${LOWBATT_PERCENT:-}${LOWBATT_RUNTIME:-}${CRITBATT_PERCENT:-}${CRITBATT_RUNTIME:-}" ]; then
			printf 'level=info msg="battery thresholds overridden (ignorelb active)" low_pct=%s low_rt=%s crit_pct=%s crit_rt=%s\n' \
				"${LOWBATT_PERCENT:-unset}" "${LOWBATT_RUNTIME:-unset}" \
				"${CRITBATT_PERCENT:-unset}" "${CRITBATT_RUNTIME:-unset}" >&2
		else
			printf 'level=info msg="no battery threshold overrides; using UPS hardware defaults"\n' >&2
		fi
	fi

	# --- upsd.conf — skip if user-mounted ---
	if ! use_user_override upsd.conf; then
		cat >/etc/nut/upsd.conf <<UPSDEOF
LISTEN $API_ADDRESS $API_PORT
UPSDEOF
	fi

	# --- upsd.users — skip if user-mounted ---
	if ! use_user_override upsd.users; then
		cat >/etc/nut/upsd.users <<USERSEOF
[admin]
    password = "$ADMIN_PASSWORD"
    actions = set
    actions = fsd
    instcmds = all

[$API_USER]
    password = "$API_PASSWORD"
    upsmon primary
USERSEOF
	fi

	# --- upsmon.conf — skip if user-mounted ---
	if ! use_user_override upsmon.conf; then
		cat >/etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@127.0.0.1:$API_PORT 1 "$API_USER" "$API_PASSWORD" primary
SHUTDOWNCMD "$SHUTDOWN_CMD"
POWERDOWNFLAG /var/run/nut/killpower
NOTIFYCMD /usr/local/bin/nut-notify.sh
POLLFREQ $POLLFREQ
POLLFREQALERT $POLLFREQALERT
DEADTIME $DEADTIME
FINALDELAY $FINALDELAY
HOSTSYNC $HOSTSYNC
NOCOMMWARNTIME $NOCOMMWARNTIME
RBWARNTIME $RBWARNTIME
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC+WALL
NOTIFYFLAG LOWBATT SYSLOG+EXEC+WALL
NOTIFYFLAG FSD SYSLOG+EXEC+WALL
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC+WALL
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC
MONEOF
	fi
}
