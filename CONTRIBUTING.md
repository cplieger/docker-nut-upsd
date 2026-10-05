# Contributing to docker-nut-upsd

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, releases, synced files and checks apply here.

## Rules

- A new setting needs a `_check` row in `check_required_vars` or `check_optional_vars` and an assignment in `canonicalize_validated_values`, both in `validate.sh`. Without the assignment, a value from an env file that ends in a newline stops the container at startup.
- A numeric setting also needs `strip_leading_zeros` before `$(( ))` reads it, as `entrypoint.sh` does for the watchdog settings. The numeric check accepts a leading zero, which `$(( ))` reads as octal, so `08` stops the script and `012` means 10.
- Every row takes the `control` check. Add `quotes`, `backslash` and `hash` when `generate-config.sh` writes the value inside double quotes, `brackets` when it names a section, and `nospace` when it is unquoted. A missing check lets a setting inject lines or tokens into a NUT config file.
- Check a NUT daemon's PID with `pid_matches_binary` in `lifecycle.sh`, never through `/proc/<pid>/exe` alone. The daemons drop to the `nut` user without a new exec, so `exe` is unreadable in a running container. An `exe` check passes the build-stage tests and fails every real start.
- Each file in `patches/` backports an upstream NUT commit. Never edit its diff. Report a defect in patched code upstream, because removing the patch later would drop a local change with no record of it.
- When a NUT update includes the upstream commit a patch backports, remove the patch rather than rebase it. Removing a patch touches its file, its `COPY` entry, `patch` line, comment and SBOM `patch=` list in the `Dockerfile`, the "What the image contains" section of `docs/hardening.md`, and the README's License section.
- Removing `cve-2026-54161-notifycmd-execvp.patch` also touches the `NOTIFYCMD` paragraph of `docs/monitoring.md` and the `UPSNotifyExecFailed` rule in `alerts/logql.yaml`. That rule matches the `execvp(` failure line the patch adds. No test checks that NUT still logs that line, so confirm it in the new release.
- When the build's source check reports that the `OFFDURATION`, `OBLBDURATION` or `ALARMCRITICAL` pin in `generate-config.sh` differs from `clients/upsmon.c`, choose NUT's new default or keep the current value. Keeping it means changing that check in the `Dockerfile` too.
- Either way, update the `UPSHardwareFault` and `UPSProtectionUnavailable` descriptions in `alerts/logql.yaml` and the "Host shutdown" section of `docs/configuration.md`, which call the pins NUT's defaults. No test checks that wording.
