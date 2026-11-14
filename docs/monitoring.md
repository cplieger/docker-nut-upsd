# Monitoring and alerts

docker-nut-upsd serves a Prometheus metrics page for the UPS and its shutdown path, logs each UPS event, and ships alert rules for Prometheus and for Loki. Read this page to choose which rules to load, to scrape the metrics, or to set up a probe that tells you when the container stops.

## What you get

| You run | You get | You set up |
| --- | --- | --- |
| Prometheus, Mimir or VictoriaMetrics, with Alertmanager | the UPS state alerts and `NutUpsdDown` from the metrics, and the [dashboard](#dashboard) of charge, runtime and load | publish port 9199, scrape it as job `nut-upsd`, load [`alerts/promql.yaml`](../alerts/promql.yaml) |
| Prometheus and Loki, with Alertmanager | the alerts above, plus the event alerts no metric can carry: a forced shutdown, a failed poweroff, an error line | the row above, plus the `nut-upsd-events` group of [`alerts/logql.yaml`](../alerts/logql.yaml) |
| Loki and Alertmanager, no metric store | every alert except `NutUpsdDown`, from the log | both groups of `alerts/logql.yaml` |
| Grafana-managed alerting only | the same rules, imported into Grafana | a Prometheus or Loki data source, then the rules above |
| Docker or Unraid only | Docker health, and the shutdown of your NUT clients on low battery | an uptime prober on `/healthz`, or something that watches Docker health |

With no monitoring stack, consider Home Assistant's [NUT integration](https://www.home-assistant.io/integrations/nut/) if you want notifications from the UPS state, or your own `NOTIFYCMD` script in a mounted `upsmon.conf.user` if you want each event sent somewhere. Your own `NOTIFYCMD` replaces the script that writes the `event=` lines, so the log rules stop matching. The metric rules do not depend on it.

## Metrics

The image runs a small exporter that serves `GET /metrics` on `METRICS_PORT`, `9199` by default, and `METRICS_PORT=0` starts no exporter. It listens on `METRICS_ADDRESS`, which defaults to the value of `API_ADDRESS`. The compose example does not publish the port, so add `- "9199:9199"` under `ports:` for a scraper on another machine. The page has no login and shows the same UPS state port 3493 gives anyone, so publish it only to your monitoring network.

The exporter asks `upsd` for the UPS's variables at each scrape, with a 3-second bound. It also reads the state the image's own processes record, which covers the comms watchdog's driver restarts, the `upsmon` parent and the D-Bus poweroff check.

| Series | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `nut_upsd_upsd_up` | gauge | none | `1` when `upsd` answered the NUT protocol at this scrape |
| `nut_upsd_ups_data_fresh` | gauge | none | `1` when `upsd` served fresh data for the UPS, `0` when the data is stale, the driver is not connected or `upsd` did not answer |
| `nut_upsd_ups_status` | gauge | `flag` | `1` when `ups.status` carries the flag, `0` when it does not. Served only while the data is fresh |
| `nut_upsd_battery_charge_ratio`, `nut_upsd_battery_charge_low_ratio` | gauge | none | battery charge and the low-battery charge, from 0 to 1 |
| `nut_upsd_battery_runtime_seconds`, `nut_upsd_battery_runtime_low_seconds` | gauge | none | runtime left at the current load, and the low-battery runtime |
| `nut_upsd_battery_voltage_volts`, `nut_upsd_battery_temperature_celsius` | gauge | none | battery voltage and temperature |
| `nut_upsd_input_voltage_volts`, `nut_upsd_input_frequency_hertz` | gauge | none | mains voltage and frequency |
| `nut_upsd_output_voltage_volts`, `nut_upsd_output_frequency_hertz` | gauge | none | output voltage and frequency |
| `nut_upsd_ups_load_ratio` | gauge | none | load as a share of the UPS rating, from 0 to 1 |
| `nut_upsd_ups_realpower_watts`, `nut_upsd_ups_realpower_nominal_watts` | gauge | none | real power the load draws, and the rated real power |
| `nut_upsd_ups_power_voltamperes`, `nut_upsd_ups_power_nominal_voltamperes` | gauge | none | apparent power the load draws, and the rated apparent power |
| `nut_upsd_ups_temperature_celsius` | gauge | none | UPS temperature |
| `nut_upsd_driver_restarts_total` | counter | none | driver restarts the comms watchdog made since the container started |
| `nut_upsd_upsmon_parent_alive` | gauge | none | `1` while the privileged `upsmon` parent, which runs the shutdown command, is running. Served once the container has started `upsmon` |
| `nut_upsd_host_poweroff_enabled` | gauge | none | `1` when `SHUTDOWN_ON_BATTERY_CRITICAL=true` |
| `nut_upsd_poweroff_path_ok` | gauge | none | `1` when the last D-Bus check found the host poweroff path usable. Served once a check has run |
| `nut_upsd_poweroff_path_probe_timestamp_seconds` | gauge | none | Unix time of the last D-Bus check |
| `nut_upsd_build_info` | gauge | `version`, `nut_version` | always `1`. `version` is the image release and `nut_version` the NUT release it runs, for a query to join on |

The `flag` label carries one `ups.status` word: `OL`, `OB`, `LB`, `HB`, `RB`, `CHRG`, `DISCHRG`, `BYPASS`, `CAL`, `OFF`, `OVER`, `TRIM`, `BOOST`, `FSD`, `ALARM` or `ECO`. Any other word sets `OTHER`. The UPS variables are served only while the data is fresh and only for the variables your UPS reports, and the percentages NUT reports are served as ratios.

The page also carries the exporter's Go runtime and process families (`go_*`, `process_*`) under the names Go's official Prometheus client uses, so stock Go dashboards work. The bundled [dashboard](#dashboard) shows the UPS series in Grafana.

## Logs

docker-nut-upsd logs every event to its container log. Every line the image writes itself is logfmt with a `level=` field.

`upsmon` runs a notify script for each event the generated `upsmon.conf` routes to it, and the script logs one `event="<TYPE>"` line per event. The routed events are `ONLINE`, `ONBATT`, `LOWBATT`, `FSD`, `SHUTDOWN`, `COMMOK`, `COMMBAD`, `NOCOMM`, `REPLBATT`, `NOPARENT`, `OFF`, `BYPASS`, `OVER`, `CAL`, `ALARM` and `OTHER`, and the clears `NOTOFF`, `NOTBYPASS`, `NOTOVER`, `NOTCAL` and `NOTALARM`.

`upsmon` also writes its own lines without a `level=` field, such as `Host sync timer expired, forcing shutdown`. Continuous UPS state, such as "still on battery", is on the metrics page and on the NUT protocol on port 3493, and `alerts/promql.yaml` alerts on it while it holds.

While host shutdown is on and the poweroff path is broken, the D-Bus check logs one `D-Bus poweroff path unreachable` error per check. Each line carries `broken_for`, the seconds since the first failed check of that outage, and the `D-Bus poweroff path recovered` line carries the total.

## Alerting

[`alerts/promql.yaml`](../alerts/promql.yaml) holds the UPS state alerts for a Prometheus ruler, read from the exporter, plus `NutUpsdDown`. [`alerts/logql.yaml`](../alerts/logql.yaml) holds two groups for Loki's ruler. Load its `nut-upsd-events` group always, beside either choice. Load its `nut-upsd-state` group only if you do not load `alerts/promql.yaml`, or each UPS state alert fires twice. The two state sources use the same alert names. `NutUpsdDown` has no log rule, because a stopped container writes no line. [Loading metric alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-metric-alert-rules) and [Loading an app's alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-an-apps-alert-rules) show how to load each file.

The first six alerts below are in the `nut-upsd-events` group. The next seven are in both the `nut-upsd-state` group and `alerts/promql.yaml`, and `NutUpsdDown` is in `alerts/promql.yaml` only. The "Fires when" text describes the log rule where both exist.

| Alert | Fires when | Severity |
| --- | --- | --- |
| `NutUpsdForcedShutdown` | an `FSD` or `SHUTDOWN` event, so the shutdown has started | critical |
| `NutUpsdHostSyncExpired` | `upsmon` logged `Host sync timer expired, forcing shutdown`. A client was still logged in when `HOSTSYNC` ran out, so the server shut down without it | warning |
| `NutUpsdNotifyExecFailed` | `upsmon` could not run `NOTIFYCMD`, so the `event=` lines stopped | warning |
| `NutUpsdCommsRepaired` | the container logged `comms watchdog UPS comms recovered` after a watchdog driver restart. The line carries the outage length and restart count | warning |
| `NutUpsdPowerOffFailed` | every D-Bus `PowerOff` call failed, or an accepted call was later refuted, during a forced shutdown | critical |
| `NutUpsdContainerError` | the image logs its own `level=error` line, such as a refused setting, a failed daemon start, a failed watchdog restart or a shutdown error | warning |
| `NutUpsdOnBattery` | the latest `ONBATT` has no `ONLINE` after it, so mains power was lost and the UPS carries the load on its battery | warning |
| `NutUpsdLowBattery` | a `LOWBATT` event, so the UPS raised its low-battery flag. On battery with low battery starts the shutdown | critical |
| `NutUpsdCommsLost` | a `NOCOMM` event, so `upsmon` could not reach the UPS for `NOCOMMWARNTIME` seconds (default 300). The metric rule fires after 5 minutes of stale data | warning |
| `NutUpsdHardwareFault` | the latest `ALARM` has no `NOTALARM` after it, or `REPLBATT` keeps repeating, so the UPS reports a hardware fault or a worn battery | warning |
| `NutUpsdProtectionDegraded` | a `CAL`, `BYPASS` or `OVER` event with no clear after it, so the UPS is calibrating, no longer protects the load, or is overloaded | warning |
| `NutUpsdProtectionUnavailable` | `NOPARENT` repeats, or `OFF` has no `NOTOFF` after it, so a forced shutdown cannot power off the host, or the UPS is off | warning |
| `NutUpsdPowerOffPathBroken` | the D-Bus check logs `unreachable`. Host shutdown is on, but a forced shutdown could not power off the host right now | warning |
| `NutUpsdDown` | the scrape of the exporter failed or found no target for 5 minutes | warning |

The rules for `NutUpsdPowerOffPathBroken` and `NutUpsdPowerOffFailed` need `SHUTDOWN_ON_BATTERY_CRITICAL=true`, and `DBUS_PROBE_INTERVAL=0` turns off only the first one. `NutUpsdOnBattery`'s log rule holds for at most its range. The range is 6 hours, so follow a longer outage with the metric rule, which holds while the UPS reports `OB`. Each metric rule fires while the exporter serves its flag or value, and holds until the UPS reports it cleared. While the data is stale the exporter serves no flag, so the flag rules resolve and `NutUpsdCommsLost` takes over.

To move from the state group to the metric rules, load `alerts/promql.yaml` first. Remove the `nut-upsd-state` group only once `NutUpsdDown` has stayed silent past its 5 minutes and any alert that holds has fired from the new file. A gap during a power event pages nobody, while the overlap can page one fault twice.

The generated `upsmon.conf` sets a `NOTIFYCMD` that logs each event, with `EXEC` on the matching `NOTIFYFLAG` lines. If you mount your own `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` flags, or the `event=` lines and the log rules that key on them stop. NUT runs `NOTIFYCMD` directly, without a shell, and passes the message as `$1`. This comes from the CVE-2026-54161 backport and matches NUT v2.8.6. So the value must be the path to an executable. Wrap a shell snippet or a command with arguments in a small script and point `NOTIFYCMD` at it.

Thresholds, `for:` windows and the `severity` labels are starting points. Change the `container` selector to the label your log collector sets, and keep the scrape job name `nut-upsd` that `NutUpsdDown` reads.

[How each alert rule works](alert-rules.md) explains each rule's window and shape, what it reads, and what to check when it fires.

## Dashboard

[`grafana-dashboard.json`](../grafana-dashboard.json) imports as the NUT UPS dashboard. It reads the metrics above from a Prometheus data source and needs Grafana 13.2 or newer. When you run more than one container, the UPS variable picks the exporter to show. It has three tabs:

- Overview shows the UPS status in words, the battery charge, the runtime left beside the low battery mark, and the load. Below them, a Needs attention row appears only while an alert from `alerts/promql.yaml` fires, with one tile per rule. Each tile reads its rule's `ALERTS` series, which Prometheus and the Mimir ruler store beside your metrics, so the row stays hidden while those rules are not loaded.
- Power over time charts the charge and the runtime against their low battery marks, the load, the mains and output voltage, and when the UPS ran on battery.
- Exporter health shows whether the scrape, `upsd` and the UPS data are healthy, the driver restarts the comms watchdog made, and the state of host poweroff, the D-Bus check and the `upsmon` parent.

The status box shows the forced-shutdown flag (`FSD`) while the UPS reports it. The forced-shutdown event, a failed poweroff, an error line and the other events of the `nut-upsd-events` group of `alerts/logql.yaml` leave no series, so they stay in the log and in that group.

The dashboard is versioned with the image, and the `grafana-dashboard.json` of release `<tag>` matches the metrics that image serves. Each release attaches it with its checksum at `https://github.com/cplieger/docker-nut-upsd/releases/download/<tag>/grafana-dashboard.json`, and each image publish pushes it as the OCI artifact `ghcr.io/cplieger/docker-nut-upsd/dashboard:<tag>`. The file sets `metadata.name` to `docker-nut-upsd`, which Grafana uses as the dashboard UID, so importing a newer copy over the old one updates it in place.

## Knowing the app is alive

| Route | Method | Port | Login | Answers |
| --- | --- | --- | --- | --- |
| `/healthz` | `GET`, `HEAD` | `METRICS_PORT`, `9199` by default | none | `200 {"status":"ok"}`, or `503 {"status":"unhealthy","reasons":[...]}` |
| `/metrics` | `GET` | the same port | none. Keep the port on your network | Prometheus text format |

**What healthy means.** `upsd` answers within 3 seconds with a fresh `ups.status` for the UPS. Stale data, a driver that is not connected or an `upsd` that does not answer makes the container unhealthy. A UPS on battery is still healthy, because the check reports the link to the UPS, not the power state. `/healthz` and the Docker healthcheck ask `upsd` the same question, so they give the same answer.

**Docker health.** The image checks itself every 30 seconds with `upsc <UPS_NAME>@<address>:<API_PORT> ups.status`, which asks `upsd` inside the container for the UPS status, on `API_ADDRESS` or on loopback for the default `0.0.0.0`. Docker marks the container unhealthy after 3 failures, and allows 135 seconds after a start. Docker's health status notifies nobody on its own, and Docker does not restart an unhealthy container. The comms watchdog restarts the driver after `COMMS_RECOVERY_TIMEOUT` seconds of stale data, and the container exits when `upsd` stops answering for about a minute, as [How docker-nut-upsd works](how-it-works.md) explains.

**Who is told.**

| You run | A stopped container | A UPS that stops answering |
| --- | --- | --- |
| Prometheus with `alerts/promql.yaml` | `NutUpsdDown` | `NutUpsdCommsLost`, and `/healthz` turns 503 |
| Loki only | no rule sees a stopped container, and `NutUpsdContainerError` fires on each refused or failed start. Add an uptime prober on `/healthz` | `NutUpsdCommsLost` |
| Docker or Unraid only | an uptime prober on `/healthz`, or on TCP port 3493 with `METRICS_PORT=0`, or something that watches Docker health | the same |

Every NUT client also logs its own `COMMBAD` and `NOCOMM` events when it loses this server. A `upsmon` that hangs while its parent stays alive is not detected.

**Probing from outside.** Check `GET http://<host>:9199/healthz` and pass on status 200 only. Do not match the body. Use a 5-second timeout, check every 60 seconds, alert after 3 failures, and wait 135 seconds after a first start. Publish the port to the prober's network first. With `METRICS_PORT=0`, probe TCP port 3493 instead, which proves only that `upsd` accepts connections. A Kubernetes liveness probe that must ignore the UPS link uses a `tcpSocket` probe on port 3493.
