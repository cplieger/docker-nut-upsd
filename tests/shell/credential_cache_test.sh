#!/usr/bin/env bash
# _resolve_cached_password(): the engine behind ADMIN_PASSWORD and the internal
# LOCAL_UPSMON_PASSWORD -- the two credentials this container generates itself.
#
# What it returns is written straight into upsd.users, where [admin] holds
# actions=set, actions=fsd and instcmds=all, and [local_upsmon] is the bundled
# upsmon's own primary credential. So "the cache is trusted when it should not be"
# means upsd boots with FSD authority behind a truncated or all-whitespace
# password, and re-serves that same weak value on every restart.
#
# tests/smoke.sh covers the happy path (generate, cache, reuse) and the
# directory-at-the-cache-path refusal. What it never reaches, and nothing else
# does either, is the cache VALIDATION and the short-generation refusal:
#   - a cache that is the wrong size,
#   - a cache that is exactly the right size but all whitespace,
#   - a generation pipeline that yields fewer than PASSWORD_LENGTH characters,
#   - and resolve_admin_password propagating that refusal instead of booting on
#     an empty credential.
#
# PASSWORD_LENGTH/PASSWORD_RAW_BYTES are file-scope readonly in password.sh but
# plain assignments once extracted; they are sourced from the shipped file rather
# than restated here, so a change to either moves the baits with it.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - ADMIN_PASSWORD_FILE and the PASSWORD_* constants are the INPUTS to
#     password.sh code that is extracted and sourced at RUNTIME, so shellcheck
#     cannot see the reads.
#   SC1090/SC1091 - the sourced paths are produced by the extraction step above,
#     so there is nothing on disk for shellcheck to follow at lint time.
# shellcheck disable=SC2015,SC2034,SC1090,SC1091
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-password.sh bash tests/shell/credential_cache_test.sh
SUBJECT="$REPO_ROOT/password.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"

# log_value lives in validate.sh, which the entrypoint sources alongside this
# file. Always read from its own file: the override above aims at ONE target.
ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function log_value

ENTRYPOINT="$SUBJECT"
# The real length contract, not a restatement of it.
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
    && grep -q 'cached ADMIN_PASSWORD invalid (wrong size, unreadable, or whitespace-only); regenerating' "$ERR"
}

# n_chars <count> <char>: a repeated-byte string built without seq (head and tr are
# already dependencies of the pipeline under test).
n_chars() {
  head -c "$1" /dev/zero | tr '\0' "$2"
}

# --- 1. the positive control: a good cache IS reused ------------------------------
#
# Every rejection case below would also pass against a function that regenerates
# unconditionally -- which would silently rotate upsd's admin credential on every
# restart. This case is what makes the rest mean something.
GOOD=$(n_chars "$PASSWORD_LENGTH" A)
printf '%s' "$GOOD" >"$CACHE"
resolve
[ "$PW" = "$GOOD" ] && grep -q 'reusing ADMIN_PASSWORD from container FS' "$ERR" \
  && ok 'a cache of exactly PASSWORD_LENGTH printable bytes is reused verbatim' \
  || no 'valid cache reused' "got a different value (len ${#PW}) or no reuse log line"

# --- 2. an OVERSIZED cache is not silently truncated ------------------------------
#
# The isolating bait for the `stat -c %s` clause, and the reason a size check
# exists at all next to the length check: the read is capped at PASSWORD_LENGTH,
# so without the size test a grown or corrupted cache yields a perfectly
# well-formed PASSWORD_LENGTH-character prefix and is trusted. An undersized cache
# (case 4) cannot isolate it, because the length check catches that one too.
BIG=$(n_chars $((PASSWORD_LENGTH * 3)) A)
printf '%s' "$BIG" >"$CACHE"
resolve
regenerated "$GOOD" \
  && ok 'an oversized cache is rejected, not truncated to a usable-looking prefix' \
  || no 'oversized cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 3. an all-WHITESPACE cache of the right size is treated as absent ------------
#
# The isolating bait for the `tr -d '[:space:]'` clause: exactly PASSWORD_LENGTH
# space bytes passes the size check AND the length check, so that clause is the
# only thing between a corrupted writable layer and upsd's [admin] account being
# configured with a password of spaces.
printf "%${PASSWORD_LENGTH}s" '' >"$CACHE"
resolve
regenerated "$GOOD" && [ -n "$(printf '%s' "$PW" | tr -d '[:space:]')" ] \
  && ok 'an all-whitespace cache of exactly PASSWORD_LENGTH bytes is regenerated, not served' \
  || no 'whitespace-only cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 4. an undersized cache is rejected ------------------------------------------
#
# The truncated-write shape. Two redundant clauses catch it (size and length), so
# this case cannot isolate either -- cases 2 and 3 do that. It is here because it
# is the failure an interrupted write actually produces.
printf 'short' >"$CACHE"
resolve
regenerated "$GOOD" \
  && ok 'a truncated cache is rejected and regenerated' \
  || no 'undersized cache' "PW=[$PW] len=${#PW}; log: $(head -c 200 "$ERR")"

# --- 5. the self-heal is real: the new value replaces the bad cache ---------------
[ "$(head -c "$PASSWORD_LENGTH" "$CACHE")" = "$PW" ] \
  && ok 'the regenerated password replaces the rejected cache (stable across the next restart)' \
  || no 'cache self-heal' 'the cache still holds the rejected value'

# --- 6. a SHORT generated password is refused, never used -------------------------
#
# Stripping `/+=` can in principle leave fewer than PASSWORD_LENGTH characters, and
# a short /dev/urandom read would too. base64 is the one stub here -- the rest of
# the shipped pipeline (head, tr, the length test) runs for real. Asserting only
# the log line would pass with the `return 1` deleted, so the status AND the
# absence of a cached weak value are both asserted.
rm -f "$CACHE"
# Invoked indirectly: the generation pipeline that calls base64 lives in the
# function extracted and sourced above, which shellcheck cannot see into.
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

# --- 7. resolve_admin_password PROPAGATES the refusal -----------------------------
#
# Asserted at the boot level: a refused credential must fail the boot rather than
# leave the entrypoint continuing with an empty ADMIN_PASSWORD, to trip much later
# on generate_all_configs' :? guard, if at all. Two mechanisms carry it (the
# explicit `|| return 1` and the fact that a failed command substitution is itself
# the assignment's status), so this case isolates neither -- it fails when the
# underlying refusal stops happening, which is the property that matters. base64 is
# still stubbed short here, so that inner refusal is real.
if (
  ADMIN_PASSWORD=""
  resolve_admin_password 2>/dev/null
); then
  no 'refusal propagated' 'resolve_admin_password returned 0 after a refused generation'
else
  ok 'resolve_admin_password propagates the weak-credential refusal to the boot'
fi
unset -f base64

# --- 8. the control for case 7: the wrapper still works ---------------------------
rm -f "$CACHE"
if (
  ADMIN_PASSWORD=""
  resolve_admin_password 2>/dev/null
  [ "${#ADMIN_PASSWORD}" -eq "$PASSWORD_LENGTH" ]
); then
  ok 'resolve_admin_password sets a full-length ADMIN_PASSWORD when generation succeeds'
else
  no 'wrapper happy path' 'resolve_admin_password did not set a full-length password'
fi

report
