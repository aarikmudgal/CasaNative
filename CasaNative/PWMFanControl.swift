import Foundation

enum PWMFanGPIOPin: Int, CaseIterable, Identifiable, Sendable {
    case gpio12 = 12
    case gpio13 = 13
    case gpio18 = 18
    case gpio19 = 19

    var id: Int { rawValue }

    var function: Int {
        switch self {
        case .gpio12, .gpio13: 4
        case .gpio18, .gpio19: 2
        }
    }

    var channel: Int {
        switch self {
        case .gpio12, .gpio18: 0
        case .gpio13, .gpio19: 1
        }
    }

    var physicalHeaderPin: Int {
        switch self {
        case .gpio12: 32
        case .gpio13: 33
        case .gpio18: 12
        case .gpio19: 35
        }
    }

    var title: String {
        "GPIO \(rawValue) · header pin \(physicalHeaderPin)"
    }
}

enum PWMFanBackend: String, Equatable, Sendable {
    case pigpio
    case sysfs
    case gpioFan

    var title: String {
        switch self {
        case .pigpio: "pigpio hardware PWM"
        case .sysfs: "Linux PWM"
        case .gpioFan: "Automatic GPIO fan"
        }
    }
}

enum PWMFanOwnership: String, Equatable, Sendable {
    case absent
    case external
    case managed
    case conflict
}

enum PWMFanControlMode: String, Equatable, Sendable {
    case manual
    case automatic
}

struct PWMFanManualConfiguration: Equatable, Sendable {
    let pin: PWMFanGPIOPin
    let dutyPercent: Int

    init(pin: PWMFanGPIOPin, dutyPercent: Int) throws {
        guard (0...100).contains(dutyPercent) else {
            throw PWMFanError.invalidDutyPercent
        }
        self.pin = pin
        self.dutyPercent = dutyPercent
    }

    static func defaultConfiguration(
        pin: PWMFanGPIOPin
    ) -> PWMFanManualConfiguration {
        try! PWMFanManualConfiguration(pin: pin, dutyPercent: 50)
    }
}

struct PWMFanAutomaticConfiguration: Equatable, Sendable {
    let pin: PWMFanGPIOPin
    let turnOnCelsius: Int
    let hysteresisCelsius: Int

    var turnOffCelsius: Int { turnOnCelsius - hysteresisCelsius }

    init(
        pin: PWMFanGPIOPin,
        turnOnCelsius: Int,
        hysteresisCelsius: Int
    ) throws {
        guard (40...75).contains(turnOnCelsius),
              (5...15).contains(hysteresisCelsius),
              turnOnCelsius - hysteresisCelsius >= 30 else {
            throw PWMFanError.invalidAutomaticPolicy
        }
        self.pin = pin
        self.turnOnCelsius = turnOnCelsius
        self.hysteresisCelsius = hysteresisCelsius
    }

    static func defaultConfiguration(
        pin: PWMFanGPIOPin
    ) -> PWMFanAutomaticConfiguration {
        try! PWMFanAutomaticConfiguration(
            pin: pin,
            turnOnCelsius: 55,
            hysteresisCelsius: 10
        )
    }
}

enum PWMFanConfiguration: Equatable, Sendable {
    case manual(PWMFanManualConfiguration)
    case automatic(PWMFanAutomaticConfiguration)

    var pin: PWMFanGPIOPin {
        switch self {
        case let .manual(value): value.pin
        case let .automatic(value): value.pin
        }
    }

    var mode: PWMFanControlMode {
        switch self {
        case .manual: .manual
        case .automatic: .automatic
        }
    }

    var dutyPercent: Int? {
        guard case let .manual(value) = self else { return nil }
        return value.dutyPercent
    }

    var turnOnCelsius: Int? {
        guard case let .automatic(value) = self else { return nil }
        return value.turnOnCelsius
    }

    var hysteresisCelsius: Int? {
        guard case let .automatic(value) = self else { return nil }
        return value.hysteresisCelsius
    }
}

enum PWMFanAutomaticDemand: String, Equatable, Sendable {
    case off
    case full
    case unknown
}

enum PWMFanTransitionPhase: String, Equatable, Sendable {
    case prepared
    case bootedAwaitingConfirmation
}

enum PWMFanTransitionRequirement: String, Equatable, Sendable {
    case reboot
    case fullShutdown
}

enum PWMFanTransitionKind: String, Equatable, Sendable {
    case configurationChange
    case rollback
    case uninstall
}

enum PWMFanTransitionTarget: Equatable, Sendable {
    case configuration(PWMFanConfiguration)
    case uninstalled

    var configuration: PWMFanConfiguration? {
        guard case let .configuration(value) = self else { return nil }
        return value
    }

    var isUninstall: Bool {
        if case .uninstalled = self { true } else { false }
    }
}

struct PWMFanTransitionState: Equatable, Sendable {
    let source: PWMFanConfiguration?
    let target: PWMFanTransitionTarget
    let phase: PWMFanTransitionPhase
    let requirement: PWMFanTransitionRequirement
    let kind: PWMFanTransitionKind

    var pendingConfiguration: PWMFanConfiguration? {
        target.configuration
    }

    var isPendingUninstall: Bool { target.isUninstall }
}

enum PWMFanLegacyState: String, Equatable, Sendable {
    case none
    case exactConvertible
    case backupAwaitingResolution
}

enum PWMFanLegacyBackupResolution: String, Equatable, Sendable {
    case restore
    case discard
}

enum PWMFanRecoveryAction: String, Equatable, Sendable {
    case cancelPreparedChange
    case completeRollbackPreparation
    case finalizePreparedChange
    case completeUninstall
    case completeLegacyConversion
    case completeLegacyRestore
    case completeLegacyDiscard
    case completeManagedApply
    case completeStateCleanup
}

enum PWMFanVerification: Equatable, Sendable {
    case verified
    case changedButUnverified
}

struct PWMFanStatus: Equatable, Sendable {
    let ownership: PWMFanOwnership
    let backend: PWMFanBackend?
    let pin: PWMFanGPIOPin?
    let periodNanoseconds: Int?
    let dutyPercent: Int?
    let isEnabled: Bool?
    let isRuntimeAvailable: Bool
    let requiresReboot: Bool
    let canRestoreAutomatic: Bool
    let detail: String
    var verification: PWMFanVerification = .verified
    var activeConfiguration: PWMFanConfiguration? = nil
    var transition: PWMFanTransitionState? = nil
    var automaticDemand: PWMFanAutomaticDemand? = nil
    var automaticRestoreConfiguration: PWMFanAutomaticConfiguration? = nil
    var legacyState: PWMFanLegacyState = .none
    var recoveryRequired: Bool = false
    var manualControlAvailable: Bool = true
    var automaticControlAvailable: Bool = true
    var recoveryAction: PWMFanRecoveryAction? = nil

    var pendingConfiguration: PWMFanConfiguration? {
        transition?.pendingConfiguration
    }

    static let demo = PWMFanStatus(
        ownership: .external,
        backend: .pigpio,
        pin: .gpio18,
        periodNanoseconds: 40_000,
        dutyPercent: 50,
        isEnabled: true,
        isRuntimeAvailable: true,
        requiresReboot: false,
        canRestoreAutomatic: true,
        detail: "Demo PWM fan is running at 25 kHz."
    )
}

protocol PWMFanControlling: Sendable {
    func detect() async throws -> PWMFanStatus
    func provision(configuration: PWMFanConfiguration) async throws -> PWMFanStatus
    func provision(
        pin: PWMFanGPIOPin,
        initialDutyPercent: Int
    ) async throws -> PWMFanStatus
    func prepareConfigurationChange(
        to configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus
    func cancelPreparedChange() async throws -> PWMFanStatus
    func finalizePreparedChange() async throws -> PWMFanStatus
    func prepareRollback() async throws -> PWMFanStatus
    func uninstallManaged() async throws -> PWMFanStatus
    func convertExactLegacyFan50() async throws -> PWMFanStatus
    func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) async throws -> PWMFanStatus
    func completeManagedApply() async throws -> PWMFanStatus
    func completeStateCleanup() async throws -> PWMFanStatus
    func apply(dutyPercent: Int, persist: Bool) async throws -> PWMFanStatus
    func restoreAutomatic() async throws -> PWMFanStatus
}

enum PWMFanError: LocalizedError, Equatable, Sendable {
    case missingCredentials
    case invalidDutyPercent
    case invalidAutomaticPolicy
    case invalidTransition(String)
    case recoveryRequired
    case unsupportedCapability(String)
    case legacyConversionUnavailable
    case legacyBackupResolutionRequired
    case invalidPrivilegedPassword
    case detectionFailed(String)
    case conflict(String)
    case setupAlreadyExists
    case runtimeUnavailable(String)
    case persistenceNotOwned
    case automaticControlUnavailable
    case sudoAuthenticationFailed
    case commandFailed(String)
    case commandTimedOut
    case outputLimitExceeded
    case invalidCommandResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "No SSH credentials are saved for this server."
        case .invalidDutyPercent:
            "Fan speed must be between 0% and 100%."
        case .invalidAutomaticPolicy:
            "Automatic control requires 40–75 °C on, 5–15 °C hysteresis, and an off threshold of at least 30 °C."
        case let .invalidTransition(detail):
            "The fan configuration change is not valid in the current phase. \(detail)"
        case .recoveryRequired:
            "Fan state is unverified. Detect and complete the available recovery before changing it again."
        case let .unsupportedCapability(detail):
            "This server cannot use the selected fan mode. \(detail)"
        case .legacyConversionUnavailable:
            "Only the exact verified GPIO18 fan50 setup can be converted."
        case .legacyBackupResolutionRequired:
            "Restore or discard the legacy backup before preparing another pin change."
        case .invalidPrivilegedPassword:
            "The saved SSH password cannot be used safely with sudo. Save a password without line breaks."
        case let .detectionFailed(detail):
            "Fan detection failed. \(detail)"
        case let .conflict(detail):
            "Fan control stopped because the server configuration is ambiguous. \(detail)"
        case .setupAlreadyExists:
            "A fan configuration already exists. Casa Native did not replace it."
        case let .runtimeUnavailable(detail):
            "PWM fan control is not available at runtime. \(detail)"
        case .persistenceNotOwned:
            "Casa Native will not rewrite another fan setup. This speed can only be applied for the current runtime."
        case .automaticControlUnavailable:
            "An automatic gpio-fan configuration was not verified, so it was not restored."
        case .sudoAuthenticationFailed:
            "sudo did not accept the saved SSH password or this account is not allowed to administer the server."
        case let .commandFailed(detail):
            "The server rejected the fan command. \(detail)"
        case .commandTimedOut:
            "The fan command timed out. The resulting server state is unknown; detect again before sending another change."
        case .outputLimitExceeded:
            "The server returned more command output than Casa Native accepts."
        case .invalidCommandResponse:
            "The server returned an invalid fan-control response."
        }
    }
}

struct SSHCommandRequest: Equatable, Sendable {
    let command: String
    let standardInput: Data
    let timeoutSeconds: Int
    let maximumOutputBytes: Int

    init(
        command: String,
        standardInput: Data = Data(),
        timeoutSeconds: Int = 12,
        maximumOutputBytes: Int = 64 * 1_024
    ) {
        self.command = command
        self.standardInput = standardInput
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

struct SSHCommandResult: Equatable, Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitStatus: Int

    var outputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var sanitizedError: String {
        Self.sanitize(String(decoding: standardError, as: UTF8.self))
    }

    private static func sanitize(_ value: String) -> String {
        let allowedControls = CharacterSet(charactersIn: "\n\t")
        let controls = CharacterSet.controlCharacters
        let scalars = value.unicodeScalars.filter {
            !controls.contains($0) || allowedControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(512)
            .description
    }
}

protocol SSHCommandExecuting: Sendable {
    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult
}

struct NIOSSHCommandExecutor: SSHCommandExecuting, Sendable {
    private let host: SSHHostIdentity
    private let hostKeyStore: any SSHPinnedHostKeyStoring
    private let hostKeyConfirmation: SSHHostKeyVerifier.Confirmation

    init(
        serverURL: URL,
        port: Int = 22,
        hostKeyStore: any SSHPinnedHostKeyStoring = SSHHostKeyStore(),
        hostKeyConfirmation: @escaping SSHHostKeyVerifier.Confirmation
    ) throws {
        host = try SSHHostIdentity(serverURL: serverURL, port: port)
        self.hostKeyStore = hostKeyStore
        self.hostKeyConfirmation = hostKeyConfirmation
    }

    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult {
        let verifier = SSHHostKeyPinningDelegate(
            host: host,
            store: hostKeyStore,
            confirmation: hostKeyConfirmation
        )

        // Host-key confirmation is a user decision and must not race a command
        // deadline. SSHClient bounds each child command after it is created.
        let client = try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            credentials: credentials,
            serverAuthDelegate: verifier,
            connectTimeout: .seconds(10)
        )
        defer { Task { try? await client.close() } }

        return try await client.execute(request)
    }
}

actor SSHPWMFanController: PWMFanControlling {
    private let serverURL: URL
    private let credentialMode: SSHCredentialMode
    private let credentialStore: any SSHCredentialStoring
    private let executor: any SSHCommandExecuting

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        hostKeyStore: any SSHPinnedHostKeyStoring = SSHHostKeyStore(),
        hostKeyConfirmation: @escaping SSHHostKeyVerifier.Confirmation
    ) {
        self.serverURL = serverURL
        self.credentialMode = credentialMode
        self.credentialStore = credentialStore
        do {
            executor = try NIOSSHCommandExecutor(
                serverURL: serverURL,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmation: hostKeyConfirmation
            )
        } catch {
            executor = FailingSSHCommandExecutor(error: error)
        }
    }

    init(
        serverURL: URL,
        credentialMode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring,
        executor: any SSHCommandExecuting
    ) {
        self.serverURL = serverURL
        self.credentialMode = credentialMode
        self.credentialStore = credentialStore
        self.executor = executor
    }

    func detect() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        return try await detect(credentials: credentials)
    }

    func provision(
        configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        try Self.requireMutable(current)
        try Self.requireCapability(configuration, status: current)
        guard current.ownership == .absent else {
            if current.ownership == .conflict {
                throw PWMFanError.conflict(current.detail)
            }
            throw PWMFanError.setupAlreadyExists
        }

        let requirement: PWMFanTransitionRequirement = .reboot
        guard try await runPrivileged(
            script: PWMFanScripts.provision(
                configuration: configuration,
                requirement: requirement
            ),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(
                from: current,
                backend: Self.backend(for: configuration),
                pin: nil,
                dutyPercent: nil,
                operation: "Setup"
            )
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            backend: Self.backend(for: configuration),
            pin: nil,
            dutyPercent: nil,
            operation: "Setup"
        )
    }

    func provision(
        pin: PWMFanGPIOPin,
        initialDutyPercent: Int
    ) async throws -> PWMFanStatus {
        try await provision(
            configuration: .manual(
                try PWMFanManualConfiguration(
                    pin: pin,
                    dutyPercent: initialDutyPercent
                )
            )
        )
    }

    func prepareConfigurationChange(
        to configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        try Self.requireMutable(current)
        try Self.requireCapability(configuration, status: current)
        guard current.ownership == .managed,
              current.transition == nil,
              let source = current.activeConfiguration else {
            throw PWMFanError.invalidTransition(
                "A stable app-managed configuration is required."
            )
        }
        if current.legacyState == .backupAwaitingResolution,
           source.pin != configuration.pin {
            throw PWMFanError.legacyBackupResolutionRequired
        }
        try Self.validateOneAxisChange(from: source, to: configuration)
        let requirement: PWMFanTransitionRequirement =
            source.pin == configuration.pin ? .reboot : .fullShutdown

        guard try await runPrivileged(
            script: PWMFanScripts.prepareConfigurationChange(
                source: source,
                target: configuration,
                requirement: requirement,
                kind: .configurationChange
            ),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(
                from: current,
                backend: current.backend,
                pin: current.pin,
                dutyPercent: current.dutyPercent,
                operation: "Configuration preparation"
            )
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            backend: current.backend,
            pin: current.pin,
            dutyPercent: current.dutyPercent,
            operation: "Configuration preparation"
        )
    }

    func cancelPreparedChange() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        guard let transition = current.transition,
              transition.phase == .prepared,
              !current.recoveryRequired
                || current.recoveryAction == .cancelPreparedChange else {
            throw PWMFanError.invalidTransition(
                "Only a change prepared in the current boot can be cancelled."
            )
        }
        guard try await runPrivileged(
            script: PWMFanScripts.cancelPreparedChange(transition: transition),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(from: current, operation: "Cancellation")
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Cancellation"
        )
    }

    func finalizePreparedChange() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        guard let transition = current.transition,
              transition.phase == .bootedAwaitingConfirmation,
              !current.recoveryRequired
                || current.recoveryAction == .finalizePreparedChange
                || current.recoveryAction == .completeUninstall else {
            throw PWMFanError.invalidTransition(
                "Finalize is available only after booting the prepared target."
            )
        }
        guard try await runPrivileged(
            script: PWMFanScripts.finalizePreparedChange(transition: transition),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(from: current, operation: "Finalization")
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Finalization"
        )
    }

    func prepareRollback() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        if current.recoveryAction == .completeRollbackPreparation {
            guard let transition = current.transition,
                  transition.phase == .prepared,
                  transition.kind == .rollback,
                  transition.source != nil
                    || transition.target.configuration != nil else {
                throw PWMFanError.invalidTransition(
                    "Rollback-recovery metadata is incomplete."
                )
            }
            guard try await runPrivileged(
                script: PWMFanScripts.completeRollbackPreparation(
                    transition: transition
                ),
                credentials: credentials
            ) == .succeeded else {
                return changedButUnverified(
                    from: current,
                    operation: "Rollback preparation recovery"
                )
            }
            return await refreshAfterMutation(
                credentials: credentials,
                fallback: current,
                operation: "Rollback preparation recovery"
            )
        }
        guard let transition = current.transition,
              transition.phase == .bootedAwaitingConfirmation,
              transition.kind != .rollback,
              transition.source != nil
                || transition.target.configuration != nil else {
            throw PWMFanError.invalidTransition(
                "Rollback requires a booted managed target and cannot be prepared twice."
            )
        }
        if let source = transition.source {
            try Self.requireCapability(source, status: current)
        }
        guard try await runPrivileged(
            script: PWMFanScripts.prepareRollback(transition: transition),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(from: current, operation: "Rollback preparation")
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Rollback preparation"
        )
    }

    func uninstallManaged() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        if let transition = current.transition {
            guard transition.kind == .uninstall,
                  transition.phase == .bootedAwaitingConfirmation,
                  !current.recoveryRequired
                    || current.recoveryAction == .completeUninstall else {
                throw PWMFanError.invalidTransition(
                    "Complete or cancel the existing transition first."
                )
            }
            guard try await runPrivileged(
                script: PWMFanScripts.finalizePreparedChange(
                    transition: transition
                ),
                credentials: credentials
            ) == .succeeded else {
                return changedButUnverified(from: current, operation: "Uninstall finalization")
            }
        } else {
            try Self.requireMutable(current)
            guard current.ownership == .managed,
                  let source = current.activeConfiguration else {
                throw PWMFanError.invalidTransition(
                    "Only a stable app-managed setup can be uninstalled."
                )
            }
            guard current.legacyState != .backupAwaitingResolution else {
                throw PWMFanError.legacyBackupResolutionRequired
            }
            guard try await runPrivileged(
                script: PWMFanScripts.prepareUninstall(source: source),
                credentials: credentials
            ) == .succeeded else {
                return changedButUnverified(from: current, operation: "Uninstall preparation")
            }
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Uninstall"
        )
    }

    func convertExactLegacyFan50() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        if current.recoveryAction != .completeLegacyConversion {
            try Self.requireMutable(current)
        }
        guard current.recoveryAction == .completeLegacyConversion
                || (current.legacyState == .exactConvertible
                    && current.ownership == .external
                    && current.pin == .gpio18
                    && current.backend == .sysfs) else {
            throw PWMFanError.legacyConversionUnavailable
        }
        guard try await runPrivileged(
            script: PWMFanScripts.convertExactLegacyFan50(),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(from: current, operation: "Legacy conversion")
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Legacy conversion"
        )
    }

    func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        let matchingRecovery = resolution == .restore
            ? current.recoveryAction == .completeLegacyRestore
            : current.recoveryAction == .completeLegacyDiscard
        guard matchingRecovery
                || (current.legacyState == .backupAwaitingResolution
                    && current.transition == nil) else {
            throw PWMFanError.invalidTransition(
                "No stable converted legacy backup is awaiting resolution."
            )
        }
        guard try await runPrivileged(
            script: PWMFanScripts.resolveLegacyBackup(resolution),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(from: current, operation: "Legacy backup resolution")
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Legacy backup resolution"
        )
    }

    func completeManagedApply() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        guard current.recoveryAction == .completeManagedApply,
              let transition = current.transition,
              case let .manual(source)? = transition.source,
              case let .manual(target)? = transition.target.configuration,
              source.pin == target.pin else {
            throw PWMFanError.invalidTransition(
                "No journaled manual speed update can be completed."
            )
        }
        guard try await runPrivileged(
            script: PWMFanScripts.managedLifecycleApply(
                source: source,
                dutyPercent: target.dutyPercent,
                persist: true,
                resume: true
            ),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(
                from: current,
                operation: "Persistent speed recovery"
            )
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "Persistent speed recovery"
        )
    }

    func completeStateCleanup() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        guard current.recoveryAction == .completeStateCleanup else {
            throw PWMFanError.invalidTransition(
                "No retired managed state is awaiting cleanup."
            )
        }
        guard try await runPrivileged(
            script: PWMFanScripts.completeStateCleanup(),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(
                from: current,
                operation: "State cleanup recovery"
            )
        }
        return await refreshAfterMutation(
            credentials: credentials,
            fallback: current,
            operation: "State cleanup recovery"
        )
    }

    func apply(dutyPercent: Int, persist: Bool) async throws -> PWMFanStatus {
        try Self.validate(dutyPercent: dutyPercent)
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        let resumingManagedApply = current.recoveryAction == .completeManagedApply
        if !resumingManagedApply { try Self.requireMutable(current) }
        guard current.transition == nil || resumingManagedApply else {
            throw PWMFanError.invalidTransition(
                "Manual speed cannot change during a prepared transition."
            )
        }
        var managedManual: PWMFanManualConfiguration?
        if resumingManagedApply {
            guard persist,
                  let transition = current.transition,
                  case let .manual(configuration)? = transition.source,
                  case let .manual(target)? = transition.target.configuration,
                  target.pin == configuration.pin,
                  target.dutyPercent == dutyPercent else {
                throw PWMFanError.invalidTransition(
                    "Only the journaled persistent speed can be completed."
                )
            }
            managedManual = configuration
        } else if current.ownership == .managed {
            guard persist else {
                throw PWMFanError.invalidTransition(
                    "App-managed manual speed changes must update runtime and the owned default atomically."
                )
            }
            guard case let .manual(configuration) = current.activeConfiguration else {
                throw PWMFanError.runtimeUnavailable(
                    "Automatic gpio-fan control is off/full and has no manual duty setting."
                )
            }
            managedManual = configuration
        }

        guard current.ownership != .conflict || resumingManagedApply else {
            throw PWMFanError.conflict(current.detail)
        }
        let resolvedBackend = resumingManagedApply ? PWMFanBackend.sysfs : current.backend
        let resolvedPin = resumingManagedApply ? managedManual?.pin : current.pin
        guard let backend = resolvedBackend, let pin = resolvedPin else {
            throw PWMFanError.runtimeUnavailable(current.detail)
        }

        switch backend {
        case .pigpio:
            guard current.ownership == .external else {
                throw PWMFanError.conflict("Unexpected pigpio ownership.")
            }
            guard !persist else { throw PWMFanError.persistenceNotOwned }
            guard await runUnprivilegedMutation(
                PWMFanScripts.pigpioApply(
                    pin: pin,
                    dutyPercent: dutyPercent
                ),
                credentials: credentials
            ) == .succeeded else {
                return changedButUnverified(
                    backend: backend,
                    pin: pin,
                    dutyPercent: dutyPercent,
                    requiresReboot: false,
                    operation: "Speed change"
                )
            }

        case .sysfs:
            guard current.isRuntimeAvailable else {
                throw PWMFanError.runtimeUnavailable(current.detail)
            }
            if current.ownership == .managed || resumingManagedApply {
                guard let managedManual else {
                    throw PWMFanError.runtimeUnavailable(current.detail)
                }
                guard try await runPrivileged(
                    script: PWMFanScripts.managedLifecycleApply(
                        source: managedManual,
                        dutyPercent: dutyPercent,
                        persist: persist,
                        resume: resumingManagedApply
                    ),
                    credentials: credentials
                ) == .succeeded else {
                    return changedButUnverified(
                        backend: backend,
                        pin: pin,
                        dutyPercent: dutyPercent,
                        requiresReboot: false,
                        operation: "Speed change"
                    )
                }
            } else {
                guard !persist else { throw PWMFanError.persistenceNotOwned }
                guard try await runPrivileged(
                    script: PWMFanScripts.externalSysfsApply(
                        pin: pin,
                        dutyPercent: dutyPercent
                    ),
                    credentials: credentials
                ) == .succeeded else {
                    return changedButUnverified(
                        backend: backend,
                        pin: pin,
                        dutyPercent: dutyPercent,
                        requiresReboot: false,
                        operation: "Speed change"
                    )
                }
            }
        case .gpioFan:
            throw PWMFanError.runtimeUnavailable(
                "Automatic gpio-fan control does not accept a manual duty percentage."
            )
        }

        do {
            let status = try await detect(credentials: credentials)
            guard
                status.backend == backend,
                status.pin == pin,
                status.dutyPercent == dutyPercent
            else {
                return changedButUnverified(
                    backend: backend,
                    pin: pin,
                    dutyPercent: dutyPercent,
                    requiresReboot: false,
                    operation: "Speed change"
                )
            }
            return status
        } catch {
            return changedButUnverified(
                backend: backend,
                pin: pin,
                dutyPercent: dutyPercent,
                requiresReboot: false,
                operation: "Speed change"
            )
        }
    }

    func restoreAutomatic() async throws -> PWMFanStatus {
        let credentials = try await loadCredentials()
        let current = try await detect(credentials: credentials)
        guard
            current.ownership == .external,
            current.backend == .pigpio,
            current.canRestoreAutomatic,
            let pin = current.pin,
            let automatic = current.automaticRestoreConfiguration,
            automatic.pin == pin
        else {
            throw PWMFanError.automaticControlUnavailable
        }

        guard try await runPrivileged(
            script: PWMFanScripts.restoreAutomatic(configuration: automatic),
            credentials: credentials
        ) == .succeeded else {
            return changedButUnverified(
                backend: nil,
                pin: pin,
                dutyPercent: nil,
                requiresReboot: false,
                operation: "Automatic-control restore"
            )
        }
        do {
            let status = try await detect(credentials: credentials)
            guard
                status.ownership == .external,
                status.backend == .gpioFan,
                status.pin == pin,
                status.isRuntimeAvailable,
                status.activeConfiguration == .automatic(automatic),
                status.automaticDemand == .off
                    || status.automaticDemand == .full
            else {
                return changedButUnverified(
                    backend: nil,
                    pin: pin,
                    dutyPercent: nil,
                    requiresReboot: false,
                    operation: "Automatic-control restore"
                )
            }
            return status
        } catch {
            return changedButUnverified(
                backend: nil,
                pin: pin,
                dutyPercent: nil,
                requiresReboot: false,
                operation: "Automatic-control restore"
            )
        }
    }

    private func detect(
        credentials: SSHCredentials
    ) async throws -> PWMFanStatus {
        guard !credentials.password.contains("\n"),
              !credentials.password.contains("\r") else {
            throw PWMFanError.invalidPrivilegedPassword
        }
        let result: SSHCommandResult
        do {
            result = try await executor.execute(
                PWMFanScripts.privilegedReadOnlyDetection(
                    password: credentials.password
                ),
                credentials: credentials
            )
        } catch {
            throw PWMFanError.detectionFailed(
                "The read-only privileged status probe could not complete."
            )
        }
        guard result.exitStatus == 0 else {
            let detail = result.sanitizedError
            if detail.localizedCaseInsensitiveContains("password")
                || detail.localizedCaseInsensitiveContains("sudoers")
                || detail.localizedCaseInsensitiveContains("not allowed")
            {
                throw PWMFanError.sudoAuthenticationFailed
            }
            throw PWMFanError.detectionFailed(
                detail.isEmpty
                    ? "Read-only probe exited with status \(result.exitStatus)."
                    : detail
            )
        }
        return try PWMFanProbeParser.parse(result.outputString)
    }

    private func loadCredentials() async throws -> SSHCredentials {
        guard let credentials = try await credentialStore.load(
            mode: credentialMode,
            for: serverURL
        ) else {
            throw PWMFanError.missingCredentials
        }
        return credentials
    }

    private enum MutationOutcome: Equatable {
        case succeeded
        case outcomeUnknown
    }

    private func runPrivileged(
        script: String,
        credentials: SSHCredentials
    ) async throws -> MutationOutcome {
        let noPassword = try await executor.execute(
            PWMFanScripts.sudoNonInteractiveCheck,
            credentials: credentials
        )

        let request: SSHCommandRequest
        if noPassword.exitStatus == 0 {
            request = PWMFanScripts.privileged(
                script: script,
                password: nil
            )
        } else {
            guard
                !credentials.password.contains("\n"),
                !credentials.password.contains("\r")
            else {
                throw PWMFanError.invalidPrivilegedPassword
            }
            request = PWMFanScripts.privileged(
                script: script,
                password: credentials.password
            )
        }

        let result: SSHCommandResult
        do {
            result = try await executor.execute(
                request,
                credentials: credentials
            )
        } catch {
            return .outcomeUnknown
        }
        guard result.exitStatus == 0 else {
            let detail = result.sanitizedError
            if !Self.isRemoteTimeoutStatus(result.exitStatus)
                && (detail.localizedCaseInsensitiveContains("password")
                    || detail.localizedCaseInsensitiveContains("sudoers")
                    || detail.localizedCaseInsensitiveContains("not allowed"))
            {
                throw PWMFanError.sudoAuthenticationFailed
            }
            return .outcomeUnknown
        }
        return .succeeded
    }

    private static func validate(dutyPercent: Int) throws {
        guard (0...100).contains(dutyPercent) else {
            throw PWMFanError.invalidDutyPercent
        }
    }

    private static func requireMutable(_ status: PWMFanStatus) throws {
        guard !status.recoveryRequired,
              status.verification == .verified else {
            throw PWMFanError.recoveryRequired
        }
    }

    private static func backend(
        for configuration: PWMFanConfiguration
    ) -> PWMFanBackend {
        configuration.mode == .manual ? .sysfs : .gpioFan
    }

    private static func requireCapability(
        _ configuration: PWMFanConfiguration,
        status: PWMFanStatus
    ) throws {
        switch configuration.mode {
        case .manual:
            guard status.manualControlAvailable else {
                throw PWMFanError.unsupportedCapability(
                    "A compatible kernel PWM controller was not verified."
                )
            }
        case .automatic:
            guard status.automaticControlAvailable else {
                throw PWMFanError.unsupportedCapability(
                    "The stock gpio-fan overlay/module and a readable CPU thermal zone are required."
                )
            }
        }
    }

    private static func validateOneAxisChange(
        from source: PWMFanConfiguration,
        to target: PWMFanConfiguration
    ) throws {
        guard source != target else {
            throw PWMFanError.invalidTransition("The target is unchanged.")
        }
        if source.mode != target.mode {
            guard source.pin == target.pin else {
                throw PWMFanError.invalidTransition(
                    "Change mode first, then prepare the pin separately."
                )
            }
            return
        }
        if source.pin != target.pin {
            switch (source, target) {
            case let (.manual(old), .manual(new)):
                guard old.dutyPercent == new.dutyPercent else {
                    throw PWMFanError.invalidTransition(
                        "Apply the manual duty first, then prepare only the pin."
                    )
                }
            case let (.automatic(old), .automatic(new)):
                guard old.turnOnCelsius == new.turnOnCelsius,
                      old.hysteresisCelsius == new.hysteresisCelsius else {
                    throw PWMFanError.invalidTransition(
                        "Prepare the automatic policy and pin as separate changes."
                    )
                }
            default:
                throw PWMFanError.invalidTransition("Unsupported combined change.")
            }
            return
        }
        switch (source, target) {
        case (.automatic, .automatic):
            return
        case (.manual, .manual):
            throw PWMFanError.invalidTransition(
                "Manual duty changes use Apply and do not require a reboot."
            )
        default:
            throw PWMFanError.invalidTransition("Unsupported configuration change.")
        }
    }

    private func runUnprivilegedMutation(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async -> MutationOutcome {
        do {
            let result = try await executor.execute(
                request,
                credentials: credentials
            )
            return result.exitStatus == 0 ? .succeeded : .outcomeUnknown
        } catch {
            return .outcomeUnknown
        }
    }

    private static func isRemoteTimeoutStatus(_ status: Int) -> Bool {
        [124, 125, 126, 127, 137, 143].contains(status)
    }

    private func changedButUnverified(
        backend: PWMFanBackend?,
        pin: PWMFanGPIOPin,
        dutyPercent: Int?,
        requiresReboot: Bool,
        operation: String
    ) -> PWMFanStatus {
        PWMFanStatus(
            ownership: .conflict,
            backend: backend,
            pin: pin,
            periodNanoseconds: backend == .pigpio ? 40_000 : nil,
            dutyPercent: dutyPercent,
            isEnabled: dutyPercent.map { $0 > 0 },
            isRuntimeAvailable: false,
            requiresReboot: requiresReboot,
            canRestoreAutomatic: false,
            detail: "\(operation) may have reached the server, but the outcome is unknown. Detect again before sending another change.",
            verification: .changedButUnverified,
            recoveryRequired: true
        )
    }

    private func changedButUnverified(
        from status: PWMFanStatus,
        backend: PWMFanBackend? = nil,
        pin: PWMFanGPIOPin? = nil,
        dutyPercent: Int? = nil,
        operation: String
    ) -> PWMFanStatus {
        PWMFanStatus(
            ownership: .conflict,
            backend: backend ?? status.backend,
            pin: pin ?? status.pin,
            periodNanoseconds: status.periodNanoseconds,
            dutyPercent: dutyPercent ?? status.dutyPercent,
            isEnabled: status.isEnabled,
            isRuntimeAvailable: false,
            requiresReboot: status.requiresReboot,
            canRestoreAutomatic: false,
            detail: "\(operation) may have reached the server, but the outcome is unknown. Detect again and use only the offered recovery action.",
            verification: .changedButUnverified,
            activeConfiguration: status.activeConfiguration,
            transition: status.transition,
            automaticDemand: status.automaticDemand,
            automaticRestoreConfiguration: status.automaticRestoreConfiguration,
            legacyState: status.legacyState,
            recoveryRequired: true,
            recoveryAction: status.recoveryAction
        )
    }

    private func refreshAfterMutation(
        credentials: SSHCredentials,
        fallback: PWMFanStatus,
        backend: PWMFanBackend? = nil,
        pin: PWMFanGPIOPin? = nil,
        dutyPercent: Int? = nil,
        operation: String
    ) async -> PWMFanStatus {
        do {
            return try await detect(credentials: credentials)
        } catch {
            return changedButUnverified(
                from: fallback,
                backend: backend,
                pin: pin,
                dutyPercent: dutyPercent,
                operation: operation
            )
        }
    }
}

actor MockPWMFanController: PWMFanControlling {
    private var status: PWMFanStatus

    init(initialStatus: PWMFanStatus = .demo) {
        status = initialStatus
    }

    func detect() async throws -> PWMFanStatus { status }

    func provision(
        configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus {
        guard status.ownership == .absent,
              !status.recoveryRequired else {
            throw PWMFanError.setupAlreadyExists
        }
        status = pendingStatus(
            source: nil,
            target: .configuration(configuration),
            kind: .configurationChange
        )
        return status
    }

    func provision(
        pin: PWMFanGPIOPin,
        initialDutyPercent: Int
    ) async throws -> PWMFanStatus {
        try await provision(
            configuration: .manual(
                try PWMFanManualConfiguration(
                    pin: pin,
                    dutyPercent: initialDutyPercent
                )
            )
        )
    }

    func prepareConfigurationChange(
        to configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus {
        guard status.ownership == .managed,
              status.transition == nil,
              !status.recoveryRequired,
              let source = status.activeConfiguration else {
            throw PWMFanError.invalidTransition("Stable managed state required.")
        }
        status = pendingStatus(
            source: source,
            target: .configuration(configuration),
            kind: .configurationChange
        )
        return status
    }

    func cancelPreparedChange() async throws -> PWMFanStatus {
        guard let transition = status.transition,
              transition.phase == .prepared else {
            throw PWMFanError.invalidTransition("No prepared change exists.")
        }
        if let source = transition.source {
            status = stableStatus(configuration: source)
        } else {
            status = absentStatus()
        }
        return status
    }

    func finalizePreparedChange() async throws -> PWMFanStatus {
        guard let transition = status.transition,
              transition.phase == .bootedAwaitingConfirmation else {
            throw PWMFanError.invalidTransition("Target has not booted.")
        }
        if let target = transition.target.configuration {
            status = stableStatus(configuration: target)
        } else {
            status = absentStatus()
        }
        return status
    }

    func prepareRollback() async throws -> PWMFanStatus {
        if status.recoveryAction == .completeRollbackPreparation,
           let transition = status.transition,
           transition.kind == .rollback,
           transition.phase == .prepared {
            status = pendingStatus(
                source: transition.source,
                target: transition.target,
                kind: .rollback
            )
            return status
        }
        guard let transition = status.transition,
              transition.phase == .bootedAwaitingConfirmation,
              transition.kind != .rollback,
              transition.source != nil
                || transition.target.configuration != nil else {
            throw PWMFanError.invalidTransition("Rollback unavailable.")
        }
        status = pendingStatus(
            source: transition.target.configuration,
            target: transition.source.map { .configuration($0) }
                ?? .uninstalled,
            kind: .rollback
        )
        return status
    }

    func uninstallManaged() async throws -> PWMFanStatus {
        if let transition = status.transition,
           transition.kind == .uninstall,
           transition.phase == .bootedAwaitingConfirmation {
            status = absentStatus()
        } else if let source = status.activeConfiguration,
                  status.ownership == .managed,
                  status.transition == nil {
            status = pendingStatus(
                source: source,
                target: .uninstalled,
                kind: .uninstall
            )
        } else {
            throw PWMFanError.invalidTransition("Uninstall unavailable.")
        }
        return status
    }

    func convertExactLegacyFan50() async throws -> PWMFanStatus {
        guard status.legacyState == .exactConvertible else {
            throw PWMFanError.legacyConversionUnavailable
        }
        let configuration = PWMFanConfiguration.manual(
            .defaultConfiguration(pin: .gpio18)
        )
        status = stableStatus(
            configuration: configuration,
            legacy: .backupAwaitingResolution
        )
        return status
    }

    func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) async throws -> PWMFanStatus {
        guard status.legacyState == .backupAwaitingResolution else {
            throw PWMFanError.invalidTransition("No legacy backup exists.")
        }
        if resolution == .restore {
            status = PWMFanStatus(
                ownership: .external,
                backend: .sysfs,
                pin: .gpio18,
                periodNanoseconds: 40_000,
                dutyPercent: 50,
                isEnabled: true,
                isRuntimeAvailable: true,
                requiresReboot: false,
                canRestoreAutomatic: false,
                detail: "Demo legacy fan50 setup restored.",
                activeConfiguration: .manual(
                    .defaultConfiguration(pin: .gpio18)
                ),
                legacyState: .exactConvertible
            )
        } else {
            status.legacyState = .none
        }
        return status
    }

    func completeManagedApply() async throws -> PWMFanStatus {
        guard status.recoveryAction == .completeManagedApply,
              let transition = status.transition,
              case let .manual(target)? = transition.target.configuration else {
            throw PWMFanError.invalidTransition(
                "No journaled manual speed update can be completed."
            )
        }
        status = stableStatus(configuration: .manual(target))
        return status
    }

    func completeStateCleanup() async throws -> PWMFanStatus {
        guard status.recoveryAction == .completeStateCleanup else {
            throw PWMFanError.invalidTransition(
                "No retired managed state is awaiting cleanup."
            )
        }
        status = absentStatus()
        return status
    }

    func apply(dutyPercent: Int, persist: Bool) async throws -> PWMFanStatus {
        guard (0...100).contains(dutyPercent) else {
            throw PWMFanError.invalidDutyPercent
        }
        guard status.isRuntimeAvailable else {
            throw PWMFanError.runtimeUnavailable(status.detail)
        }
        guard status.ownership != .managed || persist else {
            throw PWMFanError.invalidTransition(
                "App-managed manual speed changes must be persistent."
            )
        }
        guard !persist || status.ownership == .managed else {
            throw PWMFanError.persistenceNotOwned
        }
        guard status.transition == nil,
              status.backend != .gpioFan else {
            throw PWMFanError.invalidTransition("Manual Apply unavailable.")
        }
        let active = try status.pin.map {
            PWMFanConfiguration.manual(
                try PWMFanManualConfiguration(
                    pin: $0,
                    dutyPercent: dutyPercent
                )
            )
        }
        status = PWMFanStatus(
            ownership: status.ownership,
            backend: status.backend,
            pin: status.pin,
            periodNanoseconds: status.periodNanoseconds,
            dutyPercent: dutyPercent,
            isEnabled: true,
            isRuntimeAvailable: true,
            requiresReboot: false,
            canRestoreAutomatic: status.canRestoreAutomatic,
            detail: "Demo PWM fan is running at \(dutyPercent)%.",
            activeConfiguration: active,
            automaticRestoreConfiguration: status.automaticRestoreConfiguration,
            legacyState: status.legacyState
        )
        return status
    }

    func restoreAutomatic() async throws -> PWMFanStatus {
        guard status.canRestoreAutomatic,
              let pin = status.pin else {
            throw PWMFanError.automaticControlUnavailable
        }
        let automatic = status.automaticRestoreConfiguration
            ?? .defaultConfiguration(pin: pin)
        status = PWMFanStatus(
            ownership: .external,
            backend: .gpioFan,
            pin: pin,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: true,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: "Demo gpio-fan automatic control is active.",
            activeConfiguration: .automatic(automatic),
            automaticDemand: .unknown
        )
        return status
    }

    private func pendingStatus(
        source: PWMFanConfiguration?,
        target: PWMFanTransitionTarget,
        kind: PWMFanTransitionKind
    ) -> PWMFanStatus {
        let targetPin = target.configuration?.pin
        let requirement: PWMFanTransitionRequirement =
            kind == .rollback && (source == nil || target.isUninstall)
                ? .fullShutdown
                : source != nil && source?.pin != targetPin
                    ? .fullShutdown
                    : .reboot
        return PWMFanStatus(
            ownership: .managed,
            backend: source.map(Self.backend),
            pin: source?.pin,
            periodNanoseconds: source?.mode == .manual ? 40_000 : nil,
            dutyPercent: source?.dutyPercent,
            isEnabled: source == nil ? nil : true,
            isRuntimeAvailable: source != nil,
            requiresReboot: true,
            canRestoreAutomatic: false,
            detail: requirement == .fullShutdown
                ? "Demo change prepared; shut down fully before rewiring."
                : "Demo change prepared; reboot required.",
            activeConfiguration: source,
            transition: PWMFanTransitionState(
                source: source,
                target: target,
                phase: .prepared,
                requirement: requirement,
                kind: kind
            ),
            legacyState: status.legacyState
        )
    }

    private func stableStatus(
        configuration: PWMFanConfiguration,
        legacy: PWMFanLegacyState = .none
    ) -> PWMFanStatus {
        PWMFanStatus(
            ownership: .managed,
            backend: Self.backend(configuration),
            pin: configuration.pin,
            periodNanoseconds: configuration.mode == .manual ? 40_000 : nil,
            dutyPercent: configuration.dutyPercent,
            isEnabled: true,
            isRuntimeAvailable: true,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: "Demo managed \(configuration.mode.rawValue) control.",
            activeConfiguration: configuration,
            automaticDemand: configuration.mode == .automatic ? .unknown : nil,
            legacyState: legacy
        )
    }

    private func absentStatus() -> PWMFanStatus {
        PWMFanStatus(
            ownership: .absent,
            backend: nil,
            pin: nil,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: "No compatible PWM fan setup was detected."
        )
    }

    private static func backend(
        _ configuration: PWMFanConfiguration
    ) -> PWMFanBackend {
        configuration.mode == .manual ? .sysfs : .gpioFan
    }
}

private struct FailingSSHCommandExecutor: SSHCommandExecuting {
    let error: any Error & Sendable

    init(error: any Error) {
        self.error = SSHExecutorInitializationError(
            description: error.localizedDescription
        )
    }

    func execute(
        _ request: SSHCommandRequest,
        credentials: SSHCredentials
    ) async throws -> SSHCommandResult {
        throw error
    }
}

private struct SSHExecutorInitializationError: LocalizedError, Sendable {
    let description: String
    var errorDescription: String? { description }
}

enum PWMFanProbeParser {
    private static let version = "CASANATIVE_PWM_FAN_V3"
    private static let keys: Set<String> = [
        "config", "resource_conflict", "unsupported_pwm_gpio",
        "manual_capable", "automatic_capable", "managed_files",
        "disk_state", "disk_pin", "disk_duty", "disk_temp", "disk_hyst",
        "live_state", "live_pin", "live_duty", "live_temp", "live_hyst",
        "live_period", "live_enabled", "automatic_demand",
        "transition", "journal_phase", "recovery_action",
        "transition_kind", "transition_requirement",
        "source_state", "source_pin", "source_duty", "source_temp", "source_hyst",
        "target_state", "target_pin", "target_duty", "target_temp", "target_hyst",
        "legacy", "recovery", "pigs", "pigs_path", "pigpio_version",
        "pigpio_pin", "pigpio_duty", "pigpio_frequency", "pigpio_mode",
    ]

    static func parse(_ output: String) throws -> PWMFanStatus {
        let values = try records(output)
        guard let configPresent = boolean(values["config"]),
              let resourceConflict = boolean(values["resource_conflict"]),
              let unsupportedPWMGPIO = boolean(values["unsupported_pwm_gpio"]),
              let manualCapable = boolean(values["manual_capable"]),
              let automaticCapable = boolean(values["automatic_capable"]),
              let recovery = boolean(values["recovery"]) else {
            throw PWMFanError.invalidCommandResponse
        }
        guard configPresent else {
            return conflict(
                "Raspberry Pi boot configuration could not be found.",
                recovery: recovery,
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        if recovery {
            let recoveryTransition = try? transitionState(values)
            let action = try recoveryAction(values["recovery_action"] ?? "")
            guard recoveryActionIsCoherent(
                action,
                journalPhase: values["journal_phase"] ?? "",
                transition: recoveryTransition
            ) else {
                return conflict(
                    "Managed recovery metadata is malformed; no mutation is safe.",
                    recovery: true,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            return conflict(
                "A managed transaction is incomplete and requires recovery.",
                recovery: true,
                transition: recoveryTransition,
                recoveryAction: action,
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        if resourceConflict {
            return conflict(
                "Analog audio, I2S, or another PWM consumer conflicts with fan control.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        if unsupportedPWMGPIO {
            return conflict(
                "An unsupported pwm-gpio-fan setup was preserved read-only.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }

        let managedFiles = values["managed_files"] ?? ""
        guard ["none", "exact"].contains(managedFiles) else {
            return conflict(
                "App-managed files or their ownership no longer match exactly.",
                recovery: true,
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        let diskState = values["disk_state"] ?? ""
        guard [
            "none", "managed_manual", "managed_automatic",
            "external_gpiofan", "external_pwm",
        ].contains(diskState) else {
            return conflict(
                "The boot fan configuration is malformed or ambiguous.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        let diskMode: String = switch diskState {
        case "managed_manual", "external_pwm": "manual"
        case "managed_automatic", "external_gpiofan": "automatic"
        default: "none"
        }
        let disk = try configuration(
            values: values,
            prefix: "disk",
            state: diskMode,
            allowUninstalled: false
        )
        let liveState = values["live_state"] ?? ""
        guard ["none", "manual", "automatic"].contains(liveState) else {
            return conflict(
                "More than one live fan controller exists or its GPIO is ambiguous.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        let live = try configuration(
            values: values,
            prefix: "live",
            state: liveState,
            allowUninstalled: false
        )
        let livePeriod = try optionalInteger(
            values["live_period"] ?? "",
            required: liveState == "manual",
            range: 1...1_000_000_000
        )
        let liveEnabled = try optionalBoolean(
            values["live_enabled"] ?? "",
            required: liveState == "manual"
        )
        if liveState == "manual", livePeriod != 40_000 {
            return conflict(
                "The live PWM frequency is not the fixed supported 25 kHz.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        let automaticDemand = try demand(
            values["automatic_demand"] ?? "",
            required: liveState == "automatic"
        )
        let legacy = try legacyState(values["legacy"] ?? "")
        let pigpio = try pigpio(values)

        let transition = try transitionState(values)
        if let transition {
            guard managedFiles == "exact" else {
                return conflict(
                    "A transition journal exists without exact app-owned files.",
                    recovery: true,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            let expectedDisk = transition.target.configuration
            guard (expectedDisk == nil && disk == nil)
                    || expectedDisk == disk else {
                return conflict(
                    "The boot configuration does not match the transaction target.",
                    recovery: true,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            let expectedLive = transition.phase == .prepared
                ? transition.source
                : transition.target.configuration
            guard expectedLive == live else {
                return conflict(
                    "The live controller does not match the transaction phase.",
                    recovery: true,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            guard pigpio == nil else {
                return conflict(
                    "pigpio cannot control an app-managed transition.",
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            return status(
                ownership: .managed,
                configuration: live,
                period: livePeriod,
                enabled: liveEnabled,
                automaticDemand: automaticDemand,
                transition: transition,
                legacy: legacy,
                detail: transition.requirement == .fullShutdown
                    ? "A prepared change requires a full shutdown before its next-boot state can take effect."
                    : transition.phase == .prepared
                        ? "A managed change is prepared for the next reboot."
                        : "The target booted and awaits confirmation or rollback.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }

        if managedFiles == "exact" {
            guard diskState == "managed_manual"
                    || diskState == "managed_automatic",
                  let disk,
                  disk == live,
                  pigpio == nil else {
                return conflict(
                    "The stable app-managed disk and live states do not match.",
                    recovery: true,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            return status(
                ownership: .managed,
                configuration: live,
                period: livePeriod,
                enabled: liveEnabled,
                automaticDemand: automaticDemand,
                transition: nil,
                legacy: legacy,
                detail: live?.mode == .manual
                    ? "Casa Native managed fixed 25 kHz manual control is active."
                    : "Casa Native managed automatic off/full gpio-fan control is active.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }

        if legacy == .backupAwaitingResolution {
            return conflict(
                "Legacy backup metadata exists without an exact managed setup.",
                recovery: true,
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        if legacy == .exactConvertible {
            guard case let .manual(manual)? = live,
                  manual.pin == .gpio18,
                  manual.dutyPercent == 50,
                  diskState == "external_pwm" else {
                return conflict(
                    "The exact legacy fan50 files do not match the live GPIO18 50% output.",
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            if let pigpio {
                guard pigpio.pin == .gpio18 else {
                    return conflict(
                        "Legacy sysfs and pigpio report different GPIOs.",
                        manualCapable: manualCapable,
                        automaticCapable: automaticCapable
                    )
                }
                return externalPigpioStatus(
                    pigpio,
                    canRestoreAutomatic: false,
                    automaticRestoreConfiguration: nil,
                    detail: "Exact legacy fan50 files are preserved; active GPIO18 pigpio override detected.",
                    legacy: .exactConvertible,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            return status(
                ownership: .external,
                configuration: live,
                period: livePeriod,
                enabled: liveEnabled,
                automaticDemand: nil,
                transition: nil,
                legacy: .exactConvertible,
                detail: "Exact external fan50 setup detected; conversion is available without changing runtime output.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }

        if diskState == "external_gpiofan" {
            guard case let .automatic(policy)? = disk,
                  live == disk else {
                return conflict(
                    "External gpio-fan disk and live policies do not match.",
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            if let pigpio {
                guard pigpio.pin == policy.pin else {
                    return conflict(
                        "pigpio does not match the external gpio-fan GPIO.",
                        manualCapable: manualCapable,
                        automaticCapable: automaticCapable
                    )
                }
                return externalPigpioStatus(
                    pigpio,
                    canRestoreAutomatic: true,
                    automaticRestoreConfiguration: policy,
                    detail: "Pin-matched pigpio manual override of external gpio-fan control detected.",
                    legacy: .none,
                    manualCapable: manualCapable,
                    automaticCapable: automaticCapable
                )
            }
            return status(
                ownership: .external,
                configuration: live,
                period: nil,
                enabled: nil,
                automaticDemand: automaticDemand,
                transition: nil,
                legacy: .none,
                detail: "External automatic gpio-fan control detected read-only.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }

        if diskState != "none" || live != nil || pigpio != nil {
            return conflict(
                "A PWM or fan controller exists, but its purpose or ownership was not verified.",
                manualCapable: manualCapable,
                automaticCapable: automaticCapable
            )
        }
        return PWMFanStatus(
            ownership: .absent,
            backend: nil,
            pin: nil,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: automaticCapable
                ? "No compatible fan setup was detected."
                : "No fan setup was detected; stock automatic gpio-fan capability is unavailable.",
            manualControlAvailable: manualCapable,
            automaticControlAvailable: automaticCapable
        )
    }

    private static func records(_ output: String) throws -> [String: String] {
        var lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.first == version else {
            throw PWMFanError.invalidCommandResponse
        }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let tab = line.firstIndex(of: "\t"),
                  line[line.index(after: tab)...].firstIndex(of: "\t") == nil else {
                throw PWMFanError.invalidCommandResponse
            }
            let key = String(line[..<tab])
            let value = String(line[line.index(after: tab)...])
            guard keys.contains(key), result[key] == nil,
                  !value.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                  ) else {
                throw PWMFanError.invalidCommandResponse
            }
            result[key] = value
        }
        guard Set(result.keys) == keys else {
            throw PWMFanError.invalidCommandResponse
        }
        return result
    }

    private static func configuration(
        values: [String: String],
        prefix: String,
        state: String,
        allowUninstalled: Bool
    ) throws -> PWMFanConfiguration? {
        let pinValue = values["\(prefix)_pin"] ?? ""
        let dutyValue = values["\(prefix)_duty"] ?? ""
        let tempValue = values["\(prefix)_temp"] ?? ""
        let hystValue = values["\(prefix)_hyst"] ?? ""
        switch state {
        case "none":
            guard [pinValue, dutyValue, tempValue, hystValue].allSatisfy(\.isEmpty)
            else { throw PWMFanError.invalidCommandResponse }
            return nil
        case "uninstalled" where allowUninstalled:
            guard [pinValue, dutyValue, tempValue, hystValue].allSatisfy(\.isEmpty)
            else { throw PWMFanError.invalidCommandResponse }
            return nil
        case "manual":
            guard let pin = pin(pinValue),
                  let duty = integer(dutyValue, range: 0...100),
                  tempValue.isEmpty, hystValue.isEmpty else {
                throw PWMFanError.invalidCommandResponse
            }
            return .manual(
                try PWMFanManualConfiguration(pin: pin, dutyPercent: duty)
            )
        case "automatic":
            guard let pin = pin(pinValue), dutyValue.isEmpty,
                  let temp = integer(tempValue, range: 40...75),
                  let hyst = integer(hystValue, range: 5...15) else {
                throw PWMFanError.invalidCommandResponse
            }
            return .automatic(
                try PWMFanAutomaticConfiguration(
                    pin: pin,
                    turnOnCelsius: temp,
                    hysteresisCelsius: hyst
                )
            )
        default:
            throw PWMFanError.invalidCommandResponse
        }
    }

    private static func transitionState(
        _ values: [String: String]
    ) throws -> PWMFanTransitionState? {
        let phaseValue = values["transition"] ?? ""
        if phaseValue == "none" {
            if values["journal_phase"] == "removing",
               values["recovery_action"] == PWMFanRecoveryAction.completeStateCleanup.rawValue {
                guard [
                    "transition_kind", "transition_requirement",
                    "source_state", "source_pin", "source_duty", "source_temp", "source_hyst",
                    "target_state", "target_pin", "target_duty", "target_temp", "target_hyst",
                ].allSatisfy({ values[$0]?.isEmpty == true }) else {
                    throw PWMFanError.invalidCommandResponse
                }
                return nil
            }
            guard [
                "journal_phase", "recovery_action",
                "transition_kind", "transition_requirement",
                "source_state", "source_pin", "source_duty", "source_temp", "source_hyst",
                "target_state", "target_pin", "target_duty", "target_temp", "target_hyst",
            ].allSatisfy({ values[$0]?.isEmpty == true }) else {
                throw PWMFanError.invalidCommandResponse
            }
            return nil
        }
        let journalPhase = values["journal_phase"] ?? ""
        let recoveryValue = values["recovery_action"] ?? ""
        guard let phase = PWMFanTransitionPhase(rawValue: phaseValue),
              [
                "prepared", "cancelling", "finalizing",
                "legacyConverting", "legacyRestoring",
                "legacyDiscarding",
                "applying",
              ].contains(journalPhase),
              (journalPhase == "prepared"
                && (recoveryValue.isEmpty
                    || recoveryValue == PWMFanRecoveryAction.cancelPreparedChange.rawValue
                    || recoveryValue == PWMFanRecoveryAction.completeRollbackPreparation.rawValue))
                || (journalPhase != "prepared" && !recoveryValue.isEmpty),
              let kind = transitionKind(values["transition_kind"] ?? ""),
              let requirement = transitionRequirement(
                values["transition_requirement"] ?? ""
              ) else { throw PWMFanError.invalidCommandResponse }
        let sourceState = values["source_state"] ?? ""
        let source = try configuration(
            values: values,
            prefix: "source",
            state: sourceState,
            allowUninstalled: false
        )
        let targetState = values["target_state"] ?? ""
        let targetConfiguration = try configuration(
            values: values,
            prefix: "target",
            state: targetState,
            allowUninstalled: true
        )
        let target: PWMFanTransitionTarget = targetState == "uninstalled"
            ? .uninstalled
            : .configuration(
                try required(targetConfiguration)
            )
        if kind == .uninstall {
            guard target.isUninstall, source != nil else {
                throw PWMFanError.invalidCommandResponse
            }
        } else if kind == .rollback {
            guard source != nil || target.configuration != nil else {
                throw PWMFanError.invalidCommandResponse
            }
        } else {
            guard !target.isUninstall else {
                throw PWMFanError.invalidCommandResponse
            }
        }
        if kind == .rollback && (source == nil || target.isUninstall) {
            guard requirement == .fullShutdown else {
                throw PWMFanError.invalidCommandResponse
            }
        } else if source == nil {
            guard requirement == .reboot,
                  !target.isUninstall else {
                throw PWMFanError.invalidCommandResponse
            }
        } else if source?.pin != target.configuration?.pin {
            guard requirement == .fullShutdown else {
                throw PWMFanError.invalidCommandResponse
            }
        } else {
            guard requirement == .reboot else {
                throw PWMFanError.invalidCommandResponse
            }
        }
        switch journalPhase {
        case "legacyConverting":
            guard source == nil,
                  kind == .configurationChange,
                  requirement == .reboot,
                  target.configuration == .manual(.defaultConfiguration(pin: .gpio18)) else {
                throw PWMFanError.invalidCommandResponse
            }
        case "legacyRestoring", "legacyDiscarding":
            let legacy = PWMFanConfiguration.manual(
                .defaultConfiguration(pin: .gpio18)
            )
            guard source == legacy,
                  target.configuration == legacy,
                  kind == .configurationChange,
                  requirement == .reboot else {
                throw PWMFanError.invalidCommandResponse
            }
        case "applying":
            guard case let .manual(old)? = source,
                  case let .manual(new)? = target.configuration,
                  old.pin == new.pin,
                  kind == .configurationChange,
                  requirement == .reboot else {
                throw PWMFanError.invalidCommandResponse
            }
        default:
            break
        }
        if let source, let targetConfiguration = target.configuration,
           !["applying", "legacyConverting", "legacyRestoring", "legacyDiscarding"].contains(journalPhase) {
            switch (source, targetConfiguration) {
            case let (.manual(old), .automatic(new)),
                 let (.automatic(new), .manual(old)):
                guard old.pin == new.pin else {
                    throw PWMFanError.invalidCommandResponse
                }
            case let (.manual(old), .manual(new)):
                guard old.pin != new.pin,
                      old.dutyPercent == new.dutyPercent else {
                    throw PWMFanError.invalidCommandResponse
                }
            case let (.automatic(old), .automatic(new)):
                if old.pin == new.pin {
                    guard old.turnOnCelsius != new.turnOnCelsius
                            || old.hysteresisCelsius != new.hysteresisCelsius else {
                        throw PWMFanError.invalidCommandResponse
                    }
                } else {
                    guard old.turnOnCelsius == new.turnOnCelsius,
                          old.hysteresisCelsius == new.hysteresisCelsius else {
                        throw PWMFanError.invalidCommandResponse
                    }
                }
            }
        }
        return PWMFanTransitionState(
            source: source,
            target: target,
            phase: phase,
            requirement: requirement,
            kind: kind
        )
    }

    private struct PigpioState {
        let pin: PWMFanGPIOPin
        let dutyPercent: Int
    }

    private static func pigpio(
        _ values: [String: String]
    ) throws -> PigpioState? {
        let state = values["pigs"] ?? ""
        let path = values["pigs_path"] ?? ""
        let fields = [
            values["pigpio_version"] ?? "",
            values["pigpio_pin"] ?? "",
            values["pigpio_duty"] ?? "",
            values["pigpio_frequency"] ?? "",
            values["pigpio_mode"] ?? "",
        ]
        switch state {
        case "none":
            guard path.isEmpty, fields.allSatisfy(\.isEmpty) else {
                throw PWMFanError.invalidCommandResponse
            }
            return nil
        case "inactive":
            guard allowedPigsPath(path),
                  integer(fields[0], range: 79...10_000) != nil,
                  fields.dropFirst().allSatisfy(\.isEmpty) else {
                throw PWMFanError.invalidCommandResponse
            }
            return nil
        case "active":
            guard allowedPigsPath(path),
                  integer(fields[0], range: 79...10_000) != nil,
                  let pin = pin(fields[1]),
                  let duty = integer(fields[2], range: 0...1_000_000),
                  integer(fields[3], range: 1...375_000_000) == 25_000,
                  integer(fields[4], range: 0...7) == pin.function else {
                throw PWMFanError.invalidCommandResponse
            }
            return PigpioState(
                pin: pin,
                dutyPercent: Int((Double(duty) / 10_000).rounded())
            )
        case "invalid", "unsupported", "ambiguous", "unreachable", "occupied":
            throw PWMFanError.invalidCommandResponse
        default:
            throw PWMFanError.invalidCommandResponse
        }
    }

    private static func status(
        ownership: PWMFanOwnership,
        configuration: PWMFanConfiguration?,
        period: Int?,
        enabled: Bool?,
        automaticDemand: PWMFanAutomaticDemand?,
        transition: PWMFanTransitionState?,
        legacy: PWMFanLegacyState,
        detail: String,
        manualCapable: Bool,
        automaticCapable: Bool
    ) -> PWMFanStatus {
        let backend: PWMFanBackend? = configuration.map {
            $0.mode == .manual ? .sysfs : .gpioFan
        }
        return PWMFanStatus(
            ownership: ownership,
            backend: backend,
            pin: configuration?.pin,
            periodNanoseconds: period,
            dutyPercent: configuration?.dutyPercent,
            isEnabled: enabled,
            isRuntimeAvailable: configuration != nil,
            requiresReboot: transition != nil,
            canRestoreAutomatic: false,
            detail: detail,
            activeConfiguration: configuration,
            transition: transition,
            automaticDemand: automaticDemand,
            legacyState: legacy,
            manualControlAvailable: manualCapable,
            automaticControlAvailable: automaticCapable
        )
    }

    private static func externalPigpioStatus(
        _ pigpio: PigpioState,
        canRestoreAutomatic: Bool,
        automaticRestoreConfiguration: PWMFanAutomaticConfiguration?,
        detail: String,
        legacy: PWMFanLegacyState,
        manualCapable: Bool,
        automaticCapable: Bool
    ) -> PWMFanStatus {
        let configuration = PWMFanConfiguration.manual(
            try! PWMFanManualConfiguration(
                pin: pigpio.pin,
                dutyPercent: pigpio.dutyPercent
            )
        )
        return PWMFanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: pigpio.pin,
            periodNanoseconds: 40_000,
            dutyPercent: pigpio.dutyPercent,
            isEnabled: true,
            isRuntimeAvailable: true,
            requiresReboot: false,
            canRestoreAutomatic: canRestoreAutomatic,
            detail: detail,
            activeConfiguration: configuration,
            automaticRestoreConfiguration: automaticRestoreConfiguration,
            legacyState: legacy,
            manualControlAvailable: manualCapable,
            automaticControlAvailable: automaticCapable
        )
    }

    private static func conflict(
        _ detail: String,
        recovery: Bool = false,
        transition: PWMFanTransitionState? = nil,
        recoveryAction: PWMFanRecoveryAction? = nil,
        manualCapable: Bool = false,
        automaticCapable: Bool = false
    ) -> PWMFanStatus {
        PWMFanStatus(
            ownership: .conflict,
            backend: nil,
            pin: nil,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: transition != nil,
            canRestoreAutomatic: false,
            detail: detail,
            transition: transition,
            recoveryRequired: recovery,
            manualControlAvailable: manualCapable,
            automaticControlAvailable: automaticCapable,
            recoveryAction: recoveryAction
        )
    }

    private static func legacyState(
        _ value: String
    ) throws -> PWMFanLegacyState {
        switch value {
        case "none": .none
        case "exact": .exactConvertible
        case "backup": .backupAwaitingResolution
        default: throw PWMFanError.invalidCommandResponse
        }
    }

    private static func demand(
        _ value: String,
        required: Bool
    ) throws -> PWMFanAutomaticDemand? {
        if !required {
            guard value.isEmpty else { throw PWMFanError.invalidCommandResponse }
            return nil
        }
        guard let demand = PWMFanAutomaticDemand(rawValue: value) else {
            throw PWMFanError.invalidCommandResponse
        }
        return demand
    }

    private static func recoveryAction(
        _ value: String
    ) throws -> PWMFanRecoveryAction? {
        if value.isEmpty { return nil }
        guard let action = PWMFanRecoveryAction(rawValue: value) else {
            throw PWMFanError.invalidCommandResponse
        }
        return action
    }

    private static func recoveryActionIsCoherent(
        _ action: PWMFanRecoveryAction?,
        journalPhase: String,
        transition: PWMFanTransitionState?
    ) -> Bool {
        guard let action else { return true }
        if journalPhase == "removing", action == .completeStateCleanup {
            return transition == nil
        }
        guard let transition else { return false }
        switch (journalPhase, action) {
        case ("prepared", .cancelPreparedChange):
            return transition.phase == .prepared
                && transition.kind != .rollback
        case ("prepared", .completeRollbackPreparation):
            return transition.phase == .prepared
                && transition.kind == .rollback
        case ("cancelling", .cancelPreparedChange):
            return transition.phase == .prepared
        case ("finalizing", .finalizePreparedChange):
            return transition.phase == .bootedAwaitingConfirmation
                && transition.kind != .uninstall
        case ("finalizing", .completeUninstall):
            return transition.phase == .bootedAwaitingConfirmation
                && transition.kind == .uninstall
        case ("legacyConverting", .completeLegacyConversion),
             ("legacyRestoring", .completeLegacyRestore),
             ("legacyDiscarding", .completeLegacyDiscard),
             ("applying", .completeManagedApply):
            return true
        default:
            return false
        }
    }

    private static func transitionKind(
        _ value: String
    ) -> PWMFanTransitionKind? {
        switch value {
        case "change": .configurationChange
        case "rollback": .rollback
        case "uninstall": .uninstall
        default: nil
        }
    }

    private static func transitionRequirement(
        _ value: String
    ) -> PWMFanTransitionRequirement? {
        switch value {
        case "reboot": .reboot
        case "shutdown": .fullShutdown
        default: nil
        }
    }

    private static func boolean(_ value: String?) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }

    private static func optionalBoolean(
        _ value: String,
        required: Bool
    ) throws -> Bool? {
        if !required {
            guard value.isEmpty else { throw PWMFanError.invalidCommandResponse }
            return nil
        }
        guard let result = boolean(value) else {
            throw PWMFanError.invalidCommandResponse
        }
        return result
    }

    private static func optionalInteger(
        _ value: String,
        required: Bool,
        range: ClosedRange<Int>
    ) throws -> Int? {
        if !required {
            guard value.isEmpty else { throw PWMFanError.invalidCommandResponse }
            return nil
        }
        guard let result = integer(value, range: range) else {
            throw PWMFanError.invalidCommandResponse
        }
        return result
    }

    private static func integer(
        _ value: String,
        range: ClosedRange<Int>
    ) -> Int? {
        guard value == value.trimmingCharacters(in: .whitespaces),
              let result = Int(value), range.contains(result) else { return nil }
        return result
    }

    private static func pin(_ value: String) -> PWMFanGPIOPin? {
        guard let raw = integer(value, range: 0...53) else { return nil }
        return PWMFanGPIOPin(rawValue: raw)
    }

    private static func allowedPigsPath(_ value: String) -> Bool {
        value == "/usr/bin/pigs" || value == "/usr/local/bin/pigs"
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw PWMFanError.invalidCommandResponse }
        return value
    }
}

#if false // V2 wire format retired; excluded from every production build.
enum PWMFanProbeParserV2 {
    private static let version = "CASANATIVE_PWM_FAN_V2"
    private static let keys: Set<String> = [
        "config", "overlay", "legacy_block", "legacy_script", "legacy_service",
        "managed_block", "managed_helper", "managed_defaults", "managed_service",
        "resource_conflict",
        "gpio_fan_config", "gpio_fan_config_pin", "gpio_fan_live",
        "gpio_fan_live_pin", "pigs", "pigs_path", "pigpio_version",
        "pigpio_pin", "pigpio_duty", "pigpio_frequency", "pigpio_mode",
        "sysfs_count", "sysfs_pin", "sysfs_period", "sysfs_duty", "sysfs_enabled",
    ]

    static func parse(_ output: String) throws -> PWMFanStatus {
        var lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.first == version else {
            throw PWMFanError.invalidCommandResponse
        }

        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            guard
                let tab = line.firstIndex(of: "\t"),
                line[line.index(after: tab)...].firstIndex(of: "\t") == nil
            else {
                throw PWMFanError.invalidCommandResponse
            }
            let key = String(line[..<tab])
            let value = String(line[line.index(after: tab)...])
            guard
                keys.contains(key),
                values[key] == nil,
                !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw PWMFanError.invalidCommandResponse
            }
            values[key] = value
        }
        guard Set(values.keys) == keys else {
            throw PWMFanError.invalidCommandResponse
        }

        if values["overlay"]?.split(separator: ",").contains("unsupported") == true {
            return conflict("An unsupported or malformed PWM overlay is active.")
        }
        if ["legacy_block", "legacy_script", "legacy_service"].contains(
            where: { values[$0] == "x" }
        ) {
            return conflict("The existing fan50 setup could not be verified exactly.")
        }
        if ["managed_block", "managed_helper", "managed_defaults", "managed_service"].contains(
            where: { values[$0] == "x" }
        ) {
            return conflict("Casa Native's managed fan files no longer match their installed content.")
        }
        if values["gpio_fan_config"] == "x" || values["gpio_fan_live"] == "x" {
            return conflict("The automatic gpio-fan controller or its GPIO could not be verified.")
        }
        if values["sysfs_count"] == "x" {
            return conflict("An active Linux PWM controller could not be identified safely.")
        }
        if values["resource_conflict"] != "0" {
            return conflict("Analog audio, I2S, or another PWM consumer conflicts with fan control.")
        }

        guard
            let configPresent = boolean(values["config"]),
            let legacyBlock = boolean(values["legacy_block"]),
            let legacyScript = boolean(values["legacy_script"]),
            let legacyService = boolean(values["legacy_service"]),
            let managedBlock = boolean(values["managed_block"]),
            let managedHelper = boolean(values["managed_helper"]),
            let managedDefaults = boolean(values["managed_defaults"]),
            let managedService = boolean(values["managed_service"]),
            let gpioFanConfig = boolean(values["gpio_fan_config"]),
            let gpioFanLive = boolean(values["gpio_fan_live"]),
            let sysfsCount = integer(values["sysfs_count"], in: 0...32)
        else {
            throw PWMFanError.invalidCommandResponse
        }
        let gpioFanConfigPin = try optionalPin(
            values["gpio_fan_config_pin"] ?? "",
            present: gpioFanConfig
        )
        let gpioFanLivePin = try optionalPin(
            values["gpio_fan_live_pin"] ?? "",
            present: gpioFanLive
        )

        guard configPresent else {
            return conflict("Raspberry Pi boot configuration could not be found.")
        }

        let overlay = try parseOverlay(values["overlay"] ?? "")
        let pigpioProbe = try parsePigpio(values: values)
        let sysfs = try parseSysfs(values: values, count: sysfsCount)
        if case let .conflict(detail) = pigpioProbe {
            return conflict(detail)
        }
        let pigpio: PigpioState? = if case let .active(state) = pigpioProbe {
            state
        } else {
            nil
        }

        let legacyParts = [legacyBlock, legacyScript, legacyService]
        let managedParts = [managedBlock, managedHelper, managedDefaults, managedService]
        let hasAnyLegacy = legacyParts.contains(true)
        let hasAllLegacy = legacyParts.allSatisfy { $0 }
        let hasAnyManaged = managedParts.contains(true)
        let hasAllManaged = managedParts.allSatisfy { $0 }

        if (hasAnyLegacy && !hasAllLegacy) || (hasAnyManaged && !hasAllManaged) {
            return conflict("Fan setup ownership markers are incomplete.")
        }
        if hasAnyLegacy && hasAnyManaged {
            return conflict("Both legacy and Casa Native managed setups exist.")
        }
        if (hasAllLegacy || hasAllManaged || sysfs != nil)
            && (gpioFanConfig || gpioFanLive)
        {
            return conflict(
                "Linux PWM and automatic gpio-fan control are both present. No manual control was enabled."
            )
        }
        if overlay.count > 1 {
            return conflict("Multiple hardware PWM overlays are active.")
        }
        if let single = overlay.first, single.pin.function != single.function {
            return conflict("PWM overlay uses an unsupported pin/function pair.")
        }
        if (hasAllLegacy || hasAllManaged), overlay.count != 1 {
            return conflict("Owned fan files do not match one supported PWM overlay.")
        }

        if hasAllManaged {
            guard let item = overlay.first else {
                return conflict("Managed PWM overlay is missing.")
            }
            if pigpio != nil {
                return conflict("pigpio is controlling an app-managed sysfs fan.")
            }
            if let sysfs, sysfs.pin != item.pin {
                return conflict("Runtime PWM channel does not match managed GPIO.")
            }
            return PWMFanStatus(
                ownership: .managed,
                backend: .sysfs,
                pin: item.pin,
                periodNanoseconds: sysfs?.period,
                dutyPercent: sysfs?.dutyPercent,
                isEnabled: sysfs?.enabled,
                isRuntimeAvailable: sysfs != nil,
                requiresReboot: sysfs == nil,
                canRestoreAutomatic: false,
                detail: sysfs == nil
                    ? "Managed setup is installed; reboot is required before runtime control."
                    : "Casa Native managed Linux PWM setup detected."
            )
        }

        if let pigpio {
            if let overlayPin = overlay.first?.pin, overlayPin != pigpio.pin {
                return conflict("pigpio GPIO does not match configured hardware PWM GPIO.")
            }
            if let sysfs, sysfs.pin != pigpio.pin {
                return conflict("pigpio and Linux PWM report different GPIOs.")
            }
            let isLegacy = hasAllLegacy
            let isGPIOFanOverride = gpioFanConfigPin == pigpio.pin
                && gpioFanLivePin == pigpio.pin
            guard isLegacy || isGPIOFanOverride else {
                return conflict(
                    "An active PWM output was found, but its purpose was not verified as a fan. No control was enabled."
                )
            }
            return PWMFanStatus(
                ownership: .external,
                backend: .pigpio,
                pin: pigpio.pin,
                periodNanoseconds: pigpio.frequency > 0
                    ? Int((1_000_000_000.0 / Double(pigpio.frequency)).rounded())
                    : nil,
                dutyPercent: Int((Double(pigpio.duty) / 10_000.0).rounded()),
                isEnabled: pigpio.frequency > 0,
                isRuntimeAvailable: true,
                requiresReboot: false,
                canRestoreAutomatic: isGPIOFanOverride,
                detail: isLegacy
                    ? "Existing fan50 setup is active through pigpio hardware PWM."
                    : "Active PWM output is associated with the configured GPIO fan. Verify the physical wiring before changing it."
            )
        }

        if hasAllLegacy {
            let pin = overlay.first?.pin
            if let sysfs, let pin, sysfs.pin != pin {
                return conflict("Runtime PWM channel does not match configured GPIO.")
            }
            return PWMFanStatus(
                ownership: .external,
                backend: .sysfs,
                pin: pin,
                periodNanoseconds: sysfs?.period,
                dutyPercent: sysfs?.dutyPercent,
                isEnabled: sysfs?.enabled,
                isRuntimeAvailable: sysfs != nil,
                requiresReboot: false,
                canRestoreAutomatic: false,
                detail: "Existing fan50 setup detected and left unchanged."
            )
        }

        if sysfs != nil || overlay.count == 1 {
            return conflict(
                "A PWM output or overlay exists, but its purpose was not verified as a fan. No control was enabled."
            )
        }
        if gpioFanConfig || gpioFanLive {
            return PWMFanStatus(
                ownership: .external,
                backend: nil,
                pin: gpioFanLivePin ?? gpioFanConfigPin,
                periodNanoseconds: nil,
                dutyPercent: nil,
                isEnabled: nil,
                isRuntimeAvailable: false,
                requiresReboot: false,
                canRestoreAutomatic: false,
                detail: "Automatic gpio-fan control is configured; manual PWM is not active."
            )
        }
        return PWMFanStatus(
            ownership: .absent,
            backend: nil,
            pin: nil,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: "No compatible PWM fan setup was detected."
        )
    }

    private static func boolean(_ value: String?) -> Bool? {
        switch value {
        case "0": false
        case "1": true
        default: nil
        }
    }

    private static func integer(
        _ value: String?,
        in range: ClosedRange<Int>
    ) -> Int? {
        guard let value, value == value.trimmingCharacters(in: .whitespaces),
              let number = Int(value), range.contains(number) else { return nil }
        return number
    }

    private static func optionalPin(
        _ value: String,
        present: Bool
    ) throws -> PWMFanGPIOPin? {
        if !present {
            guard value.isEmpty else { throw PWMFanError.invalidCommandResponse }
            return nil
        }
        guard
            let rawPin = integer(value, in: 0...53),
            let pin = PWMFanGPIOPin(rawValue: rawPin)
        else { throw PWMFanError.invalidCommandResponse }
        return pin
    }

    private static func parseOverlay(
        _ value: String
    ) throws -> [(pin: PWMFanGPIOPin, function: Int)] {
        guard !value.isEmpty else { return [] }
        return try value.split(separator: ",", omittingEmptySubsequences: false).map {
            let parts = $0.split(separator: ":", omittingEmptySubsequences: false)
            guard
                parts.count == 2,
                let rawPin = Int(parts[0]),
                let pin = PWMFanGPIOPin(rawValue: rawPin),
                let function = Int(parts[1]),
                (0...7).contains(function)
            else { throw PWMFanError.invalidCommandResponse }
            return (pin, function)
        }
    }

    private struct PigpioState {
        let pin: PWMFanGPIOPin
        let duty: Int
        let frequency: Int
    }

    private enum PigpioProbe {
        case none
        case inactive
        case active(PigpioState)
        case conflict(String)
    }

    private static func parsePigpio(
        values: [String: String]
    ) throws -> PigpioProbe {
        let state = values["pigs"] ?? ""
        let path = values["pigs_path"] ?? ""
        let version = values["pigpio_version"] ?? ""
        let pinValue = values["pigpio_pin"] ?? ""
        let dutyValue = values["pigpio_duty"] ?? ""
        let frequencyValue = values["pigpio_frequency"] ?? ""
        let modeValue = values["pigpio_mode"] ?? ""
        let measurements = [pinValue, dutyValue, frequencyValue, modeValue]
        switch state {
        case "none":
            guard path.isEmpty, version.isEmpty,
                  measurements.allSatisfy(\.isEmpty) else {
                throw PWMFanError.invalidCommandResponse
            }
            return .none
        case "inactive":
            guard Self.isAllowedPigsPath(path),
                  integer(version, in: 79...10_000) != nil,
                  measurements.allSatisfy(\.isEmpty) else {
                throw PWMFanError.invalidCommandResponse
            }
            return .inactive
        case "active":
            guard Self.isAllowedPigsPath(path),
                  integer(version, in: 79...10_000) != nil,
                  let rawPin = integer(pinValue, in: 0...53),
                  let pin = PWMFanGPIOPin(rawValue: rawPin),
                  let duty = integer(dutyValue, in: 0...1_000_000),
                  let frequency = integer(frequencyValue, in: 1...375_000_000),
                  let mode = integer(modeValue, in: 0...7),
                  mode == pin.function else {
                throw PWMFanError.invalidCommandResponse
            }
            return .active(PigpioState(pin: pin, duty: duty, frequency: frequency))
        case "invalid", "unsupported", "ambiguous", "unreachable", "occupied":
            guard path.isEmpty || Self.isAllowedPigsPath(path),
                  measurements.allSatisfy(\.isEmpty) else {
                throw PWMFanError.invalidCommandResponse
            }
            let detail = switch state {
            case "invalid": "The pigs executable is not a single trusted root-owned file."
            case "unsupported": "The installed pigpio version cannot be read safely."
            case "ambiguous": "More than one supported GPIO reports active hardware PWM."
            case "unreachable": "pigpio state could not be read completely."
            default: "A supported GPIO is in use by another mode or PWM consumer."
            }
            return .conflict(detail)
        default:
            throw PWMFanError.invalidCommandResponse
        }
    }

    private static func isAllowedPigsPath(_ value: String) -> Bool {
        value == "/usr/bin/pigs" || value == "/usr/local/bin/pigs"
    }

    private struct SysfsState {
        let pin: PWMFanGPIOPin
        let period: Int
        let dutyPercent: Int
        let enabled: Bool
    }

    private static func parseSysfs(
        values: [String: String],
        count: Int
    ) throws -> SysfsState? {
        let fields = ["sysfs_pin", "sysfs_period", "sysfs_duty", "sysfs_enabled"]
            .map { values[$0] ?? "" }
        guard count == 0 else {
            guard count == 1,
                  let rawPin = integer(fields[0], in: 0...53),
                  let pin = PWMFanGPIOPin(rawValue: rawPin),
                  let period = integer(fields[1], in: 1...1_000_000_000),
                  let duty = integer(fields[2], in: 0...period),
                  let enabled = boolean(fields[3]) else {
                throw PWMFanError.invalidCommandResponse
            }
            return SysfsState(
                pin: pin,
                period: period,
                dutyPercent: Int((Double(duty) * 100 / Double(period)).rounded()),
                enabled: enabled
            )
        }
        guard fields.allSatisfy(\.isEmpty) else {
            throw PWMFanError.invalidCommandResponse
        }
        return nil
    }

    private static func conflict(_ detail: String) -> PWMFanStatus {
        PWMFanStatus(
            ownership: .conflict,
            backend: nil,
            pin: nil,
            periodNanoseconds: nil,
            dutyPercent: nil,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: false,
            canRestoreAutomatic: false,
            detail: detail
        )
    }
}
#endif

enum PWMFanScripts {
    private static let nonInteractiveCommand = "/usr/bin/sudo -n /usr/bin/true"

    static let sudoNonInteractiveCheck = SSHCommandRequest(
        command: nonInteractiveCommand,
        timeoutSeconds: 5,
        maximumOutputBytes: 4_096
    )

    /// Fixed, read-only probe. No sudo, exports, writes, or service operations.
    static let detection = SSHCommandRequest(
        command: PWMFanManagedLifecycleScripts.detectionShell,
        timeoutSeconds: 10,
        maximumOutputBytes: 32 * 1_024
    )

    static func pigpioApply(
        pin: PWMFanGPIOPin,
        dutyPercent: Int
    ) -> SSHCommandRequest {
        precondition((0...100).contains(dutyPercent))
        let duty = dutyPercent * 10_000
        let script = """
        set -eu
        \(trustedPigsResolutionShell(requirePresent: true))
        \(externalFanAssociationGuardShell(pin: pin))
        \(resourceConflictGuardShell)
        mode="$("$PIGS" mg \(pin.rawValue))"
        case "$mode" in ''|*[!0-9]*) exit 75;; esac
        [ "$mode" = \(pin.function) ]
        current_duty="$("$PIGS" gdc \(pin.rawValue))"
        current_frequency="$("$PIGS" pfg \(pin.rawValue))"
        case "$mode:$current_duty:$current_frequency" in *[!0-9:]*|*::* ) exit 75;; esac
        [ "$current_duty" -le 1000000 ]
        [ "$current_frequency" -gt 0 ]
        for gpio in 12 13 18 19; do
          [ "$gpio" = \(pin.rawValue) ] && continue
          other_mode="$("$PIGS" mg "$gpio")"
          case "$other_mode" in ''|*[!0-9]*) exit 75;; esac
          [ "$other_mode" = 0 ] || { echo 'Another supported PWM GPIO is in use' >&2; exit 73; }
        done
        "$PIGS" hp \(pin.rawValue) 25000 \(duty)
        """
        return unprivileged(
            script: script,
            timeoutSeconds: 10,
            maximumOutputBytes: 4_096
        )
    }

    private static func unprivileged(
        script: String,
        timeoutSeconds: Int,
        maximumOutputBytes: Int
    ) -> SSHCommandRequest {
        let boundedScript = """
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        export PATH
        \(script)
        """
        let encoded = base64(boundedScript)
        return SSHCommandRequest(
            command: "/usr/bin/timeout --signal=TERM --kill-after=2s 6s /bin/sh -c \"/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -d | /bin/sh\"",
            timeoutSeconds: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    static func privileged(script: String, password: String?) -> SSHCommandRequest {
        let rootScript = """
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        export PATH
        \(script)
        """
        let encoded = base64(rootScript)
        let decoder = "/usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -d | /bin/sh"
        let bounded = "/usr/bin/timeout --signal=TERM --kill-after=3s 15s /bin/sh -c \"\(decoder)\""
        let command: String
        var input = Data()
        if let password {
            command = "/usr/bin/sudo -S -p '' \(bounded)"
            input.append(Data(password.utf8))
            input.append(0x0A)
        } else {
            command = "/usr/bin/sudo -n \(bounded)"
        }
        return SSHCommandRequest(
            command: command,
            standardInput: input,
            timeoutSeconds: 22,
            maximumOutputBytes: 16 * 1_024
        )
    }

#if false // V1 managed lifecycle retired; V3 is in PWMFanManagedLifecycle.swift.
    static func managedApply(
        pin: PWMFanGPIOPin,
        dutyPercent: Int,
        persist: Bool
    ) -> String {
        precondition((0...100).contains(dutyPercent))
        let action: String
        if persist {
            action = """
            staged=/etc/default/.casanative-pwm-fan.new.$$
            saved=/etc/default/.casanative-pwm-fan.saved.$$
            ln /etc/default/casanative-pwm-fan "$saved"
            changed_default=0
            rollback_default() {
              result="$?"
              if [ "$result" -ne 0 ] && [ "$changed_default" = 1 ]; then
                if mv -f "$saved" /etc/default/casanative-pwm-fan; then saved=''; fi
              fi
              rm -f "$staged"
              if [ "$changed_default" = 0 ] && [ -n "$saved" ]; then rm -f "$saved"; fi
              exit "$result"
            }
            trap rollback_default EXIT
            trap 'exit 129' HUP
            trap 'exit 130' INT
            trap 'exit 143' TERM
            printf '%s\n' 'DUTY_PERCENT=\(dutyPercent)' > "$staged"
            chown 0:0 "$staged"
            chmod 0644 "$staged"
            sync -f "$staged" 2>/dev/null || sync
            mv "$staged" /etc/default/casanative-pwm-fan
            changed_default=1
            /usr/local/sbin/casanative-pwm-fan \(dutyPercent)
            changed_default=0
            rm -f "$saved"
            trap - EXIT HUP INT TERM
            """
        } else {
            action = "/usr/local/sbin/casanative-pwm-fan \(dutyPercent)"
        }
        return """
        set -eu
        \(configurationGuardShell(pin: pin))
        \(managedFilesGuardShell(pin: pin))
        \(resourceConflictGuardShell)
        \(action)
        """
    }
#endif

    static func externalSysfsApply(
        pin: PWMFanGPIOPin,
        dutyPercent: Int
    ) -> String {
        precondition((0...100).contains(dutyPercent))
        return """
        set -eu
        \(legacySetupGuardShell(pin: pin))
        \(resourceConflictGuardShell)
        \(sysfsApplyShell(pin: pin, dutyPercent: dutyPercent))
        """
    }

    static func restoreAutomatic(
        configuration: PWMFanAutomaticConfiguration
    ) -> String {
        let pin = configuration.pin
        return """
        \(PWMFanManagedLifecycleScripts.externalAutomaticLiveGuard(
            configuration: configuration
        ))
        \(trustedPigsResolutionShell(requirePresent: true))
        \(gpioFanPolicyConfigurationGuardShell(configuration: configuration))
        \(resourceConflictGuardShell)
        old_mode="$("$PIGS" mg \(pin.rawValue))"
        case "$old_mode" in ''|*[!0-9]*) exit 75;; esac
        [ "$old_mode" = \(pin.function) ]
        old_duty="$("$PIGS" gdc \(pin.rawValue))"
        old_frequency="$("$PIGS" pfg \(pin.rawValue))"
        case "$old_mode:$old_duty:$old_frequency" in *[!0-9:]*|*::* ) exit 75;; esac
        [ "$old_duty" -le 1000000 ]
        [ "$old_frequency" -gt 0 ]
        for gpio in 12 13 18 19; do
          [ "$gpio" = \(pin.rawValue) ] && continue
          other_mode="$("$PIGS" mg "$gpio")"
          case "$other_mode" in ''|*[!0-9]*) exit 75;; esac
          [ "$other_mode" = 0 ] || exit 73
        done
        rollback() {
          status="$?"
          if [ "$status" -ne 0 ]; then
            "$PIGS" hp \(pin.rawValue) "$old_frequency" "$old_duty" >/dev/null 2>&1 || :
          fi
          exit "$status"
        }
        trap rollback EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        "$PIGS" hp \(pin.rawValue) 0 0
        /sbin/modprobe -r gpio_fan
        /sbin/modprobe gpio_fan
        test -d /sys/module/gpio_fan
        verify_automatic_live \(pin.rawValue) \(configuration.turnOnCelsius) \(configuration.hysteresisCelsius)
        trap - EXIT HUP INT TERM
        """
    }

#if false // V1 provision contract retired and cannot be emitted.
    static func provision(
        pin: PWMFanGPIOPin,
        initialDutyPercent: Int
    ) -> String {
        precondition((0...100).contains(initialDutyPercent))
        let helper = managedHelper(pin: pin)
        let service = managedService
        return """
        set -eu
        CFG=''
        for candidate in /boot/firmware/config.txt /boot/config.txt; do
          if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
        done
        test -n "$CFG"
        \(provisionConflictGuardShell(pin: pin))
        test ! -e /usr/local/sbin/casanative-pwm-fan
        test ! -e /etc/default/casanative-pwm-fan
        test ! -e /etc/systemd/system/casanative-pwm-fan.service
        test ! -e /usr/local/bin/fan50.sh
        test ! -e /etc/systemd/system/fan50.service
        backup="$CFG.casanative-pwm-fan.bak"
        test ! -e "$backup"
        cp -p "$CFG" "$backup"
        changed=0
        rollback() {
          status="$?"
          if [ "$status" -ne 0 ]; then
            systemctl disable casanative-pwm-fan.service >/dev/null 2>&1 || :
            rm -f /usr/local/sbin/casanative-pwm-fan /etc/default/casanative-pwm-fan /etc/systemd/system/casanative-pwm-fan.service
            if [ "$changed" = 1 ]; then cp -p "$backup" "$CFG"; fi
            rm -f "$backup"
            systemctl daemon-reload >/dev/null 2>&1 || :
          fi
          exit "$status"
        }
        trap rollback EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        printf '\n%s\n%s\n%s\n' '# BEGIN CasaNative PWM Fan' 'dtoverlay=pwm,pin=\(pin.rawValue),func=\(pin.function)' '# END CasaNative PWM Fan' >> "$CFG"
        changed=1
        /usr/bin/printf '%s' '\(base64(helper))' | /usr/bin/base64 -d > /usr/local/sbin/casanative-pwm-fan
        chown 0:0 /usr/local/sbin/casanative-pwm-fan
        chmod 0755 /usr/local/sbin/casanative-pwm-fan
        printf '%s\n' 'DUTY_PERCENT=\(initialDutyPercent)' > /etc/default/casanative-pwm-fan
        chown 0:0 /etc/default/casanative-pwm-fan
        chmod 0644 /etc/default/casanative-pwm-fan
        /usr/bin/printf '%s' '\(base64(service))' | /usr/bin/base64 -d > /etc/systemd/system/casanative-pwm-fan.service
        chown 0:0 /etc/systemd/system/casanative-pwm-fan.service
        chmod 0644 /etc/systemd/system/casanative-pwm-fan.service
        systemctl daemon-reload
        systemctl enable casanative-pwm-fan.service
        trap - EXIT HUP INT TERM
        """
    }

    private static func managedHelper(pin: PWMFanGPIOPin) -> String {
        """
        #!/bin/sh
        # Casa Native managed PWM fan v1
        set -eu
        duty="${1:-${DUTY_PERCENT:-}}"
        case "$duty" in ''|*[!0-9]*) exit 64;; esac
        [ "$duty" -le 100 ] || exit 64
        \(configurationGuardShell(pin: pin))
        \(resourceConflictGuardShell)
        \(sysfsApplyShell(pin: pin, dutyPercentExpression: "$duty"))
        """
    }

    private static let managedService = """
    [Unit]
    Description=Casa Native managed PWM fan
    After=multi-user.target

    [Service]
    Type=oneshot
    EnvironmentFile=/etc/default/casanative-pwm-fan
    ExecStart=/usr/local/sbin/casanative-pwm-fan
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """
#endif

    private static let legacyFan50Helper = """
    #!/bin/sh
    set -eu

    chip="$(ls -d /sys/class/pwm/pwmchip* 2>/dev/null | head -n1)"
    [ -n "$chip" ] || exit 1

    if [ ! -d "$chip/pwm0" ]; then
      echo 0 > "$chip/export"
    fi

    # 25kHz period = 40000ns
    echo 40000 > "$chip/pwm0/period"
    echo 20000 > "$chip/pwm0/duty_cycle"
    echo 1 > "$chip/pwm0/enable"
    """ + "\n"

    private static let legacyFan50Service = """
    [Unit]
    Description=Set GPIO18 fan to 50% PWM
    After=multi-user.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/fan50.sh
    RemainAfterExit=yes

    [Install]
    WantedBy=multi-user.target
    """ + "\n"

    private static func sysfsApplyShell(
        pin: PWMFanGPIOPin,
        dutyPercent: Int
    ) -> String {
        sysfsApplyShell(pin: pin, dutyPercentExpression: "\(dutyPercent)")
    }

    private static func sysfsApplyShell(
        pin: PWMFanGPIOPin,
        dutyPercentExpression: String
    ) -> String {
        """
        channel='\(pin.channel)'
        chip=''
        matches=0
        for candidate in /sys/class/pwm/pwmchip*; do
          [ -d "$candidate" ] || continue
          [ -r "$candidate/npwm" ] || continue
          [ -r "$candidate/device/of_node/compatible" ] || continue
          compatible="$(tr '\\000' '\\n' < "$candidate/device/of_node/compatible" 2>/dev/null || :)"
          printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || continue
          if [ -r "$candidate/device/of_node/status" ]; then
            status="$(tr -d '\\000' < "$candidate/device/of_node/status" 2>/dev/null || :)"
            [ "$status" = okay ] || [ "$status" = ok ] || continue
          fi
          npwm="$(cat "$candidate/npwm")"
          case "$npwm" in ''|*[!0-9]*) continue;; esac
          [ "$npwm" -gt "$channel" ] || continue
          chip="$candidate"
          matches=$((matches + 1))
        done
        [ "$matches" -eq 1 ] || { echo 'PWM controller is ambiguous or cannot be verified' >&2; exit 74; }
        created=0
        if [ ! -d "$chip/pwm$channel" ]; then
          printf '%s\n' "$channel" > "$chip/export"
          created=1
          tries=0
          while [ ! -d "$chip/pwm$channel" ] && [ "$tries" -lt 20 ]; do
            sleep 0.05
            tries=$((tries + 1))
          done
        fi
        pwm="$chip/pwm$channel"
        test -d "$pwm"
        old_period="$(cat "$pwm/period" 2>/dev/null || :)"
        old_duty="$(cat "$pwm/duty_cycle" 2>/dev/null || :)"
        old_enabled="$(cat "$pwm/enable" 2>/dev/null || :)"
        case "$old_period:$old_duty:$old_enabled" in *[!0-9:]*|*::* ) exit 74;; esac
        [ "$old_enabled" = 0 ] || [ "$old_enabled" = 1 ]
        [ "$old_period" -ge 0 ]
        [ "$old_duty" -ge 0 ]
        [ "$old_period" -eq 0 ] || [ "$old_duty" -le "$old_period" ]
        modified=0
        fail_safe() {
          printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :
          printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :
          printf '%s\n' 40000 > "$pwm/period" 2>/dev/null || :
          printf '%s\n' 40000 > "$pwm/duty_cycle" 2>/dev/null || :
          printf '%s\n' 1 > "$pwm/enable" 2>/dev/null || :
        }
        rollback() {
          result="$?"
          if [ "$result" -ne 0 ] && [ "$modified" = 1 ]; then
            if [ "$created" = 0 ] && [ "$old_period" -gt 0 ]; then
              printf '%s\n' 0 > "$pwm/enable" 2>/dev/null || :
              printf '%s\n' 0 > "$pwm/duty_cycle" 2>/dev/null || :
              printf '%s\n' "$old_period" > "$pwm/period" 2>/dev/null || { fail_safe; exit "$result"; }
              printf '%s\n' "$old_duty" > "$pwm/duty_cycle" 2>/dev/null || { fail_safe; exit "$result"; }
              printf '%s\n' "$old_enabled" > "$pwm/enable" 2>/dev/null || fail_safe
            else
              fail_safe
            fi
          fi
          exit "$result"
        }
        trap rollback EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        modified=1
        [ "$old_enabled" = 0 ] || printf '%s\n' 0 > "$pwm/enable"
        printf '%s\n' 0 > "$pwm/duty_cycle"
        printf '%s\n' 40000 > "$pwm/period"
        duty=$((40000 * \(dutyPercentExpression) / 100))
        printf '%s\n' "$duty" > "$pwm/duty_cycle"
        printf '%s\n' 1 > "$pwm/enable"
        modified=0
        trap - EXIT HUP INT TERM
        """
    }

#if false // V1 app-managed block guard retired.
    private static func configurationGuardShell(pin: PWMFanGPIOPin) -> String {
        """
        CFG=''
        for candidate in /boot/firmware/config.txt /boot/config.txt; do
          if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
        done
        test -n "$CFG"
        exact="$(awk '
          $0=="# BEGIN CasaNative PWM Fan" { getline a; getline b; if(a=="dtoverlay=pwm,pin=\(pin.rawValue),func=\(pin.function)" && b=="# END CasaNative PWM Fan") n++ }
          END { print n+0 }
        ' "$CFG")"
        [ "$exact" = 1 ]
        consumers="$(grep -Ev '^[[:space:]]*#' "$CFG" | grep -Ec '^[[:space:]]*dtoverlay=(gpio-fan|pwm|pwm1|pwm-2chan|pwm-gpio|pwm-gpio-fan|pwm-ir-tx)(,|[[:space:]]*$)' || :)"
        [ "$consumers" = 1 ]
        \(noGPIOFanControllerGuardShell)
        """
    }
#endif

    private static let resourceConflictGuardShell = """
    CFG=''
    for candidate in /boot/firmware/config.txt /boot/config.txt; do
      if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
    done
    test -n "$CFG"
    if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eq '^[[:space:]]*dtparam=(audio|i2s)=on([[:space:]]*|,.*)$'; then
      echo 'Analog audio or I2S conflicts with hardware PWM' >&2
      exit 73
    fi
    if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eiq '^[[:space:]]*dtoverlay=(audremap|.*hifiberry.*|.*i2s.*|pwm-ir-tx)(,|[[:space:]]*$)'; then
      echo 'Another audio, I2S, or PWM consumer is configured' >&2
      exit 73
    fi
    """

    private static func trustedPigsResolutionShell(
        requirePresent: Bool
    ) -> String {
        """
        PIGS=''
        pigs_count=0
        for candidate in /usr/bin/pigs /usr/local/bin/pigs; do
          [ -e "$candidate" ] || continue
          [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ] || exit 75
          [ "$(stat -c %u "$candidate")" = 0 ] || exit 75
          mode="$(stat -c %a "$candidate")"
          case "$mode" in ???) :;; *) exit 75;; esac
          group="$(printf '%s' "$mode" | cut -c2)"
          other="$(printf '%s' "$mode" | cut -c3)"
          case "$group$other" in *[2367]*) exit 75;; esac
          PIGS="$candidate"
          pigs_count=$((pigs_count + 1))
        done
        [ "$pigs_count" -le 1 ]
        \(requirePresent ? "[ \"$pigs_count\" -eq 1 ]" : ":")
        """
    }

    private static func externalFanAssociationGuardShell(
        pin: PWMFanGPIOPin
    ) -> String {
        """
        fan_association=0
        if ( \(legacySetupGuardShell(pin: pin)) ); then fan_association=1; fi
        if ( \(gpioFanConfigurationGuardShell(pin: pin)); \(gpioFanDeviceTreeGuardShell(pin: pin)) ); then fan_association=1; fi
        [ "$fan_association" = 1 ]
        """
    }

#if false // V1 managed-file verifier retired with its lifecycle.
    private static func managedFilesGuardShell(pin: PWMFanGPIOPin) -> String {
        """
        test -f /usr/local/sbin/casanative-pwm-fan
        test ! -L /usr/local/sbin/casanative-pwm-fan
        [ "$(stat -c '%u:%a' /usr/local/sbin/casanative-pwm-fan)" = '0:755' ]
        test -f /etc/default/casanative-pwm-fan
        test ! -L /etc/default/casanative-pwm-fan
        [ "$(stat -c '%u:%a' /etc/default/casanative-pwm-fan)" = '0:644' ]
        [ "$(wc -l < /etc/default/casanative-pwm-fan | tr -d ' ')" = 1 ]
        grep -Eq '^DUTY_PERCENT=([0-9]|[1-9][0-9]|100)$' /etc/default/casanative-pwm-fan
        test -f /etc/systemd/system/casanative-pwm-fan.service
        test ! -L /etc/systemd/system/casanative-pwm-fan.service
        [ "$(stat -c '%u:%a' /etc/systemd/system/casanative-pwm-fan.service)" = '0:644' ]
        /usr/bin/printf '%s' '\(base64(managedHelper(pin: pin)))' | /usr/bin/base64 -d | cmp -s - /usr/local/sbin/casanative-pwm-fan
        /usr/bin/printf '%s' '\(base64(managedService))' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/casanative-pwm-fan.service
        """
    }
#endif

    private static func legacySetupGuardShell(pin: PWMFanGPIOPin) -> String {
        guard pin == .gpio18 else { return "exit 73" }
        return """
        CFG=''
        for candidate in /boot/firmware/config.txt /boot/config.txt; do
          if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
        done
        test -n "$CFG"
        exact="$(awk '
          $0=="# BEGIN fan50" { getline a; getline b; if(a=="dtoverlay=pwm,pin=18,func=2" && b=="# END fan50") n++ }
          END { print n+0 }
        ' "$CFG")"
        [ "$exact" = 1 ]
        consumers="$(grep -Ev '^[[:space:]]*#' "$CFG" | grep -Ec '^[[:space:]]*dtoverlay=(pwm|pwm1|pwm-2chan|pwm-gpio|pwm-ir-tx)(,|[[:space:]]*$)' || :)"
        [ "$consumers" = 1 ]
        \(noGPIOFanControllerGuardShell)
        test -f /usr/local/bin/fan50.sh
        test ! -L /usr/local/bin/fan50.sh
        [ "$(stat -c '%u:%a' /usr/local/bin/fan50.sh)" = '0:755' ]
        /usr/bin/printf '%s' '\(base64(legacyFan50Helper))' | /usr/bin/base64 -d | cmp -s - /usr/local/bin/fan50.sh
        test -f /etc/systemd/system/fan50.service
        test ! -L /etc/systemd/system/fan50.service
        [ "$(stat -c '%u:%a' /etc/systemd/system/fan50.service)" = '0:644' ]
        /usr/bin/printf '%s' '\(base64(legacyFan50Service))' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/fan50.service
        """
    }

    private static let noGPIOFanControllerGuardShell = """
    if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eq '^[[:space:]]*dtoverlay=gpio-fan(,|[[:space:]]*$)'; then
      echo 'Automatic gpio-fan and Linux PWM cannot be controlled together' >&2
      exit 73
    fi
    for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
      [ -r "$node/compatible" ] || continue
      if tr '\000' '\n' < "$node/compatible" 2>/dev/null | grep -qx gpio-fan; then
        echo 'A live automatic gpio-fan controller conflicts with Linux PWM' >&2
        exit 73
      fi
    done
    """

    private static func gpioFanConfigurationGuardShell(
        pin: PWMFanGPIOPin
    ) -> String {
        """
        CFG=''
        for candidate in /boot/firmware/config.txt /boot/config.txt; do
          if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
        done
        test -n "$CFG"
        configured="$(awk '
          /^[[:space:]]*#/ { next }
          /^[[:space:]]*dtoverlay=gpio-fan(,|[[:space:]]*$)/ {
            line=$0; sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]/, "", line)
            pin=12; seen=0; bad=0; n=split(line,a,",")
            for(i=2;i<=n;i++){
              count=split(a[i],b,"=")
              if(count!=2) bad=1
              else if(b[1]=="gpiopin") { if(seen) bad=1; pin=b[2]; seen=1 }
            }
            if(!bad && pin ~ /^[0-9]+$/) print pin; else print "invalid"
          }
        ' "$CFG")"
        [ "$configured" = \(pin.rawValue) ]
        """
    }

    private static func gpioFanPolicyConfigurationGuardShell(
        configuration: PWMFanAutomaticConfiguration
    ) -> String {
        """
        CFG=''
        if [ -e /boot/firmware/config.txt ] || [ -L /boot/firmware/config.txt ]; then
          [ -f /boot/firmware/config.txt ] && [ ! -L /boot/firmware/config.txt ] || exit 75; CFG=/boot/firmware/config.txt
        elif [ -e /boot/config.txt ] || [ -L /boot/config.txt ]; then
          [ -f /boot/config.txt ] && [ ! -L /boot/config.txt ] || exit 75; CFG=/boot/config.txt
        else exit 75; fi
        [ "$(stat -c '%u:%g:%h:%F' "$CFG" 2>/dev/null || :)" = '0:0:1:regular file' ]
        configured="$(awk '
          /^[[:space:]]*#/ { next }
          /^[[:space:]]*dtoverlay=gpio-fan(,|[[:space:]]*$)/ {
            line=$0; sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]/, "", line)
            pin=12; temp=55000; hyst=10000
            seenp=0; seent=0; seenh=0; bad=0; n=split(line,a,",")
            for(i=2;i<=n;i++){
              count=split(a[i],b,"=")
              if(count!=2) bad=1
              else if(b[1]=="gpiopin"&&!seenp){pin=b[2];seenp=1}
              else if(b[1]=="temp"&&!seent){temp=b[2];seent=1}
              else if(b[1]=="hyst"&&!seenh){hyst=b[2];seenh=1}
              else bad=1
            }
            if(!bad && pin ~ /^[0-9]+$/ && temp ~ /^[0-9]+$/ && hyst ~ /^[0-9]+$/) print pin "|" temp "|" hyst; else print "invalid"
          }
        ' "$CFG")"
        [ "$configured" = '\(configuration.pin.rawValue)|\(configuration.turnOnCelsius * 1_000)|\(configuration.hysteresisCelsius * 1_000)' ]
        """
    }

    private static func gpioFanDeviceTreeGuardShell(
        pin: PWMFanGPIOPin
    ) -> String {
        """
        found=0
        GPIO_FAN_NODE=''
        for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
          [ -r "$node/compatible" ] || continue
          tr '\\000' '\\n' < "$node/compatible" 2>/dev/null | grep -qx gpio-fan || continue
          [ -r "$node/gpios" ] || exit 75
          hex="$(od -An -tx1 -N12 "$node/gpios" 2>/dev/null | tr -d ' \\n')"
          [ "${#hex}" = 24 ] || exit 75
          cell="$(printf '%s' "$hex" | cut -c9-16)"
          [ "$cell" = '000000\(String(format: "%02x", pin.rawValue))' ] || exit 75
          found=$((found + 1))
          GPIO_FAN_NODE="$node"
        done
        [ "$found" = 1 ]
        """
    }

#if false // V1 provision-only conflict probe retired.
    private static func provisionConflictGuardShell(
        pin: PWMFanGPIOPin
    ) -> String {
        """
        if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eiq '^[[:space:]]*dtoverlay=(gpio-fan|pwm|pwm1|pwm-2chan|pwm-gpio|pwm-gpio-fan|pwm-ir-tx|audremap|.*hifiberry.*|.*i2s.*)(,|[[:space:]]*$)'; then
          echo 'Existing fan, PWM, audio, or I2S overlay detected' >&2
          exit 73
        fi
        if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eq '^[[:space:]]*dtparam=(audio|i2s)=on([[:space:]]*|,.*)$'; then
          echo 'Analog audio or I2S is enabled' >&2
          exit 73
        fi
        for active in /sys/class/pwm/pwmchip*/pwm*; do
          [ -d "$active" ] || continue
          echo 'An exported PWM channel already exists' >&2
          exit 73
        done
        for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
          [ -r "$node/compatible" ] || continue
          if tr '\\000' '\\n' < "$node/compatible" 2>/dev/null | grep -qx gpio-fan; then
            echo 'An automatic gpio-fan controller is active' >&2
            exit 73
          fi
        done
        \(trustedPigsResolutionShell(requirePresent: false))
        if [ "$pigs_count" = 1 ]; then
          version="$("$PIGS" pigpv 2>/dev/null || :)"
          case "$version" in ''|*[!0-9]*) exit 73;; esac
          [ "$version" -ge 79 ] || exit 73
          for gpio in 12 13 18 19; do
            mode="$("$PIGS" mg "$gpio" 2>/dev/null || :)"
            case "$mode" in ''|*[!0-9]*) exit 73;; esac
            [ "$mode" = 0 ] || { echo 'A supported GPIO is already in use' >&2; exit 73; }
          done
        fi
        """
    }
#endif

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

#if false // V2 detection script retired; V3 privileged detection is canonical.
    private static let detectionShell: String = {
        let helper12 = base64(managedHelper(pin: .gpio12))
        let helper13 = base64(managedHelper(pin: .gpio13))
        let helper18 = base64(managedHelper(pin: .gpio18))
        let helper19 = base64(managedHelper(pin: .gpio19))
        let service = base64(managedService)
        let legacyHelper = base64(legacyFan50Helper)
        let legacyService = base64(legacyFan50Service)
        return #"""
set -eu
CFG=''
for candidate in /boot/firmware/config.txt /boot/config.txt; do
  if [ -f "$candidate" ]; then CFG="$candidate"; break; fi
done
emit() { printf '%s\t%s\n' "$1" "$2"; }
printf '%s\n' CASANATIVE_PWM_FAN_V2
emit config "$([ -n "$CFG" ] && printf 1 || printf 0)"
overlay=''
legacy_block=0
managed_block=0
gpio_fan_config=0
gpio_fan_config_pin=''
if [ -n "$CFG" ]; then
  overlay="$(awk '
    /^[[:space:]]*#/ { next }
    {
      line=$0; sub(/[[:space:]]*#.*/, "", line)
      sub(/^[[:space:]]*/, "", line); sub(/[[:space:]]*$/, "", line)
    }
    line ~ /^dtoverlay=(pwm1|pwm-2chan|pwm-gpio)(,|$)/ {
      print "unsupported"; next
    }
    line == "dtoverlay=pwm" {
      print "18:2"; next
    }
    line ~ /^dtoverlay=pwm,/ {
      if(line ~ /[[:space:]]/) { print "unsupported"; next }
      pin=18; func=2; seenpin=0; seenfunc=0; bad=0; n=split(line,a,",")
      for(i=2;i<=n;i++){
        count=split(a[i],b,"=")
        if(count!=2) bad=1
        else if(b[1]=="pin" && !seenpin){pin=b[2]; seenpin=1}
        else if(b[1]=="func" && !seenfunc){func=b[2]; seenfunc=1}
        else bad=1
      }
      if(!bad && pin ~ /^[0-9]+$/ && func ~ /^[0-9]+$/) print pin ":" func; else print "unsupported"
    }
  ' "$CFG" | paste -sd, -)"
  legacy_markers="$(grep -Ec '^# (BEGIN|END) fan50$' "$CFG" || :)"
  legacy_exact="$(awk '$0=="# BEGIN fan50" { getline a; getline b; if(a=="dtoverlay=pwm,pin=18,func=2" && b=="# END fan50") n++ } END{print n+0}' "$CFG")"
  case "$legacy_markers:$legacy_exact" in 0:0) legacy_block=0;; 2:1) legacy_block=1;; *) legacy_block=x;; esac
  managed_markers="$(grep -Ec '^# (BEGIN|END) CasaNative PWM Fan$' "$CFG" || :)"
  managed_exact="$(awk '$0=="# BEGIN CasaNative PWM Fan" { getline a; getline b; if(a ~ /^dtoverlay=pwm,pin=(12|13|18|19),func=(2|4)$/ && b=="# END CasaNative PWM Fan") n++ } END{print n+0}' "$CFG")"
  case "$managed_markers:$managed_exact" in 0:0) managed_block=0;; 2:1) managed_block=1;; *) managed_block=x;; esac
  gpio_fan_lines="$(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*dtoverlay=gpio-fan(,|[[:space:]]*$)/ {
      line=$0; sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]/, "", line)
      pin=12; seen=0; bad=0; n=split(line,a,",")
      for(i=2;i<=n;i++){
        count=split(a[i],b,"=")
        if(count!=2) bad=1
        else if(b[1]=="gpiopin") { if(seen) bad=1; pin=b[2]; seen=1 }
      }
      if(!bad && pin ~ /^[0-9]+$/) print pin; else print "unsupported"
    }
  ' "$CFG")"
  gpio_fan_count="$(printf '%s\n' "$gpio_fan_lines" | awk 'NF{n++} END{print n+0}')"
  if [ "$gpio_fan_count" = 1 ]; then
    case "$gpio_fan_lines" in 12|13|18|19) gpio_fan_config=1; gpio_fan_config_pin="$gpio_fan_lines";; *) gpio_fan_config=x;; esac
  elif [ "$gpio_fan_count" -gt 1 ]; then gpio_fan_config=x; fi
fi
emit overlay "$overlay"
resource_conflict=0
if [ -n "$CFG" ]; then
  if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eq '^[[:space:]]*dtparam=(audio|i2s)=on([[:space:]]*|,.*)$'; then resource_conflict=1; fi
  if grep -Ev '^[[:space:]]*#' "$CFG" | grep -Eiq '^[[:space:]]*dtoverlay=(audremap|.*hifiberry.*|.*i2s.*|pwm-ir-tx)(,|[[:space:]]*$)'; then resource_conflict=1; fi
fi
emit resource_conflict "$resource_conflict"
emit legacy_block "$legacy_block"
legacy_script=0
if [ -e /usr/local/bin/fan50.sh ]; then
  if [ -f /usr/local/bin/fan50.sh ] && [ ! -L /usr/local/bin/fan50.sh ] && [ "$(stat -c '%u:%a' /usr/local/bin/fan50.sh 2>/dev/null || :)" = '0:755' ] && /usr/bin/printf '%s' '\#(legacyHelper)' | /usr/bin/base64 -d | cmp -s - /usr/local/bin/fan50.sh; then legacy_script=1; else legacy_script=x; fi
fi
legacy_service=0
if [ -e /etc/systemd/system/fan50.service ]; then
  if [ -f /etc/systemd/system/fan50.service ] && [ ! -L /etc/systemd/system/fan50.service ] && [ "$(stat -c '%u:%a' /etc/systemd/system/fan50.service 2>/dev/null || :)" = '0:644' ] && /usr/bin/printf '%s' '\#(legacyService)' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/fan50.service; then legacy_service=1; else legacy_service=x; fi
fi
emit legacy_script "$legacy_script"
emit legacy_service "$legacy_service"
emit managed_block "$managed_block"
managed_helper=0
if [ -e /usr/local/sbin/casanative-pwm-fan ]; then
  expected=''
  case "$overlay" in
    12:4) expected='\#(helper12)';;
    13:4) expected='\#(helper13)';;
    18:2) expected='\#(helper18)';;
    19:2) expected='\#(helper19)';;
  esac
  if [ -n "$expected" ] && [ -f /usr/local/sbin/casanative-pwm-fan ] && [ ! -L /usr/local/sbin/casanative-pwm-fan ] && [ "$(stat -c '%u:%a' /usr/local/sbin/casanative-pwm-fan 2>/dev/null || :)" = '0:755' ] && /usr/bin/printf '%s' "$expected" | /usr/bin/base64 -d | cmp -s - /usr/local/sbin/casanative-pwm-fan; then managed_helper=1; else managed_helper=x; fi
fi
managed_defaults=0
if [ -e /etc/default/casanative-pwm-fan ]; then
  if [ -f /etc/default/casanative-pwm-fan ] && [ ! -L /etc/default/casanative-pwm-fan ] && [ "$(stat -c '%u:%a' /etc/default/casanative-pwm-fan 2>/dev/null || :)" = '0:644' ] && [ "$(wc -l < /etc/default/casanative-pwm-fan | tr -d ' ')" = 1 ] && grep -Eq '^DUTY_PERCENT=([0-9]|[1-9][0-9]|100)$' /etc/default/casanative-pwm-fan 2>/dev/null; then managed_defaults=1; else managed_defaults=x; fi
fi
managed_service=0
if [ -e /etc/systemd/system/casanative-pwm-fan.service ]; then
  if [ -f /etc/systemd/system/casanative-pwm-fan.service ] && [ ! -L /etc/systemd/system/casanative-pwm-fan.service ] && [ "$(stat -c '%u:%a' /etc/systemd/system/casanative-pwm-fan.service 2>/dev/null || :)" = '0:644' ] && /usr/bin/printf '%s' '\#(service)' | /usr/bin/base64 -d | cmp -s - /etc/systemd/system/casanative-pwm-fan.service; then managed_service=1; else managed_service=x; fi
fi
emit managed_helper "$managed_helper"
emit managed_defaults "$managed_defaults"
emit managed_service "$managed_service"
emit gpio_fan_config "$gpio_fan_config"
emit gpio_fan_config_pin "$gpio_fan_config_pin"
gpio_fan_live=0
gpio_fan_live_pin=''
for node in /sys/firmware/devicetree/base/* /sys/firmware/devicetree/base/*/*; do
  [ -r "$node/compatible" ] || continue
  if tr '\000' '\n' < "$node/compatible" 2>/dev/null | grep -qx 'gpio-fan'; then
    [ -r "$node/gpios" ] || { gpio_fan_live=x; break; }
    hex="$(od -An -tx1 -N12 "$node/gpios" 2>/dev/null | tr -d ' \n')"
    [ "${#hex}" = 24 ] || { gpio_fan_live=x; break; }
    cell="$(printf '%s' "$hex" | cut -c9-16)"
    case "$cell" in
      0000000c) pin=12;; 0000000d) pin=13;; 00000012) pin=18;; 00000013) pin=19;; *) gpio_fan_live=x; break;;
    esac
    if [ "$gpio_fan_live" = 1 ]; then gpio_fan_live=x; break; fi
    gpio_fan_live=1; gpio_fan_live_pin="$pin"
  fi
done
emit gpio_fan_live "$gpio_fan_live"
emit gpio_fan_live_pin "$gpio_fan_live_pin"
pigs_state=none; pigs_path=''; pig_ver=''; pig_pin=''; pig_duty=''; pig_freq=''; pig_mode=''
pigs_count=0
for candidate in /usr/bin/pigs /usr/local/bin/pigs; do
  [ -e "$candidate" ] || continue
  pigs_count=$((pigs_count + 1))
  if [ ! -f "$candidate" ] || [ -L "$candidate" ] || [ ! -x "$candidate" ]; then pigs_state=invalid; continue; fi
  [ "$(stat -c %u "$candidate" 2>/dev/null || :)" = 0 ] || { pigs_state=invalid; continue; }
  file_mode="$(stat -c %a "$candidate" 2>/dev/null || :)"
  case "$file_mode" in ???) :;; *) pigs_state=invalid; continue;; esac
  group="$(printf '%s' "$file_mode" | cut -c2)"; other="$(printf '%s' "$file_mode" | cut -c3)"
  case "$group$other" in *[2367]*) pigs_state=invalid; continue;; esac
  pigs_path="$candidate"
done
if [ "$pigs_count" -gt 1 ]; then pigs_state=invalid; pigs_path=''; fi
if [ "$pigs_count" = 1 ] && [ "$pigs_state" != invalid ]; then
  pig_ver="$("$pigs_path" pigpv 2>/dev/null || :)"
  case "$pig_ver" in ''|*[!0-9]*) pigs_state=unreachable; pig_ver='';; *)
    if [ "$pig_ver" -lt 79 ]; then
      pigs_state=unsupported; pig_ver=''
    else
      pigs_state=inactive
      for pin in 12 13 18 19; do
        case "$pin" in 12|13) expected_mode=4;; 18|19) expected_mode=2;; esac
        m="$("$pigs_path" mg "$pin" 2>/dev/null || :)"
        case "$m" in ''|*[!0-9]*) pigs_state=unreachable; break;; esac
        [ "$m" -le 7 ] || { pigs_state=unreachable; break; }
        if [ "$m" = 0 ]; then continue; fi
        if [ "$m" != "$expected_mode" ]; then
          if [ "$gpio_fan_live" = 1 ] && [ "$gpio_fan_live_pin" = "$pin" ]; then continue; fi
          pigs_state=occupied; break
        fi
        d="$("$pigs_path" gdc "$pin" 2>/dev/null || :)"
        f="$("$pigs_path" pfg "$pin" 2>/dev/null || :)"
        case "$d:$f" in *[!0-9:]*|*::* ) pigs_state=unreachable; break;; esac
        [ "$d" -le 1000000 ] && [ "$f" -gt 0 ] || { pigs_state=unreachable; break; }
        if [ -n "$pig_pin" ]; then pigs_state=ambiguous; pig_pin=''; pig_duty=''; pig_freq=''; pig_mode=''; break; fi
        pigs_state=active; pig_pin="$pin"; pig_duty="$d"; pig_freq="$f"; pig_mode="$m"
      done
    fi
  esac
fi
case "$pigs_state" in active) :;; *) pig_pin=''; pig_duty=''; pig_freq=''; pig_mode='';; esac
emit pigs "$pigs_state"
emit pigs_path "$pigs_path"
case "$pigs_state" in active|inactive) pig_ver_out="$pig_ver";; *) pig_ver_out='';; esac
emit pigpio_version "$pig_ver_out"
emit pigpio_pin "$pig_pin"
emit pigpio_duty "$pig_duty"
emit pigpio_frequency "$pig_freq"
emit pigpio_mode "$pig_mode"
sys_count=0; sys_pin=''; sys_period=''; sys_duty=''; sys_enabled=''
for pwm in /sys/class/pwm/pwmchip*/pwm*; do
  [ -d "$pwm" ] || continue
  case "${pwm##*/}" in pwm0) channel=0;; pwm1) channel=1;; *) sys_count=x; break;; esac
  chip="${pwm%/*}"
  [ -r "$chip/device/of_node/compatible" ] || { sys_count=x; break; }
  compatible="$(tr '\000' '\n' < "$chip/device/of_node/compatible" 2>/dev/null || :)"
  printf '%s\n' "$compatible" | grep -Eq '^(brcm,bcm2835-pwm|brcm,bcm2711-pwm|brcm,bcm2712-pwm|raspberrypi,rp1-pwm)$' || { sys_count=x; break; }
  period="$(cat "$pwm/period" 2>/dev/null || :)"; duty="$(cat "$pwm/duty_cycle" 2>/dev/null || :)"; enabled="$(cat "$pwm/enable" 2>/dev/null || :)"
  case "$period:$duty:$enabled" in *[!0-9:]*|*::* ) sys_count=x; break;; esac
  [ "$period" -gt 0 ] && [ "$duty" -le "$period" ] && { [ "$enabled" = 0 ] || [ "$enabled" = 1 ]; } || { sys_count=x; break; }
  if [ "$channel" = 0 ]; then
    case "$overlay" in 12:4) sys_pin=12;; 18:2) sys_pin=18;; *) sys_count=x; break;; esac
  else
    case "$overlay" in 13:4) sys_pin=13;; 19:2) sys_pin=19;; *) sys_count=x; break;; esac
  fi
  sys_count=$((sys_count + 1)); sys_period="$period"; sys_duty="$duty"; sys_enabled="$enabled"
  [ "$sys_count" -le 1 ] || { sys_count=x; break; }
done
emit sysfs_count "$sys_count"
emit sysfs_pin "$([ "$sys_count" = 1 ] && printf '%s' "$sys_pin" || :)"
emit sysfs_period "$([ "$sys_count" = 1 ] && printf '%s' "$sys_period" || :)"
emit sysfs_duty "$([ "$sys_count" = 1 ] && printf '%s' "$sys_duty" || :)"
emit sysfs_enabled "$([ "$sys_count" = 1 ] && printf '%s' "$sys_enabled" || :)"
"""#
    }()
#endif
}
