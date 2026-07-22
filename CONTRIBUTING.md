# Contributing to docker-nut-upsd

This image packages Network UPS Tools (NUT) `upsd` into an Alpine
container. It is POSIX shell only — no Go, no compiled app code of our
own. This guide covers the conventions that aren't obvious from reading
a single file.

## Script layout

`entrypoint.sh` (`#!/bin/sh`, `set -eu`) is the only executable entry
point. It sources the helper modules and orchestrates startup; the
helpers are libraries, not programs:

| Script               | Role                                                                                                      |
| -------------------- | --------------------------------------------------------------------------------------------------------- |
| `validate.sh`        | Env-var validation functions + table-driven dispatch                                                      |
| `generate-config.sh` | Generates `ups.conf` / `upsd.conf` / `upsd.users` / `upsmon.conf`                                         |
| `lifecycle.sh`       | `stop_services`, `wait_for_pidfile`, USB comms-recovery watchdog, D-Bus poweroff-path probe               |
| `password.sh`        | Generated-credential caching (`ADMIN_PASSWORD`, internal `local_upsmon`, TLS cert), weak-password warning |

More scripts are invoked by NUT at runtime (not sourced):

- `nut-notify.sh` — `NOTIFYCMD`; turns UPS events into structured
  `level=… msg=…` log lines.
- `nut-shutdown.sh` — `SHUTDOWNCMD` when `SHUTDOWN_ON_BATTERY_CRITICAL=true`;
  powers off the host via D-Bus with retries.
- `nut-shutdown-noop.sh` — `SHUTDOWNCMD` otherwise; logs the FSD event only.

The helper modules carry a `# Sourced by entrypoint.sh; not executed
directly.` header. Keep that contract: put reusable logic in a sourced
module and call it from `entrypoint.sh`, rather than growing the entry
point or adding new top-level executables.

## Adding or validating an environment variable

Validation is table-driven and deliberately avoids `eval`. Adding a new
env var that reaches a config file means touching `validate.sh` in four
places:

1. Add a row to `VALIDATION_TABLE` (or `VALIDATION_TABLE_OPTIONAL` for
   vars only checked when non-empty), e.g. `MY_VAR:newlines,quotes`.
   Supported checks: `newlines`, `quotes`, `backslash`, `brackets`,
   `identifier`, `numeric`, `positive`, `port`, `percent`.
2. Add a `case` arm to `_resolve_var` returning `"${MY_VAR:-}"`. The
   resolver is an explicit lookup table on purpose — there is no
   indirect expansion, so an unlisted var fails the run instead of
   silently resolving to empty.
3. Add an assignment to `canonicalize_validated_values`
   (`MY_VAR=$(printf '%s' "${MY_VAR:-}")`) so a trailing newline is
   stripped BEFORE validation and config writes. The resolver's own `$()`
   strips it during validation, so an uncanonicalized var would validate
   clean while writing the raw trailing LF into the config file.
4. If you need a check that doesn't exist yet, add a `validate_*`
   function and wire it into `_dispatch_check`.

Every value that lands in a NUT config file must reject embedded
newlines (config injection), and identifiers/passwords additionally
reject brackets (INI section injection) and double quotes (NUT quoting
breakout). A value written **unquoted** into a config file (e.g.
`UPS_PORT` as `port = $UPS_PORT`, or `API_ADDRESS` in `LISTEN`) must
also reject whitespace, since a space would split it into extra config
tokens. When in doubt, copy the check set of the most similar existing
row.

## Config generation conventions

`generate_all_configs` asserts each required variable with
`: "${VAR:?…}"` before writing anything — fail fast rather than emit a
half-formed config. Per-file generation is skipped when a matching
`/etc/nut/<name>.user` override is mounted (`use_user_override`), so any
new generated file should respect that same override hook.

## Gotchas worth knowing

- **NUT `parseconf` quoting.** An unescaped `"` terminates a quoted
  argument, so a multi-quoted `printf` inlined into `SHUTDOWNCMD`
  silently loses output. That's why `nut-shutdown-noop.sh` exists as a
  separate script instead of an inline command.
- **Stale PID files.** `/var/run/nut` is in the writable layer, so PID
  files survive a `docker restart` and make `upsdrvctl` kill the fresh
  driver as a "duplicate instance". The entrypoint clears `*.pid` at
  boot — preserve that.
- **PID-file polling, not `pgrep`.** `wait_for_pidfile` waits on the
  daemon's PID file (the signal upstream relies on) to dodge BusyBox
  `pgrep` quirks with daemonized processes.
- **`/proc/<pid>/exe` is unreadable for the NUT daemons.** They
  `setuid()` from root to `nut` without exec-ing afterwards, which
  clears the process's dumpable flag — and reading a non-dumpable
  process's `exe` link needs `CAP_SYS_PTRACE`, which Docker's default
  capability set does not grant (not even to root). Any PID-identity
  check must go through `pid_matches_binary` (lifecycle.sh), which
  falls back to the world-readable `/proc/<pid>/comm`; comparing `exe`
  directly works in build-stage tests (dumpable shell) and then fails
  every real boot.
- **Runs as root by design.** USB access (`upsdrvctl`) and config
  ownership need it; `upsd` drops to user `nut` internally via configure
  flags. The Trivy AVD-DS-0002 finding is suppressed in `.trivyignore`.
- **Upstream sources may carry checked-in patches.** `patches/` holds
  backports applied to the NUT source in the Dockerfile with
  `patch -p1 --fuzz=0` (strict, so source drift on a version bump fails
  the build loudly instead of silently shipping unpatched binaries).
  Each patch header names its upstream commit and removal condition -
  e.g. the CVE-2026-54161 NOTIFYCMD/execvp backport is removed (patch
  file + Dockerfile COPY/apply step together) once `NUT_VERSION` reaches
  v2.8.6. A failing `patch` step on a NUT version bump usually means the
  fix landed upstream: drop the patch rather than re-diffing it.
- **USB re-enumeration is expected, not exceptional.** Many UPSes reset
  their USB link periodically (the driver runs fine, then goes "Data
  stale"). The `comms_watchdog` in `lifecycle.sh` recovers from this by
  re-homing the driver, but it only works if the bus is passed as a
  **live bind** (`volumes: /dev/bus/usb`) plus `device_cgroup_rules:
  ["c 189:* rmw"]` — a static `devices:` mapping hides the re-enumerated
  node from the container. The restart re-opens the device while still
  root, which is why the driver must not be started already-dropped to
  `nut`. Keep the watchdog's restart path root-capable.
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
  only holds when BOTH files are generated — with a `*.user` override
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
  watchdog `chgrp -R nut /dev/bus/usb` are guarded (warn-only), so the
  container still starts on a host where the chgrp EPERMs (user-namespace
  remap, dropped `CAP_CHOWN`); the driver opens the device as root before
  dropping to `nut` regardless. Don't let either `chgrp` abort startup
  under `set -e`.
- **Leading zeros are octal in `$(( ))`.** Numeric env vars consumed by
  shell arithmetic (the `COMMS_*` timing knobs) are canonicalized to
  base-10 with `strip_leading_zeros` before use, because POSIX `$(( ))`
  reads a leading-zero value as octal: `08`/`09` error out and, under
  `set -e`, would kill the watchdog subshell. Canonicalize any new
  arithmetic-consumed numeric var the same way.

## Local validation

The scripts and Dockerfile are linted in CI; run the same tools before
pushing:

```sh
shellcheck -x *.sh tests/*.sh
hadolint Dockerfile
docker build -t nut-upsd-test .
```

ShellCheck must be clean. `hadolint` reports only DL3018 (unpinned apk),
which is accepted. Note the in-script `# shellcheck source-path=SCRIPTDIR`
and targeted `disable` directives — keep them accurate when you move code.
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
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md) —
never in a public issue.
