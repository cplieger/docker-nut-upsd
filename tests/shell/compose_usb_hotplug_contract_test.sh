#!/usr/bin/env bash
# compose.yaml's USB hotplug pair: the live /dev/bus/usb bind plus the USB-major
# cgroup rule.
#
# WHY THIS IS A CONTRACT: the comms watchdog can only re-home the driver onto a
# re-enumerated device node if that node appears inside the container, which the
# LIVE bind provides and a static devices: mapping does not, and only if the new
# minor is accessible, which the major-wide cgroup rule provides. Drop either
# line, narrow the rule, or swap the bind for devices:, and the published example
# still starts, still passes every other test, and silently stops surviving a USB
# re-enumeration -- the failure the watchdog exists to close.
#
# Only ACTIVE YAML lines count here: both patterns are anchored at line start and
# end, so the prose in compose.yaml's own comment (which states the same
# requirement) cannot satisfy the assertion.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

compose="$REPO_ROOT/compose.yaml"
live_bind_count=$(grep -Ec '^[[:space:]]*-[[:space:]]*"/dev/bus/usb:/dev/bus/usb"[[:space:]]*$' "$compose")
cgroup_rule_count=$(grep -Ec '^[[:space:]]*-[[:space:]]*"c 189:\* rmw"[[:space:]]*$' "$compose")
devices_key_count=$(grep -Ec '^[[:space:]]+devices:[[:space:]]*$' "$compose")

if [ "$live_bind_count" -eq 1 ] \
  && [ "$cgroup_rule_count" -eq 1 ] \
  && [ "$devices_key_count" -eq 0 ]; then
  ok 'compose keeps the live USB bus bind and major-wide cgroup rule without a static devices mapping'
else
  no 'USB hotplug compose contract' \
    "live binds=$live_bind_count cgroup rules=$cgroup_rule_count devices keys=$devices_key_count"
fi

report
