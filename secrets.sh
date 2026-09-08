#!/bin/sh
# secrets.sh — credential and STARTTLS certificate resolution/caching, and the
# root:nut 640 staged install (_install_nut_config) every /etc/nut writer
# shares. Sourced by entrypoint.sh; not executed directly.

# base64 expands 3 raw bytes to 4 characters, so PASSWORD_LENGTH is derived at
# two thirds of PASSWORD_RAW_BYTES: ~2x headroom for the `/+=` stripping in
# _resolve_cached_password (worst of 300 measured draws: 5 of 48). Change the
# credential length by changing PASSWORD_RAW_BYTES.
readonly PASSWORD_RAW_BYTES=36
readonly PASSWORD_LENGTH=$((PASSWORD_RAW_BYTES * 2 / 3))
readonly PASSWORD_MIN_LENGTH=12

# Generated-credential cache paths (root-only /var/run/nut-secrets -- see
# _resolve_cached_password).
readonly ADMIN_PASSWORD_FILE=/var/run/nut-secrets/admin_password
readonly LOCAL_UPSMON_PASSWORD_FILE=/var/run/nut-secrets/local_upsmon_password

# _replace_file SRC DST CAUSE_VAR: atomic-install rename with a
# directory-destination guard, shared by every mktemp + rename site below.
# Plain mv treats an existing directory at DST as a container (POSIX mv
# destination-directory semantics), so a stale or Docker-created directory at
# a cache or working-copy path would silently break the file-at-DST contract.
_replace_file() {
  _rf_src="$1"
  _rf_dst="$2"
  _rf_cause_var="$3"
  if [ -d "$_rf_dst" ]; then
    _rf_err='destination is a directory; refusing to install file into it'
    eval "$_rf_cause_var=\$_rf_err"
    return 1
  fi
  if ! _rf_err=$(mv "$_rf_src" "$_rf_dst" 2>&1); then
    eval "$_rf_cause_var=\$_rf_err"
    return 1
  fi
}

# _install_nut_config SRC DST CAUSE_VAR: applies root:nut 640 to a staging
# file before its atomic rename, so the destination never has the wrong mode.
_install_nut_config() {
  _inc_src="$1"
  _inc_dst="$2"
  _inc_cause_var="$3"
  if ! _inc_err=$({ chown root:nut "$_inc_src" && chmod 640 "$_inc_src"; } 2>&1); then
    eval "$_inc_cause_var=\$_inc_err"
    return 1
  fi
  _replace_file "$_inc_src" "$_inc_dst" "$_inc_cause_var"
}

# _resolve_cached_password LABEL CACHE_FILE: shared engine for the credentials
# this container generates itself. Prints the resolved password on stdout;
# returns 1 when a strong password cannot be produced. The cache keeps the
# value stable across in-container restarts, in the root-only
# /var/run/nut-secrets runtime directory so the lower-privileged `nut`
# service user cannot pre-create or replace the temp/cache paths.
_resolve_cached_password() {
  _rcp_label="$1"
  _rcp_file="$2"
  _rcp_pw=""
  # `stat -L` follows, because `head` does: on a symlink a plain lstat
  # reports the link's own size, so a link to a longer file would serve a
  # truncated prefix of it as the credential.
  _rcp_size=$(stat -Lc %s "$_rcp_file" 2>/dev/null) || _rcp_size=""
  # Only generation's own output is trusted. The stat refuses a grown cache
  # (`head -c` would otherwise truncate it into a well-formed prefix of
  # itself); the length clause catches what the stat cannot, since command
  # substitution strips a trailing newline; the alphabet clause refuses the
  # quote, backslash and control bytes that break generate-config.sh's quoted
  # password field, and the whitespace that would pass as a weak credential.
  if [ "$_rcp_size" = "$PASSWORD_LENGTH" ] \
    && _rcp_pw=$(head -c "$PASSWORD_LENGTH" "$_rcp_file" 2>/dev/null) \
    && [ "${#_rcp_pw}" -eq "$PASSWORD_LENGTH" ] \
    && [ -z "$(printf '%s' "$_rcp_pw" | tr -d 'A-Za-z0-9')" ]; then
    printf 'level=info msg="reusing %s from container FS (not persisted across recreations)" path=%s\n' \
      "$_rcp_label" "$_rcp_file" >&2
    printf '%s' "$_rcp_pw"
    return 0
  fi
  if [ -s "$_rcp_file" ]; then
    printf 'level=warn msg="cached %s invalid (wrong size, shortened by trailing whitespace, unreadable, or not from the generated alphabet); regenerating" path=%s size=%s chars=%s expected=%s\n' \
      "$_rcp_label" "$_rcp_file" "${_rcp_size:-unreadable}" "${#_rcp_pw}" "$PASSWORD_LENGTH" >&2
  fi
  _rcp_pw=$(head -c "$PASSWORD_RAW_BYTES" /dev/urandom | base64 | tr -d '/+=' | head -c "$PASSWORD_LENGTH")
  # Never cache or use a short password: stripping `/+=` can in principle
  # leave fewer than PASSWORD_LENGTH characters. Fail loudly rather than
  # silently starting with weakened credentials.
  if [ "${#_rcp_pw}" -ne "$PASSWORD_LENGTH" ]; then
    printf 'level=error msg="generated %s has unexpected length; refusing weak credentials" got=%d expected=%d\n' \
      "$_rcp_label" "${#_rcp_pw}" "$PASSWORD_LENGTH" >&2
    return 1
  fi
  # mktemp in the root-only dir gives an O_EXCL, unpredictable temp name so
  # a compromised `nut` process cannot plant a symlink at the write target.
  _rcp_err=
  if ! _rcp_tmp=$(mktemp "${_rcp_file}.tmp.XXXXXX" 2>&1); then
    _rcp_err=$_rcp_tmp
    _rcp_tmp=
  fi
  if [ -n "$_rcp_tmp" ] \
    && _rcp_err=$(printf '%s' "$_rcp_pw" 2>&1 >"$_rcp_tmp") \
    && _replace_file "$_rcp_tmp" "$_rcp_file" _rcp_err; then
    printf 'level=info msg="generated %s; cached for intra-container restarts" path=%s\n' \
      "$_rcp_label" "$_rcp_file" >&2
  else
    rm -f "$_rcp_tmp" 2>/dev/null || true
    printf 'level=warn msg="generated %s but failed to cache; a new value will be generated on next restart" path=%s err="%s"\n' \
      "$_rcp_label" "$_rcp_file" "$(log_value "$_rcp_err")" >&2
  fi
  printf '%s' "$_rcp_pw"
}

# ADMIN_PASSWORD: cached at /var/run/nut-secrets/admin_password so it's stable
# across in-container restarts (see _resolve_cached_password). If the env var
# is non-empty, always use that value.
resolve_admin_password() {
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD=$(_resolve_cached_password ADMIN_PASSWORD "$ADMIN_PASSWORD_FILE") || return 1
  fi
}

# LOCAL_UPSMON_PASSWORD: secret of the reserved [local_upsmon] account — the
# bundled upsmon's own `upsmon primary` credential (see the credential-topology
# block in generate-config.sh). Purely internal: never taken from the
# environment, so any inherited LOCAL_UPSMON_PASSWORD env value is ignored and
# overwritten.
resolve_local_upsmon_password() {
  # shellcheck disable=SC2034  # consumed by sourced generate-config.sh
  LOCAL_UPSMON_PASSWORD=$(_resolve_cached_password LOCAL_UPSMON_PASSWORD "$LOCAL_UPSMON_PASSWORD_FILE") || return 1
}

withdraw_unused_credential_caches() {
  _wuc_files=''
  if user_override_present upsd.users; then
    _wuc_files="$ADMIN_PASSWORD_FILE"
  fi
  if ! local_upsmon_credential_active; then
    _wuc_files="$_wuc_files $LOCAL_UPSMON_PASSWORD_FILE"
  fi
  for _wuc_file in $_wuc_files; do
    _wuc_err=$(rm -f "$_wuc_file" 2>&1) || :
    if [ -e "$_wuc_file" ] || [ -L "$_wuc_file" ]; then
      printf 'level=warn msg="could not withdraw unused generated credential cache; continuing" path=%s err="%s"\n' \
        "$_wuc_file" "$(log_value "$_wuc_err")" >&2
    fi
  done
}

# Warn (don't block) when an operator-settable credential is shorter than
# PASSWORD_MIN_LENGTH. API_PASSWORD's default `secret` is caught by that
# length; ADMIN_PASSWORD has no default (unset auto-generates
# PASSWORD_LENGTH chars), so its arm fires only on an operator's short value.
warn_weak_api_password() {
  _wwp_api=$(nut_stored_word "$API_PASSWORD")
  if [ "${#_wwp_api}" -lt "$PASSWORD_MIN_LENGTH" ]; then
    printf 'level=warn msg="API_PASSWORD is weak (<%d chars; so is the shipped default). Acceptable on a trusted LAN; rotate it if your NUT client supports custom credentials."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
  case "$API_PASSWORD" in
    *[[:space:]]*)
      printf 'level=warn msg="API_PASSWORD contains whitespace; the bundled NUT clients send PASSWORD unquoted, so a client that does not quote it will fail to authenticate" var=API_PASSWORD\n' >&2
      ;;
  esac
}

warn_weak_admin_password() {
  _wwp_admin=$(nut_stored_word "$ADMIN_PASSWORD")
  if [ "${#_wwp_admin}" -lt "$PASSWORD_MIN_LENGTH" ]; then
    printf 'level=warn msg="ADMIN_PASSWORD is weak (<%d chars). It guards upsd set/FSD actions; use a longer value or unset it to auto-generate a strong one."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
  case "$ADMIN_PASSWORD" in
    *[[:space:]]*)
      printf 'level=warn msg="ADMIN_PASSWORD contains whitespace; the bundled NUT clients send PASSWORD unquoted, so a client that does not quote it will fail to authenticate" var=ADMIN_PASSWORD\n' >&2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# TLS (STARTTLS) server certificate resolution
# ---------------------------------------------------------------------------
# upsd's CERTFILE is ONE PEM: certificate then private key (NUT
# docs/security.txt) — hence _generate_selfsigned_cert's crt-then-key cat.
# upsd reads it as the dropped nut user, not root (ssl_init runs after
# become_user, server/upsd.c), so both sources install as a root:nut 640 copy
# in /etc/nut.
readonly TLS_CERT_MOUNT=/etc/nut/upsd.pem
readonly TLS_CERT_CACHE=/var/run/nut-secrets/upsd-selfsigned.pem
readonly TLS_CERT_RUNTIME=/etc/nut/upsd-selfsigned.pem
readonly TLS_CERT_MOUNTED_RUNTIME=/etc/nut/upsd-mounted.pem
readonly TLS_CERT_DAYS=825

# tls_cert_parses FILE: a certificate parses AND some private key parses, each on
# its own; correspondence between them is upsd's ssl_init (see tls_cert_valid).
# upsd fatalx()es on either half (server/netssl.c:715-722).
tls_cert_parses() {
  openssl x509 -in "$1" -noout >/dev/null 2>&1 \
    && openssl pkey -in "$1" -noout </dev/null >/dev/null 2>&1
}

# Every certificate in the file, not just the leaf: upsd loads the whole chain
# (SSL_CTX_use_certificate_chain_file) and checks no expiry on any of it.
tls_cert_fresh() {
  _tcf_n=$(grep -c 'BEGIN CERTIFICATE-' "$1") || return 1
  _tcf_i=1
  while [ "$_tcf_i" -le "$_tcf_n" ]; do
    awk -v want="$_tcf_i" '/BEGIN CERTIFICATE-/{c++} c==want' "$1" \
      | openssl x509 -noout -checkend 86400 >/dev/null 2>&1 || return 1
    _tcf_i=$((_tcf_i + 1))
  done
}

# tls_cert_valid FILE: the gate for reusing the cached self-signed PEM
# (regenerate on anything less). A certificate and key that parse but do not
# match each other pass; upsd's own ssl_init is what refuses that.
tls_cert_valid() {
  [ -f "$1" ] && tls_cert_parses "$1" && tls_cert_fresh "$1"
}

# tls_cert_fingerprint FILE: SHA-256 fingerprint of the first certificate in
# FILE (empty output when it does not parse).
tls_cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

# _tls_mktemp PREFIX: mktemp PREFIX.tmp.XXXXXX with a structured failure log
# (a bare `mktemp || return 1` would leave only mktemp's own unstructured
# stderr as the diagnostic).
_tls_mktemp() {
  mktemp "$1.tmp.XXXXXX" 2>/dev/null || {
    printf 'level=error msg="mktemp failed while provisioning the TLS certificate" prefix=%s\n' "$1" >&2
    return 1
  }
}

# _generate_selfsigned_cert: mint a fresh self-signed cert+key PEM into the
# root-only cache. EC P-256 over RSA 2048: keygen completes in milliseconds
# even on small ARM hosts. mktemp in the root-only dir gives O_EXCL 0600 temp
# files a compromised nut process cannot pre-plant; cert-then-key order is
# NUT's documented CERTFILE layout (`cat upsd.crt upsd.key > upsd.pem`).
_generate_selfsigned_cert() {
  _gc_key=$(_tls_mktemp "$TLS_CERT_CACHE") || return 1
  _gc_crt=$(_tls_mktemp "$TLS_CERT_CACHE") || {
    rm -f "$_gc_key"
    return 1
  }
  _gc_pem=$(_tls_mktemp "$TLS_CERT_CACHE") || {
    rm -f "$_gc_key" "$_gc_crt"
    return 1
  }
  if ! _gc_err=$(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$_gc_key" -out "$_gc_crt" -days "$TLS_CERT_DAYS" -nodes \
    -subj "/CN=nut-upsd" -addext "subjectAltName=DNS:nut-upsd" 2>&1 >/dev/null); then
    rm -f "$_gc_key" "$_gc_crt" "$_gc_pem"
    printf 'level=error msg="self-signed TLS certificate keygen failed" path=%s err="%s"\n' \
      "$TLS_CERT_CACHE" "$(log_value "$_gc_err")" >&2
    return 1
  fi
  if ! _gc_err=$(cat "$_gc_crt" "$_gc_key" 2>&1 >"$_gc_pem") \
    || ! _replace_file "$_gc_pem" "$TLS_CERT_CACHE" _gc_err; then
    rm -f "$_gc_key" "$_gc_crt" "$_gc_pem"
    printf 'level=error msg="self-signed TLS certificate generation failed" path=%s err="%s"\n' \
      "$TLS_CERT_CACHE" "$(log_value "$_gc_err")" >&2
    return 1
  fi
  rm -f "$_gc_key" "$_gc_crt"
  printf 'level=info msg="generated self-signed TLS certificate; cached for intra-container restarts (not persisted across recreations)" path=%s validity_days=%d\n' \
    "$TLS_CERT_CACHE" "$TLS_CERT_DAYS" >&2
}

# _install_cert_working_copy SRC DST: root:nut 640 working copy of SRC at DST.
# Shared by the self-signed path (cache -> TLS_CERT_RUNTIME) and the
# mounted-PEM path (mount -> TLS_CERT_MOUNTED_RUNTIME); only the copy is ever
# chowned, so an operator's bind mount is never mutated.
_install_cert_working_copy() {
  _ic_src="$1"
  _ic_dst="$2"
  _ic_tmp=$(_tls_mktemp "$_ic_dst") || return 1
  _ic_err=
  if _ic_err=$(cat "$_ic_src" 2>&1 >"$_ic_tmp") \
    && _install_nut_config "$_ic_tmp" "$_ic_dst" _ic_err; then
    return 0
  fi
  rm -f "$_ic_tmp"
  printf 'level=error msg="failed to install TLS certificate working copy for upsd" source=%s path=%s err="%s"\n' \
    "$_ic_src" "$_ic_dst" "$(log_value "$_ic_err")" >&2
  return 1
}

# resolve_tls_cert: point TLS_CERT_PATH (consumed by generate_upsd_conf) at the
# PEM this boot provisioned. Pre-flights what upsd cannot report (file type,
# dangling symlink, readability, expiry); upsd's own ssl_init is the authority
# on whether the certificate and key match (netssl.c:715-727). Runs whenever
# API_TLS=true — even with a mounted upsd.conf.user, whose author may reference
# either cert path. Returns 1 when no PEM could be provisioned (the entrypoint
# fails the boot: a TLS endpoint the operator left default-on must not silently
# degrade to cleartext).
resolve_tls_cert() {
  # -e follows the link, so a broken symlink at the mount path would
  # silently fall through to the self-signed certificate.
  if [ ! -e "$TLS_CERT_MOUNT" ] && [ -L "$TLS_CERT_MOUNT" ]; then
    printf 'level=warn msg="mounted TLS certificate path is a dangling symlink; ignoring it and provisioning the self-signed certificate" path=%s\n' "$TLS_CERT_MOUNT" >&2
  fi
  if [ -e "$TLS_CERT_MOUNT" ]; then
    # Refuse a non-regular mount (directory, FIFO, device node) up front: a
    # writer-less FIFO would block openssl/the working-copy cat forever with
    # no log line, and a directory (Docker auto-creates one when a host bind
    # source is missing) only fails later at ssl_init with a misleading
    # perms error.
    if [ ! -f "$TLS_CERT_MOUNT" ]; then
      printf 'level=error msg="mounted TLS certificate path is not a regular file (a missing host bind source makes Docker create a directory here); mount an existing PEM file or unset the mount" path=%s\n' \
        "$TLS_CERT_MOUNT" >&2
      return 1
    fi
    # Copy first, then validate the bytes upsd serves. This prevents a host
    # rewrite from making the verdict and fingerprint describe different bytes.
    # Only the root:nut 640 snapshot changes; a 600 root:root read-only mount
    # remains untouched.
    _install_cert_working_copy "$TLS_CERT_MOUNT" "$TLS_CERT_MOUNTED_RUNTIME" || return 1
    if ! tls_cert_parses "$TLS_CERT_MOUNTED_RUNTIME"; then
      rm -f "$TLS_CERT_MOUNTED_RUNTIME"
      printf 'level=error msg="mounted TLS certificate is not one PEM holding a certificate and its private key in a form openssl can read without a passphrase (upsd supplies none); upsd will exit at startup" path=%s\n' \
        "$TLS_CERT_MOUNT" >&2
      return 1
    elif ! tls_cert_fresh "$TLS_CERT_MOUNTED_RUNTIME"; then
      printf 'level=warn msg="a certificate block in the served TLS chain did not pass the expiry check (expired, expiring within a day, or unparseable); upsd'\''s own certificate loading decides whether it still serves" path=%s\n' \
        "$TLS_CERT_MOUNT" >&2
    fi
    TLS_CERT_PATH="$TLS_CERT_MOUNTED_RUNTIME"
    printf 'level=info msg="provisioned the operator-mounted TLS certificate as a working copy (the mount is never modified; a 600 root:root read-only mount is fine)" certfile=%s source=%s fingerprint="%s"\n' \
      "$TLS_CERT_MOUNTED_RUNTIME" "$TLS_CERT_MOUNT" "$(tls_cert_fingerprint "$TLS_CERT_MOUNTED_RUNTIME")" >&2
    return 0
  fi
  if tls_cert_valid "$TLS_CERT_CACHE"; then
    printf 'level=info msg="reusing cached self-signed TLS certificate (not persisted across recreations)" path=%s\n' \
      "$TLS_CERT_CACHE" >&2
  else
    if [ -s "$TLS_CERT_CACHE" ]; then
      printf 'level=warn msg="cached self-signed TLS certificate invalid or expiring; regenerating" path=%s\n' \
        "$TLS_CERT_CACHE" >&2
    fi
    _generate_selfsigned_cert || return 1
  fi
  _install_cert_working_copy "$TLS_CERT_CACHE" "$TLS_CERT_RUNTIME" || return 1
  # shellcheck disable=SC2034  # consumed by sourced generate-config.sh
  TLS_CERT_PATH="$TLS_CERT_RUNTIME"
  printf 'level=info msg="provisioned the self-signed TLS certificate" certfile=%s fingerprint="%s"\n' \
    "$TLS_CERT_RUNTIME" "$(tls_cert_fingerprint "$TLS_CERT_RUNTIME")" >&2
}

# reconcile_tls_working_copies: remove whichever managed working copies the
# current boot did not provision — always, even with an upsd.conf.user
# override mounted. Returns non-zero when a withdrawn working copy survives:
# the entrypoint calls this bare under set -e, so that status fails the boot.
reconcile_tls_working_copies() {
  if [ "$API_TLS" != "true" ]; then
    _rw_stale="$TLS_CERT_MOUNTED_RUNTIME $TLS_CERT_RUNTIME"
  elif [ "${TLS_CERT_PATH:-}" = "$TLS_CERT_MOUNTED_RUNTIME" ]; then
    _rw_stale="$TLS_CERT_RUNTIME"
  else
    _rw_stale="$TLS_CERT_MOUNTED_RUNTIME"
  fi
  # Managed paths are space-free readonly constants, so the word split is safe.
  _rw_failed=0
  for _rw_path in $_rw_stale; do
    if [ -e "$_rw_path" ] || [ -L "$_rw_path" ]; then
      _rw_present=1
    else
      _rw_present=0
    fi
    if ! _rw_err=$(rm -f "$_rw_path" 2>&1); then
      printf 'level=error msg="cannot remove unselected TLS working copy (something mounted over this internal path?); refusing to leave withdrawn key material in place" path=%s err="%s"\n' "$_rw_path" "$(log_value "$_rw_err")" >&2
      _rw_failed=1
    elif [ "$_rw_present" -eq 1 ]; then
      printf 'level=info msg="withdrew a TLS working copy this boot did not provision; an upsd.conf.user CERTFILE naming this path will fail at upsd startup" path=%s\n' \
        "$_rw_path" >&2
    fi
  done
  return "$_rw_failed"
}
