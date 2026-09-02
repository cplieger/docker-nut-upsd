#!/usr/bin/env bash
# The README export command must write only the public certificate from the
# combined certificate-and-private-key PEM that upsd serves.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

if ! command -v openssl >/dev/null 2>&1; then
  skip 'TLS certificate export contract' 'openssl is not installed'
  report
  exit $?
fi

readme_cmd=$(awk '
  /^## TLS \(STARTTLS\)$/ { in_tls=1; next }
  in_tls && /^## / { exit }
  in_tls && /^```sh$/ { in_block=1; next }
  in_block && /^```$/ { in_block=0; next }
  in_block && /docker exec nut-upsd openssl x509 -in/ { print; exit }
' "$REPO_ROOT/README.md")

if [ -z "$readme_cmd" ]; then
  no 'TLS export command found' 'README TLS section has no container-side openssl export command'
  report
  exit $?
fi

read -r docker_cmd exec_arg container openssl_cmd x509_arg in_arg provisioned_path outform_arg outform_value redirect exported_name <<<"$readme_cmd"
if [ "$docker_cmd $exec_arg $container $openssl_cmd" != 'docker exec nut-upsd openssl' ] \
  || [ "$provisioned_path" != '/etc/nut/upsd-selfsigned.pem' ] \
  || [ "$redirect" != '>' ]; then
  no 'TLS export command parsed' "unexpected command: $readme_cmd"
  report
  exit $?
fi

key="$WORK/key.pem"
cert="$WORK/cert.pem"
combined="$WORK/combined.pem"
exported="$WORK/$exported_name"
if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=nut-upsd-test' \
  -keyout "$key" -out "$cert" >/dev/null 2>&1; then
  no 'TLS export fixture generated' 'openssl could not generate the certificate fixture'
  report
  exit $?
fi
cat "$cert" "$key" >"$combined"

if openssl "$x509_arg" "$in_arg" "$combined" "$outform_arg" "$outform_value" >"$exported" \
  && grep -q -- '-----BEGIN CERTIFICATE-----' "$exported" \
  && ! grep -q -- 'PRIVATE KEY' "$exported" \
  && ! openssl pkey -in "$exported" -noout >/dev/null 2>&1; then
  ok 'the documented export writes a certificate without the private key'
else
  no 'certificate-only TLS export' 'the documented command exported no certificate or included a private key'
fi

report
