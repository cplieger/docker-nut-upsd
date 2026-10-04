# Security

This page covers how docker-nut-upsd protects its port and credentials, how TLS works, what runs with which privileges, and what the image contains. Read it before you expose the server beyond one trusted network.

## Exposure and credentials

NUT clients decide when to shut down from the status that `upsd` serves. Anyone who can reach port 3493 can read the UPS status without a password, and the `admin` account can force a shutdown of every client. Protect port 3493 with strong `API_PASSWORD` and `ADMIN_PASSWORD` values, and restrict who can reach the port. A Synology NAS logs in only as `monuser` with `secret`, so where one follows this server, restricting the port is the protection that remains.

The generated `admin` password and the internal monitor password are kept in `/var/run/nut-secrets`, a directory only root can read. They are written to a temporary file and renamed into place.

## Input checks

The entrypoint rejects control characters and NUT config delimiters before it writes any setting into a config file. Credential fields also reject the bytes listed in [Configuration](configuration.md#names-passwords-and-descriptions). Password fields refuse values longer than 501 bytes and values that NUT would store as an empty word.

## Privileges

The container starts as root to set config file ownership and give the `nut` group access to USB devices. With the generated configuration, the UPS driver and `upsd` then drop to the `nut` user. `upsmon` keeps a privileged parent process so it can run the shutdown command, and its monitoring child runs as `nut`. The container works with `no-new-privileges`. Host shutdown is off by default and needs both `SHUTDOWN_ON_BATTERY_CRITICAL=true` and the host D-Bus socket mount.

The live `/dev/bus/usb` bind lets the container give every host USB device node to its `nut` group ID. If a host group uses that same numeric group ID, its members get read and write access to those devices. Use a user-namespace remap in Docker, or keep that group ID for a dedicated group on the host.

A user-namespace remap also changes host shutdown. Without the remap, the power-off request comes from root, which `systemd-logind` accepts without asking. With it, logind's default policy asks for admin authentication, which the container cannot provide, so `SHUTDOWN_ON_BATTERY_CRITICAL=true` fails.

## TLS (STARTTLS)

By default (`API_TLS=true`) the server offers TLS through the NUT protocol's `STARTTLS` command, with `DISABLE_WEAK_SSL` set so only TLS 1.2 or later is accepted. A client that sends `STARTTLS` gets an encrypted session. A client that never asks keeps talking without encryption, so turning TLS on breaks no existing client.

The server uses the first of these certificates that applies.

1. Your own certificate. Mount one PEM file holding the certificate followed by its private key at `/etc/nut/upsd.pem`. The container never changes the mount, so a `600 root:root` read-only mount works. At every start it copies the file to `/etc/nut/upsd-mounted.pem`, which `upsd` can read after it drops privileges. A certificate you replace on the host is used from the next restart.
2. A self-signed certificate. With nothing mounted, the container creates an EC P-256 certificate named `CN=nut-upsd`, valid for 825 days, at the first start and logs its path and SHA-256 fingerprint. It survives restarts but not a recreate of the container, which creates and logs a new one.

Whether a client checks the certificate is the client's choice. The [NUT user manual](https://networkupstools.org/documentation.html) describes `upsmon`'s `FORCESSL` and `CERTVERIFY` directives. A client that checks must trust the certificate the server presents. The PEM file inside the container holds the private key and must not leave it, so export only the certificate with the container's OpenSSL:

```sh
docker exec nut-upsd openssl x509 -in /etc/nut/upsd-selfsigned.pem -outform PEM > upsd-selfsigned.crt
docker exec -i nut-upsd openssl x509 -noout -fingerprint -sha256 < upsd-selfsigned.crt
```

Compare the SHA-256 fingerprint the second command prints with the one in the container log. You can also mount your own certificate and key from a certificate authority at `/etc/nut/upsd.pem`. A client that skips the check, which is the default for `upsc` and `upsmon`, gets encryption against someone listening on the network, but no protection from someone who impersonates the server.

Set `API_TLS=false` to serve without encryption. No certificate is created, and the server answers `STARTTLS` with an error.

A mounted `upsd.conf.user` owns the TLS directives, and its `LISTEN` line must match as [Configuration](configuration.md#your-own-nut-config-files) says. With `API_TLS=true` the container still creates the certificate, but `upsd` serves it only when your file names it in `CERTFILE`. Without `CERTFILE`, `upsd` serves without encryption and logs no warning at start. Name the copy the container creates at that boot. That is `/etc/nut/upsd-mounted.pem` when you mount `/etc/nut/upsd.pem`, and `/etc/nut/upsd-selfsigned.pem` otherwise. Only one exists per boot, and the other is removed, so a file that names the wrong path fails when `upsd` starts instead of serving an old key.

## What the image contains

NUT, libmodbus and Net-SNMP are built from pinned upstream sources on an Alpine Linux base. The Alpine base image and those three source releases are pinned, and [Renovate](https://github.com/renovatebot/renovate) updates the pins. The Alpine packages the image installs are not pinned, and each image build takes their current versions.

| Dependency | Source |
| --- | --- |
| alpine | [Alpine](https://hub.docker.com/_/alpine) |
| libmodbus | [GitHub](https://github.com/stephane/libmodbus) |
| netsnmp | [GitHub](https://github.com/net-snmp/net-snmp) |
| nut | [GitHub](https://github.com/networkupstools/nut) |

Four [checked-in backports](../patches/) fix a `NOTIFYCMD` command injection, a USB descriptor out-of-bounds read, and two USB reconnect deadlocks. Each patch header names its upstream commit, and all four go away with NUT v2.8.6. The image embeds a CycloneDX fragment for these source-built components, so scanners include them in the signed release SBOM.

## Accepted scanner findings

- Grype reports CVE-2025-60876 in BusyBox's `wget` applet, which has no fix and which the image does not use.
- hadolint reports unpinned `apk` packages.
- semgrep reports the root user the image needs, and two false positives on saving and restoring `IFS` in `validate.sh`.

Current results are in the repository's Security tab.
