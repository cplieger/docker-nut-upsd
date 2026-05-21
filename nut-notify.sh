#!/bin/sh
# NUT notification handler — emits structured log lines for Alloy pickup.
# Invoked by upsmon for each event with NOTIFYFLAG ... EXEC.
# NUT passes the notification type in NOTIFYTYPE and the message as $1.

level=info
case "$NOTIFYTYPE" in
ONBATT | LOWBATT | COMMBAD | NOCOMM | REPLBATT) level=warn ;;
FSD | SHUTDOWN) level=error ;;
esac

printf 'level=%s msg="UPS event" event=%s ups=%s detail="%s"\n' \
	"$level" "$NOTIFYTYPE" "${UPSNAME:-unknown}" "${1:-}" >&2
