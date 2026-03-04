# docker-nut-upsd

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-nut-upsd)](https://github.com/cplieger/docker-nut-upsd/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/nut-upsd/size)](https://github.com/cplieger/docker-nut-upsd/pkgs/container/nut-upsd)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine 3.23.3](https://img.shields.io/badge/base-Alpine_3.23.3-0D597F?logo=alpinelinux)

NUT UPS daemon with environment-variable-driven configuration

## Overview

Runs the Network UPS Tools (NUT) upsd daemon in an Alpine container.
The entrypoint script generates ups.conf, upsd.conf, upsd.users, and
upsmon.conf from environment variables at startup. Supports USB HID
UPS devices via device passthrough. Exposes the standard NUT protocol
on port 3493 for network UPS clients.

**Important:** This container is a NUT *server* — it monitors the UPS
hardware and serves status data to NUT clients over the network. It
cannot shut down the Docker host on battery critical events because
`SHUTDOWNCMD` runs inside the container. Each host that needs graceful
shutdown should run its own `upsmon` client pointing at this server.

**Example use case:** You have a USB UPS connected to one server and want
other machines on your network to monitor its status. This container
exposes the UPS over NUT's network protocol so any host can run `upsmon`
or a dashboard like [PeaNUT](https://github.com/Brandawg93/PeaNUT) to
track battery level, load, and runtime.

This is an Alpine-based container that runs as root — NUT requires
ownership changes on config files and USB device access at startup.

### How It Differs From Network UPS Tools (NUT)

The upstream [NUT](https://networkupstools.org/) requires manual
configuration file editing. This image generates all config files from
environment variables, making it fully declarative and Docker-native.
The entrypoint handles NUT's permission requirements and quiet init
flags automatically.

## Container Registries

This image is published to both GHCR and Docker Hub:

| Registry | Image |
|----------|-------|
| GHCR | `ghcr.io/cplieger/nut-upsd` |
| Docker Hub | `docker.io/cplieger/nut-upsd` |

```bash
# Pull from GHCR
docker pull ghcr.io/cplieger/nut-upsd:latest

# Pull from Docker Hub
docker pull cplieger/nut-upsd:latest
```

Both registries receive identical images and tags. Use whichever you prefer.

## Quick Start

```yaml
services:
  nut-upsd:
    image: ghcr.io/cplieger/nut-upsd:latest
    container_name: nut-upsd
    restart: unless-stopped
    user: "0:0"  # required for config file permissions
    mem_limit: 64m

    environment:
      TZ: "Europe/Paris"
      UPS_NAME: "ups"
      UPS_DESC: "My UPS"
      UPS_DRIVER: "usbhid-ups"  # see NUT hardware compatibility list
      UPS_PORT: "auto"  # auto = USB auto-detection
      API_USER: "monuser"
      API_PASSWORD: "secret"  # change from default

    ports:
      - "3493:3493"

    devices:
      - "/dev/bus/usb/001/001:/dev/bus/usb/001/001"  # find yours with: lsusb

    healthcheck:
      test:
        - CMD-SHELL
        - upsc $$UPS_NAME@localhost 2>&1 | grep -q 'ups.status' || exit 1
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s
```

## Deployment

1. Find your UPS USB device on the host:
   ```bash
   lsusb
   # Example output: Bus 001 Device 002: ID 0764:0501 Cyber Power System, Inc.
   # The device path is /dev/bus/usb/001/002
   ```
2. Update the `devices` section in the compose file with your device path (both sides of the `:`).
3. Set `UPS_DRIVER` to match your UPS model — see the [NUT hardware compatibility list](https://networkupstools.org/stable-hcl.html). Common drivers: `usbhid-ups` (most USB UPS), `blazer_usb` (some Megatec/Q1 protocol UPS).
4. Change `API_PASSWORD` from the default. NUT clients on your network use `API_USER` and `API_PASSWORD` to connect.
5. Port 3493 is the standard NUT protocol port. Point your NUT clients (e.g. `upsmon` on other hosts, [PeaNUT](https://github.com/Brandawg93/PeaNUT) dashboard) at `<host-ip>:3493`.
6. This container runs as root because NUT requires ownership changes on config files and USB devices at startup.

For additional configuration options not covered by this image's environment variables, refer to the [Network UPS Tools (NUT) documentation](https://networkupstools.org/docs/user-manual.chunked/index.html).

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone | `Europe/Paris` | No |
| `UPS_NAME` | NUT UPS identifier used in config files and queries | `ups` | No |
| `UPS_DESC` | Human-readable UPS description shown in NUT clients | `My UPS` | No |
| `UPS_DRIVER` | NUT driver for your UPS model (see NUT hardware compatibility list) | `usbhid-ups` | Yes |
| `UPS_PORT` | UPS device port — use `auto` for USB auto-detection | `auto` | No |
| `API_USER` | Username for NUT network clients to authenticate with | `monuser` | No |
| `API_PASSWORD` | Password for the NUT API user — change from default | `secret` | Yes |


## Ports

| Port | Description |
|------|-------------|
| `3493` | NUT protocol (upsd network clients) |

## Docker Healthcheck

The healthcheck queries the UPS status via the NUT protocol to verify
the driver is communicating with the UPS hardware.

**When it becomes unhealthy:**
- UPS device is disconnected or USB path changed after reboot
- UPS driver failed to start (wrong driver for the hardware)
- upsd daemon is not responding

**When it recovers:**
- UPS device is reconnected and the driver re-establishes communication.
  May require a container restart if the USB device path changed.

To check health manually:
```bash
docker inspect --format='{{json .State.Health.Log}}' nut-upsd | python3 -m json.tool
```

| Type | Command | Meaning |
|------|---------|---------|
| NUT protocol | `upsc $UPS_NAME@localhost` | Exit 0 = UPS driver is communicating |


## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| alpine | `3.23.3` | [Alpine](https://hub.docker.com/_/alpine) |

## Design Principles

- **Always up to date**: Base images, packages, and libraries are updated automatically via Renovate. Unlike many community Docker images that ship outdated or abandoned dependencies, these images receive continuous updates.
- **Minimal attack surface**: When possible, pure Go apps use `gcr.io/distroless/static:nonroot` (no shell, no package manager, runs as non-root). Apps requiring system packages use Alpine with the minimum necessary privileges.
- **Digest-pinned**: Every `FROM` instruction pins a SHA256 digest. All GitHub Actions are digest-pinned.
- **Multi-platform**: Built for `linux/amd64` and `linux/arm64`.
- **Healthchecks**: Every container includes a Docker healthcheck.
- **Provenance**: Build provenance is attested via GitHub Actions, verifiable with `gh attestation verify`.

## Contributing

Issues, suggestions, and pull requests are welcome.

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut) into a container image. All credit for the core functionality goes to the upstream maintainers.

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
