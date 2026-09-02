#!/usr/bin/env bash
# The validation row dispatch: _check(), _check_optional(), and
# _dispatch_check().
#
# tests/smoke.sh drives every shipped row through check_required_vars and
# check_optional_vars. This file covers direct dispatch, optional empty-value
# handling, cross-field validation, inventory parity, and credential secrecy.
#
# _check exits on refusal (the entrypoint's fail-closed path), so every direct
# call that can fail runs in a subshell used as the condition.
#
# Lint directives for this whole file, each against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
#   SC2034 - the env vars assigned here are inputs to code extracted and
#     sourced at runtime, so shellcheck cannot see the reads.
#   SC1090/SC1091 - the sourced paths are produced by extraction, so there is
#     nothing on disk for shellcheck to follow at lint time.
# shellcheck disable=SC2015,SC2034,SC1090,SC1091
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins (the red-check):
#   ENTRYPOINT=/tmp/mut-validate.sh bash tests/shell/validation_dispatch_test.sh
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/validate.sh"

# The range ends at the following blank line, not at a repeat of the start
# pattern: sed does not re-test a regex end address on the start line, so with
# no second copy of the declaration the range would run to EOF and source the
# whole file, masking a missing dependency in the explicit load list below.
consts=$(extract_range '^readonly SHELL_SAFE_INTEGER_MAX=' '^$') || exit 1
. "$consts"
[ -n "${SHELL_SAFE_INTEGER_MAX:-}" ] && [ "$(grep -c . "$consts")" -eq 1 ] \
  || {
    printf 'harness error: the constant extraction captured %s non-blank lines, want exactly 1\n' \
      "$(grep -c . "$consts")" >&2
    exit 1
  }

# The dispatch layer plus every validator the rows below route to. Loaded, not
# stubbed: a dispatch test whose validators are fakes proves only that the fakes
# ran.
for fn in log_value strip_leading_zeros validate_no_control_chars validate_identifier \
  validate_no_hash validate_no_quotes validate_no_backslash validate_no_whitespace \
  validate_nut_word validate_no_brackets validate_numeric validate_positive validate_port \
  validate_percent _dispatch_check _check _check_optional check_required_vars \
  check_optional_vars driver_transport run_validations; do
  load_function "$fn"
done

ERR="$WORK/err.log"
UPS_NAME=ups
LOWBATT_PERCENT=""

# --- 1. an unknown CHECK name fails closed ---------------------------------------
#
# A typo'd check name must not mean "this variable is now unvalidated".
if (_dispatch_check UPS_NAME ups notacheck) 2>"$ERR"; then
  no 'unknown check refused' 'a misspelled check name was silently accepted'
else
  grep -q 'unknown validation check' "$ERR" \
    && ok 'a row naming an unknown check fails with the unknown-check error' \
    || no 'unknown check refused' "refused without the unknown-check line: $(head -c 200 "$ERR")"
fi

# --- 2. the control: a known check still dispatches ------------------------------
if (_dispatch_check UPS_NAME ups control) 2>"$ERR"; then
  ok 'a known check dispatches and passes a valid value'
else
  no 'known check dispatches' "rejected a valid value: $(head -c 200 "$ERR")"
fi

# NUT's atoi-consumed timing values accept INT_MAX and refuse INT_MAX+1.
if validate_numeric DEADTIME 2147483647 2>"$ERR"; then
  ok 'the largest value representable by the NUT C-int consumer is accepted'
else
  no 'NUT C-int upper boundary accepted' "INT_MAX was rejected: $(head -c 200 "$ERR")"
fi

: >"$ERR"
if validate_numeric DEADTIME 2147483648 2>"$ERR"; then
  no 'NUT C-int overflow refused' 'INT_MAX+1 was accepted'
elif grep -Fq 'msg="env var must not exceed 2147483647" var=DEADTIME value="2147483648"' "$ERR"; then
  ok 'the first value above the NUT C-int boundary is refused by the ceiling arm'
else
  no 'NUT C-int overflow refused' "wrong refusal: $(head -c 200 "$ERR")"
fi

# --- 9b. jointly disabled low-battery thresholds fail closed ---------------------
#
# Each row accepts zero because zero disables only that axis; the pair is
# unsafe together because ignorelb discards the UPS low-battery flag while
# both derived paths can never assert. Drives run_validations so this
# exercises the cross-field boundary.
run_lowbatt_validation() (
  UPS_NAME=ups
  UPS_DESC='Test UPS'
  UPS_DRIVER=usbhid-ups
  UPS_PORT=auto
  API_USER=monuser
  API_PASSWORD=secret
  API_ADDRESS=0.0.0.0
  API_PORT=3493
  API_TLS=true
  ADMIN_PASSWORD=adminpass
  SHUTDOWN_ON_BATTERY_CRITICAL=false
  DBUS_PROBE_INTERVAL=300
  POLLFREQ=5
  POLLFREQALERT=5
  DEADTIME=15
  FINALDELAY=5
  HOSTSYNC=15
  NOCOMMWARNTIME=300
  RBWARNTIME=43200
  COMMS_WATCHDOG=true
  COMMS_CHECK_INTERVAL=15
  COMMS_RECOVERY_TIMEOUT=90
  COMMS_FAST_RETRIES=3
  COMMS_BACKOFF_FACTOR=5
  LOWBATT_PERCENT=$1
  LOWBATT_RUNTIME=$2
  run_validations
)

for zero in 0 00 000; do
  if run_lowbatt_validation "$zero" "$zero" 2>"$ERR"; then
    no "both low-battery thresholds at $zero refused" 'the configuration disabled every low-battery path'
  elif grep -q 'LOWBATT_PERCENT and LOWBATT_RUNTIME must not both be zero' "$ERR"; then
    ok "both low-battery thresholds at $zero are refused by the cross-field rule"
  else
    no "both low-battery thresholds at $zero refused" "wrong refusal: $(head -c 200 "$ERR")"
  fi
done

if run_lowbatt_validation 0 300 2>"$ERR" \
  && run_lowbatt_validation 20 0 2>"$ERR"; then
  ok 'a zero threshold stays valid when the other low-battery axis is active'
else
  no 'single disabled low-battery axis accepted' "a coherent single-axis configuration was refused: $(head -c 200 "$ERR")"
fi

# --- 10. the two hand-maintained inventories agree -------------------------------
#
# The variable list appears in validation rows and assignments in
# canonicalize_validated_values. Omitting one leaves the variable validated
# but written with its raw bytes, with nothing failing anywhere. Read both
# inventories from the production file rather than restating expected names.
row_vars=$(awk '
  /^[[:space:]]+_check(_optional)? [A-Z_][A-Z0-9_]* / { print $2 }
' "$ENTRYPOINT" | sort)
canonical_vars=$(awk '
  /^canonicalize_validated_values\(\)/ { in_canonical = 1; next }
  in_canonical && /^}/ { exit }
  in_canonical && /^[[:space:]]+[A-Z_][A-Z0-9_]*=/ {
    name = $1
    sub(/=.*/, "", name)
    print name
  }
' "$ENTRYPOINT" | sort)

if [ -z "$row_vars" ] || [ -z "$canonical_vars" ]; then
  printf 'harness error: could not extract both validation inventories\n' >&2
  exit 1
fi

if [ "$row_vars" = "$canonical_vars" ]; then
  ok 'validation rows and canonicalizer carry the same variable inventory'
else
  no 'validation inventory parity' \
    "rows: $row_vars; canonicalizer: $canonical_vars"
fi

# --- 11. normalize_bool's canonical OUTPUT, not just its refusal ------------------
#
# Every production consumer compares the output with the literal `true`, so
# the spelling table is the implementation and swapping an accepted spelling
# between the two arms would reverse a safety toggle while smoke.sh stays green.
load_function normalize_bool

if [ "$(normalize_bool API_TLS true)" = "true" ] \
  && [ "$(normalize_bool API_TLS TRUE)" = "true" ] \
  && [ "$(normalize_bool API_TLS 1)" = "true" ] \
  && [ "$(normalize_bool API_TLS yes)" = "true" ] \
  && [ "$(normalize_bool API_TLS On)" = "true" ] \
  && [ "$(normalize_bool API_TLS false)" = "false" ] \
  && [ "$(normalize_bool API_TLS FALSE)" = "false" ] \
  && [ "$(normalize_bool API_TLS 0)" = "false" ] \
  && [ "$(normalize_bool API_TLS no)" = "false" ] \
  && [ "$(normalize_bool API_TLS Off)" = "false" ]; then
  ok 'normalize_bool maps every accepted spelling to its canonical true or false output'
else
  no 'normalize_bool canonical outputs' 'an accepted boolean spelling mapped to the wrong canonical value'
fi

# Credentials retain trailing LF for fail-closed validation; presentation values strip it.
load_function canonicalize_validated_values
credential_lf=$(printf 'filesecret\nx')
credential_lf=${credential_lf%x}

credential_lf_refused() (
  case "$1" in
    API_PASSWORD)
      API_PASSWORD="$credential_lf"
      canonicalize_validated_values
      _dispatch_check API_PASSWORD "$API_PASSWORD" control
      ;;
    ADMIN_PASSWORD)
      ADMIN_PASSWORD="$credential_lf"
      canonicalize_validated_values
      _dispatch_check ADMIN_PASSWORD "$ADMIN_PASSWORD" control
      ;;
  esac
)

for credential_name in API_PASSWORD ADMIN_PASSWORD; do
  : >"$ERR"
  if credential_lf_refused "$credential_name" 2>"$ERR"; then
    no "$credential_name trailing LF refused" 'the credential was silently canonicalized and accepted'
  elif grep -Fq "msg=\"env var contains control characters\" var=$credential_name" "$ERR"; then
    ok "$credential_name retains a trailing LF for the named fail-closed refusal"
  else
    no "$credential_name trailing LF refused" "wrong refusal: $(head -c 200 "$ERR")"
  fi
done

if (
  UPS_DESC="$credential_lf"
  canonicalize_validated_values
  [ "$UPS_DESC" = filesecret ]
  _dispatch_check UPS_DESC "$UPS_DESC" control
); then
  ok 'the same trailing LF remains canonicalized for a presentation value'
else
  no 'presentation trailing LF canonicalized' 'UPS_DESC did not strip to filesecret and pass validation'
fi

# --- 12. every credential-row check refuses without disclosing the value -------
credential_table=$(awk '
  /^[[:space:]]+_check (API_PASSWORD|ADMIN_PASSWORD) / {
    printf "%s:", $2
    for (i = 4; i <= NF; i++) {
      printf "%s%s", (i == 4 ? "" : ","), $i
    }
    print ""
  }
' "$ENTRYPOINT")
if [ "$(printf '%s\n' "$credential_table" | grep -c .)" -ne 2 ]; then
  printf 'harness error: could not extract both credential validation rows\n' >&2
  exit 1
fi

credential_probe_value() {
  case "$1" in
    control) printf 'LeakMarker\rsuffix' ;;
    quotes) printf 'LeakMarker"suffix' ;;
    backslash) printf 'LeakMarker\\suffix' ;;
    hash) printf 'LeakMarker#suffix' ;;
    nospace | identifier) printf 'LeakMarker suffix' ;;
    nut_word) printf 'LeakMarker\377suffix' ;;
    brackets) printf 'LeakMarker]suffix' ;;
    numeric) printf 'LeakMarker' ;;
    positive | port) printf '0' ;;
    percent) printf '101' ;;
    *) return 1 ;;
  esac
}

while IFS=: read -r credential_name credential_checks; do
  IFS=, read -r -a credential_check_list <<<"$credential_checks"
  for credential_check in "${credential_check_list[@]}"; do
    if ! credential_value=$(credential_probe_value "$credential_check"); then
      printf 'harness error: no credential leak probe for validation check %s\n' \
        "$credential_check" >&2
      exit 1
    fi
    : >"$ERR"
    if (_dispatch_check "$credential_name" "$credential_value" "$credential_check") 2>"$ERR"; then
      no "$credential_name $credential_check refusal" 'the malformed credential was accepted'
    elif grep -Fq "var=$credential_name" "$ERR" \
      && ! grep -Fq 'value=' "$ERR" \
      && ! grep -Fq 'LeakMarker' "$ERR"; then
      ok "$credential_name $credential_check refuses without disclosing the value"
    else
      no "$credential_name $credential_check refusal" \
        "wrong or value-bearing diagnostic: $(head -c 200 "$ERR")"
    fi
  done
done <<<"$credential_table"

# --- 13. the documented and the validated inventories agree ----------------------
#
# README.md's environment table is the operator-facing contract; the shipped
# `_check <NAME>` rows are what actually gets validated. Documenting a new
# generated variable without adding its validation row, or retiring a row
# while leaving the variable documented, puts an unchecked value into a NUT
# config file with every other test green. Read both sides out of the tracked
# files at run time and compare as sets so reordering either does not matter.
documented="$WORK/documented-vars"
validated="$WORK/validated-vars"

sed -n 's/^| `\([A-Z][A-Z0-9_]*\)` |.*/\1/p' "$REPO_ROOT/README.md" \
  | sort -u >"$documented"
awk '/^[[:space:]]+_check(_optional)? [A-Z][A-Z0-9_]* / { print $2 }' "$ENTRYPOINT" \
  | sort -u >"$validated"

if [ ! -s "$documented" ] || [ ! -s "$validated" ]; then
  no 'validation inventory parsed' 'README.md or the shipped validation rows produced an empty inventory'
elif diff -u "$documented" "$validated" >"$WORK/inventory.diff"; then
  ok 'every documented environment variable has a shipped validation row, and every row is documented'
else
  no 'documented and validated environment inventories match' "$(cat "$WORK/inventory.diff")"
fi

report
