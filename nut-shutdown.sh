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

# log_value: sanitize captured tool output for a logfmt detail="..." field —
# strip quotes/backslashes, flatten everything outside printable ASCII to
# spaces (same pattern nut-notify.sh uses standalone). The octal RANGE
# \040-\176 is deliberate: BusyBox tr treats a complemented character CLASS
# (tr -c '[:print:]') as a literal set, mangling every value — do not
# "simplify" this back to a class. LC_ALL=C pins the byte semantics.
log_value() {
  printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' '
}

printf 'level=error msg="UPS forced shutdown triggered; powering off host"\n' >&2

attempt=1
while [ "$attempt" -le "$DBUS_MAX_RETRIES" ]; do
  # Outer timeout bounds the whole call: --reply-timeout does not cover D-Bus
  # connect/auth, so a wedged dbus-daemon could otherwise hang this retry loop
  # mid-FSD. $() capture is safe here (dbus-send spawns no fd-holding
  # grandchildren); folding the output into the structured lines keeps the
  # container log logfmt-clean at the highest-stakes moment.
  if _out=$(timeout 5 dbus-send --system --print-reply --reply-timeout="$DBUS_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.PowerOff boolean:false 2>&1); then
    printf 'level=info msg="host poweroff dispatched via D-Bus" attempt=%d\n' "$attempt" >&2
    exit 0
  fi
  if [ "$attempt" -lt "$DBUS_MAX_RETRIES" ]; then
    printf 'level=warn msg="D-Bus poweroff failed, retrying" attempt=%d detail="%s"\n' "$attempt" "$(log_value "$_out")" >&2
    sleep "$DBUS_RETRY_SLEEP"
  fi
  attempt=$((attempt + 1))
done

printf 'level=error msg="D-Bus poweroff failed after %d attempts; host will NOT shut down cleanly" detail="%s"\n' "$DBUS_MAX_RETRIES" "$(log_value "${_out:-}")" >&2
# The poweroff conclusively failed, so no shutdown is in progress anymore.
# Clear NUT's POWERDOWNFLAG so the comms watchdog's killpower stand-down
# (lifecycle.sh restart_ups_driver) does not stay latched for the rest of
# the container's life; nothing else in this container consumes the flag.
# The flag lives in the root-only /var/run/nut-secrets (this script runs as
# root via upsmon's privileged parent, so it can clear it).
if rm -f /var/run/nut-secrets/killpower; then
  printf 'level=warn msg="cleared killpower flag after failed poweroff so USB comms recovery stays armed"\n' >&2
else
  printf 'level=error msg="failed to clear killpower flag after failed poweroff; USB comms recovery may stay disarmed"\n' >&2
fi
exit 1
