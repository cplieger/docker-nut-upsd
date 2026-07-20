#!/bin/sh
# NUT notification handler — emits structured log lines for Alloy pickup.
# Invoked by upsmon for each event with NOTIFYFLAG ... EXEC.
# NUT passes the notification type in NOTIFYTYPE and the message as $1.

# log_value: sanitize the raw message before interpolating it into the logfmt
# detail="..." field — strip double quotes/backslashes and flatten control
# characters so a custom NOTIFYMSG cannot corrupt or split the log record.
# Mirrors validate.sh's log_value (this handler runs standalone via NOTIFYCMD,
# so it cannot rely on the sourced helper).
log_value() {
  printf '%s' "$1" | tr -d '\\"' | tr -c '[:print:]' ' '
}

NOTIFYTYPE="${NOTIFYTYPE:-unknown}"
level=info
case "$NOTIFYTYPE" in
  ONLINE | COMMOK) level=info ;;
  ONBATT | LOWBATT | COMMBAD | NOCOMM | REPLBATT) level=warn ;;
  FSD | SHUTDOWN) level=error ;;
  *) level=warn ;;
esac

printf 'level=%s msg="UPS event" event=%s ups=%s detail="%s"\n' \
  "$level" "$NOTIFYTYPE" "${UPSNAME:-unknown}" "$(log_value "${1:-}")" >&2
