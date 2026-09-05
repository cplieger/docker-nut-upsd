#!/usr/bin/env bash
# The default Docker target must consume the smoke stage's success marker;
# otherwise BuildKit can prune that stage and ship an untested image.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

dockerfile="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"
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
if [ "$verified_archives" -eq 3 ]; then
  ok 'every source archive is checksum-verified before extraction'
else
  no 'source archive checksum ordering' "failed archives: ${failed_archives:-all}"
fi

publisher_verified=0
failed_publishers=""
for spec in \
  'netsnmp.tar.gz=NETSNMP_SHA256' \
  'nut.tar.gz=NUT_SHA256'; do
  archive=${spec%%=*}
  sha=${spec#*=}
  if awk -v archive="$archive" -v sha="$sha" '
    function assess(    lines, count, i, offset, line, signature, checksum, extraction) {
      if (index(instruction, archive) == 0) return
      found = 1
      count = split(instruction, lines, "\n")
      offset = 0
      for (i = 1; i <= count; i++) {
        line = lines[i]
        if (index(line, "gpgv ") > 0 && index(line, archive) > 0) signature = offset + index(line, "gpgv ")
        if (index(line, "\"${" sha "}\" " archive) > 0 && index(line, "sha256sum -c -") > 0) checksum = offset + index(line, "sha256sum -c -")
        if (index(line, "tar xz --strip-components=1 -f " archive) > 0) extraction = offset + index(line, "tar xz")
        offset += length(line) + 1
      }
      if (signature > 0 && checksum > 0 && extraction > signature && extraction > checksum) valid = 1
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
    publisher_verified=$((publisher_verified + 1))
  else
    failed_publishers="${failed_publishers}${failed_publishers:+, }$archive"
  fi
done
if [ "$publisher_verified" -eq 2 ]; then
  ok 'signed source archives are publisher- and checksum-verified before extraction'
else
  no 'source archive publisher verification ordering' "failed archives: ${failed_publishers:-all}"
fi

source_components=$(awk '
  /^# renovate: datasource=github-(releases|tags) depName=/ { count++ }
  END { print count + 0 }
' "$dockerfile")
sbom_components=$(awk '
  /RUN cat > \/out\/nut-upsd\.cdx\.json <<EOF/ { in_sbom = 1; next }
  in_sbom && /^EOF$/ { exit }
  in_sbom && /"bom-ref":/ { count++ }
  END { print count + 0 }
' "$dockerfile")
sbom_identity_ok=true
failed_component=""
for spec in \
  'networkupstools/nut|nut|cpe:2.3:a:networkupstools:nut:' \
  'stephane/libmodbus|libmodbus|cpe:2.3:a:libmodbus:libmodbus:' \
  'net-snmp/net-snmp|net-snmp|cpe:2.3:a:net-snmp:net-snmp:'; do
  dep=${spec%%|*}
  rest=${spec#*|}
  name=${rest%%|*}
  cpe=${rest#*|}
  arg=$(awk -v dep="$dep" '
    /^# renovate:/ && index($0, "depName=" dep) { found = 1; next }
    found && /^ARG [A-Z0-9_]+_VERSION=/ {
      line = $0
      sub(/^ARG /, "", line)
      sub(/=.*/, "", line)
      print line
      exit
    }
  ' "$dockerfile")
  component=$(awk -v dep="$dep" '
    index($0, "\"bom-ref\": \"pkg:github/" dep "@") { found = 1 }
    found { print }
    found && /^    }/ { exit }
  ' "$dockerfile")
  arg_ref="\${$arg}"
  version_ref="\${$arg#v}"
  if [ -z "$arg" ] || [ -z "$component" ] \
    || ! grep -Fq "\"bom-ref\": \"pkg:github/$dep@$arg_ref\"" <<<"$component" \
    || ! grep -Fq "\"name\": \"$name\"" <<<"$component" \
    || ! grep -Fq "\"version\": \"$version_ref\"" <<<"$component" \
    || ! grep -Fq "\"purl\": \"pkg:github/$dep@$arg_ref\"" <<<"$component" \
    || ! grep -Fq "\"cpe\": \"$cpe$version_ref:*:*:*:*:*:*:*\"" <<<"$component"; then
    sbom_identity_ok=false
    failed_component="${failed_component}${failed_component:+, }$name"
  fi
done
if [ "$source_components" -eq "$sbom_components" ] && [ "$sbom_identity_ok" = true ]; then
  ok 'source-built component metadata matches its source pin'
else
  no 'source-built component metadata' "source pins=$source_components components=$sbom_components mismatched=${failed_component:-none}"
fi

checked_in_patches=$(find "$REPO_ROOT/patches" -maxdepth 1 -type f -name '*.patch' -exec basename {} \; | sort)
copied_patches=$(awk '
  /^COPY patches\// { in_copy = 1 }
  in_copy {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^patches\/.*\.patch$/) {
        sub(/^patches\//, "", $i)
        print $i
      }
    }
    if ($0 ~ /\/build\/patches\/[[:space:]]*$/) exit
  }
' "$dockerfile" | sort)
applied_patches=$(awk '
  /patch -p1 --fuzz=0 -i \/build\/patches\// {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^\/build\/patches\/.*\.patch$/) {
        sub(/^\/build\/patches\//, "", $i)
        print $i
      }
    }
  }
' "$dockerfile" | sort)
if [ -n "$checked_in_patches" ] \
  && [ "$checked_in_patches" = "$copied_patches" ] \
  && [ "$checked_in_patches" = "$applied_patches" ]; then
  ok 'every checked-in patch is copied and applied exactly once'
else
  no 'checked-in patch coverage' "files=[$(tr '\n' ' ' <<<"$checked_in_patches")] copied=[$(tr '\n' ' ' <<<"$copied_patches")] applied=[$(tr '\n' ' ' <<<"$applied_patches")]"
fi

runtime_stage=$(awk '
  /^FROM .* AS runtime$/ { in_stage = 1; next }
  /^FROM / && in_stage { exit }
  in_stage { print }
' "$dockerfile")

exposed_port=$(awk '
  $1 == "EXPOSE" && $2 ~ /^[0-9][0-9]*$/ { print $2 }
' <<<"$runtime_stage")
entrypoint_port=$(sed -n \
  's/^: "${API_PORT:=\([0-9][0-9]*\)}"$/\1/p' \
  "$REPO_ROOT/entrypoint.sh")

if [ "$(printf '%s\n' "$exposed_port" | grep -c .)" -eq 1 ] \
  && [ "$(printf '%s\n' "$entrypoint_port" | grep -c .)" -eq 1 ] \
  && [ "$exposed_port" = "$entrypoint_port" ]; then
  ok "runtime image exposes its API_PORT default ($entrypoint_port)"
else
  no 'EXPOSE/API_PORT contract' \
    "EXPOSE=${exposed_port:-missing} API_PORT default=${entrypoint_port:-missing}"
fi

runtime_env=$(grep -v '^[[:space:]]*#' <<<"$runtime_stage")
if grep -Eq '^(ENV[[:space:]]+|[[:space:]]+)NUT_DEBUG_SYSLOG=stderr([[:space:]]*\\)?[[:space:]]*$' <<<"$runtime_env"; then
  ok 'runtime image preserves daemon stderr logging'
else
  no 'runtime daemon stderr logging' 'NUT_DEBUG_SYSLOG=stderr is absent from the runtime stage'
fi

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
# The fixed-string pattern below is the literal Dockerfile interpolation.
# shellcheck disable=SC2016
if printf '%s\n' "$runtime_stage" | grep -Eq '^ARG PKG_REFRESH(=|$)' \
  && [ -n "$pkg_upgrade_instruction" ] \
  && printf '%s\n' "$pkg_upgrade_instruction" | grep -Fq '${PKG_REFRESH}'; then
  ok 'PKG_REFRESH is a cache-key input to the runtime package-upgrade instruction'
else
  no 'runtime package-refresh cache bust' "upgrade instruction: ${pkg_upgrade_instruction:-missing}"
fi

if grep -Eq -- '^[[:space:]]*--with-user=nut[[:space:]]+--with-group=nut[[:space:]]*\\?$' "$dockerfile"; then
  ok 'NUT is configured to drop to the nut user and group'
else
  no 'NUT privilege-drop configure flags' \
    'the configure invocation no longer carries --with-user=nut --with-group=nut; upsd, upsmon and the driver all take their unprivileged identity from it'
fi

report
