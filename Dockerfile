# check=error=true

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache build-base clang gpgv patch perl pkgconf \
        libusb-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.2.0
# No publisher signature or checksum assets: https://github.com/stephane/libmodbus/releases
# repin: dep=stephane/libmodbus url=https://github.com/stephane/libmodbus/releases/download/{version}/libmodbus-{version_nov}.tar.gz
ARG LIBMODBUS_SHA256=72239f319b9b8483e3d393c5a60865d734fcff18a8abbb2486e389834a2f6ef1
WORKDIR /build/libmodbus
# libmodbus 3.2.0 added termios2 custom-baud support whose configure check
# mis-detects on Alpine/musl: `struct termios2` is present (via <asm/termbits.h>)
# so HAVE_STRUCT_TERMIOS2 gets set, but TCGETS2/TCSETS2 are not usable from
# <sys/ioctl.h> on musl, so modbus-rtu.c fails to compile. Force the type check
# off to build the portable classic-termios path (as 3.1.x did). Cost: the three
# drivers taking an operator baud rate (apc_modbus, generic_modbus,
# adelsystem_cbi) get B9600 for any rate the classic set cannot express, e.g.
# 14400, and libmodbus says so only at debug -- the README warns the operator
# (termios2 arrived in stephane/libmodbus#761). Remove once upstream builds
# cleanly on musl.
RUN wget -qO libmodbus.tar.gz \
      "https://github.com/stephane/libmodbus/releases/download/${LIBMODBUS_VERSION}/libmodbus-${LIBMODBUS_VERSION#v}.tar.gz" \
    && printf '%s  %s\n' "${LIBMODBUS_SHA256}" libmodbus.tar.gz | sha256sum -c - \
    && tar xz --strip-components=1 -f libmodbus.tar.gz \
    && rm libmodbus.tar.gz \
    && ac_cv_type_struct_termios2=no \
       ./configure --prefix=/usr --disable-static \
       CC=clang \
    && make -j"$(nproc)" \
    && make install

# renovate: datasource=github-tags depName=net-snmp/net-snmp
ARG NETSNMP_VERSION=v5.9.5.2
# repin: dep=net-snmp/net-snmp url=https://downloads.sourceforge.net/net-snmp/net-snmp-{version_nov}.tar.gz
ARG NETSNMP_SHA256=16707719f833184a4b72835dac359ae188123b06b5e42817c00790d7dc1384bf
WORKDIR /build/netsnmp
# configure generates netsnmp.pc (ac_config_files), but INSTALL_PKGCONFIG is a
# top-level target and this build runs only `make -C snmplib install`, so
# install it here: NUT's --with-snmp detects net-snmp through it.
# Release key 6E6718AEF1EB5C65C32D1B2A356BC0B552D53CAB is cross-checked
# against net-snmp.org's published key, the SourceForge signature, and Ubuntu's keyserver.
COPY netsnmp-release.gpg /usr/local/share/netsnmp-release.gpg
RUN wget -qO netsnmp.tar.gz \
      "https://downloads.sourceforge.net/net-snmp/net-snmp-${NETSNMP_VERSION#v}.tar.gz" \
    && wget -qO netsnmp.tar.gz.asc \
      "https://downloads.sourceforge.net/net-snmp/net-snmp-${NETSNMP_VERSION#v}.tar.gz.asc" \
    && printf '%s  %s\n' "${NETSNMP_SHA256}" netsnmp.tar.gz | sha256sum -c - \
    && gpgv --keyring /usr/local/share/netsnmp-release.gpg netsnmp.tar.gz.asc netsnmp.tar.gz \
    && tar xz --strip-components=1 -f netsnmp.tar.gz \
    && rm netsnmp.tar.gz netsnmp.tar.gz.asc \
    && ./configure --prefix=/usr --disable-static \
       --build="$(uname -m)-linux-musl" \
       CC=clang \
       --with-defaults \
       --disable-applications \
       --disable-manuals --disable-scripts --disable-mibs \
       --enable-shared --with-openssl \
    && make -j"$(nproc)" -C snmplib \
    && make -C snmplib install \
    && cp -r include/net-snmp /usr/include/ \
    && install -D -m 644 netsnmp.pc /usr/lib/pkgconfig/netsnmp.pc

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=v2.8.5
# The signature authenticates the publisher; the same-channel sha pin preserves transport integrity.
# Release subkey BFA06D7C653B64C11DFDAF0442061031267D11B1 belongs to primary
# B83459F776B90224988F36C0DE0184DA7043DCF7, cross-checked against the tarball's
# docs/security.txt, keys.openpgp.org, and the maintainer's GitHub-verified key.
# Refresh nut-release.gpg on key rotation using the procedure in docs/security.txt.
# repin: dep=networkupstools/nut url=https://github.com/networkupstools/nut/releases/download/{version}/nut-{version_nov}.tar.gz
ARG NUT_SHA256=18bf32e59eb764b13da3c4fa70384926d7fa584cb31d2fe7f137a570633eeec1
WORKDIR /build/nut
# Checked-in backports of fixes this pinned release predates; each patch
# header carries the reasoning. --fuzz=0 so source drift on a version bump
# fails the build instead of silently shipping unpatched binaries. They all go
# at NUT_VERSION >= v2.8.6 — removal checklist in CONTRIBUTING.
COPY patches/cve-2026-54161-notifycmd-execvp.patch \
     patches/libusb-exit-reconnect-deadlock.patch \
     patches/libusb-rdlens-oob-read.patch \
     patches/richcomm-libusb-context-reopen.patch \
     /build/patches/
COPY nut-release.gpg /usr/local/share/nut-release.gpg
RUN wget -qO nut.tar.gz \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
    && wget -qO nut.tar.gz.sig \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz.sig" \
    && gpgv --keyring /usr/local/share/nut-release.gpg nut.tar.gz.sig nut.tar.gz \
    && printf '%s  %s\n' "${NUT_SHA256}" nut.tar.gz | sha256sum -c - \
    && tar xz --strip-components=1 -f nut.tar.gz \
    && rm nut.tar.gz nut.tar.gz.sig \
    && patch -p1 --fuzz=0 -i /build/patches/cve-2026-54161-notifycmd-execvp.patch \
    && patch -p1 --fuzz=0 -i /build/patches/libusb-exit-reconnect-deadlock.patch \
    && patch -p1 --fuzz=0 -i /build/patches/libusb-rdlens-oob-read.patch \
    && patch -p1 --fuzz=0 -i /build/patches/richcomm-libusb-context-reopen.patch \
    && PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig" \
       LIBS="-lssl -lcrypto" \
       ./configure --prefix=/usr --sysconfdir=/etc/nut \
       --with-statepath=/var/run/nut \
       --with-drvpath=/usr/lib/nut \
       --with-user=nut --with-group=nut \
       CC=clang CXX=clang++ \
       --with-usb=libusb-1.0 --with-snmp --with-modbus \
       --with-ssl=openssl \
       --disable-shared --enable-static \
       --without-cgi --without-doc --without-avahi \
       --without-ipmi --without-neon --without-powerman \
       --without-freeipmi --without-wrap \
    && make -j"$(nproc)" \
    && mkdir -p /out/usr/sbin /out/usr/bin /out/usr/lib/nut /out/usr/share \
    && find server -name upsd -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find clients -name upsc -type f -executable -exec cp {} /out/usr/bin/ \; \
    && find clients -name upsmon -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find drivers -name upsdrvctl -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find drivers -maxdepth 1 -type f -executable \
       ! -name upsdrvctl -exec cp {} /out/usr/lib/nut/ \; \
    && cp data/cmdvartab /out/usr/share/ \
    && cp -d /usr/lib/libmodbus.so* /out/usr/lib/ \
    && cp -d /usr/lib/libnetsnmp.so* /out/usr/lib/

# Syft sees source builds only through an embedded CycloneDX fragment.
RUN cat > /out/nut-upsd.cdx.json <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    {
      "bom-ref": "pkg:github/networkupstools/nut@${NUT_VERSION}",
      "type": "application",
      "name": "nut",
      "version": "${NUT_VERSION#v}",
      "purl": "pkg:github/networkupstools/nut@${NUT_VERSION}",
      "cpe": "cpe:2.3:a:networkupstools:nut:${NUT_VERSION#v}:*:*:*:*:*:*:*"
    },
    {
      "bom-ref": "pkg:github/stephane/libmodbus@${LIBMODBUS_VERSION}",
      "type": "library",
      "name": "libmodbus",
      "version": "${LIBMODBUS_VERSION#v}",
      "purl": "pkg:github/stephane/libmodbus@${LIBMODBUS_VERSION}",
      "cpe": "cpe:2.3:a:libmodbus:libmodbus:${LIBMODBUS_VERSION#v}:*:*:*:*:*:*:*"
    },
    {
      "bom-ref": "pkg:github/net-snmp/net-snmp@${NETSNMP_VERSION}",
      "type": "library",
      "name": "net-snmp",
      "version": "${NETSNMP_VERSION#v}",
      "purl": "pkg:github/net-snmp/net-snmp@${NETSNMP_VERSION}",
      "cpe": "cpe:2.3:a:net-snmp:net-snmp:${NETSNMP_VERSION#v}:*:*:*:*:*:*:*"
    }
  ]
}
EOF

FROM builder AS source-checks
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
COPY validate.sh entrypoint.sh generate-config.sh /tmp/source-checks/
RUN <<'CHECKS'
set -eu

make_list() {
  awk -v macro="$1" '
    $1 == macro && $2 == "=" {
      in_list = 1
      sub(/^[^=]*=[[:space:]]*/, "")
    }
    in_list {
      continued = ($0 ~ /\\[[:space:]]*$/)
      gsub(/\\/, "")
      print
      if (!continued) exit
    }
  ' drivers/Makefile.am | tr '[:space:]' '\n' | sed '/^$/d' | sort
}

source_usb=$(make_list USB_LIBUSB_DRIVERLIST)
local_usb=$(sed -n '/^[[:space:]]*usbhid-ups[[:space:]]*|/{s/^[[:space:]]*//;s/)[[:space:]]*$//;p;q;}' /tmp/source-checks/validate.sh \
  | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' | sort)
[ "$source_usb" = "$local_usb" ] || {
  printf '%s\n' 'source check failed: validate.sh USB driver census differs from drivers/Makefile.am USB_LIBUSB_DRIVERLIST' >&2
  exit 1
}

source_snmp=$(make_list SNMP_DRIVERLIST)
local_snmp=$(sed -n '/^[[:space:]]*snmp-ups[[:space:]]*|/{s/^[[:space:]]*//;s/)[[:space:]]*$//;p;q;}' /tmp/source-checks/validate.sh \
  | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' \
  | grep -v '^apcupsd-ups$' | sort)
[ "$source_snmp" = "$local_snmp" ] || {
  printf '%s\n' 'source check failed: validate.sh SNMP driver census differs from drivers/Makefile.am SNMP_DRIVERLIST' >&2
  exit 1
}

source_default() {
  awk -v var="$1" '
    $0 ~ var "[[:space:]]*=" {
      line = $0
      sub(".*" var "[[:space:]]*=[[:space:]]*", "", line)
      sub(/[^0-9].*/, "", line)
      if (line != "") {
        print line
        exit
      }
    }
  ' clients/upsmon.c
}

for spec in \
  POLLFREQ:pollfreq \
  POLLFREQALERT:pollfreqalert \
  DEADTIME:deadtime \
  FINALDELAY:finaldelay \
  HOSTSYNC:hostsync \
  NOCOMMWARNTIME:nocommwarntime \
  RBWARNTIME:rbwarntime; do
  shell_var=${spec%%:*}
  source_var=${spec#*:}
  source_value=$(source_default "$source_var")
  expected=$(printf ": \"\${%s:=%s}\"" "$shell_var" "$source_value")
  grep -Fqx "$expected" /tmp/source-checks/entrypoint.sh || {
    printf 'source check failed: entrypoint.sh %s default differs from clients/upsmon.c %s\n' "$shell_var" "$source_var" >&2
    exit 1
  }
done

for spec in \
  OFFDURATION:offdurationtime \
  OBLBDURATION:oblbdurationtime \
  ALARMCRITICAL:alarmcritical; do
  directive=${spec%%:*}
  source_var=${spec#*:}
  source_value=$(source_default "$source_var")
  grep -Fqx "$directive $source_value" /tmp/source-checks/generate-config.sh || {
    printf 'source check failed: generate-config.sh %s pin differs from clients/upsmon.c %s; re-read the deliberate pin checklist in CONTRIBUTING.md\n' "$directive" "$source_var" >&2
    exit 1
  }
done

grep -Fq 'retrying harder' drivers/upsdrvctl.c || {
  printf '%s\n' 'source check failed: drivers/upsdrvctl.c SIGKILL-escalation phrase changed; lifecycle.sh restart_ups_driver would stop reporting a wedged driver stop as anything but a clean one' >&2
  exit 1
}

touch /source-checks-passed
CHECKS

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

# The `echo` is load-bearing: BuildKit keys a RUN on the args it CONSUMES, so
# dropping it leaves the upgrade on a cached layer and the image ships stale
# packages, silently.
ARG PKG_REFRESH=static
RUN echo "OS package refresh: ${PKG_REFRESH}" \
    && apk upgrade --no-cache \
    && apk add --no-cache \
        dbus \
        libusb \
        openssl \
        # util-linux-misc provides `wall`: the shipped upsmon popen()s it in
        # doshutdown() and for every notify type keeping NUT's default WALL bit, so
        # without it /bin/sh writes `wall: not found` onto upsmon's stderr mid-outage.
        # https://github.com/networkupstools/nut/blob/v2.8.5/clients/upsmon.c#L968
        util-linux-misc \
    # apk's install_if pulls dbus-daemon-launch-helper in with dbus
    # (APKINDEX `i:dbus`): setuid root, group messagebus, for autospawning a
    # service off a bus this image never runs. `test -u` fails the build if a
    # base bump stops shipping it, so this line cannot become a lie.
    && test -u /usr/libexec/dbus-daemon-launch-helper \
    && rm /usr/libexec/dbus-daemon-launch-helper \
    && addgroup -S nut \
    && adduser -S -G nut -h /var/run/nut -s /sbin/nologin nut \
    && install -d -m 770 -o nut -g nut /var/run/nut \
    && install -d -m 700 -o root -g root /var/run/nut-secrets \
    && install -d -m 750 -o root -g nut /etc/nut

COPY --from=builder /out/usr/lib/libmodbus* /out/usr/lib/libnetsnmp* /usr/lib/
COPY --from=builder /out/usr/sbin/upsd \
     /out/usr/sbin/upsmon \
     /out/usr/sbin/upsdrvctl /usr/sbin/
COPY --from=builder /out/usr/bin/upsc /usr/bin/
COPY --from=builder /out/usr/lib/nut/ /usr/lib/nut/
COPY --from=builder /out/usr/share/cmdvartab /usr/share/cmdvartab
# Placed where Syft's *.cdx.json cataloger inventories it.
COPY --from=builder /out/nut-upsd.cdx.json /usr/share/sbom/nut-upsd.cdx.json

# NUT_DEBUG_SYSLOG=stderr keeps upsd and the UPS driver logging to stderr after
# they daemonize. Without it NUT's background() clears the stderr log bit and
# reopens fd 2 on /dev/null, so those two write to syslog(3) alone -- and this
# image runs no syslog daemon while a container has no /dev/log, so musl drops
# the datagrams. "Data for UPS [x] is stale - check driver" is one of them.
# https://github.com/networkupstools/nut/blob/v2.8.5/docs/man/nut.conf.txt
ENV NUT_QUIET_INIT_UPSNOTIFY=true \
    NUT_DEBUG_SYSLOG=stderr
COPY --chmod=755 entrypoint.sh validate.sh generate-config.sh lifecycle.sh \
     secrets.sh nut-notify.sh nut-shutdown.sh nut-shutdown-noop.sh \
     /usr/local/bin/
EXPOSE 3493

# The /tests-passed marker below is the only graph edge that makes a
# default-target build execute tests/smoke.sh, so a smoke failure fails the build.
FROM runtime AS test
COPY --from=builder /build/nut/clients/upsmon.c /tmp/nut-source/clients/upsmon.c
COPY alerts/logql.yaml /tmp/alerts/logql.yaml
COPY tests/smoke.sh /tmp/tests/smoke.sh
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# Must remain the LAST stage: the CI build gate builds the default target.
FROM runtime AS final
COPY --from=test /tests-passed /tests-passed
COPY --from=source-checks /source-checks-passed /source-checks-passed

# No USER: root is required at container init (see .trivyignore).

# Probe upsd where it listens (upsd_probe_host, lifecycle.sh); upsc's stderr is
# kept because it separates "Data stale", "Connection refused" and a timeout in
# the health log. Canonicalize FIRST, default SECOND: dockerd execs this probe
# with the RAW env, dodging the := defaults (entrypoint.sh's canonicalize note).
# --start-period must cover entrypoint.sh's two start_nut_daemon bounds and
# lifecycle.sh's PIDFILE_POLL_INTERVAL x PIDFILE_POLL_MAX; the
# tests/shell/entrypoint_supervision_test.sh assertion keeps deliberate slack.

# DL3025: this probe sources lifecycle.sh and expands three env vars, which
# exec form cannot do; this image wraps NUT with a shell entrypoint, so it can
# never become shell-less.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=135s \
    CMD . /usr/local/bin/lifecycle.sh; \
        UPS_NAME=$(printf '%s' "${UPS_NAME:-}"); : "${UPS_NAME:=ups}"; \
        API_PORT=$(printf '%s' "${API_PORT:-}"); : "${API_PORT:=3493}"; \
        API_ADDRESS=$(printf '%s' "${API_ADDRESS:-}"); : "${API_ADDRESS:=0.0.0.0}"; \
        comms_fresh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
