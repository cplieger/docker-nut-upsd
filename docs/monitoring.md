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
| `nut_upsd_build_info` | gauge | `version`, `nut_version` | always `1`; `version` is the image release and `nut_version` the NUT release it runs, for a query to join on |

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
| `NutUpsdHardwareFault` | the latest `ALARM` has no `NOTALARM` after it, or `REPLBATT` keeps repeating, so the UPS reports a worn or missing battery, a fan failure, overheating or a charger fault | warning |
| `NutUpsdProtectionDegraded` | a `CAL`, `BYPASS` or `OVER` event with no clear after it, so the UPS is calibrating, no longer protects the load, or carries more than its rated load | warning |
| `NutUpsdProtectionUnavailable` | `NOPARENT` keeps repeating, or the latest `OFF` has no `NOTOFF` after it, so a forced shutdown cannot power off the host, or the UPS is off or asleep | warning |
| `NutUpsdPowerOffPathBroken` | the D-Bus check logs `unreachable`. Host shutdown is on, but a forced shutdown could not power off the host right now | warning |
| `NutUpsdDown` | the scrape of the exporter failed or found no target for 5 minutes | warning |

The rules for `NutUpsdPowerOffPathBroken` and `NutUpsdPowerOffFailed` need `SHUTDOWN_ON_BATTERY_CRITICAL=true`, and `DBUS_PROBE_INTERVAL=0` turns off only the first one. The notes below explain each log rule's window and shape. Each metric rule fires while the exporter serves its flag or value, and holds until the UPS reports it cleared. While the data is stale the exporter serves no flag, so the flag rules resolve and `NutUpsdCommsLost` takes over.

To move from the state group to the metric rules, load `alerts/promql.yaml` first. Remove the `nut-upsd-state` group only once `NutUpsdDown` has stayed silent past its 5 minutes and any alert that holds has fired from the new file. A gap during a power event pages nobody, while the overlap can page one fault twice.

The generated `upsmon.conf` sets a `NOTIFYCMD` that logs each event, with `EXEC` on the matching `NOTIFYFLAG` lines. If you mount your own `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` flags, or the `event=` lines and the log rules that key on them stop. NUT runs `NOTIFYCMD` directly, without a shell, and passes the message as `$1`. This comes from the CVE-2026-54161 backport and matches NUT v2.8.6. So the value must be the path to an executable. Wrap a shell snippet or a command with arguments in a small script and point `NOTIFYCMD` at it.

Thresholds, `for:` windows and the `severity` labels are starting points. Change the `container` selector to the label your log collector sets, and keep the scrape job name `nut-upsd` that `NutUpsdDown` reads.

### How the rules read the log

The event and message rules read parsed logfmt fields, so a word inside a quoted value cannot match them. `NutUpsdContainerError` reads the start of the line instead, so a `level=error` inside another record's detail cannot fire it. `NutUpsdHostSyncExpired` matches the end of a raw `upsmon` line for the same reason. Its pattern is open at the start, because a `DEBUG_MIN` setting in a mounted `upsmon.conf.user` makes `upsmon` prefix each line with an elapsed time.

If your log collector already sets a stream label named `event` or `msg`, Loki stores the parsed field as `event_extracted` or `msg_extracted`. The rule filters then read your stream label, so they may match nothing or the wrong records.

The image runs `upsmon` in the foreground, so its own lines reach the log too. They include a `LOG_NOTICE` copy of each event flagged `SYSLOG`, warnings such as `assuming dead` and `Too few UPS(es) are healthy`, and process errors. These lines carry no `level=` prefix and no logfmt fields. `NutUpsdHostSyncExpired` and `NutUpsdNotifyExecFailed` each match one of them. Read the rest in the log.

Three routed events have no rule on purpose:

- `COMMBAD` fires on any move into lost comms, including the unknown state `upsmon` starts each UPS in. Its count cannot separate an outage from a container start. The source is `ups_is_gone` in NUT v2.8.5 `clients/upsmon.c`.
- `COMMOK` is the upstream recovery notice. `NutUpsdCommsRepaired` alerts on a watchdog repair from the container's own record instead. That record carries the outage length and restart count, and it cannot fire on a cold start.
- `OTHER` carries status words that `upsmon` does not classify.

An `event=` line with no alert is one of these three, or a parsed field that lost to a stream label of the same name.

### Transition and state rules

A state rule stays firing while its condition holds, because its source repeats the line faster than the window. A pair rule reads the latest of a flag's raise and its clear, so it stays firing from the raise until the clear. A transition rule marks a change and resolves when its line leaves the window. No window can make a transition rule track a condition, because the window would have to outlast the condition itself. Each rule's own source decides its shape, and the notes below name it. `NutUpsdContainerError` has neither shape, because its sources range from a one-shot boot refusal to the watchdog's repeating escalation.

Both groups evaluate every 10 seconds instead of the ruler's 1-minute default. `NutUpsdOnBattery` pairs this with `for: 10s`, so the battery state must hold across one full interval before the alert fires. A brief dip, such as a load surge from a laser printer's fuser on the UPS, clears within one `upsmon` poll and stays silent. A real outage fires in about 10 to 20 seconds.

A 1-minute evaluation could delay that by up to a minute, and the runtime left depends on the load and can be short. The interval applies to every rule in a group. If the extra query load is not worth it for the slower rules, raise it.

### Notes on each rule

#### NutUpsdOnBattery

This is a pair rule. `upsmon` logs `ONBATT` once when it loses mains and `ONLINE` once when mains returns, and the rule keeps the latest of the two, so the alert holds from the first until the second. The source is `ups_on_batt` and `ups_on_line` in NUT v2.8.5 `clients/upsmon.c`. A recovery and a second outage close together fire again on the second `ONBATT`. The range is 6 hours, so an outage that outlasts it with no restart resolves at 6 hours. If your battery can outlast that, follow a longer outage with the metric rule in `alerts/promql.yaml`, which holds while the UPS reports `OB`. The `for: 10s` keeps a flicker silent: a dip that ends within one `upsmon` poll logs `ONLINE` before the alert fires.

A container start during an outage resets the alert and raises it again on `upsmon`'s first poll, as [How the pair rules hold](#how-the-pair-rules-hold) explains. `upsmon` starts each UPS with no `OB` flag and no line state, so its first poll that reads `OB` sends `ONBATT`, and a start on mains logs no `ONLINE`. The `starting upsmon` line is what clears an outage that ended while the container was down.

How long the battery holds depends on the load and on the battery's size and age. Judge the urgency from the runtime your own UPS reports rather than from a fixed figure.

#### NutUpsdLowBattery

This is a transition rule. NUT notifies on the low-battery flag alone and reports it once, when the flag is raised. The source is `ups_low_batt` in NUT v2.8.5 `clients/upsmon.c`. Check whether the UPS is also on battery and how much runtime the connected load has left.

#### NutUpsdForcedShutdown

This is a transition rule. With `SHUTDOWN_ON_BATTERY_CRITICAL=true`, `NutUpsdPowerOffFailed` reports a poweroff attempt that failed or was refuted. It does not report an attempt whose settle state was unreadable, because that record is `level=warn` and no rule matches it. So a silent `NutUpsdPowerOffFailed` does not confirm that the host powered off. `NutUpsdPowerOffPathBroken` watches the same path ahead of time.

With the default `false`, `nut-shutdown-noop.sh` logs the event and no host powers off. The privileged `upsmon` parent exits after `SHUTDOWNCMD`, and the container exits with it. The example's `restart: unless-stopped` starts monitoring again, so the alert fires about once per container life. That continues until mains power returns or the UPS stops supplying the load.

#### NutUpsdHostSyncExpired

This is a transition rule, written once per forced-shutdown attempt that timed out. A secondary was still logged in, with `maxlogins > 1`, when `HOSTSYNC` ran out. The alert does not mean that the secondary was hard-powered-off or that its own shutdown failed. The line is a raw `upsmon` diagnostic from line 1377 of NUT v2.8.5 `clients/upsmon.c`.

#### NutUpsdNotifyExecFailed

This is a transition rule. The image's `patches/cve-2026-54161-notifycmd-execvp.patch` backport logs `notify: execvp(<cmd>) failed: <strerror>` from `notify()`, at lines 154 to 157 of the patch. Every `event=<TYPE>` line comes from that handler, so every `event=` rule is blind while the fault lasts. `upsmon` writes the failure once per event routed to `NOTIFYCMD` and never repeats it, so the alert resolves 15 minutes after the last routed event. On a quiet UPS the gap between events has no bound, so no window can track the fault.

The `NOTIFYFLAG` rows in your mounted `upsmon.conf.user` decide which events survive as the `upsmon` log copy. An event routed only to `EXEC` is lost outright, while a `SYSLOG+EXEC` row keeps the upstream plain-text notice. The fault needs a mounted `upsmon.conf.user` whose `NOTIFYCMD` is wrong or not executable, because the generated config wires the shipped handler.

#### NutUpsdCommsLost

This is a state rule. `upsmon` repeats `NOCOMM` every `NOCOMMWARNTIME` seconds while comms stay down. Keep the 15-minute window above twice your `NOCOMMWARNTIME`, so the alert stays firing between warnings.

#### NutUpsdCommsRepaired

This is a transition rule. `lifecycle.sh` writes the record once per watchdog-repaired outage, when comms return, and only after at least one driver restart. So one record means the watchdog restarted the driver and comms came back. The rule alerts on the first repair rather than waiting for a second outage, because `stale_secs` and `restarts` already carry the whole outage. A recovery with `COMMS_WATCHDOG=false`, or one the UPS made without a driver restart, writes no record and is outside this rule.

The alert resolves 6 hours after the record. That is the widest range in the `nut-upsd-events` group, and its query cost on a live ruler has not been measured. If the cost matters, shorten it or raise the group interval. The rule does not group by `container`, because the message reads `stale_secs` and `restarts` from the matched series. Two repairs in one window alert separately only when those values differ.

#### NutUpsdHardwareFault

This is a pair rule for `ALARM` and a state rule for `REPLBATT`.

NUT raises `ALARM` once per change and `NOTALARM` once when the last alarm clears, so the alert holds from the first until the second. The detail field names the fault. It can be a worn or missing battery, a fan failure, overheating, a charger failure or a battery voltage out of range. With the generated `ALARMCRITICAL 1`, `upsmon` presumes the UPS dead if comms drop while `ALARM` holds, and that starts the forced shutdown. Treat `ALARM` as urgent rather than as a service reminder.

NUT has no clear for `REPLBATT`. It repeats the event every `RBWARNTIME` seconds while the UPS reports the battery worn, so the 25-hour range stays above twice the 12-hour default and the alert holds between reminders. If you raise `RBWARNTIME`, raise the range too. After you replace the battery, the alert resolves 25 hours after the last reminder, or at once when the container starts again.

#### How the pair rules hold

The pair rules map a raise to 1 and its clear to 0, and keep the latest value in their range: 7 days for the flags and 6 hours for `NutUpsdOnBattery`. A clear is logged once and a raise is not repeated, so with no clear the alert holds for the whole range after the raise.

The image's `starting upsmon` line maps to 0 in every pair. `upsmon` starts with every flag clear and reports each flag that still holds on its first poll. So a clear that happened while the container was down cannot hold the alert, and each container start reports a flag that still holds. The alert can resolve until that poll. If your Loki keeps less than 7 days of logs, a flag holds only as long as its raise stays in Loki. Each evaluation of a pair reads up to its range of this container's log, and that query cost on a live ruler has not been measured. If it matters, raise the `nut-upsd-state` group interval or shorten the ranges.

#### NutUpsdProtectionDegraded

This is a pair rule for each of `CAL`, `BYPASS` and `OVER`, each with its own clear, `NOTCAL`, `NOTBYPASS` or `NOTOVER`. The alert keeps firing while any of the three flags holds, so one flag's clear leaves it firing for another.

While `CAL` holds, `upsmon` presumes the UPS dead as soon as comms are lost, so a forced shutdown can follow one failed poll. No option turns that off, unlike `ALARMCRITICAL` for `ALARM` and `OFFDURATION` for `OFF`.

`BYPASS` means the UPS still powers the load but no longer protects it, so the next outage drops the load. While the flag holds, `upsmon` also presumes the UPS dead if comms drop. That counts it out of `MINSUPPLIES` and starts the forced shutdown, as `is_ups_critical` in NUT v2.8.5 `clients/upsmon.c` shows. No option turns that off either, so treat `BYPASS` as urgent rather than as a task to schedule.

`OVER` means the connected load is above the UPS rating, so reduce the load. It makes the UPS critical only when `OVERDURATION` is set, and the generated `upsmon.conf` leaves it unset. `BYPASS` also switches `upsmon` to `POLLFREQALERT` while it holds, and `OVER` does that only when `OVERDURATION` is set.

#### NutUpsdProtectionUnavailable

`NOPARENT` means the privileged `upsmon` parent died, so a forced shutdown cannot power off the host. NUT has no clear for it. `upsmon` repeats it every 120 seconds while the parent stays dead, so on that event this is a state rule over 15 minutes. The source is `check_parent` in NUT v2.8.5 `clients/upsmon.c`.

`OFF` means the UPS reports itself administratively off or asleep, so the load is unprotected. On that event this is a pair rule, held until `NOTOFF`. Inspect the UPS and restore protection. With the generated `OFFDURATION 30`, once the UPS has reported `OFF` for that long, `upsmon` presumes it dead even while comms are healthy. That counts it out of `MINSUPPLIES` and starts the forced shutdown, as `ups_is_off` and `is_ups_critical` show. A mounted `upsmon.conf.user` with `OFFDURATION -1` turns that off.

#### NutUpsdPowerOffPathBroken

This is a state rule. The probe repeats its error every `DBUS_PROBE_INTERVAL` seconds. Keep the window above twice `DBUS_PROBE_INTERVAL`, or the alert flaps between probes. The alert also stays firing for up to one window after the path recovers. The metric rule reads `nut_upsd_poweroff_path_ok` and resolves at the first good check.

The probe asks logind `CanPowerOff` over the mounted system bus. A good answer proves that logind owns the bus name and that the standing authorisation allows the call. It is not an end-to-end check, its sample is up to one `DBUS_PROBE_INTERVAL` old, and it does not see inhibitor locks. On systemd v257 or later, a block inhibitor makes logind refuse the real `PowerOff` call before polkit, while `CanPowerOff` still answers yes. On older systemd releases, root overrides the inhibitor and powers off despite the lock.

Read the detail field. A missing socket or a bus error points at `/run/dbus/system_bus_socket` or the host D-Bus daemon. An authorisation answer points at the host's polkit decision for `org.freedesktop.login1.power-off`. A user-namespace remap is a common cause, because the sender loses the euid-0 shortcut. The shipped power-off policy then asks for admin authentication, which a non-interactive call cannot supply.

#### NutUpsdPowerOffFailed

This is a transition rule, written once per forced-shutdown attempt. Either every D-Bus `PowerOff` attempt failed, or logind accepted the request and then stopped reporting a pending poweroff while the container was still running. So the host kept running while the UPS was about to stop supplying it. The example restart policy starts monitoring again, so a UPS that stays critical makes another attempt. The alert then fires about once per container life until mains power returns.

An attempt that failed while logind reported a pending shutdown-class action also counts as failed. `PreparingForShutdown` is set for any delayed shutdown-class action and cannot name which one. So a concurrent reboot shows as a failed poweroff, with the property reply in `settle` beside the bus error in `detail`. That instance is a false positive for this poweroff.

The false positive clears about 15 minutes after the record, because the rule counts log lines over 15 minutes. Stopping the container or the host does not remove a line Loki already holds.

If every attempt failed, the detail field carries the bus or authorisation error. A separate `D-Bus poweroff inhibitors at failure` record appears only when logind returned a readable refutation. Its detail lists the current lock holders and cuts a long list short. Without that record, the settle state was unreadable, which does not prove that no inhibitor was held. On systemd v257 or later, a block inhibitor causes this failure before polkit, and on older releases root overrides the lock.

If logind first accepted the request, the detail field carries the `PreparingForShutdown` reply and no inhibitor record follows. The host journal then holds the cause, not `docker logs`.

#### NutUpsdContainerError

The rule matches every `level=error` line the image writes from its entrypoint, validation, config generation, credential and TLS setup, and lifecycle helpers. It fires with no `NOTIFYCMD` wired and with host shutdown off. The lines include:

- an environment variable it refused
- a NUT daemon that failed to start or exited later
- a boot refusal, such as a missing `/dev/bus/usb`, an unmountable D-Bus socket with host shutdown on, or a config or `*.user` override it could not generate or install
- a certificate or credential it could not provision
- a comms watchdog whose driver restart failed on any attempt, or that is still restarting from its last fast retry onward
- a pidfile PID it refused to kill
- a background worker it had to respawn
- an `upsd` that stopped answering the protocol probe, after which the container stops its services and exits
- a forced-shutdown path record

An abort exits the container, so the restart policy retries it and the line repeats while the UPS goes unmonitored. The image healthcheck confirms neither kind of abort. A boot refusal exits inside the start period, and a teardown after boot exits before enough probes fail to mark the container unhealthy. The probe interval, retry count and start period are the `HEALTHCHECK` values in the Dockerfile.

The rule is a net under the others and overlaps them. A broken D-Bus poweroff path also fires `NutUpsdPowerOffPathBroken`, and an unconfirmed host poweroff also fires `NutUpsdPowerOffFailed`. A forced-shutdown path record does not fire `NutUpsdForcedShutdown`, because that rule keys on `event=`, which only `nut-notify.sh` writes and this rule's exclusion drops.

If a mounted `upsmon.conf.user` leaves out `NOTIFYCMD`, this warning is the only alert-firing record of a forced shutdown. That holds only while `SHUTDOWNCMD` is still one of the image's `nut-shutdown` scripts. With any other `SHUTDOWNCMD`, a forced shutdown leaves no alert-firing record here, because the `upsmon` parent-exit record is `level=warn`.

## Dashboard

[`grafana-dashboard.json`](../grafana-dashboard.json) imports as the NUT UPS dashboard. It reads the metrics above from a Prometheus data source and needs Grafana 13.2 or newer. When you run more than one container, the UPS variable picks the exporter to show. It has three tabs:

- Overview shows the UPS status in words, the battery charge, the runtime left beside the low battery mark, and the load. Below them, a Needs attention row appears only while an alert from `alerts/promql.yaml` fires, with one tile per rule. Each tile reads its rule's `ALERTS` series, which Prometheus and the Mimir ruler store beside your metrics, so the row stays hidden while those rules are not loaded.
- Power over time charts the charge and the runtime against their low battery marks, the load, the mains and output voltage, and when the UPS ran on battery.
- Exporter health shows whether the scrape, `upsd` and the UPS data are healthy, the driver restarts the comms watchdog made, and the shutdown path: host poweroff, the D-Bus check and the `upsmon` parent.

The status box shows the forced-shutdown flag (`FSD`) while the UPS reports it. The forced-shutdown event, a failed poweroff, an error line and the other events of the `nut-upsd-events` group of `alerts/logql.yaml` leave no series, so they stay in the log and in that group.

The dashboard is versioned with the image, and the `grafana-dashboard.json` of release `<tag>` matches the metrics that image serves. Each release attaches it with its checksum at `https://github.com/cplieger/docker-nut-upsd/releases/download/<tag>/grafana-dashboard.json`, and each image publish pushes it as the OCI artifact `ghcr.io/cplieger/docker-nut-upsd/dashboard:<tag>`. The file sets `metadata.name` to `docker-nut-upsd`, which Grafana uses as the dashboard UID, so importing a newer copy over the old one updates it in place.

## Knowing the app is alive

| Route | Method | Port | Login | Answers |
| --- | --- | --- | --- | --- |
| `/healthz` | `GET`, `HEAD` | `METRICS_PORT`, `9199` by default | none | `200 {"status":"ok"}`, or `503 {"status":"unhealthy","reasons":[...]}` |
| `/metrics` | `GET` | the same port | none, so keep the port on your network | Prometheus text format |

**What healthy means.** `upsd` answers within 3 seconds with a fresh `ups.status` for the UPS. Stale data, a driver that is not connected or an `upsd` that does not answer makes the container unhealthy. A UPS on battery is still healthy, because the check reports the link to the UPS, not the power state. `/healthz` and the Docker healthcheck ask `upsd` the same question, so they give the same answer.

**Docker health.** The image checks itself every 30 seconds with `upsc <UPS_NAME>@<address>:<API_PORT> ups.status`, against `upsd` inside the container. Docker marks the container unhealthy after 3 failures, and allows 135 seconds after a start. Docker's health status notifies nobody on its own, and Docker does not restart an unhealthy container. The comms watchdog restarts the driver after `COMMS_RECOVERY_TIMEOUT` seconds of stale data, and the container exits when `upsd` stops answering for about a minute, as [How docker-nut-upsd works](how-it-works.md) explains.

**Who is told.**

| You run | A stopped container | A UPS that stops answering |
| --- | --- | --- |
| Prometheus with `alerts/promql.yaml` | `NutUpsdDown` | `NutUpsdCommsLost`, and `/healthz` turns 503 |
| Loki only | no rule sees a stopped container. `NutUpsdContainerError` fires on the error line of each refused or failed start. Add an uptime prober on `/healthz`, as in the row below | `NutUpsdCommsLost` |
| Docker or Unraid only | an uptime prober on `/healthz`, or on TCP port 3493 with `METRICS_PORT=0`, or something that watches Docker health | the same |

Every NUT client also logs its own `COMMBAD` and `NOCOMM` events when it loses this server. A `upsmon` that hangs while its parent stays alive is not detected.

**Probing from outside.** Check `GET http://<host>:9199/healthz` and pass on status 200 only. Do not match the body. Use a 5-second timeout, check every 60 seconds, alert after 3 failures, and wait 135 seconds after a first start. Publish the port to the prober's network first. With `METRICS_PORT=0`, probe TCP port 3493 instead, which proves only that `upsd` accepts connections.
