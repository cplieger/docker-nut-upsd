# check=error=true

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache automake build-base clang libtool lld patch perl pkgconf \
        libusb-compat-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.2.0
# Recompute on bump:
# curl -sL https://github.com/stephane/libmodbus/releases/download/<vX.Y.Z>/libmodbus-<X.Y.Z>.tar.gz | sha256sum
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
# Recompute on bump (GitHub-generated tag archive, same class the fleet
# already gates for darkhttpd):
# curl -sL https://github.com/net-snmp/net-snmp/archive/refs/tags/<vX.Y.Z.N>.tar.gz | sha256sum
ARG NETSNMP_SHA256=dc67748f382f7c0d2c17b62aabb1445724d80bb20a09081b7f010c9c86b84d45
WORKDIR /build/netsnmp
# The conditional netsnmp.pc fallback below writes literal ${prefix}/${libdir}
# for pkg-config to expand at consume time, NOT the shell — hence the
# single-quoted printf format string. SC2016 is a false positive here.
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
    && if [ ! -f /usr/lib/pkgconfig/netsnmp.pc ]; then \
         mkdir -p /usr/lib/pkgconfig \
         && printf 'prefix=/usr\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\nincludedir=${prefix}/include\n\nName: netsnmp\nDescription: Net-SNMP library\nVersion: %s\nLibs: -L${libdir} -lnetsnmp\nLibs.private: -lssl -lcrypto\nCflags: -I${includedir}\n' \
           "${NETSNMP_VERSION#v}" \
           > /usr/lib/pkgconfig/netsnmp.pc; \
       fi

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=v2.8.5
# Recompute on bump (cross-check against the upstream
# nut-<X.Y.Z>.tar.gz.sha256 release asset):
# curl -sL https://github.com/networkupstools/nut/releases/download/<vX.Y.Z>/nut-<X.Y.Z>.tar.gz | sha256sum
ARG NUT_SHA256=18bf32e59eb764b13da3c4fa70384926d7fa584cb31d2fe7f137a570633eeec1
WORKDIR /build/nut
# CVE-2026-54161 / GHSA-mjgp-j4gm-6qg5 backport (see the patch header): v2.8.5
# ships upsmon/upssched invoking NOTIFYCMD/CMDSCRIPT via system() with
# server-controlled text interpolated into the shell command. Applied strictly
# (--fuzz=0) so source drift on a version bump fails the build loudly instead
# of silently shipping unpatched binaries. Remove with NUT_VERSION >= v2.8.6.
COPY patches/cve-2026-54161-notifycmd-execvp.patch /build/patches/
RUN wget -qO nut.tar.gz \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
    && printf '%s  %s\n' "${NUT_SHA256}" nut.tar.gz | sha256sum -c - \
    && tar xz --strip-components=1 -f nut.tar.gz \
    && rm nut.tar.gz \
    && patch -p1 --fuzz=0 -i /build/patches/cve-2026-54161-notifycmd-execvp.patch \
    && PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig" \
       LIBS="-lssl -lcrypto" \
       ac_cv_func_setpgrp_void=yes \
       ac_cv_func_memcmp_working=yes \
       ac_cv_func_mmap_fixed_mapped=yes \
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
    && mkdir -p /out/usr/sbin /out/usr/bin /out/usr/lib/nut /out/usr/share/nut \
    && find server -name upsd -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find clients -name upsc -type f -executable -exec cp {} /out/usr/bin/ \; \
    && find clients -name upsmon -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find drivers -name upsdrvctl -type f -executable -exec cp {} /out/usr/sbin/ \; \
    && find drivers -maxdepth 1 -type f -executable ! -name "*.la" \
       ! -name upsdrvctl -exec cp {} /out/usr/lib/nut/ \; \
    && cp data/driver.list /out/usr/share/nut/ \
    && cp data/cmdvartab /out/usr/share/ \
    && cp /usr/lib/libmodbus.so* /out/usr/lib/ \
    && cp /usr/lib/libnetsnmp.so* /out/usr/lib/

# ---------------------------------------------------------------------------
# Embedded SBOM fragment. Syft inventories the final image from Alpine's APK
# database only, so the three source-built payloads (NUT, libmodbus,
# net-snmp) are invisible to the signed release SBOM and to vulnerability
# scanners. Generate a CycloneDX fragment from the same Renovate-tracked
# version ARGs the builds use — a Renovate bump keeps the SBOM correct with
# zero extra maintenance — and ship it in the runtime image where Syft's
# *.cdx.json cataloger picks it up (see the COPY in the runtime stage).
# The VEX entry ships in-image and documents the CVE-2026-54161 backport
# applied above for anyone scanning the embedded fragment; the SIGNED
# release SBOM (Syft's SPDX 2.3 output) carries the component inventory
# only — Syft does not propagate CycloneDX vulnerability analysis into
# that output, so the resolved state reaches the registry through the
# OpenVEX document at vex/cve-2026-54161.openvex.json instead, which the
# release pipeline attests alongside the image.
# Remove the entry together with the patch at NUT_VERSION >= v2.8.6.
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
  ],
  "vulnerabilities": [
    {
      "id": "CVE-2026-54161",
      "analysis": {
        "state": "resolved",
        "detail": "Built with the checked-in backport patches/cve-2026-54161-notifycmd-execvp.patch (upstream ecf98e7542e4ae2b62b211622ee26989274b2220) applied at build time; remove this entry with the patch at NUT_VERSION >= v2.8.6."
      },
      "affects": [
        { "ref": "pkg:github/networkupstools/nut@${NUT_VERSION}" }
      ]
    }
  ]
}
EOF

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

# apk upgrade: the pinned base ships some packages (e.g. libssl3) at a stale,
# CVE-affected revision; upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        dbus \
        libusb-compat \
        openssl \
        tzdata \
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
COPY --from=builder /out/usr/share/nut/ /usr/share/nut/
COPY --from=builder /out/usr/share/cmdvartab /usr/share/cmdvartab
# CycloneDX SBOM fragment for the source-built components (generated in the
# builder stage from the Renovate-tracked version ARGs). Placed where Syft's
# *.cdx.json cataloger inventories it, so SBOMs and scanners see NUT,
# libmodbus, and net-snmp alongside the APK packages.
COPY --from=builder /out/nut-upsd.cdx.json /usr/share/sbom/nut-upsd.cdx.json

ENV NUT_QUIET_INIT_UPSNOTIFY=true \
    NUT_QUIET_INIT_SSL=true
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 validate.sh /usr/local/bin/validate.sh
COPY --chmod=755 generate-config.sh /usr/local/bin/generate-config.sh
COPY --chmod=755 lifecycle.sh /usr/local/bin/lifecycle.sh
COPY --chmod=755 password.sh /usr/local/bin/password.sh
COPY --chmod=755 nut-notify.sh /usr/local/bin/nut-notify.sh
COPY --chmod=755 nut-shutdown.sh /usr/local/bin/nut-shutdown.sh
COPY --chmod=755 nut-shutdown-noop.sh /usr/local/bin/nut-shutdown-noop.sh
EXPOSE 3493

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (NUT binaries run; the
# entrypoint's env -> config generation and input-validation guards behave).
# A failure here fails the centralized `ci / validate` docker build gate,
# because the final stage below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM runtime AS test
COPY tests/ /tmp/tests/
# The OpenVEX doc is static while the embedded fragment is ARG-generated;
# copied in so smoke.sh section 8 can assert their nut versions agree.
COPY vex/ /tmp/vex/
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. Must remain last so the CI build gate
# (which builds the default target) produces it; the marker COPY forces the
# test stage to build and pass first.
# ---------------------------------------------------------------------------
FROM runtime AS final
COPY --from=test /tests-passed /tests-passed

# Note: this image runs as root by design — NUT needs root at init for USB
# device access (upsdrvctl) and to chown the runtime directories. The upsd
# daemon drops to user "nut" internally via the build-time configure flags
# (--with-user=nut --with-group=nut). AVD-DS-0002 is suppressed via
# .trivyignore at the repo root; see the rationale there.
# Probe upsd at its configured listen address (upsd_probe_host, lifecycle.sh).
# stderr is NOT discarded: upsc's error is the only signal in the docker health
# log distinguishing "Data stale" (driver lost the device) from "Connection
# refused" (upsd down) from silence (timeout fired). Env is canonicalized via
# $(printf '%s' ...) — dockerd execs this probe with the RAW container env,
# not the entrypoint's canonicalize_validated_values copy, so a trailing-LF
# UPS_NAME/API_PORT/API_ADDRESS that boots fine would otherwise fail every probe.
# Canonicalize FIRST, default SECOND (mirroring the entrypoint's order): an
# LF-only value is non-empty raw, so defaulting from the raw value would pick
# the LF over the documented default and probe an empty name/address/port.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD . /usr/local/bin/lifecycle.sh; \
        UPS_NAME=$(printf '%s' "${UPS_NAME:-}"); : "${UPS_NAME:=ups}"; \
        API_PORT=$(printf '%s' "${API_PORT:-}"); : "${API_PORT:=3493}"; \
        API_ADDRESS=$(printf '%s' "${API_ADDRESS:-}"); : "${API_ADDRESS:=0.0.0.0}"; \
        timeout 3 upsc "${UPS_NAME}@$(upsd_probe_host):${API_PORT}" | grep -q 'ups.status' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
