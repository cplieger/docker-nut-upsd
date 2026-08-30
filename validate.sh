#!/bin/sh
# validate.sh — validation functions and table-driven dispatch for NUT env vars.
# Sourced by entrypoint.sh; not executed directly.

# Digit-count ceiling for every numeric env var: the largest all-nines value
# inside a signed 64-bit long, so any value validate_numeric accepts (<= 18
# digits) still compares safely in $(( )) and test(1). run_validations bounds
# the one multiplied pair so its product stays under it too.
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
# "simplify" this back to a class. LC_ALL=C pins the byte semantics. The 512-byte
# cap is the same bound the entrypoint puts on captured output: a rejected value
# is operator-supplied and unbounded, and this runs on a boot path that restarts.
log_value() {
  _lv=$(printf '%s' "$1" | tr -d '\\"' | LC_ALL=C tr -c '\040-\176' ' ' | cut -c 1-513)
  if [ "${#_lv}" -le 512 ]; then
    printf '%s' "$_lv"
  else
    printf '%.509s...' "$_lv"
  fi
}

validate_no_control_chars() {
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
  # Reject digit strings too long to compare as shell integers, BEFORE
  # normalizing: beyond LONG_MAX, BusyBox test(1) errors with status 2 — which
  # an enclosing `if` swallows, so the range validators below would silently
  # accept the value and unbounded numbers would reach lifecycle.sh arithmetic.
  # Bounding the RAW value also bounds strip_leading_zeros, whose
  # one-byte-at-a-time loop is quadratic in the leading-zero run under BusyBox
  # ash (measured: 54.7s at 40000 zeros, and the value was ACCEPTED).
  if [ "${#2}" -gt "${#SHELL_SAFE_INTEGER_MAX}" ]; then
    printf 'level=error msg="env var numeric value has too many digits" var=%s length=%d\n' "$1" "${#2}" >&2
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

validate_no_hash() {
  # NUT's parseconf hard-errors on an unescaped `#` inside a double-quoted
  # value and treats it as a comment introducer outside quotes; either way the
  # consumer drops the config line and carries on, so an ordinary value yields
  # an account that cannot authenticate or a LISTEN line on a different port.
  # Escaping `\#` at the write sites is possible but the backslash refusal
  # above closes that route, so refusal at this boundary is the whole remedy.
  case "$2" in
    *'#'*)
      printf 'level=error msg="env var contains hash character" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

validate_no_whitespace() {
  # Whitespace splits a value written UNQUOTED into a config file into extra
  # directive tokens, and an extra getopt argument for the CLI consumers that
  # take UPS_NAME positionally.
  case "$2" in
    *[[:space:]]*)
      printf 'level=error msg="env var contains whitespace" var=%s value="%s"\n' "$1" "$(log_value "$2")" >&2
      return 1
      ;;
  esac
}

validate_nut_word() {
  # NUT parseconf silently ALTERS a value it will not preserve, and this app's
  # env-var-to-config mapping is the only place that can name the variable:
  # common/parseconf.c addchar() discards every byte outside 0x20-0x7E
  # (CVE-2012-2944) and stops appending at PCONF_DEFAULT_WORDLEN_LIMIT (512).
  # For a credential the result is an account whose stored password is not the
  # one that was set.
  case "$2" in
    *[!' '-'~']*)
      printf 'level=error msg="env var contains a byte NUT will not preserve (ASCII 0x20-0x7E only)" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
  if [ "${#2}" -gt 512 ]; then
    printf 'level=error msg="env var is longer than NUT 512-byte word limit" var=%s length=%d\n' "$1" "${#2}" >&2
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

# usb_bus_required: return 0 when this configuration needs /dev/bus/usb
# (the live bus bind + cgroup rule from the README). Always for the usb
# driver family, never for net, and for `other` when UPS_PORT is `auto`
# or a /dev/bus/usb node -- `other` mixes serial-only and dual-mode
# drivers with no way to tell them apart by name, so `auto` counts as
# USB auto-detection for all of them.
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
# Supported checks: control, quotes, backslash, hash, nospace, nut_word, brackets, identifier, numeric, positive, port, percent
# A row DECLARES every injection hazard the value's write form has
# (CONTRIBUTING.md "Adding or validating an environment variable"), then its
# domain check. A declared hazard stays even where the domain check already
# subsumes it: the table is what the write-form rules are audited against, and
# the hazard check reports the invisible-byte case precisely ("contains control
# characters", not "must be a non-negative integer").
VALIDATION_TABLE='
UPS_NAME:control,quotes,brackets,identifier
UPS_DESC:control,quotes,backslash,hash
UPS_DRIVER:control,identifier
UPS_PORT:control,quotes,backslash,hash,nospace
API_USER:control,quotes,brackets,identifier
API_PASSWORD:control,quotes,backslash,hash,nut_word
API_ADDRESS:control,quotes,backslash,brackets,hash,nospace
API_PORT:control,port
API_TLS:control
ADMIN_PASSWORD:control,quotes,backslash,hash,nut_word
SHUTDOWN_ON_BATTERY_CRITICAL:control
DBUS_PROBE_INTERVAL:control,numeric
POLLFREQ:control,positive
POLLFREQALERT:control,positive
DEADTIME:control,positive
FINALDELAY:control,numeric
HOSTSYNC:control,numeric
NOCOMMWARNTIME:control,numeric
RBWARNTIME:control,numeric
COMMS_WATCHDOG:control
COMMS_CHECK_INTERVAL:control,numeric
COMMS_RECOVERY_TIMEOUT:control,positive
COMMS_FAST_RETRIES:control,positive
COMMS_BACKOFF_FACTOR:control,positive
'

# Optional vars: only validated when non-empty.
VALIDATION_TABLE_OPTIONAL='
LOWBATT_PERCENT:control,percent
LOWBATT_RUNTIME:control,numeric
'

# Dispatch a single check for a variable.
_dispatch_check() {
  _var="$1"
  _val="$2"
  _check="$3"
  case "$_check" in
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
      printf 'level=error msg="unknown validation check" check=%s var=%s\n' "$_check" "$_var" >&2
      return 1
      ;;
  esac
}

# Resolve a variable name into _value without eval.
_resolve_var() {
  case "$1" in
    UPS_NAME) _value="${UPS_NAME:-}" ;;
    UPS_DESC) _value="${UPS_DESC:-}" ;;
    UPS_DRIVER) _value="${UPS_DRIVER:-}" ;;
    UPS_PORT) _value="${UPS_PORT:-}" ;;
    API_USER) _value="${API_USER:-}" ;;
    API_PASSWORD) _value="${API_PASSWORD:-}" ;;
    API_ADDRESS) _value="${API_ADDRESS:-}" ;;
    API_PORT) _value="${API_PORT:-}" ;;
    API_TLS) _value="${API_TLS:-}" ;;
    ADMIN_PASSWORD) _value="${ADMIN_PASSWORD:-}" ;;
    SHUTDOWN_ON_BATTERY_CRITICAL) _value="${SHUTDOWN_ON_BATTERY_CRITICAL:-}" ;;
    DBUS_PROBE_INTERVAL) _value="${DBUS_PROBE_INTERVAL:-}" ;;
    POLLFREQ) _value="${POLLFREQ:-}" ;;
    POLLFREQALERT) _value="${POLLFREQALERT:-}" ;;
    DEADTIME) _value="${DEADTIME:-}" ;;
    FINALDELAY) _value="${FINALDELAY:-}" ;;
    HOSTSYNC) _value="${HOSTSYNC:-}" ;;
    NOCOMMWARNTIME) _value="${NOCOMMWARNTIME:-}" ;;
    RBWARNTIME) _value="${RBWARNTIME:-}" ;;
    COMMS_WATCHDOG) _value="${COMMS_WATCHDOG:-}" ;;
    COMMS_CHECK_INTERVAL) _value="${COMMS_CHECK_INTERVAL:-}" ;;
    COMMS_RECOVERY_TIMEOUT) _value="${COMMS_RECOVERY_TIMEOUT:-}" ;;
    COMMS_FAST_RETRIES) _value="${COMMS_FAST_RETRIES:-}" ;;
    COMMS_BACKOFF_FACTOR) _value="${COMMS_BACKOFF_FACTOR:-}" ;;
    LOWBATT_PERCENT) _value="${LOWBATT_PERCENT:-}" ;;
    LOWBATT_RUNTIME) _value="${LOWBATT_RUNTIME:-}" ;;
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
    # Skip the empty first/last lines of the table literal. Deliberately ONLY
    # the empty string: an accidentally indented row must fail loudly through
    # _resolve_var's unknown-variable error (fail-closed), never be skipped
    # silently (fail-open) -- this loop dispatches the security validations.
    case "$_line" in
      '') continue ;;
    esac
    _var="${_line%%:*}"
    _checks="${_line#*:}"
    # A row with an empty check list -- "VAR:" -- is the one malformed shape that
    # dispatches nothing: `set -- $_checks` yields no positional parameters and
    # the loop below runs no iterations, so the variable would go unvalidated with
    # nothing logged. Every other malformed shape already fails closed.
    if [ -z "$_checks" ]; then
      printf 'level=error msg="validation table row declares no checks" var=%s\n' "$_var" >&2
      exit 1
    fi
    _resolve_var "$_var" || exit 1
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
# artifacts) from every value whose PRESENTATION may safely change, by
# assigning it through $(). MUST run BEFORE run_validations and before any
# raw-value interpretation, so the validated, classified and written bytes are
# identical: a surviving LF breaks mid-line config writes (upsmon.conf's
# MONITOR host:$API_PORT) and raw-value cross-field checks (driver_transport
# matches ${UPS_DRIVER} literally, so "snmp-ups<LF>" classifies as "other" and
# dodges the network-transport UPS_PORT restrictions). It is also why
# _resolve_var assigns rather than prints: a $() there would strip the LF for
# the checks only. A no-op for every value with no trailing LF.
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
  # remote client reproduces them byte for byte, so a trailing LF is
  # refused by the `control` check rather than silently stripped
  # (env-validation.md, the no-repair rule).
  API_PASSWORD="${API_PASSWORD:-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
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

  # DEADTIME below the larger poll interval arms an irreversible host poweroff:
  # upsmon promotes an on-battery UPS to OB+LB as soon as one poll is late
  # (clients/upsmon.c:1712), and with SHUTDOWN_ON_BATTERY_CRITICAL=true that
  # state powers the host off during a mains blip — while this image's own comms
  # watchdog makes a late poll ordinary. Upstream only ADVISES a multiple of the
  # poll intervals; this app refuses anything below the larger of them. Both are
  # validated `positive` above, so the floor is >= 1.
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
  # driver_transport): "auto"/`/dev/*` for usb and serial, a host or
  # host:port endpoint for net. These arms REFUSE the spelling each
  # transport cannot use -- they do not establish the endpoint or
  # device-node form, which the driver reports for itself. UPS_PORT's
  # table row has already applied the unquoted-write guards.
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
