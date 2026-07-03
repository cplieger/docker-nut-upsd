# check=error=true

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache automake build-base clang libtool lld perl pkgconf \
        gcc musl-dev libusb-compat-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.2.0
WORKDIR /build/libmodbus
# libmodbus 3.2.0 added termios2 custom-baud support whose configure check
# mis-detects on Alpine/musl: `struct termios2` is present (via <asm/termbits.h>)
# so HAVE_STRUCT_TERMIOS2 gets set, but TCGETS2/TCSETS2 are not usable from
# <sys/ioctl.h> on musl, so modbus-rtu.c fails to compile. Force the type check
# off to build the portable classic-termios path (as 3.1.x did); this image is
# USB-HID/SNMP only, so custom-baud RTU is irrelevant. Remove once upstream
# libmodbus builds cleanly on musl.
RUN wget -qO- \
      "https://github.com/stephane/libmodbus/releases/download/${LIBMODBUS_VERSION}/libmodbus-${LIBMODBUS_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
    && ac_cv_type_struct_termios2=no \
       ./configure --prefix=/usr --disable-static \
       CC=clang \
    && make -j"$(nproc)" \
    && make install

# renovate: datasource=github-tags depName=net-snmp/net-snmp
ARG NETSNMP_VERSION=v5.9.5.2
WORKDIR /build/netsnmp
# The conditional netsnmp.pc fallback below writes literal ${prefix}/${libdir}
# for pkg-config to expand at consume time, NOT the shell — hence the
# single-quoted printf format string. SC2016 is a false positive here.
# hadolint ignore=SC2016
RUN wget -qO- \
      "https://github.com/net-snmp/net-snmp/archive/refs/tags/${NETSNMP_VERSION}.tar.gz" \
      | tar xz --strip-components=1 \
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
           "$(echo "${NETSNMP_VERSION}" | sed 's/^v//')" \
           > /usr/lib/pkgconfig/netsnmp.pc; \
       fi

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=v2.8.5
WORKDIR /build/nut
RUN wget -qO- \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
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
    && install -d -m 770 -o nut -g nut /etc/nut

COPY --from=builder /out/usr/lib/libmodbus* /usr/lib/
COPY --from=builder /out/usr/lib/libnetsnmp* /usr/lib/
COPY --from=builder /out/usr/sbin/upsd \
     /out/usr/sbin/upsmon \
     /out/usr/sbin/upsdrvctl /usr/sbin/
COPY --from=builder /out/usr/bin/upsc /usr/bin/
COPY --from=builder /out/usr/lib/nut/ /usr/lib/nut/
COPY --from=builder /out/usr/share/nut/ /usr/share/nut/
COPY --from=builder /out/usr/share/cmdvartab /usr/share/cmdvartab

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
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD timeout 3 upsc "${UPS_NAME:-ups}@127.0.0.1:${API_PORT:-3493}" 2>/dev/null | grep -q 'ups.status' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
