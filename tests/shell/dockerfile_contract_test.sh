#!/usr/bin/env bash
# The default Docker target must consume the smoke stage's success marker;
# otherwise BuildKit can prune that stage and ship an untested image.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

dockerfile="$REPO_ROOT/Dockerfile"
test_stage=$(awk '
  /^FROM .* AS test$/ { in_stage = 1; next }
  /^FROM / && in_stage { exit }
  in_stage { print }
' "$dockerfile")
final_stage=$(awk '
  /^FROM .* AS final$/ { in_stage = 1; next }
  /^FROM / && in_stage { exit }
  in_stage { print }
' "$dockerfile")
last_stage=$(awk '/^FROM / { stage = $NF } END { print stage }' "$dockerfile")

if [ -n "$test_stage" ] \
  && [ -n "$final_stage" ] \
  && printf '%s\n' "$test_stage" \
    | grep -Eq '^[[:space:]]*RUN[[:space:]].*smoke\.sh.*&&[[:space:]]*touch[[:space:]]+/tests-passed' \
  && printf '%s\n' "$final_stage" \
    | grep -Eq '^[[:space:]]*COPY[[:space:]]+--from=test[[:space:]]+/tests-passed[[:space:]]+/tests-passed' \
  && [ "$last_stage" = final ]; then
  ok 'default Docker target depends on a successful smoke-test stage'
else
  no 'Dockerfile smoke-stage dependency' "last stage=${last_stage:-none}"
fi

report
