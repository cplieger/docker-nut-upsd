#!/bin/sh
# generate-config.sh — NUT config file generation helpers.
# Sourced by entrypoint.sh; not executed directly.

# ---------------------------------------------------------------------------
# Config generation helpers
# ---------------------------------------------------------------------------
# If /etc/nut/<name>.user exists, copy it over /etc/nut/<name> and return 0
# (caller skips generation). Return 1 otherwise.
use_user_override() {
  _uo_probed="${_uo_probed:-} $1"
  if [ ! -e "/etc/nut/$1.user" ]; then
    # A dangling symlink (e.g. a mounted directory of symlinks with a broken
    # target) fails -e and would silently drop the operator's override; name
    # it before falling back to generation (warn-only: mirrors the fail-loud
    # posture of the non-regular-file gate below without changing behavior).
    if [ -L "/etc/nut/$1.user" ]; then
      printf 'level=warn msg="mounted override path is a dangling symlink; ignoring it and generating the file" file=%s.user\n' "$1" >&2
    fi
    return 1
  fi
  # Refuse a non-regular mount (directory, FIFO, device node) up front: cp of
  # a writer-less FIFO would block forever and hang config generation with no
  # log line. Mirrors the resolve_tls_cert gate on /etc/nut/upsd.pem.
  if [ ! -f "/etc/nut/$1.user" ]; then
    printf 'level=error msg="mounted override path is not a regular file; aborting" file=%s.user\n' "$1" >&2
    exit 1
  fi
  # Staged install through _replace_file (password.sh; sourced alongside this
  # module before any generator runs): plain cp treats an existing directory
  # at the destination (e.g. an accidentally auto-created bind-mount target)
  # as a container — it writes /etc/nut/<name>/<name>.user, returns success,
  # and the override is logged as applied while /etc/nut/<name> is still a
  # directory, so startup fails later with a misleading daemon/config error.
  _uo_dst="/etc/nut/$1"
  _uo_tmp=$(mktemp "${_uo_dst}.tmp.XXXXXX" 2>/dev/null) || {
    printf 'level=error msg="failed to create mounted-override staging file; aborting" file=%s.user\n' "$1" >&2
    exit 1
  }
  if ! cat "${_uo_dst}.user" >"$_uo_tmp" \
    || ! _replace_file "$_uo_tmp" "$_uo_dst"; then
    rm -f "$_uo_tmp"
    printf 'level=error msg="failed to apply mounted override; aborting" file=%s.user\n' "$1" >&2
    exit 1
  fi
  printf 'level=info msg="using mounted %s.user"\n' "$1" >&2 || :
}

# --- ups.conf — skipped if user-mounted ---
generate_ups_conf() {
  use_user_override ups.conf && return 0
  cat >/etc/nut/ups.conf <<UPSEOF
[$UPS_NAME]
    desc = "$UPS_DESC"
    driver = $UPS_DRIVER
    port = $UPS_PORT
UPSEOF

  # pollonly is registered by usbhid-ups alone (drivers/usbhid-ups.c in the
  # pinned NUT tree); any other driver exits during ups.conf parsing on a flag
  # absent from its vartab (drivers/main.c, storeval).
  if [ "$UPS_DRIVER" = "usbhid-ups" ]; then
    printf '    pollonly\n' >>/etc/nut/ups.conf
  fi

  # Battery overrides (ignorelb tells NUT to use our thresholds instead of
  # hardware).
  _batt_overrides="${LOWBATT_PERCENT:-}${LOWBATT_RUNTIME:-}"
  if [ -n "$_batt_overrides" ]; then
    printf '    ignorelb\n' >>/etc/nut/ups.conf
  fi

  # Battery override directives — explicit per-variable to avoid eval.
  [ -n "${LOWBATT_PERCENT:-}" ] \
    && printf '    override.battery.charge.low = %s\n' "$LOWBATT_PERCENT" >>/etc/nut/ups.conf
  [ -n "${LOWBATT_RUNTIME:-}" ] \
    && printf '    override.battery.runtime.low = %s\n' "$LOWBATT_RUNTIME" >>/etc/nut/ups.conf

  if [ -n "$_batt_overrides" ]; then
    printf 'level=info msg="battery thresholds overridden (ignorelb active)" low_pct=%s low_rt=%s\n' \
      "${LOWBATT_PERCENT:-unset}" "${LOWBATT_RUNTIME:-unset}" >&2
  else
    printf 'level=info msg="no battery threshold overrides; using UPS hardware defaults"\n' >&2
  fi
}

# --- upsd.conf — skipped if user-mounted ---
# STARTTLS (API_TLS=true, the default): CERTFILE names the cert+key PEM
# resolved by resolve_tls_cert (password.sh), and DISABLE_WEAK_SSL true pins
# the handshake to TLS 1.2+ (upsd otherwise accepts TLS 1.0 and logs a
# warning). STARTTLS is opportunistic in the NUT protocol — clients that
# never request it keep talking cleartext — so enabling it breaks no legacy
# client. With API_TLS=false the output stays byte-identical to the
# pre-TLS-feature config.
generate_upsd_conf() {
  use_user_override upsd.conf && return 0
  cat >/etc/nut/upsd.conf <<UPSDEOF
LISTEN $API_ADDRESS $API_PORT
UPSDEOF
  if [ "$API_TLS" = "true" ]; then
    cat >>/etc/nut/upsd.conf <<UPSDEOF
CERTFILE $TLS_CERT_PATH
DISABLE_WEAK_SSL true
UPSDEOF
  fi
}

# ---------------------------------------------------------------------------
# Credential topology: which account links upsd.users to upsmon.conf
# ---------------------------------------------------------------------------
# The bundled upsmon is the only generated `upsmon primary`, and it holds that
# slot through the reserved [local_upsmon] account (secret auto-generated and
# cached root-only by password.sh); the network-facing [$API_USER] is the
# secondary. validate.sh owns the reserved-name refusal. The internal
# credential is a contract between the two GENERATED files, so when exactly one
# of them is mounted the generated half uses the API pair instead — the only
# credential a mounted half written against the documented env vars can be
# assumed to know. The two level=warn records below name which half fell back.
local_upsmon_credential_active() {
  [ ! -e /etc/nut/upsd.users.user ] && [ ! -e /etc/nut/upsmon.conf.user ]
}

# --- upsd.users — skipped if user-mounted ---
generate_upsd_users() {
  use_user_override upsd.users && return 0
  cat >/etc/nut/upsd.users <<USERSEOF
[admin]
    password = "$ADMIN_PASSWORD"
    actions = set
    actions = fsd
    instcmds = all
USERSEOF
  if local_upsmon_credential_active; then
    cat >>/etc/nut/upsd.users <<USERSEOF

[local_upsmon]
    password = "$LOCAL_UPSMON_PASSWORD"
    upsmon primary

[$API_USER]
    password = "$API_PASSWORD"
    upsmon secondary
USERSEOF
  else
    # Legacy fallback — see the credential-topology block above.
    printf 'level=warn msg="upsmon.conf.user mounted without upsd.users.user; generated upsd.users keeps the API user as upsmon primary (cross-file credential contract with a mounted override). Your mounted upsmon.conf must MONITOR with this user and password, or upsd refuses the login and with it the forced-shutdown request, and networked clients fall back to their own HOSTSYNC timeout" user=%s\n' \
      "$API_USER" >&2
    cat >>/etc/nut/upsd.users <<USERSEOF

[$API_USER]
    password = "$API_PASSWORD"
    upsmon primary
USERSEOF
  fi
}

# --- upsmon.conf — skipped if user-mounted ---
# POWERDOWNFLAG lives in the root-only /var/run/nut-secrets rather than the
# nut-writable /var/run/nut, so a compromised nut-user process cannot plant the
# flag and latch the comms watchdog's stand-down (lifecycle.sh
# restart_ups_driver). Every legitimate actor is root: upsmon's privileged
# parent writes it on FSD, the entrypoint clears it at boot, the watchdog tests
# it, nut-shutdown.sh clears it on a failed poweroff.

# MONITOR host: upsd_probe_host (lifecycle.sh) owns the LISTEN-address mapping.
# MONITOR credential: local_upsmon_credential_active owns the choice.
# ALARM needs EXEC because ups.alarm is upstream's only report of a UPS hardware
# fault; without it the fault reaches no event= line.
generate_upsmon_conf() {
  if use_user_override upsmon.conf; then
    printf 'level=info msg="mounted upsmon.conf.user owns POWERDOWNFLAG; the comms watchdog stand-down and the boot-time stale-flag clear both read this path and stay inert unless your file sets it" path=%s\n' \
      "$POWERDOWNFLAG_FILE" >&2
    return 0
  fi
  if local_upsmon_credential_active; then
    _mon_user=local_upsmon
    _mon_password="$LOCAL_UPSMON_PASSWORD"
  else
    # Legacy fallback — see the credential-topology block above.
    printf 'level=warn msg="upsd.users.user mounted without upsmon.conf.user; generated upsmon.conf MONITOR falls back to the API user/password pair (cross-file credential contract with a mounted override). Your mounted upsd.users must declare this account as upsmon primary, or upsd refuses the forced-shutdown request from the bundled upsmon and networked clients fall back to their own HOSTSYNC timeout" user=%s\n' \
      "$API_USER" >&2
    _mon_user="$API_USER"
    _mon_password="$API_PASSWORD"
  fi
  cat >/etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@$(upsd_probe_host):$API_PORT 1 "$_mon_user" "$_mon_password" primary
SHUTDOWNCMD "$SHUTDOWN_CMD"
POWERDOWNFLAG $POWERDOWNFLAG_FILE
NOTIFYCMD /usr/local/bin/nut-notify.sh
POLLFREQ $POLLFREQ
POLLFREQALERT $POLLFREQALERT
DEADTIME $DEADTIME
FINALDELAY $FINALDELAY
HOSTSYNC $HOSTSYNC
NOCOMMWARNTIME $NOCOMMWARNTIME
RBWARNTIME $RBWARNTIME
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC
NOTIFYFLAG ALARM EXEC
NOTIFYFLAG OTHER EXEC
MONEOF
}

generate_all_configs() {
  # Empty in these five fails OPEN: an empty password authenticates, upsd
  # serves cleartext, SHUTDOWNCMD no-ops. Everything else fails visibly.
  : "${API_PASSWORD:?generate_all_configs requires API_PASSWORD}"
  # Only required when the internal cross-file credential is in play (both
  # upsd.users and upsmon.conf generated — see the credential-topology block).
  if local_upsmon_credential_active; then
    : "${LOCAL_UPSMON_PASSWORD:?generate_all_configs requires LOCAL_UPSMON_PASSWORD when upsd.users and upsmon.conf are both generated}"
  fi
  # Only required when TLS is on (resolve_tls_cert sets it before this runs).
  if [ "$API_TLS" = "true" ]; then
    : "${TLS_CERT_PATH:?generate_all_configs requires TLS_CERT_PATH when API_TLS=true}"
  fi
  : "${ADMIN_PASSWORD:?generate_all_configs requires ADMIN_PASSWORD}"
  : "${SHUTDOWN_CMD:?generate_all_configs requires SHUTDOWN_CMD}"

  _uo_probed=''

  generate_ups_conf
  generate_upsd_conf
  generate_upsd_users
  generate_upsmon_conf

  # An operator's *.user file the four generators never probed was ignored; from
  # the log an ignored override and an absent one are otherwise identical.
  for _uo_file in /etc/nut/*.user; do
    [ -e "$_uo_file" ] || continue
    _uo_name=${_uo_file##*/}
    case " $_uo_probed " in
      *" ${_uo_name%.user} "*) ;;
      *)
        printf 'level=warn msg="mounted override is not a file this image applies; ignoring it" file=%s\n' \
          "$_uo_name" >&2
        ;;
    esac
  done
}
