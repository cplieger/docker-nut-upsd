# check=error=true
FROM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659

RUN apk add --no-cache \
        dbus \
        libusb-compat \
        nut \
        util-linux-misc \
    && install -d -m 770 -o nut -g nut /var/run/nut \
    && install -d -m 770 -o nut -g nut /etc/nut
ENV NUT_QUIET_INIT_UPSNOTIFY=true \
    NUT_QUIET_INIT_SSL=true
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
EXPOSE 3493
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
