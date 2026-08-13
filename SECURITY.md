# Security Policy

Casa Native controls sensitive CasaOS sessions and can perform destructive operations when explicitly instructed by its user. Please report vulnerabilities privately and include enough detail for a safe, reproducible investigation.

## Supported versions

| Version | Security fixes |
| --- | --- |
| Current `main` branch | Yes |
| Most recent tagged release, after releases begin | Yes |
| Older tags, forks, and modified builds | No guaranteed support |

Until the first tagged release, `main` is the only supported version. A fix may land on `main` before a replacement release is available.

## Reporting a vulnerability

Use the repository's **Security → Report a vulnerability** form when GitHub private vulnerability reporting is enabled. Do not place credentials, tokens, private hostnames, drive serial numbers, exploit code, or unredacted server responses in a public issue.

If private vulnerability reporting is unavailable, open a public issue containing only a request for a private contact channel. Do not include vulnerability details until a maintainer provides one.

Please include:

- The affected commit or release tag and iOS version.
- Whether the issue occurs with mock fixtures or a live CasaOS server.
- Preconditions, impact, and the smallest reproducible sequence.
- Redacted logs or screenshots, if useful.
- A suggested fix or regression test, if known.

No response or remediation deadline is promised. Please allow maintainers time to reproduce, assess, and coordinate a fix before public disclosure.

## Important security boundaries

Reports are especially useful when they involve:

- Exposure, mis-scoping, or persistence of CasaOS tokens or SSH credentials.
- Keychain accessibility or server-origin isolation failures.
- TLS validation bypass or endpoint-normalization confusion.
- SSH host-key pinning bypass, changed-key acceptance, or terminal data persistence.
- A direct SMART command that runs automatically, omits the standby guard before explicit wake confirmation, targets more than the exact displayed physical drive path, bypasses host-key verification, exposes an SSH password, or offers wake after a failed preflight.
- A PWM fan write before explicit confirmation, a write during read-only detection, owner-managed configuration replacement, unsafe GPIO/duty/temperature-policy input, mutation during a pending or unverified state, SSH password exposure through a command or log, or an unbounded fan-control command.
- Path traversal, control-character handling, path-normalization bypass, or an operation targeting a different absolute path than the user selected.
- A state-changing CasaOS request that occurs without clear user intent and confirmation.
- Sensitive data in logs, screenshots, crash reports, release artifacts, or tests.
- Malformed or hostile CasaOS responses that cause memory-safety, availability, or authorization problems.

Casa Native's threat boundary does not include a fully compromised or jailbroken iPhone, an attacker who already controls an unlocked device, a compromised CasaOS host, or an attacker-controlled third-party app opened in the in-app browser. Those conditions can invalidate platform and server security assumptions. They may still reveal defense-in-depth improvements worth reporting.

## Operational guidance

- Prefer HTTPS, a trusted LAN, or a private Tailscale route. Plain HTTP exposes credentials and session traffic to network interception.
- Verify a first-use SSH fingerprint through a trusted channel. Treat an unexpected changed-key warning as a potential attack until proven otherwise.
- Treat direct SMART as privileged physical-drive access. It runs only after an individual-drive button is pressed. The first check must retain smartctl's `-n standby` guard; if the drive is sleeping or its state is unknown, verify the exact displayed name and `/dev` path before confirming the separate wake read. Spin-up can interrupt an automated sleep period. Casa Native never starts a SMART self-test or changes drive settings.
- USB SMART passthrough depends on the enclosure or bridge. If smartctl requests an explicit device type, do not guess one: verify the hardware and smartctl documentation independently. An incorrect type can address a device differently than intended.
- Fresh installations default to CasaOS sign-in reuse: after a successful login, the same username and password are retained in a device-only Keychain item for SSH. Use Separate sign-in when the Linux account has different credentials or when distinct passwords are preferred. Existing installations continue to honor their saved mode. Changing modes does not clear either saved credential entry, but disconnecting and forgetting the server clears both.
- Keep the iPhone passcode-protected, current, and out of Developer Mode when development access is no longer needed.
- Verify release checksums and re-sign unsigned artifacts with your own trusted tooling and Apple account.
- Treat Files as a full server filesystem client, not a sandbox. Casa Native validates absolute paths but adds no `/DATA` mutation boundary. Requests require a signed-in CasaOS session; CasaOS service and host permissions determine backend access, and stock handlers may execute with daemon privileges rather than per-account filesystem ACLs. A privileged backend may modify or permanently delete system files; inspect the current path and every destructive confirmation.
- Treat PWM fan setup as privileged server administration. Confirm the GPIO against the physical wiring, use suitable fan-driving hardware, and keep another way to cool or recover the Raspberry Pi. A GPIO cannot power a fan motor. Automatic control requires a GPIO-safe active-high interface where low is off and high is full output. A 3-wire fan's third lead is tachometer output, not speed control; a 4-wire PWM input needs a level-safe, open-drain interface. A 0% duty cycle can overheat the server. Casa Native cannot verify the circuit or the fan's electrical limits.
- Treat automatic status as controller demand, not evidence of fan motion. Casa Native has no tachometer input and does not measure or estimate RPM. Kernel `gpio-fan` provides off/full demand, not a variable-speed curve.
- Fan detection must remain read-only. Owner-managed scripts, services, and boot settings are outside Casa Native's ownership and must not be rewritten. External `gpio-fan` is read-only, while any compatible pigpio/sysfs manual override is runtime-only and may reset after reboot or service restart.
- App-managed setup and changes are transactions. Mode and temperature-policy changes require a manual reboot; pin transitions require a full shutdown, disconnected power, and wire movement only while unpowered. A pending target must keep normal controls unavailable until cancel, finalize, rollback, or uninstall recovery completes. An unknown mutation result must quarantine further writes until re-detection.
- Only the exact verified legacy `fan50` layout is eligible for conversion. Its backup must remain available until explicit restore or discard. Similar, ambiguous, or otherwise owner-managed layouts must not be converted.
- Casa Native does not install server packages and never initiates a fan-related reboot or shutdown. The operator remains responsible for server tooling, permissions, GPIO resource conflicts, physical wiring, and safe cooling.
- Confirmed setup and privileged fan changes may present the saved SSH password to `sudo` through standard input in the encrypted SSH session when passwordless sudo is unavailable. Unprivileged pigpio duty changes do not. The password must never appear in the command, output, diagnostics, or logs. Host sudo policy remains authoritative.

## Safe validation

Automated security tests must use mocks or fixtures. They must not call a live server's `/v1/disks`, run live SSH or smartctl, wake a drive, alter apps or files, change fan state or configuration, or send restart or shutdown commands. Any authorized live-server investigation should begin with read-only requests and use a server owned by the tester. A separately authorized direct-SMART check must identify one physical path and begin with the standby-safe preflight; a wake read requires the owner's explicit acceptance of spin-up.

## Project status and trademarks

No external security audit is claimed. Keychain `WhenUnlockedThisDeviceOnly` protection reduces exposure but does not make secrets impossible to extract from a compromised or already-unlocked device.

Casa Native is unofficial and is not affiliated with IceWhale Technology Ltd. (IceWhaleTech). CasaOS and related names, logos, and marks belong to their respective owners.
