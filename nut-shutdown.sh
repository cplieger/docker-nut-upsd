#!/bin/sh
# Host shutdown helper invoked by upsmon's SHUTDOWNCMD when
# SHUTDOWN_ON_BATTERY_CRITICAL=true. Tries D-Bus powerOff with retries;
# logs structured level lines for Alloy pickup.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly DBUS_MAX_RETRIES=3
readonly DBUS_RETRY_SLEEP=2
readonly DBUS_REPLY_TIMEOUT_MS=3000

printf 'level=error msg="UPS forced shutdown triggered; powering off host"\n' >&2

attempt=1
while [ "$attempt" -le "$DBUS_MAX_RETRIES" ]; do
  if dbus-send --system --print-reply --reply-timeout="$DBUS_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.PowerOff boolean:false >&2; then
    printf 'level=info msg="host poweroff dispatched via D-Bus" attempt=%d\n' "$attempt" >&2
    exit 0
  fi
  if [ "$attempt" -lt "$DBUS_MAX_RETRIES" ]; then
    printf 'level=warn msg="D-Bus poweroff failed, retrying" attempt=%d\n' "$attempt" >&2
    sleep "$DBUS_RETRY_SLEEP"
  fi
  attempt=$((attempt + 1))
done

printf 'level=error msg="D-Bus poweroff failed after %d attempts; host will NOT shut down cleanly"\n' "$DBUS_MAX_RETRIES" >&2
# The poweroff conclusively failed, so no shutdown is in progress anymore.
# Clear NUT's POWERDOWNFLAG so the comms watchdog's killpower stand-down
# (lifecycle.sh restart_ups_driver) does not stay latched for the rest of
# the container's life; nothing else in this container consumes the flag.
rm -f /var/run/nut/killpower
printf 'level=warn msg="cleared killpower flag after failed poweroff so USB comms recovery stays armed"\n' >&2
exit 1
