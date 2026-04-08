# check=error=true
# renovate: datasource=docker depName=tonistiigi/xx
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.9.0@sha256:c64defb9ed5a91eacb37f96ccc3d4cd72521c4bd18d5442905b95e2226b0e707 AS xx

FROM --platform=$BUILDPLATFORM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS builder

COPY --from=xx / /
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache automake build-base clang libtool lld perl pkgconf

ARG TARGETPLATFORM
RUN xx-apk add --no-cache \
        gcc musl-dev libusb-compat-dev openssl-dev linux-headers

# renovate: datasource=github-releases depName=stephane/libmodbus
ARG LIBMODBUS_VERSION=v3.1.12
WORKDIR /build/libmodbus
RUN SYSROOT=$(xx-info sysroot) \
    && wget -qO- \
      "https://github.com/stephane/libmodbus/releases/download/${LIBMODBUS_VERSION}/libmodbus-${LIBMODBUS_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
    && ./configure --prefix=/usr --disable-static \
       --host="$(xx-clang --print-target-triple)" \
       CC=xx-clang \
    && make -j"$(nproc)" -C src \
    && mkdir -p "${SYSROOT}/usr/lib" "${SYSROOT}/usr/include/modbus" \
       "${SYSROOT}/usr/lib/pkgconfig" \
    && xx-clang -shared -o "${SYSROOT}/usr/lib/libmodbus.so.5.1.0" \
       src/.libs/modbus.o src/.libs/modbus-data.o \
       src/.libs/modbus-rtu.o src/.libs/modbus-tcp.o \
       -Wl,-soname,libmodbus.so.5 \
    && ln -s libmodbus.so.5.1.0 "${SYSROOT}/usr/lib/libmodbus.so.5" \
    && ln -s libmodbus.so.5.1.0 "${SYSROOT}/usr/lib/libmodbus.so" \
    && cp src/modbus.h src/modbus-version.h src/modbus-rtu.h \
       src/modbus-tcp.h "${SYSROOT}/usr/include/modbus/" \
    && cp libmodbus.pc "${SYSROOT}/usr/lib/pkgconfig/"

# renovate: datasource=github-tags depName=net-snmp/net-snmp
ARG NETSNMP_VERSION=v5.9.5.2
WORKDIR /build/netsnmp
RUN SYSROOT=$(xx-info sysroot) \
    && wget -qO- \
      "https://github.com/net-snmp/net-snmp/archive/refs/tags/${NETSNMP_VERSION}.tar.gz" \
      | tar xz --strip-components=1 \
    && ./configure --prefix=/usr --disable-static \
       --build="$(uname -m)-linux-musl" \
       --host="$(xx-clang --print-target-triple)" \
       CC=xx-clang \
       --with-defaults \
       --disable-applications \
       --disable-manuals --disable-scripts --disable-mibs \
       --enable-shared --with-openssl \
    && make -j"$(nproc)" -C snmplib \
    && mkdir -p "${SYSROOT}/usr/lib" \
    && xx-clang -shared -o "${SYSROOT}/usr/lib/libnetsnmp.so.45.0.0" \
       snmplib/.libs/*.o -lssl -lcrypto \
    && ln -s libnetsnmp.so.45.0.0 "${SYSROOT}/usr/lib/libnetsnmp.so.45" \
    && ln -s libnetsnmp.so.45.0.0 "${SYSROOT}/usr/lib/libnetsnmp.so" \
    && cp -r include/net-snmp "${SYSROOT}/usr/include/"

# renovate: datasource=github-releases depName=networkupstools/nut
ARG NUT_VERSION=2.8.5
WORKDIR /build/nut
RUN SYSROOT=$(xx-info sysroot) \
    && wget -qO- \
      "https://github.com/networkupstools/nut/releases/download/${NUT_VERSION}/nut-${NUT_VERSION#v}.tar.gz" \
      | tar xz --strip-components=1 \
    && sed -i 's/as_fn_error.*Net-SNMP libraries not found/: #/' configure \
    && PKG_CONFIG_SYSROOT_DIR="${SYSROOT}" \
       PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/pkgconfig" \
       LIBS="-lssl -lcrypto" \
       ac_cv_func_setpgrp_void=yes \
       ac_cv_func_memcmp_working=yes \
       ac_cv_func_mmap_fixed_mapped=yes \
       ac_cv_lib_netsnmp_init_snmp=yes \
       ./configure --prefix=/usr --sysconfdir=/etc/nut \
       --with-statepath=/var/run/nut \
       --with-drvpath=/usr/lib/nut \
       --with-user=nut --with-group=nut \
       --host="$(xx-clang --print-target-triple)" \
       CC=xx-clang CXX="xx-clang++" \
       --with-usb --with-snmp --with-modbus \
       --with-snmp-includes="-I${SYSROOT}/usr/include" \
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
    && xx-verify /out/usr/sbin/upsd \
    && cp "${SYSROOT}/usr/lib/libmodbus.so"* /out/usr/lib/ \
    && cp "${SYSROOT}/usr/lib/libnetsnmp.so"* /out/usr/lib/

FROM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659

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
EXPOSE 3493
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
