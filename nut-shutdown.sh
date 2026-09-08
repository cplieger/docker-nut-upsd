#!/bin/sh
# Host shutdown helper: upsmon's SHUTDOWNCMD when SHUTDOWN_ON_BATTERY_CRITICAL=true.
readonly DBUS_MAX_ATTEMPTS=3
readonly DBUS_RETRY_SLEEP=2
readonly DBUS_REPLY_TIMEOUT_MS=3000
# Above logind's InhibitDelayMaxSec default of 5s (systemd src/login/logind.conf.in:25).
readonly DBUS_SETTLE_SLEEP=8

# Outer bound covers connect/auth, which --reply-timeout does not: a wedged
# dbus-daemon must not hang the poweroff path mid-FSD. The stderr capture is
# what puts the cause in detail=, the shell's own signal-death line included.
dbus_call() {
  { timeout 5 dbus-send --system --print-reply --reply-timeout="$DBUS_REPLY_TIMEOUT_MS" \
    --dest=org.freedesktop.login1 /org/freedesktop/login1 "$@"; } 2>&1
}

# log_value: byte-identical copy of validate.sh's sanitizer — upsmon execs this
# handler as a standalone process, so it cannot rely on the helper already being
# sourced. validate.sh owns the BusyBox-tr octal-range rationale; parity across
# the copies is asserted.
log_value() {
  _lv=$(printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' ' | cut -c 1-512)
  if [ "${#1}" -le 512 ]; then
    printf '%s' "$_lv"
  else
    printf '%.509s...' "$_lv"
  fi
}

# clear_killpower: a latched POWERDOWNFLAG keeps restart_ups_driver
# (lifecycle.sh) stood down for whatever container life remains after a failed
# poweroff: the next driver bounce is about 105s away at the defaults, and the
# stand-down lasts until recreation or entrypoint clears the flag at next boot.
# Root-only path; upsmon's privileged parent runs this as root.
clear_killpower() {
  if rm -f /var/run/nut-secrets/killpower; then
    printf 'level=warn msg="cleared killpower flag after failed poweroff so USB comms recovery stays armed"\n' >&2
  else
    printf 'level=error msg="failed to clear killpower flag after failed poweroff; USB comms recovery may stay disarmed"\n' >&2
  fi
}

printf 'level=error msg="UPS forced shutdown triggered; powering off host"\n' >&2

attempt=1
while [ "$attempt" -le "$DBUS_MAX_ATTEMPTS" ]; do
  if _out=$(dbus_call org.freedesktop.login1.Manager.PowerOff boolean:false); then
    printf 'level=info msg="host poweroff dispatched via D-Bus" attempt=%d\n' "$attempt" >&2
    # logind replies before the action runs; PreparingForShutdown tracks delayed_action and is cleared however the queued job ends.
    # Queued failures reach only the host journal (systemd src/login/logind-dbus.c:2307-2312, :1951, :325-344).
    sleep "$DBUS_SETTLE_SLEEP"
    _settle=$(dbus_call org.freedesktop.DBus.Properties.Get \
      string:org.freedesktop.login1.Manager string:PreparingForShutdown) || :
    case "$_settle" in
      *'boolean true'*)
        printf 'level=info msg="logind still reports a pending poweroff after the settle wait" attempt=%d\n' "$attempt" >&2
        exit 0
        ;;
      *'boolean false'*)
        printf 'level=error msg="D-Bus poweroff failed after logind accepted the request; host poweroff NOT confirmed" attempt=%d detail="%s"\n' "$attempt" "$(log_value "$_settle")" >&2
        clear_killpower
        exit 1
        ;;
    esac
    # Outside UPSPowerOffFailed's matcher and clear_killpower on purpose: a
    # vanished bus is also the ordinary signature of a poweroff in progress,
    # so a critical alert and re-armed driver bounce would both act on a state
    # nothing here can decide.
    printf 'level=warn msg="D-Bus poweroff settle state unreadable; host poweroff neither confirmed nor refuted" attempt=%d detail="%s"\n' "$attempt" "$(log_value "$_settle")" >&2
    exit 0
  fi
  if [ "$attempt" -lt "$DBUS_MAX_ATTEMPTS" ]; then
    printf 'level=warn msg="D-Bus poweroff failed, retrying" attempt=%d detail="%s"\n' "$attempt" "$(log_value "$_out")" >&2
    sleep "$DBUS_RETRY_SLEEP"
  fi
  attempt=$((attempt + 1))
done

# A failed request does not refute the action: logind refuses a repeat while one
# is in flight, so a reply lost after dispatch or a poweroff another client
# started arrives here with the host already going down. PreparingForShutdown
# identifies any delayed shutdown-class action, not which action is in flight.
# A positive reply therefore diverts the killpower clear and inhibitor query,
# never the failure record. Anything else keeps the terminal record, because a
# wedged bus cannot distinguish an accepted poweroff from one never dispatched.
sleep "$DBUS_SETTLE_SLEEP"
_settle=$(dbus_call org.freedesktop.DBus.Properties.Get \
  string:org.freedesktop.login1.Manager string:PreparingForShutdown) || :
case "$_settle" in
  *'boolean true'*)
    printf 'level=error msg="D-Bus poweroff failed after %d attempts; logind reports a pending shutdown-class action, which may be a reboot or halt rather than this poweroff" detail="%s" settle="%s"\n' \
      "$DBUS_MAX_ATTEMPTS" "$(log_value "$_out")" "$(log_value "$_settle")" >&2
    exit 0
    ;;
esac
printf 'level=error msg="D-Bus poweroff failed after %d attempts; host poweroff NOT confirmed" detail="%s"\n' "$DBUS_MAX_ATTEMPTS" "$(log_value "$_out")" >&2
# Only a bus that answered can name a holder; on an unreadable settle the call
# can only repeat the line above at the cost of another outer-timeout window.
case "$_settle" in
  *'boolean false'*)
    _inhibitors=$(dbus_call org.freedesktop.login1.Manager.ListInhibitors) || :
    printf 'level=error msg="D-Bus poweroff inhibitors at failure" detail="%s"\n' "$(log_value "$_inhibitors")" >&2
    ;;
esac
clear_killpower
exit 1
