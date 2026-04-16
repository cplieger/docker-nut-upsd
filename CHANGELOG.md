# Changelog

## 2026.04.16-ce72580 (2026-04-16)

### Dependencies

- Update alpine:3.23.4 docker digest to 5b10f43 (#197)

## 2026.04.13-98ff0b3 (2026-04-13)

### Fixed

- Update NUT_VERSION ARG to include version prefix
- Improve input validation and error handling

### Dependencies

- Update networkupstools/nut to v2.8.5

## 2026.04.01-878c624 (2026-04-01)

### Added

- Add cmdvartab data file to runtime image
- Add cmdvartab data file to runtime image
- Add driver path configuration to net-snmp build
- Add debug output for libmodbus build artifacts
- Build NUT from source with multi-arch support
- Add input validation to prevent NUT config injection
- Add shellcheck directive to cleanup function
- Add arch verification for sops and revert to localhsot for healthchecks
- Add custom built upsd server
- Seerr compsoe added and various descriptions added to compose files

### Fixed

- Refactor build to use sysroot and manual binary copying
- Replace net-snmp make install with direct file copy
- Replace make install with direct file copy for includes
- Replace libmodbus shared object copy with explicit linking
- Replace wildcard libmodbus copy with explicit versioning
- Replace make install with manual file copying
- Use stage alias in COPY --from to fix multi-platform builds
- Improve health check responsiveness and timeout handling
- Use loopback IP and improve configuration validation
- Improve newline injection detection in input validation
- Security and healthcheck fixes
- Fix nut healthcheck
- Nut server variable fix
- Fixed relative paths in app compose files

### Changed

- Update xx builder image to 1.9.0
- Quote port mapping in compose file
- Style(nut-upsd): improve shell script readability with explicit conditionals
- Migrate to structured logging and enhance validation
- Consolidate age encryption hooks and re-encrypt all env files
- Docs(nut-upsd): document env var expansion and config override patterns
- Simplify USB device mapping in compose configuration
- Update health checks and standardize environment variable quoting
- Docs(steering): Update collaboration, operations, and structure guidance
- Update encrypted environment files across all services
- Update nut image
- Silence flags and optimize for Cyberpower
- Update compose.yaml
- New approach to env file management for sops
- New approach to sops .env file naming
- Clean up variable secrets
- Relative paths
- Playing with paths
- Base.yaml path
- Try another path for extend ./
- Undo relative paths

## 2026.03.17-3c4ac7f (2026-03-17)

### Added

- Add cmdvartab data file to runtime image
- Add cmdvartab data file to runtime image
- Add driver path configuration to net-snmp build
- Add debug output for libmodbus build artifacts
- Build NUT from source with multi-arch support

### Fixed

- Refactor build to use sysroot and manual binary copying
- Replace net-snmp make install with direct file copy
- Replace make install with direct file copy for includes
- Replace libmodbus shared object copy with explicit linking
- Replace wildcard libmodbus copy with explicit versioning
- Replace make install with manual file copying
- Use stage alias in COPY --from to fix multi-platform builds

### Changed

- Update xx builder image to 1.9.0

## 2026.03.11-f24b8ab (2026-03-11)

### Fixed

- Use loopback IP and improve configuration validation

### Changed

- Style(nut-upsd): improve shell script readability with explicit conditionals
- Migrate to structured logging and enhance validation

## 2026.03.08-7da938e (2026-03-08)

### Added

- Add input validation to prevent NUT config injection

### Fixed

- Improve newline injection detection in input validation

## 2026.03.05-9aec447 (2026-03-05)

### Added

- Add shellcheck directive to cleanup function

### Changed

- Document env var expansion and config override patterns
- Simplify USB device mapping in compose configuration

## 2026.03.03-cdb462e (2026-03-04)

- Initial release
