#!/usr/bin/env bash
# The validation table's dispatch layer: _run_table(), _resolve_var(),
# _dispatch_check().
#
# tests/smoke.sh drives the guards themselves through run_validations, but it
# can only observe "the table as shipped rejected this value". This file
# covers the dispatch layer's own fail-closed rules that decide whether a row
# runs at all:
#
#   - a row whose variable name is not in _resolve_var must FAIL, not skip;
#   - a row naming an unknown check must FAIL, not skip;
#   - only the EMPTY line is skipped, so an accidentally indented row (a
#     reformat, a bad merge) fails loudly instead of silently dropping that
#     variable's checks;
#   - the optional table skips only genuinely EMPTY values.
#
# The bait for the skip rule is an INDENTED REAL VARIABLE NAME: a bogus name
# would not distinguish the two rules, since it fails on _resolve_var even
# under a lenient skip.
#
# _run_table exits (the entrypoint's fail-closed path), so every call here
# runs in a subshell that IS the condition -- `if ( _run_table ... ); then`.
# The naive `( fixture; if _run_table; then ...; fi )` form kills the fixture
# subshell before either branch runs, and the assertion silently vanishes
# while the tally still reads green.
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
  validate_percent _dispatch_check _resolve_var _run_table driver_transport run_validations; do
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

# --- 3. dispatch routes to the RIGHT validator -----------------------------------
#
# Not just "some validator ran": the percent arm must reach validate_percent,
# whose range message is what an operator sees.
if (_dispatch_check LOWBATT_PERCENT 101 percent) 2>"$ERR"; then
  no 'percent arm routes correctly' 'a 101% threshold was accepted'
else
  grep -q 'must be 0-100' "$ERR" \
    && ok 'the percent arm reaches validate_percent (101 rejected with its range message)' \
    || no 'percent arm routes correctly' "wrong validator ran: $(head -c 200 "$ERR")"
fi

# --- 3b. ...and the hash arm reaches validate_no_hash ----------------------------
#
# `#` is a parseconf hard error inside a double-quoted NUT value and a comment
# introducer outside one. Assert the hash message, not merely that something
# refused the value.
if (_dispatch_check UPS_DESC 'Rack #1 UPS' hash) 2>"$ERR"; then
  no 'hash arm routes correctly' 'a value containing # was accepted'
else
  grep -q 'contains hash character' "$ERR" \
    && ok 'the hash arm reaches validate_no_hash (a # value rejected with its own message)' \
    || no 'hash arm routes correctly' "wrong validator ran: $(head -c 200 "$ERR")"
fi

# --- 4. an unknown VARIABLE name fails closed ------------------------------------
if (_resolve_var NOT_A_REAL_VAR) 2>"$ERR"; then
  no 'unknown variable refused' 'an unknown table variable resolved successfully'
else
  grep -q 'unknown variable in validation table' "$ERR" \
    && ok 'a row naming an unknown variable fails with the unknown-variable error' \
    || no 'unknown variable refused' "refused without the unknown-variable line: $(head -c 200 "$ERR")"
fi

# --- 5. the control: a known variable resolves to its value ----------------------
#
# The resolver ASSIGNS _value in the caller's shell rather than printing it, so
# a command substitution here would prove nothing about what the checks see.
_value=""
_resolve_var UPS_NAME 2>/dev/null
[ "$_value" = "ups" ] \
  && ok 'a known table variable resolves to its environment value' \
  || no 'known variable resolves' 'the resolver did not assign the environment value'

# --- 6. THE SKIP RULE: an indented real row fails loudly -------------------------
#
# "  UPS_NAME:control" is a row a reformat or a bad merge produces. If the loop
# skipped anything that is not a clean row, UPS_NAME -- written into ups.conf as
# a [section] header -- would stop being checked for control characters,
# brackets and identifier shape, with nothing failing anywhere. The assertion
# is the unknown-variable line, proving the row was DISPATCHED, not skipped.
INDENTED_TABLE='
  UPS_NAME:control
'
if (_run_table "$INDENTED_TABLE" 0) 2>"$ERR"; then
  no 'indented row fails closed' 'an indented table row was silently skipped (fail-open)'
else
  grep -q 'unknown variable in validation table' "$ERR" \
    && ok 'an indented table row fails closed through the unknown-variable path' \
    || no 'indented row fails closed' "failed for another reason: $(head -c 200 "$ERR")"
fi

# --- 7. the other direction: the literal's own blank lines ARE skipped -----------
#
# Isolates the same `case '' ) continue` rule from the opposite side; without
# it every table would fail on its own leading and trailing newline.
CLEAN_TABLE='
UPS_NAME:control,identifier
'
if (_run_table "$CLEAN_TABLE" 0) 2>"$ERR"; then
  ok 'the blank first and last lines of a table literal are skipped'
else
  no 'blank lines skipped' "a clean table failed: $(head -c 200 "$ERR")"
fi

# --- 8. the optional table skips only genuinely empty values ---------------------
OPTIONAL_TABLE='
LOWBATT_PERCENT:control,percent
'
if (
  LOWBATT_PERCENT=""
  _run_table "$OPTIONAL_TABLE" 1
) 2>"$ERR"; then
  ok 'an unset optional variable is skipped rather than rejected as non-numeric'
else
  no 'optional empty skipped' "an unset optional var was validated: $(head -c 200 "$ERR")"
fi

# --- 9. ...and validates the ones that ARE set -----------------------------------
#
# Dropping the emptiness test from case 8's condition would skip every optional
# row, so a set-but-invalid threshold would reach upsmon.conf unchecked.
if (
  LOWBATT_PERCENT=250
  _run_table "$OPTIONAL_TABLE" 1
) 2>"$ERR"; then
  no 'optional set value validated' 'a set optional variable was skipped instead of validated'
else
  grep -q 'must be 0-100' "$ERR" \
    && ok 'a SET optional variable is validated (the skip is emptiness-only)' \
    || no 'optional set value validated' "failed for another reason: $(head -c 200 "$ERR")"
fi

# --- 9b. jointly disabled low-battery thresholds fail closed ---------------------
#
# Each row accepts zero because zero disables only that axis; the pair is
# unsafe together because ignorelb discards the UPS low-battery flag while
# both derived paths can never assert. Drives run_validations so this
# exercises the cross-field boundary.
lowbatt_required_table=$(extract_range "^VALIDATION_TABLE='" "^'\$" "$WORK/lowbatt-required-table.sh") || exit 1
lowbatt_optional_table=$(extract_range "^VALIDATION_TABLE_OPTIONAL='" "^'\$" "$WORK/lowbatt-optional-table.sh") || exit 1
. "$lowbatt_required_table"
. "$lowbatt_optional_table"

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

# --- 10. the three hand-maintained inventories agree -----------------------------
#
# The same variable list is written three times in the shipped file: rows in
# the two tables, arms in _resolve_var, assignments in
# canonicalize_validated_values. Omitting one leaves the variable validated
# but written with its raw bytes, with nothing failing anywhere. Read all
# three out of the production file rather than restating expected names here.
table_vars=$(awk '
  /^VALIDATION_TABLE(_OPTIONAL)?=/ { in_table = 1; next }
  in_table && /^[A-Z_][A-Z0-9_]*:/ {
    name = $0
    sub(/:.*/, "", name)
    print name
    next
  }
  in_table { in_table = 0 }
' "$ENTRYPOINT" | sort)
resolver_vars=$(awk '
  /^_resolve_var\(\)/ { in_resolver = 1; next }
  in_resolver && /^}/ { exit }
  in_resolver && /^[[:space:]]+[A-Z_][A-Z0-9_]*\)/ {
    name = $1
    sub(/\).*/, "", name)
    print name
  }
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

if [ -z "$table_vars" ] || [ -z "$resolver_vars" ] || [ -z "$canonical_vars" ]; then
  printf 'harness error: could not extract all three validation inventories\n' >&2
  exit 1
fi

if [ "$table_vars" = "$resolver_vars" ] && [ "$table_vars" = "$canonical_vars" ]; then
  ok 'validation tables, resolver, and canonicalizer carry the same variable inventory'
else
  no 'validation inventory parity' \
    "tables: $table_vars; resolver: $resolver_vars; canonicalizer: $canonical_vars"
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

# --- 12. the credential rows refuse without disclosing the value -----------------
#
# The property is the PAIRING of the two credential rows with the three silent
# validators, read out of the shipped table rather than restated: a routing
# change fails this. LeakMarker is the sentinel -- a validator that starts
# printing the value it rejected fails here too.
load_function validate_no_quotes
load_function validate_no_backslash
load_function validate_nut_word

credential_table=$(awk '/^(API_PASSWORD|ADMIN_PASSWORD):/ { print }' "$ENTRYPOINT")
if [ "$(printf '%s\n' "$credential_table" | grep -c .)" -ne 2 ]; then
  printf 'harness error: could not extract both credential validation rows\n' >&2
  exit 1
fi

check_credential_refusal() {
  _credential_name=$1
  _credential_value=$2
  _credential_error=$3
  API_PASSWORD=safe
  ADMIN_PASSWORD=safe
  export "$_credential_name=$_credential_value"
  : >"$ERR"

  if (_run_table "$credential_table" 0) 2>"$ERR"; then
    no "$_credential_name $_credential_error refusal" 'the malformed credential was accepted'
  elif grep -Fq "$_credential_error" "$ERR" \
    && grep -Fq "var=$_credential_name" "$ERR" \
    && ! grep -Fq 'LeakMarker' "$ERR"; then
    ok "$_credential_name is refused by $_credential_error without disclosing its value"
  else
    no "$_credential_name $_credential_error refusal" \
      "wrong or value-bearing diagnostic: $(head -c 200 "$ERR")"
  fi
}

check_credential_refusal API_PASSWORD 'LeakMarker"suffix' 'contains double-quote'
check_credential_refusal API_PASSWORD 'LeakMarker\suffix' 'contains backslash'
check_credential_refusal API_PASSWORD "LeakMarker$(printf '\r')suffix" 'contains control characters'
check_credential_refusal ADMIN_PASSWORD 'LeakMarker"suffix' 'contains double-quote'
check_credential_refusal ADMIN_PASSWORD 'LeakMarker\suffix' 'contains backslash'
check_credential_refusal ADMIN_PASSWORD "LeakMarker$(printf '\r')suffix" 'contains control characters'

# --- 13. the documented and the validated inventories agree ----------------------
#
# README.md's environment table is the operator-facing contract; the two
# shipped table literals are what actually gets validated. Documenting a new
# generated variable without adding its validation row -- or retiring a row
# while leaving the variable documented -- puts an unchecked value into a NUT
# config file with every other test green. Read both sides out of the tracked
# files at run time and compare as sets so reordering either does not matter.
required_table=$(extract_range "^VALIDATION_TABLE='" "^'\$" "$WORK/required-table.sh") || exit 1
optional_table=$(extract_range "^VALIDATION_TABLE_OPTIONAL='" "^'\$" "$WORK/optional-table.sh") || exit 1
. "$required_table"
. "$optional_table"

documented="$WORK/documented-vars"
validated="$WORK/validated-vars"

sed -n 's/^| `\([A-Z][A-Z0-9_]*\)` |.*/\1/p' "$REPO_ROOT/README.md" \
  | sort -u >"$documented"
printf '%s\n%s\n' "$VALIDATION_TABLE" "$VALIDATION_TABLE_OPTIONAL" \
  | sed -n 's/^\([A-Z][A-Z0-9_]*\):.*/\1/p' \
  | sort -u >"$validated"

if [ ! -s "$documented" ] || [ ! -s "$validated" ]; then
  no 'validation inventory parsed' 'README.md or the shipped validation tables produced an empty inventory'
elif diff -u "$documented" "$validated" >"$WORK/inventory.diff"; then
  ok 'every documented environment variable has a shipped validation row, and every row is documented'
else
  no 'documented and validated environment inventories match' "$(cat "$WORK/inventory.diff")"
fi

report
