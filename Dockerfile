# check=error=true

FROM alpine:3.24.0@sha256:660e0827bd401543d81323d4886abbd08fda0fe3ba84337837d0b11a67251283 AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache automake build-base clang libtool lld perl pkgconf \
        gcc musl-dev libusb-compat-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.1.12
WORKDIR /build/libmodbus
RUN wget -qO- \
      "https://github.com/stephane/libmodbus/releases/download/${LIBMODBUS_VERSION}/libmodbus-${LIBMODBUS_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
    && ./configure --prefix=/usr --disable-static \
       CC=clang \
    && make -j"$(nproc)" -C src \
    && mkdir -p /usr/lib /usr/include/modbus \
       /usr/lib/pkgconfig \
    && clang -shared -o /usr/lib/libmodbus.so.5.1.0 \
       src/.libs/modbus.o src/.libs/modbus-data.o \
       src/.libs/modbus-rtu.o src/.libs/modbus-tcp.o \
       -Wl,-soname,libmodbus.so.5 \
    && ln -s libmodbus.so.5.1.0 /usr/lib/libmodbus.so.5 \
    && ln -s libmodbus.so.5.1.0 /usr/lib/libmodbus.so \
    && cp src/modbus.h src/modbus-version.h src/modbus-rtu.h \
       src/modbus-tcp.h /usr/include/modbus/ \
    && cp libmodbus.pc /usr/lib/pkgconfig/

# renovate: datasource=github-tags depName=net-snmp/net-snmp
ARG NETSNMP_VERSION=v5.9.5.2
WORKDIR /build/netsnmp
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
    && mkdir -p /usr/lib \
    && clang -shared -o /usr/lib/libnetsnmp.so.45.0.0 \
       snmplib/.libs/*.o -lssl -lcrypto \
    && ln -s libnetsnmp.so.45.0.0 /usr/lib/libnetsnmp.so.45 \
    && ln -s libnetsnmp.so.45.0.0 /usr/lib/libnetsnmp.so \
    && cp -r include/net-snmp /usr/include/

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=v2.8.5
WORKDIR /build/nut
RUN wget -qO- \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
    && sed -i 's/as_fn_error.*Net-SNMP libraries not found/: #/' configure \
    && PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig" \
       LIBS="-lssl -lcrypto" \
       ac_cv_func_setpgrp_void=yes \
       ac_cv_func_memcmp_working=yes \
       ac_cv_func_mmap_fixed_mapped=yes \
       ac_cv_lib_netsnmp_init_snmp=yes \
       ./configure --prefix=/usr --sysconfdir=/etc/nut \
       --with-statepath=/var/run/nut \
       --with-drvpath=/usr/lib/nut \
       --with-user=nut --with-group=nut \
       CC=clang CXX=clang++ \
       --with-usb --with-snmp --with-modbus \
       --with-snmp-includes="-I/usr/include" \
       --with-snmp-libs="-lnetsnmp -lssl -lcrypto" \
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

FROM alpine:3.24.0@sha256:660e0827bd401543d81323d4886abbd08fda0fe3ba84337837d0b11a67251283

RUN apk add --no-cache \
        dbus \
        libusb-compat \
        openssl \
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

# Note: this image runs as root by design — NUT needs root at init for USB
# device access (upsdrvctl) and to chown the runtime directories. The upsd
# daemon drops to user "nut" internally via the build-time configure flags
# (--with-user=nut --with-group=nut). AVD-DS-0002 is suppressed via
# .trivyignore at the repo root; see the rationale there.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD timeout 3 upsc "$UPS_NAME@127.0.0.1" 2>/dev/null | grep -q 'ups.status' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
