# Configuration

This page lists every setting of docker-nut-upsd and explains the ones whose effect is not obvious from the table. Read it when you change more than the quick start sets, use a serial or network UPS, or supply your own NUT config files.

## Where settings live

Every setting is an environment variable in `compose.yaml`. At each start the container checks the values and writes NUT's four config files from them: `ups.conf`, `upsd.conf`, `upsd.users` and `upsmon.conf`. Recreate the container with `docker compose up -d` after a change.

The container refuses to start when a value would break a NUT config file. It rejects control characters everywhere and NUT's config delimiters where the table says so, and the log line names the variable.

## Every setting

| Variable | Description | Default |
| --- | --- | --- |
| `UPS_NAME` | Name of the UPS that clients ask for, as in `ups@host` | `ups` |
| `UPS_DESC` | Description shown in NUT clients. No `"`, `\` or `#` | `My UPS` |
| `UPS_DRIVER` | NUT driver for your UPS model, from the [NUT hardware list](https://networkupstools.org/stable-hcl.html) | `usbhid-ups` |
| `UPS_PORT` | `auto` for USB, a device node such as `/dev/ttyUSB0` for serial, or `host[:port]` for a network UPS | `auto` |
| `API_USER` | User name your NUT clients log in with. Letters, numbers, `_` and `-` | `monuser` |
| `API_PASSWORD` | Password for `API_USER`. Use 12 characters or more. No `"`, `\` or `#` | `secret` |
| `ADMIN_PASSWORD` | Password for the `admin` account, which can run UPS commands. Generated and kept when unset | Random (cached when generated) |
| `API_TLS` | Offer TLS encryption to clients that ask for it | `true` |
| `LOWBATT_PERCENT` | Battery percentage at which the UPS counts as low. `0` turns this threshold off | Hardware default |
| `LOWBATT_RUNTIME` | Seconds of runtime left at which the UPS counts as low. `0` turns this threshold off | Hardware default |
| `SHUTDOWN_ON_BATTERY_CRITICAL` | Power off the machine running this container when the battery is critical | `false` |
| `COMMS_WATCHDOG` | Restart the UPS driver when the UPS stops answering, such as after it drops off USB | `true` |
| `API_ADDRESS` | Address the server listens on. Write IPv6 without brackets, such as `::1` | `0.0.0.0` |
| `API_PORT` | Port the server listens on | `3493` |
| `POLLFREQ` | Seconds between status checks on mains power. `1` or more | `5` |
| `POLLFREQALERT` | Seconds between status checks on battery. `1` or more | `5` |
| `DEADTIME` | Seconds without fresh data before the UPS counts as lost | `15` |
| `FINALDELAY` | Seconds between the shutdown warning and the shutdown. `0` means no delay | `5` |
| `HOSTSYNC` | Seconds to wait for clients to log off before shutting down. `0` means no wait | `15` |
| `NOCOMMWARNTIME` | Seconds without contact before a "lost communication" warning, repeated at that interval. `0` warns on every check | `300` |
| `RBWARNTIME` | Seconds between "replace battery" warnings. `0` warns on every check | `43200` |
| `DBUS_PROBE_INTERVAL` | Seconds between checks that host shutdown would still work. `0` turns the check off | `300` |
| `COMMS_CHECK_INTERVAL` | Seconds between the watchdog's status checks. `0` turns the watchdog off | `15` |
| `COMMS_RECOVERY_TIMEOUT` | Seconds of stale data before the watchdog restarts the driver | `90` |
| `COMMS_FAST_RETRIES` | Driver restarts at the normal pace before the watchdog slows down | `3` |
| `COMMS_BACKOFF_FACTOR` | How many times longer the watchdog waits between restarts once it slows down | `5` |

## Names, passwords and descriptions

- `UPS_DESC` also refuses control bytes. NUT itself drops any byte outside ASCII 0x20 to 0x7F and prints one warning per dropped byte.
- `API_USER` is at most 510 bytes. It cannot be `admin` or `local_upsmon`, because the server reserves both names.
- `API_PASSWORD` and `ADMIN_PASSWORD` refuse `"`, `\` and `#`, because NUT's config parser would change the password. They are at most 501 bytes, and a value that NUT would store as an empty word is refused.
- The container logs a warning for a password shorter than 12 characters. The default `secret` gets that warning too.
- A password with spaces is accepted with a warning. Only a client that quotes the password, as the NUT network protocol allows, can then log in. The NUT clients in this image send it unquoted.
- When `ADMIN_PASSWORD` is unset, the container generates one and keeps it for later restarts. A mounted `upsd.users.user` owns the `admin` account instead.

## Accounts the server creates

The generated `upsd.users` holds three accounts. The machine that owns the UPS runs the one NUT monitor with the `primary` role, and machines on the network are `secondary`, which is NUT's usual layout.

- `admin` can change UPS variables, run UPS commands and force a shutdown. `ADMIN_PASSWORD` guards it.
- `local_upsmon` is the account the monitor inside this container uses. It holds the `primary` role, which can ask every client to shut down. Its password is generated and kept like `ADMIN_PASSWORD`, and it never leaves the container.
- `API_USER` is the account for your network clients, with the `secondary` role. A client can follow the UPS and shut itself down, but it cannot force a shutdown for the others.

If you mount only one of `upsd.users.user` and `upsmon.conf.user`, the generated half uses `API_USER` and `API_PASSWORD` instead of `local_upsmon`, and the container logs a warning. Your mounted half must then give that pair the `primary` role, or `upsd` refuses the forced-shutdown request from the monitor in this container.

## Driver and port

- For `usbhid-ups`, the container adds `pollonly`, so the driver polls the UPS instead of reading its USB interrupt pipe. `upsc` then reports `driver.flag.pollonly`. To read the interrupt pipe, mount your own `ups.conf.user` without `pollonly`.
- `UPS_PORT` takes no whitespace, `"`, `\` or `#`.
- The network drivers `snmp-ups` and `apcupsd-ups` need `UPS_PORT` set to `host` or `host:port`. They refuse `auto` and `/dev/*`, so a network driver left at the `auto` default stops the container at start.
- USB drivers ignore `UPS_PORT`, and NUT warns when you set an unusual value.
- `API_ADDRESS` takes no whitespace, `"`, `\` or `#`. Brackets are added where NUT needs them.

## Serial UPS

Set `UPS_PORT` to the device node, such as `/dev/ttyUSB0`, and pass that node to the container with `devices:`, as in `- /dev/ttyUSB0:/dev/ttyUSB0`.

Every driver in this image opens the device as the `nut` user. Give that user access with a mode change on the host, or mount an `ups.conf.user` that sets `user = root`. Compose `group_add:` does not help, because the driver resets its extra groups with `initgroups` before it opens the port. If the adapter disconnects and comes back under a new node, bind its device directory live and add a cgroup rule for its device major number instead, as the example does for USB.

## USB UPS

Keep both USB lines of the example. One binds `/dev/bus/usb` live under `volumes:`, and `device_cgroup_rules: ["c 189:* rmw"]` allows the USB major number 189. A `devices:` mapping of the bus is not enough, because it keeps only the device nodes present at start. [How docker-nut-upsd works](how-it-works.md#a-ups-that-drops-off-usb) explains why.

The bus is needed for every USB driver, and for a driver that talks serial or USB when `UPS_PORT` is `auto` or a `/dev/bus/usb` node. A network or serial setup runs without it.

## Low-battery thresholds

NUT starts the shutdown when the UPS is on battery and its low-battery flag is set. `LOWBATT_PERCENT` and `LOWBATT_RUNTIME` decide when that flag is set.

- A non-zero value in either one adds `ignorelb` to the generated `ups.conf`, so NUT computes low battery from your thresholds and ignores the flag the UPS hardware raises. This also fixes a UPS that raises the flag falsely.
- With `ignorelb` active, the UPS must report `battery.charge`, or both `battery.runtime` and its own `battery.runtime.low`. A UPS that reports neither makes the driver refuse to start. The log then shows `upsdrvctl start failed or timed out at boot`, the container exits, and the restart policy repeats the failure.
- `LOWBATT_PERCENT=100` sets low battery as soon as the charge drops below full.
- If one threshold is `0` and the other is non-zero, the container starts normally. Low battery then depends on the remaining threshold and on the UPS reporting that reading and its `.low` companion.
- A `0` on its own, or on both thresholds, generates no override. The UPS's own low-battery flag decides, as it does when both are unset.
- A mounted `ups.conf.user` makes both settings do nothing.

## Timing

`DEADTIME` must be at least the larger of `POLLFREQ` and `POLLFREQALERT`, and NUT advises three times that. The container refuses a smaller value. NUT would otherwise declare the UPS lost as soon as one check is late, and with `SHUTDOWN_ON_BATTERY_CRITICAL=true` that powers the host off during a short mains dip.

## Host shutdown

With `SHUTDOWN_ON_BATTERY_CRITICAL=true`, the container asks the host to power off through the host's system D-Bus socket. Mount it with `- /run/dbus/system_bus_socket:/run/dbus/system_bus_socket` under `volumes:`. The container refuses to start when the setting is on and the socket is missing. The request goes to `systemd-logind`, so the host must run it.

Low battery is the usual trigger. The generated `upsmon.conf` sets `OFFDURATION 30`, `OBLBDURATION 0` and `ALARMCRITICAL 1` at the values NUT v2.8.5 uses by default, so a later change of NUT's defaults does not change this image. NUT also treats a UPS as critical in some calibration, bypass, alarm and off states.

When the battery is critical, the monitor runs the shutdown command and exits. With host shutdown off, it logs the forced shutdown and leaves the host running. The container then exits, and the example restart policy starts it again, which repeats until mains power returns.

While host shutdown is on, the container checks every `DBUS_PROBE_INTERVAL` seconds that the host would accept a power-off request, and logs an error when it would not. The `UPSPowerOffPathBroken` alert keys on that line. Keep that alert's window above twice this interval, because the alert stays active only while the error line recurs.

## Your own NUT config files

Mount `/etc/nut/ups.conf.user`, `/etc/nut/upsd.conf.user`, `/etc/nut/upsd.users.user` or `/etc/nut/upsmon.conf.user` to replace the file the container would generate. You then own every directive in that file, including the ones the rest of the image reads.

- In `ups.conf.user`, keep the section name `[...]` equal to `UPS_NAME` and the `driver` directive equal to `UPS_DRIVER`. The healthcheck, the generated `upsmon.conf` and the comms watchdog use the section name, and the container waits for the driver's PID file `/var/run/nut/$UPS_DRIVER-$UPS_NAME.pid`. Either mismatch stops the boot. The log shows `UPS driver did not confirm a live PID for the expected binary in time`, the container exits about five seconds in, and the restart policy brings it back to the same state.
- The serial Modbus drivers are `apc_modbus`, `generic_modbus` and `adelsystem_cbi`. Give them a standard POSIX baud rate, such as 9600, their default. Every standard rate from 110 up to 115200 and beyond works. libmodbus is built here without custom-rate support, which does not compile on Alpine. A rate such as 14400 or 28800 is then accepted but opened at 9600, and the driver never reaches the device. The log shows a communication failure and does not name the baud rate.
- In `ups.conf.user`, keep the driver's worst-case start inside 90s, the outer bound the container puts on `upsdrvctl start`. NUT's own `maxstartdelay` defaults to 75 seconds per driver and `maxretry` to 1 attempt, as the [ups.conf manual](https://networkupstools.org/docs/man/ups.conf.html) says. Raising either can pass that bound, and `maxretry 2` alone allows up to 75 + 5 + 75 = 155 seconds. The log then shows `upsdrvctl start failed or timed out at boot`, the container exits, and the restart policy repeats it.
- In `upsd.conf.user`, keep `LISTEN` on `API_ADDRESS` and `API_PORT`, where the health checks look. A different `LISTEN` fails every check against a server that works, and the container exits after about a minute of failed checks.
- In `upsd.conf.user`, your file owns the TLS directives. [Security](hardening.md#tls-starttls) says which certificate path to name.
- In `upsmon.conf.user`, keep a `SHUTDOWNCMD` line. Without it a forced shutdown does nothing on the host, even with `SHUTDOWN_ON_BATTERY_CRITICAL=true`, and `upsmon` prints `Warning: no shutdown command defined!` once at start.
- In `upsmon.conf.user`, keep `POWERDOWNFLAG /var/run/nut-secrets/killpower` at that exact path. Otherwise the comms watchdog cannot stand down during a real host power-off. A driver restart then causes a short forced-shutdown blackout for network clients and skips the `HOSTSYNC` wait, because NUT v2.8.5 counts zero logged-in clients after the server-side failure. The stale-flag cleanup at boot also stops matching.
- In `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` notify flags, or the event log lines and the alerts that key on them stop. [Monitoring and alerts](monitoring.md#alerting) has the details.
- A mounted `ups.conf.user` makes `LOWBATT_PERCENT` and `LOWBATT_RUNTIME` do nothing.

Anything mounted under `/etc/nut` is used exactly as provided, with no ownership or mode change. It must already be readable by the `nut` user, and a whole-directory mount must also let that user enter it.

## Volumes

| Mount | Description |
| --- | --- |
| `/dev/bus/usb` | The USB bus, bound live under `volumes:`. Needed for a USB UPS, and for a serial-or-USB driver with `UPS_PORT` at `auto` |
| `/run/dbus/system_bus_socket` | Host D-Bus socket. Needed only with `SHUTDOWN_ON_BATTERY_CRITICAL=true` |
| `/etc/nut/{ups.conf,upsd.conf,upsd.users,upsmon.conf}.user` | Your own NUT config files, replacing the generated ones |
| `/etc/nut/upsd.pem` | Your own TLS certificate and private key in one PEM file. Never modified, so mount it read-only |
