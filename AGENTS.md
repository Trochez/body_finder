# Body Finder Agent Instructions

## Purpose

Experimental Flutter research application for uncertainty-aware search-and-rescue technology development.

## Current state

The repository is initialized and active. Flutter/Dart application source, Android/iOS/Linux targets, CI, release-artifact workflows, native capability probes, geometry utilities, session utilities, simulation scaffolding, and tests are present.

## Working rules

1. Never claim that an empty result proves absence.
2. Never present synthetic simulation markers as real detections.
3. Distinguish hardware presence, public API availability, permission state, and actual measurement availability.
4. Do not claim raw Wi-Fi CSI or raw UWB access unless verified on the exact platform/API.
5. Keep physical-device-dependent features behind runtime capability checks.
6. Add tests for deterministic domain/application logic.
7. Keep pull-request CI green before merging to `main`.
8. Record physical device model and OS version for every hardware validation result.

## Main project surfaces

- `lib/domain/`
- `lib/application/`
- `lib/infrastructure/`
- `lib/presentation/`
- `test/`
- `docs/`
- `.github/workflows/`

## Validation commands

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```
