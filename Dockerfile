# check=error=true

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache automake build-base clang libtool patch perl pkgconf \
        libusb-compat-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.2.0
# repin: dep=stephane/libmodbus url=https://github.com/stephane/libmodbus/releases/download/{version}/libmodbus-{version_nov}.tar.gz
ARG LIBMODBUS_SHA256=72239f319b9b8483e3d393c5a60865d734fcff18a8abbb2486e389834a2f6ef1
WORKDIR /build/libmodbus
# libmodbus 3.2.0 added termios2 custom-baud support whose configure check
# mis-detects on Alpine/musl: `struct termios2` is present (via <asm/termbits.h>)
# so HAVE_STRUCT_TERMIOS2 gets set, but TCGETS2/TCSETS2 are not usable from
# <sys/ioctl.h> on musl, so modbus-rtu.c fails to compile. Force the type check
# off to build the portable classic-termios path (as 3.1.x did). Modbus support
# is unaffected: NUT's modbus drivers run at standard baud rates, so only the
# termios2 custom-baud RTU path is lost. Remove once upstream libmodbus builds
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
# repin: dep=net-snmp/net-snmp url=https://github.com/net-snmp/net-snmp/archive/refs/tags/{version}.tar.gz
ARG NETSNMP_SHA256=dc67748f382f7c0d2c17b62aabb1445724d80bb20a09081b7f010c9c86b84d45
WORKDIR /build/netsnmp
# netsnmp.pc is installed by net-snmp's TOP-LEVEL makefile, and this build
# runs only `make -C snmplib install`, so write it here. The literal
# ${prefix}/${libdir} are for pkg-config to expand at consume time, NOT the
# shell — hence the single-quoted printf format string. SC2016 is a false
# positive here.
# hadolint ignore=SC2016
RUN wget -qO netsnmp.tar.gz \
      "https://github.com/net-snmp/net-snmp/archive/refs/tags/${NETSNMP_VERSION}.tar.gz" \
    && printf '%s  %s\n' "${NETSNMP_SHA256}" netsnmp.tar.gz | sha256sum -c - \
    && tar xz --strip-components=1 -f netsnmp.tar.gz \
    && rm netsnmp.tar.gz \
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
    && mkdir -p /usr/lib/pkgconfig \
    && printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\nincludedir=${prefix}/include\n\nName: netsnmp\nDescription: Net-SNMP library\nVersion: %s\nLibs: -L${libdir} -lnetsnmp\nLibs.private: -lssl -lcrypto\nCflags: -I${includedir}\n' \
         "${NETSNMP_VERSION#v}" \
         > /usr/lib/pkgconfig/netsnmp.pc

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=v2.8.5
# The repin task below recomputes this on bump; cross-check the result
# against the upstream nut-<X.Y.Z>.tar.gz.sha256 release asset.
# repin: dep=networkupstools/nut url=https://github.com/networkupstools/nut/releases/download/{version}/nut-{version_nov}.tar.gz
ARG NUT_SHA256=18bf32e59eb764b13da3c4fa70384926d7fa584cb31d2fe7f137a570633eeec1
WORKDIR /build/nut
# Four checked-in backports of fixes this pinned release predates; each patch
# header carries the reasoning. --fuzz=0 so source drift on a version bump
# fails the build instead of silently shipping unpatched binaries. All four go
# at NUT_VERSION >= v2.8.6 — removal checklist in CONTRIBUTING.
COPY patches/cve-2026-54161-notifycmd-execvp.patch \
     patches/libusb-exit-reconnect-deadlock.patch \
     patches/libusb-rdlens-oob-read.patch \
     patches/richcomm-libusb-context-reopen.patch \
     /build/patches/
RUN wget -qO nut.tar.gz \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
    && printf '%s  %s\n' "${NUT_SHA256}" nut.tar.gz | sha256sum -c - \
    && tar xz --strip-components=1 -f nut.tar.gz \
    && rm nut.tar.gz \
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
       --with-usb --with-snmp --with-modbus \
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
    && find drivers -maxdepth 1 -type f -executable ! -name "*.la" \
       ! -name upsdrvctl -exec cp {} /out/usr/lib/nut/ \; \
    && cp data/cmdvartab /out/usr/share/ \
    && cp -d /usr/lib/libmodbus.so* /out/usr/lib/ \
    && cp -d /usr/lib/libnetsnmp.so* /out/usr/lib/

# Syft inventories an Alpine image from the APK database alone, so the three
# source-built payloads reach neither the signed release SBOM nor scanners.
# Generated from the same Renovate-tracked ARGs the builds use, so a bump
# keeps it correct.
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
        util-linux-misc \
    && addgroup -S nut \
    && adduser -S -G nut -h /var/run/nut -s /sbin/nologin nut \
    && install -d -m 770 -o nut -g nut /var/run/nut \
    && install -d -m 700 -o root -g root /var/run/nut-secrets \
    && install -d -m 750 -o root -g nut /etc/nut

COPY --from=builder /out/usr/lib/libmodbus* /usr/lib/
COPY --from=builder /out/usr/lib/libnetsnmp* /usr/lib/
COPY --from=builder /out/usr/sbin/upsd \
     /out/usr/sbin/upsmon \
     /out/usr/sbin/upsdrvctl /usr/sbin/
COPY --from=builder /out/usr/bin/upsc /usr/bin/
COPY --from=builder /out/usr/lib/nut/ /usr/lib/nut/
COPY --from=builder /out/usr/share/cmdvartab /usr/share/cmdvartab
# Placed where Syft's *.cdx.json cataloger inventories it, so SBOMs and scanners
# see NUT, libmodbus, and net-snmp alongside the APK packages.
COPY --from=builder /out/nut-upsd.cdx.json /usr/share/sbom/nut-upsd.cdx.json

# NUT_DEBUG_SYSLOG=stderr keeps upsd and the UPS driver logging to stderr after
# they daemonize. Without it NUT's background() clears the stderr log bit and
# reopens fd 2 on /dev/null, so those two write to syslog(3) alone -- and this
# image runs no syslog daemon while a container has no /dev/log, so musl drops
# the datagrams. "Data for UPS [x] is stale - check driver" is one of them.
# https://github.com/networkupstools/nut/blob/v2.8.5/docs/man/nut.conf.txt
ENV NUT_QUIET_INIT_UPSNOTIFY=true \
    NUT_DEBUG_SYSLOG=stderr
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 validate.sh /usr/local/bin/validate.sh
COPY --chmod=755 generate-config.sh /usr/local/bin/generate-config.sh
COPY --chmod=755 lifecycle.sh /usr/local/bin/lifecycle.sh
COPY --chmod=755 password.sh /usr/local/bin/password.sh
COPY --chmod=755 nut-notify.sh /usr/local/bin/nut-notify.sh
COPY --chmod=755 nut-shutdown.sh /usr/local/bin/nut-shutdown.sh
COPY --chmod=755 nut-shutdown-noop.sh /usr/local/bin/nut-shutdown-noop.sh
EXPOSE 3493

# The /tests-passed marker below is the only graph edge that makes a
# default-target build execute tests/smoke.sh, so a smoke failure fails the build.
FROM runtime AS test
COPY tests/smoke.sh /tmp/tests/smoke.sh
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# Must remain the LAST stage: the CI build gate builds the default target.
FROM runtime AS final
COPY --from=test /tests-passed /tests-passed

# No USER: root is required at container init; the rationale and the
# AVD-DS-0002 suppression live in .trivyignore at the repo root.

# Probe upsd where it listens (upsd_probe_host, lifecycle.sh). upsc's stderr
# is NOT discarded: it is the only signal in the docker health log separating
# "Data stale" from "Connection refused" from a timeout.
#
# Canonicalize FIRST, default SECOND, mirroring the entrypoint: dockerd execs
# this probe with the RAW container env, and an LF-only value is non-empty
# raw, so defaulting from it would probe an empty name, address or port.
#
# DL3025: this probe sources lifecycle.sh and expands three env vars, which
# exec form cannot do; this image wraps NUT with a shell entrypoint, so it can
# never become shell-less.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=135s \
    CMD . /usr/local/bin/lifecycle.sh; \
        UPS_NAME=$(printf '%s' "${UPS_NAME:-}"); : "${UPS_NAME:=ups}"; \
        API_PORT=$(printf '%s' "${API_PORT:-}"); : "${API_PORT:=3493}"; \
        API_ADDRESS=$(printf '%s' "${API_ADDRESS:-}"); : "${API_ADDRESS:=0.0.0.0}"; \
        comms_fresh || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
