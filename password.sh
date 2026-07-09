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
    # Treat a whitespace-only cache as absent (self-heal): POSIX command
    # substitution strips trailing newlines, but spaces/tabs would otherwise
    # pass a bare `-n` check and cache an unusable admin password.
    if [ -s "$ADMIN_PASSWORD_FILE" ] && ADMIN_PASSWORD=$(cat "$ADMIN_PASSWORD_FILE") \
      && [ -n "$(printf '%s' "$ADMIN_PASSWORD" | tr -d '[:space:]')" ]; then
      printf 'level=info msg="reusing ADMIN_PASSWORD from container FS (not persisted across recreations)" path=%s\n' \
        "$ADMIN_PASSWORD_FILE" >&2
    else
      # Pull more entropy than we need so stripping `/+=` still leaves
      # ≥PASSWORD_LENGTH usable characters; head -c then gives a stable length.
      ADMIN_PASSWORD=$(head -c "$PASSWORD_RAW_BYTES" /dev/urandom | base64 | tr -d '/+=' | head -c "$PASSWORD_LENGTH")
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
    printf 'level=warn msg="API_PASSWORD is weak (literal \"secret\" or <%d chars). Acceptable on a trusted LAN; rotate it if your NUT client supports custom credentials."\n' \
      "$PASSWORD_MIN_LENGTH" >&2
  fi
}
