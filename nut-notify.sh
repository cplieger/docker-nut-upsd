#!/bin/sh
# NUT notification handler — emits structured log lines for Alloy pickup.
# Invoked by upsmon for each event with NOTIFYFLAG ... EXEC.
# NUT passes the notification type in NOTIFYTYPE and the message as $1.

# log_value: sanitize the raw message before interpolating it into the logfmt
# detail="..." field — strip double quotes/backslashes and flatten everything
# outside printable ASCII to spaces so a custom NOTIFYMSG cannot corrupt or
# split the log record. Mirrors validate.sh's log_value (this handler runs
# standalone via NOTIFYCMD, so it cannot rely on the sourced helper). The
# octal RANGE \040-\176 is deliberate: BusyBox tr treats a complemented
# character CLASS (tr -c '[:print:]') as a literal set, mangling every value
# — do not "simplify" this back to a class. LC_ALL=C pins the byte semantics.
log_value() {
  printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' '
}

NOTIFYTYPE="${NOTIFYTYPE:-unknown}"
case "$NOTIFYTYPE" in
  ONLINE | COMMOK) level=info ;;
  ONBATT | LOWBATT | COMMBAD | NOCOMM | REPLBATT) level=warn ;;
  FSD | SHUTDOWN) level=error ;;
  *) level=warn ;;
esac

printf 'level=%s msg="UPS event" event=%s ups=%s detail="%s"\n' \
  "$level" "$NOTIFYTYPE" "${UPSNAME:-unknown}" "$(log_value "${1:-}")" >&2
