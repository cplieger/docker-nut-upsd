#!/bin/sh
# NUT notification handler — emits structured log lines for Alloy pickup.
# Invoked by upsmon for each event with NOTIFYFLAG ... EXEC.
# NUT passes NOTIFYTYPE, UPSNAME (upsmon's "upsname@hostname[:port]") and the message as $1.

# log_value: sanitize a value before interpolating it into a logfmt field, so
# untrusted text cannot corrupt or split the log record. Byte-identical copy of
# validate.sh's sanitizer — upsmon execs this handler as a standalone process, so
# it cannot rely on the helper already being sourced. validate.sh owns the
# BusyBox-tr octal-range rationale; parity across the copies is asserted.
log_value() {
  _lv=$(printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' ' | cut -c 1-512)
  if [ "${#1}" -le 512 ]; then
    printf '%s' "$_lv"
  else
    printf '%.509s...' "$_lv"
  fi
}

NOTIFYTYPE="${NOTIFYTYPE:-unknown}"
case "$NOTIFYTYPE" in
  ONLINE | COMMOK | NOT*) level=info ;;
  FSD | SHUTDOWN) level=error ;;
  *) level=warn ;;
esac

ups_name="${UPSNAME%%@*}"
printf 'level=%s msg="UPS event" event="%s" ups="%s" detail="%s"\n' \
  "$level" "$(log_value "$NOTIFYTYPE")" "$(log_value "${ups_name:-upsmon}")" \
  "$(log_value "${1:-}")" >&2
