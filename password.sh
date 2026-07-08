#!/bin/sh
# password.sh — ADMIN_PASSWORD generation and caching logic.
# Sourced by entrypoint.sh.

readonly PASSWORD_RAW_BYTES=36
readonly PASSWORD_LENGTH=24
readonly PASSWORD_MIN_LENGTH=12

# ADMIN_PASSWORD: cached at /var/run/nut/admin_password so it's stable across
# in-container restarts. The file lives in the container's writable layer and
# is lost on recreation (docker rm && docker run, or any orchestrator
# redeploy). If the env var is set, always use that value.
resolve_admin_password() {
  ADMIN_PASSWORD_FILE=/var/run/nut/admin_password
  if [ -z "${ADMIN_PASSWORD:-}" ]; then
    if [ -r "$ADMIN_PASSWORD_FILE" ]; then
      ADMIN_PASSWORD=$(cat "$ADMIN_PASSWORD_FILE")
      printf 'level=info msg="reusing ADMIN_PASSWORD from container FS (not persisted across recreations)" path=%s\n' \
        "$ADMIN_PASSWORD_FILE" >&2
    else
      # Pull more entropy than we need so stripping `/+=` still leaves
      # ≥PASSWORD_LENGTH usable characters; head -c then gives a stable length.
      ADMIN_PASSWORD=$(head -c "$PASSWORD_RAW_BYTES" /dev/urandom | base64 | tr -d '/+=' | head -c "$PASSWORD_LENGTH")
      if (umask 077 && printf '%s' "$ADMIN_PASSWORD" >"$ADMIN_PASSWORD_FILE"); then
        printf 'level=info msg="generated ADMIN_PASSWORD; cached for intra-container restarts" path=%s\n' \
          "$ADMIN_PASSWORD_FILE" >&2
      else
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
