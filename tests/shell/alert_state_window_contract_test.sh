#!/usr/bin/env bash
# Holds each state alert's range above twice the shipped producer cadence.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

ALERTS="${ALERTS:-$REPO_ROOT/alerts/logql.yaml}"
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

rule_text() {
  awk -v want="- alert: $1" '
    $0 ~ want "$" { inrule = 1; next }
    inrule && /- alert: / { exit }
    inrule { print }
  ' "$ALERTS" | tr -s '[:space:]' ' '
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

ENTRYPOINT="$REPO_ROOT/generate-config.sh"
new_workdir >/dev/null
load_function _emit_upsmon_conf

generated_upsmon=$(
  UPS_NAME=ups
  API_PORT=3493
  _mon_user=local_upsmon
  _mon_password=secret
  SHUTDOWN_CMD=/usr/local/bin/nut-shutdown-noop.sh
  POWERDOWNFLAG_FILE=/var/run/nut-secrets/killpower
  POLLFREQ=5
  POLLFREQALERT=5
  DEADTIME=15
  FINALDELAY=5
  HOSTSYNC=15
  NOCOMMWARNTIME=300
  RBWARNTIME=43200
  upsd_probe_host() { printf '127.0.0.1\n'; }
  _emit_upsmon_conf
)

protection_claim=$(rule_text UPSProtectionDegraded)
if [ -z "$protection_claim" ]; then
  printf 'harness error: UPSProtectionDegraded annotation was not found\n' >&2
  exit 1
fi

if printf '%s\n' "$generated_upsmon" | grep -q '^MONITOR ups@127\.0\.0\.1:3493 ' \
  && printf '%s\n' "$generated_upsmon" | grep -q '^NOTIFYFLAG OVER ' \
  && ! printf '%s\n' "$generated_upsmon" | grep -q '^OVERDURATION\([[:space:]]\|$\)' \
  && printf '%s\n' "$protection_claim" | grep -Fq 'OVERDURATION is configured' \
  && printf '%s\n' "$protection_claim" | grep -Fq 'generated upsmon.conf does not set it.'; then
  ok 'UPSProtectionDegraded publishes the generated upsmon.conf OVERDURATION absence'
else
  no 'UPSProtectionDegraded OVERDURATION contract' \
    'the generated config or the scoped annotation no longer carries the published absence'
fi

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

compose_restart=$(awk '$1 == "restart:" { print $2; exit }' "$REPO_ROOT/compose.yaml")
if [ -z "$compose_restart" ]; then
  printf 'harness error: compose.yaml has no restart policy\n' >&2
  exit 1
fi

readme_restart=$(awk '
  /^## Quick start$/ { quick_start = 1; next }
  quick_start && /^```yaml$/ { yaml = 1; next }
  yaml && /^```$/ { exit }
  yaml && $1 == "restart:" { print $2; exit }
' "$REPO_ROOT/README.md")
if [ -z "$readme_restart" ]; then
  printf 'harness error: README Quick start has no restart policy\n' >&2
  exit 1
fi

forced=$(rule_text UPSForcedShutdown)
failed=$(rule_text UPSPowerOffFailed)
if [ -z "$forced" ] || [ -z "$failed" ]; then
  printf 'harness error: forced-shutdown alert annotations were not found\n' >&2
  exit 1
fi

if [ "$compose_restart" = unless-stopped ] \
  && [ "$readme_restart" = "$compose_restart" ] \
  && printf '%s\n' "$forced" | grep -Fq "restart: $compose_restart" \
  && printf '%s\n' "$forced" | grep -Fq 'once per container life' \
  && printf '%s\n' "$failed" | grep -Fq 'restart policy re-enters monitoring' \
  && printf '%s\n' "$failed" | grep -Fq 'once per container life'; then
  ok 'compose, README, UPSForcedShutdown and UPSPowerOffFailed share the repeating restart contract'
else
  no 'forced-shutdown restart contract' \
    "compose=$compose_restart README=$readme_restart; an annotation no longer publishes the per-container-life consequence"
fi

report
