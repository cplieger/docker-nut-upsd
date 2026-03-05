#!/bin/sh
set -eu

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
: "${ADMIN_PASSWORD:=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)}"
: "${POLLFREQ:=5}"
: "${POLLFREQALERT:=5}"
: "${DEADTIME:=15}"
: "${FINALDELAY:=5}"
: "${HOSTSYNC:=15}"
: "${NOCOMMWARNTIME:=300}"
: "${RBWARNTIME:=43200}"

# Host shutdown support via D-Bus (requires /run/dbus mount)
: "${SHUTDOWN_ON_BATTERY_CRITICAL:=false}"

if [ "$API_PASSWORD" = "secret" ]; then
    echo "Warning: API_PASSWORD is using the default value 'secret' — set a secure password" >&2
fi

# ---------------------------------------------------------------------------
# USB device validation
# ---------------------------------------------------------------------------
if [ ! -d /dev/bus/usb ]; then
    echo "Error: /dev/bus/usb not found — map a USB device to the container" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine SHUTDOWNCMD
# ---------------------------------------------------------------------------
if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" = "true" ]; then
    if [ ! -S /run/dbus/system_bus_socket ]; then
        echo "Error: SHUTDOWN_ON_BATTERY_CRITICAL=true but /run/dbus/system_bus_socket is not mounted" >&2
        exit 1
    fi
    SHUTDOWN_CMD="dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.PowerOff boolean:true"
    echo "Host shutdown enabled via D-Bus on battery critical" >&2
else
    SHUTDOWN_CMD="logger -t nut-upsd 'UPS forced shutdown (FSD) triggered'"
fi

# ---------------------------------------------------------------------------
# nut.conf — always generated (MODE is not user-configurable)
# ---------------------------------------------------------------------------
cat > /etc/nut/nut.conf <<'EOF'
MODE=netserver
EOF

# ---------------------------------------------------------------------------
# ups.conf — skip if user-mounted
# ---------------------------------------------------------------------------
if [ ! -e /etc/nut/ups.conf.user ]; then
    cat > /etc/nut/ups.conf <<UPSEOF
[$UPS_NAME]
    desc = "$UPS_DESC"
    driver = $UPS_DRIVER
    port = $UPS_PORT
    pollonly
UPSEOF

    # Battery overrides (ignorelb tells NUT to use our thresholds instead of hardware)
    if [ -n "${LOWBATT_PERCENT:-}" ] || [ -n "${LOWBATT_RUNTIME:-}" ] \
       || [ -n "${CRITBATT_PERCENT:-}" ] || [ -n "${CRITBATT_RUNTIME:-}" ]; then
        printf '    ignorelb\n' >> /etc/nut/ups.conf
    fi

    # Low-battery overrides
    [ -n "${LOWBATT_PERCENT:-}" ] && \
        printf '    override.battery.charge.low = %s\n' "$LOWBATT_PERCENT" >> /etc/nut/ups.conf
    [ -n "${LOWBATT_RUNTIME:-}" ] && \
        printf '    override.battery.runtime.low = %s\n' "$LOWBATT_RUNTIME" >> /etc/nut/ups.conf

    # Critical-battery overrides
    [ -n "${CRITBATT_PERCENT:-}" ] && \
        printf '    override.battery.charge.critical = %s\n' "$CRITBATT_PERCENT" >> /etc/nut/ups.conf
    [ -n "${CRITBATT_RUNTIME:-}" ] && \
        printf '    override.battery.runtime.critical = %s\n' "$CRITBATT_RUNTIME" >> /etc/nut/ups.conf
else
    cp /etc/nut/ups.conf.user /etc/nut/ups.conf
    echo "Using mounted ups.conf.user" >&2
fi

# ---------------------------------------------------------------------------
# upsd.conf — skip if user-mounted
# ---------------------------------------------------------------------------
if [ ! -e /etc/nut/upsd.conf.user ]; then
    cat > /etc/nut/upsd.conf <<UPSDEOF
LISTEN $API_ADDRESS $API_PORT
UPSDEOF
else
    cp /etc/nut/upsd.conf.user /etc/nut/upsd.conf
    echo "Using mounted upsd.conf.user" >&2
fi

# ---------------------------------------------------------------------------
# upsd.users — skip if user-mounted
# ---------------------------------------------------------------------------
if [ ! -e /etc/nut/upsd.users.user ]; then
    cat > /etc/nut/upsd.users <<USERSEOF
[admin]
    password = "$ADMIN_PASSWORD"
    actions = set
    actions = fsd
    instcmds = all

[$API_USER]
    password = "$API_PASSWORD"
    upsmon primary
USERSEOF
else
    cp /etc/nut/upsd.users.user /etc/nut/upsd.users
    echo "Using mounted upsd.users.user" >&2
fi

# ---------------------------------------------------------------------------
# upsmon.conf — skip if user-mounted
# ---------------------------------------------------------------------------
if [ ! -e /etc/nut/upsmon.conf.user ]; then
    cat > /etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@localhost 1 "$API_USER" "$API_PASSWORD" primary
SHUTDOWNCMD "$SHUTDOWN_CMD"
POWERDOWNFLAG /var/run/nut/killpower
NOTIFYCMD /usr/bin/logger
POLLFREQ $POLLFREQ
POLLFREQALERT $POLLFREQALERT
DEADTIME $DEADTIME
FINALDELAY $FINALDELAY
HOSTSYNC $HOSTSYNC
NOCOMMWARNTIME $NOCOMMWARNTIME
RBWARNTIME $RBWARNTIME
MONEOF
else
    cp /etc/nut/upsmon.conf.user /etc/nut/upsmon.conf
    echo "Using mounted upsmon.conf.user" >&2
fi

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
chgrp -R nut /etc/nut
chmod -R 640 /etc/nut/*
chmod 750 /etc/nut
chgrp -R nut /dev/bus/usb

# ---------------------------------------------------------------------------
# Start NUT services with signal handling
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317
cleanup() {
    echo "Shutting down NUT services..." >&2
    /usr/sbin/upsmon -c stop 2>/dev/null || true
    /usr/sbin/upsd -c stop 2>/dev/null || true
    /usr/sbin/upsdrvctl stop 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

/usr/sbin/upsdrvctl start
/usr/sbin/upsd

# Run upsmon in the background so the trap can fire
/usr/sbin/upsmon -D &
UPSMON_PID=$!

# Wait for upsmon — propagate its exit code on unexpected exit
wait "$UPSMON_PID"
exit $?
