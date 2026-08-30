#!/usr/bin/env bash
# POWERDOWNFLAG is written by the generator and consumed by three standalone
# lifecycle paths; all four must name the same file. lifecycle.sh owns the path
# as POWERDOWNFLAG_FILE and the three sourced sites read that constant, so this
# reads the constant's VALUE and the one deliberate literal (nut-shutdown.sh is
# exec'd by upsmon and sources nothing) and asserts they agree.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The owner of the path. Sourcing lifecycle.sh at top level only defines
# constants and functions.
# shellcheck source=/dev/null
. "$REPO_ROOT/lifecycle.sh"

# The exec-boundary copy: nut-shutdown.sh runs as upsmon's SHUTDOWNCMD, sources
# nothing, and therefore keeps the literal. A file-wide grep has been measured
# passing on a drifted constant, so the extraction is scoped to the `rm` line
# that clears the flag.
shutdown_cleanup=$(awk '
  $1 == "if" && $2 == "rm" && $3 == "-f" {
    path = $4
    sub(/;$/, "", path)
    print path
    exit
  }
' "$REPO_ROOT/nut-shutdown.sh")

# The three sourced sites must name the constant rather than respell the path.
generated=$(awk '$1 == "POWERDOWNFLAG" { print $2; exit }' "$REPO_ROOT/generate-config.sh")
boot_cleanup=$(awk '
  /clearing stale killpower flag/ {
    getline
    if ($1 == "rm" && $2 == "-f") print $3
    exit
  }
' "$REPO_ROOT/entrypoint.sh")
watchdog=$(awk '
  /SHUTDOWN_ON_BATTERY_CRITICAL/ && /-e/ {
    for (i = 1; i <= NF; i++) if ($i == "-e") print $(i + 1)
    exit
  }
' "$REPO_ROOT/lifecycle.sh")

# Fatal preconditions: a missing site extracts as empty, and four empty values
# compare equal, which would turn every case below green.
if [ -z "${POWERDOWNFLAG_FILE:-}" ] || [ -z "$generated" ] \
  || [ -z "$boot_cleanup" ] || [ -z "$watchdog" ] || [ -z "$shutdown_cleanup" ]; then
  printf 'harness error: could not extract all POWERDOWNFLAG consumers (constant=%s generated=%s boot=%s watchdog=%s shutdown=%s)\n' \
    "${POWERDOWNFLAG_FILE:-}" "$generated" "$boot_cleanup" "$watchdog" "$shutdown_cleanup" >&2
  exit 1
fi

# shellcheck disable=SC2016  # the expected spellings are literal, never expanded
[ "$generated" = '$POWERDOWNFLAG_FILE' ] \
  && [ "$boot_cleanup" = '"$POWERDOWNFLAG_FILE"' ] \
  && [ "$watchdog" = '"$POWERDOWNFLAG_FILE"' ] \
  && ok 'the generated directive, the boot-time clear and the watchdog stand-down all read $POWERDOWNFLAG_FILE' \
  || no 'POWERDOWNFLAG constant is the single owner' \
    "generated=$generated boot=$boot_cleanup watchdog=$watchdog"

[ "$shutdown_cleanup" = "$POWERDOWNFLAG_FILE" ] \
  && ok "nut-shutdown.sh's literal ($shutdown_cleanup) equals the constant it cannot source" \
  || no 'POWERDOWNFLAG exec-boundary literal' \
    "constant=$POWERDOWNFLAG_FILE shutdown=$shutdown_cleanup"

report
