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
- TLS (NUT STARTTLS) on by default: a self-signed certificate is generated at first boot, or mount your own at `/etc/nut/upsd.pem`; legacy cleartext clients keep working (see [TLS](#tls-starttls))
- Optional host shutdown via D-Bus when the UPS reaches critical battery (`SHUTDOWN_ON_BATTERY_CRITICAL=true`)
- Survives UPS-initiated USB re-enumeration: a built-in comms watchdog re-homes the driver onto the re-enumerated device automatically (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery))
- Custom config override: mount your own NUT config files as `*.user` (e.g. `ups.conf.user`) into `/etc/nut/` to bypass env-var generation. If you mount `ups.conf.user`, keep its section name (`[...]`) equal to `UPS_NAME`: the healthcheck, the generated `upsmon.conf` MONITOR line, and the comms watchdog all address the UPS by `UPS_NAME`, so a mismatched section name reports permanently unhealthy and makes the watchdog restart a nonexistent UPS
- Configurable low-battery and critical-battery thresholds
- Clean signal handling: SIGTERM gracefully stops all NUT services

### Why this design

- **Environment-variable config**: no hand-edited `nut.conf` files; the entrypoint generates them declaratively from env vars
- **Single container replaces three daemons**: bundles the NUT driver, `upsd`, and `upsmon` so you deploy one service instead of three
- **Minimal Alpine base**: only the packages NUT needs, nothing that widens the attack surface
- **Compiled from upstream sources**: NUT, libmodbus, and net-snmp built from latest upstream, not distro packages; see [Security](#security) for the resulting CVE posture

## Quick start

Available from both `ghcr.io/cplieger/docker-nut-upsd` and `docker.io/cplieger/docker-nut-upsd`; identical images and tags.

```yaml
services:
  nut-upsd:
    image: ghcr.io/cplieger/docker-nut-upsd:latest
    container_name: nut-upsd
    restart: unless-stopped

    environment:
      TZ: "Europe/Paris"
      UPS_NAME: "ups"
      UPS_DESC: "My UPS"
      UPS_DRIVER: "usbhid-ups"  # see NUT hardware compatibility list
      UPS_PORT: "auto"  # auto = USB auto-detection
      API_USER: "monuser"
      API_PASSWORD: "secret"  # change this

    ports:
      - "3493:3493"

    # USB hotplug: bind the bus LIVE (not via devices:) plus the USB-major cgroup
    # rule, so a UPS that re-enumerates to a new node stays reachable without a
    # recreate. See "USB hotplug & comms recovery" below.
    device_cgroup_rules:
      - "c 189:* rmw"
    volumes:
      - "/dev/bus/usb:/dev/bus/usb"
```

## Configuration reference

### Environment variables

| Variable | Description | Default |
| --- | --- | --- |
| `TZ` | Container timezone | Unset (UTC) |
| `UPS_NAME` | NUT UPS identifier used in config files and queries | `ups` |
| `UPS_DESC` | Human-readable UPS description shown in NUT clients | `My UPS` |
| `UPS_DRIVER` | NUT driver for your UPS model (see [NUT HCL](https://networkupstools.org/stable-hcl.html)) | `usbhid-ups` |
| `UPS_PORT` | UPS port: `auto` (USB), `/dev/*` (serial), `host[:port]` for network drivers (`snmp-ups`) | `auto` |
| `API_USER` | Username for NUT network clients, declared `upsmon secondary` (see [NUT accounts and roles](#nut-accounts-and-roles)) | `monuser` |
| `API_PASSWORD` | Password for the NUT API user (entrypoint warns on weak credentials) | `secret` |
| `API_ADDRESS` | Listen address for upsd; write IPv6 bare (`::1`), not bracketed; brackets are added internally where NUT needs them | `0.0.0.0` |
| `API_PORT` | Listen port for upsd | `3493` |
| `API_TLS` | Offer STARTTLS on the upsd listener; self-signed certificate unless you mount `/etc/nut/upsd.pem` (see [TLS](#tls-starttls)) | `true` |
| `LOWBATT_PERCENT` | Low-battery threshold percentage (enables `ignorelb`) | Hardware default |
| `LOWBATT_RUNTIME` | Low-battery threshold runtime in seconds (enables `ignorelb`) | Hardware default |
| `CRITBATT_PERCENT` | Critical-battery threshold percentage (enables `ignorelb`) | Hardware default |
| `CRITBATT_RUNTIME` | Critical-battery threshold runtime in seconds (enables `ignorelb`) | Hardware default |
| `POLLFREQ` | Seconds between UPS status polls | `5` |
| `POLLFREQALERT` | Seconds between polls when on battery | `5` |
| `DEADTIME` | Seconds before declaring UPS stale | `15` |
| `FINALDELAY` | Seconds between shutdown warning and actual shutdown | `5` |
| `HOSTSYNC` | Seconds to wait for secondary hosts to disconnect | `15` |
| `NOCOMMWARNTIME` | Seconds before warning about lost UPS communication | `300` |
| `RBWARNTIME` | Seconds between "replace battery" warnings | `43200` |
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off host via D-Bus on battery critical | `false` |
| `DBUS_PROBE_INTERVAL` | Seconds between D-Bus poweroff-path liveness probes when host shutdown is enabled (`0` disables) | `300` |
| `ADMIN_PASSWORD` | Password for the NUT admin user (set/FSD actions); auto-generated if unset | Random (cached) |
| `COMMS_WATCHDOG` | Enable the USB comms-recovery watchdog (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery)) | `true` |
| `COMMS_CHECK_INTERVAL` | Seconds between watchdog comms probes | `15` |
| `COMMS_RECOVERY_TIMEOUT` | Seconds of continuous stale comms before the watchdog re-homes the driver | `90` |
| `COMMS_FAST_RETRIES` | Fast (stage-1) restart attempts before backing off; see recovery notes below | `3` |
| `COMMS_BACKOFF_FACTOR` | Stage-2 cadence multiplier on COMMS_RECOVERY_TIMEOUT once fast retries spent | `5` |

### NUT accounts and roles

The generated `upsd.users` defines three accounts, matching canonical NUT topology (the box that owns the UPS runs the single `upsmon primary`; networked clients are secondaries):

- **`admin`**: upsd `set`/`FSD` actions and instant commands, guarded by `ADMIN_PASSWORD`.
- **`local_upsmon`**: reserved internal account for the bundled `upsmon`, which holds the one `upsmon primary` slot (the authority to request a forced shutdown for all clients). Its password is auto-generated and cached exactly like `ADMIN_PASSWORD`; it never needs to leave the container. `API_USER` may not take this name (or `admin`).
- **`API_USER`**: the network-facing client account, declared `upsmon secondary`: remote machines authenticate with it to follow UPS status and shut themselves down, but cannot request a forced shutdown for everyone else.

If you mount exactly one of `upsd.users.user` / `upsmon.conf.user`, the generated half falls back to the shared `API_USER`/`API_PASSWORD` credential pair (logged at `level=warn`) so it still interoperates with your mounted file; the internal account only spans the two files when both are generated.

### Volumes

| Mount | Description |
| --- | --- |
| `/dev/bus/usb` | USB bus, bound live (not `devices:`); USB drivers only, see hotplug notes |
| `/run/dbus/system_bus_socket` | Host D-Bus socket (required only if `SHUTDOWN_ON_BATTERY_CRITICAL=true`) |
| `/etc/nut/*.user` | Custom NUT config overrides (e.g. `ups.conf.user`); bypasses env-var generation |
| `/etc/nut/upsd.pem` | Your own TLS certificate + private key (one PEM); replaces the self-signed one. Never modified, so mount it read-only |

> For a USB UPS, pair the live `/dev/bus/usb` bind with `device_cgroup_rules: ["c 189:* rmw"]` (USB major 189). A static `devices:` mapping is **not** sufficient; see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery).

## Healthcheck

The built-in healthcheck runs `upsc` against upsd on its configured listen address (loopback for the default `API_ADDRESS=0.0.0.0`) to verify the NUT driver is communicating with the UPS hardware. It becomes unhealthy when the UPS device is disconnected, the driver failed to start, or upsd is not responding, and recovers once the device is reconnected and the driver re-establishes communication. The [comms watchdog](#usb-hotplug--comms-recovery) actively drives that recovery after a USB re-enumeration, so the unhealthy window is bounded by `COMMS_RECOVERY_TIMEOUT` rather than lasting until you recreate the container.

## TLS (STARTTLS)

upsd offers TLS on its listener by default (`API_TLS=true`) via the NUT protocol's `STARTTLS` command, with `DISABLE_WEAK_SSL` set so only TLS 1.2+ is accepted. STARTTLS is **opportunistic**: a client that sends `STARTTLS` gets an encrypted session; a client that never asks keeps talking cleartext exactly as before, so enabling it breaks no existing client.

The certificate, in order of precedence:

1. **Your own certificate**: mount a single PEM containing the certificate followed by its private key at `/etc/nut/upsd.pem`. The mount itself is never modified (no chown, no chmod, no rewrite), so a `600 root:root` read-only (`:ro`) mount works as-is. At every boot the entrypoint copies it to an internal working copy at `/etc/nut/upsd-mounted.pem` that upsd can read after dropping privileges; a certificate rotated on the host is picked up at the next restart.
2. **Self-signed fallback**: with nothing mounted, the entrypoint generates an EC P-256 certificate (`CN=nut-upsd`, 825-day validity) at first boot and logs its path and SHA-256 fingerprint. It survives restarts but not a container recreation (a fresh one is minted and logged).

Client-side verification is the client's choice; see the [NUT user manual](https://networkupstools.org/documentation.html) for `upsmon`'s `FORCESSL` / `CERTVERIFY` directives. A verifying client must trust the serving certificate: import the self-signed one (grab it from the startup log or `docker cp`), or mount your own CA-issued pair at `/etc/nut/upsd.pem`. Clients that skip verification (the default for `upsc` and `upsmon`) still get opportunistic encryption against passive sniffing, but no protection from an active man-in-the-middle.

Set `API_TLS=false` to serve cleartext only: no certificate is provisioned, `STARTTLS` is answered with an error, and the generated `upsd.conf` is byte-identical to pre-TLS releases. If you mount `upsd.conf.user`, your file owns the TLS directives entirely; the certificate is still provisioned whenever `API_TLS=true`, so your override should reference the working copy the boot actually provisions: `/etc/nut/upsd-mounted.pem` when you mount `/etc/nut/upsd.pem`, otherwise `/etc/nut/upsd-selfsigned.pem`. Exactly one is provisioned per boot (mounted-PEM precedence) and the unselected copy is removed, so an override naming the other path fails at upsd startup instead of serving stale key material.

## USB hotplug & comms recovery

Many USB UPSes drop and re-establish their USB link periodically on their own firmware resets; the CyberPower Elite PFC line is a well-known example ([networkupstools/nut#1786](https://github.com/networkupstools/nut/issues/1786)). Each reset **re-enumerates** the UPS to a new `/dev/bus/usb` node, owned `root:root` by the kernel.

This breaks the naive passthrough in two ways:

1. **Visibility.** Docker's `devices: - /dev/bus/usb:/dev/bus/usb` maps only the device nodes present at container start; a node created later by a re-enumeration never appears inside the container. Fix: bind the bus **live** with `volumes: - /dev/bus/usb:/dev/bus/usb`.
2. **Access.** The container's cgroup device allowlist only permits the device minors present at start, and the new node is created `root:root` while the driver runs as the unprivileged `nut` user. Fix: `device_cgroup_rules: - "c 189:* rmw"` permits any USB-major (189) minor.

With both in place, the **comms watchdog** (on by default) closes the loop: it probes `upsd` every `COMMS_CHECK_INTERVAL` seconds and, after `COMMS_RECOVERY_TIMEOUT` seconds of continuous stale data, re-asserts the `nut` group on the bus and restarts the driver, which re-opens the re-enumerated device cleanly.

Recovery is **two-stage** so a transient reset heals fast without thrashing a genuinely-absent UPS. For the first `COMMS_FAST_RETRIES` attempts it retries every `COMMS_RECOVERY_TIMEOUT` seconds (default 3 × 90 s = 4.5 min). If those fast retries do not restore comms, it escalates its log to `error` on the final fast retry and backs off to `COMMS_RECOVERY_TIMEOUT × COMMS_BACKOFF_FACTOR` for subsequent attempts, so a UPS that is unplugged or dead stops churning host USB permissions and flooding logs while staying visible (and still self-healing if it returns). If you alert on absent UPS data, keep `COMMS_FAST_RETRIES × COMMS_RECOVERY_TIMEOUT` at or under your alert window so recovery never arrives late. During a real host poweroff (`SHUTDOWN_ON_BATTERY_CRITICAL=true`) the watchdog stands down when NUT sets its `killpower` flag, rather than bouncing the driver mid-poweroff.

Set `COMMS_WATCHDOG=false` to disable it. It is a no-op while comms are healthy.

## Alerting

nut-upsd has no metrics endpoint; its operational state is in its logs. Its `upsmon` notification handler logs a structured `event=<TYPE>` line to the container log for every UPS event (`LOWBATT`, `FSD`/`SHUTDOWN`, `NOCOMM`, and so on). Ship the container's logs to Loki (Grafana Alloy's Docker log discovery does this with no configuration) and evaluate the rules in [`alerts.yaml`](alerts.yaml) with [Loki's ruler](https://grafana.com/docs/loki/latest/alert/); firing alerts deliver through your Alertmanager exactly like Prometheus metric alerts. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `UPSLowBattery` | a `LOWBATT` event: the UPS is on battery and has reached its low-battery threshold, so shutdown is imminent | critical |
| `UPSForcedShutdown` | an `FSD`/`SHUTDOWN` event: the battery is exhausted and the shutdown sequence has started | critical |
| `UPSCommsLost` | a `NOCOMM` event: upsmon could not reach the UPS for `NOCOMMWARNTIME` seconds (default 300) | warning |
| `UPSPowerOffPathBroken` | the D-Bus poweroff-path probe logs `unreachable`: host shutdown is enabled but a forced shutdown could not power off the host right now | warning |

These events are emitted out of the box: the generated `upsmon.conf` sets a `NOTIFYCMD` that writes each event to the log, with `EXEC` on the relevant `NOTIFYFLAG`s. If you supply your own config by mounting `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` notify flags or these log lines (and the alerts that key on them) will not appear. Note that `NOTIFYCMD` is executed directly, with no shell, receiving the message as `$1` (the CVE-2026-54161 backport, matching NUT v2.8.6 semantics), so its value must be the path to an executable; wrap any shell snippet or command-with-arguments in a small script and point `NOTIFYCMD` at it. With `SHUTDOWN_ON_BATTERY_CRITICAL=true`, a background probe additionally re-checks the D-Bus poweroff path every `DBUS_PROBE_INTERVAL` seconds (default 300) and logs `level=error` while it is unreachable, so a broken mount alerts before an outage instead of failing during the forced shutdown itself.

Thresholds, `for:` windows, and the `severity` labels are starting points; adjust the `container` selector to your deployment and route by whatever labels your Alertmanager uses.

## Security

**Dependency CVE posture.** NUT, libmodbus, and net-snmp are compiled
from patched upstream sources, every source version- and hash-pinned,
in native per-arch builds (no QEMU, no cross-compilation), avoiding
the CVEs carried by Alpine's older packages. The image is scanned with
Trivy and Grype on relevant pull requests and on every release; the
authoritative, current results live in the repository's Security tab.
Accepted findings, one line each: Grype's unfixed BusyBox-wget
advisory CVE-2025-60876 (the wget applet ships in the image's BusyBox
binary but is never invoked at runtime; only the builder stage uses
wget), hadolint `DL3018` (unpinned apk), and
[semgrep](https://semgrep.dev/)'s missing-`USER` (root by design) plus
two `IFS` save/restore false positives in `validate.sh`.

Because SBOM tooling reads Alpine images from the APK database, the
source-built components would be invisible to scanners, so the image
embeds a CycloneDX SBOM fragment at
`/usr/share/sbom/nut-upsd.cdx.json` covering NUT, libmodbus, and
net-snmp, and its component inventory is imported into the signed
release SBOM. An OpenVEX document ([`vex/`](vex/)) is attested
alongside the image so registry scanners see the backported
CVE-2026-54161 fix as resolved.

The entrypoint validates every env var before it reaches a NUT config
file: it rejects control characters, quote/backslash/bracket
injection, whitespace in values written unquoted (e.g. `UPS_PORT`,
`API_ADDRESS`), and non-identifier characters in values used as NUT
section names (`UPS_NAME`, `API_USER`), so a crafted value cannot
inject extra config directives.

The container runs as root, required for NUT config ownership and USB
device access; the daemons drop to the unprivileged `nut` user
internally. It is safe to run with `security_opt:
["no-new-privileges:true"]`: NUT only drops privileges, never gains
them. Host shutdown via D-Bus is gated behind an explicit opt-in env
var, and the generated credentials (`ADMIN_PASSWORD`, the internal
`local_upsmon` password, the self-signed TLS private key) are cached
in a root-only directory.

One boundary is inherent to NUT itself: shutdown coordination is the
protocol's function, so `upsmon` and every networked NUT client decide
to shut down based on the status `upsd` serves. Requesting a forced
shutdown (FSD) for everyone else, however, is separated by account
role: only the internal `admin` and `local_upsmon` accounts carry that
authority, while the network-facing `API_USER` is an `upsmon
secondary` that follows status but cannot command an FSD (see
[NUT accounts and roles](#nut-accounts-and-roles)). The meaningful
hardening surface is the listener itself: strong
`API_PASSWORD`/`ADMIN_PASSWORD` credentials and limiting who can reach
port 3493. That listener offers STARTTLS by default, TLS 1.2+ only;
see [TLS](#tls-starttls) for the certificate model and what
verification does and does not protect against.

One host-side effect to know about: because `/dev/bus/usb` is a live
bind of the host bus, the container's startup and watchdog
`chgrp -R nut /dev/bus/usb` retag every host USB device node to the
container's `nut` GID (an Alpine system GID). If that numeric GID is
assigned to a group on the host, members of that host group gain
read/write access (default `0664` node mode) to all USB devices. If
that matters for your host, run the container under a user namespace
remap, or reserve the matching host GID for a dedicated group.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Source |
| --- | --- |
| alpine | [Alpine](https://hub.docker.com/_/alpine) |
| libmodbus | [GitHub](https://github.com/stephane/libmodbus) |
| netsnmp | [GitHub](https://github.com/net-snmp/net-snmp) |
| nut | [GitHub](https://github.com/networkupstools/nut) |

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut) into a container image. All credit for the core functionality goes to the upstream maintainers.

- [libmodbus](https://github.com/stephane/libmodbus) by
  [@stephane](https://github.com/stephane), the Modbus protocol
  library used by NUT's `apc_modbus` driver
- [Net-SNMP](https://github.com/net-snmp/net-snmp), the SNMP
  library used by NUT's `snmp-ups` driver

## Contributing

Issues and pull requests are welcome. Please open an issue first for
larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

GPL-3.0. See [LICENSE](LICENSE).
