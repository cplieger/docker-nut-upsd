#!/bin/sh
set -eu

: "${UPS_NAME:=ups}"
: "${UPS_DESC:=UPS}"
: "${UPS_DRIVER:=usbhid-ups}"
: "${UPS_PORT:=auto}"
: "${API_USER:=monuser}"
: "${API_PASSWORD:=secret}"
: "${ADMIN_PASSWORD:=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 24)}"

if [ "$API_PASSWORD" = "secret" ]; then
    echo "Warning: API_PASSWORD is using the default value 'secret' — set a secure password" >&2
fi

# SHUTDOWNCMD runs inside the container, so it cannot power off the host.
# This container serves UPS data to NUT clients — each client host should
# run its own upsmon to handle local shutdown on battery critical events.
SHUTDOWN_CMD="logger -t nut-upsd 'UPS forced shutdown (FSD) triggered'"

cat > /etc/nut/nut.conf <<'EOF'
MODE=netserver
EOF

# ups.conf needs variable substitution
cat > /etc/nut/ups.conf <<UPSEOF
[$UPS_NAME]
    desc = "$UPS_DESC"
    driver = $UPS_DRIVER
    port = $UPS_PORT
    pollonly
UPSEOF

cat > /etc/nut/upsd.conf <<'EOF'
LISTEN 0.0.0.0 3493
EOF

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

cat > /etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@localhost 1 "$API_USER" "$API_PASSWORD" primary
SHUTDOWNCMD "$SHUTDOWN_CMD"
POWERDOWNFLAG /var/run/nut/killpower
NOTIFYCMD /usr/bin/logger
MONEOF

chgrp -R nut /etc/nut
chmod -R 640 /etc/nut/*
chmod 750 /etc/nut

if [ -e /dev/bus/usb ]; then
    chgrp -R nut /dev/bus/usb
fi

/usr/sbin/upsdrvctl start
/usr/sbin/upsd
exec /usr/sbin/upsmon -D
