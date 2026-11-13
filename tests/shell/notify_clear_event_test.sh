#!/usr/bin/env bash
# The five clear events NUT v2.8.5 raises for a flag the flag rules hold
# (clients/upsmon.h NOTIFY_NOTCAL to NOTIFY_NOTOVER), driven through the
# generated upsmon.conf: each must reach nut-notify.sh and log its own event=
# line at info, or its rule never resolves.
# Assigned config values and the probe fake are consumed by the extracted emitter.
# shellcheck disable=SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

NOTIFY="${NOTIFY:-$REPO_ROOT/nut-notify.sh}"
ENTRYPOINT="${ENTRYPOINT_GENERATOR:-$REPO_ROOT/generate-config.sh}"
load_function _emit_upsmon_conf

generated=$(
  UPS_NAME=ups
  API_PORT=3493
  _mon_user=local_upsmon
  _mon_password=secret
  SHUTDOWN_CMD=/usr/local/bin/nut-shutdown-noop.sh
  POWERDOWNFLAG_FILE=/var/run/nut-secrets/killpower
  POLLFREQ=5
  POLLFREQALERT=5
  DEADTIME=15
  FINALDELAY=5
  HOSTSYNC=15
  NOCOMMWARNTIME=300
  RBWARNTIME=43200
  upsd_probe_host() { printf '127.0.0.1\n'; }
  _emit_upsmon_conf
)
if ! printf '%s\n' "$generated" | grep -q '^NOTIFYCMD /usr/local/bin/nut-notify.sh$'; then
  printf 'harness error: the generated upsmon.conf has no NOTIFYCMD line\n' >&2
  exit 1
fi

# notify_through_config <event> -> the line nut-notify.sh logs for the event,
# or nothing when the generated NOTIFYFLAG row does not carry EXEC, which is
# when upsmon runs no NOTIFYCMD (clients/upsmon.c do_notify).
notify_through_config() {
  printf '%s\n' "$generated" | grep -Eq "^NOTIFYFLAG $1 ([A-Z]+\+)*EXEC(\+[A-Z]+)*$" || return 0
  NOTIFYTYPE="$1" UPSNAME='ups@127.0.0.1:3493' sh "$NOTIFY" "UPS ups clear" 2>&1
}

for _ev in NOTCAL NOTOFF NOTBYPASS NOTALARM NOTOVER; do
  _line=$(notify_through_config "$_ev")
  if printf '%s\n' "$_line" | grep -qx "level=info msg=\"UPS event\" event=\"$_ev\" ups=\"ups\" detail=\"UPS ups clear\""; then
    ok "$_ev reaches nut-notify.sh through the generated config and logs event=\"$_ev\" at info"
  else
    no "$_ev clear event line" "got: ${_line:-<no NOTIFYCMD run: the row lacks EXEC>}"
  fi
  if printf '%s\n' "$generated" | grep -qx "NOTIFYFLAG $_ev SYSLOG+EXEC"; then
    ok "$_ev keeps upstream's SYSLOG copy beside EXEC"
  else
    no "$_ev NOTIFYFLAG row" "want NOTIFYFLAG $_ev SYSLOG+EXEC, got: $(printf '%s\n' "$generated" | grep "^NOTIFYFLAG $_ev " || printf '<none>')"
  fi
done

report
