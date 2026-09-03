#!/usr/bin/env bash
# Holds UPSContainerError's anchored prefix and event exclusion against the
# structured records emitted by the shipped shell.
# shellcheck disable=SC2016  # backticks below are literal LogQL delimiters.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"

ALERTS="${ALERTS:-$REPO_ROOT/alerts/logql.yaml}"
SHELL_ROOT="${SHELL_ROOT:-$REPO_ROOT}"
RULE=$(awk '
  /- alert: UPSContainerError$/ { inrule = 1; next }
  inrule && /- alert: / { exit }
  inrule { print }
' "$ALERTS")
PREFIX_PATTERN=$(printf '%s\n' "$RULE" | sed -n 's/.*|~ `\([^`]*\)`.*/\1/p' | head -1)
EXCLUSION=$(printf '%s\n' "$RULE" | sed -n 's/.*!= `\([^`]*\)`.*/\1/p' | head -1)
case "$PREFIX_PATTERN|$EXCLUSION" in
  '^level=error |msg="UPS event"') ;;
  *)
    printf 'harness error: unexpected UPSContainerError matcher: prefix=%s exclusion=%s\n' \
      "${PREFIX_PATTERN:-<empty>}" "${EXCLUSION:-<empty>}" >&2
    exit 1
    ;;
esac

exclusion_owners=$(grep -oHF -- "$EXCLUSION" "$SHELL_ROOT"/*.sh || true)
expected_exclusion_owner="$SHELL_ROOT/nut-notify.sh:$EXCLUSION"
if [ "$exclusion_owners" = "$expected_exclusion_owner" ]; then
  ok 'only nut-notify owns the UPSContainerError event-exclusion literal'
else
  no 'UPSContainerError event-exclusion owner' \
    "expected exactly one hit in nut-notify.sh, got: $exclusion_owners"
fi

PREFIX=${PREFIX_PATTERN#^}
bad=""
seen=0
while IFS= read -r record; do
  source_line=${record#*:*:}
  format=${source_line#*printf \'}
  format=${format%%\'*}
  seen=$((seen + 1))
  case "$format" in
    "$PREFIX"*) ;;
    *) bad="$bad ${record%%:*}:${record#*:}" ;;
  esac
done < <(grep -nHE "printf '[^']*level=error" "$SHELL_ROOT"/*.sh)

if [ "$seen" -gt 0 ] && [ -z "$bad" ]; then
  ok "every literal structured error format opens with the prefix UPSContainerError reads from alerts/logql.yaml"
else
  no 'UPSContainerError anchored prefix' "checked=$seen formats; nonmatching:$bad"
fi

notify_line=$(NOTIFYTYPE=FSD UPSNAME=ups sh "$REPO_ROOT/nut-notify.sh" 'forced shutdown' 2>&1)
container_line=$(SHUTDOWN_ON_BATTERY_CRITICAL=false sh "$REPO_ROOT/nut-shutdown-noop.sh" 2>&1)
if printf '%s\n' "$notify_line" | grep -Eq -- "$PREFIX_PATTERN" \
  && printf '%s\n' "$notify_line" | grep -Fq -- "$EXCLUSION" \
  && printf '%s\n' "$container_line" | grep -Eq -- "$PREFIX_PATTERN" \
  && ! printf '%s\n' "$container_line" | grep -Fq -- "$EXCLUSION"; then
  ok 'the forced-shutdown event is excluded while a container-owned error remains matched'
else
  no 'UPSContainerError event exclusion' "notify=[$notify_line] container=[$container_line]"
fi

HOSTSYNC_RULE=$(awk '
  /^[[:space:]]*- alert: UPSHostSyncExpired$/ { inrule = 1; next }
  inrule && /^[[:space:]]*- alert:/ { exit }
  inrule { print }
' "$ALERTS")
HOSTSYNC_PATTERN=$(printf '%s\n' "$HOSTSYNC_RULE" \
  | sed -n 's/.*|~ `\([^`]*\)` \[[^]]*\].*/\1/p')
if [ "$(printf '%s\n' "$HOSTSYNC_PATTERN" | grep -c .)" -ne 1 ]; then
  printf 'harness error: UPSHostSyncExpired must carry one regex line filter\n' >&2
  exit 1
fi

hostsync_bare='Host sync timer expired, forcing shutdown'
hostsync_structured='level=warn msg="UPS event" event="ALARM" ups="ups" detail="Host sync timer expired, forcing shutdown"'
if printf '%s\n' "$hostsync_bare" | grep -Eq "$HOSTSYNC_PATTERN" \
  && ! printf '%s\n' "$hostsync_structured" | grep -Eq "$HOSTSYNC_PATTERN"; then
  ok 'UPSHostSyncExpired accepts the bare upsmon record and rejects the phrase inside a structured detail field'
else
  no 'UPSHostSyncExpired raw-record boundary' \
    "pattern=$HOSTSYNC_PATTERN"
fi

report
