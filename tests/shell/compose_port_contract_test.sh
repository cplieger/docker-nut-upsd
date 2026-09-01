#!/usr/bin/env bash
# The shipped compose example's published port against the image's own API_PORT.
#
# WHY THIS IS A CONTRACT: the example sets no API_PORT, so its "3493:3493"
# mapping is a second, silent copy of the entrypoint's default -- the port upsd
# is actually told to listen on. Move the default and the example publishes a
# host port with nothing behind it: the container still starts, still reports
# healthy on its own loopback probe, and every networked NUT client of anyone
# who pasted the example fails to connect. Same shape as the container_name
# coupling alert_container_selector_contract_test.sh pins.
#
# The example setting no API_PORT is part of the contract, so an example that
# starts setting one goes red here on purpose: that changes which side decides
# the port, and the decision should be made rather than inherited.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

compose="$REPO_ROOT/compose.yaml"
entrypoint="$REPO_ROOT/entrypoint.sh"

mapping=$(grep -E '^[[:space:]]*-[[:space:]]*"[0-9]+:[0-9]+"[[:space:]]*$' "$compose" | tr -d ' "-')
if [ "$(printf '%s\n' "$mapping" | grep -c .)" -ne 1 ]; then
  printf 'harness error: expected exactly one numeric host:container mapping in compose.yaml\n' >&2
  exit 1
fi
container_port=${mapping#*:}

default_port=$(sed -n 's/^: "${API_PORT:=\([0-9][0-9]*\)}"$/\1/p' "$entrypoint")
if [ -z "$default_port" ]; then
  printf 'harness error: no numeric API_PORT default found in entrypoint.sh\n' >&2
  exit 1
fi

explicit=$(grep -Ec '^[[:space:]]*API_PORT:' "$compose" || :)
if [ "$container_port" = "$default_port" ] && [ "$explicit" -eq 0 ]; then
  ok "compose publishes the image's own API_PORT default ($default_port) and sets no API_PORT of its own"
else
  no 'compose/API_PORT contract' \
    "compose container port=$container_port; entrypoint API_PORT default=$default_port; explicit API_PORT rows=$explicit"
fi

report
