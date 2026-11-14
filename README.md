# docker-nut-upsd

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-nut-upsd/badges/size.json)](https://github.com/cplieger/docker-nut-upsd/pkgs/container/docker-nut-upsd) [![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)](https://github.com/cplieger/docker-nut-upsd/pkgs/container/docker-nut-upsd) [![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)](https://github.com/cplieger/docker-nut-upsd/blob/main/Dockerfile) [![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-nut-upsd/releases)

<!-- hub-overview BEGIN -->
docker-nut-upsd runs Network UPS Tools (NUT) on the machine your UPS plugs into and shares the UPS with every machine on the same power. It has no web page.

## What it does

Your NAS, servers and other NUT clients shut down cleanly on low battery, and Home Assistant shows the UPS status.

- Sets up NUT from a few compose settings, with no NUT config files to write.
- Works with USB, serial, Modbus and network (SNMP) UPSes, on `amd64` and `arm64`.
- Reconnects to a UPS that drops off USB and comes back, without a container restart.
- Encrypts the connection for clients that support TLS, and still serves the others.
- Can also power off this machine on low battery. This is off by default.

## Who it is for

docker-nut-upsd is built for a UPS on an always-on Linux machine that runs Docker, shared with every machine on the same power. It checks every setting before it starts and ships UPS metrics and alert rules. You need a UPS listed on the [NUT hardware list](https://networkupstools.org/stable-hcl.html), connected to that machine by USB, serial or the network.

Two other projects suit a different setup:

- Consider [NUT for Unraid](https://github.com/desertwitch/NUT-unRAID) if your UPS plugs into an Unraid server. The plugin adds NUT to Unraid itself, with a settings frontend. Its maintainer ends support on 30 November 2026.
- Consider [gpdm/nut-upsd](https://github.com/gpdm/nut/blob/master/nut-upsd/README.md) if you want one container to monitor several UPSes from NUT config files you write.

docker-nut-upsd is free software under the Apache-2.0 license.
<!-- hub-overview END -->

## Quick start

The image is on GitHub Container Registry and Docker Hub, for `amd64` and `arm64`. It builds the NUT release that the `NUT_VERSION` line of the [`Dockerfile`](Dockerfile) names. This is the [`compose.yaml`](compose.yaml) in this repository.

```yaml
services:
  nut-upsd:
    image: ghcr.io/cplieger/docker-nut-upsd:latest
    container_name: nut-upsd
    restart: unless-stopped

    environment:
      UPS_NAME: "ups"
      UPS_DESC: "My UPS"
      UPS_DRIVER: "usbhid-ups"  # the driver the NUT hardware list names for your UPS model
      UPS_PORT: "auto"  # auto finds a USB UPS. For serial and network UPSes, see docs/configuration.md
      API_USER: "monuser"
      API_PASSWORD: "secret"  # your NUT clients log in with it. If no Synology NAS uses this server, change it

    ports:
      - "3493:3493"

    # Keep both USB lines below. They let the driver reach the UPS again after it
    # drops off USB and comes back, which a devices: mapping cannot do.
    device_cgroup_rules:
      - "c 189:* rmw"
    volumes:
      - "/dev/bus/usb:/dev/bus/usb"
```

1. Find your UPS model on the [NUT hardware list](https://networkupstools.org/stable-hcl.html) and set `UPS_DRIVER` to the driver it names.
2. If no Synology NAS will use this server, change `API_PASSWORD` to a password of 12 characters or more. If a Synology NAS will use this server, keep `API_USER`, `API_PASSWORD` and `UPS_NAME` as they are. It logs in only as `monuser` with `secret`, to a UPS named `ups`.
3. Run `docker compose up -d`.

Run `docker logs nut-upsd`. You should see `NUT services started; supervising upsmon`. If you see `upsdrvctl start failed or timed out at boot`, the driver could not reach the UPS. Check `UPS_DRIVER` and the USB cable.

## Connecting your other machines

Point each NUT client at this machine on port 3493, with `API_USER` and `API_PASSWORD`. Use the address other devices on your network reach this machine at, such as `192.0.2.10`, not `localhost`.

- In Home Assistant, open Settings > Devices & services and add the [Network UPS Tools (NUT)](https://www.home-assistant.io/integrations/nut/) integration. `API_USER` can read the UPS but cannot run UPS commands, such as a battery test, from Home Assistant.
- On a Synology NAS, open Control Panel > Hardware & Power > UPS, turn on UPS support, choose Synology UPS server and enter this machine's address. The NAS needs the defaults `monuser`, `secret` and `ups`.
- On a Linux machine that runs NUT's `upsmon`, add this line to `upsmon.conf`:

```text
MONITOR ups@192.0.2.10:3493 1 monuser your-password secondary
```

When the battery runs low, this server tells every client to shut down and waits up to `HOSTSYNC` seconds (default 15) for them to log off. One container serves one UPS, and [More than one UPS](docs/configuration.md#more-than-one-ups) covers a second one.

## Configuration reference

Settings are environment variables in `compose.yaml`. The container reads them at each start and writes NUT's config files from them, so recreate it with `docker compose up -d` after a change.

| Variable | Description | Default |
| --- | --- | --- |
| `UPS_NAME` | Name of the UPS that clients ask for, as in `ups@host` | `ups` |
| `UPS_DRIVER` | NUT driver for your UPS model, from the [NUT hardware list](https://networkupstools.org/stable-hcl.html) | `usbhid-ups` |
| `UPS_PORT` | `auto` for USB, a device node such as `/dev/ttyUSB0` for serial, or `host[:port]` for a network UPS | `auto` |
| `API_USER` | User name your NUT clients log in with. Letters, numbers, `_` and `-` | `monuser` |
| `API_PASSWORD` | Password for `API_USER`. Use 12 characters or more. No `"`, `\` or `#` | `secret` |
| `ADMIN_PASSWORD` | Password for the `admin` account, which can run UPS commands. When unset, one is generated and kept until the container is recreated | Random |
| `API_TLS` | Offer TLS encryption to clients that ask for it | `true` |
| `LOWBATT_PERCENT` | Battery percentage at which the UPS counts as low. `0` turns this threshold off | Hardware default |
| `LOWBATT_RUNTIME` | Seconds of runtime left at which the UPS counts as low. `0` turns this threshold off | Hardware default |
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off the machine running this container when the battery is critical | `false` |
| `COMMS_WATCHDOG` | Restart the UPS driver when the UPS stops answering, such as after it drops off USB | `true` |
| `METRICS_PORT` | Port the built-in exporter serves Prometheus metrics and `/healthz` on. `0` starts no exporter. Must differ from `API_PORT`. Published only if you map it | `9199` |

[Configuration](docs/configuration.md) lists every setting, including `UPS_DESC` and the exporter's `METRICS_ADDRESS`, and covers serial and network UPSes, low-battery thresholds, host shutdown and your own NUT config files.

| Mount | Description |
| --- | --- |
| `/dev/bus/usb` | The USB bus, bound live under `volumes:`. Needed for a USB UPS, and for a driver that supports serial and USB when `UPS_PORT` is `auto` |
| `/run/dbus/system_bus_socket` | Host D-Bus socket. Needed only with `SHUTDOWN_ON_BATTERY_CRITICAL=true` |
| `/etc/nut/{ups.conf,upsd.conf,upsd.users,upsmon.conf}.user` | Your own NUT config files, replacing the generated ones |
| `/etc/nut/upsd.pem` | Your own TLS certificate and private key in one PEM file. Never modified, so mount it read-only |

| Port | Description |
| --- | --- |
| `3493` | The NUT protocol, for your NUT clients |
| `9199` | Prometheus metrics at `/metrics` and the health check at `/healthz`, with no login. Publish it only to your monitoring network |

## Security

Your clients shut down on what this server reports, and anyone who can reach port 3493 can read the UPS status without a password. Keep port 3493 and the metrics port on your network. Change `API_PASSWORD` from `secret` unless a Synology NAS uses this server.

TLS is on by default, with a certificate the container creates. A client that skips the certificate check gets encryption but cannot tell this server from an impostor. The PEM file inside the container holds the private key, so export only the certificate, as [Security](docs/hardening.md#tls-starttls) shows.

The container starts as root, then runs the UPS driver and the server as its `nut` user. So the UPS driver can reach the UPS, the container gives every USB device on the host to its `nut` group. Members of a host group with the same numeric group ID can then read and write those devices. Host shutdown fails when Docker remaps user namespaces and the host keeps systemd-logind's default policy. [Security](docs/hardening.md) covers the rest.

## Troubleshooting

An unhealthy container means the UPS is unplugged, the driver failed, or the server stopped answering. The container recovers on its own once the UPS answers again. If the server stops answering for about a minute, the container exits and your restart policy starts it again.

- The log shows `/dev/bus/usb not found`. Put back the two USB lines from the example.
- The container stops with `env var contains` and a character name. Remove that character from the variable the line names.
- With host shutdown off, the container restarts again and again after the battery ran low. That is expected until mains power returns, because `upsmon` exits after each forced shutdown and the container exits with it.

[How docker-nut-upsd works](docs/how-it-works.md) explains the watchdog timing and every planned exit.

## Monitoring

docker-nut-upsd serves Prometheus metrics on port 9199 and logs each UPS event, such as `event="ONBATT"`. Alert rules for Prometheus and for Loki ship in [`alerts/`](alerts/), and [`grafana-dashboard.json`](grafana-dashboard.json) is a UPS dashboard for Grafana 13.2 or newer. [Monitoring and alerts](docs/monitoring.md) says which rules to load, and how to run your own `NOTIFYCMD` script on each UPS event. The image has a Docker healthcheck, and [Knowing the app is alive](docs/monitoring.md#knowing-the-app-is-alive) says what it proves and who is told.

## Documentation

- [Configuration](docs/configuration.md) lists every setting, for serial, network and custom setups.
- [How docker-nut-upsd works](docs/how-it-works.md) explains recovery, the healthcheck and planned exits.
- [Security](docs/hardening.md) covers TLS, privileges and the image contents.
- [Monitoring and alerts](docs/monitoring.md) lists the metrics, the log lines, both rule files and which groups to load.
- [How each alert rule works](docs/alert-rules.md) explains each rule's window, its source and what to check when it fires.

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut), licensed GPL-2.0-or-later, into a container image. All credit for the core functionality goes to the upstream maintainers.

- [libmodbus](https://github.com/stephane/libmodbus), licensed LGPL-2.1, by [@stephane](https://github.com/stephane), is the Modbus library NUT's Modbus drivers use.
- [Net-SNMP](https://github.com/net-snmp/net-snmp) is the SNMP library NUT's `snmp-ups` driver uses.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI assistance. The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).

The image carries the license text of every bundled component under `/usr/share/licenses/`. The Alpine packages in the image ship no license file upstream, so their license texts are kept under `licenses/` in this repository and copied in.

The image packages [Network UPS Tools](https://github.com/networkupstools/nut) (GPL-2.0-or-later), compiled from the release tarball the Dockerfile fetches at the version its `NUT_VERSION` argument pins (`https://github.com/networkupstools/nut/releases/download/<version>/nut-<version>.tar.gz`), and links [libmodbus](https://github.com/stephane/libmodbus) and [Net-SNMP](https://github.com/net-snmp/net-snmp), each compiled the same way from the tarball its own version argument pins. Each component's own license text is in that tree.

The build applies checked-in backports of upstream NUT source, so those files stay GPL-2.0-or-later:

- `patches/cve-2026-54161-notifycmd-execvp.patch` backports upstream commit `ecf98e7542e4ae2b62b211622ee26989274b2220`.
- `patches/libusb-exit-reconnect-deadlock.patch` backports upstream commit `bfbba15928aa6a91b3e4b8943e0cad16199d9d48`.
- `patches/libusb-rdlens-oob-read.patch` backports upstream commit `edc06fb39435b892d5daeec53cb4845cb12d1d50`.
- `patches/richcomm-libusb-context-reopen.patch` backports upstream commit `ce2364e2b1e79406248be50b01a031db67c1c9fd`.

This repository's `Dockerfile` and those patch files are the complete recipe for the NUT, libmodbus and Net-SNMP binaries the image ships: the corresponding source is the upstream tarball each pin names, with the patches above applied.
