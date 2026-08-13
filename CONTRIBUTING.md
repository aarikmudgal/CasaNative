# Contributing to Casa Native

Thank you for helping improve Casa Native. Keep changes narrow, testable, and safe for a personal server.

## Before starting

1. Search existing issues and pull requests for overlapping work.
2. Open an issue before a large feature, dependency replacement, API migration, or security-sensitive redesign.
3. Use GitHub private vulnerability reporting for security findings. Follow [SECURITY.md](SECURITY.md); do not disclose sensitive details publicly.

Current scope is an iPhone-native CasaOS client for iOS 26 and later. iPad-specific UI, App Store distribution, Zima cloud features, backup, VPN setup, app installation/editing, disk formatting, Samba administration, and localization are intentionally outside the initial scope unless maintainers agree otherwise.

## Development setup

- Use Xcode 26.6 or a compatible newer version.
- Open `CasaNative.xcodeproj` and use the shared `CasaNative` scheme.
- Keep `CasaNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` committed.
- Do not commit DerivedData, `.xcresult`, archives, apps, IPAs, user schemes, credentials, or live server captures.

Resolve only the versions in the lockfile:

```sh
xcodebuild \
  -resolvePackageDependencies \
  -project CasaNative.xcodeproj \
  -scheme CasaNative \
  -onlyUsePackageVersionsFromResolvedFile
```

## Making a change

- Prefer the smallest responsible layer: SwiftUI for presentation, `AppModel` for app-wide state, `CasaOSClient` for behavior, and the live or mock client for transport-specific work.
- Preserve actor isolation and Swift 6 concurrency checks.
- Treat every CasaOS response as untrusted input.
- Keep session and SSH secrets out of `UserDefaults`, logs, fixtures, screenshots, and error messages.
- Validate file-operation paths as normalized absolute paths without traversal or control characters. Remember that validation is not a sandbox: CasaOS service and host permissions remain authoritative across the full server filesystem.
- Require explicit user action for app status, file mutation, power, SSH, and drive-health requests.
- Do not add polling for `/v1/disks`. Individual-drive health loads once on entry and refreshes only when the user asks.
- Do not invent SMART attributes or RAID metadata CasaOS does not provide.
- Keep fan detection read-only, preserve owner-managed fan files and boot settings, and do not add package-manager or network-install commands to fan setup.
- Keep fan mutations explicitly confirmed and bounded. Managed configuration changes must preserve the two-phase reboot or full-shutdown workflow, and the app must never initiate a fan-related reboot or shutdown.
- Preserve the dashboard's active-only 10-second soft refresh unless the product behavior is deliberately changed and tested.

New behavior needs tests at the contract or policy boundary. Prefer deterministic URL fixtures and `MockCasaOSClient` over network-dependent tests.

## Testing

Run the complete test suite on the CI destination before requesting review:

```sh
xcodebuild \
  -project CasaNative.xcodeproj \
  -scheme CasaNative \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -derivedDataPath .testbuild \
  -resultBundlePath .testbuild/CasaNative.xcresult \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test
```

For UI changes, install the newest build on that simulator and inspect both Light and Dark appearances at practical Dynamic Type sizes. Screenshots committed to documentation must use mock mode and must not expose a live hostname, username, token, IP address, drive serial number, file name, or app-specific private data.

## Live CasaOS policy

Automated tests must never contact a live CasaOS server. Manual development validation against a personally controlled server is read-only by default: connection, login, dashboard, storage, app listing/opening, and file listing/download.

Do not run live SSH, request `/v1/disks` during automated validation, change apps or files, change fan state or configuration, or send power commands. A server owner may manually test state-changing actions with disposable data, verified fan wiring and fallback cooling where applicable, and acceptable downtime, but those actions are not part of routine contribution validation.

Never commit a packet capture, server response, `.xcresult`, crash report, terminal transcript, or screenshot until it has been checked for secrets and identifying data.

## Dependency changes

Explain why a dependency is necessary and why an existing Apple framework or current package cannot meet the requirement. Keep package requirements narrow, regenerate the committed lockfile intentionally, update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and verify the new license is compatible with distribution. Do not commit SwiftPM checkouts or caches.

## Pull requests

A focused pull request should include:

- A concise problem and solution description.
- User-visible behavior changes and known limitations.
- Tests added or updated and the exact result.
- Security, privacy, API, and migration implications.
- Sanitized screenshots for material UI changes.
- An updated [CHANGELOG.md](CHANGELOG.md) entry when users or integrators would notice the change.

Keep unrelated cleanup separate. Do not rewrite shared history or include generated build products.

## Licensing of contributions

Casa Native is licensed under the MIT License. By submitting a contribution, you confirm that you have the right to submit it and agree that it may be distributed under the project's [MIT License](LICENSE).

Third-party components remain governed by their own licenses. CasaOS and related names, logos, and marks belong to their respective owners. This project is not affiliated with or endorsed by IceWhale Technology Ltd. (IceWhaleTech).
