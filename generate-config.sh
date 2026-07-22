#!/bin/sh
# generate-config.sh — NUT config file generation helpers.
# Sourced by entrypoint.sh; not executed directly.

# ---------------------------------------------------------------------------
# Config generation helpers
# ---------------------------------------------------------------------------
# If /etc/nut/<name>.user exists, copy it over /etc/nut/<name> and return 0
# (caller skips generation). Return 1 otherwise.
use_user_override() {
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
  if ! cp "/etc/nut/$1.user" "/etc/nut/$1"; then
    printf 'level=error msg="failed to apply mounted override; aborting" file=%s.user\n' "$1" >&2
    exit 1
  fi
  printf 'level=info msg="using mounted %s.user"\n' "$1" >&2
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

  # pollonly is only meaningful for USB HID drivers; other drivers may
  # ignore it or warn. Emit it only for the USB driver family, reusing the
  # canonical classification in validate.sh (driver_transport) so the
  # USB-family driver list lives in one place.
  if [ "$(driver_transport)" = "usb" ]; then
    printf '    pollonly\n' >>/etc/nut/ups.conf
  fi

  # Battery overrides (ignorelb tells NUT to use our thresholds instead of
  # hardware).
  _batt_overrides="${LOWBATT_PERCENT:-}${LOWBATT_RUNTIME:-}${CRITBATT_PERCENT:-}${CRITBATT_RUNTIME:-}"
  if [ -n "$_batt_overrides" ]; then
    printf '    ignorelb\n' >>/etc/nut/ups.conf
  fi

  # Battery override directives — explicit per-variable to avoid eval.
  [ -n "${LOWBATT_PERCENT:-}" ] \
    && printf '    override.battery.charge.low = %s\n' "$LOWBATT_PERCENT" >>/etc/nut/ups.conf
  [ -n "${LOWBATT_RUNTIME:-}" ] \
    && printf '    override.battery.runtime.low = %s\n' "$LOWBATT_RUNTIME" >>/etc/nut/ups.conf
  [ -n "${CRITBATT_PERCENT:-}" ] \
    && printf '    override.battery.charge.critical = %s\n' "$CRITBATT_PERCENT" >>/etc/nut/ups.conf
  [ -n "${CRITBATT_RUNTIME:-}" ] \
    && printf '    override.battery.runtime.critical = %s\n' "$CRITBATT_RUNTIME" >>/etc/nut/ups.conf

  if [ -n "$_batt_overrides" ]; then
    printf 'level=info msg="battery thresholds overridden (ignorelb active)" low_pct=%s low_rt=%s crit_pct=%s crit_rt=%s\n' \
      "${LOWBATT_PERCENT:-unset}" "${LOWBATT_RUNTIME:-unset}" \
      "${CRITBATT_PERCENT:-unset}" "${CRITBATT_RUNTIME:-unset}" >&2
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
# The generated pair separates NUT's monitor roles the canonical way: the box
# that owns the UPS (this container's bundled upsmon) runs the ONE `upsmon
# primary`, and remote network clients are secondaries. So the bundled upsmon
# authenticates with a reserved internal account — [local_upsmon], secret
# auto-generated and cached root-only (resolve_local_upsmon_password,
# password.sh) — that carries `upsmon primary` (the FSD-request authority),
# while the network-facing [$API_USER] account is written `upsmon secondary`
# (status-following only). validate.sh rejects API_USER=local_upsmon (and
# =admin) so a generated [$API_USER] section can never merge with a reserved
# stanza and clobber its credential.
#
# The internal credential is a contract BETWEEN two generated files (the
# [local_upsmon] stanza in upsd.users and the MONITOR credential in
# upsmon.conf), so it is only used when BOTH files are generated. When a
# *.user override is mounted for exactly ONE of them, the generated half
# falls back to the legacy shared API-pair contract — the only credential a
# mounted half written against the documented env vars can be assumed to
# know — and logs a level=warn naming the fallback:
#   - upsd.users.user mounted, upsmon.conf generated: MONITOR authenticates
#     with $API_USER/$API_PASSWORD (primary — the mounted users file decides
#     what that account may do).
#   - upsd.users generated, upsmon.conf.user mounted: [$API_USER] keeps
#     `upsmon primary` so a mounted MONITOR line using the API pair keeps its
#     primary slot; no [local_upsmon] stanza is generated (nothing would
#     authenticate with it).
# Both mounted: nothing is generated and no decision is needed.
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
    printf 'level=warn msg="upsmon.conf.user mounted without upsd.users.user; generated upsd.users keeps the API user as upsmon primary (cross-file credential contract with a mounted override)" user=%s\n' \
      "$API_USER" >&2
    cat >>/etc/nut/upsd.users <<USERSEOF

[$API_USER]
    password = "$API_PASSWORD"
    upsmon primary
USERSEOF
  fi
}

# --- upsmon.conf — skipped if user-mounted ---
# POWERDOWNFLAG lives in the root-only /var/run/nut-secrets (mode 700
# root:root, created unconditionally by the Dockerfile) rather than the
# nut-writable /var/run/nut, so a compromised nut-user process cannot plant
# the flag and latch the comms watchdog's stand-down (lifecycle.sh
# restart_ups_driver). Every legitimate actor is root: upsmon's privileged
# parent writes the flag on FSD, the entrypoint clears it at boot, the
# watchdog tests it, and nut-shutdown.sh clears it on a failed poweroff.
# The MONITOR host comes from upsd_probe_host (lifecycle.sh, sourced before
# this runs): upsd binds ONLY the LISTEN address generated from API_ADDRESS,
# so upsmon must connect where upsd actually listens — the same mapping the
# comms watchdog probe and the Dockerfile HEALTHCHECK apply.
# The MONITOR credential is the internal [local_upsmon] account when both
# upsd.users and upsmon.conf are generated, and falls back to the legacy
# API pair when upsd.users is user-mounted — see the credential-topology
# block above generate_upsd_users.
generate_upsmon_conf() {
  use_user_override upsmon.conf && return 0
  if local_upsmon_credential_active; then
    _mon_user=local_upsmon
    _mon_password="$LOCAL_UPSMON_PASSWORD"
  else
    # Legacy fallback — see the credential-topology block above.
    printf 'level=warn msg="upsd.users.user mounted without upsmon.conf.user; generated upsmon.conf MONITOR falls back to the API user/password pair (cross-file credential contract with a mounted override)" user=%s\n' \
      "$API_USER" >&2
    _mon_user="$API_USER"
    _mon_password="$API_PASSWORD"
  fi
  cat >/etc/nut/upsmon.conf <<MONEOF
MONITOR $UPS_NAME@$(upsd_probe_host):$API_PORT 1 "$_mon_user" "$_mon_password" primary
SHUTDOWNCMD "$SHUTDOWN_CMD"
POWERDOWNFLAG /var/run/nut-secrets/killpower
NOTIFYCMD /usr/local/bin/nut-notify.sh
POLLFREQ $POLLFREQ
POLLFREQALERT $POLLFREQALERT
DEADTIME $DEADTIME
FINALDELAY $FINALDELAY
HOSTSYNC $HOSTSYNC
NOCOMMWARNTIME $NOCOMMWARNTIME
RBWARNTIME $RBWARNTIME
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC+WALL
NOTIFYFLAG LOWBATT SYSLOG+EXEC+WALL
NOTIFYFLAG FSD SYSLOG+EXEC+WALL
NOTIFYFLAG COMMOK SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC+WALL
NOTIFYFLAG REPLBATT SYSLOG+EXEC
NOTIFYFLAG NOCOMM SYSLOG+EXEC
MONEOF
}

generate_all_configs() {
  # Required variables — fail fast if caller forgot to set them.
  : "${UPS_NAME:?generate_all_configs requires UPS_NAME}"
  : "${UPS_DESC:?generate_all_configs requires UPS_DESC}"
  : "${UPS_DRIVER:?generate_all_configs requires UPS_DRIVER}"
  : "${UPS_PORT:?generate_all_configs requires UPS_PORT}"
  : "${API_USER:?generate_all_configs requires API_USER}"
  : "${API_PASSWORD:?generate_all_configs requires API_PASSWORD}"
  # Only required when the internal cross-file credential is in play (both
  # upsd.users and upsmon.conf generated — see the credential-topology block).
  if local_upsmon_credential_active; then
    : "${LOCAL_UPSMON_PASSWORD:?generate_all_configs requires LOCAL_UPSMON_PASSWORD when upsd.users and upsmon.conf are both generated}"
  fi
  : "${API_ADDRESS:?generate_all_configs requires API_ADDRESS}"
  : "${API_PORT:?generate_all_configs requires API_PORT}"
  : "${API_TLS:?generate_all_configs requires API_TLS}"
  # Only required when TLS is on (resolve_tls_cert sets it before this runs).
  if [ "$API_TLS" = "true" ]; then
    : "${TLS_CERT_PATH:?generate_all_configs requires TLS_CERT_PATH when API_TLS=true}"
  fi
  : "${ADMIN_PASSWORD:?generate_all_configs requires ADMIN_PASSWORD}"
  : "${SHUTDOWN_CMD:?generate_all_configs requires SHUTDOWN_CMD}"
  : "${POLLFREQ:?generate_all_configs requires POLLFREQ}"
  : "${POLLFREQALERT:?generate_all_configs requires POLLFREQALERT}"
  : "${DEADTIME:?generate_all_configs requires DEADTIME}"
  : "${FINALDELAY:?generate_all_configs requires FINALDELAY}"
  : "${HOSTSYNC:?generate_all_configs requires HOSTSYNC}"
  : "${NOCOMMWARNTIME:?generate_all_configs requires NOCOMMWARNTIME}"
  : "${RBWARNTIME:?generate_all_configs requires RBWARNTIME}"

  # --- nut.conf — always generated (MODE is not user-configurable) ---
  cat >/etc/nut/nut.conf <<'EOF'
MODE=netserver
EOF

  generate_ups_conf
  generate_upsd_conf
  generate_upsd_users
  generate_upsmon_conf
}
