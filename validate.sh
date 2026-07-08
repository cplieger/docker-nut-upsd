#!/bin/sh
# validate.sh — validation functions and table-driven dispatch for NUT env vars.
# Sourced by entrypoint.sh; not executed directly.

# ---------------------------------------------------------------------------
# Validation functions
# ---------------------------------------------------------------------------
validate_no_newlines() {
  # Strip one trailing newline before scanning for control bytes: a single
  # trailing newline is harmless (env files and $() pipelines often
  # preserve one), but embedded control characters (CR, LF, tab, etc.)
  # remain rejected because they inject or alter NUT config directives.
  _val=$(
    printf '%s' "$2"
    printf x
  )
  _val=${_val%x}
  _val=${_val%"
"}
  case "$_val" in
    *[[:cntrl:]]*)
      printf 'level=error msg="env var contains control characters" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_numeric() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'level=error msg="env var must be a non-negative integer" var=%s value="%s"\n' "$1" "$2" >&2
      return 1
      ;;
  esac
}

validate_positive() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -lt 1 ]; then
    printf 'level=error msg="env var must be a positive integer (>= 1)" var=%s value="%s"\n' "$1" "$2" >&2
    return 1
  fi
}

validate_port() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
    printf 'level=error msg="env var must be 1-65535" var=%s value="%s"\n' "$1" "$2" >&2
    return 1
  fi
}

validate_percent() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -gt 100 ]; then
    printf 'level=error msg="env var must be 0-100" var=%s value="%s"\n' "$1" "$2" >&2
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
      printf 'level=error msg="env var is not a valid identifier" var=%s value="%s"\n' "$1" "$2" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Table-driven validation dispatch
# ---------------------------------------------------------------------------

# Each line: VAR_NAME:check1,check2,...
# Supported checks: newlines, quotes, brackets, identifier, numeric, positive, port, percent
VALIDATION_TABLE='
UPS_NAME:newlines,quotes,brackets,identifier
UPS_DESC:newlines,quotes,backslash
UPS_DRIVER:newlines,identifier
UPS_PORT:newlines
API_USER:newlines,quotes,brackets,backslash
API_PASSWORD:newlines,quotes,backslash
API_ADDRESS:newlines,quotes,backslash
API_PORT:newlines,numeric,port
ADMIN_PASSWORD:newlines,quotes,backslash
SHUTDOWN_ON_BATTERY_CRITICAL:newlines
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
LOWBATT_PERCENT:newlines,numeric,percent
LOWBATT_RUNTIME:newlines,numeric
CRITBATT_PERCENT:newlines,numeric,percent
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
    ADMIN_PASSWORD) printf '%s' "${ADMIN_PASSWORD:-}" ;;
    SHUTDOWN_ON_BATTERY_CRITICAL) printf '%s' "${SHUTDOWN_ON_BATTERY_CRITICAL:-}" ;;
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

run_validations() {
  _run_table "$VALIDATION_TABLE" 0
  _run_table "$VALIDATION_TABLE_OPTIONAL" 1

  # UPS_PORT must be "auto" or a /dev/* path (NUT's documented conventions).
  case "$UPS_PORT" in
    auto | /dev/*) : ;;
    *)
      printf 'level=error msg="UPS_PORT must be auto or /dev/*" value="%s"\n' "$UPS_PORT" >&2
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

  # API_USER must not be "admin": upsd.users already defines a hardcoded [admin]
  # user (granted set/fsd/instcmds=all). A second [admin] section generated from
  # API_USER=admin would merge into it and clobber the admin credential with
  # API_PASSWORD, exposing the FSD/set-capable account under the weaker password.
  if [ "$API_USER" = "admin" ]; then
    printf 'level=error msg="API_USER must not be admin (reserved for the internal NUT admin user)"\n' >&2
    exit 1
  fi
}
