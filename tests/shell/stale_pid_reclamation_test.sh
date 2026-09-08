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
ENTRYPOINT="$REPO_ROOT/validate.sh"
LOG_VALUE=$(extract_function log_value "$WORK/log-value.sh") || exit 1
ENTRYPOINT="$SUBJECT"

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
    REAL_FIND="$REAL_FIND" FIND_CALLS="$WORK/find-calls" LOG_VALUE="$LOG_VALUE" \
    bash -c '
      set -eu
      . "$LOG_VALUE"
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

LONG_SURVIVORS="$WORK/long-survivors"
mkdir "$LONG_SURVIVORS"
for _long_index in 1 2 3 4; do
  _long_name=$(printf '%0170d.pid' "$_long_index")
  mkdir "$LONG_SURVIVORS/$_long_name"
  : >"$LONG_SURVIVORS/$_long_name/child"
done
run_block "$LONG_SURVIVORS"
survivor_record=$(grep -F 'failed to clear a stale NUT PID path; refusing to start' "$WORK/stderr" || :)
survivor_detail=${survivor_record##* surviving=\"}
survivor_detail=${survivor_detail%\"}
[ "$RUN_RC" -eq 1 ] && [ "${#survivor_detail}" -eq 512 ] \
  && [ "${survivor_detail: -3}" = '...' ] \
  && [ "$(wc -l <"$WORK/stderr")" -eq 2 ] \
  && ok 'an overlong stale PID survivor inventory is bounded and visibly truncated' \
  || no 'overlong stale PID survivor diagnostic' \
    "rc=$RUN_RC detail_length=${#survivor_detail} detail_suffix=${survivor_detail: -3} stderr=$(tr '\n' '|' <"$WORK/stderr")"

KILLPOWER_BLOCK=$(extract_range '^if \[ -e "\$POWERDOWNFLAG_FILE" \]; then$' '^fi$' "$WORK/killpower-cleanup-block.sh") || exit 1

run_killpower_cleanup() {
  : >"$WORK/stderr"
  if env KILLPOWER_BLOCK="$KILLPOWER_BLOCK" POWERDOWNFLAG_FILE="$WORK/killpower" \
    bash -c '
      set -euf
      . "$KILLPOWER_BLOCK"
    ' >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

rm -f "$WORK/killpower"
run_killpower_cleanup
[ "$RUN_RC" -eq 0 ] && [ ! -e "$WORK/killpower" ] && [ ! -s "$WORK/stderr" ] \
  && ok 'startup is silent when no stale killpower flag exists' \
  || no 'absent stale killpower flag' \
    "rc=$RUN_RC exists=$([ -e "$WORK/killpower" ] && printf yes || printf no) stderr=$(cat "$WORK/stderr")"

: >"$WORK/killpower"
run_killpower_cleanup
[ "$RUN_RC" -eq 0 ] && [ ! -e "$WORK/killpower" ] \
  && grep -Fqx -- "level=info msg=\"clearing stale killpower flag from previous lifecycle\" path=$WORK/killpower" "$WORK/stderr" \
  && ok 'startup clears a stale killpower flag and names its path' \
  || no 'present stale killpower flag' \
    "rc=$RUN_RC exists=$([ -e "$WORK/killpower" ] && printf yes || printf no) stderr=$(cat "$WORK/stderr")"

mkdir "$WORK/killpower-rm-failure-bin"
cat >"$WORK/killpower-rm-failure-bin/rm" <<'STUB'
#!/usr/bin/env bash
set -u
[ "$#" -eq 2 ] && [ "$1" = -f ] && [ "$2" = "$POWERDOWNFLAG_FILE" ] || exit 92
exit 1
STUB
chmod +x "$WORK/killpower-rm-failure-bin/rm"

: >"$WORK/killpower"
: >"$WORK/stderr"
if env PATH="$WORK/killpower-rm-failure-bin:$PATH" \
  KILLPOWER_BLOCK="$KILLPOWER_BLOCK" POWERDOWNFLAG_FILE="$WORK/killpower" \
  bash -c '
    set -euf
    . "$KILLPOWER_BLOCK"
  ' >"$WORK/stdout" 2>"$WORK/stderr"; then
  RUN_RC=0
else
  RUN_RC=$?
fi
[ "$RUN_RC" -eq 1 ] && [ -e "$WORK/killpower" ] \
  && grep -Fqx -- "level=error msg=\"failed to clear the stale killpower flag; refusing to start\" path=$WORK/killpower" "$WORK/stderr" \
  && ok 'startup refuses when a stale killpower flag cannot be cleared' \
  || no 'stale killpower clear refusal' \
    "rc=$RUN_RC exists=$([ -e "$WORK/killpower" ] && printf yes || printf no) stderr=$(cat "$WORK/stderr")"
rm -f "$WORK/killpower"

TEMP_BLOCK=$(extract_range '^_clt_etc=' '^fi$' "$WORK/temp-cleanup-block.sh") || exit 1

cat >"$WORK/drive-temp-cleanup.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
. "$VALIDATE"
. "$GENERATE_CONFIG"
. "$SECRETS"
WD_RESTART_CAPTURE_PREFIX="$WORK/wd-restart"
STOP_CMD_CAPTURE_PREFIX="$WORK/stop-cmd"

rm() {
  printf '%s\n' "$@" >"$RM_ARGS"
  if [ "$MODE" = failure ]; then
    printf '%0600d' 0 | tr 0 x >&2
    return 1
  fi
}

. "$TEMP_BLOCK"
DRIVER
chmod +x "$WORK/drive-temp-cleanup.sh"

run_temp_cleanup() {
  : >"$WORK/rm-args"
  : >"$WORK/stderr"
  if env MODE="$1" TEMP_BLOCK="$TEMP_BLOCK" WORK="$WORK" RM_ARGS="$WORK/rm-args" \
    VALIDATE="$REPO_ROOT/validate.sh" GENERATE_CONFIG="$REPO_ROOT/generate-config.sh" \
    SECRETS="$REPO_ROOT/secrets.sh" \
    bash "$WORK/drive-temp-cleanup.sh" >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

run_temp_cleanup success
producer_prefixes=$(awk '
  FILENAME ~ /generate-config[.]sh$/ && $1 == "_stage_generated" {
    print "/etc/nut/" $2 ".tmp.*"
    next
  }
  FILENAME ~ /secrets[.]sh$/ && $1 == "readonly" && $2 ~ /^TLS_CERT_[A-Z_]+=\/etc\/nut\// {
    split($2, pair, "=")
    destination[pair[1]] = pair[2]
    next
  }
  FILENAME ~ /secrets[.]sh$/ && $1 == "_install_cert_working_copy" {
    name = $3
    gsub(/["$]/, "", name)
    if (!(name in destination)) {
      printf "harness error: unresolved TLS working-copy destination %s\n", name > "/dev/stderr"
      failed = 1
      next
    }
    print destination[name] ".tmp.*"
  }
  END { if (failed) exit 1 }
' "$REPO_ROOT/generate-config.sh" "$REPO_ROOT/secrets.sh" | sort -u) || exit 1
expected_args=$(
  {
    printf '%s\n' -f "$WORK/wd-restart.*" "$WORK/stop-cmd.*" /var/run/nut-secrets/'*.tmp.*'
    printf '%s\n' "$producer_prefixes"
  } | sort -u
)
actual_args=$(sort -u "$WORK/rm-args")
[ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/stderr" ] \
  && [ "$actual_args" = "$expected_args" ] \
  && ok 'startup submits every in-container staging producer namespace for reclamation without claiming unrelated /etc/nut names' \
  || no 'producer-derived temporary-file namespace reclamation' \
    "rc=$RUN_RC expected=$(printf '%s' "$expected_args" | tr '\n' ' ') actual=$(printf '%s' "$actual_args" | tr '\n' ' ') stderr=$(cat "$WORK/stderr")"

run_temp_cleanup failure
warning_count=$(grep -c 'crash-leaked temp file from a previous lifecycle; continuing' "$WORK/stderr" || true)
error_bytes=$(tr -cd x <"$WORK/stderr" | wc -c | tr -d ' ')
expected_error=$(printf '%0509d' 0 | tr 0 x)
[ "$RUN_RC" -eq 0 ] && [ "$warning_count" -eq 1 ] && [ "$error_bytes" -eq 509 ] \
  && grep -Fq -- "${expected_error}..." "$WORK/stderr" \
  && ok 'a cleanup failure stays warn-only and marks its error as truncated at 512 bytes' \
  || no 'bounded fail-soft temporary cleanup' \
    "rc=$RUN_RC warnings=$warning_count error_bytes=$error_bytes stderr=$(cat "$WORK/stderr")"

report
