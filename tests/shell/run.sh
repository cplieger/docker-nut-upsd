#!/usr/bin/env bash
# Runs every shell unit test in this directory.
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
# This suite targets production paths that tests/smoke.sh cannot exercise
# cheaply: fail-closed lifecycle guards, recovery and shutdown state machines,
# credential and TLS refusals, validation dispatch, and contracts shared by
# lifecycle.sh, the image health probe, and the alert rules. Positive controls
# intentionally overlap smoke coverage where a refusal test would otherwise
# pass against code that rejects every input.
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
  printf 'FAILED: %d of %d shell test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d shell test files passed\n' "$ran"
