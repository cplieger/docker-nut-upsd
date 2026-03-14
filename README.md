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
hardware and serves status data to NUT clients over the network. By
default, `SHUTDOWNCMD` only logs inside the container. Each host that
needs graceful shutdown should run its own `upsmon` client pointing at
this server.

**Host shutdown support:** If you set `SHUTDOWN_ON_BATTERY_CRITICAL=true`
and mount the host's D-Bus socket (`/run/dbus/system_bus_socket`), the
container can power off the host via systemd when the UPS reaches
critical battery. This works on any systemd-based host without
switching to a Debian base image.

**Custom config override:** For advanced users, mount your own NUT
config files as `*.user` (e.g. `ups.conf.user`) into `/etc/nut/` and
the entrypoint will use them instead of generating from env vars.

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

Compared to other NUT Docker images:
- Stays on Alpine (not Debian) — smaller image, same functionality
- Supports host shutdown via D-Bus without installing systemd in the container
- Configurable low-battery and critical-battery thresholds via env vars
- Custom config override via `*.user` file mounts
- Configurable upsmon tuning (poll frequency, deadtime, etc.)
- Clean signal handling — SIGTERM gracefully stops all NUT services

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
      - /dev/bus/usb:/dev/bus/usb  # full bus — survives USB re-enumeration

    healthcheck:
      test:
        - CMD-SHELL
        - upsc $$UPS_NAME@127.0.0.1 2>&1 | grep -q 'ups.status' || exit 1
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
```

## Deployment

1. The compose file maps the entire USB bus (`/dev/bus/usb:/dev/bus/usb`)
   so the NUT driver can find the UPS regardless of device number changes
   after reboots or USB re-enumeration. Verify your UPS is visible:
   ```bash
   lsusb
   # Example output: Bus 001 Device 003: ID 0764:0601 Cyber Power System, Inc.
   ```
   > **Note:** Mapping the full bus exposes all USB devices to the container.
   > The NUT driver only opens the device it recognizes, but if you prefer
   > tighter isolation you can restrict the mapping to a specific device
   > (e.g. `/dev/bus/usb/001/003:/dev/bus/usb/001/003`). Keep in mind that
   > the device number may change after a reboot or USB re-enumeration, so
   > you would need to update the path when that happens.
2. Set `UPS_DRIVER` to match your UPS model — see the
   [NUT hardware compatibility list](https://networkupstools.org/stable-hcl.html).
   Common drivers: `usbhid-ups` (most USB UPS),
   `blazer_usb` (some Megatec/Q1 protocol UPS).
3. Change `API_PASSWORD` from the default. NUT clients on your
   network use `API_USER` and `API_PASSWORD` to connect.
4. Port 3493 is the standard NUT protocol port. Point your NUT
   clients (e.g. `upsmon` on other hosts,
   [PeaNUT](https://github.com/Brandawg93/PeaNUT) dashboard)
   at `<host-ip>:3493`.
5. This container runs as root because NUT requires ownership changes on config files and USB devices at startup.

**Host shutdown (optional):**
To enable automatic host poweroff on battery critical, add these to your
compose file:
```yaml
environment:
  SHUTDOWN_ON_BATTERY_CRITICAL: "true"
volumes:
  - /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
```
This uses D-Bus to call `org.freedesktop.login1.Manager.PowerOff` on
the host's systemd. Works on any systemd-based Linux distribution.

**Custom NUT config (advanced):**
Mount your own config files with a `.user` suffix to bypass env-var
generation:
```yaml
volumes:
  - ./ups.conf:/etc/nut/ups.conf.user:ro
  - ./upsd.users:/etc/nut/upsd.users.user:ro
```

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

### Additional Environment Variables

The following optional environment variables are also supported but not included in the compose example above. Add them to your `environment:` block as needed.

**Network configuration:**

| Variable | Description | Default |
|----------|-------------|---------|
| `API_ADDRESS` | Listen address for upsd | `0.0.0.0` |
| `API_PORT` | Listen port for upsd | `3493` |

**Battery threshold overrides:**

Override when the UPS reports low or critical battery. Setting any of
these variables automatically enables `ignorelb` in ups.conf, telling
NUT to use your thresholds instead of the hardware defaults.

| Variable | Description | Default |
|----------|-------------|---------|
| `LOWBATT_PERCENT` | Low-battery threshold percentage | Hardware default |
| `LOWBATT_RUNTIME` | Low-battery threshold runtime (seconds) | Hardware default |
| `CRITBATT_PERCENT` | Critical-battery threshold percentage | Hardware default |
| `CRITBATT_RUNTIME` | Critical-battery threshold runtime (seconds) | Hardware default |

**upsmon tuning:**

| Variable | Description | Default |
|----------|-------------|---------|
| `POLLFREQ` | Seconds between UPS status polls | `5` |
| `POLLFREQALERT` | Seconds between polls when on battery | `5` |
| `DEADTIME` | Seconds before declaring UPS stale | `15` |
| `FINALDELAY` | Seconds between shutdown warning and actual shutdown | `5` |
| `HOSTSYNC` | Seconds to wait for secondary hosts to disconnect | `15` |
| `NOCOMMWARNTIME` | Seconds before warning about lost UPS communication | `300` |
| `RBWARNTIME` | Seconds between "replace battery" warnings | `43200` |

**Host shutdown:**

| Variable | Description | Default |
|----------|-------------|---------|
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off host via D-Bus on battery critical | `false` |

Requires mounting `/run/dbus/system_bus_socket` from the host. See
Deployment section above for details.

**Authentication:**

| Variable | Description | Default |
|----------|-------------|---------|
| `ADMIN_PASSWORD` | Password for the NUT admin user (set/FSD actions) | Random |


## Ports

| Port | Description |
|------|-------------|
| `3493` | NUT protocol (upsd network clients) |


## Docker Healthcheck

The healthcheck queries the UPS status via the NUT protocol to verify
the driver is communicating with the UPS hardware.

**When it becomes unhealthy:**
- UPS device is disconnected or powered off
- UPS driver failed to start (wrong driver for the hardware)
- upsd daemon is not responding

**When it recovers:**
- UPS device is reconnected and the driver re-establishes communication. The entire USB bus is mapped, so device number changes after reconnection are handled automatically. A container restart may still be needed for the driver to re-detect the device.

To check health manually:
```bash
docker inspect --format='{{json .State.Health.Log}}' nut-upsd | python3 -m json.tool
```

| Type | Command | Meaning |
|------|---------|---------|
| NUT protocol | `upsc $UPS_NAME@127.0.0.1` | Exit 0 = UPS driver is communicating |


## Code Quality

| Metric | Value |
|--------|-------|
| Language | POSIX shell (Alpine) |
| Entrypoint | 252 lines |
| Static Analysis | [ShellCheck](https://www.shellcheck.net/) (enforced in CI) |
| Validation Tests | 177 |
| Input Validation | Newline injection, numeric, bracket injection |

The entrypoint generates NUT config files from environment variables
with security-focused input validation: all values are checked for
embedded newlines (prevents config injection), bracket characters
(prevents INI section injection), and numeric parameters are
validated as positive integers. The validation logic is tested via
a shared reference library with 177 tests. ShellCheck enforced in CI.

Not tested via unit tests: the config file generation and NUT daemon
startup — validated on first deploy via the NUT protocol healthcheck
(queries the UPS directly).

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

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut) into a container image. All credit for the core functionality goes to the upstream maintainers.

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
