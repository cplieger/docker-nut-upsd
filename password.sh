#!/bin/sh
# password.sh — generated-credential resolution and caching logic
# (ADMIN_PASSWORD, the internal local_upsmon password, and the STARTTLS
# server certificate). Sourced by entrypoint.sh; not executed directly.

readonly PASSWORD_RAW_BYTES=36
readonly PASSWORD_LENGTH=24
readonly PASSWORD_MIN_LENGTH=12

# Generated-credential cache paths (root-only /var/run/nut-secrets -- see
# _resolve_cached_password).
readonly ADMIN_PASSWORD_FILE=/var/run/nut-secrets/admin_password
readonly LOCAL_UPSMON_PASSWORD_FILE=/var/run/nut-secrets/local_upsmon_password

# _replace_file SRC DST: atomic-install rename with a directory-destination
# guard, shared by every mktemp + rename site below. Plain mv treats an
# existing directory at DST as a container (POSIX mv destination-directory
# semantics): the rename "succeeds" by placing SRC INSIDE the directory, so a
# stale or Docker-created directory at a cache or working-copy path would
# silently break the file-at-DST contract while the caller logs success.
# Rejecting the directory up front routes such a boot through the caller's
# existing cleanup/warn/error branch instead.
_replace_file() {
  _rf_src="$1"
  _rf_dst="$2"
  if [ -d "$_rf_dst" ]; then
    printf 'level=warn msg="destination is a directory; refusing to install file into it" dst=%s\n' \
      "$_rf_dst" >&2
    return 1
  fi
  if ! _rf_err=$(mv "$_rf_src" "$_rf_dst" 2>&1); then
    printf 'level=warn msg="rename failed while installing file" dst=%s err="%s"\n' \
      "$_rf_dst" "$(log_value "$_rf_err")" >&2
    return 1
  fi
}

# _resolve_cached_password LABEL CACHE_FILE: shared engine for the credentials
# this container generates itself. Prints the resolved password on stdout (all
# logging goes to stderr); returns 1 when a strong password cannot be
# produced. The cache keeps the value stable across in-container restarts. It
# lives in the root-only /var/run/nut-secrets runtime directory (mode 700,
# owner root) so the lower-privileged `nut` service user cannot pre-create or
# replace the temp/cache paths (symlink/clobber hardening). The file lives in
# the container's writable layer and is lost on recreation (docker rm &&
# docker run, or any orchestrator redeploy).
_resolve_cached_password() {
  _rcp_label="$1"
  _rcp_file="$2"
  # Bounded, validated cache read: generation below always writes exactly
  # PASSWORD_LENGTH bytes, so only a cache of exactly that size is trusted,
  # and the read itself is capped at PASSWORD_LENGTH bytes. An unbounded
  # `cat` of a corrupted or grown cache in the reused writable layer would
  # let PID 1 consume memory proportional to the file and repeat the OOM on
  # every restart. Treat a whitespace-only cache as absent (self-heal):
  # POSIX command substitution strips trailing newlines, but spaces/tabs
  # would otherwise pass a length check and cache an unusable password.
  _rcp_size=$(stat -c %s "$_rcp_file" 2>/dev/null) || _rcp_size=""
  if [ "$_rcp_size" = "$PASSWORD_LENGTH" ] \
    && _rcp_pw=$(head -c "$PASSWORD_LENGTH" "$_rcp_file" 2>/dev/null) \
    && [ "${#_rcp_pw}" -eq "$PASSWORD_LENGTH" ] \
    && [ -n "$(printf '%s' "$_rcp_pw" | tr -d '[:space:]')" ]; then
    printf 'level=info msg="reusing %s from container FS (not persisted across recreations)" path=%s\n' \
      "$_rcp_label" "$_rcp_file" >&2
    printf '%s' "$_rcp_pw"
    return 0
  fi
  if [ -s "$_rcp_file" ]; then
    printf 'level=warn msg="cached %s invalid (wrong size, unreadable, or whitespace-only); regenerating" path=%s size=%s expected=%s\n' \
      "$_rcp_label" "$_rcp_file" "${_rcp_size:-unreadable}" "$PASSWORD_LENGTH" >&2
  fi
  # Pull more entropy than we need so stripping `/+=` still leaves
  # >=PASSWORD_LENGTH usable characters; head -c then gives a stable length.
  _rcp_pw=$(head -c "$PASSWORD_RAW_BYTES" /dev/urandom | base64 | tr -d '/+=' | head -c "$PASSWORD_LENGTH")
  # Never cache or use a short password: stripping `/+=` can in principle
  # leave fewer than PASSWORD_LENGTH characters, and a short read from
  # /dev/urandom would too. Fail loudly (entrypoint runs under set -e)
  # rather than silently starting with weakened credentials.
  if [ "${#_rcp_pw}" -ne "$PASSWORD_LENGTH" ]; then
    printf 'level=error msg="generated %s has unexpected length; refusing weak credentials" got=%d expected=%d\n' \
      "$_rcp_label" "${#_rcp_pw}" "$PASSWORD_LENGTH" >&2
    return 1
  fi
  # mktemp in the root-only dir gives an O_EXCL, unpredictable temp name so
  # a compromised `nut` process cannot plant a symlink at the write target.
  if _rcp_tmp=$(mktemp "${_rcp_file}.tmp.XXXXXX" 2>/dev/null) \
    && (umask 077 && printf '%s' "$_rcp_pw" >"$_rcp_tmp") && _replace_file "$_rcp_tmp" "$_rcp_file"; then
    printf 'level=info msg="generated %s; cached for intra-container restarts" path=%s\n' \
      "$_rcp_label" "$_rcp_file" >&2
  else
    rm -f "$_rcp_tmp" 2>/dev/null || true
    printf 'level=warn msg="generated %s but failed to cache; a new value will be generated on next restart" path=%s\n' \
      "$_rcp_label" "$_rcp_file" >&2
  fi
  printf '%s' "$_rcp_pw"
}

# ADMIN_PASSWORD: cached at /var/run/nut-secrets/admin_password so it's stable
# across in-container restarts (see _resolve_cached_password). If the env var
# is set, always use that value.
resolve_admin_password() {
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD=$(_resolve_cached_password ADMIN_PASSWORD "$ADMIN_PASSWORD_FILE") || return 1
  fi
}

# LOCAL_UPSMON_PASSWORD: secret of the reserved [local_upsmon] account — the
# bundled upsmon's own `upsmon primary` credential in the generated
# upsd.users/upsmon.conf pair (see the credential-topology block in
# generate-config.sh). Purely internal: it is never taken from the
# environment (there is nothing for an operator to configure; the *.user
# override files are the escape hatch), so any inherited LOCAL_UPSMON_PASSWORD
# env value is ignored and overwritten. Cached at
# /var/run/nut-secrets/local_upsmon_password exactly like ADMIN_PASSWORD.
resolve_local_upsmon_password() {
  # shellcheck disable=SC2034  # consumed by sourced generate-config.sh
  LOCAL_UPSMON_PASSWORD=$(_resolve_cached_password LOCAL_UPSMON_PASSWORD "$LOCAL_UPSMON_PASSWORD_FILE") || return 1
}

# Warn (don't block) on the well-known default credentials.
warn_weak_api_password() {
  if [ "$API_PASSWORD" = "secret" ] || [ "${#API_PASSWORD}" -lt "$PASSWORD_MIN_LENGTH" ]; then
    printf 'level=warn msg="API_PASSWORD is weak (default value or <%d chars). Acceptable on a trusted LAN; rotate it if your NUT client supports custom credentials."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
  if [ "${#ADMIN_PASSWORD}" -lt "$PASSWORD_MIN_LENGTH" ]; then
    printf 'level=warn msg="ADMIN_PASSWORD is weak (<%d chars). It guards upsd set/FSD actions; use a longer value or unset it to auto-generate a strong one."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
}

# ---------------------------------------------------------------------------
# TLS (STARTTLS) server certificate resolution
# ---------------------------------------------------------------------------
# upsd's CERTFILE is ONE PEM containing the server certificate followed by
# its private key (NUT docs/security.txt; the v2.8.x OpenSSL backend loads
# both from the same file). Precedence: an operator-mounted PEM at
# TLS_CERT_MOUNT wins (its content is authoritative and never regenerated or
# rewritten; it is copied to an internal working copy on every boot, so a
# rotated cert is picked up at restart); otherwise a self-signed PEM is
# generated at boot and cached at TLS_CERT_CACHE with the same hardening as
# the password caches above (root-only dir, mktemp + atomic rename), so it
# stays stable across in-container restarts.
#
# Placement subtlety: upsd reads CERTFILE as the dropped nut user, NOT root —
# ssl_init() runs after become_user() ("keyfile must be readable by nut
# user", server/upsd.c; docs/security.txt mandates root:nut 0640). The
# root-only /var/run/nut-secrets is unreadable to upsd by design, and the
# operator's mount must never be chowned/chmodded in place: on a rw bind
# mount that mutates the HOST file, handing the private key to whatever host
# group the container's nut GID happens to map to. So BOTH sources are
# installed as a root:nut 640 working copy inside /etc/nut (750 root:nut —
# the generated-config perms) and CERTFILE points at the copy: the
# self-signed cache at TLS_CERT_RUNTIME, the mounted PEM at
# TLS_CERT_MOUNTED_RUNTIME.
readonly TLS_CERT_MOUNT=/etc/nut/upsd.pem
readonly TLS_CERT_CACHE=/var/run/nut-secrets/upsd-selfsigned.pem
readonly TLS_CERT_RUNTIME=/etc/nut/upsd-selfsigned.pem
readonly TLS_CERT_MOUNTED_RUNTIME=/etc/nut/upsd-mounted.pem
readonly TLS_CERT_DAYS=825

# tls_cert_valid FILE: the first certificate parses and is not expiring
# within a day, and the private key parses — the sanity gate for reusing the
# cached self-signed PEM (regenerate on anything less).
tls_cert_valid() {
  openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1 \
    && openssl pkey -in "$1" -noout >/dev/null 2>&1
}

# tls_cert_fingerprint FILE: SHA-256 fingerprint of the first certificate in
# FILE (empty output when it does not parse).
tls_cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

# _tls_mktemp PREFIX: mktemp PREFIX.tmp.XXXXXX with a structured failure
# log. Every other failure exit in TLS provisioning logs level=error before
# the boot aborts; a bare `mktemp || return 1` would exit the container with
# only mktemp's own unstructured stderr as the diagnostic.
_tls_mktemp() {
  mktemp "$1.tmp.XXXXXX" 2>/dev/null || {
    printf 'level=error msg="mktemp failed while provisioning the TLS certificate" prefix=%s\n' "$1" >&2
    return 1
  }
}

# _generate_selfsigned_cert: mint a fresh self-signed cert+key PEM into the
# root-only cache. EC P-256 over RSA 2048: keygen completes in milliseconds
# even on small ARM hosts (RSA 2048 keygen is slower and CPU-variable at
# boot), handshakes are smaller, and P-256 is universally supported by the
# OpenSSL/GnuTLS stacks NUT clients build against. The container has no
# stable identity to attest, so the name is the generic CN=nut-upsd (SAN
# DNS:nut-upsd); 825-day validity stays inside the ceiling common TLS
# verifiers enforce. mktemp in the root-only dir gives O_EXCL 0600 temp
# files a compromised nut process cannot pre-plant (same rationale as
# _resolve_cached_password); cert-then-key order is NUT's documented
# CERTFILE layout (`cat upsd.crt upsd.key > upsd.pem`).
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
  if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$_gc_key" -out "$_gc_crt" -days "$TLS_CERT_DAYS" -nodes \
    -subj "/CN=nut-upsd" -addext "subjectAltName=DNS:nut-upsd" >/dev/null 2>&1 \
    && cat "$_gc_crt" "$_gc_key" >"$_gc_pem" \
    && _replace_file "$_gc_pem" "$TLS_CERT_CACHE"; then
    rm -f "$_gc_key" "$_gc_crt"
    printf 'level=info msg="generated self-signed TLS certificate; cached for intra-container restarts (not persisted across recreations)" path=%s validity_days=%d\n' \
      "$TLS_CERT_CACHE" "$TLS_CERT_DAYS" >&2
    return 0
  fi
  rm -f "$_gc_key" "$_gc_crt" "$_gc_pem"
  printf 'level=error msg="self-signed TLS certificate generation failed" path=%s\n' \
    "$TLS_CERT_CACHE" >&2
  return 1
}

# _install_cert_working_copy SRC DST: root:nut 640 working copy of SRC at DST
# (nut-readable — see the placement subtlety above). Shared by the self-signed
# path (cache -> TLS_CERT_RUNTIME) and the mounted-PEM path (mount ->
# TLS_CERT_MOUNTED_RUNTIME); only the copy is ever chowned, so the source —
# in particular an operator's bind mount — is never mutated. /etc/nut has no
# unprivileged writer (750 root:nut), but mktemp + rename keeps the install
# atomic anyway.
_install_cert_working_copy() {
  _ic_src="$1"
  _ic_dst="$2"
  _ic_tmp=$(_tls_mktemp "$_ic_dst") || return 1
  if cat "$_ic_src" >"$_ic_tmp" \
    && chown root:nut "$_ic_tmp" && chmod 640 "$_ic_tmp" \
    && _replace_file "$_ic_tmp" "$_ic_dst"; then
    return 0
  fi
  rm -f "$_ic_tmp"
  printf 'level=error msg="failed to install TLS certificate working copy for upsd" source=%s path=%s\n' \
    "$_ic_src" "$_ic_dst" >&2
  return 1
}

# resolve_tls_cert: point TLS_CERT_PATH (consumed by generate_upsd_conf) at a
# PEM upsd can serve. Runs whenever API_TLS=true — even with a mounted
# upsd.conf.user, whose author may reference either cert path. Returns 1 when
# no usable PEM could be provisioned (the entrypoint fails the boot: a TLS
# endpoint the operator left default-on must not silently degrade to
# cleartext).
resolve_tls_cert() {
  # Same dangling-symlink diagnostic as use_user_override (generate-config.sh):
  # -e follows the link, so a broken symlink at the mount path would silently
  # fall through to the self-signed certificate.
  if [ ! -e "$TLS_CERT_MOUNT" ] && [ -L "$TLS_CERT_MOUNT" ]; then
    printf 'level=warn msg="mounted TLS certificate path is a dangling symlink; ignoring it and provisioning the self-signed certificate" path=%s\n' "$TLS_CERT_MOUNT" >&2
  fi
  if [ -e "$TLS_CERT_MOUNT" ]; then
    # Refuse a non-regular mount (directory, FIFO, device node) up front: a
    # writer-less FIFO would block openssl/the working-copy cat forever and hang the
    # boot with no log line, and a directory (Docker auto-creates one when a
    # host bind source is missing) only fails later at ssl_init with a
    # misleading perms error. A non-regular PEM has never worked, so failing
    # fail-closed here is behavior-preserving (mirrors read_pidfile).
    if [ ! -f "$TLS_CERT_MOUNT" ]; then
      printf 'level=error msg="mounted TLS certificate path is not a regular file (a missing host bind source makes Docker create a directory here); mount an existing PEM file or unset the mount" path=%s\n' \
        "$TLS_CERT_MOUNT" >&2
      return 1
    fi
    # Warn-only parse/expiry gate: the mounted PEM's content is still served
    # as-is (upsd stays authoritative at ssl_init), but name the likely
    # consequence now instead of leaving a later fatal exit or client
    # rejection undiagnosed.
    if ! tls_cert_valid "$TLS_CERT_MOUNT"; then
      printf 'level=warn msg="mounted TLS certificate does not parse as cert+key or expires within a day; upsd may exit at startup or verifying clients may reject the handshake" path=%s\n' \
        "$TLS_CERT_MOUNT" >&2
    fi
    # Operator-mounted PEM: copied on every boot to a root:nut 640 working
    # copy inside /etc/nut, never chowned/chmodded in place (on a rw bind
    # mount that would mutate the HOST file — see the placement subtlety
    # above). Root always reads the mount regardless of its perms, so a
    # 600 root:root read-only mount works; the copy is nut-readable by
    # construction, and a cert rotated on the host is picked up at the next
    # restart.
    _install_cert_working_copy "$TLS_CERT_MOUNT" "$TLS_CERT_MOUNTED_RUNTIME" || return 1
    TLS_CERT_PATH="$TLS_CERT_MOUNTED_RUNTIME"
    printf 'level=info msg="TLS enabled with operator-mounted certificate (working copy; mount is never modified, a 600 root:root read-only mount is fine)" certfile=%s source=%s fingerprint="%s"\n' \
      "$TLS_CERT_MOUNTED_RUNTIME" "$TLS_CERT_MOUNT" "$(tls_cert_fingerprint "$TLS_CERT_MOUNT")" >&2
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
  printf 'level=info msg="TLS enabled with self-signed certificate" certfile=%s fingerprint="%s"\n' \
    "$TLS_CERT_RUNTIME" "$(tls_cert_fingerprint "$TLS_CERT_RUNTIME")" >&2
}

# reconcile_tls_working_copies: remove whichever managed working copies the
# current boot did not provision — always, even with an upsd.conf.user
# override mounted (see the entrypoint call site for the full rationale).
# set -u safe: $TLS_CERT_PATH is only read when API_TLS=true, where
# resolve_tls_cert guarantees it is set.
reconcile_tls_working_copies() {
  if [ "$API_TLS" != "true" ]; then
    _rw_stale="$TLS_CERT_MOUNTED_RUNTIME $TLS_CERT_RUNTIME"
  elif [ "$TLS_CERT_PATH" = "$TLS_CERT_MOUNTED_RUNTIME" ]; then
    _rw_stale="$TLS_CERT_RUNTIME"
  else
    _rw_stale="$TLS_CERT_MOUNTED_RUNTIME"
  fi
  # Managed paths are space-free readonly constants, so the word split is safe.
  _rw_failed=0
  for _rw_path in $_rw_stale; do
    if ! _rw_err=$(rm -f "$_rw_path" 2>&1); then
      printf 'level=error msg="cannot remove unselected TLS working copy (something mounted over this internal path?); refusing to leave withdrawn key material in place" path=%s err="%s"\n' "$_rw_path" "$(log_value "$_rw_err")" >&2
      _rw_failed=1
    fi
  done
  return "$_rw_failed"
}
