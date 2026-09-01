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

verified_archives=0
failed_archives=""
for spec in \
  'libmodbus.tar.gz=LIBMODBUS_SHA256' \
  'netsnmp.tar.gz=NETSNMP_SHA256' \
  'nut.tar.gz=NUT_SHA256'; do
  archive=${spec%%=*}
  sha=${spec#*=}
  if awk -v archive="$archive" -v sha="$sha" '
    function assess() {
      if (index(instruction, archive) == 0) return
      found = 1
      checksum = index(instruction, "\"${" sha "}\" " archive " | sha256sum -c -")
      extraction = index(instruction, "tar xz --strip-components=1 -f " archive)
      if (checksum > 0 && extraction > checksum) valid = 1
    }
    /^RUN / {
      if (active) assess()
      instruction = $0
      active = 1
      if ($0 !~ /\\[[:space:]]*$/) {
        assess()
        active = 0
      }
      next
    }
    active {
      instruction = instruction "\n" $0
      if ($0 !~ /\\[[:space:]]*$/) {
        assess()
        active = 0
      }
    }
    END {
      if (active) assess()
      exit !(found && valid)
    }
  ' "$dockerfile"; then
    verified_archives=$((verified_archives + 1))
  else
    failed_archives="${failed_archives}${failed_archives:+, }$archive"
  fi
done
[ "$verified_archives" -eq 3 ] \
  && ok 'every source archive is checksum-verified before extraction' \
  || no 'source archive checksum ordering' "failed archives: ${failed_archives:-all}"

runtime_stage=$(awk '
  /^FROM .* AS runtime$/ { in_stage = 1; next }
  /^FROM / && in_stage { exit }
  in_stage { print }
' "$dockerfile")
pkg_upgrade_instruction=$(printf '%s\n' "$runtime_stage" | awk '
  function emit_if_upgrade() {
    if (index(instruction, "apk upgrade --no-cache") > 0) {
      print instruction
      found = 1
    }
  }
  /^RUN / {
    instruction = $0
    active = 1
    if ($0 !~ /\\[[:space:]]*$/) {
      emit_if_upgrade()
      active = 0
    }
    next
  }
  active {
    instruction = instruction "\n" $0
    if ($0 !~ /\\[[:space:]]*$/) {
      emit_if_upgrade()
      active = 0
    }
  }
  END {
    if (active && !found) emit_if_upgrade()
  }
')
if printf '%s\n' "$runtime_stage" | grep -Eq '^ARG PKG_REFRESH(=|$)' \
  && [ -n "$pkg_upgrade_instruction" ] \
  && printf '%s\n' "$pkg_upgrade_instruction" | grep -Fq '${PKG_REFRESH}'; then
  ok 'PKG_REFRESH is a cache-key input to the runtime package-upgrade instruction'
else
  no 'runtime package-refresh cache bust' "upgrade instruction: ${pkg_upgrade_instruction:-missing}"
fi

report
