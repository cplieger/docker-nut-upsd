#!/usr/bin/env bash
# reconcile_tls_working_copies(): remove whichever of the two managed TLS working
# copies this boot did NOT provision.
#
# Both copies hold a private key, root:nut 640, readable by upsd. A copy left
# behind by a previous lifecycle (the operator removed the mount, or turned
# API_TLS off) is withdrawn key material still sitting in the writable layer at a
# path a mounted upsd.conf.user may still name -- so upsd can keep serving a key
# the operator believes is gone. That is why this function reports a REMOVAL
# FAILURE instead of shrugging: the entrypoint fails the boot on a non-zero return.
#
# tests/smoke.sh drives the selection branches (self-signed selected under an
# upsd.conf.user override, and API_TLS=false removing both) but always on paths
# that remove cleanly, so the failure return at the end -- the whole reason the
# function has a status -- is exercised nowhere. That is what this file asserts.
#
# The bait for an unremovable path is a POPULATED DIRECTORY, which is what a
# stray bind mount over one of these internal paths looks like. A plain
# unwritable file does NOT work: this code runs as root, where rm -f succeeds
# anyway.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - API_TLS/TLS_CERT_* are the INPUTS to password.sh code that is
#     extracted and sourced at RUNTIME, so shellcheck cannot see the reads.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The file under test; a caller who SET ENTRYPOINT wins, which is the red-check:
#   ENTRYPOINT=/tmp/mut-password.sh bash tests/shell/tls_reconcile_test.sh
SUBJECT="$REPO_ROOT/password.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"

# log_value lives in validate.sh, which the entrypoint sources alongside this
# file. Always read from its own file: the override above aims at ONE target.
ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function log_value

ENTRYPOINT="$SUBJECT"
load_function reconcile_tls_working_copies

# The production paths are /etc/nut/upsd-{selfsigned,mounted}.pem, file-scope
# readonly in password.sh and plain variables once extracted, so the whole
# reconciliation runs against the scratch dir.
TLS_CERT_RUNTIME="$WORK/upsd-selfsigned.pem"
TLS_CERT_MOUNTED_RUNTIME="$WORK/upsd-mounted.pem"
ERR="$WORK/err.log"
API_TLS=true
TLS_CERT_PATH="$TLS_CERT_RUNTIME"

reset_paths() {
  rm -rf "$TLS_CERT_RUNTIME" "$TLS_CERT_MOUNTED_RUNTIME"
  : >"$ERR"
}

# A directory with a file in it: rm -f cannot remove it even as root.
plant_unremovable() {
  mkdir -p "$1"
  : >"$1/mounted-over"
}

# --- 1. the positive control: a clean reconciliation returns 0 --------------------
#
# Every failure assertion below would also pass against a function that always
# returns 1, which would fail every boot.
reset_paths
printf 'selected self-signed key\n' >"$TLS_CERT_RUNTIME"
printf 'withdrawn mounted key\n' >"$TLS_CERT_MOUNTED_RUNTIME"
API_TLS=true
TLS_CERT_PATH="$TLS_CERT_RUNTIME"
if reconcile_tls_working_copies 2>"$ERR"; then
  [ ! -e "$TLS_CERT_MOUNTED_RUNTIME" ] && [ -f "$TLS_CERT_RUNTIME" ] \
    && ok 'the withdrawn working copy is removed, the selected one kept, status 0' \
    || no 'clean reconciliation' 'removed the wrong copy, or left the withdrawn one'
else
  no 'clean reconciliation' "returned non-zero on removable paths: $(head -c 200 "$ERR")"
fi

# --- 2. the other selection branch: a mounted PEM withdraws the self-signed copy ---
#
# Asserted from the opposite direction so the branch cannot be inverted without a
# failure here: with the mounted copy selected, the SELF-SIGNED one is the stale
# key material that must go.
reset_paths
printf 'selected mounted key\n' >"$TLS_CERT_MOUNTED_RUNTIME"
printf 'withdrawn self-signed key\n' >"$TLS_CERT_RUNTIME"
TLS_CERT_PATH="$TLS_CERT_MOUNTED_RUNTIME"
if reconcile_tls_working_copies 2>"$ERR"; then
  [ ! -e "$TLS_CERT_RUNTIME" ] && [ -f "$TLS_CERT_MOUNTED_RUNTIME" ] \
    && ok 'with an operator PEM selected, the stale self-signed working copy is the one removed' \
    || no 'mounted-selected reconciliation' 'the wrong copy survived'
else
  no 'mounted-selected reconciliation' "returned non-zero: $(head -c 200 "$ERR")"
fi

# --- 3. THE FAILURE RETURN: an unremovable withdrawn copy fails the boot ----------
#
# Something mounted over the internal path, so the withdrawn key cannot be
# removed. Returning 0 here would let the boot continue with key material the
# operator believes was withdrawn -- silently, because the entrypoint's only
# signal is this status.
reset_paths
printf 'selected self-signed key\n' >"$TLS_CERT_RUNTIME"
plant_unremovable "$TLS_CERT_MOUNTED_RUNTIME"
TLS_CERT_PATH="$TLS_CERT_RUNTIME"
if reconcile_tls_working_copies 2>"$ERR"; then
  no 'unremovable withdrawn copy' 'returned 0 while the withdrawn TLS working copy was still in place'
else
  grep -q 'cannot remove unselected TLS working copy' "$ERR" \
    && grep -q "path=$TLS_CERT_MOUNTED_RUNTIME" "$ERR" \
    && ok 'an unremovable withdrawn working copy returns non-zero and names the stuck path' \
    || no 'unremovable withdrawn copy' "no structured error naming the path: $(head -c 200 "$ERR")"
fi

# --- 4. the failure does not cost the selected copy -------------------------------
[ -f "$TLS_CERT_RUNTIME" ] \
  && ok 'the removal failure leaves the SELECTED working copy intact' \
  || no 'selected copy survives a failure' 'the selected working copy was removed too'

# --- 5. every managed path is attempted, not just the first ------------------------
#
# With API_TLS=false BOTH copies are withdrawn. A `return 1` on the first failure
# would leave the second path unreported, so the operator would fix one mount and
# hit the same boot failure again. The loop must record the failure and continue.
reset_paths
plant_unremovable "$TLS_CERT_RUNTIME"
plant_unremovable "$TLS_CERT_MOUNTED_RUNTIME"
API_TLS=false
if reconcile_tls_working_copies 2>"$ERR"; then
  no 'both paths reported' 'returned 0 with two unremovable withdrawn copies'
else
  grep -q "path=$TLS_CERT_RUNTIME" "$ERR" && grep -q "path=$TLS_CERT_MOUNTED_RUNTIME" "$ERR" \
    && ok 'with API_TLS off, BOTH unremovable copies are reported (no bail on the first)' \
    || no 'both paths reported' "only one path was named: $(head -c 300 "$ERR")"
fi

report
