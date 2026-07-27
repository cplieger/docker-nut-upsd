#!/usr/bin/env bash
# The validation table's dispatch layer: _run_table(), _resolve_var(),
# _dispatch_check().
#
# Every input-validation guard in this image is reached through these three
# functions. tests/smoke.sh drives the guards themselves hard (the whole
# injection matrix, through run_validations), but it can only ever observe "the
# table as shipped rejected this value". What it cannot see is the dispatch
# layer's own fail-closed rules -- the ones that decide whether a row runs AT ALL:
#
#   - a row whose variable name is not in _resolve_var must FAIL, not be skipped;
#   - a row naming an unknown check must FAIL, not be skipped;
#   - only the EMPTY line is skipped, so an accidentally indented row (a reformat,
#     a bad merge) fails loudly instead of silently dropping that variable's
#     checks -- which would reopen the config-injection surface with no log line
#     anywhere and every existing test still green;
#   - the optional table skips only genuinely EMPTY values.
#
# The bait for the skip rule is an INDENTED REAL VARIABLE NAME. A bogus name would
# not distinguish the two rules: it fails on _resolve_var even under a lenient
# skip, so the case would pass with the strict rule gone.
#
# _run_table exits (it is the entrypoint's fail-closed path), so every call here
# runs in a subshell that IS the condition -- `if ( _run_table ... ); then`. The
# naive `( fixture; if _run_table; then ...; fi )` form kills the fixture subshell
# before either branch runs, and the assertion silently vanishes while the tally
# still reads green.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - UPS_NAME/LOWBATT_PERCENT are the INPUTS to validate.sh code that is
#     extracted and sourced at RUNTIME, so shellcheck cannot see the reads.
#   SC1090/SC1091 - the sourced paths are produced by the extraction step above,
#     so there is nothing on disk for shellcheck to follow at lint time.
# shellcheck disable=SC2015,SC2034,SC1090,SC1091
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-validate.sh bash tests/shell/validation_dispatch_test.sh
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] && ENTRYPOINT="$REPO_ROOT/validate.sh"

# The integer ceiling validate_numeric bounds against, sourced from the shipped
# file rather than restated here. The range ENDS at the following blank line, not
# at a repeat of the start pattern: sed does not re-test a regex end address on the
# start line, and with no second copy of the declaration in the file the range ran
# to EOF and sourced the whole of validate.sh -- which would mask a missing
# dependency in the explicit load list below.
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
  validate_numeric validate_percent _dispatch_check _resolve_var _run_table; do
  load_function "$fn"
done

ERR="$WORK/err.log"
UPS_NAME=ups
LOWBATT_PERCENT=""

# --- 1. an unknown CHECK name fails closed ---------------------------------------
#
# The table is edited by hand; a typo'd check name must not mean "this variable is
# now unvalidated".
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
# Not just "some validator ran": the percent arm must reach validate_percent, whose
# range message is the one an operator sees. The optional table's percent checks
# (LOWBATT_PERCENT, CRITBATT_PERCENT) are reached by nothing else.
if (_dispatch_check LOWBATT_PERCENT 101 percent) 2>"$ERR"; then
  no 'percent arm routes correctly' 'a 101% threshold was accepted'
else
  grep -q 'must be 0-100' "$ERR" \
    && ok 'the percent arm reaches validate_percent (101 rejected with its range message)' \
    || no 'percent arm routes correctly' "wrong validator ran: $(head -c 200 "$ERR")"
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
[ "$(_resolve_var UPS_NAME 2>/dev/null)" = "ups" ] \
  && ok 'a known table variable resolves to its environment value' \
  || no 'known variable resolves' 'the resolver did not return the environment value'

# --- 6. THE SKIP RULE: an indented real row fails loudly -------------------------
#
# "  UPS_NAME:control" is a row a reformat or a bad merge produces. If the loop
# skipped anything that is not a clean row, UPS_NAME -- written into ups.conf as a
# [section] header -- would stop being checked for control characters, brackets and
# identifier shape, with nothing failing anywhere. The assertion is the
# unknown-variable line, which proves the row was DISPATCHED (and rejected),
# not skipped.
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
# Isolates the same `case '' ) continue` rule from the opposite side. Without it
# every table would fail on its own leading and trailing newline, so this case is
# what keeps case 6 from being satisfiable by simply deleting the skip.
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
# The isolating pair for case 8: dropping the emptiness test from that condition
# would skip every optional row, so a set-but-invalid threshold would reach
# upsmon.conf unchecked.
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

report
