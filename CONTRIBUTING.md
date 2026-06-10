# Contributing to docker-nut-upsd

This image packages Network UPS Tools (NUT) `upsd` into an Alpine
container. It is POSIX shell only — no Go, no compiled app code of our
own. This guide covers the conventions that aren't obvious from reading
a single file.

## Script layout

`entrypoint.sh` (`#!/bin/sh`, `set -eu`) is the only executable entry
point. It sources four helper modules and orchestrates startup; the
helpers are libraries, not programs:

| Script | Role |
|--------|------|
| `validate.sh` | Env-var validation functions + table-driven dispatch |
| `generate-config.sh` | Generates `ups.conf` / `upsd.conf` / `upsd.users` / `upsmon.conf` |
| `lifecycle.sh` | `stop_services`, `wait_for_pidfile` daemon helpers |
| `password.sh` | `ADMIN_PASSWORD` generation/caching, weak-password warning |

Three more scripts are invoked by NUT at runtime (not sourced):

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
env var that reaches a config file means touching `validate.sh` in three
places:

1. Add a row to `VALIDATION_TABLE` (or `VALIDATION_TABLE_OPTIONAL` for
   vars only checked when non-empty), e.g. `MY_VAR:newlines,quotes`.
   Supported checks: `newlines`, `quotes`, `brackets`, `identifier`,
   `numeric`, `port`, `percent`.
2. Add a `case` arm to `_resolve_var` returning `"${MY_VAR:-}"`. The
   resolver is an explicit lookup table on purpose — there is no
   indirect expansion, so an unlisted var fails the run instead of
   silently resolving to empty.
3. If you need a check that doesn't exist yet, add a `validate_*`
   function and wire it into `_dispatch_check`.

Every value that lands in a NUT config file must reject embedded
newlines (config injection), and identifiers/passwords additionally
reject brackets (INI section injection) and double quotes (NUT quoting
breakout). When in doubt, copy the check set of the most similar
existing row.

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
- **Runs as root by design.** USB access (`upsdrvctl`) and config
  ownership need it; `upsd` drops to user `nut` internally via configure
  flags. The Trivy AVD-DS-0002 finding is suppressed in `.trivyignore`.

## Local validation

The scripts and Dockerfile are linted in CI; run the same tools before
pushing:

```sh
shellcheck *.sh
hadolint Dockerfile
docker build -t nut-upsd-test .
```

ShellCheck must be clean. `hadolint` reports only DL3018 (unpinned apk),
which is accepted. Note the in-script `# shellcheck source-path=SCRIPTDIR`
and targeted `disable` directives — keep them accurate when you move code.

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
