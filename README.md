# docker-nut-upsd

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-nut-upsd/badges/size.json)](https://github.com/cplieger/docker-nut-upsd/pkgs/container/docker-nut-upsd)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13206/badge)](https://www.bestpractices.dev/projects/13206)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-nut-upsd/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-nut-upsd)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-nut-upsd/releases)

Monitor your UPS and let networked machines shut down gracefully during power outages.

## What it does

Monitors your UPS (uninterruptible power supply) and exposes its status over the network so other machines can shut down gracefully during a power outage.

The container runs the Network UPS Tools (NUT) upsd daemon in Alpine Linux. The entrypoint script generates all NUT configuration files (`ups.conf`, `upsd.conf`, `upsd.users`, `upsmon.conf`) from environment variables at startup.

- Supports USB HID, Modbus, and SNMP UPS devices
- Exposes the standard NUT protocol on port 3493 for network clients
- Optional host shutdown via D-Bus when the UPS reaches critical battery (`SHUTDOWN_ON_BATTERY_CRITICAL=true`)
- Survives UPS-initiated USB re-enumeration — a built-in comms watchdog re-homes the driver onto the re-enumerated device automatically (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery))
- Custom config override: mount your own NUT config files as `*.user` (e.g. `ups.conf.user`) into `/etc/nut/` to bypass env-var generation
- Configurable low-battery and critical-battery thresholds
- Clean signal handling — SIGTERM gracefully stops all NUT services

### Why this design

- **Environment-variable config** — no need to hand-edit `nut.conf` files; the entrypoint generates them declaratively from env vars
- **Single container replaces three daemons** — bundles the NUT driver, `upsd`, and `upsmon` so you deploy one service instead of three
- **Minimal Alpine base** — small image with only the packages NUT needs; no extras that increase attack surface
- **Compiled from upstream sources** — NUT, libmodbus, and net-snmp built from latest upstream (not distro packages); see [Security](#security) for the resulting CVE posture

## Quick start

Available from both `ghcr.io/cplieger/docker-nut-upsd` and `docker.io/cplieger/docker-nut-upsd` — identical images and tags.

```yaml
services:
  nut-upsd:
    image: ghcr.io/cplieger/docker-nut-upsd:latest
    container_name: nut-upsd
    restart: unless-stopped
    user: "0:0"  # required for config file permissions + USB access

    # Block setuid privilege escalation. Safe for NUT: it only drops
    # privileges (root -> nut after opening the device), never gains them.
    security_opt:
      - no-new-privileges:true

    environment:
      TZ: "Europe/Paris"
      UPS_NAME: "ups"
      UPS_DESC: "My UPS"
      UPS_DRIVER: "usbhid-ups"  # see NUT hardware compatibility list
      UPS_PORT: "auto"  # auto = USB auto-detection
      API_USER: "monuser"
      API_PASSWORD: "secret"  # rotate if your NUT client supports custom credentials
      # Comms recovery watchdog (defaults shown; on by default). See "USB
      # hotplug & comms recovery" below.
      COMMS_WATCHDOG: "true"
      COMMS_RECOVERY_TIMEOUT: "90"

    ports:
      - "3493:3493"

    # USB hotplug — see "USB hotplug & comms recovery" below. Allow the whole
    # USB major at the cgroup AND bind the bus live so a UPS that re-enumerates
    # stays reachable without recreating the container.
    device_cgroup_rules:
      - "c 189:* rmw"
    volumes:
      - /dev/bus/usb:/dev/bus/usb
```

## Configuration reference

### Environment variables

| Variable                       | Description                                                                                               | Default          |
| ------------------------------ | --------------------------------------------------------------------------------------------------------- | ---------------- |
| `TZ`                           | Container timezone                                                                                        | `Europe/Paris`   |
| `UPS_NAME`                     | NUT UPS identifier used in config files and queries                                                       | `ups`            |
| `UPS_DESC`                     | Human-readable UPS description shown in NUT clients                                                       | `My UPS`         |
| `UPS_DRIVER`                   | NUT driver for your UPS model (see [NUT HCL](https://networkupstools.org/stable-hcl.html))                | `usbhid-ups`     |
| `UPS_PORT`                     | UPS device port — use `auto` for USB auto-detection                                                       | `auto`           |
| `API_USER`                     | Username for NUT network clients to authenticate with                                                     | `monuser`        |
| `API_PASSWORD`                 | Password for the NUT API user (entrypoint warns on weak credentials)                                      | `secret`         |
| `API_ADDRESS`                  | Listen address for upsd                                                                                   | `0.0.0.0`        |
| `API_PORT`                     | Listen port for upsd                                                                                      | `3493`           |
| `LOWBATT_PERCENT`              | Low-battery threshold percentage (enables `ignorelb`)                                                     | Hardware default |
| `LOWBATT_RUNTIME`              | Low-battery threshold runtime in seconds (enables `ignorelb`)                                             | Hardware default |
| `CRITBATT_PERCENT`             | Critical-battery threshold percentage (enables `ignorelb`)                                                | Hardware default |
| `CRITBATT_RUNTIME`             | Critical-battery threshold runtime in seconds (enables `ignorelb`)                                        | Hardware default |
| `POLLFREQ`                     | Seconds between UPS status polls                                                                          | `5`              |
| `POLLFREQALERT`                | Seconds between polls when on battery                                                                     | `5`              |
| `DEADTIME`                     | Seconds before declaring UPS stale                                                                        | `15`             |
| `FINALDELAY`                   | Seconds between shutdown warning and actual shutdown                                                      | `5`              |
| `HOSTSYNC`                     | Seconds to wait for secondary hosts to disconnect                                                         | `15`             |
| `NOCOMMWARNTIME`               | Seconds before warning about lost UPS communication                                                       | `300`            |
| `RBWARNTIME`                   | Seconds between "replace battery" warnings                                                                | `43200`          |
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off host via D-Bus on battery critical                                                              | `false`          |
| `ADMIN_PASSWORD`               | Password for the NUT admin user (set/FSD actions); auto-generated if unset                                | Random (cached)  |
| `COMMS_WATCHDOG`               | Enable the USB comms-recovery watchdog (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery)) | `true`           |
| `COMMS_CHECK_INTERVAL`         | Seconds between watchdog comms probes                                                                     | `15`             |
| `COMMS_RECOVERY_TIMEOUT`       | Seconds of continuous stale comms before the watchdog re-homes the driver                                 | `90`             |
| `COMMS_FAST_RETRIES`           | Fast (stage-1) restart attempts before backing off; see recovery notes below                              | `3`              |
| `COMMS_BACKOFF_FACTOR`         | Stage-2 cadence multiplier on COMMS_RECOVERY_TIMEOUT once fast retries spent                              | `5`              |

### Volumes

| Mount                         | Description                                                                      |
| ----------------------------- | -------------------------------------------------------------------------------- |
| `/dev/bus/usb`                | USB bus, bound live (not `devices:`) so re-enumerated nodes stay reachable       |
| `/run/dbus/system_bus_socket` | Host D-Bus socket (required only if `SHUTDOWN_ON_BATTERY_CRITICAL=true`)         |
| `/etc/nut/*.user`             | Custom NUT config overrides (e.g. `ups.conf.user`) — bypasses env-var generation |

> For a USB UPS, pair the live `/dev/bus/usb` bind with `device_cgroup_rules: ["c 189:* rmw"]` (USB major 189). A static `devices:` mapping is **not** sufficient — see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery).

## Healthcheck

The built-in healthcheck runs `upsc $UPS_NAME@127.0.0.1` to verify the NUT driver is communicating with the UPS hardware. It becomes unhealthy when the UPS device is disconnected, the driver failed to start, or upsd is not responding, and recovers once the device is reconnected and the driver re-establishes communication. The [comms watchdog](#usb-hotplug--comms-recovery) actively drives that recovery after a USB re-enumeration, so the unhealthy window is bounded by `COMMS_RECOVERY_TIMEOUT` rather than lasting until you recreate the container.

## USB hotplug & comms recovery

Many USB UPSes — the CyberPower Elite PFC line is a well-known example ([networkupstools/nut#1786](https://github.com/networkupstools/nut/issues/1786)) — drop and re-establish their USB link periodically on their own firmware resets. Each reset **re-enumerates** the UPS to a new `/dev/bus/usb` node (a fresh device number, hence a new device minor), owned `root:root` by the kernel.

This breaks the naive passthrough in two ways:

1. **Visibility.** Docker's `devices: - /dev/bus/usb:/dev/bus/usb` maps only the device nodes present at container start. A node created later by a re-enumeration never appears inside the container. Fix: bind the bus **live** with `volumes: - /dev/bus/usb:/dev/bus/usb` (a real bind mount reflects nodes the host creates afterwards).
2. **Access.** The container's cgroup device allowlist only permits the device minors present at start, and the new node is created `root:root` while the driver runs as the unprivileged `nut` user. Fix: `device_cgroup_rules: - "c 189:* rmw"` permits any USB-major (189) minor.

With both in place, the **comms watchdog** (on by default) closes the loop: it probes `upsd` every `COMMS_CHECK_INTERVAL` seconds and, after `COMMS_RECOVERY_TIMEOUT` seconds of continuous stale data, re-asserts the `nut` group on the bus and restarts the driver. The restart re-opens the device while still root (the driver only drops to `nut` after opening), so it binds the re-enumerated node cleanly.

Recovery is **two-stage** so it stays fast for a transient reset without thrashing a genuinely-absent UPS. For the first `COMMS_FAST_RETRIES` attempts it retries every `COMMS_RECOVERY_TIMEOUT` (default 3 × 90 s = 4.5 min, inside a typical 5-minute "UPS data absent" alert window, so transient resets self-heal before the alert fires). If those fast retries do not restore comms — a UPS that is unplugged, dead, or whose driver cannot start — it backs off to `COMMS_RECOVERY_TIMEOUT × COMMS_BACKOFF_FACTOR` for subsequent attempts and escalates its log to `error` on the final fast retry (so the error lands within the alert window, where an operator wants confirmation of a sustained outage) — so a genuinely-absent UPS stops churning host USB permissions and flooding logs while staying visible (and still self-healing if the UPS returns). If you retune the alert window, keep `COMMS_FAST_RETRIES × COMMS_RECOVERY_TIMEOUT` at or under it so recovery never arrives late. During a real host poweroff (`SHUTDOWN_ON_BATTERY_CRITICAL=true`) the watchdog stands down when NUT sets its `killpower` flag, rather than bouncing the driver mid-poweroff.

Set `COMMS_WATCHDOG=false` to disable it (e.g. for a UPS that never re-enumerates, or when debugging). It is a no-op while comms are healthy.

## Security

**No dependency CVEs.** NUT, libmodbus, and net-snmp are compiled
from patched upstream sources via native cross-compilation,
eliminating all CVEs present in Alpine's older packages.

| Tool                                             | Result                               |
| ------------------------------------------------ | ------------------------------------ |
| [shellcheck](https://www.shellcheck.net/)        | Clean                                |
| [hadolint](https://github.com/hadolint/hadolint) | DL3018 (unpinned apk, accepted)      |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected                  |
| [trivy](https://trivy.dev/)                      | 0 dependency CVEs (Alpine base only) |
| [grype](https://github.com/anchore/grype)        | 0 dependency CVEs (Alpine base only) |
| [semgrep](https://semgrep.dev/)                  | 1 info (missing USER, expected)      |

All source versions are tracked by Renovate. The
multi-stage build uses [xx](https://github.com/tonistiigi/xx)
for native cross-compilation (no QEMU). The entrypoint validates
all env vars before generating NUT config: newline injection
prevention, numeric validation, bracket injection checks,
double-quote injection prevention for config file quoting, and
whitespace rejection for values written unquoted (e.g. `UPS_PORT`,
`API_ADDRESS`), so a space cannot split into extra config tokens.
Runs as root (required for NUT config ownership and USB device
access). Host shutdown via D-Bus is gated behind an explicit
opt-in env var.

**Details for advanced users:** NUT is built with
`--disable-shared --enable-static` so all binaries are
self-contained. Config files are 640 root:nut. Admin password
auto-generated from `/dev/urandom` if not set, then cached in a
root-only directory (`/var/run/nut-secrets`, mode 700) so the
lower-privileged `nut` user cannot pre-plant a symlink at the write
path. All NUT drivers are included (USB HID, Modbus, SNMP).

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency    | Source                                           |
| ------------- | ------------------------------------------------ |
| tonistiigi/xx | [Docker Hub](https://hub.docker.com/_/xx)        |
| alpine        | [Alpine](https://hub.docker.com/_/alpine)        |
| libmodbus     | [GitHub](https://github.com/stephane/libmodbus)  |
| netsnmp       | [GitHub](https://github.com/net-snmp/net-snmp)   |
| nut           | [GitHub](https://github.com/networkupstools/nut) |

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut) into a container image. All credit for the core functionality goes to the upstream maintainers.

- [libmodbus](https://github.com/stephane/libmodbus) by
  [@stephane](https://github.com/stephane) — the Modbus protocol
  library used by NUT's `apc_modbus` driver
- [Net-SNMP](https://github.com/net-snmp/net-snmp) — the SNMP
  library used by NUT's `snmp-ups` driver
- [xx](https://github.com/tonistiigi/xx) — Dockerfile
  cross-compilation helper for native multi-platform builds

## Contributing

Issues and pull requests are welcome. Please open an issue first for
larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
