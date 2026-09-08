#!/bin/sh
# validate.sh — validation functions for NUT env vars.
# Sourced by entrypoint.sh; not executed directly.

# log_value: sanitize a rejected raw value before interpolating it into a
# logfmt value="..." field — strip double quotes/backslashes and flatten
# everything outside printable ASCII to spaces so a malformed value cannot
# also corrupt or split the error line that reports it. The octal RANGE
# \040-\176 is deliberate: BusyBox tr treats a complemented character CLASS
# (tr -c '[:print:]') as a literal set, mangling every value. LC_ALL=C pins
# the byte semantics. The marker reports whether the caller exceeded 512
# characters; cut only bounds the captured sanitized value.
log_value() {
  _lv=$(printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' ' | cut -c 1-512)
  if [ "${#1}" -le 512 ]; then
    printf '%s' "$_lv"
  else
    printf '%.509s...' "$_lv"
  fi
}

validate_no_control_chars() {
  # Trailing-newline tolerance is owned by canonicalize_validated_values,
  # which runs BEFORE validation — so a surviving LF is rejected fail-closed.
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
  # Reject digit strings too long to compare as shell integers, BEFORE
  # normalizing: beyond LONG_MAX, BusyBox test(1) errors with status 2, which
  # an enclosing `if` swallows, so the range validators below would silently
  # accept the value (18 digits is the largest all-nines value inside a signed
  # 64-bit long). Bounding the RAW value also bounds strip_leading_zeros,
  # whose one-byte-at-a-time loop is quadratic in the leading-zero run under
  # BusyBox ash (measured: 54.7s at 40000 zeros, and the value was accepted).
  if [ "${#2}" -gt 18 ]; then
    printf 'level=error msg="env var numeric value has too many digits" var=%s length=%d\n' "$1" "${#2}" >&2
    return 1
  fi

  # tier 2: one ceiling for every numeric row, set by the strictest
  # consumer. upsmon reads DEADTIME, HOSTSYNC, NOCOMMWARNTIME and
  # RBWARNTIME through a bare atoi(3) with no validity arm
  # (clients/upsmon.c:2428-2460), so above INT_MAX the stored value is not
  # the configured one and a negative deadtime makes
  # `(now - lastpoll) > deadtime` (:1712) true on every pass, powering the
  # host off when the opt-in is set. DBUS_PROBE_INTERVAL and the four
  # COMMS_* rows have no NUT consumer and share the ceiling anyway.
  if [ "$2" -gt 2147483647 ]; then
    printf 'level=error msg="env var must not exceed 2147483647" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_positive() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -lt 1 ]; then
    printf 'level=error msg="env var must be a positive integer (>= 1)" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_port() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
    printf 'level=error msg="env var must be 1-65535" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
    return 1
  fi
}

validate_percent() {
  validate_numeric "$1" "$2" || return 1
  if [ "$2" -gt 100 ]; then
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

validate_no_hash() {
  # NUT parseconf hard-errors on an unescaped `#` inside a quoted value,
  # then resumes at the byte after the error instead of the next line. The
  # remainder is re-parsed in the active section: `desc = "evil #pollonly = 1 x"`
  # injects `pollonly = 1` (tier 1 refusal).
  case "$2" in
    *'#'*)
      printf 'level=error msg="env var contains hash character" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_no_whitespace() {
  # Whitespace splits a value written UNQUOTED into a config file into extra
  # directive tokens.
  case "$2" in
    *[[:space:]]*)
      printf 'level=error msg="env var contains whitespace" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
}

# parseconf keeps bytes 0x20-0x7F; this app's control check refuses 0x7F,
# so this is the credential upsd actually stores.
nut_stored_word() {
  printf '%s' "$1" | LC_ALL=C tr -cd '\040-\176'
}

validate_nut_word() {
  # Whitespace is the exception to the shared filter: the bundled clients send
  # PASSWORD unquoted, so spaces split the message before upsd can filter it.
  # warn_weak_api_password reports that client-specific mismatch at startup.
  # Refuse only the degenerate empty stored word and the length no bundled
  # client can send.
  if [ -z "$(nut_stored_word "$2")" ]; then
    printf 'level=error msg="env var becomes an empty NUT word after parsing" var=%s\n' "$1" >&2
    return 1
  fi
  if [ "${#2}" -gt 501 ]; then
    printf 'level=error msg="env var is longer than the bundled NUT client password limit" var=%s length=%d limit=501\n' "$1" "${#2}" >&2
    return 1
  fi
}

validate_identifier() {
  case "$2" in
    '' | *[!a-zA-Z0-9_-]*)
      printf 'level=error msg="env var is not a valid identifier" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
  # Reject a leading dash for every identifier this check covers (UPS_NAME,
  # UPS_DRIVER, API_USER): CLI consumers pass UPS_NAME as the first
  # getopt-parsed argument (the HEALTHCHECK's `upsc $UPS_NAME@...`, the
  # watchdog's comms probe, `upsdrvctl stop $UPS_NAME`), so a dash-leading
  # name parses as options and fails every one of them while boot succeeds.
  case "$2" in
    -*)
      printf 'level=error msg="env var must not start with a dash" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac

  # parseconf caps words at 512 bytes and silently drops overflow, so 510
  # leaves room for both brackets in generated section headers.
  if [ "${#2}" -gt 510 ]; then
    printf 'level=error msg="env var is longer than the 510-byte NUT identifier limit" var=%s length=%d\n' "$1" "${#2}" >&2
    return 1
  fi
}

# Normalize a validated numeric so arithmetic expansion treats it as base-10.
# test(1) compares decimal, so only $(( )) consumers and values printed in
# canonical form need this call. A leading zero is octal in $(( )): 08/09
# error out, and 012 means 10.
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
# Both censuses are hand-copied from the pinned NUT tree's drivers/Makefile.am.
driver_transport() {
  case "${UPS_DRIVER:-}" in
    snmp-ups | apcupsd-ups)
      printf 'net'
      ;;
    usbhid-ups | blazer_usb | tripplite_usb | bcmxcp_usb | richcomm_usb | riello_usb | powervar_cx_usb | nutdrv_atcl_usb)
      printf 'usb'
      ;;
    *)
      printf 'other'
      ;;
  esac
}

# usb_bus_required: return 0 when this configuration needs /dev/bus/usb.
# Always for the usb driver family, never for net, and for `other` when
# UPS_PORT is `auto` or a /dev/bus/usb node — `other` mixes serial-only and
# dual-mode drivers with no way to tell them apart by name.
usb_bus_required() {
  case "$(driver_transport)" in
    usb) return 0 ;;
    net) return 1 ;;
  esac
  case "${UPS_PORT:-auto}" in
    auto | /dev/bus/usb/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Validation dispatch
# ---------------------------------------------------------------------------

# Each _check call names the variable, its value, and its checks.
# _dispatch_check owns the legal names; CONTRIBUTING.md "Adding or validating
# an environment variable" owns row composition.
# A hazard a domain check already refuses stays listed where the refusal must
# NAME the injection case: `control` everywhere, quotes/brackets on the two
# section-header rows.

# Dispatch a single check for a variable.
_dispatch_check() {
  _var="$1"
  _val="$2"
  _chk_name="$3"
  case "$_chk_name" in
    control) validate_no_control_chars "$_var" "$_val" ;;
    quotes) validate_no_quotes "$_var" "$_val" ;;
    backslash) validate_no_backslash "$_var" "$_val" ;;
    hash) validate_no_hash "$_var" "$_val" ;;
    nospace) validate_no_whitespace "$_var" "$_val" ;;
    nut_word) validate_nut_word "$_var" "$_val" ;;
    brackets) validate_no_brackets "$_var" "$_val" ;;
    identifier) validate_identifier "$_var" "$_val" ;;
    numeric) validate_numeric "$_var" "$_val" ;;
    positive) validate_positive "$_var" "$_val" ;;
    port) validate_port "$_var" "$_val" ;;
    percent) validate_percent "$_var" "$_val" ;;
    *)
      printf 'level=error msg="unknown validation check" check=%s var=%s\n' "$_chk_name" "$_var" >&2
      return 1
      ;;
  esac
}

_check() {
  _row_var="$1"
  _row_value="$2"
  shift 2
  for _row_check in "$@"; do
    _dispatch_check "$_row_var" "$_row_value" "$_row_check" || exit 1
  done
}

_check_optional() {
  [ -n "$2" ] || return 0
  _check "$@"
}

check_required_vars() {
  _check UPS_NAME "${UPS_NAME:-}" control quotes brackets identifier
  _check UPS_DESC "${UPS_DESC:-}" control quotes backslash hash
  _check UPS_DRIVER "${UPS_DRIVER:-}" control identifier
  _check UPS_PORT "${UPS_PORT:-}" control quotes backslash hash nospace
  _check API_USER "${API_USER:-}" control quotes brackets identifier
  _check API_PASSWORD "${API_PASSWORD:-}" control quotes backslash hash nut_word
  # API_ADDRESS's `brackets` is not that case: upsd_probe_host brackets a
  # colon-bearing host itself (lifecycle.sh), so `[::1]` would probe `[[::1]]`.
  _check API_ADDRESS "${API_ADDRESS:-}" control quotes backslash brackets hash nospace
  _check API_PORT "${API_PORT:-}" control port
  _check API_TLS "${API_TLS:-}" control
  _check_optional ADMIN_PASSWORD "${ADMIN_PASSWORD:-}" control quotes backslash hash nut_word
  _check SHUTDOWN_ON_BATTERY_CRITICAL "${SHUTDOWN_ON_BATTERY_CRITICAL:-}" control
  _check DBUS_PROBE_INTERVAL "${DBUS_PROBE_INTERVAL:-}" control numeric
  _check POLLFREQ "${POLLFREQ:-}" control positive
  _check POLLFREQALERT "${POLLFREQALERT:-}" control positive
  _check DEADTIME "${DEADTIME:-}" control positive
  _check FINALDELAY "${FINALDELAY:-}" control numeric
  _check HOSTSYNC "${HOSTSYNC:-}" control numeric
  _check NOCOMMWARNTIME "${NOCOMMWARNTIME:-}" control numeric
  _check RBWARNTIME "${RBWARNTIME:-}" control numeric
  _check COMMS_WATCHDOG "${COMMS_WATCHDOG:-}" control
  _check COMMS_CHECK_INTERVAL "${COMMS_CHECK_INTERVAL:-}" control numeric
  _check COMMS_RECOVERY_TIMEOUT "${COMMS_RECOVERY_TIMEOUT:-}" control positive
  _check COMMS_FAST_RETRIES "${COMMS_FAST_RETRIES:-}" control positive
  _check COMMS_BACKOFF_FACTOR "${COMMS_BACKOFF_FACTOR:-}" control positive
}

check_optional_vars() {
  _check_optional LOWBATT_PERCENT "${LOWBATT_PERCENT:-}" control percent
  _check_optional LOWBATT_RUNTIME "${LOWBATT_RUNTIME:-}" control numeric
}

# canonicalize_validated_values: strip trailing newline bytes (env-file
# artifacts) from every value whose PRESENTATION may safely change, by
# assigning it through $(). MUST run BEFORE run_validations: every row runs
# `control`, so an unstripped trailing LF ends the boot instead of being
# tolerated. Tolerance is a STRIP rather than a byte allowed through because
# a raw LF would break mid-line config writes (upsmon.conf's MONITOR
# host:$API_PORT) and cross-field checks (driver_transport matches
# ${UPS_DRIVER} literally). A no-op for every value with no trailing LF.
canonicalize_validated_values() {
  UPS_NAME=$(printf '%s' "${UPS_NAME:-}")
  UPS_DESC=$(printf '%s' "${UPS_DESC:-}")
  UPS_DRIVER=$(printf '%s' "${UPS_DRIVER:-}")
  UPS_PORT=$(printf '%s' "${UPS_PORT:-}")
  API_USER=$(printf '%s' "${API_USER:-}")
  API_ADDRESS=$(printf '%s' "${API_ADDRESS:-}")
  API_PORT=$(printf '%s' "${API_PORT:-}")
  API_TLS=$(printf '%s' "${API_TLS:-}")
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
  # API_PASSWORD/ADMIN_PASSWORD are enumerated but NOT canonicalized: a
  # remote client reproduces them byte for byte, so a trailing LF is refused
  # by the `control` check rather than silently stripped.
  API_PASSWORD="${API_PASSWORD:-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
}

run_validations() {
  check_required_vars
  check_optional_vars

  # DEADTIME below the larger poll interval arms an irreversible host poweroff:
  # upsmon promotes an on-battery UPS to OB+LB as soon as one poll is late
  # (clients/upsmon.c:1712), and with SHUTDOWN_ON_BATTERY_CRITICAL=true that
  # state powers the host off during a mains blip. Upstream only ADVISES a
  # multiple of the poll intervals; this app refuses it unconditionally, even where a
  # mounted upsmon.conf.user makes the value inert -- unmounting must not boot unchecked.
  _deadtime=$(strip_leading_zeros "$DEADTIME")
  _pollfreq=$(strip_leading_zeros "$POLLFREQ")
  _pollalert=$(strip_leading_zeros "$POLLFREQALERT")
  _pollmax="$_pollfreq"
  if [ "$_pollalert" -gt "$_pollmax" ]; then
    _pollmax="$_pollalert"
  fi
  if [ "$_deadtime" -lt "$_pollmax" ]; then
    printf 'level=error msg="DEADTIME must be at least the larger of POLLFREQ and POLLFREQALERT" deadtime=%s pollfreq=%s pollfreqalert=%s\n' "$_deadtime" "$_pollfreq" "$_pollalert" >&2
    exit 1
  fi

  # UPS_PORT's usable shape depends on the driver's transport (see
  # driver_transport). Only the net arm refuses a spelling: snmp-ups hands the
  # value to net-snmp as a peername, so `auto` or a device node there fails at
  # daemon start with no variable named. The usb family carries no arm on
  # purpose — every USB driver ignores the value and upstream warns about it
  # itself (warn_if_bad_usb_port_filename, drivers/usb-common.c), so refusing
  # here turned a working configuration into a boot refusal.
  case "$(driver_transport)" in
    net)
      case "$UPS_PORT" in
        auto | /dev/*)
          printf 'level=error msg="UPS_PORT must be a host or host:port endpoint for a network driver" driver=%s value="%s"\n' "$UPS_DRIVER" "$(log_value "$UPS_PORT")" >&2
          exit 1
          ;;
      esac
      ;;
  esac

  # API_USER must not shadow a reserved generated account: upsd.users defines
  # a hardcoded [admin] and — when both upsd.users and upsmon.conf are
  # generated — the reserved internal [local_upsmon] monitor account. upsd
  # keeps the FIRST stanza of a repeated name (server/user.c user_add), so
  # the API pair would authenticate no account while its `upsmon` line grants
  # that type to the stanza parsed before it.
  if [ "$API_USER" = "admin" ]; then
    printf 'level=error msg="API_USER must not be admin (reserved for the internal NUT admin user)"\n' >&2
    exit 1
  fi
  if [ "$API_USER" = "local_upsmon" ]; then
    printf 'level=error msg="API_USER must not be local_upsmon (reserved for the internal upsmon monitor account)"\n' >&2
    exit 1
  fi
}
