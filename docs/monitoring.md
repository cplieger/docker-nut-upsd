# Monitoring and alerts

This page lists what docker-nut-upsd writes to its log and the alert rules that ship with it. Read it when you collect the container's logs with Loki and want alerts for power loss, low battery or a broken shutdown path.

## What it logs

docker-nut-upsd has no metrics endpoint, so its state is in its container log. Every line the image writes itself is logfmt with a `level=` field.

`upsmon` runs a notify script for each event the generated `upsmon.conf` routes to it, and the script logs one `event="<TYPE>"` line per event. The routed events are `ONLINE`, `ONBATT`, `LOWBATT`, `FSD`, `SHUTDOWN`, `COMMOK`, `COMMBAD`, `NOCOMM`, `REPLBATT`, `NOPARENT`, `OFF`, `BYPASS`, `OVER`, `CAL`, `ALARM` and `OTHER`.

`upsmon` also writes its own lines without a `level=` field, such as `Host sync timer expired, forcing shutdown`. Continuous UPS state, such as "still on battery", is on the NUT protocol on port 3493 and not in the log, so alert on a NUT metrics exporter for a latched alarm.

## Alerting

Ship the container's logs to Loki and load the rules in [`alerts/logql.yaml`](../alerts/logql.yaml) into [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). Grafana Alloy's Docker log discovery ships the logs with no extra configuration. Firing alerts go through your Alertmanager like any Prometheus alert. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `UPSOnBattery` | an `ONBATT` event with no `ONLINE` after it in the window, so mains power was lost and the UPS took the load onto its battery | warning |
| `UPSLowBattery` | a `LOWBATT` event, so the UPS raised its low-battery flag. On battery with low battery starts the shutdown | critical |
| `UPSForcedShutdown` | an `FSD` or `SHUTDOWN` event, so the shutdown has started | critical |
| `UPSHostSyncExpired` | `upsmon` logged `Host sync timer expired, forcing shutdown`. A client was still logged in when `HOSTSYNC` ran out, so the server shut down without it | warning |
| `UPSNotifyExecFailed` | `upsmon` could not run `NOTIFYCMD`, so the `event=` lines stopped | warning |
| `UPSCommsLost` | a `NOCOMM` event, so `upsmon` could not reach the UPS for `NOCOMMWARNTIME` seconds (default 300) | warning |
| `UPSCommsRepaired` | the container logged `comms watchdog UPS comms recovered` after a watchdog driver restart. The line carries the outage length and restart count | warning |
| `UPSHardwareFault` | a `REPLBATT` or `ALARM` event, so the UPS reports a worn or missing battery, a fan failure, overheating or a charger fault | warning |
| `UPSProtectionDegraded` | a `CAL`, `BYPASS` or `OVER` event, so the UPS is calibrating, no longer protects the load, or carries more than its rated load | warning |
| `UPSProtectionUnavailable` | a `NOPARENT` or `OFF` event, so a forced shutdown cannot power off the host, or the UPS is off or asleep | warning |
| `UPSPowerOffPathBroken` | the D-Bus check logs `unreachable`. Host shutdown is on, but a forced shutdown could not power off the host right now | warning |
| `UPSPowerOffFailed` | every D-Bus `PowerOff` call failed, or an accepted call was later refuted, during a forced shutdown | critical |
| `UPSContainerError` | the image logs its own `level=error` line, such as a refused setting, a failed daemon start, a failed watchdog restart or a shutdown error | warning |

The rules for `UPSPowerOffPathBroken` and `UPSPowerOffFailed` need `SHUTDOWN_ON_BATTERY_CRITICAL=true`, and `DBUS_PROBE_INTERVAL=0` turns off only the first one. The rule file's own comments explain each rule's window.

The generated `upsmon.conf` sets a `NOTIFYCMD` that logs each event, with `EXEC` on the matching `NOTIFYFLAG` lines. If you mount your own `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` flags, or the `event=` lines and the alerts that key on them disappear. NUT runs `NOTIFYCMD` directly, without a shell, and passes the message as `$1`. This comes from the CVE-2026-54161 backport and matches NUT v2.8.6. So the value must be the path to an executable. Wrap a shell snippet or a command with arguments in a small script and point `NOTIFYCMD` at it.

Thresholds, `for:` windows and the `severity` labels are starting points. Change the `container` selector to the label your log collector sets, and route by whatever labels your Alertmanager uses.
