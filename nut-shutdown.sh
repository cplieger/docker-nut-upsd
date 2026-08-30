#!/bin/sh
# Host shutdown helper: upsmon's SHUTDOWNCMD when SHUTDOWN_ON_BATTERY_CRITICAL=true.
readonly DBUS_MAX_RETRIES=3
readonly DBUS_RETRY_SLEEP=2
readonly DBUS_REPLY_TIMEOUT_MS=3000

# log_value: byte-identical copy of validate.sh's sanitizer — upsmon execs this
# handler standalone, so it cannot source the helper. validate.sh owns the
# BusyBox-tr octal-range rationale; parity across the copies is asserted.
log_value() {
  _lv=$(printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' ' | cut -c 1-513)
  if [ "${#_lv}" -le 512 ]; then
    printf '%s' "$_lv"
  else
    printf '%.509s...' "$_lv"
  fi
}

printf 'level=error msg="UPS forced shutdown triggered; powering off host"\n' >&2

attempt=1
while [ "$attempt" -le "$DBUS_MAX_RETRIES" ]; do
  # Outer bound covers connect/auth, which --reply-timeout does not: a wedged
  # dbus-daemon must not hang this loop mid-FSD. The brace group's redirect
  # covers the reporting shell too, so its signal-death message lands in detail=.
  if _out=$({ timeout 5 dbus-send --system --print-reply --reply-timeout="$DBUS_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager.PowerOff boolean:false; } 2>&1); then
    printf 'level=info msg="host poweroff dispatched via D-Bus" attempt=%d\n' "$attempt" >&2
    exit 0
  fi
  if [ "$attempt" -lt "$DBUS_MAX_RETRIES" ]; then
    printf 'level=warn msg="D-Bus poweroff failed, retrying" attempt=%d detail="%s"\n' "$attempt" "$(log_value "$_out")" >&2
    sleep "$DBUS_RETRY_SLEEP"
  fi
  attempt=$((attempt + 1))
done

printf 'level=error msg="D-Bus poweroff failed after %d attempts; host poweroff NOT confirmed" detail="%s"\n' "$DBUS_MAX_RETRIES" "$(log_value "$_out")" >&2
# Clear NUT's POWERDOWNFLAG: a latched flag keeps restart_ups_driver
# (lifecycle.sh) stood down for whatever container life remains after the
# failed poweroff. Root-only path; upsmon's privileged parent runs this as root.
if rm -f /var/run/nut-secrets/killpower; then
  printf 'level=warn msg="cleared killpower flag after failed poweroff so USB comms recovery stays armed"\n' >&2
else
  printf 'level=error msg="failed to clear killpower flag after failed poweroff; USB comms recovery may stay disarmed"\n' >&2
fi
exit 1
