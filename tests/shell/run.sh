#!/usr/bin/env bash
# Runs every entrypoint.sh unit test in this directory.
#
# This filename is the contract: cplieger/ci's shell-ci.yaml runs
# `tests/shell/run.sh` when it exists, and skips otherwise, so a repo opts into
# shell unit testing by committing this file. Keep the name.
#
# The hook tests -f and invokes this through `bash`, so the exec bit is not
# load-bearing (it was committed 100644 once, which under an -x check would have
# skipped the whole suite silently and still reported CI green). The bit is set
# anyway, for anyone running it directly.
#
# WHAT THIS REPO'S SUITE COVERS. This file is repo-owned (lib.sh and
# harness_test.sh beside it are synced from cplieger/ci), so the per-repo scope
# rationale lives here.
#
# WHY THESE TESTS EXIST, and how they differ from tests/smoke.sh: this repo
# already has a real unit-test suite. tests/smoke.sh sources the four shipped
# helpers off /usr/local/bin and calls the REAL functions with hostile input —
# but it runs ONLY inside `docker build` (the Dockerfile test stage), and this
# image compiles NUT, libmodbus and net-snmp from upstream source natively per
# arch. So every guard it covers costs a full from-source image build to check,
# and the guards it does NOT cover are checked nowhere at all.
#
# This suite is scoped to that second set: re-testing the injection matrix would be
# duplication that leaves the real gap untested. The scoping is to the FAIL-CLOSED
# and error paths, not zero overlap — a handful of positive controls here do cover
# ground smoke.sh also walks (a valid credential-cache reuse, a clean TLS
# selection), and they are kept deliberately, because without them every refusal
# assertion beside them would also pass against a function that refuses everything.
# What lives here is the boot path's most consequential uncovered surface:
#   - kill_stale_driver_from_pidfile's confused-deputy guards, which stand
#     between a nut-writable pidfile and a root `kill -9`;
#   - wait_for_pidfile's startup trust gate;
#   - the credential-cache guards that decide whether upsd's set/FSD account
#     boots with a corrupt or short password;
#   - reconcile_tls_working_copies' failure return, which refuses to leave
#     withdrawn private-key material nut-readable;
#   - the validation table's fail-closed dispatch rules, where a silently
#     skipped row would drop a security check with no log line anywhere;
#   - the two log lines alerts.yaml keys on, which stop firing SILENTLY when
#     their shape changes.
#
# Each *_test.sh is a separate process, so one test's stubs, traps and shell
# options cannot leak into another's. All of them run even when an early one
# fails: a boot path's tests are cheap, and a maintainer wants the whole picture
# from one CI log rather than one failure at a time.
set -u

cd -- "$(dirname -- "$0")" || exit 1

failed=0
ran=0
for t in ./*_test.sh; do
  # A glob that matches nothing expands to itself; treat that as a harness fault
  # rather than a green run, since an empty suite passing silently is how a
  # test directory quietly stops testing anything.
  if [ ! -f "$t" ]; then
    printf 'harness error: no *_test.sh found in %s\n' "$PWD" >&2
    exit 1
  fi
  printf '=== %s\n' "$(basename "$t")"
  if bash "$t"; then
    ran=$((ran + 1))
  else
    ran=$((ran + 1))
    failed=$((failed + 1))
  fi
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf 'FAILED: %d of %d entrypoint test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d entrypoint test files passed\n' "$ran"
