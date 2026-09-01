#!/usr/bin/env bash
# _resolve_cached_password(): the engine behind ADMIN_PASSWORD and the internal
# LOCAL_UPSMON_PASSWORD -- the two credentials this container generates itself.
#
# What it returns is written into upsd.users, where [admin] holds actions=set,
# actions=fsd and instcmds=all. So "the cache is trusted when it should not be"
# means upsd boots with FSD authority behind a truncated or all-whitespace
# password, re-served on every restart.
#
# tests/smoke.sh covers the happy path and the directory-at-the-cache-path
# refusal. This file covers the cache VALIDATION and short-generation refusal
# that nothing else reaches: a wrong-size cache, an all-whitespace cache of the
# right size, a generation pipeline yielding fewer than PASSWORD_LENGTH
# characters, and resolve_admin_password propagating that refusal.
#
# Lint directives for this whole file, each against a stated guarantee:
#   SC2015 - ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
#   SC2034 - ADMIN_PASSWORD_FILE and PASSWORD_* are inputs to code extracted
#     and sourced at runtime, so shellcheck cannot see the reads.
#   SC1090/SC1091 - the sourced paths are produced by extraction, so there is
#     nothing on disk for shellcheck to follow at lint time.
# shellcheck disable=SC2015,SC2034,SC1090,SC1091
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins (the red-check):
#   ENTRYPOINT=/tmp/mut-password.sh bash tests/shell/credential_cache_test.sh
SUBJECT="$REPO_ROOT/password.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"

# log_value lives in validate.sh, sourced alongside password.sh by the entrypoint.
ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function log_value

ENTRYPOINT="$SUBJECT"
consts=$(extract_range '^readonly PASSWORD_RAW_BYTES=' '^readonly PASSWORD_MIN_LENGTH=') || exit 1
. "$consts"
load_function _replace_file
load_function _resolve_cached_password
load_function resolve_admin_password

CACHE="$WORK/admin_password"
ERR="$WORK/err.log"
ADMIN_PASSWORD_FILE="$CACHE"

# resolve <cache-content-writer...>: plants a cache, resolves, and leaves the
# result in $PW / the log in $ERR. Returns the function's own status.
resolve() {
  : >"$ERR"
  PW=$(_resolve_cached_password ADMIN_PASSWORD "$CACHE" 2>"$ERR")
}

regenerated() {
  [ "${#PW}" -eq "$PASSWORD_LENGTH" ] && [ "$PW" != "$1" ] \
    && grep -q 'cached ADMIN_PASSWORD invalid (wrong size, unreadable, or not from the generated alphabet); regenerating' "$ERR"
}

# n_chars <count> <char>: a repeated-byte string built without seq.
n_chars() {
  head -c "$1" /dev/zero | tr '\0' "$2"
}

# --- 1. the positive control: a good cache IS reused -----------------------------
#
# Every rejection case below would also pass against a function that regenerates
# unconditionally, which would silently rotate upsd's admin credential on every
# restart. This case is what makes the rest mean something.
GOOD=$(n_chars "$PASSWORD_LENGTH" A)
printf '%s' "$GOOD" >"$CACHE"
resolve
[ "$PW" = "$GOOD" ] && grep -q 'reusing ADMIN_PASSWORD from container FS' "$ERR" \
  && ok 'a cache of exactly PASSWORD_LENGTH printable bytes is reused verbatim' \
  || no 'valid cache reused' "got a different value (len ${#PW}) or no reuse log line"

# --- 2. an OVERSIZED cache is not silently truncated -----------------------------
#
# Isolates the `stat -c %s` clause: the read is capped at PASSWORD_LENGTH, so
# without the size test a grown or corrupted cache yields a well-formed
# PASSWORD_LENGTH-character prefix and is trusted.
BIG=$(n_chars $((PASSWORD_LENGTH * 3)) A)
printf '%s' "$BIG" >"$CACHE"
resolve
regenerated "$GOOD" \
  && ok 'an oversized cache is rejected, not truncated to a usable-looking prefix' \
  || no 'oversized cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 3. an all-WHITESPACE cache of the right size is treated as absent -----------
#
# Isolates the alphabet clause (`tr -d 'A-Za-z0-9'`): exactly PASSWORD_LENGTH
# space bytes passes the size AND length checks, so this clause is the only
# thing between a corrupted writable layer and a spaces-only [admin] password.
printf "%${PASSWORD_LENGTH}s" '' >"$CACHE"
resolve
regenerated "$GOOD" && [ -n "$(printf '%s' "$PW" | tr -d '[:space:]')" ] \
  && ok 'an all-whitespace cache of exactly PASSWORD_LENGTH bytes is regenerated, not served' \
  || no 'whitespace-only cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 3b. ...and so is one whose trailing newline hides a truncated value ---------
#
# Isolates the `${#_rcp_pw} -eq PASSWORD_LENGTH` clause: PASSWORD_LENGTH-1
# printable bytes plus a newline is PASSWORD_LENGTH bytes on disk, and command
# substitution strips the newline before the alphabet clause sees it, so only
# the length check stands between a truncated value and upsd's [admin] account.
SHORT_BY_LF=$(n_chars $((PASSWORD_LENGTH - 1)) A)
printf '%s\n' "$SHORT_BY_LF" >"$CACHE"
resolve
regenerated "$SHORT_BY_LF" \
  && ok 'a right-sized cache shortened by command substitution is regenerated at full length' \
  || no 'command-substitution-shortened cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 4. an undersized cache is rejected ------------------------------------------
#
# The truncated-write shape an interrupted write actually produces; cases 2 and 3
# isolate the size/length clauses individually.
printf 'short' >"$CACHE"
resolve
regenerated "$GOOD" \
  && ok 'a truncated cache is rejected and regenerated' \
  || no 'undersized cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 5. the self-heal is real: the new value replaces the bad cache -------------
[ "$(head -c "$PASSWORD_LENGTH" "$CACHE")" = "$PW" ] \
  && ok 'the regenerated password replaces the rejected cache (stable across the next restart)' \
  || no 'cache self-heal' 'the cache still holds the rejected value'

# --- 6. a SHORT generated password is refused, never used -----------------------
#
# base64 is the one stub -- the rest of the pipeline (head, tr, the length
# test) runs for real. Asserts status AND the absence of a cached weak value,
# not just the log line.
rm -f "$CACHE"
# shellcheck disable=SC2329
base64() {
  printf 'abc'
}
if resolve; then
  no 'short generation refused' "returned rc=0 with a ${#PW}-char password"
else
  [ -z "$PW" ] && [ ! -e "$CACHE" ] \
    && grep -q 'generated ADMIN_PASSWORD has unexpected length; refusing weak credentials' "$ERR" \
    && ok 'a short generated password returns non-zero, prints nothing, and caches nothing' \
    || no 'short generation refused' "PW=[$PW] cache_exists=$([ -e "$CACHE" ] && echo yes || echo no)"
fi

# --- 7. resolve_admin_password PROPAGATES the refusal ----------------------------
#
# A refused credential must fail the boot rather than continue with an empty
# ADMIN_PASSWORD. base64 is still stubbed short here, so the inner refusal is
# real.
if (
  ADMIN_PASSWORD=""
  resolve_admin_password 2>/dev/null
); then
  no 'refusal propagated' 'resolve_admin_password returned 0 after a refused generation'
else
  ok 'resolve_admin_password propagates the weak-credential refusal to the boot'
fi
unset -f base64

# --- 8. a fresh cache is generated without a corruption warning -----------------
rm -f "$CACHE"
: >"$ERR"
ADMIN_PASSWORD=""
if resolve_admin_password 2>"$ERR"; then
  [ "${#ADMIN_PASSWORD}" -eq "$PASSWORD_LENGTH" ] && [ -f "$CACHE" ] \
    && grep -q 'generated ADMIN_PASSWORD; cached for intra-container restarts' "$ERR" \
    && ! grep -q 'cached ADMIN_PASSWORD invalid' "$ERR" \
    && ok 'a missing cache generates ADMIN_PASSWORD without claiming corruption' \
    || no 'fresh-cache generation' "value_len=${#ADMIN_PASSWORD} cache_exists=$([ -e "$CACHE" ] && printf yes || printf no); log: $(head -c 200 "$ERR")"
else
  no 'fresh-cache generation' "resolve_admin_password returned non-zero: $(head -c 200 "$ERR")"
fi

# --- 9. an operator-supplied password bypasses generation -----------------------
rm -f "$CACHE"
: >"$ERR"
ADMIN_PASSWORD='operator supplied 123'
if resolve_admin_password 2>"$ERR"; then
  [ "$ADMIN_PASSWORD" = 'operator supplied 123' ] && [ ! -e "$CACHE" ] \
    && ok 'a non-empty ADMIN_PASSWORD passes through byte-for-byte without creating a cache' \
    || no 'operator password pass-through' "value=[$ADMIN_PASSWORD] cache_exists=$([ -e "$CACHE" ] && printf yes || printf no)"
else
  no 'operator password pass-through' "resolver returned non-zero: $(head -c 200 "$ERR")"
fi

report
