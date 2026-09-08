#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok/no return 0 unconditionally, so `[ cond ] && ok || no` cannot mis-fire.
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

mkdir -p "$WORK/etc/nut"
sed "s#/etc/nut#$WORK/etc/nut#g" "$ENTRYPOINT" >"$WORK/entrypoint.sh"
ENTRYPOINT="$WORK/entrypoint.sh"
TLS_BLOCK=$(extract_range \
  '^if \[ "[$]API_TLS" = "true" \]; then$' \
  '^# Always, even with an upsd.conf.user override mounted:$' \
  "$WORK/tls-diagnostic-block.sh") || exit 1

cat >"$WORK/drive-tls-diagnostic.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euf
. "$GENERATE_CONFIG"
_uo_decided=true
_uo_present=''
if [ "$SNAPSHOT" = present ]; then
  _uo_present=' upsd.conf'
fi
API_TLS="$TLS_MODE"
resolve_tls_cert() { :; }
. "$TLS_BLOCK"
DRIVER
chmod +x "$WORK/drive-tls-diagnostic.sh"

run_tls_diagnostic() {
  : >"$WORK/stderr"
  if env SNAPSHOT="$1" TLS_MODE="$2" TLS_BLOCK="$TLS_BLOCK" \
    GENERATE_CONFIG="$REPO_ROOT/generate-config.sh" \
    bash "$WORK/drive-tls-diagnostic.sh" \
    >"$WORK/stdout" 2>"$WORK/stderr"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
}

: >"$WORK/etc/nut/upsd.conf.user"
for _tls_mode in true false; do
  run_tls_diagnostic absent "$_tls_mode"
  [ "$RUN_RC" -eq 0 ] \
    && ! grep -Fq 'mounted upsd.conf.user owns the TLS directives' "$WORK/stderr" \
    && ok "API_TLS=$_tls_mode ignores an override that appeared after topology was decided" \
    || no "API_TLS=$_tls_mode late override appearance" \
      "rc=$RUN_RC stderr=$(tr '\n' '|' <"$WORK/stderr")"
done

rm -f "$WORK/etc/nut/upsd.conf.user"
for _tls_mode in true false; do
  run_tls_diagnostic present "$_tls_mode"
  [ "$RUN_RC" -eq 0 ] \
    && grep -Fq 'mounted upsd.conf.user owns the TLS directives' "$WORK/stderr" \
    && ok "API_TLS=$_tls_mode retains override ownership after the decided path disappears" \
    || no "API_TLS=$_tls_mode late override disappearance" \
      "rc=$RUN_RC stderr=$(tr '\n' '|' <"$WORK/stderr")"
done

report
