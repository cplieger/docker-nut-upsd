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
    printf 'level=warn msg="API_PASSWORD is using the default value — set a secure password"\n' >&2
fi

# ---------------------------------------------------------------------------
# Input validation — reject values that could inject NUT config directives
# ---------------------------------------------------------------------------
validate_no_newlines() {
    # Count lines — a clean value has exactly 1 line (or 0 if empty).
    # An injected newline produces 2+ lines.
    line_count=$(printf '%s' "$2" | wc -l)
    if [ "$line_count" -gt 0 ]; then
        printf 'level=error msg="env var contains newlines" var=%s\n' "$1" >&2
        exit 1
    fi
}

validate_numeric() {
    case "$2" in
        ''|*[!0-9]*)
            printf 'level=error msg="env var must be a positive integer" var=%s value="%s"\n' "$1" "$2" >&2
            exit 1
            ;;
    esac
}

validate_no_brackets() {
    case "$2" in
        *"["*|*"]"*)
            printf 'level=error msg="env var contains bracket characters" var=%s\n' "$1" >&2
            exit 1
            ;;
    esac
}

validate_no_quotes() {
    case "$2" in
        *'"'*)
            printf 'level=error msg="env var contains double-quote" var=%s\n' "$1" >&2
            exit 1
            ;;
    esac
}

validate_no_newlines "UPS_NAME" "$UPS_NAME"
validate_no_newlines "UPS_DESC" "$UPS_DESC"
validate_no_newlines "UPS_DRIVER" "$UPS_DRIVER"
validate_no_newlines "UPS_PORT" "$UPS_PORT"
validate_no_newlines "API_USER" "$API_USER"
validate_no_newlines "API_PASSWORD" "$API_PASSWORD"
validate_no_newlines "API_ADDRESS" "$API_ADDRESS"
validate_no_newlines "API_PORT" "$API_PORT"
validate_no_newlines "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
validate_no_newlines "SHUTDOWN_ON_BATTERY_CRITICAL" "$SHUTDOWN_ON_BATTERY_CRITICAL"

# Validate numeric parameters
validate_numeric "API_PORT" "$API_PORT"
validate_numeric "POLLFREQ" "$POLLFREQ"
validate_numeric "POLLFREQALERT" "$POLLFREQALERT"
validate_numeric "DEADTIME" "$DEADTIME"
validate_numeric "FINALDELAY" "$FINALDELAY"
validate_numeric "HOSTSYNC" "$HOSTSYNC"
validate_numeric "NOCOMMWARNTIME" "$NOCOMMWARNTIME"
validate_numeric "RBWARNTIME" "$RBWARNTIME"

# Validate optional battery threshold overrides (numeric when set)
for var in LOWBATT_PERCENT LOWBATT_RUNTIME CRITBATT_PERCENT CRITBATT_RUNTIME; do
    eval "val=\${${var}:-}"
    if [ -n "$val" ]; then
        validate_no_newlines "$var" "$val"
        validate_numeric "$var" "$val"
    fi
done

# Reject bracket characters in UPS_NAME and API_USER to prevent section injection
validate_no_brackets "UPS_NAME" "$UPS_NAME"
validate_no_brackets "API_USER" "$API_USER"

# Reject double-quote characters that would break NUT config file quoting
validate_no_quotes "UPS_DESC" "$UPS_DESC"
validate_no_quotes "API_USER" "$API_USER"
validate_no_quotes "API_PASSWORD" "$API_PASSWORD"
validate_no_quotes "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
validate_no_quotes "UPS_NAME" "$UPS_NAME"

# Reject spaces/tabs in UPS_NAME (NUT doesn't support them, and they break
# the healthcheck's upsc command due to shell word-splitting)
case "$UPS_NAME" in
    *" "*|*"	"*)
        printf 'level=error msg="UPS_NAME must not contain spaces or tabs"\n' >&2
        exit 1
        ;;
esac

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
if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" = "true" ]; then
    if [ ! -S /run/dbus/system_bus_socket ]; then
        printf 'level=error msg="SHUTDOWN_ON_BATTERY_CRITICAL=true but D-Bus socket not mounted"\n' >&2
        exit 1
    fi
    SHUTDOWN_CMD="dbus-send --system --print-reply --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.PowerOff boolean:true"
    printf 'level=info msg="host shutdown enabled via D-Bus on battery critical"\n' >&2
else
    if [ "$SHUTDOWN_ON_BATTERY_CRITICAL" != "false" ]; then
        printf 'level=warn msg="unrecognized SHUTDOWN_ON_BATTERY_CRITICAL value, treating as false" value="%s"\n' \
            "$SHUTDOWN_ON_BATTERY_CRITICAL" >&2
    fi
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
    if [ -n "${LOWBATT_PERCENT:-}" ]; then
        printf '    override.battery.charge.low = %s\n' "$LOWBATT_PERCENT" >> /etc/nut/ups.conf
    fi
    if [ -n "${LOWBATT_RUNTIME:-}" ]; then
        printf '    override.battery.runtime.low = %s\n' "$LOWBATT_RUNTIME" >> /etc/nut/ups.conf
    fi

    # Critical-battery overrides
    if [ -n "${CRITBATT_PERCENT:-}" ]; then
        printf '    override.battery.charge.critical = %s\n' "$CRITBATT_PERCENT" >> /etc/nut/ups.conf
    fi
    if [ -n "${CRITBATT_RUNTIME:-}" ]; then
        printf '    override.battery.runtime.critical = %s\n' "$CRITBATT_RUNTIME" >> /etc/nut/ups.conf
    fi
else
    cp /etc/nut/ups.conf.user /etc/nut/ups.conf
    printf 'level=info msg="using mounted ups.conf.user"\n' >&2
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
    printf 'level=info msg="using mounted upsd.conf.user"\n' >&2
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
    printf 'level=info msg="using mounted upsd.users.user"\n' >&2
fi

# ---------------------------------------------------------------------------
# upsmon.conf — skip if user-mounted
# ---------------------------------------------------------------------------
if [ ! -e /etc/nut/upsmon.conf.user ]; then
    cat > /etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@127.0.0.1 1 "$API_USER" "$API_PASSWORD" primary
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
    printf 'level=info msg="using mounted upsmon.conf.user"\n' >&2
fi

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
chown -R root:nut /etc/nut
find /etc/nut -type d -exec chmod 750 {} +
find /etc/nut -type f -exec chmod 640 {} +
chgrp -R nut /dev/bus/usb

# ---------------------------------------------------------------------------
# Start NUT services with signal handling
# ---------------------------------------------------------------------------
# shellcheck disable=SC2317,SC2329
cleanup() {
    printf 'level=info msg="shutting down NUT services"\n' >&2
    /usr/sbin/upsmon -c stop || true
    /usr/sbin/upsd -c stop || true
    /usr/sbin/upsdrvctl stop || true
    exit 0
}
trap cleanup TERM INT

printf 'level=info msg="starting NUT services" ups=%s driver=%s port=%s listen=%s:%s\n' \
    "$UPS_NAME" "$UPS_DRIVER" "$UPS_PORT" "$API_ADDRESS" "$API_PORT" >&2

printf 'level=info msg="starting upsdrvctl"\n' >&2
/usr/sbin/upsdrvctl start
printf 'level=info msg="starting upsd"\n' >&2
/usr/sbin/upsd

# Run upsmon in the background so the trap can fire
printf 'level=info msg="starting upsmon"\n' >&2
/usr/sbin/upsmon -D &
UPSMON_PID=$!

printf 'level=info msg="NUT services started successfully"\n' >&2

# Wait for upsmon — propagate its exit code on unexpected exit
wait "$UPSMON_PID"
exit $?
