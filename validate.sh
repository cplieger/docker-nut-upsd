#!/bin/sh
# validate.sh — validation functions and table-driven dispatch for NUT env vars.
# Sourced by entrypoint.sh; not executed directly.

# Largest value safely representable in shell integer arithmetic and test(1)
# comparisons (18 nines fits a signed 64-bit long). validate_numeric bounds
# every numeric env var to 18 normalized digits, and run_validations bounds
# the one multiplied pair so its product stays under this ceiling.
readonly SHELL_SAFE_INTEGER_MAX=999999999999999999

# ---------------------------------------------------------------------------
# Validation functions
# ---------------------------------------------------------------------------

# log_value: sanitize a rejected raw value before interpolating it into a
# logfmt value="..." field — strip double quotes/backslashes and flatten
# everything outside printable ASCII to spaces so a malformed value cannot
# also corrupt or split the error line that reports it. The octal RANGE
# \040-\176 is deliberate: BusyBox tr treats a complemented character CLASS
# (tr -c '[:print:]') as a literal set, mangling every value — do not
# "simplify" this back to a class. LC_ALL=C pins the byte semantics.
log_value() {
  printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' '
}

validate_no_newlines() {
  # Control characters (CR, LF, tab, ...) inject or alter NUT config
  # directives. Trailing-newline tolerance is owned by
  # canonicalize_validated_values, which the entrypoint runs BEFORE
  # validation — so a trailing LF that reaches this check un-stripped is
  # rejected fail-closed rather than silently tolerated.
  case "$2" in
    *[[:cntrl:]]*)
      printf 'level=error msg="env var contains control characters" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_numeric() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'level=error msg="env var must be a non-negative integer" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
  # Reject normalized values too long to compare as shell integers: beyond
  # LONG_MAX, BusyBox test(1) errors with status 2 — which an enclosing `if`
  # swallows, so the range validators below would silently accept the value
  # and unbounded numbers would reach lifecycle.sh arithmetic.
  _numeric=$(strip_leading_zeros "$2")
  if [ "${#_numeric}" -gt "${#SHELL_SAFE_INTEGER_MAX}" ]; then
    printf 'level=error msg="env var numeric value too large" var=%s length=%d\n' "$1" "${#_numeric}" >&2
    return 1
  fi
}

validate_positive() {
  validate_numeric "$1" "$2" || return 1
  _numeric=$(strip_leading_zeros "$2")
  if [ "$_numeric" -lt 1 ]; then
    printf 'level=error msg="env var must be a positive integer (>= 1)" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_port() {
  validate_numeric "$1" "$2" || return 1
  _numeric=$(strip_leading_zeros "$2")
  if [ "$_numeric" -lt 1 ] || [ "$_numeric" -gt 65535 ]; then
    printf 'level=error msg="env var must be 1-65535" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_percent() {
  validate_numeric "$1" "$2" || return 1
  _numeric=$(strip_leading_zeros "$2")
  if [ "$_numeric" -gt 100 ]; then
    printf 'level=error msg="env var must be 0-100" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_no_brackets() {
  case "$2" in
    *"["* | *"]"*)
      printf 'level=error msg="env var contains bracket characters" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_no_quotes() {
  case "$2" in
    *'"'*)
      printf 'level=error msg="env var contains double-quote" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_no_backslash() {
  case "$2" in
    *\\*)
      printf 'level=error msg="env var contains backslash" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_identifier() {
  case "$2" in
    '' | *[!a-zA-Z0-9_-]*)
      printf 'level=error msg="env var is not a valid identifier" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
  # Position rule: reject a leading dash for every identifier this check
  # covers (UPS_NAME, UPS_DRIVER, API_USER). CLI consumers pass UPS_NAME as
  # the FIRST getopt-parsed argument (the HEALTHCHECK's `upsc $UPS_NAME@...`,
  # the watchdog's comms probe, `upsdrvctl stop $UPS_NAME`), so a dash-leading
  # name parses as options and fails every one of them while boot succeeds.
  # UPS_DRIVER and API_USER have no getopt-positional exposure (API_USER is
  # written as an unquoted [$API_USER] section header and a quoted MONITOR
  # credential), but a leading dash is not a meaningful identifier for either,
  # so the shared check stays uniform.
  case "$2" in
    -*)
      printf 'level=error msg="env var must not start with a dash" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
}

# Normalize a validated numeric so arithmetic expansion treats it as base-10.
# $(( )) reads a leading zero as octal: 08/09 error out (and under set -e kill the
# comms-watchdog subshell, silently disabling USB recovery); 012 would mean 10.
strip_leading_zeros() {
  _n="$1"
  while [ "${#_n}" -gt 1 ] && [ "${_n#0}" != "$_n" ]; do
    _n="${_n#0}"
  done
  printf '%s' "$_n"
}

# normalize_bool NAME VALUE -> prints 'true'/'false'; returns 1 (with an error log)
# on an unrecognized spelling so a misconfigured safety toggle fails loud.
normalize_bool() {
  _nb=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$_nb" in
    true | 1 | yes | on) printf 'true' ;;
    false | 0 | no | off) printf 'false' ;;
    *)
      printf 'level=error msg="env var must be a boolean (true/false/1/0/yes/no/on/off)" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Driver transport classification
# ---------------------------------------------------------------------------

# driver_transport: classify UPS_DRIVER for validation and device-access
# scoping. Prints one of:
#   usb   — libusb drivers that always talk through /dev/bus/usb
#   net   — network drivers whose port is a host[:port] endpoint (no local device)
#   other — serial or dual-mode drivers; the UPS_PORT shape decides what device
#           access is needed (see usb_bus_required)
driver_transport() {
  case "${UPS_DRIVER:-}" in
    snmp-ups)
      printf 'net'
      ;;
    usbhid-ups | blazer_usb | tripplite_usb | bcmxcp_usb | richcomm_usb | riello_usb | nutdrv_atcl_usb)
      printf 'usb'
      ;;
    *)
      printf 'other'
      ;;
  esac
}

# usb_bus_required: return 0 when this configuration needs /dev/bus/usb (the
# live bus bind + cgroup rule from the README). True for the USB driver
# family, and for dual-mode drivers when UPS_PORT requests USB auto-detection
# or names a node under the USB bus. Network drivers and serial /dev/tty*
# nodes run without the bus, so the entrypoint and watchdog skip the bus
# existence check and nut-group setup for them.
usb_bus_required() {
  case "$(driver_transport)" in
    usb) return 0 ;;
    net) return 1 ;;
  esac
  if [ "${UPS_PORT:-auto}" = "auto" ]; then
    return 0
  fi
  case "${UPS_PORT:-}" in
    /dev/bus/usb/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Table-driven validation dispatch
# ---------------------------------------------------------------------------

# Each line: VAR_NAME:check1,check2,...
# Supported checks: newlines, quotes, backslash, brackets, identifier, numeric, positive, port, percent
VALIDATION_TABLE='
UPS_NAME:newlines,quotes,brackets,identifier
UPS_DESC:newlines,quotes,backslash
UPS_DRIVER:newlines,identifier
UPS_PORT:newlines,backslash
API_USER:newlines,identifier
API_PASSWORD:newlines,quotes,backslash
API_ADDRESS:newlines,quotes,backslash,brackets
API_PORT:newlines,port
API_TLS:newlines
ADMIN_PASSWORD:newlines,quotes,backslash
SHUTDOWN_ON_BATTERY_CRITICAL:newlines
DBUS_PROBE_INTERVAL:numeric
POLLFREQ:numeric
POLLFREQALERT:numeric
DEADTIME:numeric
FINALDELAY:numeric
HOSTSYNC:numeric
NOCOMMWARNTIME:numeric
RBWARNTIME:numeric
COMMS_WATCHDOG:newlines
COMMS_CHECK_INTERVAL:numeric
COMMS_RECOVERY_TIMEOUT:positive
COMMS_FAST_RETRIES:positive
COMMS_BACKOFF_FACTOR:positive
'

# Optional vars: only validated when non-empty.
VALIDATION_TABLE_OPTIONAL='
LOWBATT_PERCENT:newlines,percent
LOWBATT_RUNTIME:newlines,numeric
CRITBATT_PERCENT:newlines,percent
CRITBATT_RUNTIME:newlines,numeric
'

# Dispatch a single check for a variable.
_dispatch_check() {
  _var="$1"
  _val="$2"
  _check="$3"
  case "$_check" in
    newlines) validate_no_newlines "$_var" "$_val" ;;
    quotes) validate_no_quotes "$_var" "$_val" ;;
    backslash) validate_no_backslash "$_var" "$_val" ;;
    brackets) validate_no_brackets "$_var" "$_val" ;;
    identifier) validate_identifier "$_var" "$_val" ;;
    numeric) validate_numeric "$_var" "$_val" ;;
    positive) validate_positive "$_var" "$_val" ;;
    port) validate_port "$_var" "$_val" ;;
    percent) validate_percent "$_var" "$_val" ;;
    *)
      printf 'level=error msg="unknown validation check" check=%s var=%s\n' "$_check" "$_var" >&2
      return 1
      ;;
  esac
}

# Resolve a variable name to its value without eval.
_resolve_var() {
  case "$1" in
    UPS_NAME) printf '%s' "${UPS_NAME:-}" ;;
    UPS_DESC) printf '%s' "${UPS_DESC:-}" ;;
    UPS_DRIVER) printf '%s' "${UPS_DRIVER:-}" ;;
    UPS_PORT) printf '%s' "${UPS_PORT:-}" ;;
    API_USER) printf '%s' "${API_USER:-}" ;;
    API_PASSWORD) printf '%s' "${API_PASSWORD:-}" ;;
    API_ADDRESS) printf '%s' "${API_ADDRESS:-}" ;;
    API_PORT) printf '%s' "${API_PORT:-}" ;;
    API_TLS) printf '%s' "${API_TLS:-}" ;;
    ADMIN_PASSWORD) printf '%s' "${ADMIN_PASSWORD:-}" ;;
    SHUTDOWN_ON_BATTERY_CRITICAL) printf '%s' "${SHUTDOWN_ON_BATTERY_CRITICAL:-}" ;;
    DBUS_PROBE_INTERVAL) printf '%s' "${DBUS_PROBE_INTERVAL:-}" ;;
    POLLFREQ) printf '%s' "${POLLFREQ:-}" ;;
    POLLFREQALERT) printf '%s' "${POLLFREQALERT:-}" ;;
    DEADTIME) printf '%s' "${DEADTIME:-}" ;;
    FINALDELAY) printf '%s' "${FINALDELAY:-}" ;;
    HOSTSYNC) printf '%s' "${HOSTSYNC:-}" ;;
    NOCOMMWARNTIME) printf '%s' "${NOCOMMWARNTIME:-}" ;;
    RBWARNTIME) printf '%s' "${RBWARNTIME:-}" ;;
    COMMS_WATCHDOG) printf '%s' "${COMMS_WATCHDOG:-}" ;;
    COMMS_CHECK_INTERVAL) printf '%s' "${COMMS_CHECK_INTERVAL:-}" ;;
    COMMS_RECOVERY_TIMEOUT) printf '%s' "${COMMS_RECOVERY_TIMEOUT:-}" ;;
    COMMS_FAST_RETRIES) printf '%s' "${COMMS_FAST_RETRIES:-}" ;;
    COMMS_BACKOFF_FACTOR) printf '%s' "${COMMS_BACKOFF_FACTOR:-}" ;;
    LOWBATT_PERCENT) printf '%s' "${LOWBATT_PERCENT:-}" ;;
    LOWBATT_RUNTIME) printf '%s' "${LOWBATT_RUNTIME:-}" ;;
    CRITBATT_PERCENT) printf '%s' "${CRITBATT_PERCENT:-}" ;;
    CRITBATT_RUNTIME) printf '%s' "${CRITBATT_RUNTIME:-}" ;;
    *)
      printf 'level=error msg="unknown variable in validation table" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

# Run all checks from a table against the current environment.
_run_table() {
  _table="$1"
  _optional="$2"
  printf '%s\n' "$_table" | while IFS= read -r _line; do
    # Skip blank lines
    case "$_line" in
      '' | ' '*) continue ;;
    esac
    _var="${_line%%:*}"
    _checks="${_line#*:}"
    _value=$(_resolve_var "$_var") || exit 1
    # For optional vars, skip if empty.
    if [ "$_optional" = "1" ] && [ -z "$_value" ]; then
      continue
    fi
    # Split checks on comma and dispatch each.
    _saved_ifs="$IFS"
    IFS=','
    # shellcheck disable=SC2086
    set -- $_checks
    IFS="$_saved_ifs"
    for _chk; do
      _dispatch_check "$_var" "$_value" "$_chk" || exit 1
    done
  done || exit 1
}

# canonicalize_validated_values: strip trailing newline bytes (env-file
# artifacts) from every env var the validation tables cover, by assigning each
# through $() (which strips trailing LFs). MUST run BEFORE run_validations and
# before any raw-value interpretation: the table resolver's own $() already
# strips trailing LFs, so validation would otherwise pass a value whose raw
# form still carries the LF — breaking mid-line config writes (upsmon.conf's
# MONITOR host:$API_PORT) and raw-value cross-field checks (driver_transport
# matches ${UPS_DRIVER} literally, so "snmp-ups<LF>" would classify as
# "other" and dodge the network-transport UPS_PORT restrictions). Covers every
# _resolve_var entry so the validated, classified, and written bytes are
# identical. A no-op for every value with no trailing LF.
canonicalize_validated_values() {
  UPS_NAME=$(printf '%s' "${UPS_NAME:-}")
  UPS_DESC=$(printf '%s' "${UPS_DESC:-}")
  UPS_DRIVER=$(printf '%s' "${UPS_DRIVER:-}")
  UPS_PORT=$(printf '%s' "${UPS_PORT:-}")
  API_USER=$(printf '%s' "${API_USER:-}")
  API_PASSWORD=$(printf '%s' "${API_PASSWORD:-}")
  API_ADDRESS=$(printf '%s' "${API_ADDRESS:-}")
  API_PORT=$(printf '%s' "${API_PORT:-}")
  API_TLS=$(printf '%s' "${API_TLS:-}")
  ADMIN_PASSWORD=$(printf '%s' "${ADMIN_PASSWORD:-}")
  SHUTDOWN_ON_BATTERY_CRITICAL=$(printf '%s' "${SHUTDOWN_ON_BATTERY_CRITICAL:-}")
  DBUS_PROBE_INTERVAL=$(printf '%s' "${DBUS_PROBE_INTERVAL:-}")
  POLLFREQ=$(printf '%s' "${POLLFREQ:-}")
  POLLFREQALERT=$(printf '%s' "${POLLFREQALERT:-}")
  DEADTIME=$(printf '%s' "${DEADTIME:-}")
  FINALDELAY=$(printf '%s' "${FINALDELAY:-}")
  HOSTSYNC=$(printf '%s' "${HOSTSYNC:-}")
  NOCOMMWARNTIME=$(printf '%s' "${NOCOMMWARNTIME:-}")
  RBWARNTIME=$(printf '%s' "${RBWARNTIME:-}")
  COMMS_WATCHDOG=$(printf '%s' "${COMMS_WATCHDOG:-}")
  COMMS_CHECK_INTERVAL=$(printf '%s' "${COMMS_CHECK_INTERVAL:-}")
  COMMS_RECOVERY_TIMEOUT=$(printf '%s' "${COMMS_RECOVERY_TIMEOUT:-}")
  COMMS_FAST_RETRIES=$(printf '%s' "${COMMS_FAST_RETRIES:-}")
  COMMS_BACKOFF_FACTOR=$(printf '%s' "${COMMS_BACKOFF_FACTOR:-}")
  LOWBATT_PERCENT=$(printf '%s' "${LOWBATT_PERCENT:-}")
  LOWBATT_RUNTIME=$(printf '%s' "${LOWBATT_RUNTIME:-}")
  CRITBATT_PERCENT=$(printf '%s' "${CRITBATT_PERCENT:-}")
  CRITBATT_RUNTIME=$(printf '%s' "${CRITBATT_RUNTIME:-}")
}

run_validations() {
  _run_table "$VALIDATION_TABLE" 0
  _run_table "$VALIDATION_TABLE_OPTIONAL" 1

  # COMMS_RECOVERY_TIMEOUT and COMMS_BACKOFF_FACTOR are the one validated pair
  # that gets MULTIPLIED in shell arithmetic (lifecycle.sh's stage-2 backoff
  # threshold). Each is individually bounded to 18 digits by validate_numeric,
  # but their product can still overflow $(( )); bound the pair so the product
  # stays representable. Both are validated `positive` above, so _backoff >= 1
  # and the division is safe.
  _recovery=$(strip_leading_zeros "$COMMS_RECOVERY_TIMEOUT")
  _backoff=$(strip_leading_zeros "$COMMS_BACKOFF_FACTOR")
  if [ "$_recovery" -gt $((SHELL_SAFE_INTEGER_MAX / _backoff)) ]; then
    printf 'level=error msg="watchdog recovery interval product is too large" recovery_timeout=%s backoff_factor=%s\n' "$_recovery" "$_backoff" >&2
    exit 1
  fi

  # UPS_PORT shape depends on the driver's transport (see driver_transport):
  #   usb   — "auto" (USB auto-detection) or an explicit /dev/* node
  #   net   — a host or host:port endpoint; "auto" and /dev/* are USB/serial
  #           conventions that snmp-ups cannot use
  #   other — "auto", /dev/* (serial), or a network endpoint; the driver decides
  # The unquoted-write guards below apply to every shape.
  case "$(driver_transport)" in
    usb)
      case "$UPS_PORT" in
        auto | /dev/*) : ;;
        *)
          printf 'level=error msg="UPS_PORT must be auto or /dev/* for a USB driver" driver=%s value="%s"\n' "$UPS_DRIVER" "$(log_value "$UPS_PORT")" >&2
          exit 1
          ;;
      esac
      ;;
    net)
      case "$UPS_PORT" in
        auto | /dev/*)
          printf 'level=error msg="UPS_PORT must be a host or host:port endpoint for a network driver" driver=%s value="%s"\n' "$UPS_DRIVER" "$(log_value "$UPS_PORT")" >&2
          exit 1
          ;;
      esac
      ;;
  esac

  # UPS_PORT is written UNQUOTED into ups.conf (`port = $UPS_PORT`); a space would
  # split it into extra tokens and a double-quote would open a quoted context.
  # The `/dev/*` glob above matches whitespace/quotes, so guard them explicitly.
  case "$UPS_PORT" in
    *[[:space:]]* | *'"'*)
      printf 'level=error msg="UPS_PORT must not contain whitespace or quotes" value="%s"\n' "$(log_value "$UPS_PORT")" >&2
      exit 1
      ;;
  esac

  # Reject whitespace in UPS_NAME — NUT doesn't support it and the healthcheck's
  # `upsc $UPS_NAME@127.0.0.1` would word-split.
  case "$UPS_NAME" in
    *[[:space:]]*)
      printf 'level=error msg="UPS_NAME must not contain whitespace"\n' >&2
      exit 1
      ;;
  esac

  # Reject whitespace in API_ADDRESS — it is written unquoted into upsd.conf's
  # LISTEN directive, so a space would split it into extra tokens.
  case "$API_ADDRESS" in
    *[[:space:]]*)
      printf 'level=error msg="API_ADDRESS must not contain whitespace"\n' >&2
      exit 1
      ;;
  esac

  # API_USER must not shadow a reserved generated account: upsd.users defines
  # a hardcoded [admin] (the FSD/set-capable account) and — when both
  # upsd.users and upsmon.conf are generated — the reserved internal monitor
  # account [local_upsmon] (the bundled upsmon's `upsmon primary` credential;
  # see generate-config.sh). A second section generated from API_USER with
  # either name would merge into the reserved stanza and clobber its
  # credential with API_PASSWORD, exposing that account's authority under the
  # weaker network-facing password.
  if [ "$API_USER" = "admin" ]; then
    printf 'level=error msg="API_USER must not be admin (reserved for the internal NUT admin user)"\n' >&2
    exit 1
  fi
  if [ "$API_USER" = "local_upsmon" ]; then
    printf 'level=error msg="API_USER must not be local_upsmon (reserved for the internal upsmon monitor account)"\n' >&2
    exit 1
  fi
}
