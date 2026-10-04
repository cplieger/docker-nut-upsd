# How docker-nut-upsd works

This page explains what runs inside the container, how it recovers a UPS that stops answering, and when the container exits on purpose. Read it when you size the watchdog settings or want to know why the container restarted.

## What runs in the container

One container runs three NUT programs that normally deploy separately. They are the UPS driver, the `upsd` server that answers clients on port 3493, and the `upsmon` monitor that starts the shutdown. NUT, libmodbus and Net-SNMP are compiled from pinned upstream sources on Alpine Linux.

At each start the entrypoint checks every setting, writes NUT's config files from them, and starts the driver, then `upsd`, then `upsmon`. It waits up to 90 seconds for the driver and 30 seconds for `upsd`. A daemon that fails to start inside its bound stops the boot, and the container exits with a non-zero code.

On `SIGTERM` the container stops the watchdog, the D-Bus check and every NUT daemon before it exits.

## When the container exits on purpose

- A daemon fails to start at boot. The log names it, such as `upsdrvctl start failed or timed out at boot`.
- `upsd` stops answering for about a minute, four failed checks 15 seconds apart. The log shows `upsd unresponsive; stopping services and exiting so the restart policy rebuilds the stack`.
- The monitor runs the shutdown command after a forced shutdown and exits. With host shutdown off, the restart policy starts the container again until mains power returns.

In each case the restart policy decides what happens next. A restart starts from the same state as a first boot.

## Healthcheck

The built-in healthcheck runs `upsc` against `upsd` every 30 seconds, on the configured listen address, or on the loopback address for the default `API_ADDRESS=0.0.0.0`. It checks that the driver is talking to the UPS. It turns unhealthy when the UPS is disconnected, the driver failed to start, or `upsd` stops responding, and healthy again once the driver reaches the UPS. Health is a live check every time, never a stored result.

The comms watchdog below drives that recovery, so the unhealthy window lasts about `COMMS_RECOVERY_TIMEOUT` seconds rather than until you recreate the container.

## A UPS that drops off USB

Some USB UPSes reset their USB link on their own from time to time. The CyberPower Elite PFC line is a known example, reported in [networkupstools/nut#1786](https://github.com/networkupstools/nut/issues/1786). Each reset gives the UPS a new device node under `/dev/bus/usb`, owned by `root:root`.

A `devices: - /dev/bus/usb:/dev/bus/usb` mapping is fixed at container start, so the new node never appears inside the container. The container's device allowlist also covers only the nodes present at start. The compose example fixes both. It binds the bus live with `volumes: - /dev/bus/usb:/dev/bus/usb`, and `device_cgroup_rules: - "c 189:* rmw"` allows any device with the USB major number 189.

With both in place, the comms watchdog finishes the job. It is on by default. It checks `upsd` every `COMMS_CHECK_INTERVAL` seconds. After `COMMS_RECOVERY_TIMEOUT` seconds of continuous stale data, it gives the `nut` group access to the bus again and restarts the driver, which opens the new device node. The watchdog keys on stale data rather than on USB, so it also recovers an `snmp-ups` or serial driver whose device stopped answering. Giving the `nut` group access to `/dev/bus/usb` is its one USB step, and it runs only for a driver that needs the bus.

## Watchdog timing

Recovery has two stages. The watchdog first tries `COMMS_FAST_RETRIES` restarts at the normal pace. After that it waits `COMMS_RECOVERY_TIMEOUT × COMMS_BACKOFF_FACTOR` seconds between restarts, which limits the churn while the UPS is gone and still finds it when it returns.

A failed restart logs at `error` on any attempt. The watchdog's progress line also turns to `error` from the last fast attempt onward. The first failed restart logs about `COMMS_RECOVERY_TIMEOUT` seconds after the data went stale. The progress line turns to `error` after `COMMS_FAST_RETRIES × (COMMS_RECOVERY_TIMEOUT + COMMS_CHECK_INTERVAL)` seconds plus the time to stop and start the driver. At the defaults the three fast restarts happen about 105, 210 and 315 seconds after the last fresh check, plus the time each restart takes.

The default `COMMS_RECOVERY_TIMEOUT` of 90 seconds stays above the one-minute limit after which the container exits for an unresponsive `upsd`. During a host power-off the watchdog stands down while NUT's `killpower` flag exists.

Set `COMMS_WATCHDOG=false` to turn it off. It does nothing while the data is fresh.
