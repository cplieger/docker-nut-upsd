#!/bin/sh
# Logs the forced-shutdown event when host poweroff is disabled. Invoked
# by upsmon's SHUTDOWNCMD when SHUTDOWN_ON_BATTERY_CRITICAL is not "true".
# A separate script, not an inlined printf: NUT's parseconf ends the quoted
# SHUTDOWNCMD argument at the first unescaped `"` (v2.8.5
# common/parseconf.c, quotecollect()), silently dropping the log line.

printf 'level=error msg="UPS forced shutdown (FSD) triggered; host will NOT be powered off" shutdown_on_battery_critical=%s\n' \
  "${SHUTDOWN_ON_BATTERY_CRITICAL:-unset}" >&2
exit 0
