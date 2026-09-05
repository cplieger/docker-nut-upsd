#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

SUBJECT=$ENTRYPOINT
ENTRYPOINT="$SUBJECT"
# End-anchored on the next CODE line, not on a comment: a sed range whose second address
# never matches prints to EOF, and an over-extraction would source the rest of the boot
# path (resolve_tls_cert, generate_all_configs, the daemon starts) while still satisfying
# the isolation guard below. The anchor line itself is stripped, because running it here
# would normalize an unset COMMS_WATCHDOG under `set -u`.
raw_block=$(extract_range '^export SHUTDOWN_ON_BATTERY_CRITICAL$' '^COMMS_WATCHDOG=\$(normalize_bool' "$WORK/shutdown-selection-raw.sh") || exit 1
if ! tail -n 1 "$raw_block" | grep -Fq 'COMMS_WATCHDOG=$(normalize_bool'; then
  printf 'harness error: the shutdown-selection range did not end at the COMMS_WATCHDOG normalization\n' >&2
  exit 1
fi
block="$WORK/shutdown-selection.sh"
sed -e '$d' -e 's#if \[ ! -S /run/dbus/system_bus_socket \]; then#if false; then#' "$raw_block" >"$block"

if [ "$(grep -Fc 'if false; then' "$block")" -ne 1 ] \
  || grep -Fq 'if [ ! -S /run/dbus/system_bus_socket ]; then' "$block" \
  || grep -Fq 'normalize_bool COMMS_WATCHDOG' "$block" \
  || grep -Fq 'generate_all_configs' "$block"; then
  printf 'harness error: could not isolate the shutdown-selection block\n' >&2
  exit 1
fi

ENTRYPOINT="$REPO_ROOT/validate.sh"
load_function normalize_bool

select_shutdown_cmd() (
  SHUTDOWN_ON_BATTERY_CRITICAL=$1
  SHUTDOWN_CMD=
  # shellcheck disable=SC1090  # extracted production block
  . "$block" 2>/dev/null
  printf '%s|%s\n' "$SHUTDOWN_ON_BATTERY_CRITICAL" "$SHUTDOWN_CMD"
)

while IFS='|' read -r spelling normalized helper; do
  got=$(select_shutdown_cmd "$spelling")
  want="$normalized|/usr/local/bin/$helper"
  if [ "$got" = "$want" ]; then
    ok "SHUTDOWN_ON_BATTERY_CRITICAL=$spelling selects $helper"
  else
    no "SHUTDOWN_ON_BATTERY_CRITICAL=$spelling selection" "got=$got want=$want"
  fi
# Three rows, not the full spelling table: validation_dispatch_test.sh:178-196 pins
# normalize_bool's canonical-output table, and a third home for it would fail two suites
# for one fact. What is proved here is the COMPOSITION — one non-canonical spelling on
# each branch (also the only thing that catches a compare-before-normalize reorder), plus
# the canonical true.
done <<'CASES'
On|true|nut-shutdown.sh
true|true|nut-shutdown.sh
Off|false|nut-shutdown-noop.sh
CASES

report
