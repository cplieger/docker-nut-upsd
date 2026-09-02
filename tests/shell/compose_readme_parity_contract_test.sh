#!/usr/bin/env bash
# The README's copyable compose block against the shipped compose.yaml.
#
# WHY THIS IS A CONTRACT: the example ships twice, and all three existing
# compose contract tests read compose.yaml alone
# (alert_container_selector_contract_test.sh holds every rule's
# {container="..."} selector to it, compose_port_contract_test.sh ties its one
# numeric mapping to entrypoint.sh's API_PORT default,
# compose_usb_hotplug_contract_test.sh counts the live bind and the cgroup
# rule). So a compose.yaml-only edit leaves the suite green while the README's
# Quick start -- the copy a reader is likeliest to paste -- creates a
# container whose name the README's own Alerting section no longer selects.
#
# Comments are stripped on both sides on purpose: the two copies word their
# USB-hotplug comment differently, each correct in its own context. Only the
# active lines are the contract.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

readme="$REPO_ROOT/README.md"
compose="$REPO_ROOT/compose.yaml"

block=$(awk '
  /^```yaml$/ && !seen { seen = 1; inblock = 1; next }
  inblock && /^```$/   { inblock = 0; next }
  inblock              { print }
' "$readme")
if [ -z "$block" ]; then
  printf 'harness error: no fenced yaml block found in README.md\n' >&2
  exit 1
fi

# Active lines only: drop trailing comments, whole-line comments and blanks.
# Safe as a naive strip because no value in either copy contains a '#'.
normalize() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'; }

readme_active=$(printf '%s\n' "$block" | normalize)
compose_active=$(normalize <"$compose")
n=$(printf '%s\n' "$compose_active" | grep -c .)

if [ "$readme_active" = "$compose_active" ]; then
  ok "the README compose block and compose.yaml agree on all $n active lines"
else
  first=$(diff <(printf '%s\n' "$compose_active") <(printf '%s\n' "$readme_active") \
    | grep -m2 '^[<>]' | tr '\n' ' ')
  no 'README/compose example parity' "first divergence (< compose, > README): $first"
fi

report
