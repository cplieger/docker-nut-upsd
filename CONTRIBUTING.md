# Contributing to docker-nut-upsd

This image packages Network UPS Tools (NUT) `upsd` into an Alpine
container. It is POSIX shell only; no Go, no compiled app code of our
own. This guide covers the conventions that aren't obvious from reading
a single file.

## Script layout

`entrypoint.sh` (`#!/bin/sh`, `set -eu`) is the only executable entry
point. It sources the helper modules and orchestrates startup; the
helpers are libraries, not programs:

| Script               | Role                                                                                                      |
| -------------------- | --------------------------------------------------------------------------------------------------------- |
| `validate.sh`        | Env-var validation                                                                                        |
| `generate-config.sh` | Generates `ups.conf` / `upsd.conf` / `upsd.users` / `upsmon.conf`                                         |
| `lifecycle.sh`       | NUT service lifecycle, comms recovery, and D-Bus poweroff-path probe                                      |
| `secrets.sh`         | Credential and STARTTLS-certificate resolution/caching, weak-password warning, staged /etc/nut install    |

More scripts are invoked by NUT at runtime (not sourced):

- `nut-notify.sh`: `NOTIFYCMD`; turns UPS events into structured
  `level=… msg=…` log lines.
- `nut-shutdown.sh`: `SHUTDOWNCMD` when `SHUTDOWN_ON_BATTERY_CRITICAL=true`;
  powers off the host via D-Bus with retries.
- `nut-shutdown-noop.sh`: `SHUTDOWNCMD` otherwise; logs the FSD event only.

The helper modules carry a `# Sourced by entrypoint.sh; not executed
directly.` header. Keep that contract: put reusable logic in a sourced
module and call it from `entrypoint.sh`, rather than growing the entry
point or adding new top-level executables.

## Adding or validating an environment variable

Validation uses value-carrying rows and deliberately avoids `eval`. Adding
an env var that reaches a config file means touching `validate.sh` in three
places:

1. Add a row to `check_required_vars` (or `check_optional_vars` for vars
   only checked when non-empty), for example:
   `_check MY_VAR "${MY_VAR:-}" control quotes`. Supported checks:
   `control`, `quotes`, `backslash`, `hash`, `nospace` (the value is
   written unquoted, so whitespace would split it into extra tokens),
   `nut_word` (credential byte and length limits; see
   `validate_nut_word`), `brackets`, `identifier`, `numeric`, `positive`,
   `port`, `percent`.
2. Add an assignment to `canonicalize_validated_values`
   (`MY_VAR=$(printf '%s' "${MY_VAR:-}")`) so a trailing newline is
   stripped BEFORE validation and config writes. A value a remote client
   must reproduce byte for byte is the exception: enumerate it there with
   a RAW assignment (`MY_VAR="${MY_VAR:-}"`), as `API_PASSWORD` and
   `ADMIN_PASSWORD` are, so the `control` check refuses a trailing LF
   instead of this app silently stripping it.
3. If you need a check that does not exist yet, add a `validate_*`
   function and wire it into `_dispatch_check`.

Every value that lands in a NUT config file must reject embedded
control characters (newline/CR/tab config injection). Values embedded
in double-quoted NUT fields: including the passwords: additionally
reject double quotes (NUT quoting breakout), backslashes and `#`
(parseconf hard-errors on an unescaped `#` inside quotes); identifiers
used as section headers (e.g. `UPS_NAME`, written as `[$UPS_NAME]`)
additionally reject bracket characters (INI section injection). A value
written **unquoted** into a config file (e.g.
`UPS_PORT` as `port = $UPS_PORT`, or `API_ADDRESS` in `LISTEN`) must
also reject whitespace (`nospace`), since a space would split it into
extra config tokens. When in doubt, copy the check set of the most
similar existing row.

## Config generation conventions

`generate_all_configs` asserts each required variable with
`: "${VAR:?…}"` before writing anything: fail fast rather than emit a
half-formed config. Per-file generation is skipped when a matching
`/etc/nut/<name>.user` override is mounted (`use_user_override`), so any
new generated file should respect that same override hook.

## Gotchas worth knowing

- **NUT `parseconf` quoting.** An unescaped `"` terminates a quoted
  argument (v2.8.5 `common/parseconf.c`, `quotecollect()`), so a
  multi-quoted `printf` inlined into `SHUTDOWNCMD` silently loses
  output. That's why `nut-shutdown-noop.sh` exists as a separate script.
- **Stale PID files.** `/var/run/nut` is in the writable layer, so PID
  files survive a `docker restart` and make `upsdrvctl` kill the fresh
  driver as a "duplicate instance". The entrypoint clears `*.pid` at
  boot: preserve that.
- **PID-file polling, not `pgrep`.** `wait_for_pidfile` waits on the
  daemon's PID file (the signal upstream relies on) to dodge BusyBox
  `pgrep` quirks with daemonized processes.
- **`/proc/<pid>/exe` is unreadable for the NUT daemons.** They
  `setuid()` from root to `nut` without exec-ing afterwards, which
  clears the process's dumpable flag: and reading a non-dumpable
  process's `exe` link needs `CAP_SYS_PTRACE`, which Docker's default
  capability set does not grant (not even to root). Any PID-identity
  check must go through `pid_matches_binary` (lifecycle.sh), which
  falls back to the world-readable `/proc/<pid>/comm`; comparing `exe`
  directly works in build-stage tests (dumpable shell) and then fails
  every real boot.
- **Runs as root by design.** USB access (`upsdrvctl`) and config
  ownership need it; `upsd` drops to user `nut` internally via configure
  flags. The Trivy AVD-DS-0002 finding is suppressed in `.trivyignore`,
  which carries the rationale; CI supplies its own ignore list, so those
  bytes reach only an ad-hoc `trivy` run in this working directory.
- **Upstream sources may carry checked-in patches.** `patches/` holds
  backports applied to the NUT source in the Dockerfile with
  `patch -p1 --fuzz=0` (strict, so source drift on a version bump fails
  the build loudly instead of silently shipping unpatched binaries).
  Each patch header names its upstream commit and removal condition, and
  this is the removal checklist they point at. Each patch goes when
  `NUT_VERSION` reaches v2.8.6, and removing one touches:
  - the patch file in `patches/`;
  - its `COPY patches/...` entry and its `patch -p1 --fuzz=0` line in the
    `Dockerfile`;
  - the `Dockerfile` comment above that COPY, which describes the carried
    backports and their removal condition;
  - the [README's Security section](README.md#security), whose first
    paragraph names the backports and what they cover;
  - the [README's License section](README.md#license), which keeps
    `patches/` as a GPL-2.0-or-later exception;
  - this checklist.
  Removing the CVE-2026-54161 NOTIFYCMD/execvp backport additionally requires
  re-reading the [README's Alerting section](README.md#alerting). Re-affirm both
  claims in its `NOTIFYCMD` paragraph against the new pin: NUT executes the
  command directly, and `NOTIFYCMD` must be an executable path with arguments or
  shell snippets wrapped in a script. Upstream master parses `NOTIFYCMD` into an
  argument vector, so do not assume that the second claim remains true. Also
  re-affirm the `UPSNotifyExecFailed` matcher in `alerts/logql.yaml`. Its
  `execvp(`/`failed` filters match a diagnostic that the backport introduces,
  and dropping the patch removes the current `--fuzz=0` drift signal.
  Do not edit the diff bodies: a patch that no longer matches what
  upstream wrote is no longer a backport, and the removal drops the whole
  file with nothing recording the divergence - so a defect found in
  patched code is reported upstream, not fixed in the hunks.
  A failing `patch` step on a NUT version
  bump usually means the fix landed upstream: drop the patch rather than
  re-diffing it.
- **`driver_transport`'s censuses are hand-copied from the pin.**
  `validate.sh` lists NUT's libusb and network driver names literally
  (`drivers/Makefile.am`: `USB_LIBUSB_DRIVERLIST`, `SNMP_DRIVERLIST`,
  plus `apcupsd-ups` from `NUTSW_DRIVERLIST`). A `NUT_VERSION` bump must
  re-read those lists: a renamed or added driver silently classifies as
  `other`, and the runtime image carries no source tree for a test to
  derive them from.
- **The libmodbus build pre-seeds `ac_cv_type_struct_termios2=no`.** On a
  `LIBMODBUS_VERSION` bump, drop that assignment from the libmodbus
  `./configure` line and rebuild. Restore it only if `modbus-rtu.c` fails to
  compile on musl. If the build passes, remove the override and its explanatory
  comment. The cache variable suppresses the check, so a build with the override
  proves nothing about whether upstream fixed the musl detection.
- **The `upsmon` timing defaults are hand-copied from the pin.** The
  consecutive `: "${VAR:=N}"` directives in `entrypoint.sh`, from `POLLFREQ`
  through `RBWARNTIME`, restate NUT v2.8.5's defaults. A `NUT_VERSION` bump must
  compare every directive against `clients/upsmon.c` and either update it or
  reaffirm the pin deliberately. Pinning keeps the FSD sequence and notification
  intervals stable across a bump. `generate-config.sh` separately pins
  `OFFDURATION`, `OBLBDURATION` and `ALARMCRITICAL`, and deliberately leaves
  `OVERDURATION` unset. Compare all four choices with the new pin and decide
  whether to re-pin them. Re-read the `UPSHardwareFault` annotation for
  `ALARMCRITICAL` and the `UPSProtectionUnavailable` annotation for
  `OFFDURATION`; both credit upstream for the pinned default. If a timing default
  moves, review the coupled sites in the same change: `alerts/logql.yaml` carries
  the literals 5, 300 and 43200 in its windows and prose, and
  `tests/shell/alert_state_window_contract_test.sh` reads `POLLFREQ`,
  `POLLFREQALERT`, `NOCOMMWARNTIME` and `RBWARNTIME` from the directives. Its
  window assertions derive their minimum ranges from the shipped defaults, and
  its published-default assertions require the alert prose to match those
  defaults. No runtime check of the upstream pin is possible because the runtime
  image carries no NUT source tree.
- **The `clients/upsmon.c` citations are pinned to NUT v2.8.5.** On a
  `NUT_VERSION` bump, find every site with
  `grep -n 'clients/upsmon\.c' entrypoint.sh generate-config.sh validate.sh alerts/logql.yaml`
  and re-affirm each against the new pin. The timing-default comment in
  `entrypoint.sh` and the timing-and-criticality comment in `generate-config.sh`
  claim their values are upstream's own defaults. The `HOSTSYNC` ceiling comment
  in `validate.sh` justifies a refusal. Other citations explain the `DEADTIME`
  comparison and the `ups_on_batt` cadence. Two alert matchers key directly on
  upstream prose: `UPSHostSyncExpired` matches upsmon's host-sync diagnostic,
  and `UPSNotifyExecFailed` matches the execvp failure diagnostic introduced by
  the CVE backport. An upstream reword silently breaks either matcher, and the
  second matcher loses its patch-application drift signal when the backport is
  dropped. The criticality pin also couples `_emit_upsmon_conf`, the
  `UPSHardwareFault` and `UPSProtectionUnavailable` annotations, the
  `SHUTDOWN_ON_BATTERY_CRITICAL` row in the README, and the criticality cases in
  `tests/shell/alert_state_window_contract_test.sh`; the `OVERDURATION` absence
  is deliberate. At v2.8.6, re-verify every citation and both matchers before
  removing the checked-in patches.
- **USB re-enumeration is expected, not exceptional.** Many UPSes reset
  their USB link periodically (the driver runs fine, then goes "Data
  stale"). The `comms_watchdog` in `lifecycle.sh` recovers from this by
  re-homing the driver, but it only works if the bus is passed as a
  **live bind** (`volumes: /dev/bus/usb`) plus `device_cgroup_rules:
  ["c 189:* rmw"]`: a static `devices:` mapping hides the re-enumerated
  node from the container. The generated configuration runs the driver
  as `nut`, so the group re-assert must precede the restart and make the
  new `root:root` node accessible. A mounted `ups.conf.user` can select a
  different user. Keep the watchdog's restart path root-capable so it
  can update the node group before the bounce.
- **Password caches are root-only.** The generated credentials
  (`ADMIN_PASSWORD` at `/var/run/nut-secrets/admin_password`, the
  internal `local_upsmon` password beside it) are cached in a
  `root:root` mode-700 directory created in the Dockerfile, not in the
  `nut`-writable `/var/run/nut` that holds PID files. The entrypoint
  writes them as root via `mktemp` + atomic rename, so a compromised
  `nut`-user process cannot pre-plant a symlink at the cache path. Don't
  move them back to a `nut`-writable location or use a predictable `.$$`
  temp name.
- **The generated `upsd.users`/`upsmon.conf` pair links via
  `[local_upsmon]`.** The bundled `upsmon` authenticates with the
  reserved internal account (`upsmon primary`); the network-facing
  `[$API_USER]` is written `upsmon secondary`. That cross-file contract
  only holds when BOTH files are generated: with a `*.user` override
  mounted for exactly one of them, the generated half falls back to the
  legacy `API_USER`/`API_PASSWORD` pair and logs a `level=warn`. See the
  credential-topology comment block in `generate-config.sh` before
  touching either generator.
- **upsd reads `CERTFILE` as the `nut` user, not root.** `ssl_init()`
  runs _after_ `become_user()` (see the "keyfile must be readable by nut
  user" comment in NUT's `server/upsd.c`), so the STARTTLS PEM must be
  readable post-privilege-drop or upsd exits fatally at startup. That is
  why BOTH certificate sources are served through a `root:nut` 640
  working copy inside `/etc/nut`: the self-signed cert is _cached_ in
  the root-only `/var/run/nut-secrets` (same hardening as the password
  caches) and installed at `/etc/nut/upsd-selfsigned.pem`; the
  operator-mounted `/etc/nut/upsd.pem` is copied at every boot to
  `/etc/nut/upsd-mounted.pem`. Never chown/chmod the mount in place: on
  a rw bind mount that mutates the HOST file (handing the private key
  to whatever host group the container's `nut` GID maps to), and it is
  also why `upsd.pem` is excluded from the entrypoint's blanket
  `/etc/nut` chown/chmod sweep (a read-only mount would additionally
  EROFS the sweep and abort boot under `set -e`). Keep all these pieces
  aligned when touching the TLS path.
- **`chgrp` on the USB bus is best-effort.** Both the startup and the
  watchdog `chgrp -R nut /dev/bus/usb` are guarded (warn-only). With the
  generated configuration, the group re-assert makes a new `root:root`
  node accessible to the driver after it drops to `nut`. A failed
  `chgrp` does not prove the node is inaccessible; if access is blocked,
  NUT reports the failure when the driver starts. Do not let either
  `chgrp` abort startup under `set -e`.
- **Leading zeros are octal in `$(( ))`.** Numeric env vars consumed by
  shell arithmetic (the `COMMS_*` timing knobs) are canonicalized to
  base-10 with `strip_leading_zeros` before use, because POSIX `$(( ))`
  reads a leading-zero value as octal: `08`/`09` error out and, under
  `set -e`, would kill the watchdog subshell. Canonicalize any new
  arithmetic-consumed numeric var the same way.

## Local validation

Put assertions that run inside the image filesystem — the compiled binaries,
config generation, and the validation matrix — in `tests/smoke.sh`. That is a
Dockerfile `test` stage on the pre-final runtime stage, so it never executes the
baked ENTRYPOINT or HEALTHCHECK.

Put assertions that need the assembled, running container in the `smoke_verify`
hook in `tests/image-smoke.conf`, which drives the live container through
`$SMOKE_CONTAINER`.

Put pure shell logic and cross-file contracts that read both source files in
`tests/shell/`.

`tests/image-smoke.sh` is synced verbatim from the shared harness in
`cplieger/ci` and must never be hand-edited — a local edit is overwritten by the
next sync. Change the harness there and let the sync land it.

The scripts and Dockerfile are linted in CI; run the same tools before
pushing:

```sh
shellcheck -x *.sh tests/*.sh
hadolint Dockerfile
docker build -t nut-upsd-test .
```

ShellCheck must be clean. `hadolint` reports only DL3018 (unpinned apk),
which is accepted. Note the in-script `# shellcheck source-path=SCRIPTDIR`
and targeted `disable` directives: keep them accurate when you move code.
The `docker build` runs `tests/smoke.sh` in the image's test stage
(validation matrix, config generation, and fake-clock behavioral tests of
the comms watchdog), so a failing test fails the build.

## Commits & PRs

Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
git-cliff parses them for the release changelog (`feat:` → Added,
`fix:` → Fixed, `sec:` → Security, `chore(deps):` → Dependencies, others
→ Changed). Write the subject as the changelog line a user would read.
Open a PR against `main`; for larger changes, open an issue first to
discuss the approach.

## Conduct & security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report security vulnerabilities through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md) -
never in a public issue.
