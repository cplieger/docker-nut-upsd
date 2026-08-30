#!/usr/bin/env bash
# The prior-lifecycle cleanup must clear every reserved *.pid pathname and
# refuse startup when a non-empty directory survives reclamation.
# SC2015: ok/no always return zero. SC2016: the single-quoted child script
# intentionally expands BLOCK only in the child environment.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

SUBJECT="$REPO_ROOT/entrypoint.sh"
[ "$ENTRYPOINT" = "$REPO_ROOT/entrypoint.sh" ] || SUBJECT="$ENTRYPOINT"
ENTRYPOINT="$SUBJECT"
BLOCK=$(extract_range '^stale_nut_pid_paths() {' '^fi$' "$WORK/stale-pid-block.sh") || exit 1

REAL_FIND=$(command -v find)
mkdir -p "$WORK/bin"
cat >"$WORK/bin/find" <<'STUB'
#!/usr/bin/env bash
set -u
[ "$1" = /var/run/nut ] || exit 64
shift
printf '%s\n' "$*" >>"$FIND_CALLS"
exec "$REAL_FIND" "$PID_ROOT" "$@"
STUB
chmod +x "$WORK/bin/find"

run_block() {
  : >"$WORK/stdout"
  : >"$WORK/stderr"
  : >"$WORK/find-calls"
  if env PATH="$WORK/bin:$PATH" BLOCK="$BLOCK" PID_ROOT="$1" \
    REAL_FIND="$REAL_FIND" FIND_CALLS="$WORK/find-calls" \
    bash -c '
      set -eu
      log_value() { printf "%s" "$1"; }
      . "$BLOCK"
    ' >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

CLEAN="$WORK/clean"
mkdir "$CLEAN"
run_block "$CLEAN"
[ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/stderr" ] \
  && ok 'an empty PID directory starts without a cleanup diagnostic' \
  || no 'empty PID directory' "rc=$RUN_RC stderr=$(cat "$WORK/stderr")"

RECLAIMABLE="$WORK/reclaimable"
mkdir "$RECLAIMABLE"
: >"$RECLAIMABLE/regular.pid"
ln -s missing "$RECLAIMABLE/symlink.pid"
mkfifo "$RECLAIMABLE/fifo.pid"
mkdir "$RECLAIMABLE/empty-directory.pid"
run_block "$RECLAIMABLE"
remaining=$($REAL_FIND "$RECLAIMABLE" -maxdepth 1 -name '*.pid' -print -quit)
[ "$RUN_RC" -eq 0 ] && [ -z "$remaining" ] \
  && grep -q 'clearing stale NUT PID paths' "$WORK/stderr" \
  && ! grep -q 'refusing to start' "$WORK/stderr" \
  && ok 'files, symlinks, FIFOs, and empty directories at *.pid paths are all reclaimed' \
  || no 'all reclaimable PID object types reclaimed' "rc=$RUN_RC remaining=$remaining stderr=$(cat "$WORK/stderr")"

BLOCKED="$WORK/blocked"
mkdir -p "$BLOCKED/nonempty.pid"
: >"$BLOCKED/nonempty.pid/child"
run_block "$BLOCKED"
[ "$RUN_RC" -eq 1 ] && [ -d "$BLOCKED/nonempty.pid" ] \
  && grep -q 'failed to clear a stale NUT PID path; refusing to start' "$WORK/stderr" \
  && grep -q 'nonempty.pid' "$WORK/stderr" \
  && ok 'a surviving reserved PID pathname refuses startup and names the survivor' \
  || no 'surviving PID pathname refusal' "rc=$RUN_RC stderr=$(cat "$WORK/stderr")"

report
