# Changelog

All notable user-visible changes to Casa Native will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) with canonical `vX.Y.Z` tags.

## [Unreleased]

### Added

- Lazy native thumbnails in square Files-grid preview wells for supported images, documents, PDFs, and small videos, preserving full aspect ratio with native letterboxing instead of cropping, plus a 16 MiB automatic-download limit, two-job concurrency cap, memory-only cache, and icon fallback.
- Post-merge semantic versioning and draft-first release automation gated by repository checks, exact simulator tests, Xcode static analysis, CodeQL, atomic metadata/tag pushes, and recoverable unsigned-IPA publication.

### Changed

- Automatic releases reuse the successful exact-commit CI and CodeQL results, then run only release metadata validation, locked-package resolution, the unsigned device build, asset verification, and publication. The generated metadata commit skips redundant push CI; manual tagged recovery retains full validation reruns.

### Security

- Release publication now fails closed unless `RELEASE_TOKEN` authenticates as `aarikmudgal` and has repository push permission, while CODEOWNERS assigns every repository path to `@aarikmudgal`.

## [0.1.0] - 2026-08-13

### Added

- Native SwiftUI iPhone app targeting iOS 26 and later.
- Saved-host, `casaos.local`, Bonjour, manual LAN, and Tailscale connection paths with CasaOS endpoint verification.
- CasaOS login, token refresh, validated session restoration, and device-only Keychain storage.
- Dashboard with active-only 10-second CPU and memory refresh, storage, temperature, hardware, architecture, and version data.
- Read-only OS and Other Drives views, inferred multi-drive clusters, physical-member drill-down, and on-demand CasaOS-reported health details.
- Compose app listing, controls, and in-app browser routing through the active host.
- File browsing starting at `/DATA`, full server filesystem navigation and session-authenticated create/upload/rename/copy/move/delete actions subject to CasaOS service and host permissions, native Quick Look previews, 128 MiB in-memory upload/export limits, and a 1 GiB disk-backed preview limit.
- Multi-file uploads with per-file progress and completion summaries, plus persistent List and Grid file layouts.
- Ephemeral native SSH terminal with optional CasaOS credential reuse, separate credentials, first-use fingerprint confirmation, and changed-key blocking.
- Read-only PWM fan detection; compatible pigpio and Linux PWM sysfs runtime duty control; read-only owner-managed `gpio-fan`; and app-managed Manual or Automatic setup with validated GPIO/header mappings.
- Automatic kernel `gpio-fan` policies with 40–75 °C turn-on, 5–15 °C hysteresis, computed turn-off display, and explicit off/full demand wording without RPM claims.
- Transactional fan setup, configuration changes, rollback, and uninstall with cancel/finalize states, manual reboot flow, full-shutdown pin-move checklists, wiring acknowledgements, and mutation quarantine after unknown outcomes.
- Exact legacy GPIO18 `fan50` conversion with an explicit choice to restore or permanently discard the retained backup.
- Manual per-physical-drive SMART inspection over host-key-pinned SSH. A standby-safe `smartctl -a -j -n standby` preflight reads an already-awake OS drive, standalone drive, or RAID member; sleeping or unknown-state drives require a separate, path-specific spin-up confirmation.
- Structured SMART sections for overall pass/fail, temperature, explicit life or wear values, power history, sector and CRC errors, NVMe fields, identity, protocol, firmware, capacity, and device type without deriving missing metrics or a health percentage.
- Restart and shutdown confirmations, System/Light/Dark appearance, and offline mock mode.
- Fixture-backed API, path-policy, token-store, endpoint, storage, app, SSH, and fan lifecycle and recovery tests.
- Shared Xcode scheme, exact SwiftPM lockfile, GitHub Actions CI, and unsigned tagged-release automation.
- MIT License for project-specific source and documentation.

### Security

- Rejects traversal and control-character paths while leaving filesystem authorization to CasaOS service and host permissions; the UI warns that path validation is not a sandbox, adds no `/DATA` boundary, and privileged backend operations can damage the server.
- Uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for session tokens, optional SSH credentials, and pinned SSH host keys.
- Defaults fresh installations to retaining the successful CasaOS username and password in a device-only Keychain item for SSH reuse; separate SSH credentials remain available.
- Preserves saved SSH credentials when switching modes and removes both credential entries when disconnecting and forgetting a server.
- Avoids persistent terminal history and tears down SSH sessions when the terminal loses focus or the app backgrounds.
- Loads `/v1/disks` only from an individual-drive detail screen and never during automated live-server validation.
- Keeps authentication tokens out of Quick Look URLs by downloading previews through an authenticated request into app-temporary storage.
- Requires explicit confirmation before every PWM fan write, keeps detection read-only, validates supported GPIO/duty/temperature-policy inputs, preserves external configurations, disables normal controls during pending or unverified states, and sends a required sudo password only through SSH standard input rather than a command or log.
- Direct SMART never runs on entry, during refresh polling, or from drive-list and RAID-cluster screens. Wake reads require an on-screen confirmation naming the exact physical drive and `/dev` path, while first-use SSH host keys remain subject to fingerprint confirmation and pinning.

### Known limitations

- Stock CasaOS does not expose RAID level/state or full SMART attributes; the app displays only supported CasaOS fields and inferred grouping.
- Stock CasaOS 0.4.15 does not expose CPU frequency and may omit USB-backed devices from its drive-health endpoint; the app does not fabricate either value.
- PWM fan control requires saved SSH credentials, compatible Raspberry Pi hardware, already-installed server tooling, and suitable sudo permission. Automatic mode is kernel off/full `gpio-fan`, not variable speed; no RPM/tachometer monitoring is available.
- CasaOS commonly uses plain HTTP, which is unsuitable for untrusted networks without a trusted tunnel or HTTPS termination.
- Tagged release IPAs are unsigned and must be re-signed before installation.
- Detailed SMART requires saved SSH credentials, server-side smartmontools, suitable sudo permission, and working drive or USB-bridge SMART passthrough. Casa Native reports but does not guess a smartctl `-d` device type when a bridge requires one.

[Unreleased]: https://github.com/aarikmudgal/CasaNative/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aarikmudgal/CasaNative/releases/tag/v0.1.0
