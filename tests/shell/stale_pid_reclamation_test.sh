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

TEMP_BLOCK=$(extract_range '^if ! _clt_err=' '^fi$' "$WORK/temp-cleanup-block.sh") || exit 1

cat >"$WORK/drive-temp-cleanup.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
WD_RESTART_CAPTURE_PREFIX="$WORK/wd-restart"
STOP_CMD_CAPTURE_PREFIX="$WORK/stop-cmd"
ADMIN_PASSWORD_FILE="$WORK/admin-password"
LOCAL_UPSMON_PASSWORD_FILE="$WORK/local-upsmon-password"
TLS_CERT_CACHE="$WORK/tls-cache"
TLS_CERT_RUNTIME="$WORK/tls-runtime"
TLS_CERT_MOUNTED_RUNTIME="$WORK/tls-mounted-runtime"

log_value() { printf '%s' "$1"; }
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
    bash "$WORK/drive-temp-cleanup.sh" >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

run_temp_cleanup success
expected_args=$(cat <<EOF
-f
$WORK/wd-restart.*
$WORK/stop-cmd.*
$WORK/admin-password.tmp.*
$WORK/local-upsmon-password.tmp.*
$WORK/tls-cache.tmp.*
$WORK/tls-runtime.tmp.*
$WORK/tls-mounted-runtime.tmp.*
/etc/nut/ups.conf.tmp.*
/etc/nut/upsd.conf.tmp.*
/etc/nut/upsd.users.tmp.*
/etc/nut/upsmon.conf.tmp.*
EOF
)
[ "$RUN_RC" -eq 0 ] && [ ! -s "$WORK/stderr" ] \
  && [ "$(cat "$WORK/rm-args")" = "$expected_args" ] \
  && ok 'startup submits every owned temporary-file namespace for reclamation' \
  || no 'temporary-file namespace reclamation' \
    "rc=$RUN_RC args=$(tr '\n' ' ' <"$WORK/rm-args") stderr=$(cat "$WORK/stderr")"

run_temp_cleanup failure
warning_count=$(grep -c 'crash-leaked temp file from a previous lifecycle; continuing' "$WORK/stderr" || true)
error_bytes=$(tr -cd x <"$WORK/stderr" | wc -c | tr -d ' ')
[ "$RUN_RC" -eq 0 ] && [ "$warning_count" -eq 1 ] && [ "$error_bytes" -eq 512 ] \
  && ok 'a cleanup failure stays warn-only and bounds the captured error to 512 bytes' \
  || no 'bounded fail-soft temporary cleanup' \
    "rc=$RUN_RC warnings=$warning_count error_bytes=$error_bytes stderr=$(cat "$WORK/stderr")"

RAW_PERMISSIONS_BLOCK=$(extract_range '^if ! _perm_err=$(' '^fi$' "$WORK/raw-permissions-block.sh") || exit 1
PERMISSIONS_BLOCK="$WORK/permissions-block.sh"
sed 's#/etc/nut#$NUT_ROOT#g' "$RAW_PERMISSIONS_BLOCK" >"$PERMISSIONS_BLOCK"

PERMISSIONS_ROOT="$WORK/etc-nut"
mkdir -p "$PERMISSIONS_ROOT"
: >"$PERMISSIONS_ROOT/upsd.conf"
: >"$PERMISSIONS_ROOT/ups.conf.user"
: >"$PERMISSIONS_ROOT/upsd.pem"
chmod 600 "$PERMISSIONS_ROOT/upsd.conf"
chmod 604 "$PERMISSIONS_ROOT/ups.conf.user"
chmod 606 "$PERMISSIONS_ROOT/upsd.pem"

mkdir -p "$WORK/permissions-bin"
cat >"$WORK/permissions-bin/chown" <<'STUB'
#!/bin/sh
[ "$1" = root:nut ] || exit 96
shift
printf '%s\n' "$@" >>"$CHOWN_PATHS"
STUB
chmod +x "$WORK/permissions-bin/chown"

: >"$WORK/chown-paths"
: >"$WORK/permissions-stderr"
if env PATH="$WORK/permissions-bin:$PATH" NUT_ROOT="$PERMISSIONS_ROOT" \
  TLS_CERT_MOUNT=/etc/nut/upsd.pem CHOWN_PATHS="$WORK/chown-paths" \
  PERMISSIONS_BLOCK="$PERMISSIONS_BLOCK" bash -c '
    set -euf
    log_value() { printf "%s" "$1"; }
    . "$PERMISSIONS_BLOCK"
  ' >"$WORK/permissions-stdout" 2>"$WORK/permissions-stderr"; then
  RUN_RC=0
else
  RUN_RC=$?
fi

[ "$RUN_RC" -eq 0 ] \
  && [ "$(stat -c %a "$PERMISSIONS_ROOT")" = 750 ] \
  && [ "$(stat -c %a "$PERMISSIONS_ROOT/upsd.conf")" = 640 ] \
  && [ "$(stat -c %a "$PERMISSIONS_ROOT/ups.conf.user")" = 604 ] \
  && [ "$(stat -c %a "$PERMISSIONS_ROOT/upsd.pem")" = 606 ] \
  && grep -Fqx "$PERMISSIONS_ROOT/upsd.conf" "$WORK/chown-paths" \
  && ! grep -Fqx "$PERMISSIONS_ROOT/ups.conf.user" "$WORK/chown-paths" \
  && ! grep -Fqx "$PERMISSIONS_ROOT/upsd.pem" "$WORK/chown-paths" \
  && ok 'permissions sweep normalizes generated configs without mutating operator mounts' \
  || no 'generated-config and operator-mount permissions' "rc=$RUN_RC chown=$(tr '\n' ' ' <"$WORK/chown-paths") modes=$(stat -c %a "$PERMISSIONS_ROOT"/*) stderr=$(cat "$WORK/permissions-stderr")"

report
