#!/bin/sh
# Build-time smoke test for docker-nut-upsd.
#
# Runs in the Dockerfile `test` stage (FROM the runtime image, which has the
# compiled NUT binaries and the entrypoint helper scripts), so the centralized
# `ci / validate` docker build-ability gate executes it on every PR and push.
#
# It covers the two things that have no other unit coverage in this shell-only,
# compiled-from-source image: (1) the NUT binaries built from upstream sources
# actually run, and (2) the entrypoint's env -> config generation and its input
# validation (config-injection guards) behave correctly. Daemon startup itself
# still needs a real UPS and is covered by the runtime healthcheck.
#
# Run locally inside the image:  sh /tmp/tests/smoke.sh
set -eu

# shellcheck source=/dev/null
. /usr/local/bin/validate.sh
# shellcheck source=/dev/null
. /usr/local/bin/generate-config.sh
# shellcheck source=/dev/null
. /usr/local/bin/lifecycle.sh
# shellcheck source=/dev/null
. /usr/local/bin/password.sh

fail=0
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# 1. Binaries compiled from upstream sources are present and link.
for b in upsd upsc upsmon upsdrvctl; do
  if ! command -v "$b" >/dev/null 2>&1; then
    err "FAIL: NUT binary missing from PATH: $b"
    fail=1
  fi
done

for b in dbus-send timeout; do
  if ! command -v "$b" >/dev/null 2>&1; then
    err "FAIL: nut-shutdown runtime command missing from PATH: $b"
    fail=1
  fi
done

if ! command -v wall >/dev/null 2>&1; then
  err "FAIL: upsmon notification dependency missing from PATH: wall"
  fail=1
fi

if [ ! -x /usr/lib/nut/usbhid-ups ]; then
  err "FAIL: default UPS driver missing or not executable: /usr/lib/nut/usbhid-ups"
  fail=1
fi

for driver in snmp-ups apc_modbus; do
  if [ ! -x "/usr/lib/nut/$driver" ]; then
    err "FAIL: documented UPS driver missing or not executable: /usr/lib/nut/$driver"
    fail=1
  fi
done

shutdown_default=$(awk '
  /^[[:space:]]*SHUTDOWN_CMD=/ {
    value = $0
    sub(/^[^=]*=/, "", value)
    gsub(/^"|"$/, "", value)
    print value
    exit
  }
' /usr/local/bin/entrypoint.sh)

if [ -z "$shutdown_default" ]; then
  err "FAIL: could not read the disabled-host SHUTDOWNCMD default from the installed entrypoint"
  fail=1
elif [ ! -x "$shutdown_default" ]; then
  err "FAIL: disabled-host SHUTDOWNCMD missing or not executable: $shutdown_default"
  fail=1
fi

# `command -v` above resolves names without running the loader, so it
# cannot see a runtime library that was dropped, renamed or swapped.
for bin in /usr/sbin/upsd /usr/bin/upsc /usr/sbin/upsmon /usr/sbin/upsdrvctl /usr/lib/nut/*; do
  [ -x "$bin" ] || continue
  if ! out=$(ldd "$bin" 2>&1); then
    err "FAIL: loader rejected shipped NUT executable: $bin"
    err "$out"
    fail=1
  elif printf '%s\n' "$out" | grep -qE 'not found|Error loading shared library'; then
    err "FAIL: shipped NUT executable has an unresolved shared library: $bin"
    err "$out"
    fail=1
  fi
done

# 2. Valid env passes validation and generates all four config files.
export UPS_NAME=ups UPS_DESC="Test UPS" UPS_DRIVER=usbhid-ups UPS_PORT=auto \
  API_USER=monuser API_PASSWORD=secret API_ADDRESS=0.0.0.0 API_PORT=3493 \
  API_TLS=true \
  ADMIN_PASSWORD=adminpass LOCAL_UPSMON_PASSWORD=localmonpass \
  SHUTDOWN_CMD=/usr/local/bin/nut-shutdown-noop.sh \
  POLLFREQ=5 POLLFREQALERT=5 DEADTIME=15 FINALDELAY=5 HOSTSYNC=15 \
  NOCOMMWARNTIME=300 RBWARNTIME=43200 \
  COMMS_WATCHDOG=true COMMS_CHECK_INTERVAL=15 COMMS_RECOVERY_TIMEOUT=90 \
  COMMS_FAST_RETRIES=3 COMMS_BACKOFF_FACTOR=5 DBUS_PROBE_INTERVAL=300

if ! out=$( (run_validations) 2>&1); then
  err "FAIL: run_validations rejected a valid environment"
  err "$out"
  fail=1
fi

# TLS is on in the baseline env (the production default), so provision the
# cert exactly like the entrypoint does before generating configs; the
# provisioning behavior itself is exercised in section 7.
if ! resolve_tls_cert 2>/dev/null; then
  err "FAIL: resolve_tls_cert could not provision the self-signed certificate"
  fail=1
fi

decide_user_overrides
generate_all_configs
for f in ups.conf upsd.conf upsd.users upsmon.conf; do
  if [ ! -s "/etc/nut/$f" ]; then
    err "FAIL: config not generated: /etc/nut/$f"
    fail=1
  fi
done
if ! (
  POLLFREQ=11
  POLLFREQALERT=13
  DEADTIME=17
  FINALDELAY=19
  HOSTSYNC=23
  NOCOMMWARNTIME=29
  RBWARNTIME=31
  generate_upsmon_conf >/dev/null 2>&1
  grep -q '^POLLFREQ 11$' /etc/nut/upsmon.conf \
    && grep -q '^POLLFREQALERT 13$' /etc/nut/upsmon.conf \
    && grep -q '^DEADTIME 17$' /etc/nut/upsmon.conf \
    && grep -q '^FINALDELAY 19$' /etc/nut/upsmon.conf \
    && grep -q '^HOSTSYNC 23$' /etc/nut/upsmon.conf \
    && grep -q '^NOCOMMWARNTIME 29$' /etc/nut/upsmon.conf \
    && grep -q '^RBWARNTIME 31$' /etc/nut/upsmon.conf
); then
  err "FAIL: non-default upsmon timing values did not reach every generated directive"
  fail=1
fi
grep -q '^\[ups\]' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing [ups] section"
  fail=1
}
grep -q 'driver = usbhid-ups' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing driver"
  fail=1
}
grep -q 'pollonly' /etc/nut/ups.conf || {
  err "FAIL: ups.conf missing pollonly for usbhid driver"
  fail=1
}
# NUT storeval aborts when a driver receives a flag absent from its vartab.
if ! (
  UPS_DRIVER=apc_modbus
  generate_ups_conf >/dev/null 2>&1
  ! grep -q '^    pollonly$' /etc/nut/ups.conf
); then
  err "FAIL: ups.conf emitted pollonly for a non-usbhid driver"
  fail=1
fi
# Battery thresholds: with no overrides, preserve the UPS hardware LB flag;
# with LOWBATT_PERCENT set, emit NUT's low-charge override and arm ignorelb.
if ! (
  unset LOWBATT_PERCENT LOWBATT_RUNTIME CRITBATT_PERCENT CRITBATT_RUNTIME
  generate_ups_conf >/dev/null 2>&1
  ! grep -q '^    ignorelb$' /etc/nut/ups.conf \
    && ! grep -q '^    override\.battery\.' /etc/nut/ups.conf
); then
  err "FAIL: default ups.conf emitted ignorelb or a battery override"
  fail=1
fi
if ! (
  LOWBATT_PERCENT=20
  unset LOWBATT_RUNTIME CRITBATT_PERCENT CRITBATT_RUNTIME
  generate_ups_conf >/dev/null 2>&1
  [ "$(grep -c '^    ignorelb$' /etc/nut/ups.conf)" -eq 1 ] \
    && grep -q '^    override\.battery\.charge\.low = 20$' /etc/nut/ups.conf
); then
  err "FAIL: LOWBATT_PERCENT did not emit one ignorelb and the NUT low-charge override"
  fail=1
fi
if (
  LOWBATT_PERCENT=0
  LOWBATT_RUNTIME=0
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: LOWBATT_PERCENT=0 with LOWBATT_RUNTIME=0 disabled every low-battery path but was accepted"
  fail=1
fi
BATT_ERR=$(mktemp)
if ! (
  LOWBATT_PERCENT=0
  LOWBATT_RUNTIME=300
  run_validations >/dev/null 2>&1 || exit 1
  generate_ups_conf >/dev/null 2>"$BATT_ERR"
  [ "$(grep -c '^    ignorelb$' /etc/nut/ups.conf)" -eq 1 ] \
    && grep -q '^    override\.battery\.charge\.low = 0$' /etc/nut/ups.conf \
    && grep -q '^    override\.battery\.runtime\.low = 300$' /etc/nut/ups.conf
); then
  err "FAIL: a disabled percentage axis with an active runtime threshold did not generate the coherent single-axis config"
  fail=1
fi
if ! grep -q 'level=warn msg="battery percentage threshold disabled; low battery uses the runtime threshold" low_pct=DISABLED low_rt=300' "$BATT_ERR"; then
  err "FAIL: a disabled percentage axis was not identified in the battery-threshold warning"
  fail=1
fi
rm -f "$BATT_ERR"
(
  unset LOWBATT_PERCENT LOWBATT_RUNTIME CRITBATT_PERCENT CRITBATT_RUNTIME
  generate_ups_conf >/dev/null 2>&1
)
grep -q 'LISTEN 0.0.0.0 3493' /etc/nut/upsd.conf || {
  err "FAIL: upsd.conf missing LISTEN directive"
  fail=1
}
grep -q '^CERTFILE /etc/nut/upsd-selfsigned.pem$' /etc/nut/upsd.conf || {
  err "FAIL: upsd.conf missing CERTFILE with API_TLS=true"
  fail=1
}
grep -q '^DISABLE_WEAK_SSL true$' /etc/nut/upsd.conf || {
  err "FAIL: upsd.conf missing DISABLE_WEAK_SSL with API_TLS=true"
  fail=1
}

# Credential topology (generate-config.sh): with no *.user overrides (the
# test-stage default), the generated pair links via the reserved internal
# [local_upsmon] account — the bundled upsmon holds the one `upsmon primary`
# slot — and the network-facing [$API_USER] account is a plain secondary.
# upsd_users_role SECTION: print the `upsmon <role>` role of one upsd.users
# section (empty when the section or its role line is absent).
upsd_users_role() {
  awk -v want="[$1]" '
    $0 == want { insec = 1; next }
    /^\[/ { insec = 0 }
    insec && $1 == "upsmon" { print $2 }
  ' /etc/nut/upsd.users
}
upsd_users_password() {
  awk -v want="[$1]" '
    $0 == want { insec = 1; next }
    /^\[/ { insec = 0 }
    insec && /^[[:space:]]*password[[:space:]]*=/ {
      sub(/^[[:space:]]*password[[:space:]]*=[[:space:]]*"/, "")
      sub(/"$/, "")
      print
    }
  ' /etc/nut/upsd.users
}
grep -q '^\[local_upsmon\]$' /etc/nut/upsd.users || {
  err "FAIL: generated upsd.users missing the reserved [local_upsmon] section"
  fail=1
}
if [ "$(upsd_users_role local_upsmon)" != "primary" ]; then
  err "FAIL: [local_upsmon] does not carry 'upsmon primary'"
  fail=1
fi
if [ "$(upsd_users_role monuser)" != "secondary" ]; then
  err "FAIL: [monuser] must carry 'upsmon secondary' and not primary (got '$(upsd_users_role monuser)')"
  fail=1
fi
grep -q '^MONITOR ups@127.0.0.1:3493 1 "local_upsmon" "localmonpass" primary$' /etc/nut/upsmon.conf || {
  err "FAIL: generated upsmon.conf MONITOR does not authenticate with the internal local_upsmon credential"
  fail=1
}
if [ "$(upsd_users_password admin)" != "$ADMIN_PASSWORD" ]; then
  err "FAIL: generated [admin] password does not equal ADMIN_PASSWORD"
  fail=1
fi
if [ "$(upsd_users_password "$API_USER")" != "$API_PASSWORD" ]; then
  err "FAIL: generated [$API_USER] password does not equal API_PASSWORD"
  fail=1
fi
upsmon_stored_password=$(awk '
  $1 == "MONITOR" {
    line = $0
    sub(/^MONITOR [^ ]+ 1 "[^"]*" "/, "", line)
    sub(/" primary$/, "", line)
    print line
  }
' /etc/nut/upsmon.conf)
if [ "$(upsd_users_password local_upsmon)" != "$LOCAL_UPSMON_PASSWORD" ]; then
  err "FAIL: generated [local_upsmon] password does not equal LOCAL_UPSMON_PASSWORD"
  fail=1
fi
if [ "$(upsd_users_password local_upsmon)" != "$upsmon_stored_password" ]; then
  err "FAIL: generated upsd.users and upsmon.conf disagree on the local upsmon password"
  fail=1
fi

# A single trailing LF (env-file artifact) is harmless only because the
# entrypoint strips it from every validated var BEFORE validation and config
# generation (validate.sh canonicalize_validated_values). Exercise the real
# production helper — not a hand-rolled copy of the strip — and assert the
# desc directive stays a single well-formed line.
if ! (
  UPS_DESC="$(printf 'desc\nx')"
  UPS_DESC=${UPS_DESC%x}
  canonicalize_validated_values
  run_validations >/dev/null 2>&1 || exit 1
  decide_user_overrides
  generate_all_configs >/dev/null 2>&1
  grep -q '^    desc = "desc"$' /etc/nut/ups.conf
); then
  err "FAIL: trailing-LF UPS_DESC did not canonicalize to a one-line desc directive"
  fail=1
fi
# API_PORT is the one var written MID-LINE into a generated config (upsmon.conf's
# MONITOR directive); a surviving trailing LF would split the directive across
# two lines. Assert canonicalization keeps it one well-formed line.
if ! (
  API_PORT="$(printf '3493\nx')"
  API_PORT=${API_PORT%x}
  canonicalize_validated_values
  run_validations >/dev/null 2>&1 || exit 1
  decide_user_overrides
  generate_all_configs >/dev/null 2>&1
  grep -q '^MONITOR ups@127.0.0.1:3493 1 "local_upsmon" "localmonpass" primary$' /etc/nut/upsmon.conf
); then
  err "FAIL: trailing-LF API_PORT did not canonicalize to a one-line MONITOR directive"
  fail=1
fi
# Credential byte fidelity (validate.sh canonicalize_validated_values): a remote
# client reproduces API_PASSWORD/ADMIN_PASSWORD byte for byte, so those two are
# enumerated but assigned RAW — an LF-only value reaches the `control` check and
# is REFUSED, naming the variable, instead of being silently rewritten into an
# account whose stored password is not the one that was set. The presentation
# values around them still canonicalize (the two cases above).
rm -f /var/run/nut-secrets/admin_password
CRED_ERR=$(mktemp)
if (
  ADMIN_PASSWORD="$(printf '\nx')"
  ADMIN_PASSWORD=${ADMIN_PASSWORD%x}
  canonicalize_validated_values
  run_validations
) >/dev/null 2>"$CRED_ERR"; then
  err "FAIL: LF-only ADMIN_PASSWORD was accepted (credential silently rewritten)"
  fail=1
fi
if ! grep -q 'msg="env var contains control characters" var=ADMIN_PASSWORD' "$CRED_ERR"; then
  err "FAIL: LF-only ADMIN_PASSWORD was not refused with the control-character error naming it ($(head -c 200 "$CRED_ERR"))"
  fail=1
fi
rm -f "$CRED_ERR"
#    ...and an UNSET ADMIN_PASSWORD still auto-generates a full-length secret,
#    which is the documented behaviour of unset (README) rather than of an
#    LF-only value. The isolating pair for the refusal above: without it, making
#    the refusal fire for every ADMIN_PASSWORD would still pass.
if ! (
  ADMIN_PASSWORD=""
  canonicalize_validated_values
  resolve_admin_password 2>/dev/null
  [ "${#ADMIN_PASSWORD}" -eq "$PASSWORD_LENGTH" ]
); then
  err "FAIL: an unset ADMIN_PASSWORD did not auto-generate a ${PASSWORD_LENGTH}-char password"
  fail=1
fi
rm -f /var/run/nut-secrets/admin_password
# warn_weak_api_password truth table. The strong pair is the isolating control:
# without it, a function that warned unconditionally would pass both cases.
WEAK_PASSWORD_ERR=$(mktemp)
(
  API_PASSWORD=secret
  ADMIN_PASSWORD=ABCDEFGHIJKLMNOPQRSTUVWX
  warn_weak_api_password
) 2>"$WEAK_PASSWORD_ERR"
if ! grep -q 'API_PASSWORD is weak' "$WEAK_PASSWORD_ERR" \
  || grep -q 'ADMIN_PASSWORD is weak' "$WEAK_PASSWORD_ERR"; then
  err "FAIL: the published weak API password did not emit only the API_PASSWORD warning"
  fail=1
fi

(
  API_PASSWORD=ABCDEFGHIJKLMNOPQRSTUVWX
  ADMIN_PASSWORD=short
  warn_weak_api_password
) 2>"$WEAK_PASSWORD_ERR"
if ! grep -q 'ADMIN_PASSWORD is weak' "$WEAK_PASSWORD_ERR" \
  || grep -q 'API_PASSWORD is weak' "$WEAK_PASSWORD_ERR"; then
  err "FAIL: a short admin password did not emit only the ADMIN_PASSWORD warning"
  fail=1
fi

(
  API_PASSWORD=ABCDEFGHIJKLMNOPQRSTUVWX
  ADMIN_PASSWORD=ZYXWVUTSRQPONMLKJIHGFEDC
  warn_weak_api_password
) 2>"$WEAK_PASSWORD_ERR"
if [ -s "$WEAK_PASSWORD_ERR" ]; then
  err "FAIL: strong API and admin passwords emitted a weak-credential warning"
  fail=1
fi
rm -f "$WEAK_PASSWORD_ERR"
# Canonicalize-then-default contract (entrypoint boot order): the := defaults
# are a raw-value interpretation (an LF-only value is non-empty raw), so an
# LF-only UPS_NAME (env-file artifact) must canonicalize to empty FIRST and
# then take the documented default — without canonicalize-first the raw LF
# dodges the default and fails validation (control characters) instead of
# booting as "ups". This pins canonicalize_validated_values composed with the
# := default in the documented order; the entrypoint's literal top-level call
# ordering is inline flow and is NOT exercised here.
if ! (
  UPS_NAME="$(printf '\nx')"
  UPS_NAME=${UPS_NAME%x}
  canonicalize_validated_values
  : "${UPS_NAME:=ups}"
  [ "$UPS_NAME" = "ups" ] || exit 1
  run_validations >/dev/null 2>&1
); then
  err "FAIL: LF-only UPS_NAME did not canonicalize to empty and take the documented default"
  fail=1
fi

# Partial-override fallback (generate-config.sh credential topology): with
# upsd.users.user mounted and upsmon.conf still generated, the internal
# cross-file credential is unusable, so the generated MONITOR must fall back
# to the legacy API pair and the fallback must be logged at level=warn.
printf '# override fixture\n' >/etc/nut/upsd.users.user
FALLBACK_ERR=$(mktemp)
decide_user_overrides
generate_all_configs >/dev/null 2>"$FALLBACK_ERR"
if ! grep -q '^MONITOR ups@127.0.0.1:3493 1 "monuser" "secret" primary$' /etc/nut/upsmon.conf; then
  err "FAIL: with upsd.users.user mounted, generated MONITOR did not fall back to the API user/password pair"
  fail=1
fi
if ! grep -q 'level=warn msg="upsd.users.user mounted without upsmon.conf.user' "$FALLBACK_ERR"; then
  err "FAIL: MONITOR API-pair fallback was not logged at level=warn"
  fail=1
fi
rm -f /etc/nut/upsd.users.user "$FALLBACK_ERR"
#    Mirror direction: with upsmon.conf.user mounted and upsd.users generated,
#    [$API_USER] must keep `upsmon primary` (the mounted MONITOR line
#    authenticates with the API pair) and no [local_upsmon] stanza may exist.
printf '# override fixture\n' >/etc/nut/upsmon.conf.user
FALLBACK_ERR=$(mktemp)
decide_user_overrides
generate_all_configs >/dev/null 2>"$FALLBACK_ERR"
if [ "$(upsd_users_role monuser)" != "primary" ]; then
  err "FAIL: with upsmon.conf.user mounted, generated [monuser] did not keep 'upsmon primary'"
  fail=1
fi
if grep -q '^\[local_upsmon\]$' /etc/nut/upsd.users; then
  err "FAIL: with upsmon.conf.user mounted, generated upsd.users still defines [local_upsmon]"
  fail=1
fi
if ! grep -q 'level=warn msg="upsmon.conf.user mounted without upsd.users.user' "$FALLBACK_ERR"; then
  err "FAIL: upsd.users API-pair fallback was not logged at level=warn"
  fail=1
fi
rm -f /etc/nut/upsmon.conf.user "$FALLBACK_ERR"

printf '# override fixture\n' >/etc/nut/ups.conf.user
printf '# override fixture\n' >/etc/nut/upsd.conf.user
printf '# override fixture\n' >/etc/nut/upsd.users.user
printf '# override fixture\n' >/etc/nut/upsmon.conf.user
printf '# override fixture\n' >/etc/nut/ignored.conf.user
OVERRIDE_SWEEP_ERR=$(mktemp)
decide_user_overrides
if ! generate_all_configs >/dev/null 2>"$OVERRIDE_SWEEP_ERR"; then
  err "FAIL: config generation failed while checking mounted-override diagnostics"
  fail=1
fi
override_warn_count=$(grep -cF 'level=warn msg="mounted override is not a file this image applies; ignoring it"' "$OVERRIDE_SWEEP_ERR" || :)
if [ "$override_warn_count" -ne 1 ]; then
  err "FAIL: mounted-override sweep emitted $override_warn_count ignored-file warnings, want 1"
  fail=1
fi
if ! grep -F 'level=warn msg="mounted override is not a file this image applies; ignoring it"' "$OVERRIDE_SWEEP_ERR" \
  | grep -q 'ignored\.conf\.user'; then
  err "FAIL: mounted-override sweep did not name ignored.conf.user in its warning"
  fail=1
fi
rm -f /etc/nut/ups.conf.user /etc/nut/upsd.conf.user \
  /etc/nut/upsd.users.user /etc/nut/upsmon.conf.user \
  /etc/nut/ignored.conf.user "$OVERRIDE_SWEEP_ERR"
decide_user_overrides
generate_all_configs >/dev/null 2>&1

# One decision must govern both generated credential files even if an override
# appears between them.
decide_user_overrides
generate_upsd_users >/dev/null 2>&1
printf '# appeared after the decision\n' >/etc/nut/upsd.users.user
generate_upsmon_conf >/dev/null 2>&1
if [ "$(upsd_users_role local_upsmon)" != primary ] \
  || ! grep -q '^MONITOR ups@127.0.0.1:3493 1 "local_upsmon" "localmonpass" primary$' /etc/nut/upsmon.conf; then
  err "FAIL: an override appearing mid-generation split the recorded internal credential topology"
  fail=1
fi
rm -f /etc/nut/upsd.users.user

# The mirror mutation must keep the mounted/API topology after its source
# disappears; the installed destination remains the first half of the pair.
printf '[monuser]\n    password = "secret"\n    upsmon primary\n' >/etc/nut/upsd.users.user
decide_user_overrides
generate_upsd_users >/dev/null 2>&1
rm -f /etc/nut/upsd.users.user
generate_upsmon_conf >/dev/null 2>&1
if [ "$(upsd_users_role monuser)" != primary ] \
  || grep -q '^\[local_upsmon\]$' /etc/nut/upsd.users \
  || ! grep -q '^MONITOR ups@127.0.0.1:3493 1 "monuser" "secret" primary$' /etc/nut/upsmon.conf; then
  err "FAIL: an override disappearing mid-generation split the recorded mounted credential topology"
  fail=1
fi
decide_user_overrides
#    Non-regular override refusal (use_user_override): a FIFO planted at an
#    override path passes a bare existence check and cp then blocks forever
#    waiting for a writer, hanging config generation with no diagnostic. The
#    regular-file gate must refuse it with an explicit error BEFORE cp — an
#    elapsed timeout budget means cp blocked, i.e. the gate failed. BusyBox
#    timeout (the only one in this image) reports expiry as 143 (128+TERM)
#    because it execs the command in the parent and signals it from a watchdog;
#    coreutils' 124 is matched too for portability. Matching 124 alone would
#    read a blocked cp as a pass and make the gate deletable with this green.
mkfifo /etc/nut/ups.conf.user
FIFO_ERR=$(mktemp)
fifo_rc=0
timeout 2 sh -c '. /usr/local/bin/generate-config.sh; decide_user_overrides; generate_ups_conf' \
  >/dev/null 2>"$FIFO_ERR" || fifo_rc=$?
if [ "$fifo_rc" -eq 0 ] || [ "$fifo_rc" -eq 124 ] || [ "$fifo_rc" -eq 143 ]; then
  err "FAIL: FIFO at /etc/nut/ups.conf.user was not refused before cp (rc=$fifo_rc; 124/143 = cp blocked until timeout)"
  fail=1
fi
if ! grep -q 'level=error msg="mounted override path is not a regular file' "$FIFO_ERR"; then
  err "FAIL: FIFO override was not refused with the not-a-regular-file error"
  fail=1
fi
rm -f /etc/nut/ups.conf.user "$FIFO_ERR"
#    Dangling-symlink override: -e follows the link, so a broken symlink must
#    fall back to generation (boot continues) but be named at level=warn
#    rather than dropped silently.
ln -s /etc/nut/does-not-exist /etc/nut/ups.conf.user
DANGLE_ERR=$(mktemp)
decide_user_overrides
if ! generate_ups_conf >/dev/null 2>"$DANGLE_ERR"; then
  err "FAIL: dangling-symlink ups.conf.user aborted generation instead of falling back"
  fail=1
fi
if ! grep -q 'level=warn msg="mounted override path is a dangling symlink' "$DANGLE_ERR"; then
  err "FAIL: dangling-symlink override was not logged at level=warn"
  fail=1
fi
rm -f /etc/nut/ups.conf.user "$DANGLE_ERR"
grep -q '^\[ups\]' /etc/nut/ups.conf || {
  err "FAIL: fallback generation did not write ups.conf"
  fail=1
}
#    Directory planted at the generated-config destination: plain cp would
#    treat /etc/nut/ups.conf-as-a-directory as a container (POSIX cp
#    destination-directory semantics), write ups.conf.user INSIDE it, return
#    success, and log the override as applied while the config path is still
#    a directory. The staged _replace_file install must refuse it promptly
#    (non-zero, not a hang), log the structured apply failure, and leak
#    nothing into the directory. password.sh is sourced in the subshell so
#    _replace_file is in scope, as in the entrypoint.
printf '[ups]\n    driver = usbhid-ups\n    port = auto\n' >/etc/nut/ups.conf.user
rm -f /etc/nut/ups.conf
mkdir /etc/nut/ups.conf
DIRDST_ERR=$(mktemp)
dirdst_rc=0
timeout 2 sh -c '. /usr/local/bin/password.sh; . /usr/local/bin/generate-config.sh; decide_user_overrides; generate_ups_conf' \
  >/dev/null 2>"$DIRDST_ERR" || dirdst_rc=$?
if [ "$dirdst_rc" -eq 0 ] || [ "$dirdst_rc" -eq 124 ] || [ "$dirdst_rc" -eq 143 ]; then
  err "FAIL: directory at /etc/nut/ups.conf was not refused promptly (rc=$dirdst_rc; 124/143 = install blocked until timeout)"
  fail=1
fi
if ! grep -q 'level=error msg="failed to apply mounted override; aborting" file=ups.conf.user' "$DIRDST_ERR"; then
  err "FAIL: directory at the generated-config destination was not refused with the apply-failure error"
  fail=1
fi
if [ -n "$(ls -A /etc/nut/ups.conf)" ]; then
  err "FAIL: file leaked inside the directory planted at the generated-config destination"
  fail=1
fi
rmdir /etc/nut/ups.conf
rm -f /etc/nut/ups.conf.user /etc/nut/ups.conf.tmp.* "$DIRDST_ERR"
#    A best-effort success diagnostic must not turn a completed override install
#    into generation fallback when stderr is unavailable.
printf '[ups]\n    driver = dummy-ups\n    port = /tmp/operator.dev\n' >/etc/nut/ups.conf.user
decide_user_overrides
if ! use_user_override ups.conf 2>&-; then
  err "FAIL: applied ups.conf.user returned failure when its success diagnostic could not write"
  fail=1
fi
if ! cmp -s /etc/nut/ups.conf.user /etc/nut/ups.conf; then
  err "FAIL: direct override install did not preserve the operator bytes"
  fail=1
fi
if ! generate_ups_conf 2>&-; then
  err "FAIL: generate_ups_conf failed after applying ups.conf.user with stderr closed"
  fail=1
elif ! cmp -s /etc/nut/ups.conf.user /etc/nut/ups.conf; then
  err "FAIL: generate_ups_conf overwrote an applied ups.conf.user after its success diagnostic failed"
  fail=1
fi
rm -f /etc/nut/ups.conf.user

# resolve_local_upsmon_password (password.sh): generates a PASSWORD_LENGTH-char
# secret, caches it root-only, and reuses the cache on the next resolve
# (stable across in-container restarts) — and ignores any inherited env value
# (the exported 12-char test value must NOT survive a resolve). Subshell keeps
# the fixed test LOCAL_UPSMON_PASSWORD in place for the config assertions.
rm -f /var/run/nut-secrets/local_upsmon_password
if ! (
  resolve_local_upsmon_password 2>/dev/null
  _first="$LOCAL_UPSMON_PASSWORD"
  [ "${#_first}" -eq "$PASSWORD_LENGTH" ] || exit 1
  resolve_local_upsmon_password 2>/dev/null
  [ "$LOCAL_UPSMON_PASSWORD" = "$_first" ]
); then
  err "FAIL: resolve_local_upsmon_password did not generate and reuse a cached ${PASSWORD_LENGTH}-char secret"
  fail=1
fi
rm -f /var/run/nut-secrets/local_upsmon_password

#    Directory planted at the password-cache path: plain mv would move the
#    temp INSIDE the directory (POSIX mv destination-directory semantics) and
#    falsely log the credential as cached, so every restart would mint a new
#    password and leak another temp file. _replace_file must refuse it: the
#    resolve still returns a full-length password (cache failure is warn-only)
#    and nothing leaks into the directory.
mkdir /var/run/nut-secrets/local_upsmon_password
DIRCACHE_ERR=$(mktemp)
if ! (
  resolve_local_upsmon_password 2>"$DIRCACHE_ERR" || exit 1
  [ "${#LOCAL_UPSMON_PASSWORD}" -eq "$PASSWORD_LENGTH" ]
); then
  err "FAIL: resolve_local_upsmon_password did not produce a full-length password with a directory at its cache path"
  fail=1
fi
if ! grep -q 'level=warn msg="generated LOCAL_UPSMON_PASSWORD but failed to cache' "$DIRCACHE_ERR"; then
  err "FAIL: directory at the password-cache path was not logged as a warn-level cache failure"
  fail=1
fi
if [ -n "$(ls -A /var/run/nut-secrets/local_upsmon_password)" ]; then
  err "FAIL: temp file leaked inside the directory planted at the password-cache path"
  fail=1
fi
rmdir /var/run/nut-secrets/local_upsmon_password
rm -f "$DIRCACHE_ERR"

# Regenerate with the baseline env so later steps see the section-2 configs.
decide_user_overrides
generate_all_configs >/dev/null 2>&1

# 3. Validation rejects config-injection attempts (run_validations exits non-
#    zero on failure, so each negative case runs in a subshell).

# Every row of the two SHIPPED validation tables, driven with a value the row's
# config destination forbids. Those declarations are the only link between an
# operator-set variable and the validator its destination needs, so deleting a
# row -- or widening the check that rejects a class -- goes unnoticed today: the
# named cases below fail instead, one per variable and prohibited class. Each
# case requires the intended validator's OWN message, because a row carries
# several checks and an outcome-only assertion cannot tell which one refused
# (shell.md, "where two guards are redundant"). The tables are driven through
# _run_table rather than run_validations to keep the cross-field guards out of
# the way; the classes are value shapes, not check names.
rejected_table_value() {
  case "$1" in
    control) printf 'bad\rvalue' ;;
    quote) printf 'bad"value' ;;
    backslash) printf 'bad\\value' ;;
    hash) printf 'bad#value' ;;
    nut_word) printf '%600s' '' | tr ' ' 'a' ;;
    bracket) printf 'bad]value' ;;
    identifier) printf 'bad value' ;;
    numeric) printf 'not-a-number' ;;
    positive | port) printf '0' ;;
    percent) printf '101' ;;
    *) return 1 ;;
  esac
}

rejected_table_message() {
  case "$1" in
    control) printf 'contains control characters' ;;
    quote) printf 'contains double-quote' ;;
    backslash) printf 'contains backslash' ;;
    hash) printf 'contains hash character' ;;
    nut_word) printf 'longer than NUT 512-byte word limit' ;;
    bracket) printf 'contains bracket characters' ;;
    identifier) printf 'is not a valid identifier' ;;
    numeric) printf 'must be a non-negative integer' ;;
    positive) printf 'must be a positive integer (>= 1)' ;;
    port) printf 'must be 1-65535' ;;
    percent) printf 'must be 0-100' ;;
    *) return 1 ;;
  esac
}

check_table_rejection() {
  _matrix_var="$1"
  _matrix_class="$2"
  _matrix_optional="$3"
  _matrix_value=$(rejected_table_value "$_matrix_class") || exit 1
  _matrix_want=$(rejected_table_message "$_matrix_class") || exit 1
  if _matrix_err=$(
    (
      export "$_matrix_var=$_matrix_value"
      if [ "$_matrix_optional" = 1 ]; then
        _run_table "$VALIDATION_TABLE_OPTIONAL" 1
      else
        _run_table "$VALIDATION_TABLE" 0
      fi
    ) 2>&1
  ); then
    err "FAIL: $_matrix_var accepted a $_matrix_class value forbidden by its config destination"
    fail=1
  elif ! printf '%s\n' "$_matrix_err" | grep -Fq "$_matrix_want"; then
    err "FAIL: $_matrix_var refused a $_matrix_class value, but not through the $_matrix_class check"
    err "$_matrix_err"
    fail=1
  fi
}

while IFS='|' read -r matrix_var matrix_class matrix_optional; do
  [ -n "$matrix_var" ] || continue
  check_table_rejection "$matrix_var" "$matrix_class" "$matrix_optional"
done <<'CASES'
UPS_NAME|control|0
UPS_NAME|quote|0
UPS_NAME|bracket|0
UPS_NAME|identifier|0
UPS_DESC|control|0
UPS_DESC|quote|0
UPS_DESC|backslash|0
UPS_DESC|hash|0
UPS_DRIVER|control|0
UPS_DRIVER|identifier|0
UPS_PORT|control|0
UPS_PORT|backslash|0
UPS_PORT|hash|0
API_USER|control|0
API_USER|bracket|0
API_PASSWORD|control|0
API_PASSWORD|quote|0
API_PASSWORD|backslash|0
API_PASSWORD|hash|0
API_PASSWORD|nut_word|0
API_ADDRESS|control|0
API_ADDRESS|quote|0
API_ADDRESS|backslash|0
API_ADDRESS|bracket|0
API_ADDRESS|hash|0
API_PORT|control|0
API_PORT|port|0
DBUS_PROBE_INTERVAL|control|0
POLLFREQ|control|0
POLLFREQALERT|control|0
DEADTIME|control|0
FINALDELAY|control|0
HOSTSYNC|control|0
NOCOMMWARNTIME|control|0
RBWARNTIME|control|0
COMMS_CHECK_INTERVAL|control|0
COMMS_RECOVERY_TIMEOUT|control|0
COMMS_FAST_RETRIES|control|0
COMMS_BACKOFF_FACTOR|control|0
API_TLS|control|0
ADMIN_PASSWORD|control|0
ADMIN_PASSWORD|quote|0
ADMIN_PASSWORD|backslash|0
ADMIN_PASSWORD|hash|0
ADMIN_PASSWORD|nut_word|0
SHUTDOWN_ON_BATTERY_CRITICAL|control|0
DBUS_PROBE_INTERVAL|numeric|0
POLLFREQ|positive|0
POLLFREQALERT|positive|0
DEADTIME|positive|0
FINALDELAY|numeric|0
HOSTSYNC|numeric|0
NOCOMMWARNTIME|numeric|0
RBWARNTIME|numeric|0
COMMS_WATCHDOG|control|0
COMMS_CHECK_INTERVAL|numeric|0
COMMS_RECOVERY_TIMEOUT|positive|0
COMMS_FAST_RETRIES|positive|0
COMMS_BACKOFF_FACTOR|positive|0
LOWBATT_PERCENT|control|1
LOWBATT_PERCENT|percent|1
LOWBATT_RUNTIME|control|1
LOWBATT_RUNTIME|numeric|1
CASES

while IFS='|' read -r _ws_var _ws_value; do
  [ -n "$_ws_var" ] || continue
  if _ws_out=$(
    (
      UPS_DRIVER=usbhid-ups
      UPS_PORT=auto
      API_ADDRESS=0.0.0.0
      export "$_ws_var=$_ws_value"
      run_validations
    ) 2>&1
  ); then
    err "FAIL: $_ws_var accepted embedded whitespace: $_ws_value"
    fail=1
  elif ! printf '%s\n' "$_ws_out" | grep -Fq 'msg="env var contains whitespace"' \
    || ! printf '%s\n' "$_ws_out" | grep -Fq "var=$_ws_var"; then
    err "FAIL: $_ws_var was not refused by its whitespace boundary"
    err "$_ws_out"
    fail=1
  fi
done <<'CASES'
UPS_PORT|/dev/ttyS0 extra
API_ADDRESS|0.0.0.0 4444
CASES

if (
  UPS_NAME='bad]name'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: bracket-injection UPS_NAME was accepted"
  fail=1
fi
# Bracketed IPv6 must be rejected: bare IPv6 (::1) is the accepted spelling,
# because upsd_probe_host brackets colon-bearing hosts itself — accepting
# [::1] would double-bracket the probe ([[::1]]) and break the healthcheck.
if (
  API_ADDRESS='[::1]'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: bracketed-IPv6 API_ADDRESS was accepted"
  fail=1
fi
# UPS_NAME is the first getopt-parsed arg of every CLI consumer (healthcheck,
# comms_fresh, upsdrvctl); dash-leading parses as options, not a name.
if (
  UPS_NAME='-foo'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: dash-leading UPS_NAME was accepted"
  fail=1
fi
if (
  UPS_PORT='notapath'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: invalid UPS_PORT was accepted"
  fail=1
fi
if (
  API_PORT='70000'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: out-of-range API_PORT was accepted"
  fail=1
fi
# Digit strings beyond LONG_MAX make BusyBox test(1) error (status 2) instead
# of comparing, and an enclosing `if` swallows that — validate_numeric must
# reject >18 normalized digits before any range comparison runs.
if (
  API_PORT='9999999999999999999'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: overlong API_PORT (>18 digits) was accepted"
  fail=1
fi
# The stage-2 backoff threshold multiplies these two; each fits in 18 digits
# but the product would overflow $(( )), so run_validations must bound the pair.
if (
  COMMS_RECOVERY_TIMEOUT='999999999999999999'
  COMMS_BACKOFF_FACTOR='5'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: COMMS_RECOVERY_TIMEOUT x COMMS_BACKOFF_FACTOR product overflow was accepted"
  fail=1
fi
while IFS='|' read -r _dt_poll _dt_alert _dt_dead _dt_expect; do
  [ -n "$_dt_poll" ] || continue
  if _dt_out=$(
    (
      POLLFREQ="$_dt_poll"
      POLLFREQALERT="$_dt_alert"
      DEADTIME="$_dt_dead"
      run_validations
    ) 2>&1
  ); then
    if [ "$_dt_expect" = reject ]; then
      err "FAIL: DEADTIME=$_dt_dead accepted below POLLFREQ=$_dt_poll / POLLFREQALERT=$_dt_alert"
      fail=1
    fi
  elif [ "$_dt_expect" = accept ]; then
    err "FAIL: DEADTIME=$_dt_dead rejected at the larger poll interval ($_dt_poll / $_dt_alert)"
    err "$_dt_out"
    fail=1
  else
    _dt_norm_poll=$(strip_leading_zeros "$_dt_poll")
    _dt_norm_alert=$(strip_leading_zeros "$_dt_alert")
    _dt_norm_dead=$(strip_leading_zeros "$_dt_dead")
    if ! printf '%s\n' "$_dt_out" | grep -Fq 'DEADTIME must be at least the larger of POLLFREQ and POLLFREQALERT' \
      || ! printf '%s\n' "$_dt_out" | grep -Fq "deadtime=$_dt_norm_dead pollfreq=$_dt_norm_poll pollfreqalert=$_dt_norm_alert"; then
      err "FAIL: DEADTIME poll-floor refusal did not report the normalized cross-field diagnostic"
      err "$_dt_out"
      fail=1
    fi
  fi
done <<'CASES'
5|7|6|reject
7|5|6|reject
5|7|7|accept
7|5|7|accept
05|07|06|reject
05|07|07|accept
CASES
if (
  COMMS_CHECK_INTERVAL='notanumber'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: non-numeric COMMS_CHECK_INTERVAL was accepted"
  fail=1
fi
if (
  COMMS_BACKOFF_FACTOR='0'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: zero COMMS_BACKOFF_FACTOR was accepted (collapses stage-2 threshold; watchdog thrashes)"
  fail=1
fi
# A bare CR (0x0D) must be rejected: the old wc -l guard counted only LF, so a
# CR-only injection slipped through into a NUT config field unaltered.
if (
  UPS_DESC="$(printf 'desc\rinjected')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: CR-injection UPS_DESC was accepted"
  fail=1
fi
# A trailing backslash must be rejected: in a double-quoted NUT directive a
# backslash escapes the next character, so a trailing one escapes the closing
# quote and breaks out of the quoted context (config-quoting breakout).
if (
  API_PASSWORD="$(printf 'secret\134')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: backslash-injection API_PASSWORD was accepted"
  fail=1
fi
# A credential NUT will not preserve must be refused rather than stored altered:
# parseconf's addchar() silently discards bytes outside 0x20-0x7E (CVE-2012-2944).
if (
  API_PASSWORD="$(printf 'p\303\244ssword')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: a non-ASCII API_PASSWORD was accepted (NUT stores it with the byte dropped)"
  fail=1
fi
# API_USER is written unquoted as a `[$API_USER]` section header in upsd.users,
# so it gets the same identifier discipline as UPS_NAME.
if (
  API_USER='mon user'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: whitespace API_USER was accepted"
  fail=1
fi
# API_USER must not shadow a reserved generated account: a [$API_USER] section
# named like one would merge into the reserved stanza and clobber its
# credential ([admin] = set/FSD authority; [local_upsmon] = the bundled
# upsmon's `upsmon primary` credential).
if (
  API_USER='admin'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: API_USER=admin was accepted (reserved internal admin account)"
  fail=1
fi
if (
  API_USER='local_upsmon'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: API_USER=local_upsmon was accepted (reserved internal monitor account)"
  fail=1
fi
# snmp-ups takes a network endpoint: a host must pass, USB auto-detection must not.
if ! (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='192.168.1.50'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: snmp-ups with a host endpoint was rejected"
  fail=1
fi
if (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='auto'
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: snmp-ups with UPS_PORT=auto was accepted (auto is USB-only)"
  fail=1
fi
# A trailing LF on UPS_DRIVER must not dodge the transport check: raw
# "snmp-ups<LF>" fails driver_transport's literal case match and classifies
# as "other" (where auto is allowed), so canonicalization must strip it
# BEFORE run_validations for the network-transport rejection to fire.
if (
  UPS_DRIVER="$(printf 'snmp-ups\nx')"
  UPS_DRIVER=${UPS_DRIVER%x}
  UPS_PORT='auto'
  canonicalize_validated_values
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: trailing-LF snmp-ups with UPS_PORT=auto was accepted (canonicalization bypassed the transport check)"
  fail=1
fi
# log_value sanitizer contract: double quotes and backslashes do not survive;
# LF, CR, tab, BEL, and high bytes flatten to spaces; printable ASCII survives.
# This runs under BusyBox tr, whose complemented [:print:] class is not equivalent.
_log_value_input=$(printf 'val"with\\stuff\n\r\t\377and\007ctl')
_log_value_want='valwithstuff    and ctl'
_log_value_got=$(log_value "$_log_value_input")
if [ "$_log_value_got" != "$_log_value_want" ]; then
  err "FAIL: log_value byte contract: got '$_log_value_got', want '$_log_value_want'"
  fail=1
fi
_log_value_512=$(head -c 512 /dev/zero | tr '\0' a)
_log_value_600=$(head -c 600 /dev/zero | tr '\0' a)
_log_value_509=$(head -c 509 /dev/zero | tr '\0' a)
_log_value_long_want="${_log_value_509}..."
_log_value_512_got=$(log_value "$_log_value_512")
_log_value_600_got=$(log_value "$_log_value_600")
if [ "$_log_value_512_got" != "$_log_value_512" ]; then
  err "FAIL: log_value truncated a 512-character value"
  fail=1
fi
if [ "$_log_value_600_got" != "$_log_value_long_want" ]; then
  err "FAIL: log_value did not cap a long value at 509 characters plus ellipsis"
  fail=1
fi

STANDALONE_OUT=$(mktemp)
STANDALONE_ERR=$(mktemp)
if ! sh -c '
  . "$1"
  command -v upsd_probe_host >/dev/null 2>&1
  API_ADDRESS=0.0.0.0
  [ "$(upsd_probe_host)" = "127.0.0.1" ]
' sh /usr/local/bin/lifecycle.sh >"$STANDALONE_OUT" 2>"$STANDALONE_ERR"; then
  err "FAIL: lifecycle.sh could not be sourced alone by the healthcheck shell"
  err "$(head -c 512 "$STANDALONE_ERR")"
  fail=1
elif [ -s "$STANDALONE_OUT" ] || [ -s "$STANDALONE_ERR" ]; then
  err "FAIL: sourcing lifecycle.sh alone emitted output"
  err "stdout=$(head -c 256 "$STANDALONE_OUT") stderr=$(head -c 256 "$STANDALONE_ERR")"
  fail=1
fi
rm -f "$STANDALONE_OUT" "$STANDALONE_ERR"

# The three NUT controls share Docker's 10-second stop grace. Drive the real
# sequence with a fake clock so a widened bound or an added control cannot push
# upsdrvctl stop past SIGKILL.
STOP_BUDGET_TRACE=$(mktemp)
(
  elapsed=0
  # Invoked indirectly by the extracted stop_nut_cmd path.
  # shellcheck disable=SC2329
  timeout() {
    if [ "${1-}" != "-s" ] || [ "${2-}" != "KILL" ]; then
      printf 'invalid\t%s\n' "$*" >>"$STOP_BUDGET_TRACE"
      return 0
    fi
    case "${3-}" in
      '' | *[!0-9]*)
        printf 'invalid\t%s\n' "$*" >>"$STOP_BUDGET_TRACE"
        return 0
        ;;
    esac
    delay=$3
    shift 3
    elapsed=$((elapsed + delay))
    printf 'ok\t%d\t%s\n' "$elapsed" "$*" >>"$STOP_BUDGET_TRACE"
  }
  stop_services 2>/dev/null
)
last_elapsed=$(awk -F '\t' '$1 == "ok" { value = $2 } END { print value }' "$STOP_BUDGET_TRACE")
upsdrv_elapsed=$(awk -F '\t' '$1 == "ok" && $3 == "/usr/sbin/upsdrvctl stop" { print $2; exit }' "$STOP_BUDGET_TRACE")
if grep -q '^invalid' "$STOP_BUDGET_TRACE"; then
  err "FAIL: a NUT stop control lost timeout -s KILL"
  fail=1
elif printf '%s\n%s\n' "$last_elapsed" "$upsdrv_elapsed" | grep -Eqv '^[0-9]+$'; then
  err "FAIL: the bounded stop sequence or upsdrvctl stop was not observed"
  fail=1
elif [ "$last_elapsed" -ge 10 ] || [ "$upsdrv_elapsed" -ge 10 ]; then
  err "FAIL: NUT stop sequence exceeds Docker's 10s grace (total=${last_elapsed}s upsdrvctl=${upsdrv_elapsed}s)"
  fail=1
fi
rm -f "$STOP_BUDGET_TRACE"

# Capture cleanup preserves /dev/null on allocation failure but removes real paths.
CAPTURE_RM_CALLS=$(mktemp)
CAPTURE_MODE=fail
# shellcheck disable=SC2329  # the stubs are invoked indirectly by the capture helpers
mktemp() {
  if [ "$CAPTURE_MODE" = "fail" ]; then
    return 1
  fi
  printf '%s' /var/run/nut-secrets/capture-test.real
}
# shellcheck disable=SC2329  # invoked indirectly by capture_cleanup
rm() {
  printf '%s\n' "$*" >>"$CAPTURE_RM_CALLS"
  return 0
}
capture_path=$(capture_tmpfile /var/run/nut-secrets/capture-test)
capture_cleanup "$capture_path"
if [ "$capture_path" != "/dev/null" ] || [ -s "$CAPTURE_RM_CALLS" ]; then
  err "FAIL: capture cleanup attempted to unlink the /dev/null fallback"
  fail=1
fi
CAPTURE_MODE=success
capture_path=$(capture_tmpfile /var/run/nut-secrets/capture-test)
capture_cleanup "$capture_path"
if [ "$capture_path" != "/var/run/nut-secrets/capture-test.real" ] \
  || ! grep -qx -- '-f /var/run/nut-secrets/capture-test.real' "$CAPTURE_RM_CALLS"; then
  err "FAIL: capture cleanup did not remove a real capture path"
  fail=1
fi
unset -f mktemp rm
rm -f "$CAPTURE_RM_CALLS"

#    read_pidfile: race-safe pidfile reads. A regular nut-readable file's
#    content comes back through the BusyBox `su` privilege drop (real NUT
#    pidfiles are nut-owned, so the fixture is chowned to nut explicitly —
#    readability under the drop must not depend on the build stage's umask);
#    a planted symlink and a FIFO are both refused. The FIFO has no writer,
#    so this block completing at all also proves the read path cannot block
#    on a raced special file.
printf '12345' >/var/run/nut/rp-regular.pid
chown nut:nut /var/run/nut/rp-regular.pid
if [ "$(read_pidfile /var/run/nut/rp-regular.pid)" != "12345" ]; then
  err "FAIL: read_pidfile did not return the content of a regular pidfile"
  fail=1
fi
printf 'root-only' >/var/run/nut-secrets/rp-secret
ln -s /var/run/nut-secrets/rp-secret /var/run/nut/rp-symlink.pid
if [ -n "$(read_pidfile /var/run/nut/rp-symlink.pid)" ]; then
  err "FAIL: read_pidfile followed a planted symlink"
  fail=1
fi
mkfifo /var/run/nut/rp-fifo.pid
if [ -n "$(read_pidfile /var/run/nut/rp-fifo.pid)" ]; then
  err "FAIL: read_pidfile read from a FIFO"
  fail=1
fi
rm -f /var/run/nut/rp-regular.pid /var/run/nut/rp-symlink.pid \
  /var/run/nut/rp-fifo.pid /var/run/nut-secrets/rp-secret

#    pid_matches_binary: kernel-truth identity match for a live PID whose exe
#    link is readable (this build-stage shell is dumpable, so it is); a
#    mismatched binary must be refused. The comm fallback branch (exe
#    unreadable for the non-dumpable setuid NUT daemons under default Docker
#    caps) needs a real daemon boot and is exercised by the runtime
#    healthcheck/watchdog paths, not at build time.
if ! pid_matches_binary $$ /bin/busybox; then
  err "FAIL: pid_matches_binary rejected this shell as a /bin/busybox instance"
  fail=1
fi
if pid_matches_binary $$ /usr/sbin/upsd; then
  err "FAIL: pid_matches_binary accepted a binary this shell is not"
  fail=1
fi

#    upsd_probe_host maps ONLY the wildcard binds to loopback; specific IPv4
#    binds — including 127.0.0.2-style loopback addresses that a 127.0.0.1
#    probe cannot reach, and the name "localhost", which upsd binds to only
#    the first address it resolves to — pass through unchanged, specific IPv6
#    literals gain NUT's documented brackets ([::1], [2001:db8::1]), and the
#    :: wildcard maps to the bracketed loopback [::1]. Guards the shared
#    helper against regressing to address-family-wide rewriting (the
#    Dockerfile HEALTHCHECK sources this same helper, so these cases
#    directly cover the healthcheck mapping).
for spec in '0.0.0.0=127.0.0.1' 'localhost=localhost' '::=[::1]' \
  '::1=[::1]' '2001:db8::1=[2001:db8::1]' \
  '127.0.0.2=127.0.0.2' '192.168.1.5=192.168.1.5'; do
  addr=${spec%%=*}
  want=${spec#*=}
  got=$(API_ADDRESS="$addr" upsd_probe_host)
  if [ "$got" != "$want" ]; then
    err "FAIL: upsd_probe_host mapped API_ADDRESS=$addr to '$got' (want '$want')"
    fail=1
  fi
done

# A server with stale driver data still answers LIST UPS and must remain alive.
PROBE_CALLS=$(mktemp)
PROBE_EXPECTED=$(mktemp)
# shellcheck disable=SC2329  # the stubs are invoked indirectly by the probe helpers
timeout() {
  _probe_bound=$1
  shift
  printf 'timeout=%s command=%s\n' "$_probe_bound" "$*" >>"$PROBE_CALLS"
  "$@"
}
# shellcheck disable=SC2329  # invoked indirectly, via the timeout stub above
upsc() {
  printf 'upsc %s\n' "$*" >>"$PROBE_CALLS"
  [ "$1" = "-l" ] && return 0
  [ "${2:-}" = "ups.status" ] && return 1
  return 2
}
if comms_fresh; then
  err "FAIL: comms_fresh accepted an ups.status read modeled as stale"
  fail=1
fi
if ! upsd_responsive; then
  err "FAIL: upsd_responsive conflated protocol liveness with stale driver data"
  fail=1
fi
cat >"$PROBE_EXPECTED" <<'EOF'
timeout=3 command=upsc ups@127.0.0.1:3493 ups.status
upsc ups@127.0.0.1:3493 ups.status
timeout=5 command=upsc -l 127.0.0.1:3493
upsc -l 127.0.0.1:3493
EOF
if ! cmp -s "$PROBE_EXPECTED" "$PROBE_CALLS"; then
  err "FAIL: freshness and supervision probes did not use their distinct bounded NUT queries"
  err "$(tr '\n' '|' <"$PROBE_CALLS")"
  fail=1
fi
unset -f timeout upsc
rm -f "$PROBE_CALLS" "$PROBE_EXPECTED"

# 5. Watchdog behavior, driven through the injectable seams (comms_fresh,
#    sleep, watchdog_epoch) with a fake clock — no real waiting.
#
#    Cadence and budget with the defaults (check=15, recovery=90,
#    fast_retries=3, backoff=5): stale from t=15 on, fast attempts fire at
#    t=105/210/315, then the stage-2 threshold (450s) delays attempts 4 and 5
#    to t=780/1245.
WATCHDOG_ERR=$(mktemp)
RESTART_LOG=$(mktemp)
# shellcheck disable=SC2329  # the stubs are invoked indirectly by comms_watchdog
(
  _FAKE_NOW=0
  watchdog_epoch() { printf '%s' "$_FAKE_NOW"; }
  # Advance fake time by the check interval (15, matching the exported env)
  # instead of waiting; end the scenario past t=1300.
  sleep() {
    _FAKE_NOW=$((_FAKE_NOW + 15))
    [ "$_FAKE_NOW" -le 1300 ] || exit 0
  }
  comms_fresh() { return 1; }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$_FAKE_NOW" >>"$RESTART_LOG"
    return 0
  }
  comms_watchdog
) 2>"$WATCHDOG_ERR"
attempts=$(($(wc -l <"$RESTART_LOG")))
if [ "$attempts" -ne 5 ]; then
  err "FAIL: watchdog cadence: expected 5 restart attempts by t=1300, got $attempts"
  fail=1
else
  t1=$(awk 'NR==1{print $2}' "$RESTART_LOG")
  t2=$(awk 'NR==2{print $2}' "$RESTART_LOG")
  t3=$(awk 'NR==3{print $2}' "$RESTART_LOG")
  t4=$(awk 'NR==4{print $2}' "$RESTART_LOG")
  if [ $((t2 - t1)) -gt 120 ]; then
    err "FAIL: fast-stage attempts not on the fast cadence (t1=$t1 t2=$t2)"
    fail=1
  fi
  if [ $((t4 - t3)) -lt 450 ]; then
    err "FAIL: stage-2 attempt did not back off (t3=$t3 t4=$t4, want >=450s gap)"
    fail=1
  fi
fi
rm -f "$WATCHDOG_ERR" "$RESTART_LOG"

# A transient clock failure skips one stale tick without killing recovery.
CLOCK_ERR=$(mktemp)
CLOCK_RESTARTS=$(mktemp)
set +e
# shellcheck disable=SC2329  # the stubs are invoked indirectly by comms_watchdog
(
  _CLOCK_TICK=0
  sleep() {
    _CLOCK_TICK=$((_CLOCK_TICK + 1))
    [ "$_CLOCK_TICK" -le 4 ] || exit 0
  }
  comms_fresh() { return 1; }
  watchdog_epoch() {
    case "$_CLOCK_TICK" in
      1) printf '0' ;;
      2) return 1 ;;
      3) printf '5' ;;
      4) printf '10' ;;
    esac
  }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$_CLOCK_TICK" >>"$CLOCK_RESTARTS"
    return 0
  }
  COMMS_CHECK_INTERVAL=1
  COMMS_RECOVERY_TIMEOUT=10
  set -eu
  comms_watchdog
) 2>"$CLOCK_ERR"
clock_rc=$?
set -e
if [ "$clock_rc" -ne 0 ] \
  || [ "$(grep -c 'clock read failed; skipping tick' "$CLOCK_ERR")" -ne 1 ] \
  || [ "$(cat "$CLOCK_RESTARTS")" != "1 4" ]; then
  err "FAIL: a clock-read failure killed or reset the comms watchdog"
  err "rc=$clock_rc restarts=$(tr '\n' '|' <"$CLOCK_RESTARTS") log=$(tr '\n' '|' <"$CLOCK_ERR")"
  fail=1
fi
rm -f "$CLOCK_ERR" "$CLOCK_RESTARTS"

#    Recovery resets both the stale window and the restart budget: stale from
#    t=15 (attempt 1 at t=105), fresh during t=150-299 (recovery logged),
#    stale again from t=300 — the next attempt must be numbered 1 again.
WATCHDOG_ERR=$(mktemp)
RESTART_LOG=$(mktemp)
# shellcheck disable=SC2329  # the stubs are invoked indirectly by comms_watchdog
(
  _FAKE_NOW=0
  watchdog_epoch() { printf '%s' "$_FAKE_NOW"; }
  sleep() {
    _FAKE_NOW=$((_FAKE_NOW + 15))
    [ "$_FAKE_NOW" -le 400 ] || exit 0
  }
  comms_fresh() { [ "$_FAKE_NOW" -ge 150 ] && [ "$_FAKE_NOW" -lt 300 ]; }
  restart_ups_driver() {
    printf '%s %s\n' "$1" "$_FAKE_NOW" >>"$RESTART_LOG"
    return 0
  }
  comms_watchdog
) 2>"$WATCHDOG_ERR"
if ! grep -q 'comms watchdog UPS comms recovered.*restarts=1' "$WATCHDOG_ERR"; then
  err "FAIL: watchdog recovery not logged after comms returned"
  fail=1
fi
second_attempt_no=$(awk 'NR==2{print $1}' "$RESTART_LOG")
if [ "${second_attempt_no:-}" != "1" ]; then
  err "FAIL: restart budget not reset after recovery (second attempt numbered ${second_attempt_no:-none})"
  fail=1
fi
rm -f "$WATCHDOG_ERR" "$RESTART_LOG"

#    Killpower stand-down: with host shutdown armed and NUT's POWERDOWNFLAG
#    present, the real restart_ups_driver must stand down (rc!=0, no driver
#    bounce) so a recovery can't fight a poweroff in progress.
KILLPOWER_ERR=$(mktemp)
if (
  # shellcheck disable=SC2034  # consumed by restart_ups_driver (sourced lifecycle.sh)
  SHUTDOWN_ON_BATTERY_CRITICAL=true
  touch "$POWERDOWNFLAG_FILE"
  restart_ups_driver 1
) 2>"$KILLPOWER_ERR"; then
  err "FAIL: restart_ups_driver did not stand down with killpower set"
  fail=1
fi
rm -f "$POWERDOWNFLAG_FILE"
if ! grep -q 'standing down' "$KILLPOWER_ERR"; then
  err "FAIL: killpower stand-down not logged"
  fail=1
fi
rm -f "$KILLPOWER_ERR"

# 6. Transport classification and device/D-Bus gates.
if ! (
  UPS_DRIVER='snmp-ups'
  [ "$(driver_transport)" = "net" ]
); then
  err "FAIL: snmp-ups not classified as a network transport"
  fail=1
fi
if ! (
  UPS_DRIVER='usbhid-ups'
  [ "$(driver_transport)" = "usb" ]
); then
  err "FAIL: usbhid-ups not classified as a USB transport"
  fail=1
fi
if (
  UPS_DRIVER='snmp-ups'
  UPS_PORT='192.168.1.50'
  usb_bus_required
); then
  err "FAIL: usb_bus_required claims snmp-ups needs the USB bus"
  fail=1
fi
if ! (
  UPS_DRIVER='usbhid-ups'
  UPS_PORT='auto'
  usb_bus_required
); then
  err "FAIL: usb_bus_required denies the bus to usbhid-ups"
  fail=1
fi
if (
  UPS_DRIVER='apc_modbus'
  UPS_PORT='/dev/ttyUSB0'
  usb_bus_required
); then
  err "FAIL: usb_bus_required claims a serial node needs the USB bus"
  fail=1
fi
if ! (
  UPS_DRIVER='apc_modbus'
  UPS_PORT='auto'
  usb_bus_required
); then
  err "FAIL: usb_bus_required denies the bus to a dual-mode driver on auto"
  fail=1
fi
if ! (
  UPS_DRIVER='apc_modbus'
  UPS_PORT='/dev/bus/usb/001/003'
  usb_bus_required
); then
  err "FAIL: usb_bus_required denies the bus to a dual-mode driver using a USB bus node"
  fail=1
fi
# No D-Bus socket is mounted in the test stage, so the poweroff-path gate
# must report broken.
if dbus_poweroff_path_ok; then
  err "FAIL: dbus_poweroff_path_ok returned success without a mounted D-Bus socket"
  fail=1
fi

# 7. TLS (STARTTLS) support — resolve_tls_cert / generate_upsd_conf
#    (password.sh, generate-config.sh). Section 2 already provisioned the
#    self-signed cert and asserted the CERTFILE/DISABLE_WEAK_SSL directives.
#
#    The self-signed PEM: cache and nut-readable working copy both exist, the
#    cert parses, and cert + private key live in the ONE file NUT's OpenSSL
#    backend expects (docs/security.txt layout: certificate first, then key).
for pem in /var/run/nut-secrets/upsd-selfsigned.pem /etc/nut/upsd-selfsigned.pem; do
  if ! openssl x509 -in "$pem" -noout 2>/dev/null; then
    err "FAIL: self-signed PEM missing or certificate does not parse: $pem"
    fail=1
  fi
  if ! openssl pkey -in "$pem" -noout 2>/dev/null; then
    err "FAIL: self-signed PEM missing the private key: $pem"
    fail=1
  fi
done
# upsd reads CERTFILE as the dropped nut user (ssl_init runs after
# become_user), so the working copy must be root:nut 640 — and the root-only
# cache must NOT be group-readable.
if [ "$(stat -c '%U:%G %a' /etc/nut/upsd-selfsigned.pem)" != "root:nut 640" ]; then
  err "FAIL: /etc/nut/upsd-selfsigned.pem is not root:nut 640 (got '$(stat -c '%U:%G %a' /etc/nut/upsd-selfsigned.pem)')"
  fail=1
fi
if [ "$(stat -c '%U:%G %a' /var/run/nut-secrets/upsd-selfsigned.pem)" != "root:root 600" ]; then
  err "FAIL: cached self-signed PEM is not root:root 600 (got '$(stat -c '%U:%G %a' /var/run/nut-secrets/upsd-selfsigned.pem)')"
  fail=1
fi

#    Cache reuse: a second resolve must serve the SAME certificate (stable
#    across in-container restarts), not mint a new one.
tls_fp_first=$(tls_cert_fingerprint /var/run/nut-secrets/upsd-selfsigned.pem)
if ! resolve_tls_cert 2>/dev/null; then
  err "FAIL: resolve_tls_cert failed on a warm cache"
  fail=1
fi
if [ -z "$tls_fp_first" ] || [ "$(tls_cert_fingerprint /var/run/nut-secrets/upsd-selfsigned.pem)" != "$tls_fp_first" ]; then
  err "FAIL: resolve_tls_cert did not reuse the cached certificate (fingerprint changed)"
  fail=1
fi

#    Invalid cache: corrupt it and resolve again — must regenerate a parsing
#    PEM with a NEW fingerprint rather than serve the corrupted file.
printf 'not a pem\n' >/var/run/nut-secrets/upsd-selfsigned.pem
if ! resolve_tls_cert 2>/dev/null; then
  err "FAIL: resolve_tls_cert failed to regenerate over a corrupted cache"
  fail=1
fi
tls_fp_regen=$(tls_cert_fingerprint /var/run/nut-secrets/upsd-selfsigned.pem)
if [ -z "$tls_fp_regen" ] || [ "$tls_fp_regen" = "$tls_fp_first" ]; then
  err "FAIL: corrupted TLS cache was not regenerated (fingerprint '$tls_fp_regen')"
  fail=1
fi

# A parseable certificate inside the 24-hour horizon must not be reused from the
# self-signed cache; the same operator-mounted PEM remains usable but warns.
tls_exp_key=$(mktemp)
tls_exp_crt=$(mktemp)
tls_exp_pem=$(mktemp)
tls_exp_err=$(mktemp)
if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$tls_exp_key" -out "$tls_exp_crt" -days 1 -nodes \
  -subj '/CN=nut-upsd' -addext 'subjectAltName=DNS:nut-upsd' >/dev/null 2>&1 \
  || ! cat "$tls_exp_crt" "$tls_exp_key" >"$tls_exp_pem"; then
  err "FAIL: could not create the expiring TLS fixture"
  fail=1
elif ! tls_cert_parses "$tls_exp_pem" || tls_cert_fresh "$tls_exp_pem"; then
  err "FAIL: expiring TLS fixture does not isolate freshness from parsing"
  fail=1
else
  cp "$tls_exp_pem" /var/run/nut-secrets/upsd-selfsigned.pem
  tls_fp_expiring=$(tls_cert_fingerprint /var/run/nut-secrets/upsd-selfsigned.pem)
  : >"$tls_exp_err"
  if ! resolve_tls_cert 2>"$tls_exp_err"; then
    err "FAIL: resolve_tls_cert failed to replace an expiring cached certificate"
    fail=1
  else
    tls_fp_refreshed=$(tls_cert_fingerprint /var/run/nut-secrets/upsd-selfsigned.pem)
    if [ -z "$tls_fp_refreshed" ] || [ "$tls_fp_refreshed" = "$tls_fp_expiring" ]; then
      err "FAIL: expiring cached TLS certificate was reused instead of regenerated"
      fail=1
    fi
    if ! grep -q 'cached self-signed TLS certificate invalid or expiring; regenerating' "$tls_exp_err"; then
      err "FAIL: expiring cached TLS certificate did not log regeneration"
      fail=1
    fi
  fi

  cp "$tls_exp_pem" /etc/nut/upsd.pem
  : >"$tls_exp_err"
  if ! resolve_tls_cert 2>"$tls_exp_err"; then
    err "FAIL: resolve_tls_cert rejected an expiring operator-mounted certificate"
    fail=1
  else
    if ! grep -q 'mounted TLS certificate expires within a day' "$tls_exp_err"; then
      err "FAIL: expiring mounted TLS certificate did not log its warning"
      fail=1
    fi
    if [ "$TLS_CERT_PATH" != "/etc/nut/upsd-mounted.pem" ] \
      || ! cmp -s "$tls_exp_pem" /etc/nut/upsd-mounted.pem; then
      err "FAIL: expiring mounted TLS certificate was not served through its working copy"
      fail=1
    fi
  fi
  rm -f /etc/nut/upsd.pem /etc/nut/upsd-mounted.pem
fi
rm -f "$tls_exp_key" "$tls_exp_crt" "$tls_exp_pem" "$tls_exp_err"

#    Operator-mounted PEM (/etc/nut/upsd.pem): served via a root:nut 640
#    working copy at /etc/nut/upsd-mounted.pem — TLS_CERT_PATH points at the
#    copy (same content), and the MOUNT file itself is never touched: owner,
#    mode, and content stay exactly as the operator set them (the point of
#    the working-copy design — a 600 root:root read-only mount must work).
cp /var/run/nut-secrets/upsd-selfsigned.pem /etc/nut/upsd.pem
chown root:root /etc/nut/upsd.pem
chmod 600 /etc/nut/upsd.pem
tls_fp_mounted=$(tls_cert_fingerprint /etc/nut/upsd.pem)
# Exact-byte digest of the mount BEFORE resolution: the fingerprint above
# hashes only the first parsed certificate, so it proves cert identity but
# not that the private key / chain / trailing bytes survived untouched.
tls_sha_mounted=$(sha256sum /etc/nut/upsd.pem | awk '{print $1}')
if ! (
  resolve_tls_cert 2>/dev/null || exit 1
  [ "$TLS_CERT_PATH" = "/etc/nut/upsd-mounted.pem" ] || exit 1
  [ "$(tls_cert_fingerprint /etc/nut/upsd-mounted.pem)" = "$tls_fp_mounted" ]
); then
  err "FAIL: mounted /etc/nut/upsd.pem was not served via the /etc/nut/upsd-mounted.pem working copy"
  fail=1
fi
if [ "$(stat -c '%U:%G %a' /etc/nut/upsd-mounted.pem)" != "root:nut 640" ]; then
  err "FAIL: mounted-PEM working copy is not root:nut 640 (got '$(stat -c '%U:%G %a' /etc/nut/upsd-mounted.pem)')"
  fail=1
fi
if [ "$(stat -c '%U:%G %a' /etc/nut/upsd.pem)" != "root:root 600" ]; then
  err "FAIL: resolve_tls_cert mutated the mounted PEM's owner/mode (got '$(stat -c '%U:%G %a' /etc/nut/upsd.pem)', want the operator's root:root 600)"
  fail=1
fi
if [ "$(sha256sum /etc/nut/upsd.pem | awk '{print $1}')" != "$tls_sha_mounted" ]; then
  err "FAIL: resolve_tls_cert rewrote the mounted PEM's content"
  fail=1
fi
if ! (
  resolve_tls_cert >/dev/null 2>&1
  decide_user_overrides
  generate_all_configs >/dev/null 2>&1
  grep -q '^CERTFILE /etc/nut/upsd-mounted.pem$' /etc/nut/upsd.conf
); then
  err "FAIL: generated upsd.conf does not reference the mounted-PEM working copy"
  fail=1
fi
rm -f /etc/nut/upsd.pem /etc/nut/upsd-mounted.pem

#    Non-regular mount refusal: a directory planted at /etc/nut/upsd.pem (what
#    Docker auto-creates when a host bind source is missing) must make
#    resolve_tls_cert fail fast with a clear error instead of hanging or
#    failing later at ssl_init with a misleading perms error.
mkdir /etc/nut/upsd.pem
NONREG_ERR=$(mktemp)
if (resolve_tls_cert) 2>"$NONREG_ERR"; then
  err "FAIL: resolve_tls_cert accepted a directory at /etc/nut/upsd.pem"
  fail=1
fi
if ! grep -q 'level=error msg="mounted TLS certificate path is not a regular file' "$NONREG_ERR"; then
  err "FAIL: directory at /etc/nut/upsd.pem was not refused with the not-a-regular-file error"
  fail=1
fi
rmdir /etc/nut/upsd.pem
rm -f "$NONREG_ERR"

#    Unparseable mounted PEM: fatal — resolve_tls_cert must log the parse error
#    and refuse to publish a working copy.
printf 'not a pem\n' >/etc/nut/upsd.pem
tls_sha_badpem=$(sha256sum /etc/nut/upsd.pem | awk '{print $1}')
BADPEM_ERR=$(mktemp)
if resolve_tls_cert 2>"$BADPEM_ERR"; then
  err "FAIL: resolve_tls_cert accepted an unparseable mounted PEM"
  fail=1
fi
if [ "$(sha256sum /etc/nut/upsd.pem | awk '{print $1}')" != "$tls_sha_badpem" ]; then
  err "FAIL: resolve_tls_cert rewrote the unparseable mounted PEM"
  fail=1
fi
if [ -e /etc/nut/upsd-mounted.pem ]; then
  err "FAIL: resolve_tls_cert published a working copy of an unparseable mounted PEM"
  fail=1
fi
if ! grep -q 'level=error msg="mounted TLS certificate is not one PEM holding a certificate and its private key' "$BADPEM_ERR"; then
  err "FAIL: unparseable mounted PEM did not log the parse error"
  fail=1
fi
rm -f /etc/nut/upsd.pem /etc/nut/upsd-mounted.pem "$BADPEM_ERR"

#    Working-copy reconciliation under a config override: a regular
#    upsd.conf.user must NOT suppress reconcile_tls_working_copies. With
#    API_TLS=true and no mounted PEM, a stale /etc/nut/upsd-mounted.pem left
#    by a previous lifecycle (mount removed) must be deleted after
#    self-signed selection, while the selected working copy survives.
printf '# operator override\nLISTEN 0.0.0.0 3493\n' >/etc/nut/upsd.conf.user
rm -f /etc/nut/upsd.pem
printf 'stale key material\n' >/etc/nut/upsd-mounted.pem
if ! (
  resolve_tls_cert 2>/dev/null || exit 1
  reconcile_tls_working_copies
  [ "$TLS_CERT_PATH" = "/etc/nut/upsd-selfsigned.pem" ]
); then
  err "FAIL: reconcile under an upsd.conf.user override did not select the self-signed working copy"
  fail=1
fi
if [ ! -f /etc/nut/upsd-selfsigned.pem ]; then
  err "FAIL: reconciliation removed the selected self-signed working copy"
  fail=1
fi
if [ -e /etc/nut/upsd-mounted.pem ]; then
  err "FAIL: stale /etc/nut/upsd-mounted.pem survived reconciliation under an upsd.conf.user override"
  fail=1
fi
rm -f /etc/nut/upsd.conf.user /etc/nut/upsd-mounted.pem

#    API_TLS=false removes BOTH managed working copies — withdrawn
#    private-key material must not persist nut-readable in the writable
#    layer, even with an override mounted.
printf '# operator override\nLISTEN 0.0.0.0 3493\n' >/etc/nut/upsd.conf.user
printf 'stale self-signed copy\n' >/etc/nut/upsd-selfsigned.pem
printf 'stale mounted copy\n' >/etc/nut/upsd-mounted.pem
(
  API_TLS=false
  reconcile_tls_working_copies
)
if [ -e /etc/nut/upsd-selfsigned.pem ] || [ -e /etc/nut/upsd-mounted.pem ]; then
  err "FAIL: API_TLS=false reconciliation did not remove both managed TLS working copies"
  fail=1
fi
rm -f /etc/nut/upsd.conf.user /etc/nut/upsd-selfsigned.pem /etc/nut/upsd-mounted.pem

#    Directory planted at the working-copy path (the cache above is still
#    valid): plain mv would "install" the root:nut copy INSIDE the directory
#    (POSIX mv destination-directory semantics) and report success while upsd
#    later fails at ssl_init on a directory CERTFILE. _replace_file must
#    refuse it: resolve_tls_cert fails with the structured install error and
#    leaks no temp into the directory.
mkdir /etc/nut/upsd-selfsigned.pem
DIRDEST_ERR=$(mktemp)
if (resolve_tls_cert) 2>"$DIRDEST_ERR"; then
  err "FAIL: resolve_tls_cert reported success with a directory at the working-copy path"
  fail=1
fi
if ! grep -q 'level=error msg="failed to install TLS certificate working copy' "$DIRDEST_ERR"; then
  err "FAIL: directory at the working-copy path was not refused with the install error"
  fail=1
fi
if [ -n "$(ls -A /etc/nut/upsd-selfsigned.pem)" ]; then
  err "FAIL: temp file leaked inside the directory planted at the working-copy path"
  fail=1
fi
rmdir /etc/nut/upsd-selfsigned.pem
rm -f "$DIRDEST_ERR"

#    Directory planted at the self-signed cache path: plain mv would drop the
#    freshly assembled PEM INSIDE the directory and log generation success
#    with no usable cache. _replace_file must refuse it: resolve_tls_cert
#    fails with the structured generation error and leaks none of the three
#    temp files into the directory.
rm -f /var/run/nut-secrets/upsd-selfsigned.pem
mkdir /var/run/nut-secrets/upsd-selfsigned.pem
DIRDEST_ERR=$(mktemp)
if (resolve_tls_cert) 2>"$DIRDEST_ERR"; then
  err "FAIL: resolve_tls_cert reported success with a directory at the self-signed cache path"
  fail=1
fi
if ! grep -q 'level=error msg="self-signed TLS certificate generation failed' "$DIRDEST_ERR"; then
  err "FAIL: directory at the self-signed cache path was not refused with the generation error"
  fail=1
fi
if [ -n "$(ls -A /var/run/nut-secrets/upsd-selfsigned.pem)" ]; then
  err "FAIL: temp files leaked inside the directory planted at the self-signed cache path"
  fail=1
fi
rmdir /var/run/nut-secrets/upsd-selfsigned.pem
rm -f "$DIRDEST_ERR"

# Restore the baseline self-signed working copy for any later sections.
if ! resolve_tls_cert 2>/dev/null; then
  err "FAIL: could not restore the self-signed working copy after the reconcile cases"
  fail=1
fi

#    API_TLS=false: no TLS directives and no new cert — upsd.conf must be
#    byte-identical to the pre-TLS-feature output.
if ! (
  API_TLS=false
  decide_user_overrides
  generate_all_configs >/dev/null 2>&1
  printf 'LISTEN 0.0.0.0 3493\n' | cmp -s - /etc/nut/upsd.conf
); then
  err "FAIL: API_TLS=false upsd.conf is not byte-identical to the pre-TLS output"
  fail=1
fi

#    Boolean rejection: the table row guards injection (control chars), and the
#    entrypoint's normalize_bool — same convention as COMMS_WATCHDOG — refuses
#    unrecognized spellings so a security toggle cannot silently degrade.
if (
  API_TLS="$(printf 'true\ninjected')"
  run_validations
) >/dev/null 2>&1; then
  err "FAIL: newline-injection API_TLS was accepted"
  fail=1
fi
if normalize_bool API_TLS banana >/dev/null 2>&1; then
  err "FAIL: API_TLS=banana was accepted by normalize_bool"
  fail=1
fi

# 8. Embedded SBOM fragment (Dockerfile builder stage): the CycloneDX file
#    covering the source-built components must ship in the image, name all
#    three components with a version-shaped string each, and carry the
#    CVE-2026-54161 VEX entry for the backport. BusyBox has no jq, so assert
#    shape with grep: non-empty, starts with { and ends with }.
SBOM=/usr/share/sbom/nut-upsd.cdx.json
if [ ! -s "$SBOM" ]; then
  err "FAIL: embedded SBOM fragment missing or empty: $SBOM"
  fail=1
else
  if [ "$(head -c 1 "$SBOM")" != "{" ] || [ "$(tail -c 2 "$SBOM")" != "}" ]; then
    err "FAIL: embedded SBOM fragment is not a JSON object (bad first/last byte)"
    fail=1
  fi
  for comp in nut libmodbus net-snmp; do
    grep -q "\"name\": \"$comp\"" "$SBOM" || {
      err "FAIL: embedded SBOM fragment missing component: $comp"
      fail=1
    }
  done
  # Each component carries a version-shaped value (ARG-derived, leading v
  # stripped): assert three "version": "X.Y..." occurrences.
  # grep -c prints the count (0 included) even when it exits 1 on zero
  # matches; || true keeps set -e from aborting before the FAIL report.
  versions=$(grep -c '"version": "[0-9][0-9.]*"' "$SBOM" || true)
  if [ "$versions" -ne 3 ]; then
    err "FAIL: embedded SBOM fragment has $versions version-shaped component versions (want 3)"
    fail=1
  fi
  grep -q '"CVE-2026-54161"' "$SBOM" || {
    err "FAIL: embedded SBOM fragment missing the CVE-2026-54161 VEX entry"
    fail=1
  }
fi

# Restore the section-2 baseline configs for any future sections.
decide_user_overrides
generate_all_configs >/dev/null 2>&1

[ "$fail" -eq 0 ] && log "nut-upsd smoke: ok"
exit "$fail"
