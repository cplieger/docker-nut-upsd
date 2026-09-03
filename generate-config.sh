#!/bin/sh
# generate-config.sh — NUT config file generation helpers.
# Sourced by entrypoint.sh; not executed directly.

# Reclamation consumes this inventory so operator-owned /etc/nut *.tmp.* paths remain untouched.
# shellcheck disable=SC2034  # consumed by entrypoint.sh boot reclamation
readonly NUT_STAGED_CONFIGS='ups.conf upsd.conf upsd.users upsmon.conf'

decide_user_overrides() {
  if [ -e /etc/nut/ups.conf.user ]; then
    _uo_ups_conf=true
  else
    _uo_ups_conf=false
  fi
  if [ -e /etc/nut/upsd.conf.user ]; then
    _uo_upsd_conf=true
  else
    _uo_upsd_conf=false
  fi
  if [ -e /etc/nut/upsd.users.user ]; then
    _uo_upsd_users=true
  else
    _uo_upsd_users=false
  fi
  if [ -e /etc/nut/upsmon.conf.user ]; then
    _uo_upsmon_conf=true
  else
    _uo_upsmon_conf=false
  fi
  _uo_decided=true
}

_user_override_present() {
  if [ "${_uo_decided:-}" != true ]; then
    printf 'level=error msg="config override topology was read before it was decided; aborting" file=%s.user\n' "$1" >&2
    exit 1
  fi
  case "$1" in
    ups.conf) [ "$_uo_ups_conf" = true ] ;;
    upsd.conf) [ "$_uo_upsd_conf" = true ] ;;
    upsd.users) [ "$_uo_upsd_users" = true ] ;;
    upsmon.conf) [ "$_uo_upsmon_conf" = true ] ;;
    *)
      printf 'level=error msg="unknown config override name; aborting" file=%s.user\n' "$1" >&2
      exit 1
      ;;
  esac
}

# If /etc/nut/<name>.user was present when overrides were decided, copy it over
# /etc/nut/<name> and return 0 (caller skips generation). Return 1 when no
# override is present; abort the boot (exit 1) when the decided override cannot
# be applied, including when its path has since gone away.
use_user_override() {
  if ! _user_override_present "$1"; then
    # A dangling symlink (e.g. a mounted directory of symlinks with a broken
    # target) fails -e and would silently drop the operator's override; name
    # it before falling back to generation.
    if [ -L "/etc/nut/$1.user" ] && [ ! -e "/etc/nut/$1.user" ]; then
      printf 'level=warn msg="mounted override path is a dangling symlink; ignoring it and generating the file" file=%s.user\n' "$1" >&2
    fi
    return 1
  fi
  # Refuse a non-regular mount (directory, FIFO, device node) up front: reading
  # a writer-less FIFO would block forever and hang config generation with no
  # log line. Mirrors the resolve_tls_cert gate on /etc/nut/upsd.pem.
  if [ ! -f "/etc/nut/$1.user" ]; then
    if [ -L "/etc/nut/$1.user" ] && [ ! -e "/etc/nut/$1.user" ]; then
      printf 'level=error msg="mounted override symlink target went away after boot read the override topology; aborting (the next boot reads it afresh)" file=%s.user\n' "$1" >&2
    elif [ ! -e "/etc/nut/$1.user" ]; then
      printf 'level=error msg="mounted override path went away after boot read the override topology; aborting (the next boot reads it afresh)" file=%s.user\n' "$1" >&2
    else
      printf 'level=error msg="mounted override path is not a regular file; aborting" file=%s.user\n' "$1" >&2
    fi
    exit 1
  fi
  # Staged install through _install_nut_config (secrets.sh; sourced alongside this
  # module before any generator runs): plain cp treats an existing directory
  # at the destination (e.g. an accidentally auto-created bind-mount target)
  # as a container — it writes /etc/nut/<name>/<name>.user, returns success,
  # and the override is logged as applied while /etc/nut/<name> is still a
  # directory, so startup fails later with a misleading daemon/config error.
  _uo_dst="/etc/nut/$1"
  _uo_tmp=$(mktemp "${_uo_dst}.tmp.XXXXXX" 2>&1) || {
    printf 'level=error msg="failed to create mounted-override staging file; aborting" file=%s.user err="%s"\n' \
      "$1" "$(log_value "$_uo_tmp")" >&2
    exit 1
  }
  if ! cat "${_uo_dst}.user" >"$_uo_tmp" \
    || ! _install_nut_config "$_uo_tmp" "$_uo_dst"; then
    rm -f "$_uo_tmp"
    printf 'level=error msg="failed to apply mounted override; aborting" file=%s.user\n' "$1" >&2
    exit 1
  fi
  printf 'level=info msg="using mounted %s.user"\n' "$1" >&2 || :
}

_stage_generated() {
  _sg_tmp=$(mktemp "/etc/nut/$1.tmp.XXXXXX" 2>&1) || {
    printf 'level=error msg="failed to create generated-config staging file; aborting" file=%s err="%s"\n' \
      "$1" "$(log_value "$_sg_tmp")" >&2
    exit 1
  }
}

_install_generated() {
  if ! _install_nut_config "$_sg_tmp" "/etc/nut/$1"; then
    rm -f "$_sg_tmp"
    printf 'level=error msg="failed to install generated config; aborting" file=%s\n' "$1" >&2
    exit 1
  fi
}

_staged_write_failed() {
  rm -f "$_sg_tmp"
  printf 'level=error msg="failed to write generated config; aborting" file=%s\n' "$1" >&2
  exit 1
}

# --- ups.conf — skipped if user-mounted ---
_emit_ups_conf() {
  cat <<UPSEOF || return 1
[$UPS_NAME]
    desc = "$UPS_DESC"
    driver = $UPS_DRIVER
    port = $UPS_PORT
UPSEOF

  # pollonly is registered by usbhid-ups alone (drivers/usbhid-ups.c in the
  # pinned NUT tree); any other driver exits during ups.conf parsing on a flag
  # absent from its vartab (drivers/main.c, storeval).
  if [ "$UPS_DRIVER" = "usbhid-ups" ]; then
    printf '    pollonly\n' || return 1
  fi

  # Battery overrides (ignorelb tells NUT to use our thresholds instead of
  # hardware).
  if [ -n "$_batt_overrides" ]; then
    printf '    ignorelb\n' || return 1
  fi

  # Battery override directives — explicit per-variable to avoid eval.
  if [ -n "${LOWBATT_PERCENT:-}" ]; then
    printf '    override.battery.charge.low = %s\n' "$LOWBATT_PERCENT" || return 1
  fi
  if [ -n "${LOWBATT_RUNTIME:-}" ]; then
    printf '    override.battery.runtime.low = %s\n' "$LOWBATT_RUNTIME" || return 1
  fi
}

generate_ups_conf() {
  use_user_override ups.conf && return 0
  _batt_overrides="${LOWBATT_PERCENT:-}${LOWBATT_RUNTIME:-}"
  _stage_generated ups.conf
  _emit_ups_conf >"$_sg_tmp" || _staged_write_failed ups.conf
  _install_generated ups.conf

  if [ -n "$_batt_overrides" ]; then
    _low_pct_log="${LOWBATT_PERCENT:-unset}"
    _low_rt_log="${LOWBATT_RUNTIME:-unset}"
    if [ -n "${LOWBATT_PERCENT:-}" ] && [ "$LOWBATT_PERCENT" -eq 0 ]; then
      _low_pct_log=DISABLED
    fi
    if [ -n "${LOWBATT_RUNTIME:-}" ] && [ "$LOWBATT_RUNTIME" -eq 0 ]; then
      _low_rt_log=DISABLED
    fi

    if [ "$_low_pct_log" = DISABLED ]; then
      if [ -n "${LOWBATT_RUNTIME:-}" ]; then
        printf 'level=warn msg="battery percentage threshold disabled; low battery uses the runtime threshold" low_pct=%s low_rt=%s\n' \
          "$_low_pct_log" "$_low_rt_log" >&2
      else
        printf 'level=warn msg="battery percentage threshold disabled; low battery depends on the UPS reporting battery.runtime and battery.runtime.low" low_pct=%s low_rt=%s\n' \
          "$_low_pct_log" "$_low_rt_log" >&2
      fi
    elif [ "$_low_rt_log" = DISABLED ]; then
      if [ -n "${LOWBATT_PERCENT:-}" ]; then
        printf 'level=warn msg="battery runtime threshold disabled; low battery uses the percentage threshold" low_pct=%s low_rt=%s\n' \
          "$_low_pct_log" "$_low_rt_log" >&2
      else
        printf 'level=warn msg="battery runtime threshold disabled; low battery depends on the UPS reporting battery.charge and battery.charge.low" low_pct=%s low_rt=%s\n' \
          "$_low_pct_log" "$_low_rt_log" >&2
      fi
    else
      printf 'level=info msg="battery thresholds overridden (ignorelb active)" low_pct=%s low_rt=%s\n' \
        "$_low_pct_log" "$_low_rt_log" >&2
    fi
  else
    printf 'level=info msg="no battery threshold overrides; using UPS hardware defaults"\n' >&2
  fi
}

# --- upsd.conf — skipped if user-mounted ---
# STARTTLS (API_TLS=true, the default): CERTFILE names the cert+key PEM
# resolved by resolve_tls_cert (secrets.sh), and DISABLE_WEAK_SSL true pins
# the handshake to TLS 1.2+ (upsd otherwise accepts TLS 1.0 and logs a
# warning). STARTTLS is opportunistic in the NUT protocol — clients that
# never request it keep talking cleartext — so enabling it breaks no legacy
# client. With API_TLS=false, no TLS directives are emitted.
_emit_upsd_conf() {
  cat <<UPSDEOF || return 1
LISTEN $API_ADDRESS $API_PORT
UPSDEOF
  if [ "$API_TLS" = "true" ]; then
    cat <<UPSDEOF || return 1
CERTFILE $TLS_CERT_PATH
DISABLE_WEAK_SSL true
UPSDEOF
  fi
}

generate_upsd_conf() {
  use_user_override upsd.conf && return 0
  _stage_generated upsd.conf
  _emit_upsd_conf >"$_sg_tmp" || _staged_write_failed upsd.conf
  _install_generated upsd.conf
}

# ---------------------------------------------------------------------------
# Credential topology: which account links upsd.users to upsmon.conf
# ---------------------------------------------------------------------------
# When both files are generated, they share the internal credential. When
# exactly one is overridden, the generated half uses the documented API pair.
local_upsmon_credential_active() {
  ! _user_override_present upsd.users && ! _user_override_present upsmon.conf
}

# --- upsd.users — skipped if user-mounted ---
_emit_upsd_users() {
  cat <<USERSEOF || return 1
[admin]
    password = "$ADMIN_PASSWORD"
    actions = set
    actions = fsd
    instcmds = all
USERSEOF
  if local_upsmon_credential_active; then
    cat <<USERSEOF || return 1

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
    cat <<USERSEOF || return 1

[$API_USER]
    password = "$API_PASSWORD"
    upsmon primary
USERSEOF
  fi
}

generate_upsd_users() {
  use_user_override upsd.users && return 0
  _stage_generated upsd.users
  _emit_upsd_users >"$_sg_tmp" || _staged_write_failed upsd.users
  _install_generated upsd.users
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
# fault. ALARM and OTHER omit SYSLOG because their stock notices interpolate
# device-controlled strings (NUT clients/upsmon.h) that would otherwise be
# re-emitted raw on the alert-matched stream.
# The timing and criticality directives below are emitted at NUT
# v2.8.5's own defaults (clients/upsmon.c:59-133), so a NUT bump
# cannot move the generated file's shutdown decision. OFFDURATION,
# OBLBDURATION and ALARMCRITICAL are the three that decide whether a
# state is critical at all; see is_ups_critical.
_emit_upsmon_conf() {
  cat <<MONEOF || return 1
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
OFFDURATION 30
OBLBDURATION 0
ALARMCRITICAL 1
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOPARENT SYSLOG+EXEC
NOTIFYFLAG OFF SYSLOG+EXEC
NOTIFYFLAG BYPASS SYSLOG+EXEC
NOTIFYFLAG OVER SYSLOG+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC
NOTIFYFLAG ALARM EXEC
NOTIFYFLAG OTHER EXEC
MONEOF
}

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
  _stage_generated upsmon.conf
  _emit_upsmon_conf >"$_sg_tmp" || _staged_write_failed upsmon.conf
  _install_generated upsmon.conf
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

  generate_ups_conf
  generate_upsd_conf
  generate_upsd_users
  generate_upsmon_conf

  # An operator's *.user file not named by NUT_STAGED_CONFIGS is not one this
  # image stages; from the log an ignored override and an absent one are otherwise identical.
  for _uo_file in /etc/nut/*.user; do
    [ -e "$_uo_file" ] || [ -L "$_uo_file" ] || continue
    _uo_name=${_uo_file##*/}
    _uo_was_probed=false
    for _uo_probed_name in $NUT_STAGED_CONFIGS; do
      if [ "$_uo_probed_name" = "${_uo_name%.user}" ]; then
        _uo_was_probed=true
        break
      fi
    done
    if [ "$_uo_was_probed" = true ]; then
      if [ -e "$_uo_file" ] && ! _user_override_present "${_uo_name%.user}"; then
        printf 'level=warn msg="mounted override appeared after boot read the override topology; ignoring it for this boot (a container restart applies it)" file="%s"\n' \
          "$(log_value "$_uo_name")" >&2
      fi
    else
      printf 'level=warn msg="mounted override is not a file this image applies; ignoring it" file="%s"\n' \
        "$(log_value "$_uo_name")" >&2
    fi
  done
}
