import XCTest
@testable import CasaNative

final class FanControlScreenModelTests: XCTestCase {
    @MainActor
    func testAbsentStatusBuildsOnlyBoundedManualAndAutomaticSelections() async throws {
        let controller = FanScreenControllerFake(
            detected: fanStatus(ownership: .absent)
        )
        let model = PWMFanScreenModel(controller: controller)

        await model.detectIfNeeded()

        model.selectedMode = .manual
        model.selectedPin = .gpio19
        model.selectedDutyPercent = 0
        XCTAssertEqual(
            model.selectedConfiguration,
            .manual(
                try PWMFanManualConfiguration(
                    pin: .gpio19,
                    dutyPercent: 0
                )
            )
        )

        model.selectedDutyPercent = -1
        XCTAssertNil(model.selectedConfiguration)
        model.selectedDutyPercent = 101
        XCTAssertNil(model.selectedConfiguration)

        model.selectedMode = .automatic
        model.selectedPin = .gpio12
        model.selectedTurnOnCelsius = 40
        model.selectedHysteresisCelsius = 10
        XCTAssertEqual(model.selectedTurnOffCelsius, 30)
        XCTAssertEqual(
            model.selectedConfiguration,
            .automatic(
                try PWMFanAutomaticConfiguration(
                    pin: .gpio12,
                    turnOnCelsius: 40,
                    hysteresisCelsius: 10
                )
            )
        )

        model.selectedHysteresisCelsius = 11
        XCTAssertEqual(model.selectedTurnOffCelsius, 29)
        XCTAssertNil(model.selectedConfiguration)

        model.selectedTurnOnCelsius = 75
        model.selectedHysteresisCelsius = 15
        XCTAssertEqual(model.selectedTurnOffCelsius, 60)
        XCTAssertNotNil(model.selectedConfiguration)
    }

    @MainActor
    func testStableManagedDetectionSeedsActiveManualAndAutomaticConfigurations() async throws {
        let manual = try PWMFanConfiguration.manual(
            PWMFanManualConfiguration(pin: .gpio13, dutyPercent: 75)
        )
        let manualController = FanScreenControllerFake(
            detected: fanStatus(
                ownership: .managed,
                backend: .sysfs,
                pin: .gpio18,
                dutyPercent: 10,
                activeConfiguration: manual
            )
        )
        let manualModel = PWMFanScreenModel(controller: manualController)

        await manualModel.detectIfNeeded()

        XCTAssertEqual(manualModel.selectedMode, .manual)
        XCTAssertEqual(manualModel.selectedPin, .gpio13)
        XCTAssertEqual(manualModel.selectedDutyPercent, 75)
        XCTAssertEqual(manualModel.selectedConfiguration, manual)

        let automatic = try PWMFanConfiguration.automatic(
            PWMFanAutomaticConfiguration(
                pin: .gpio12,
                turnOnCelsius: 63,
                hysteresisCelsius: 8
            )
        )
        let automaticController = FanScreenControllerFake(
            detected: fanStatus(
                ownership: .managed,
                backend: .gpioFan,
                activeConfiguration: automatic
            )
        )
        let automaticModel = PWMFanScreenModel(controller: automaticController)

        await automaticModel.detectIfNeeded()

        XCTAssertEqual(automaticModel.selectedMode, .automatic)
        XCTAssertEqual(automaticModel.selectedPin, .gpio12)
        XCTAssertEqual(automaticModel.selectedTurnOnCelsius, 63)
        XCTAssertEqual(automaticModel.selectedHysteresisCelsius, 8)
        XCTAssertEqual(automaticModel.selectedTurnOffCelsius, 55)
        XCTAssertEqual(automaticModel.selectedConfiguration, automatic)
    }

    @MainActor
    func testTransitionPhaseSeedsLiveSideAndEnforcesMutationGates() async throws {
        let source = try PWMFanConfiguration.manual(
            PWMFanManualConfiguration(pin: .gpio18, dutyPercent: 50)
        )
        let target = try PWMFanConfiguration.automatic(
            PWMFanAutomaticConfiguration(
                pin: .gpio18,
                turnOnCelsius: 60,
                hysteresisCelsius: 7
            )
        )
        let prepared = PWMFanTransitionState(
            source: source,
            target: .configuration(target),
            phase: .prepared,
            requirement: .reboot,
            kind: .configurationChange
        )
        let preparedController = FanScreenControllerFake(
            detected: fanStatus(
                ownership: .managed,
                backend: .sysfs,
                activeConfiguration: source,
                transition: prepared
            )
        )
        let preparedModel = PWMFanScreenModel(controller: preparedController)

        await preparedModel.detectIfNeeded()

        XCTAssertEqual(preparedModel.status?.transition?.phase, .prepared)
        XCTAssertEqual(preparedModel.selectedConfiguration, source)
        await preparedModel.apply(dutyPercent: 75, persist: true)
        XCTAssertEqual(
            preparedModel.errorMessage,
            "Manual duty is unavailable during a prepared change."
        )
        await preparedModel.finalizePreparedChange()
        XCTAssertEqual(
            preparedModel.errorMessage,
            "The prepared target must boot before it can be finalized."
        )
        let preparedMutationCalls = await preparedController.mutationCallCount()
        XCTAssertEqual(preparedMutationCalls, 0)

        let booted = PWMFanTransitionState(
            source: source,
            target: .configuration(target),
            phase: .bootedAwaitingConfirmation,
            requirement: .reboot,
            kind: .configurationChange
        )
        let stableTarget = fanStatus(
            ownership: .managed,
            backend: .gpioFan,
            activeConfiguration: target
        )
        let bootedController = FanScreenControllerFake(
            detected: fanStatus(
                ownership: .managed,
                backend: .gpioFan,
                activeConfiguration: target,
                transition: booted
            ),
            mutation: .returning(stableTarget)
        )
        let bootedModel = PWMFanScreenModel(controller: bootedController)

        await bootedModel.detectIfNeeded()

        XCTAssertEqual(
            bootedModel.status?.transition?.phase,
            .bootedAwaitingConfirmation
        )
        XCTAssertEqual(bootedModel.selectedConfiguration, target)
        await bootedModel.finalizePreparedChange()
        let bootedMutationCalls = await bootedController.mutationCallCount()
        XCTAssertEqual(bootedMutationCalls, 1)
        XCTAssertNil(bootedModel.status?.transition)
        XCTAssertEqual(
            bootedModel.noticeMessage,
            "Prepared target finalized."
        )
    }

    @MainActor
    func testChangedButUnverifiedMutationStartsQuarantineAndBlocksDetection() async {
        let detected = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 50
        )
        let unverified = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 75,
            verification: .changedButUnverified
        )
        let controller = FanScreenControllerFake(
            detected: detected,
            mutation: .returning(unverified)
        )
        let model = PWMFanScreenModel(
            controller: controller,
            mutationQuarantine: .seconds(25)
        )

        await model.detectIfNeeded()
        let verificationCycleBeforeMutation = model.verificationCycle
        await model.apply(dutyPercent: 75, persist: false)

        XCTAssertTrue(model.needsVerification)
        XCTAssertTrue(model.isDetectionQuarantined)
        XCTAssertNotEqual(model.verificationCycle, verificationCycleBeforeMutation)
        XCTAssertEqual(model.status?.verification, .changedButUnverified)
        XCTAssertEqual(
            model.noticeMessage,
            "The command may have reached the server, but its result could not be verified. Wait for detection and check cooling."
        )
        await model.detect(force: true)
        let detectCalls = await controller.detectCallCount()
        XCTAssertEqual(detectCalls, 1)
    }

    @MainActor
    func testInterruptedMutationBecomesUnknownAndIgnoresLateSuccess() async {
        let detected = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 50
        )
        let lateSuccess = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 75
        )
        let controller = FanScreenControllerFake(
            detected: detected,
            mutation: .suspending
        )
        let model = PWMFanScreenModel(
            controller: controller,
            mutationQuarantine: .seconds(25)
        )

        await model.detectIfNeeded()
        let mutation = Task { @MainActor in
            await model.apply(dutyPercent: 75, persist: false)
        }
        await controller.waitForMutationStart()

        model.cancelCurrentOperation()

        XCTAssertEqual(model.status?.ownership, .conflict)
        XCTAssertEqual(model.status?.verification, .changedButUnverified)
        XCTAssertTrue(model.status?.recoveryRequired == true)
        XCTAssertTrue(model.needsVerification)
        XCTAssertTrue(model.isDetectionQuarantined)
        XCTAssertNil(model.noticeMessage)
        XCTAssertEqual(
            model.errorMessage,
            "Refresh fan detection and verify the expected output before another change."
        )

        await controller.resumeMutation(returning: lateSuccess)
        await mutation.value

        XCTAssertEqual(model.status?.ownership, .conflict)
        XCTAssertEqual(model.status?.verification, .changedButUnverified)
        XCTAssertNil(model.noticeMessage)
    }

    @MainActor
    func testVerifiedMutationKeepsSuccessSemantics() async {
        let detected = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 50
        )
        let verified = fanStatus(
            ownership: .external,
            backend: .pigpio,
            pin: .gpio18,
            dutyPercent: 75
        )
        let controller = FanScreenControllerFake(
            detected: detected,
            mutation: .returning(verified)
        )
        let model = PWMFanScreenModel(controller: controller)

        await model.detectIfNeeded()
        await model.apply(dutyPercent: 75, persist: false)

        XCTAssertEqual(model.status?.verification, .verified)
        XCTAssertFalse(model.status?.recoveryRequired == true)
        XCTAssertFalse(model.needsVerification)
        XCTAssertFalse(model.isDetectionQuarantined)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.noticeMessage, "PWM duty set to 75%.")
    }

    @MainActor
    func testEveryParserProvenRecoveryActionRoutesOnlyItsMatchingCall() async {
        let cases: [(PWMFanRecoveryAction, FanScreenControllerCall)] = [
            (.cancelPreparedChange, .cancelPreparedChange),
            (.finalizePreparedChange, .finalizePreparedChange),
            (.completeUninstall, .uninstallManaged),
            (.completeLegacyConversion, .convertExactLegacyFan50),
            (.completeLegacyRestore, .resolveLegacyBackup(.restore)),
            (.completeLegacyDiscard, .resolveLegacyBackup(.discard)),
            (.completeManagedApply, .completeManagedApply),
            (.completeStateCleanup, .completeStateCleanup),
        ]

        for (action, expectedCall) in cases {
            let recovery = fanStatus(
                ownership: .conflict,
                verification: .changedButUnverified,
                recoveryRequired: true,
                recoveryAction: action
            )
            let verified = fanStatus(ownership: .absent)
            let controller = FanScreenControllerFake(
                detected: recovery,
                mutation: .returning(verified)
            )
            let model = PWMFanScreenModel(
                controller: controller,
                mutationQuarantine: .zero
            )

            await model.detectIfNeeded()
            await model.recover(action)

            let calls = await controller.mutationCallsSnapshot()
            XCTAssertEqual(calls, [expectedCall], "Wrong route for \(action)")
            XCTAssertFalse(model.needsVerification)
            XCTAssertNil(model.errorMessage)
            XCTAssertNotNil(model.noticeMessage)
        }
    }

    @MainActor
    func testPostDelayRecoveryDetectionDoesNotRestartQuarantine() async {
        let recovery = fanStatus(
            ownership: .conflict,
            recoveryRequired: true,
            recoveryAction: .finalizePreparedChange
        )
        let controller = FanScreenControllerFake(detected: recovery)
        let model = PWMFanScreenModel(
            controller: controller,
            mutationQuarantine: .zero
        )

        await model.detectIfNeeded()
        let firstQuarantineCycle = model.verificationCycle

        await model.detectWhenSafeIfNeeded()

        XCTAssertEqual(model.verificationCycle, firstQuarantineCycle)
        XCTAssertFalse(model.isDetectionQuarantined)
        XCTAssertEqual(
            model.status?.recoveryAction,
            .finalizePreparedChange
        )
        let detectCalls = await controller.detectCallCount()
        XCTAssertEqual(detectCalls, 2)
    }

    @MainActor
    func testRecoveryRejectsAStaleOrMismatchedAction() async {
        let recovery = fanStatus(
            ownership: .conflict,
            recoveryRequired: true,
            recoveryAction: .finalizePreparedChange
        )
        let controller = FanScreenControllerFake(detected: recovery)
        let model = PWMFanScreenModel(
            controller: controller,
            mutationQuarantine: .zero
        )

        await model.detectIfNeeded()
        await model.recover(.cancelPreparedChange)

        let calls = await controller.mutationCallsSnapshot()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            "Recovery changed. Refresh detection before continuing."
        )
    }
}

private enum FanScreenMutationResponse: Sendable {
    case returning(PWMFanStatus)
    case failing(PWMFanError)
    case suspending
}

private enum FanScreenControllerCall: Equatable, Sendable {
    case provision
    case prepareConfigurationChange
    case cancelPreparedChange
    case finalizePreparedChange
    case prepareRollback
    case uninstallManaged
    case convertExactLegacyFan50
    case resolveLegacyBackup(PWMFanLegacyBackupResolution)
    case completeManagedApply
    case completeStateCleanup
    case apply
    case restoreAutomatic
}

private actor FanScreenControllerFake: PWMFanControlling {
    private let detected: PWMFanStatus
    private let mutation: FanScreenMutationResponse
    private var detectCalls = 0
    private var mutationCalls: [FanScreenControllerCall] = []
    private var pendingMutation: CheckedContinuation<PWMFanStatus, any Error>?
    private var mutationStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        detected: PWMFanStatus,
        mutation: FanScreenMutationResponse? = nil
    ) {
        self.detected = detected
        self.mutation = mutation ?? .returning(detected)
    }

    func detect() async throws -> PWMFanStatus {
        detectCalls += 1
        return detected
    }

    func provision(configuration: PWMFanConfiguration) async throws -> PWMFanStatus {
        try await respondToMutation(.provision)
    }

    func provision(
        pin: PWMFanGPIOPin,
        initialDutyPercent: Int
    ) async throws -> PWMFanStatus {
        try await respondToMutation(.provision)
    }

    func prepareConfigurationChange(
        to configuration: PWMFanConfiguration
    ) async throws -> PWMFanStatus {
        try await respondToMutation(.prepareConfigurationChange)
    }

    func cancelPreparedChange() async throws -> PWMFanStatus {
        try await respondToMutation(.cancelPreparedChange)
    }

    func finalizePreparedChange() async throws -> PWMFanStatus {
        try await respondToMutation(.finalizePreparedChange)
    }

    func prepareRollback() async throws -> PWMFanStatus {
        try await respondToMutation(.prepareRollback)
    }

    func uninstallManaged() async throws -> PWMFanStatus {
        try await respondToMutation(.uninstallManaged)
    }

    func convertExactLegacyFan50() async throws -> PWMFanStatus {
        try await respondToMutation(.convertExactLegacyFan50)
    }

    func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) async throws -> PWMFanStatus {
        try await respondToMutation(.resolveLegacyBackup(resolution))
    }

    func apply(dutyPercent: Int, persist: Bool) async throws -> PWMFanStatus {
        try await respondToMutation(.apply)
    }

    func completeManagedApply() async throws -> PWMFanStatus {
        try await respondToMutation(.completeManagedApply)
    }

    func completeStateCleanup() async throws -> PWMFanStatus {
        try await respondToMutation(.completeStateCleanup)
    }

    func restoreAutomatic() async throws -> PWMFanStatus {
        try await respondToMutation(.restoreAutomatic)
    }

    func detectCallCount() -> Int { detectCalls }

    func mutationCallCount() -> Int { mutationCalls.count }

    func mutationCallsSnapshot() -> [FanScreenControllerCall] { mutationCalls }

    func waitForMutationStart() async {
        guard pendingMutation == nil else { return }
        await withCheckedContinuation { continuation in
            mutationStartWaiters.append(continuation)
        }
    }

    func resumeMutation(returning status: PWMFanStatus) {
        pendingMutation?.resume(returning: status)
        pendingMutation = nil
    }

    private func respondToMutation(
        _ call: FanScreenControllerCall
    ) async throws -> PWMFanStatus {
        mutationCalls.append(call)
        switch mutation {
        case let .returning(status):
            return status
        case let .failing(error):
            throw error
        case .suspending:
            return try await withCheckedThrowingContinuation { continuation in
                pendingMutation = continuation
                let waiters = mutationStartWaiters
                mutationStartWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }
}

private func fanStatus(
    ownership: PWMFanOwnership,
    backend: PWMFanBackend? = nil,
    pin: PWMFanGPIOPin? = nil,
    dutyPercent: Int? = nil,
    verification: PWMFanVerification = .verified,
    activeConfiguration: PWMFanConfiguration? = nil,
    transition: PWMFanTransitionState? = nil,
    recoveryRequired: Bool = false,
    recoveryAction: PWMFanRecoveryAction? = nil
) -> PWMFanStatus {
    let configured = ownership == .external || ownership == .managed
    return PWMFanStatus(
        ownership: ownership,
        backend: backend,
        pin: pin ?? activeConfiguration?.pin,
        periodNanoseconds: backend == .pigpio || backend == .sysfs
            ? 40_000
            : nil,
        dutyPercent: dutyPercent ?? activeConfiguration?.dutyPercent,
        isEnabled: configured ? true : nil,
        isRuntimeAvailable: configured,
        requiresReboot: transition != nil,
        canRestoreAutomatic: false,
        detail: "Fixture",
        verification: verification,
        activeConfiguration: activeConfiguration,
        transition: transition,
        automaticDemand: activeConfiguration?.mode == .automatic ? .unknown : nil,
        legacyState: .none,
        recoveryRequired: recoveryRequired,
        manualControlAvailable: true,
        automaticControlAvailable: true,
        recoveryAction: recoveryAction
    )
}
