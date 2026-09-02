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
- Recovers from lost UPS communications without a restart: a built-in comms watchdog restarts the driver after sustained stale data on any transport - USB re-enumeration is the common case (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery))
- Custom config override: mount `/etc/nut/{ups.conf,upsd.conf,upsd.users,upsmon.conf}.user` to bypass env-var generation. You then own every directive in that file, including the ones the rest of the image reads:
  - `ups.conf.user`: keep the section name (`[...]`) equal to `UPS_NAME` and its `driver` directive equal to `UPS_DRIVER`. The healthcheck, generated `upsmon.conf` MONITOR line, and comms watchdog use the section name. NUT names the PID file from the driver directive and section, while the startup gate waits for `/var/run/nut/$UPS_DRIVER-$UPS_NAME.pid`. Either mismatch is fatal at boot: the container logs `UPS driver did not confirm a live PID for the expected binary in time` and exits about five seconds in, so your restart policy brings it straight back to the same state
  - `ups.conf.user`: keep the driver's worst-case start inside 90s, the outer bound the entrypoint puts on `upsdrvctl start`; NUT's own `maxstartdelay` defaults to 75s per driver and `maxretry` to 1 attempt ([ups.conf](https://networkupstools.org/docs/man/ups.conf.html)), so raising either — `maxretry 2` alone allows up to 75 + 5 + 75 = 155s — can push a configuration NUT considers healthy past that bound, and the container logs `upsdrvctl start failed or timed out at boot` and exits, leaving your restart policy to loop it
  - `upsd.conf.user`: keep `LISTEN` on `API_ADDRESS` and `API_PORT`, where those same probes look; a divergent `LISTEN` fails every one of them against a correctly-serving upsd, the container exits after about a minute of failed probes, and your restart policy brings it back into the same state
  - `upsmon.conf.user`: keep a `SHUTDOWNCMD` line, or a forced shutdown takes no action on the host even with `SHUTDOWN_ON_BATTERY_CRITICAL=true`; `upsmon` prints `Warning: no shutdown command defined!` once at startup
  - `upsmon.conf.user`: keep `POWERDOWNFLAG /var/run/nut-secrets/killpower` at that exact path, or the comms watchdog cannot stand down during a real host poweroff and bounces the driver mid-shutdown, and the boot-time stale-flag clear stops matching
  - `upsmon.conf.user`: keep the `NOTIFYCMD` line and the `EXEC` notify flags (see Alerting)
- Configurable low-battery thresholds
- Clean signal handling: SIGTERM gracefully stops all NUT services

## Quick start

Available from both `ghcr.io/cplieger/docker-nut-upsd` and `docker.io/cplieger/docker-nut-upsd`; identical images and tags.

```yaml
services:
  nut-upsd:
    image: ghcr.io/cplieger/docker-nut-upsd:latest
    container_name: nut-upsd
    restart: unless-stopped

    environment:
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
| `UPS_NAME` | NUT UPS identifier used in config files and queries | `ups` |
| `UPS_DESC` | Human-readable UPS description shown in NUT clients; ASCII 0x20-0x7E only; no `"`, `\` or `#` because NUT reserves them for config escaping | `My UPS` |
| `UPS_DRIVER` | NUT driver for your UPS model (see [NUT HCL](https://networkupstools.org/stable-hcl.html)) | `usbhid-ups` |
| `UPS_PORT` | UPS port: `auto` (USB), `/dev/*` (serial), or `host[:port]` for network drivers (`snmp-ups`, `apcupsd-ups`); network drivers refuse `auto` and `/dev/*`; no whitespace, `"`, `\` or `#` | `auto` |
| `API_USER` | Username for NUT network clients: letters, numbers, `_`, or `-`; 510-byte maximum; declared `upsmon secondary` (see [NUT accounts and roles](#nut-accounts-and-roles)) | `monuser` |
| `API_PASSWORD` | Password for the NUT API user (entrypoint warns on weak credentials); no `"`, `\` or `#` because NUT config parsing would alter the credential | `secret` |
| `API_ADDRESS` | Listen address for upsd; write IPv6 bare (`::1`), not bracketed; brackets are added internally where NUT needs them; no whitespace, `"`, `\` or `#` | `0.0.0.0` |
| `API_PORT` | Listen port for upsd | `3493` |
| `API_TLS` | Offer STARTTLS on the upsd listener; self-signed certificate unless you mount `/etc/nut/upsd.pem` (see [TLS](#tls-starttls)) | `true` |
| `LOWBATT_PERCENT` | Low-battery percentage (enables `ignorelb`); `0` disables this axis, and `100` asserts low battery below full charge | Hardware default |
| `LOWBATT_RUNTIME` | Low-battery runtime in seconds (enables `ignorelb`); `0` disables this axis | Hardware default |
| `POLLFREQ` | Seconds between UPS status polls; `1` or more | `5` |
| `POLLFREQALERT` | Seconds between polls when on battery; `1` or more | `5` |
| `DEADTIME` | Seconds before declaring UPS stale; at least the larger of `POLLFREQ` and `POLLFREQALERT` | `15` |
| `FINALDELAY` | Seconds between shutdown warning and actual shutdown (`0` = no delay) | `5` |
| `HOSTSYNC` | Seconds to wait for secondary hosts to disconnect (`0` = do not wait) | `15` |
| `NOCOMMWARNTIME` | Seconds before warning about lost UPS communication (`0` = warn on every poll) | `300` |
| `RBWARNTIME` | Seconds between "replace battery" warnings (`0` = warn on every poll) | `43200` |
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off host via D-Bus on battery critical. In NUT the critical state IS low battery, so `LOWBATT_PERCENT`/`LOWBATT_RUNTIME` (or the UPS hardware flag when neither is set) decide when the shutdown fires | `false` |
| `DBUS_PROBE_INTERVAL` | Seconds between D-Bus poweroff-path liveness probes when host shutdown is enabled (`0` disables) | `300` |
| `ADMIN_PASSWORD` | Password for the NUT admin user (set/FSD actions); auto-generated if unset; no `"`, `\` or `#` because NUT config parsing would alter the credential | Random (cached) |
| `COMMS_WATCHDOG` | Enable the comms-recovery watchdog: restarts the UPS driver after sustained stale comms, on any transport (see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery)) | `true` |
| `COMMS_CHECK_INTERVAL` | Seconds between watchdog comms probes (`0` disables) | `15` |
| `COMMS_RECOVERY_TIMEOUT` | Seconds of continuous stale comms before the watchdog re-homes the driver | `90` |
| `COMMS_FAST_RETRIES` | Fast (stage-1) restart attempts before backing off; see recovery notes below | `3` |
| `COMMS_BACKOFF_FACTOR` | Stage-2 cadence multiplier on COMMS_RECOVERY_TIMEOUT once fast retries spent | `5` |

`DEADTIME` below the larger poll interval is refused: NUT declares the UPS dead as soon as one poll is late, and with `SHUTDOWN_ON_BATTERY_CRITICAL=true` that powers the host off during a short mains dip. Upstream advises a multiple of the poll interval; this image refuses anything below it.

Setting either `LOWBATT_PERCENT` or `LOWBATT_RUNTIME` enables `ignorelb`. The UPS must report `battery.charge`, or it must report both `battery.runtime` and its own `battery.runtime.low`. The generated `override.battery.charge.low` supplies the percentage threshold. If the UPS reports neither usable reading, the driver logs `upsdrvctl start failed or timed out at boot` and exits, so the restart policy repeats the failure.

When battery power becomes critical, `upsmon` runs the shutdown command and exits. With host shutdown disabled, it logs the forced shutdown and leaves the host running; the example restart policy repeats this cycle until mains power returns.

### NUT accounts and roles

The generated `upsd.users` defines three accounts, matching canonical NUT topology (the box that owns the UPS runs the single `upsmon primary`; networked clients are secondaries):

- **`admin`**: upsd `set`/`FSD` actions and instant commands, guarded by `ADMIN_PASSWORD`.
- **`local_upsmon`**: reserved internal account for the bundled `upsmon`, which holds the one `upsmon primary` slot (the authority to request a forced shutdown for all clients). Its password is auto-generated and cached exactly like `ADMIN_PASSWORD`; it never needs to leave the container. `API_USER` may not take this name (or `admin`).
- **`API_USER`**: the network-facing client account, declared `upsmon secondary`: remote machines authenticate with it to follow UPS status and shut themselves down, but cannot request a forced shutdown for everyone else.

If you mount exactly one of `upsd.users.user` / `upsmon.conf.user`, the generated half falls back to the shared `API_USER`/`API_PASSWORD` credential pair (logged at `level=warn`); the internal account only spans the two files when both are generated. Your mounted half must grant that pair `upsmon primary`, or `upsd` refuses the bundled `upsmon`'s forced-shutdown request.

### Volumes

| Mount | Description |
| --- | --- |
| `/dev/bus/usb` | USB bus, bound live (not `devices:`); USB drivers only, see hotplug notes |
| `/run/dbus/system_bus_socket` | Host D-Bus socket (required only if `SHUTDOWN_ON_BATTERY_CRITICAL=true`) |
| `/etc/nut/{ups.conf,upsd.conf,upsd.users,upsmon.conf}.user` | Custom NUT config overrides; bypasses env-var generation |
| `/etc/nut/upsd.pem` | Your own TLS certificate + private key (one PEM); replaces the self-signed one. Never modified, so mount it read-only |

> For a USB UPS, pair the live `/dev/bus/usb` bind with `device_cgroup_rules: ["c 189:* rmw"]` (USB major 189). A static `devices:` mapping is **not** sufficient; see [USB hotplug & comms recovery](#usb-hotplug--comms-recovery).

## Healthcheck

The built-in healthcheck runs `upsc` against upsd on its configured listen address (loopback for the default `API_ADDRESS=0.0.0.0`) to verify the NUT driver is communicating with the UPS hardware. It becomes unhealthy when the UPS device is disconnected, the driver failed to start, or upsd is not responding, and recovers once the device is reconnected and the driver re-establishes communication. The [comms watchdog](#usb-hotplug--comms-recovery) actively drives that recovery whenever comms go stale, so the unhealthy window is bounded by `COMMS_RECOVERY_TIMEOUT` rather than lasting until you recreate the container.

## TLS (STARTTLS)

upsd offers TLS on its listener by default (`API_TLS=true`) via the NUT protocol's `STARTTLS` command, with `DISABLE_WEAK_SSL` set so only TLS 1.2+ is accepted. STARTTLS is **opportunistic**: a client that sends `STARTTLS` gets an encrypted session; a client that never asks keeps talking cleartext exactly as before, so enabling it breaks no existing client.

The certificate, in order of precedence:

1. **Your own certificate**: mount a single PEM containing the certificate followed by its private key at `/etc/nut/upsd.pem`. The mount itself is never modified (no chown, no chmod, no rewrite), so a `600 root:root` read-only (`:ro`) mount works as-is. At every boot the entrypoint copies it to an internal working copy at `/etc/nut/upsd-mounted.pem` that upsd can read after dropping privileges; a certificate rotated on the host is picked up at the next restart.
2. **Self-signed fallback**: with nothing mounted, the entrypoint generates an EC P-256 certificate (`CN=nut-upsd`, 825-day validity) at first boot and logs its path and SHA-256 fingerprint. It survives restarts but not a container recreation (a fresh one is minted and logged).

Client-side verification is the client's choice; see the [NUT user manual](https://networkupstools.org/documentation.html) for `upsmon`'s `FORCESSL` / `CERTVERIFY` directives. A verifying client must trust the serving certificate. The provisioned PEM contains the private key and must not leave the container. Export only the certificate with the container's OpenSSL:

```sh
docker exec nut-upsd openssl x509 -in /etc/nut/upsd-selfsigned.pem -outform PEM > upsd-selfsigned.crt
docker exec -i nut-upsd openssl x509 -noout -fingerprint -sha256 < upsd-selfsigned.crt
```

Compare the second command's SHA-256 fingerprint with the fingerprint in the container log. Alternatively, mount your own CA-issued pair at `/etc/nut/upsd.pem`. Clients that skip verification (the default for `upsc` and `upsmon`) get encryption against passive sniffing but no protection from an active man-in-the-middle.

Set `API_TLS=false` to serve cleartext only: no certificate is provisioned, `STARTTLS` is answered with an error. If you mount `upsd.conf.user`, your file owns the TLS directives entirely (and the `LISTEN` coupling listed under "What it does"). The certificate is still provisioned whenever `API_TLS=true`, but upsd serves it only if your override names it in `CERTFILE`; if `CERTFILE` is absent, upsd serves cleartext without a startup warning. Reference the working copy that boot provisions: `/etc/nut/upsd-mounted.pem` when you mount `/etc/nut/upsd.pem`, otherwise `/etc/nut/upsd-selfsigned.pem`. Exactly one is provisioned per boot (mounted-PEM precedence) and the unselected copy is removed, so an override naming the other path fails at upsd startup instead of serving stale key material.

## USB hotplug & comms recovery

Many USB UPSes drop and re-establish their USB link periodically on their own firmware resets; the CyberPower Elite PFC line is a well-known example ([networkupstools/nut#1786](https://github.com/networkupstools/nut/issues/1786)). Each reset **re-enumerates** the UPS to a new `/dev/bus/usb` node, owned `root:root` by the kernel.

A `devices: - /dev/bus/usb:/dev/bus/usb` mapping is frozen at container start, so it never shows the new node, and the container's cgroup allowlist covers only the minors present at start. Both are fixed in the compose example above: bind the bus **live** with `volumes: - /dev/bus/usb:/dev/bus/usb`, and add `device_cgroup_rules: - "c 189:* rmw"` for any USB-major (189) minor.

With both in place, the **comms watchdog** (on by default) closes the loop: it probes `upsd` every `COMMS_CHECK_INTERVAL` seconds and, after `COMMS_RECOVERY_TIMEOUT` seconds of continuous stale data, re-asserts the `nut` group on the bus and restarts the driver, which re-opens the re-enumerated device cleanly. The watchdog itself keys on stale comms, not on USB, so it also recovers an `snmp-ups` or serial driver whose device stopped answering. Re-asserting the `nut` group on `/dev/bus/usb` is its one USB-specific step and runs only for a driver that needs the bus.

Recovery has two stages. It retries at a fast cadence for the first `COMMS_FAST_RETRIES` attempts, logging at `error` from the last of those fast attempts onward, and then retries every `COMMS_RECOVERY_TIMEOUT × COMMS_BACKOFF_FACTOR` seconds, which limits churn while the UPS is absent and still detects its return. Keep an absent-UPS alert above `COMMS_FAST_RETRIES × (COMMS_RECOVERY_TIMEOUT + COMMS_CHECK_INTERVAL)` plus driver stop/start time so recovery can finish first. During host poweroff, the watchdog stands down while NUT's `killpower` flag exists. The default recovery timeout also stays above the approximately 60-second upsd supervision limit.

Set `COMMS_WATCHDOG=false` to disable it. It is a no-op while comms are healthy.

## Alerting

nut-upsd has no metrics endpoint; its operational state is in its logs. Its `upsmon` notification handler logs a structured `event="<TYPE>"` line to the container log for each event the generated `upsmon.conf` wires to it (`ONLINE`, `ONBATT`, `LOWBATT`, `FSD`, `SHUTDOWN`, `COMMOK`, `COMMBAD`, `NOCOMM`, `REPLBATT`, `NOPARENT`, `OFF`, `BYPASS`, `OVER`, `ALARM`, `OTHER`). Ship the container's logs to Loki (Grafana Alloy's Docker log discovery does this with no configuration) and evaluate the rules in [`alerts/logql.yaml`](alerts/logql.yaml) with [Loki's ruler](https://grafana.com/docs/loki/latest/alert/); firing alerts deliver through your Alertmanager exactly like Prometheus metric alerts. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `UPSOnBattery` | an `ONBATT` event with no `ONLINE` after it in the window: mains power was lost and the UPS took the load onto its battery | warning |
| `UPSLowBattery` | a `LOWBATT` event: the UPS raised its low-battery flag (on battery plus low battery starts the shutdown sequence) | critical |
| `UPSForcedShutdown` | an `FSD`/`SHUTDOWN` event: the shutdown sequence has started | critical |
| `UPSHostSyncExpired` | `upsmon` logged `Host sync timer expired, forcing shutdown`: a secondary was still logged in when HOSTSYNC ran out, so the primary shut down without it | warning |
| `UPSCommsLost` | a `NOCOMM` event: upsmon could not reach the UPS for `NOCOMMWARNTIME` seconds (default 300) | warning |
| `UPSHardwareFault` | a `REPLBATT`/`ALARM` event: the UPS reports a worn or missing battery, a fan failure, overheat, or a charger fault | warning |
| `UPSProtectionDegraded` | a `BYPASS`/`OVER` event: the UPS no longer protects the load or the load exceeds its rating | warning |
| `UPSProtectionUnavailable` | a `NOPARENT`/`OFF` event: forced shutdown cannot power off the host, or the UPS is off or asleep | warning |
| `UPSPowerOffPathBroken` | the D-Bus poweroff-path probe logs `unreachable`: host shutdown is enabled but a forced shutdown could not power off the host right now | warning |
| `UPSPowerOffFailed` | every D-Bus `PowerOff` call failed during a forced shutdown, so host poweroff was not confirmed | critical |
| `UPSContainerError` | the container logs a `level=error` line of its own: a refused environment variable, a daemon start failure, the comms watchdog from its last fast retry onward, or a forced-shutdown path line | warning |

These events are emitted out of the box: the generated `upsmon.conf` sets a `NOTIFYCMD` that writes each event to the log, with `EXEC` on the relevant `NOTIFYFLAG`s. If you supply your own config by mounting `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` notify flags or these log lines (and the alerts that key on them) will not appear. Note that `NOTIFYCMD` is executed directly, with no shell, receiving the message as `$1` (the CVE-2026-54161 backport, matching NUT v2.8.6 semantics), so its value must be the path to an executable; wrap any shell snippet or command-with-arguments in a small script and point `NOTIFYCMD` at it.

Thresholds, `for:` windows, and the `severity` labels are starting points; adjust the `container` selector to your deployment and route by whatever labels your Alertmanager uses.

## Security

NUT, libmodbus, and net-snmp are built from pinned upstream sources. Four [checked-in backports](patches/) cover `NOTIFYCMD` command injection, a USB descriptor out-of-bounds read, and two USB reconnect deadlocks. Each patch header names its upstream commit, and all four patches are removed with NUT v2.8.6. The image embeds a CycloneDX fragment for these source-built components so scanners include them in the signed release SBOM.

Accepted scanner findings: Grype reports the unused BusyBox `wget` applet's unfixed CVE-2025-60876; hadolint reports unpinned `apk`; semgrep reports the required root user and two `IFS` save/restore false positives in `validate.sh`. Current results are in the repository's Security tab.

The entrypoint rejects control characters and NUT config delimiters before it writes environment values. Credential fields reject the bytes listed in the configuration table. Password fields also refuse bytes outside ASCII 0x20-0x7E and NUT words over 512 bytes.

The container starts as root for config ownership and USB access, then the NUT daemons drop to the `nut` user. It works with `no-new-privileges`. Host shutdown is disabled by default and requires an explicit D-Bus opt-in.

NUT clients make shutdown decisions from the status that `upsd` serves. Protect port 3493 with strong API and admin passwords and restrict who can reach it. The listener offers STARTTLS with TLS 1.2 or later by default; see [TLS](#tls-starttls) for certificate verification limits.

The live `/dev/bus/usb` bind lets the container retag all host USB nodes to its `nut` GID. If a host group uses that numeric GID, its members get read/write access to those devices. Use a user-namespace remap, or reserve the GID for a dedicated group. A remap also removes the sender's euid-0 poweroff shortcut. With `SHUTDOWN_ON_BATTERY_CRITICAL=true`, logind's default policy then asks for admin authentication that the non-interactive call cannot provide.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Source |
| --- | --- |
| alpine | [Alpine](https://hub.docker.com/_/alpine) |
| libmodbus | [GitHub](https://github.com/stephane/libmodbus) |
| netsnmp | [GitHub](https://github.com/net-snmp/net-snmp) |
| nut | [GitHub](https://github.com/networkupstools/nut) |

## Credits

This project packages [Network UPS Tools (NUT)](https://github.com/networkupstools/nut) (GPL-2.0-or-later) into a container image. All credit for the core functionality goes to the upstream maintainers.

- [libmodbus](https://github.com/stephane/libmodbus) (LGPL-2.1) by
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

Apache-2.0. See [LICENSE](LICENSE).

`patches/` is an exception. It holds backports of upstream NUT source, so
those files stay GPL-2.0-or-later. Each patch header names its upstream commit.
