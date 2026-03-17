# Changelog

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
