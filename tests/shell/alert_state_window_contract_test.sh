#!/usr/bin/env bash
# Holds each state alert's range above twice the shipped producer cadence.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

ALERTS="${ALERTS:-$REPO_ROOT/alerts.yaml}"
ENTRYPOINT_FILE="${ENTRYPOINT_FILE:-$REPO_ROOT/entrypoint.sh}"

rule_window_seconds() {
  local alert=$1 raw number unit factor
  raw=$(awk -v want="- alert: $alert" '
    $0 ~ want "$" { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule { print }
  ' "$ALERTS" \
    | sed -n 's/.*\[\([0-9][0-9]*\)\([smhd]\)\].*/\1 \2/p' | head -1)
  if [ -z "$raw" ]; then
    printf 'harness error: no range selector found for %s\n' "$alert" >&2
    exit 1
  fi
  number=${raw% *}
  unit=${raw#* }
  case "$unit" in
    s) factor=1 ;;
    m) factor=60 ;;
    h) factor=3600 ;;
    d) factor=86400 ;;
    *)
      printf 'harness error: unsupported range unit %s for %s\n' "$unit" "$alert" >&2
      exit 1
      ;;
  esac
  printf '%d\n' "$((number * factor))"
}

default_seconds() {
  local var=$1 value
  value=$(sed -n 's/^: "${'"$var"':=\([0-9][0-9]*\)}"$/\1/p' "$ENTRYPOINT_FILE")
  if [ -z "$value" ]; then
    printf 'harness error: no numeric default found for %s\n' "$var" >&2
    exit 1
  fi
  printf '%d\n' "$value"
}

check_pair() {
  local alert=$1 var=$2 window cadence
  window=$(rule_window_seconds "$alert")
  cadence=$(default_seconds "$var")
  if [ "$window" -gt "$((2 * cadence))" ]; then
    ok "$alert range (${window}s) stays above twice $var's shipped default (${cadence}s)"
  else
    no "$alert/$var cadence contract" "range=${window}s must be greater than $((2 * cadence))s"
  fi
}

check_pair UPSCommsLost NOCOMMWARNTIME
check_pair UPSPowerOffPathBroken DBUS_PROBE_INTERVAL

on_battery_annotation=$(awk '
  /^[[:space:]]*#/ { leading = leading $0 ORS; next }
  /^[[:space:]]*$/ { leading = leading ORS; next }
  /^[[:space:]]*- alert: UPSOnBattery$/ {
    printf "%s", leading
    found = 1
    exit
  }
  { leading = "" }
  END { if (!found) exit 1 }
' "$ALERTS") || {
  printf 'harness error: UPSOnBattery leading annotation not found\n' >&2
  exit 1
}

if printf '%s\n' "$on_battery_annotation" | grep -qw POLLFREQ \
  && printf '%s\n' "$on_battery_annotation" | grep -qw POLLFREQALERT; then
  ok 'UPSOnBattery sizing annotation names both POLLFREQ and POLLFREQALERT'
else
  no 'UPSOnBattery cadence annotation' 'both polling knobs must be named'
fi

on_battery_window=$(rule_window_seconds UPSOnBattery)
pollfreq=$(default_seconds POLLFREQ)
pollfreqalert=$(default_seconds POLLFREQALERT)
if [ "$on_battery_window" -gt "$((pollfreq + pollfreqalert))" ]; then
  ok "UPSOnBattery range (${on_battery_window}s) clears the combined default polling gap (${pollfreq}s + ${pollfreqalert}s)"
else
  no 'UPSOnBattery polling-gap range' "range=${on_battery_window}s; combined default gap=$((pollfreq + pollfreqalert))s"
fi

report
