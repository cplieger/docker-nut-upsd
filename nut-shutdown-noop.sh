#!/bin/sh
# Logs the forced-shutdown event when host poweroff is disabled. Invoked
# by upsmon's SHUTDOWNCMD when SHUTDOWN_ON_BATTERY_CRITICAL is not "true".
# Exists as a separate script because inlining a multi-quoted printf into
# SHUTDOWNCMD is parsed incorrectly by NUT's parseconf (unescaped `"`
# terminates the quoted argument), which silently drops the FSD log line.

printf 'level=error msg="UPS forced shutdown (FSD) triggered; SHUTDOWN_ON_BATTERY_CRITICAL=%s, host will NOT be powered off"\n' \
  "${SHUTDOWN_ON_BATTERY_CRITICAL:-unset}" >&2
exit 0
