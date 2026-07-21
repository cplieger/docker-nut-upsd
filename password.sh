#!/bin/sh
# password.sh — ADMIN_PASSWORD generation and caching logic.
# Sourced by entrypoint.sh; not executed directly.

readonly PASSWORD_RAW_BYTES=36
readonly PASSWORD_LENGTH=24
readonly PASSWORD_MIN_LENGTH=12

# ADMIN_PASSWORD: cached at /var/run/nut-secrets/admin_password so it's stable
# across in-container restarts. The cache lives in a root-only runtime directory
# (mode 700, owner root) so the lower-privileged `nut` service user cannot
# pre-create or replace the temp/cache paths (symlink/clobber hardening). The
# file lives in the container's writable layer and is lost on recreation
# (docker rm && docker run, or any orchestrator redeploy). If the env var is
# set, always use that value.
resolve_admin_password() {
  ADMIN_PASSWORD_FILE=/var/run/nut-secrets/admin_password
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    # Bounded, validated cache read: generation below always writes exactly
    # PASSWORD_LENGTH bytes, so only a cache of exactly that size is trusted,
    # and the read itself is capped at PASSWORD_LENGTH bytes. An unbounded
    # `cat` of a corrupted or grown cache in the reused writable layer would
    # let PID 1 consume memory proportional to the file and repeat the OOM on
    # every restart. Treat a whitespace-only cache as absent (self-heal):
    # POSIX command substitution strips trailing newlines, but spaces/tabs
    # would otherwise pass a length check and cache an unusable password.
    _cache_size=$(stat -c %s "$ADMIN_PASSWORD_FILE" 2>/dev/null) || _cache_size=""
    if [ "$_cache_size" = "$PASSWORD_LENGTH" ] \
      && ADMIN_PASSWORD=$(head -c "$PASSWORD_LENGTH" "$ADMIN_PASSWORD_FILE" 2>/dev/null) \
      && [ "${#ADMIN_PASSWORD}" -eq "$PASSWORD_LENGTH" ] \
      && [ -n "$(printf '%s' "$ADMIN_PASSWORD" | tr -d '[:space:]')" ]; then
      printf 'level=info msg="reusing ADMIN_PASSWORD from container FS (not persisted across recreations)" path=%s\n' \
        "$ADMIN_PASSWORD_FILE" >&2
    else
      if [ -s "$ADMIN_PASSWORD_FILE" ]; then
        printf 'level=warn msg="cached ADMIN_PASSWORD invalid (wrong size, unreadable, or whitespace-only); regenerating" path=%s size=%s expected=%s\n' \
          "$ADMIN_PASSWORD_FILE" "${_cache_size:-unreadable}" "$PASSWORD_LENGTH" >&2
      fi
      # Pull more entropy than we need so stripping `/+=` still leaves
      # ≥PASSWORD_LENGTH usable characters; head -c then gives a stable length.
      ADMIN_PASSWORD=$(head -c "$PASSWORD_RAW_BYTES" /dev/urandom | base64 | tr -d '/+=' | head -c "$PASSWORD_LENGTH")
      # Never cache or use a short password: stripping `/+=` can in principle
      # leave fewer than PASSWORD_LENGTH characters, and a short read from
      # /dev/urandom would too. Fail loudly (entrypoint runs under set -e)
      # rather than silently starting with weakened admin credentials.
      if [ "${#ADMIN_PASSWORD}" -ne "$PASSWORD_LENGTH" ]; then
        printf 'level=error msg="generated ADMIN_PASSWORD has unexpected length; refusing weak credentials" got=%d expected=%d\n' \
          "${#ADMIN_PASSWORD}" "$PASSWORD_LENGTH" >&2
        return 1
      fi
      # mktemp in the root-only dir gives an O_EXCL, unpredictable temp name so
      # a compromised `nut` process cannot plant a symlink at the write target.
      if _tmp=$(mktemp "${ADMIN_PASSWORD_FILE}.tmp.XXXXXX") \
        && (umask 077 && printf '%s' "$ADMIN_PASSWORD" >"$_tmp") && mv "$_tmp" "$ADMIN_PASSWORD_FILE"; then
        printf 'level=info msg="generated ADMIN_PASSWORD; cached for intra-container restarts" path=%s\n' \
          "$ADMIN_PASSWORD_FILE" >&2
      else
        rm -f "$_tmp" 2>/dev/null || true
        printf 'level=warn msg="generated ADMIN_PASSWORD but failed to cache; a new value will be generated on next restart" path=%s\n' \
          "$ADMIN_PASSWORD_FILE" >&2
      fi
    fi
  fi
}

# Warn (don't block) on the well-known default credentials.
warn_weak_api_password() {
  if [ "$API_PASSWORD" = "secret" ] || [ "${#API_PASSWORD}" -lt "$PASSWORD_MIN_LENGTH" ]; then
    printf 'level=warn msg="API_PASSWORD is weak (default value or <%d chars). Acceptable on a trusted LAN; rotate it if your NUT client supports custom credentials."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
}
