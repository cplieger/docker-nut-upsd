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

The rules for `UPSPowerOffPathBroken` and `UPSPowerOffFailed` need `SHUTDOWN_ON_BATTERY_CRITICAL=true`, and `DBUS_PROBE_INTERVAL=0` turns off only the first one. The notes below explain each rule's window and shape.

The generated `upsmon.conf` sets a `NOTIFYCMD` that logs each event, with `EXEC` on the matching `NOTIFYFLAG` lines. If you mount your own `upsmon.conf.user`, keep the `NOTIFYCMD` line and the `EXEC` flags, or the `event=` lines and the alerts that key on them disappear. NUT runs `NOTIFYCMD` directly, without a shell, and passes the message as `$1`. This comes from the CVE-2026-54161 backport and matches NUT v2.8.6. So the value must be the path to an executable. Wrap a shell snippet or a command with arguments in a small script and point `NOTIFYCMD` at it.

Thresholds, `for:` windows and the `severity` labels are starting points. Change the `container` selector to the label your log collector sets, and route by whatever labels your Alertmanager uses.

### How the rules read the log

The event and message rules read parsed logfmt fields, so a word inside a quoted value cannot match them. `UPSContainerError` reads the start of the line instead, so a `level=error` inside another record's detail cannot fire it. `UPSHostSyncExpired` matches the end of a raw `upsmon` line for the same reason. Its pattern is open at the start, because a `DEBUG_MIN` setting in a mounted `upsmon.conf.user` makes `upsmon` prefix each line with an elapsed time.

If your log collector already sets a stream label named `event` or `msg`, Loki stores the parsed field as `event_extracted` or `msg_extracted`. The rule filters then read your stream label, so they may match nothing or the wrong records.

The image runs `upsmon` in the foreground, so its own lines reach the log too. They include a `LOG_NOTICE` copy of each event flagged `SYSLOG`, warnings such as `assuming dead` and `Too few UPS(es) are healthy`, and process errors. These lines carry no `level=` prefix and no logfmt fields. `UPSHostSyncExpired` and `UPSNotifyExecFailed` each match one of them. Read the rest in the log.

Three routed events have no rule on purpose:

- `COMMBAD` fires on any move into lost comms, including the unknown state `upsmon` starts each UPS in. Its count cannot separate an outage from a container start. The source is `ups_is_gone` in NUT v2.8.5 `clients/upsmon.c`.
- `COMMOK` is the upstream recovery notice. `UPSCommsRepaired` alerts on a watchdog repair from the container's own record instead. That record carries the outage length and restart count, and it cannot fire on a cold start.
- `OTHER` carries status words that `upsmon` does not classify.

An `event=` line with no alert is one of these three, or a parsed field that lost to a stream label of the same name.

### Transition and state rules

A state rule stays firing while its condition holds, because its source repeats the line faster than the window. A transition rule marks a change and resolves when its line leaves the window. No window can make a transition rule track a condition, because the window would have to outlast the condition itself. Each rule's own source decides its shape, and the notes below name it. `UPSContainerError` has neither shape, because its sources range from a one-shot boot refusal to the watchdog's repeating escalation.

The group evaluates every 10 seconds instead of the ruler's 1-minute default. `UPSOnBattery` pairs this with `for: 10s`, so the battery state must hold across one full interval before the alert fires. A brief dip, such as a load surge from a laser printer's fuser on the UPS, clears within one `upsmon` poll and stays silent. A real outage fires in about 10 to 20 seconds.

A 1-minute evaluation could delay that by up to a minute, and the runtime left depends on the load and can be short. The interval applies to every rule in the group. If the extra query load is not worth it for the slower rules, raise it.

### Notes on each rule

#### UPSOnBattery

This is a transition rule, because `upsmon` logs `ONBATT` once when it loses mains and `ONLINE` once when mains returns. The source is `ups_on_batt` and `ups_on_line` in NUT v2.8.5 `clients/upsmon.c`. The rule keeps the latest of the two in time order. A recovery and a second outage inside one window then fire on the second `ONBATT`. The alert resolves within 2 minutes while the UPS may still carry the load, so read `ups.status` over the NUT protocol to follow the outage.

The `ONBATT` line lands within one `POLLFREQ`. `upsmon` then switches to `POLLFREQALERT` and restores `POLLFREQ` only once it sees the UPS on line again. The source is `ups_on_batt` at line 887 and `try_restore_pollfreq`. So a flicker spans about `POLLFREQ` + `POLLFREQALERT`, and the 2-minute window must stay above that. If you raise either setting, raise the window too, and see [Configuration](configuration.md) for both defaults.

How long the battery holds depends on the load and on the battery's size and age. Judge the urgency from the runtime your own UPS reports rather than from a fixed figure.

#### UPSLowBattery

This is a transition rule. NUT notifies on the low-battery flag alone and reports it once, when the flag is raised. The source is `ups_low_batt` in NUT v2.8.5 `clients/upsmon.c`. Check whether the UPS is also on battery and how much runtime the connected load has left.

#### UPSForcedShutdown

This is a transition rule. With `SHUTDOWN_ON_BATTERY_CRITICAL=true`, `UPSPowerOffFailed` reports a poweroff attempt that failed or was refuted. It does not report an attempt whose settle state was unreadable, because that record is `level=warn` and no rule matches it. So a silent `UPSPowerOffFailed` does not confirm that the host powered off. `UPSPowerOffPathBroken` watches the same path ahead of time.

With the default `false`, `nut-shutdown-noop.sh` logs the event and no host powers off. The privileged `upsmon` parent exits after `SHUTDOWNCMD`, and the container exits with it. The example's `restart: unless-stopped` starts monitoring again, so the alert fires about once per container life. That continues until mains power returns or the UPS stops supplying the load.

#### UPSHostSyncExpired

This is a transition rule, written once per forced-shutdown attempt that timed out. A secondary was still logged in, with `maxlogins > 1`, when `HOSTSYNC` ran out. The alert does not mean that the secondary was hard-powered-off or that its own shutdown failed. The line is a raw `upsmon` diagnostic from line 1377 of NUT v2.8.5 `clients/upsmon.c`.

#### UPSNotifyExecFailed

This is a transition rule. The image's `patches/cve-2026-54161-notifycmd-execvp.patch` backport logs `notify: execvp(<cmd>) failed: <strerror>` from `notify()`, at lines 154 to 157 of the patch. Every `event=<TYPE>` line comes from that handler, so every `event=` rule is blind while the fault lasts. `upsmon` writes the failure once per event routed to `NOTIFYCMD` and never repeats it, so the alert resolves 15 minutes after the last routed event. On a quiet UPS the gap between events has no bound, so no window can track the fault.

The `NOTIFYFLAG` rows in your mounted `upsmon.conf.user` decide which events survive as the `upsmon` log copy. An event routed only to `EXEC` is lost outright, while a `SYSLOG+EXEC` row keeps the upstream plain-text notice. The fault needs a mounted `upsmon.conf.user` whose `NOTIFYCMD` is wrong or not executable, because the generated config wires the shipped handler.

#### UPSCommsLost

This is a state rule. `upsmon` repeats `NOCOMM` every `NOCOMMWARNTIME` seconds while comms stay down. Keep the 15-minute window above twice your `NOCOMMWARNTIME`, so the alert stays firing between warnings.

#### UPSCommsRepaired

This is a transition rule. `lifecycle.sh` writes the record once per watchdog-repaired outage, when comms return, and only after at least one driver restart. So one record means the watchdog restarted the driver and comms came back. The rule alerts on the first repair rather than waiting for a second outage, because `stale_secs` and `restarts` already carry the whole outage. A recovery with `COMMS_WATCHDOG=false`, or one the UPS made without a driver restart, writes no record and is outside this rule.

The alert resolves 6 hours after the record. That is the widest range in the group, and its query cost on a live ruler has not been measured. If the cost matters, shorten it or raise the group interval. The rule does not group by `container`, because the message reads `stale_secs` and `restarts` from the matched series. Two repairs in one window alert separately only when those values differ.

#### UPSHardwareFault

This is a transition rule, and NUT raises `ALARM` once per change. The detail field names the fault. It can be a worn or missing battery, a fan failure, overheating, a charger failure or a battery voltage out of range. With the generated `ALARMCRITICAL 1`, `upsmon` presumes the UPS dead if comms drop while `ALARM` holds, and that starts the forced shutdown. Treat `ALARM` as urgent rather than as a service reminder.

NUT repeats `REPLBATT` every `RBWARNTIME` seconds, so on the defaults expect the alert again about every 12 hours until the battery is serviced. That is the NUT reminder cadence, not a flap. Read the UPS status and plan the service.

#### UPSProtectionDegraded

This is a transition rule. NUT logs each event once when the flag is raised, so the alert resolves after 15 minutes rather than tracking the state.

While `CAL` holds, `upsmon` presumes the UPS dead as soon as comms are lost, so a forced shutdown can follow one failed poll. No option turns that off, unlike `ALARMCRITICAL` for `ALARM` and `OFFDURATION` for `OFF`.

`BYPASS` means the UPS still powers the load but no longer protects it, so the next outage drops the load. While the flag holds, `upsmon` also presumes the UPS dead if comms drop. That counts it out of `MINSUPPLIES` and starts the forced shutdown, as `is_ups_critical` in NUT v2.8.5 `clients/upsmon.c` shows. No option turns that off either, so treat `BYPASS` as urgent rather than as a task to schedule.

`OVER` means the connected load is above the UPS rating, so reduce the load. It makes the UPS critical only when `OVERDURATION` is set, and the generated `upsmon.conf` leaves it unset. `BYPASS` also switches `upsmon` to `POLLFREQALERT` while it holds, and `OVER` does that only when `OVERDURATION` is set.

#### UPSProtectionUnavailable

`NOPARENT` means the privileged `upsmon` parent died, so a forced shutdown cannot power off the host. `upsmon` repeats it every 120 seconds while the parent stays dead, so on that event the alert keeps firing. The source is `check_parent` in NUT v2.8.5 `clients/upsmon.c`. `OFF` is raised once when the flag appears, so on that event the alert marks the change and resolves after 15 minutes.

`OFF` means the UPS reports itself administratively off or asleep, so the load is unprotected. Inspect the UPS and restore protection. With the generated `OFFDURATION 30`, once the UPS has reported `OFF` for that long, `upsmon` presumes it dead even while comms are healthy. That counts it out of `MINSUPPLIES` and starts the forced shutdown, as `ups_is_off` and `is_ups_critical` show. A mounted `upsmon.conf.user` with `OFFDURATION -1` turns that off.

#### UPSPowerOffPathBroken

This is a state rule. The probe repeats its error every `DBUS_PROBE_INTERVAL` seconds. Keep the window above twice `DBUS_PROBE_INTERVAL`, or the alert flaps between probes. The alert also stays firing for up to one window after the path recovers.

The probe asks logind `CanPowerOff` over the mounted system bus. A good answer proves that logind owns the bus name and that the standing authorisation allows the call. It is not an end-to-end check, its sample is up to one `DBUS_PROBE_INTERVAL` old, and it does not see inhibitor locks. On systemd v257 or later, a block inhibitor makes logind refuse the real `PowerOff` call before polkit, while `CanPowerOff` still answers yes. On older systemd releases, root overrides the inhibitor and powers off despite the lock.

Read the detail field. A missing socket or a bus error points at `/run/dbus/system_bus_socket` or the host D-Bus daemon. An authorisation answer points at the host's polkit decision for `org.freedesktop.login1.power-off`. A user-namespace remap is a common cause, because the sender loses the euid-0 shortcut. The shipped power-off policy then asks for admin authentication, which a non-interactive call cannot supply.

#### UPSPowerOffFailed

This is a transition rule, written once per forced-shutdown attempt. Either every D-Bus `PowerOff` attempt failed, or logind accepted the request and then stopped reporting a pending poweroff while the container was still running. So the host kept running while the UPS was about to stop supplying it. The example restart policy starts monitoring again, so a UPS that stays critical makes another attempt. The alert then fires about once per container life until mains power returns.

An attempt that failed while logind reported a pending shutdown-class action also counts as failed. `PreparingForShutdown` is set for any delayed shutdown-class action and cannot name which one. So a concurrent reboot shows as a failed poweroff, with the property reply in `settle` beside the bus error in `detail`. That instance is a false positive for this poweroff.

The false positive clears about 15 minutes after the record, because the rule counts log lines over 15 minutes. Stopping the container or the host does not remove a line Loki already holds.

If every attempt failed, the detail field carries the bus or authorisation error. A separate `D-Bus poweroff inhibitors at failure` record appears only when logind returned a readable refutation. Its detail lists the current lock holders and cuts a long list short. Without that record, the settle state was unreadable, which does not prove that no inhibitor was held. On systemd v257 or later, a block inhibitor causes this failure before polkit, and on older releases root overrides the lock.

If logind first accepted the request, the detail field carries the `PreparingForShutdown` reply and no inhibitor record follows. The host journal then holds the cause, not `docker logs`.

#### UPSContainerError

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

The rule is a net under the others and overlaps them. A broken D-Bus poweroff path also fires `UPSPowerOffPathBroken`, and an unconfirmed host poweroff also fires `UPSPowerOffFailed`. A forced-shutdown path record does not fire `UPSForcedShutdown`, because that rule keys on `event=`, which only `nut-notify.sh` writes and this rule's exclusion drops.

If a mounted `upsmon.conf.user` leaves out `NOTIFYCMD`, this warning is the only alert-firing record of a forced shutdown. That holds only while `SHUTDOWNCMD` is still one of the image's `nut-shutdown` scripts. With any other `SHUTDOWNCMD`, a forced shutdown leaves no alert-firing record here, because the `upsmon` parent-exit record is `level=warn`.
