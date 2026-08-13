import Combine
import SwiftUI
import UIKit

@MainActor
struct FanControlDestinationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var hostKeyConfirmation: PWMFanHostKeyConfirmationModel
    private let controller: any PWMFanControlling
    private let temperatureClient: any CasaOSClient

    init(model: AppModel) {
        let confirmation = PWMFanHostKeyConfirmationModel()
        _hostKeyConfirmation = StateObject(wrappedValue: confirmation)
        temperatureClient = model.client

        if model.mockMode {
            controller = MockPWMFanController()
        } else {
            controller = SSHPWMFanController(
                serverURL: model.serverURL,
                credentialMode: model.sshCredentialMode,
                credentialStore: model.sshCredentialStore,
                hostKeyConfirmation: { [weak confirmation] prompt in
                    guard let confirmation else { return false }
                    return await confirmation.requestApproval(for: prompt)
                }
            )
        }
    }

    var body: some View {
        FanControlView(
            controller: controller,
            temperatureClient: temperatureClient
        )
        .alert(
            "Verify SSH Server",
            isPresented: Binding(
                get: { hostKeyConfirmation.prompt != nil },
                set: { if !$0 { hostKeyConfirmation.resolve(accepted: false) } }
            )
        ) {
            Button("Trust and Continue") {
                hostKeyConfirmation.resolve(accepted: true)
            }
            Button("Cancel", role: .cancel) {
                hostKeyConfirmation.resolve(accepted: false)
            }
        } message: {
            if let prompt = hostKeyConfirmation.prompt {
                Text(
                    "Confirm this fingerprint for \(prompt.host.description):\n\n"
                        + prompt.fingerprint
                        + "\n\nOnly trust it if it matches your server."
                )
            }
        }
        .onDisappear {
            hostKeyConfirmation.resolve(accepted: false)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            hostKeyConfirmation.resolve(accepted: false)
        }
    }
}

@MainActor
struct FanControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state: PWMFanScreenModel
    @State private var confirmation: PWMFanConfirmation?
    @State private var actionTask: Task<Void, Never>?
    @State private var temperatureCelsius: Double?

    @State private var wiringDriverAcknowledged = false
    @State private var wiringResourceAcknowledged = false
    @State private var automaticLogicAcknowledged = false
    @State private var threeWireTachAcknowledged = false
    @State private var fourWireInterfaceAcknowledged = false
    @State private var oldAndNewPinAcknowledged = false
    @State private var powerOffAcknowledged = false
    @State private var postBootOutputAcknowledged = false

    private let temperatureClient: (any CasaOSClient)?

    init(
        controller: any PWMFanControlling,
        temperatureClient: (any CasaOSClient)? = nil
    ) {
        _state = StateObject(
            wrappedValue: PWMFanScreenModel(controller: controller)
        )
        self.temperatureClient = temperatureClient
    }

    var body: some View {
        List {
            fanContent
        }
        .navigationTitle("PWM Fan")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            guard !state.isBusy, !state.isDetectionQuarantined else { return }
            await state.detect(force: true)
            await loadTemperature()
        }
        .toolbar {
            Button("Refresh Fan Status", systemImage: "arrow.clockwise") {
                startRefresh()
            }
            .disabled(state.isBusy || state.isDetectionQuarantined)
        }
        .task(id: state.verificationCycle) {
            await state.detectWhenSafeIfNeeded()
        }
        .task {
            await loadTemperature()
        }
        .onDisappear(perform: cancelWork)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                cancelWork()
            }
        }
        .onChange(of: state.selectedPin) { _, _ in
            wiringDriverAcknowledged = false
            wiringResourceAcknowledged = false
            automaticLogicAcknowledged = false
            threeWireTachAcknowledged = false
            fourWireInterfaceAcknowledged = false
            oldAndNewPinAcknowledged = false
            powerOffAcknowledged = false
        }
        .onChange(of: state.selectedMode) { _, newMode in
            wiringDriverAcknowledged = false
            wiringResourceAcknowledged = false
            automaticLogicAcknowledged = false
            threeWireTachAcknowledged = false
            fourWireInterfaceAcknowledged = false
            guard let active = state.status?.activeConfiguration,
                  newMode != active.mode else { return }
            state.selectedPin = active.pin
        }
        .onChange(of: state.selectedTurnOnCelsius) { _, newValue in
            let maximum = min(15, max(5, newValue - 30))
            if state.selectedHysteresisCelsius > maximum {
                state.selectedHysteresisCelsius = maximum
            }
        }
        .onChange(of: state.status?.transition) { _, _ in
            postBootOutputAcknowledged = false
        }
        .onChange(of: state.noticeMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .onChange(of: state.errorMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            confirmationButtons
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private var fanContent: some View {
        if let status = state.status {
            if status.verification == .changedButUnverified
                || status.recoveryRequired
                || status.ownership == .conflict {
                recoveryContent(status: status)
            } else if let transition = status.transition {
                transitionContent(status: status, transition: transition)
            } else {
                switch status.ownership {
                case .absent:
                    setupContent(status: status)
                case .external:
                    externalContent(status: status)
                case .managed:
                    managedContent(status: status)
                case .conflict:
                    recoveryContent(status: status)
                }
            }
        } else if let errorMessage = state.errorMessage {
            ContentUnavailableView {
                Label(
                    "Fan Status Unavailable",
                    systemImage: "fan.badge.exclamationmark"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { startRefresh() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isDetectionQuarantined)
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("Checking fan configuration…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func setupContent(status: PWMFanStatus) -> some View {
        Section {
            featureHeader(
                title: "Choose how the fan is controlled",
                detail: "Detection was read-only. Nothing changes until you review and confirm setup.",
                symbol: "fan.fill",
                color: .accentColor
            )
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if status.manualControlAvailable || status.automaticControlAvailable {
            Section("Control mode") {
                Picker("Mode", selection: $state.selectedMode) {
                    if status.manualControlAvailable {
                        Text("Manual").tag(PWMFanControlMode.manual)
                    }
                    if status.automaticControlAvailable {
                        Text("Automatic").tag(PWMFanControlMode.automatic)
                    }
                }
                .pickerStyle(.segmented)

                modeExplanation(state.selectedMode)
            }

            Section("Output and policy") {
                pinPicker

                switch state.selectedMode {
                case .manual:
                    dutyEditor
                case .automatic:
                    automaticPolicyEditor
                }
            }

            Section {
                Toggle(isOn: $wiringDriverAcknowledged) {
                    Text(
                        "The GPIO uses a suitable driver and common ground; "
                            + "it does not power the fan motor"
                    )
                }
                .accessibilityHint("Required before setup")

                Toggle(isOn: $wiringResourceAcknowledged) {
                    Text("The selected GPIO is not reserved by audio or I²S")
                }
                .accessibilityHint("Required before setup")

                if state.selectedMode == .automatic {
                    Toggle(isOn: $automaticLogicAcknowledged) {
                        Text(
                            "The control interface is GPIO-safe and active-high: "
                                + "low means off, high means full output"
                        )
                    }
                    .accessibilityHint("Required for automatic setup")

                    Toggle(isOn: $threeWireTachAcknowledged) {
                        Text(
                            "I understand a 3-wire fan's third lead is tachometer "
                                + "output, not speed control"
                        )
                    }
                    .accessibilityHint("Required for automatic setup")

                    Toggle(isOn: $fourWireInterfaceAcknowledged) {
                        Text(
                            "If this is a 4-wire fan, its PWM input uses a "
                                + "level-safe, open-drain interface"
                        )
                    }
                    .accessibilityHint("Required for automatic setup")
                }
            } header: {
                Text("Wiring checks")
            } footer: {
                Text(
                    "Confirm the physical header pin shown above. Automatic mode drives "
                        + "off/full logic; it is not a 3-wire tach input or a direct motor "
                        + "connection. GPIO functions can conflict with analog audio or I²S "
                        + "resources on these pins."
                )
            }

            Section {
                Button {
                    guard let configuration = state.selectedConfiguration else { return }
                    confirmation = .provision(configuration)
                } label: {
                    operationLabel(
                        operation: .provisioning,
                        idleTitle: "Prepare Fan Setup",
                        busyTitle: "Preparing setup…"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.isBusy
                        || !wiringDriverAcknowledged
                        || !wiringResourceAcknowledged
                        || (state.selectedMode == .automatic
                            && (!automaticLogicAcknowledged
                                || !threeWireTachAcknowledged
                                || !fourWireInterfaceAcknowledged))
                        || state.selectedConfiguration == nil
                )
                .accessibilityHint(
                    "Shows a final confirmation before preparing server changes"
                )
            } footer: {
                Text(
                    "Setup uses tools already present on the server; Casa Native does not "
                        + "install packages. It prepares an app-managed configuration and "
                        + "then waits for you to reboot. The server is never rebooted automatically."
                )
            }
        } else {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No supported controller is available")
                            .font(.headline)
                        Text(
                            "Casa Native does not install missing kernel support or server tools. Resolve the reported server requirements, then refresh detection."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(.orange)
                }
            }
        }

        operationFeedback
    }

    @ViewBuilder
    private func externalContent(status: PWMFanStatus) -> some View {
        Section {
            fanOverview(status: status)
        }

        Section {
            featureHeader(
                title: externalTitle(for: status),
                detail: externalDetail(for: status),
                symbol: "checkmark.shield.fill",
                color: .green
            )
        } header: {
            Text("Owner-managed setup")
        }

        if status.legacyState == .exactConvertible,
           status.backend == .sysfs {
            legacyConversionSection
        } else if status.legacyState == .exactConvertible,
                  status.backend == .pigpio {
            legacyPigpioConversionGuidance(
                canRestoreAutomatic: status.canRestoreAutomatic
            )
        }

        if status.backend == .gpioFan {
            automaticDemandSection(status: status, readOnly: true)
        } else {
            manualControlSection(status: status, persist: false)
        }

        controllerStatusSection(status: status)

        if status.canRestoreAutomatic {
            Section {
                Button(
                    "Return to Configured Automatic Control",
                    systemImage: "arrow.uturn.backward.circle"
                ) {
                    confirmation = .restoreAutomatic
                }
                .disabled(state.isBusy)
            } footer: {
                Text(
                    "Relinquishes the manual pigpio override and hands behavior back to "
                        + "the verified gpio-fan controller. It does not rewrite that controller."
                )
            }
        }

        operationFeedback
    }

    @ViewBuilder
    private func managedContent(status: PWMFanStatus) -> some View {
        if let active = status.activeConfiguration {
            Section {
                fanOverview(status: status)
            }

            if status.legacyState == .backupAwaitingResolution {
                legacyBackupSection
            }

            switch active {
            case .manual:
                manualControlSection(status: status, persist: true)
            case .automatic:
                automaticDemandSection(status: status, readOnly: false)
            }

            managedConfigurationSection(status: status, active: active)
            controllerStatusSection(status: status)

            Section {
                Button("Uninstall App-Managed Fan Control", role: .destructive) {
                    confirmation = .uninstall
                }
                .disabled(
                    state.isBusy
                        || status.legacyState == .backupAwaitingResolution
                )
            } header: {
                Text("Remove configuration")
            } footer: {
                Text(
                    status.legacyState == .backupAwaitingResolution
                        ? "Restore or discard the legacy backup before uninstalling."
                        : "Removal is prepared first. You remain in control of shutdown, wiring, and final confirmation."
                )
            }

            operationFeedback
        } else {
            recoveryContent(
                status: status,
                fallback: "The managed setup has no verified active configuration. Casa Native will not change it."
            )
        }
    }

    @ViewBuilder
    private func transitionContent(
        status: PWMFanStatus,
        transition: PWMFanTransitionState
    ) -> some View {
        Section {
            featureHeader(
                title: transitionTitle(transition),
                detail: transitionDetail(transition),
                symbol: transition.requirement == .fullShutdown
                    ? "power.circle.fill"
                    : "arrow.trianglehead.2.clockwise.rotate.90.circle.fill",
                color: .orange
            )

            VStack(alignment: .leading, spacing: 12) {
                switch transition.phase {
                case .prepared:
                    if let source = transition.source {
                        configurationRow("Current", configuration: source)
                    } else {
                        LabeledContent("Current", value: "Not configured")
                    }

                    if let target = transition.target.configuration {
                        configurationRow("Prepared target", configuration: target)
                    } else {
                        LabeledContent(
                            "Prepared target",
                            value: "Remove app-managed setup"
                        )
                    }

                case .bootedAwaitingConfirmation:
                    if let target = transition.target.configuration {
                        configurationRow(
                            "Active detected target",
                            configuration: target
                        )
                    } else {
                        LabeledContent(
                            "Active detected target",
                            value: "App-managed setup removed"
                        )
                    }

                    if let source = transition.source {
                        configurationRow("Rollback copy", configuration: source)
                    } else {
                        LabeledContent("Previous state", value: "Not configured")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Change in progress")
        } footer: {
            Text(
                "Normal fan controls stay hidden until this transaction is either "
                    + "cancelled, finalized, or rolled back. Casa Native never reboots "
                    + "or shuts down the server automatically."
            )
        }

        switch transition.phase {
        case .prepared:
            preparedTransitionSection(transition)
        case .bootedAwaitingConfirmation:
            bootedTransitionSection(transition)
        }

        if !status.detail.isEmpty {
            Section("Detected state") {
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        operationFeedback
    }

    @ViewBuilder
    private func preparedTransitionSection(
        _ transition: PWMFanTransitionState
    ) -> some View {
        Section {
            if transition.requirement == .fullShutdown {
                checklistRow(
                    number: 1,
                    title: "Shut the Raspberry Pi down fully",
                    detail: "Do not use a restart for a wiring change."
                )
                checklistRow(
                    number: 2,
                    title: "Disconnect its power",
                    detail: "Wait until all activity and power indicators are off."
                )
                checklistRow(
                    number: 3,
                    title: wiringMoveInstruction(transition),
                    detail: wiringMoveDetail(transition)
                )
                checklistRow(
                    number: 4,
                    title: "Reconnect power and boot",
                    detail: "The prepared target becomes active on this boot."
                )
                checklistRow(
                    number: 5,
                    title: "Return here and refresh",
                    detail: "Review the detected target before finalizing it."
                )
            } else {
                checklistRow(
                    number: 1,
                    title: "Restart the Raspberry Pi when ready",
                    detail: "Use your normal CasaOS or server administration method."
                )
                checklistRow(
                    number: 2,
                    title: "Wait for CasaOS and SSH to return",
                    detail: "Casa Native does not poll or reboot in the background."
                )
                checklistRow(
                    number: 3,
                    title: "Return here and refresh",
                    detail: "The detected target must be reviewed before finalization."
                )
            }
        } header: {
            Text(
                transition.requirement == .fullShutdown
                    ? "Full shutdown and wiring checklist"
                    : "Reboot checklist"
            )
        } footer: {
            if transition.requirement == .fullShutdown {
                Text("Never move or remove a fan control wire while the Raspberry Pi is powered.")
            }
        }

        Section {
            Button("Cancel Prepared Change", role: .destructive) {
                confirmation = .cancelPrepared
            }
            .disabled(state.isBusy)
        } footer: {
            Text(
                "Cancellation is available only before the prepared target has booted. "
                    + "If you already shut down or rebooted, power the server normally, "
                    + "refresh this screen, and use the recovery choices shown then."
            )
        }
    }

    @ViewBuilder
    private func bootedTransitionSection(
        _ transition: PWMFanTransitionState
    ) -> some View {
        Section {
            Toggle(isOn: $postBootOutputAcknowledged) {
                Text(postBootAcknowledgement(transition))
            }
            .accessibilityHint("Required before finalizing the prepared target")

            Button(finalizeButtonTitle(transition)) {
                confirmation = transition.kind == .uninstall
                    ? .finalizeUninstall
                    : .finalize
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isBusy || !postBootOutputAcknowledged)
        } header: {
            Text("Target booted — decision required")
        } footer: {
            Text(
                "Finalizing keeps the detected target and removes the rollback copy. "
                    + "This acknowledgement concerns configuration and expected PWM/demand, "
                    + "not RPM or proof that a fan is physically spinning."
            )
        }

        if transition.kind != .rollback,
           transition.source != nil || transition.target.configuration != nil {
            Section {
                Button("Prepare Rollback", role: .destructive) {
                    confirmation = .rollback
                }
                .disabled(state.isBusy)
            } footer: {
                Text(
                    "Rollback restores the preserved previous lifecycle generation. "
                        + "Installing or removing control, or returning to a different GPIO, "
                        + "requires a full shutdown and the same unpowered wiring checklist."
                )
            }
        }
    }

    @ViewBuilder
    private func managedConfigurationSection(
        status: PWMFanStatus,
        active: PWMFanConfiguration
    ) -> some View {
        let target = managedTarget(from: active)
        let pinChanges = target?.pin != active.pin
        let automaticPolicyChanges = automaticPolicyChanged(
            active: active,
            target: target
        )
        let changesManualToAutomatic = active.mode == .manual
            && target?.mode == .automatic
        let changesAutomaticToManual = active.mode == .automatic
            && target?.mode == .manual
        let manualDutyEditedSeparately = active.mode == .manual
            && state.selectedMode == .manual
            && state.selectedDutyPercent != active.dutyPercent
        let modeChangeAcknowledgementsSatisfied = if changesManualToAutomatic {
            automaticLogicAcknowledged
                && threeWireTachAcknowledged
                && fourWireInterfaceAcknowledged
        } else if changesAutomaticToManual {
            wiringDriverAcknowledged
        } else {
            true
        }

        Section {
            Picker("Mode", selection: $state.selectedMode) {
                if status.manualControlAvailable || active.mode == .manual {
                    Text("Manual").tag(PWMFanControlMode.manual)
                }
                if status.automaticControlAvailable || active.mode == .automatic {
                    Text("Automatic").tag(PWMFanControlMode.automatic)
                }
            }
            .pickerStyle(.segmented)

            Picker("PWM output", selection: $state.selectedPin) {
                ForEach(PWMFanGPIOPin.allCases) { pin in
                    Text(pin.title).tag(pin)
                }
            }
            .disabled(state.selectedMode != active.mode || automaticPolicyChanges)

            if state.selectedMode == .automatic {
                automaticPolicyEditor
                    .disabled(pinChanges && active.mode == .automatic)
            } else if active.mode == .automatic {
                dutyEditor
            }

            if pinChanges {
                Label {
                    Text(
                        "Changing from \(active.pin.title) to "
                            + "\(target?.pin.title ?? state.selectedPin.title) requires a full shutdown."
                    )
                    .font(.footnote)
                } icon: {
                    Image(systemName: "power")
                        .foregroundStyle(.orange)
                }

                if manualDutyEditedSeparately,
                   let activeDutyPercent = active.dutyPercent {
                    Label {
                        Text(
                            "The pin transition keeps the active \(activeDutyPercent)% duty. "
                                + "Use Apply Duty separately for the selected "
                                + "\(state.selectedDutyPercent)% value."
                        )
                        .font(.footnote)
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if target != nil, target != active {
                Label {
                    Text("This mode or policy change requires a reboot.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Managed configuration")
        } footer: {
            Text(
                "Change one configuration axis at a time. A pin change preserves the "
                    + "current mode and policy; a mode change stays on the current pin."
            )
        }

        if pinChanges {
            Section {
                Toggle(isOn: $oldAndNewPinAcknowledged) {
                    Text("I identified both physical header pins")
                }
                Toggle(isOn: $powerOffAcknowledged) {
                    Text("I will disconnect power before moving the control wire")
                }
            } header: {
                Text("Pin-change acknowledgements")
            } footer: {
                Text(
                    "Do not move the wire during a restart. Fully shut down, disconnect "
                        + "power, move the control wire, and only then reconnect power."
                )
            }
        }

        if changesManualToAutomatic {
            Section {
                Toggle(isOn: $automaticLogicAcknowledged) {
                    Text(
                        "The GPIO-safe control is active-high: low is static off "
                            + "and high is static full output"
                    )
                }
                .accessibilityHint("Required before preparing automatic control")

                Toggle(isOn: $threeWireTachAcknowledged) {
                    Text(
                        "I confirmed the control lead is not a 3-wire fan's "
                            + "tachometer output"
                    )
                }
                .accessibilityHint("Required before preparing automatic control")

                Toggle(isOn: $fourWireInterfaceAcknowledged) {
                    Text(
                        "For a 4-wire fan, its PWM control input uses a "
                            + "level-safe, open-drain interface"
                    )
                }
                .accessibilityHint("Required before preparing automatic control")
            } header: {
                Text("Automatic-mode wiring acknowledgements")
            } footer: {
                Text(
                    "Automatic control switches only between static off and full output. "
                        + "It does not use a 3-wire tachometer lead as a control input."
                )
            }
        } else if changesAutomaticToManual {
            Section {
                Toggle(isOn: $wiringDriverAcknowledged) {
                    Text(
                        "I confirmed a GPIO-safe driver or interface with common ground "
                            + "that supports 25 kHz hardware PWM; the GPIO does not "
                            + "power the fan motor"
                    )
                }
                .accessibilityHint("Required before preparing manual PWM control")
            } header: {
                Text("Manual-mode wiring acknowledgement")
            } footer: {
                Text(
                    "Manual mode drives a fixed 25 kHz hardware-PWM duty. "
                        + "The fan motor must be powered through suitable hardware."
                )
            }
        }

        if let target, target != active {
            Section {
                Button("Prepare Configuration Change") {
                    confirmation = .prepareConfiguration(
                        target,
                        pinChange: pinChanges
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.isBusy
                        || !modeChangeAcknowledgementsSatisfied
                        || (pinChanges
                            && (!oldAndNewPinAcknowledged || !powerOffAcknowledged))
                )
            } footer: {
                Text(
                    "Preparing writes the inactive target only. It does not reboot, "
                        + "shut down, or switch the running controller."
                )
            }
        }
    }

    @ViewBuilder
    private func manualControlSection(
        status: PWMFanStatus,
        persist: Bool
    ) -> some View {
        Section {
            dutyEditor

            Button {
                confirmation = .apply(
                    dutyPercent: state.selectedDutyPercent,
                    persist: persist,
                    requiresSudo: status.backend == .sysfs
                )
            } label: {
                operationLabel(
                    operation: .applying,
                    idleTitle: "Apply \(state.selectedDutyPercent)% Duty",
                    busyTitle: "Applying duty…"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                state.isBusy
                    || !status.isRuntimeAvailable
                    || state.selectedDutyPercent == status.dutyPercent
            )
            .accessibilityHint("Shows a confirmation before changing PWM duty")
        } header: {
            Text("Manual PWM duty")
        } footer: {
            Text(
                persist
                    ? "A confirmed change updates the app-managed manual policy for future boots. Duty is electrical output, not measured RPM."
                    : "A confirmed change affects the running system only and may reset after a reboot or service restart. Owner-managed files are not rewritten."
            )
        }
    }

    @ViewBuilder
    private func automaticDemandSection(
        status: PWMFanStatus,
        readOnly: Bool
    ) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: automaticDemandSymbol(status.automaticDemand))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(automaticDemandColor(status.automaticDemand))
                    .frame(width: 44, height: 44)
                    .background(
                        automaticDemandColor(status.automaticDemand).opacity(0.12),
                        in: .circle
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(automaticDemandTitle(status.automaticDemand))
                        .font(.headline)
                    Text(
                        "The kernel controller reports only off/full demand. "
                            + "Casa Native does not infer RPM or physical fan motion."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if let configuration = status.activeConfiguration,
               case let .automatic(policy) = configuration {
                LabeledContent("Turn on", value: "\(policy.turnOnCelsius) °C")
                LabeledContent("Turn off", value: "\(policy.turnOffCelsius) °C")
                LabeledContent("Hysteresis", value: "\(policy.hysteresisCelsius) °C")
            }
        } header: {
            Text(readOnly ? "External automatic policy" : "Automatic demand")
        } footer: {
            if readOnly {
                Text("This owner-managed gpio-fan configuration is read-only in Casa Native.")
            } else {
                Text("The kernel evaluates its thermal sensor; the app does not run a background temperature loop.")
            }
        }
    }

    private var legacyConversionSection: some View {
        Section {
            featureHeader(
                title: "Exact legacy fan50 setup found",
                detail: "The verified GPIO18, 25 kHz, 50% sysfs setup can be converted without changing its current runtime output.",
                symbol: "shippingbox.and.arrow.backward.fill",
                color: .orange
            )

            Button("Convert Exact Legacy Setup") {
                confirmation = .convertLegacy
            }
            .disabled(state.isBusy)
        } header: {
            Text("Optional conversion")
        } footer: {
            Text(
                "Conversion is offered only for the exact supported legacy files. "
                    + "Casa Native keeps a backup until you explicitly restore or discard it."
            )
        }
    }

    private func legacyPigpioConversionGuidance(
        canRestoreAutomatic: Bool
    ) -> some View {
        Section {
            featureHeader(
                title: "Restore the owner-managed controller first",
                detail: canRestoreAutomatic
                    ? "pigpio currently overrides the verified automatic controller. Use Return to Configured Automatic Control below, then refresh. That automatic controller remains owner-managed and is not converted."
                    : "pigpio currently owns GPIO18. Restore the exact legacy fan50 service's sysfs 25 kHz, 50% runtime output using its owner-managed controls, then refresh before conversion.",
                symbol: "arrow.uturn.backward.circle.fill",
                color: .orange
            )
        } header: {
            Text("Legacy conversion unavailable")
        } footer: {
            Text(
                "Casa Native will not convert the legacy files while pigpio is the active "
                    + "backend. Returning runtime control does not inherently require a reboot."
            )
        }
    }

    private var legacyBackupSection: some View {
        Section {
            featureHeader(
                title: "Legacy backup needs a decision",
                detail: "Choose whether to restore the exact pre-conversion setup or permanently keep the app-managed version.",
                symbol: "externaldrive.badge.questionmark",
                color: .orange
            )

            Button("Restore Legacy Backup") {
                confirmation = .resolveLegacy(.restore)
            }
            .disabled(state.isBusy)

            Button("Discard Legacy Backup", role: .destructive) {
                confirmation = .resolveLegacy(.discard)
            }
            .disabled(state.isBusy)
        } header: {
            Text("Conversion backup")
        } footer: {
            Text(
                "Restore returns ownership to the exact legacy fan50 setup. Discard "
                    + "permanently removes that backup and keeps Casa Native management."
            )
        }
    }

    @ViewBuilder
    private func recoveryContent(
        status: PWMFanStatus,
        fallback: String? = nil
    ) -> some View {
        ContentUnavailableView {
            Label(
                status.verification == .changedButUnverified
                    ? "Fan State Unverified"
                    : "Fan Configuration Needs Attention",
                systemImage: "exclamationmark.triangle.fill"
            )
        } description: {
            Text(
                status.detail.isEmpty
                    ? (fallback
                        ?? "The fan configuration could not be proved safe to change. Casa Native has disabled mutations.")
                    : status.detail
            )
        } actions: {
            if let recoveryAction = state.recoverableAction,
               !state.isDetectionQuarantined,
               state.errorMessage == nil {
                Button(recoveryButtonTitle(recoveryAction)) {
                    confirmation = .recover(recoveryAction)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || state.isDetectionQuarantined)

                Button("Refresh Detection") { startRefresh() }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy || state.isDetectionQuarantined)
            } else {
                Button("Refresh Detection") { startRefresh() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy || state.isDetectionQuarantined)
            }
        }

        Section {
            Text(
                "Check CPU temperature and the expected controller output before relying "
                    + "on an earlier value. If a change was interrupted, wait for the "
                    + "verification delay. A recovery button appears only when detection "
                    + "proves one retry-safe action; otherwise refresh is the only option."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Mutation quarantine")
        }

        operationFeedback
    }

    private func fanOverview(status: PWMFanStatus) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "fan.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(
                        status.isRuntimeAvailable ? Color.accentColor : .secondary
                    )
                    .frame(width: 52, height: 52)
                    .background(
                        (status.isRuntimeAvailable ? Color.accentColor : .gray)
                            .opacity(0.12),
                        in: .circle
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(overviewTitle(for: status))
                        .font(.headline)
                    Text(overviewSubtitle(for: status))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if status.backend != .gpioFan {
                Gauge(
                    value: Double(status.dutyPercent ?? 0),
                    in: 0...100
                ) {
                    Text("PWM duty")
                } currentValueLabel: {
                    Text(status.dutyPercent.map { "\($0)%" } ?? "—")
                        .monospacedDigit()
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("100")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .controlSize(.extraLarge)
                .tint(fanGradient)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("PWM duty")
                .accessibilityValue(
                    status.dutyPercent.map { "\($0) percent" } ?? "Unavailable"
                )
            }

            HStack(spacing: 16) {
                if let pin = status.pin {
                    Label(
                        pin.title,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }
                if let temperatureCelsius {
                    Label(
                        temperatureCelsius.formatted(
                            .number.precision(.fractionLength(0))
                        ) + " °C",
                        systemImage: "thermometer.medium"
                    )
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var pinPicker: some View {
        Picker("PWM output", selection: $state.selectedPin) {
            ForEach(PWMFanGPIOPin.allCases) { pin in
                Text(pin.title).tag(pin)
            }
        }
        .accessibilityHint("Shows GPIO number and physical Raspberry Pi header pin")
    }

    private var dutyEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { preset in
                    if state.selectedDutyPercent == preset {
                        dutyPresetButton(preset)
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    } else {
                        dutyPresetButton(preset)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)

            HStack {
                Text("PWM duty")
                Spacer()
                Text("\(state.selectedDutyPercent)%")
                    .font(.body.monospacedDigit().weight(.semibold))
            }

            Slider(
                value: Binding(
                    get: { Double(state.selectedDutyPercent) },
                    set: {
                        state.selectedDutyPercent = Int($0.rounded() / 5) * 5
                    }
                ),
                in: 0...100,
                step: 5
            )
            .accessibilityLabel("PWM duty")
            .accessibilityValue("\(state.selectedDutyPercent) percent")

            Text("Electrical duty only. No tachometer or RPM measurement is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func dutyPresetButton(_ preset: Int) -> some View {
        Button {
            state.selectedDutyPercent = preset
        } label: {
            Text(preset == 0 ? "Off" : "\(preset)%")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel(
            preset == 0
                ? "Zero percent duty preset"
                : "\(preset) percent duty preset"
        )
        .accessibilityAddTraits(
            state.selectedDutyPercent == preset ? .isSelected : []
        )
    }

    private var automaticPolicyEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Turn on at")
                    Spacer()
                    Text("\(state.selectedTurnOnCelsius) °C")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                Slider(
                    value: Binding(
                        get: { Double(state.selectedTurnOnCelsius) },
                        set: { state.selectedTurnOnCelsius = Int($0.rounded()) }
                    ),
                    in: 40...75,
                    step: 1
                )
                .accessibilityLabel("Automatic turn-on temperature")
                .accessibilityValue("\(state.selectedTurnOnCelsius) degrees Celsius")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hysteresis")
                    Spacer()
                    Text("\(state.selectedHysteresisCelsius) °C")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                Slider(
                    value: Binding(
                        get: { Double(state.selectedHysteresisCelsius) },
                        set: { state.selectedHysteresisCelsius = Int($0.rounded()) }
                    ),
                    in: 5...Double(
                        min(15, max(5, state.selectedTurnOnCelsius - 30))
                    ),
                    step: 1
                )
                .accessibilityLabel("Automatic hysteresis")
                .accessibilityValue("\(state.selectedHysteresisCelsius) degrees Celsius")
            }

            LabeledContent(
                "Computed turn-off",
                value: "\(state.selectedTurnOffCelsius) °C"
            )
            .fontWeight(.medium)

            Text(
                "The kernel requests full output at the on threshold and returns to "
                    + "off after cooling to the computed threshold. This is not variable-speed control."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func controllerStatusSection(status: PWMFanStatus) -> some View {
        Section("Controller status") {
            if let backend = status.backend {
                LabeledContent("Backend", value: backend.title)
            }
            if let pin = status.pin {
                LabeledContent("Output", value: pin.title)
            }
            if let period = status.periodNanoseconds, period > 0 {
                LabeledContent("PWM frequency", value: pwmFrequency(period: period))
            }
            if let enabled = status.isEnabled {
                LabeledContent("Output enabled", value: enabled ? "Yes" : "No")
            }
            LabeledContent(
                "Runtime access",
                value: status.isRuntimeAvailable ? "Available" : "Unavailable"
            )
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var operationFeedback: some View {
        if let operation = state.operation, operation != .detecting {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(operation.progressTitle)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let noticeMessage = state.noticeMessage {
            if state.needsVerification {
                Section {
                    Label(
                        noticeMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } header: {
                    Text("Verification required")
                }
            } else {
                Section {
                    Label(noticeMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }

        if let errorMessage = state.errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Refresh Fan Status") { startRefresh() }
                    .disabled(state.isDetectionQuarantined || state.isBusy)
            } header: {
                Text("Fan control failed")
            }
        }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        switch confirmation {
        case let .provision(configuration):
            Button("Prepare \(configuration.mode.title) Setup") {
                confirmation = nil
                startAction {
                    await state.provision(configuration: configuration)
                }
            }

        case let .apply(dutyPercent, persist, _):
            Button(
                dutyPercent == 0 ? "Apply 0% Duty" : "Apply \(dutyPercent)% Duty",
                role: dutyPercent == 0 ? .destructive : nil
            ) {
                confirmation = nil
                startAction {
                    await state.apply(
                        dutyPercent: dutyPercent,
                        persist: persist
                    )
                }
            }

        case .restoreAutomatic:
            Button("Return to Automatic Control") {
                confirmation = nil
                startAction { await state.restoreAutomatic() }
            }

        case let .prepareConfiguration(configuration, _):
            Button("Prepare Change") {
                confirmation = nil
                startAction {
                    await state.prepareConfigurationChange(to: configuration)
                }
            }

        case .cancelPrepared:
            Button("Cancel Prepared Change", role: .destructive) {
                confirmation = nil
                startAction { await state.cancelPreparedChange() }
            }

        case .finalize:
            Button("Finalize Prepared Target") {
                confirmation = nil
                startAction { await state.finalizePreparedChange() }
            }

        case .rollback:
            Button("Prepare Rollback", role: .destructive) {
                confirmation = nil
                startAction { await state.prepareRollback() }
            }

        case .uninstall:
            Button("Prepare Uninstall", role: .destructive) {
                confirmation = nil
                startAction { await state.uninstallManaged() }
            }

        case .finalizeUninstall:
            Button("Finalize Uninstall", role: .destructive) {
                confirmation = nil
                startAction { await state.uninstallManaged() }
            }

        case .convertLegacy:
            Button("Convert Exact Legacy Setup") {
                confirmation = nil
                startAction { await state.convertExactLegacyFan50() }
            }

        case let .resolveLegacy(resolution):
            Button(
                resolution == .restore
                    ? "Restore Legacy Backup"
                    : "Discard Legacy Backup",
                role: resolution == .discard ? .destructive : nil
            ) {
                confirmation = nil
                startAction { await state.resolveLegacyBackup(resolution) }
            }

        case let .recover(action):
            Button(
                recoveryButtonTitle(action),
                role: recoveryButtonRole(action)
            ) {
                confirmation = nil
                startAction { await state.recover(action) }
            }

        case nil:
            EmptyView()
        }
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .provision:
            return "Prepare fan setup?"
        case let .apply(dutyPercent, _, _):
            return dutyPercent == 0
                ? "Apply zero PWM duty?"
                : "Apply \(dutyPercent)% PWM duty?"
        case .restoreAutomatic:
            return "Return to automatic control?"
        case let .prepareConfiguration(_, pinChange):
            return pinChange
                ? "Prepare a GPIO transition?"
                : "Prepare configuration change?"
        case .cancelPrepared:
            return "Cancel prepared change?"
        case .finalize:
            return "Finalize the booted target?"
        case .rollback:
            return "Prepare rollback?"
        case .uninstall:
            return "Prepare uninstall?"
        case .finalizeUninstall:
            return "Finalize uninstall?"
        case .convertLegacy:
            return "Convert exact legacy setup?"
        case let .resolveLegacy(resolution):
            return resolution == .restore
                ? "Restore legacy backup?"
                : "Permanently discard legacy backup?"
        case let .recover(action):
            return recoveryConfirmationTitle(action)
        case nil:
            return "Confirm fan control"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case let .provision(configuration):
            return configurationSummary(configuration)
                + " Casa Native will re-check the server, prepare its owned files, and wait for you to reboot. It does not install packages or reboot automatically. Manual hardware PWM can conflict with analog audio or I²S on the selected GPIO. Your saved SSH password may be presented to sudo over the encrypted SSH connection; it is never placed in a command or log."

        case let .apply(dutyPercent, persist, requiresSudo):
            let safety = dutyPercent == 0
                ? "Zero PWM duty can remove active cooling. Monitor CPU temperature and confirm passive cooling is sufficient. "
                : ""
            let lifetime = persist
                ? "This updates the app-managed manual policy for future boots."
                : "This is runtime-only and may reset after a reboot or service restart."
            let privilege = requiresSudo
                ? " Your saved SSH password may be presented to sudo over the encrypted SSH connection; it is never placed in a command or log."
                : " The pigpio command is unprivileged and your password is not presented to sudo."
            return safety + lifetime + privilege

        case .restoreAutomatic:
            return "This relinquishes the manual pigpio override and returns behavior to the verified owner-managed gpio-fan controller. It does not replace that controller. Your saved SSH password may be presented to sudo over the encrypted SSH connection; it is never placed in a command or log."

        case let .prepareConfiguration(configuration, pinChange):
            let transition = pinChange
                ? "This prepares a full-shutdown transition to \(configuration.pin.title). After preparation, fully shut down and disconnect power before moving the control wire. Never rewire a powered Raspberry Pi."
                : "This prepares the new mode or temperature policy for the next reboot. The running controller does not switch now."
            return transition
                + " Casa Native will not shut down or reboot the server. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case .cancelPrepared:
            return "This removes the inactive prepared target and keeps the current configuration. Use it only before the target has booted. The saved SSH password may be presented to sudo over encrypted SSH."

        case .finalize:
            return "This keeps the currently detected target and removes its rollback copy. Confirm only after checking the expected PWM duty or automatic controller demand and the CPU temperature. The app does not measure RPM. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case .rollback:
            return "This prepares the preserved previous lifecycle generation as the next target, including restoring control after a prepared uninstall or returning a fresh install to no app-managed control. It does not switch or reboot now. Rollback requires a full shutdown; move wiring only while the Raspberry Pi is fully unpowered. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case .uninstall:
            return "This prepares removal of Casa Native's owned fan configuration. Normal controls stay unavailable until the full shutdown/reboot checklist and final decision are complete. Owner-managed files are not deleted. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case .finalizeUninstall:
            return "This confirms the booted uninstall target and permanently removes Casa Native's rollback copy. Confirm the server's expected cooling arrangement first. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case .convertLegacy:
            return "Only the exact verified GPIO18 fan50 files are converted. Current runtime output stays unchanged and a restorable backup is retained until you explicitly restore or discard it. Your SSH password may be presented to sudo over encrypted SSH."

        case let .resolveLegacy(resolution):
            if resolution == .restore {
                return "This restores the exact pre-conversion fan50 setup and returns it to owner-managed status. The app-managed replacement is removed. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."
            }
            return "This permanently deletes the exact pre-conversion backup and keeps the app-managed configuration. This cannot be undone from Casa Native. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."

        case let .recover(action):
            return recoveryConfirmationMessage(action)

        case nil:
            return "No change will be made until you confirm."
        }
    }

    private func recoveryButtonTitle(_ action: PWMFanRecoveryAction) -> String {
        switch action {
        case .cancelPreparedChange:
            return "Retry Cancel Prepared Change"
        case .completeRollbackPreparation:
            return "Complete Interrupted Rollback Preparation"
        case .finalizePreparedChange:
            return "Retry Finalize Prepared Target"
        case .completeUninstall:
            return "Retry Complete Uninstall"
        case .completeLegacyConversion:
            return "Retry Complete Legacy Conversion"
        case .completeLegacyRestore:
            return "Retry Restore Legacy Backup"
        case .completeLegacyDiscard:
            return "Retry Discard Legacy Backup"
        case .completeManagedApply:
            return "Complete Duty Recovery"
        case .completeStateCleanup:
            return "Complete Lifecycle Recovery"
        }
    }

    private func recoveryButtonRole(
        _ action: PWMFanRecoveryAction
    ) -> ButtonRole? {
        switch action {
        case .cancelPreparedChange,
             .completeRollbackPreparation,
             .completeUninstall,
             .completeLegacyDiscard:
            return .destructive
        case .finalizePreparedChange,
             .completeLegacyConversion,
             .completeLegacyRestore,
             .completeManagedApply,
             .completeStateCleanup:
            return nil
        }
    }

    private func recoveryConfirmationTitle(
        _ action: PWMFanRecoveryAction
    ) -> String {
        switch action {
        case .cancelPreparedChange:
            return "Retry cancelling the prepared change?"
        case .completeRollbackPreparation:
            return "Complete interrupted rollback preparation?"
        case .finalizePreparedChange:
            return "Retry finalizing the prepared target?"
        case .completeUninstall:
            return "Retry completing uninstall?"
        case .completeLegacyConversion:
            return "Retry completing legacy conversion?"
        case .completeLegacyRestore:
            return "Retry restoring the legacy backup?"
        case .completeLegacyDiscard:
            return "Retry discarding the legacy backup?"
        case .completeManagedApply:
            return "Complete duty recovery?"
        case .completeStateCleanup:
            return "Complete lifecycle recovery?"
        }
    }

    private func recoveryConfirmationMessage(
        _ action: PWMFanRecoveryAction
    ) -> String {
        let step: String
        switch action {
        case .cancelPreparedChange:
            step = "This retries removal of the inactive prepared target and keeps the currently running configuration."
        case .completeRollbackPreparation:
            step = "A rollback preparation was interrupted after its exact target was staged. This completes that journaled preparation; it does not prepare a rollback of the rollback or switch the running controller."
        case .finalizePreparedChange:
            step = "This retries keeping the detected booted target and removing its rollback copy. Verify the expected controller demand and CPU temperature first."
        case .completeUninstall:
            step = "This retries finalizing the detected uninstall target and removing its rollback copy. Confirm the expected cooling arrangement first."
        case .completeLegacyConversion:
            step = "This retries completion of the exact legacy fan50 conversion. Its backup remains until you explicitly restore or discard it."
        case .completeLegacyRestore:
            step = "This retries restoring the exact pre-conversion fan50 backup and returning it to owner management."
        case .completeLegacyDiscard:
            step = "This retries permanently discarding the exact pre-conversion backup and keeping app management. This cannot be undone from Casa Native."
        case .completeManagedApply:
            step = "An app-managed duty/default transaction was interrupted. This retries the exact journaled duty with persistence enabled to reconcile the runtime output and saved boot setting."
        case .completeStateCleanup:
            step = "Publication or cleanup of Casa Native's reserved configuration, helper, default, service, legacy temporary, state, or partial staging artifacts was interrupted. This retry reconciles only strictly verified Casa Native reserved artifacts; it never changes or removes external controller files."
        }
        return step
            + " Detection identified this as the only retry-safe recovery action. The server phase is checked again before mutation. Casa Native does not reboot automatically. Your saved SSH password may be presented to sudo over encrypted SSH; it is never placed in a command or log."
    }

    private var fanGradient: Gradient {
        Gradient(colors: [.blue, .cyan, .green, .orange])
    }

    private func managedTarget(
        from active: PWMFanConfiguration
    ) -> PWMFanConfiguration? {
        if state.selectedMode != active.mode {
            switch state.selectedMode {
            case .manual:
                return try? .manual(
                    PWMFanManualConfiguration(
                        pin: active.pin,
                        dutyPercent: state.selectedDutyPercent
                    )
                )
            case .automatic:
                return try? .automatic(
                    PWMFanAutomaticConfiguration(
                        pin: active.pin,
                        turnOnCelsius: state.selectedTurnOnCelsius,
                        hysteresisCelsius: state.selectedHysteresisCelsius
                    )
                )
            }
        }

        if state.selectedPin != active.pin {
            switch active {
            case let .manual(configuration):
                return try? .manual(
                    PWMFanManualConfiguration(
                        pin: state.selectedPin,
                        dutyPercent: configuration.dutyPercent
                    )
                )
            case let .automatic(configuration):
                return try? .automatic(
                    PWMFanAutomaticConfiguration(
                        pin: state.selectedPin,
                        turnOnCelsius: configuration.turnOnCelsius,
                        hysteresisCelsius: configuration.hysteresisCelsius
                    )
                )
            }
        }

        switch active {
        case .manual:
            return active
        case .automatic:
            return try? .automatic(
                PWMFanAutomaticConfiguration(
                    pin: active.pin,
                    turnOnCelsius: state.selectedTurnOnCelsius,
                    hysteresisCelsius: state.selectedHysteresisCelsius
                )
            )
        }
    }

    private func automaticPolicyChanged(
        active: PWMFanConfiguration,
        target: PWMFanConfiguration?
    ) -> Bool {
        guard active.mode == .automatic,
              state.selectedMode == .automatic,
              state.selectedPin == active.pin,
              let target else { return false }
        return target != active
    }

    private func featureHeader(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func modeExplanation(_ mode: PWMFanControlMode) -> some View {
        Group {
            switch mode {
            case .manual:
                Text("Sets a fixed hardware-PWM duty in 5% steps.")
            case .automatic:
                Text("Uses the kernel gpio-fan controller: full output above the on threshold and off below the computed threshold.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func configurationRow(
        _ label: String,
        configuration: PWMFanConfiguration
    ) -> some View {
        LabeledContent(label) {
            Text(configurationSummary(configuration))
                .multilineTextAlignment(.trailing)
        }
    }

    private func configurationSummary(
        _ configuration: PWMFanConfiguration
    ) -> String {
        switch configuration {
        case let .manual(value):
            return "Manual · \(value.dutyPercent)% duty · \(value.pin.title)"
        case let .automatic(value):
            return "Automatic · on \(value.turnOnCelsius) °C · off \(value.turnOffCelsius) °C · \(value.pin.title)"
        }
    }

    private func checklistRow(
        number: Int,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }

    private func operationLabel(
        operation: PWMFanOperation,
        idleTitle: String,
        busyTitle: String
    ) -> some View {
        Group {
            if state.operation == operation {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(busyTitle)
                }
            } else {
                Text(idleTitle)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func overviewTitle(for status: PWMFanStatus) -> String {
        if status.verification == .changedButUnverified {
            return "Fan state unverified"
        }
        if status.backend == .gpioFan {
            return "Automatic fan policy"
        }
        return status.isRuntimeAvailable
            ? "PWM control available"
            : "PWM control unavailable"
    }

    private func overviewSubtitle(for status: PWMFanStatus) -> String {
        let controller = status.backend?.title ?? "Fan controller"
        if status.verification == .changedButUnverified {
            return "\(controller) · refresh required"
        }
        if status.backend == .gpioFan {
            return "\(controller) · \(automaticDemandTitle(status.automaticDemand))"
        }
        if let duty = status.dutyPercent {
            return "\(controller) · \(duty)% PWM duty"
        }
        return controller
    }

    private func externalTitle(for status: PWMFanStatus) -> String {
        status.backend == .gpioFan
            ? "Existing automatic controller detected"
            : "Existing runtime controller detected"
    }

    private func externalDetail(for status: PWMFanStatus) -> String {
        if status.backend == .gpioFan {
            return "Casa Native reports this gpio-fan policy but does not edit, replace, or remove it."
        }
        return "Casa Native leaves its files and boot configuration unchanged. Any available manual override is runtime-only and may reset after reboot or service restart."
    }

    private func automaticDemandTitle(
        _ demand: PWMFanAutomaticDemand?
    ) -> String {
        switch demand {
        case .off:
            return "Controller demand: Off"
        case .full:
            return "Controller demand: Full"
        case .unknown, nil:
            return "Controller demand: Unknown"
        }
    }

    private func automaticDemandSymbol(
        _ demand: PWMFanAutomaticDemand?
    ) -> String {
        switch demand {
        case .off:
            return "moon.zzz.fill"
        case .full:
            return "bolt.fill"
        case .unknown, nil:
            return "questionmark.circle.fill"
        }
    }

    private func automaticDemandColor(
        _ demand: PWMFanAutomaticDemand?
    ) -> Color {
        switch demand {
        case .off:
            return .blue
        case .full:
            return .orange
        case .unknown, nil:
            return .secondary
        }
    }

    private func transitionTitle(
        _ transition: PWMFanTransitionState
    ) -> String {
        switch (transition.kind, transition.phase) {
        case (.configurationChange, .prepared):
            return "Configuration prepared"
        case (.configurationChange, .bootedAwaitingConfirmation):
            return "Prepared configuration booted"
        case (.rollback, .prepared):
            return "Rollback prepared"
        case (.rollback, .bootedAwaitingConfirmation):
            return "Rollback target booted"
        case (.uninstall, .prepared):
            return "Uninstall prepared"
        case (.uninstall, .bootedAwaitingConfirmation):
            return "Uninstall target booted"
        }
    }

    private func transitionDetail(
        _ transition: PWMFanTransitionState
    ) -> String {
        if transition.phase == .bootedAwaitingConfirmation {
            return "The target is active but not committed. Review it, then finalize or prepare a rollback where available."
        }
        if transition.requirement == .fullShutdown {
            return "A full shutdown and unpowered wiring step is required before the prepared target can boot."
        }
        return "The inactive target is ready for your next reboot."
    }

    private func wiringMoveInstruction(
        _ transition: PWMFanTransitionState
    ) -> String {
        if transition.target.isUninstall {
            return "Remove or reconnect the control wire for your next controller"
        }
        if let source = transition.source,
           let target = transition.target.configuration,
           source.pin != target.pin {
            return "Move the control wire to \(target.pin.title)"
        }
        return "Check the fan control wiring"
    }

    private func wiringMoveDetail(
        _ transition: PWMFanTransitionState
    ) -> String {
        if let source = transition.source,
           let target = transition.target.configuration,
           source.pin != target.pin {
            return "Move only after power is disconnected: \(source.pin.title) → \(target.pin.title)."
        }
        return "Follow the cooling arrangement you selected outside Casa Native."
    }

    private func postBootAcknowledgement(
        _ transition: PWMFanTransitionState
    ) -> String {
        if transition.target.isUninstall {
            return "I verified the expected cooling arrangement after removal"
        }
        return "I verified the target configuration, expected output, and CPU temperature"
    }

    private func finalizeButtonTitle(
        _ transition: PWMFanTransitionState
    ) -> String {
        transition.kind == .uninstall
            ? "Finalize Uninstall"
            : "Finalize Prepared Target"
    }

    private func pwmFrequency(period: Int) -> String {
        let hertz = 1_000_000_000.0 / Double(period)
        if hertz >= 1_000 {
            return (hertz / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            ) + " kHz"
        }
        return hertz.formatted(.number.precision(.fractionLength(0))) + " Hz"
    }

    private func startRefresh() {
        guard !state.isBusy, !state.isDetectionQuarantined else { return }
        startAction {
            await state.detect(force: true)
            await loadTemperature()
        }
    }

    private func startAction(
        _ action: @escaping @MainActor () async -> Void
    ) {
        actionTask?.cancel()
        actionTask = Task { await action() }
    }

    private func cancelWork() {
        actionTask?.cancel()
        actionTask = nil
        state.cancelCurrentOperation()
    }

    private func loadTemperature() async {
        guard let temperatureClient else { return }
        do {
            let summary = try await temperatureClient.fetchServerSummary()
            guard !Task.isCancelled else { return }
            temperatureCelsius = summary.temperature.flatMap { $0 > 0 ? $0 : nil }
        } catch is CancellationError {
            return
        } catch {
            // Temperature is context only and never gates safe fan-state handling.
        }
    }
}

@MainActor
final class PWMFanScreenModel: ObservableObject {
    @Published private(set) var status: PWMFanStatus?
    @Published private(set) var operation: PWMFanOperation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var verificationCycle = UUID()

    @Published var selectedMode: PWMFanControlMode = .manual
    @Published var selectedPin: PWMFanGPIOPin = .gpio18
    @Published var selectedDutyPercent = 50
    @Published var selectedTurnOnCelsius = 55
    @Published var selectedHysteresisCelsius = 10

    var selectedTurnOffCelsius: Int {
        selectedTurnOnCelsius - selectedHysteresisCelsius
    }

    var selectedConfiguration: PWMFanConfiguration? {
        switch selectedMode {
        case .manual:
            return try? .manual(
                PWMFanManualConfiguration(
                    pin: selectedPin,
                    dutyPercent: selectedDutyPercent
                )
            )
        case .automatic:
            return try? .automatic(
                PWMFanAutomaticConfiguration(
                    pin: selectedPin,
                    turnOnCelsius: selectedTurnOnCelsius,
                    hysteresisCelsius: selectedHysteresisCelsius
                )
            )
        }
    }

    var isBusy: Bool { operation != nil }

    var needsVerification: Bool {
        status?.verification == .changedButUnverified
            || status?.recoveryRequired == true
    }

    var recoverableAction: PWMFanRecoveryAction? {
        guard status?.recoveryRequired == true else { return nil }
        return status?.recoveryAction
    }

    var isDetectionQuarantined: Bool {
        guard let detectionSafeAfter else { return false }
        return clock.now < detectionSafeAfter
    }

    private let controller: any PWMFanControlling
    private let clock = ContinuousClock()
    private let mutationQuarantine: Duration
    private var hasDetected = false
    private var operationID = UUID()
    private var detectionSafeAfter: ContinuousClock.Instant?

    init(
        controller: any PWMFanControlling,
        mutationQuarantine: Duration = .seconds(25)
    ) {
        self.controller = controller
        self.mutationQuarantine = mutationQuarantine
    }

    func detectIfNeeded() async {
        guard !hasDetected else { return }
        await detect(force: false)
    }

    func detectWhenSafeIfNeeded() async {
        if let detectionSafeAfter, clock.now < detectionSafeAfter {
            do {
                try await clock.sleep(until: detectionSafeAfter)
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        detectionSafeAfter = nil
        await detect(force: needsVerification || !hasDetected)
    }

    func detect(force: Bool) async {
        guard !isDetectionQuarantined else { return }
        guard operation == nil || operation == .detecting else { return }
        guard force || !hasDetected else { return }

        let id = begin(.detecting)
        do {
            let detected = try await controller.detect()
            try Task.checkCancellation()
            guard operationID == id else { return }
            let wasAwaitingVerification = needsVerification
            update(
                with: detected,
                startQuarantine: !wasAwaitingVerification
            )
            hasDetected = true
            errorMessage = nil
            noticeMessage = nil
        } catch is CancellationError {
            guard operationID == id else { return }
            hasDetected = false
            finish(id)
            return
        } catch {
            guard operationID == id else { return }
            hasDetected = false
            errorMessage = displayMessage(for: error)
        }
        finish(id)
    }

    func provision(configuration: PWMFanConfiguration) async {
        guard let status, status.ownership == .absent else {
            errorMessage = "Fan setup changed. Refresh detection before continuing."
            return
        }
        let backend: PWMFanBackend = configuration.mode == .manual
            ? .sysfs
            : .gpioFan
        await performMutation(
            operation: .provisioning,
            fallbackPin: configuration.pin,
            fallbackBackend: backend,
            unknownDetail: "Fan setup may have reached the server, but its resulting state is unknown.",
            success: { updated in
                updated.transition == nil
                    ? "Fan setup verified."
                    : "Fan setup prepared. Complete the reboot checklist when ready."
            }
        ) {
            try await controller.provision(configuration: configuration)
        }
    }

    func provision(pin: PWMFanGPIOPin, dutyPercent: Int) async {
        guard let configuration = try? PWMFanConfiguration.manual(
            PWMFanManualConfiguration(
                pin: pin,
                dutyPercent: clamped(dutyPercent)
            )
        ) else {
            errorMessage = PWMFanError.invalidDutyPercent.localizedDescription
            return
        }
        await provision(configuration: configuration)
    }

    func prepareConfigurationChange(
        to configuration: PWMFanConfiguration
    ) async {
        guard status?.ownership == .managed,
              status?.transition == nil else {
            errorMessage = "A stable app-managed configuration is required."
            return
        }
        await performMutation(
            operation: .preparingConfiguration,
            fallbackPin: status?.pin,
            fallbackBackend: status?.backend,
            unknownDetail: "Configuration preparation may have reached the server, but its resulting state is unknown.",
            success: { updated in
                guard let requirement = updated.transition?.requirement else {
                    return "Configuration change verified."
                }
                return requirement == .fullShutdown
                    ? "GPIO transition prepared. Follow the full shutdown and wiring checklist."
                    : "Configuration change prepared. Reboot when ready."
            }
        ) {
            try await controller.prepareConfigurationChange(to: configuration)
        }
    }

    func cancelPreparedChange() async {
        guard status?.transition?.phase == .prepared else {
            errorMessage = "Only a target prepared in the current boot can be cancelled."
            return
        }
        await performMutation(
            operation: .cancellingPrepared,
            unknownDetail: "Prepared-change cancellation may have reached the server, but its resulting state is unknown.",
            success: { _ in "Prepared change cancelled." }
        ) {
            try await controller.cancelPreparedChange()
        }
    }

    func finalizePreparedChange() async {
        guard status?.transition?.phase == .bootedAwaitingConfirmation else {
            errorMessage = "The prepared target must boot before it can be finalized."
            return
        }
        await performMutation(
            operation: .finalizing,
            unknownDetail: "Finalization may have reached the server, but its resulting state is unknown.",
            success: { _ in "Prepared target finalized." }
        ) {
            try await controller.finalizePreparedChange()
        }
    }

    func prepareRollback() async {
        guard status?.transition?.phase == .bootedAwaitingConfirmation else {
            errorMessage = "Rollback is available only after the prepared target boots."
            return
        }
        await performMutation(
            operation: .preparingRollback,
            unknownDetail: "Rollback preparation may have reached the server, but its resulting state is unknown.",
            success: { updated in
                updated.transition?.requirement == .fullShutdown
                    ? "Rollback prepared. Follow the full shutdown and wiring checklist."
                    : "Rollback prepared. Reboot when ready."
            }
        ) {
            try await controller.prepareRollback()
        }
    }

    func uninstallManaged() async {
        let isFinalization = status?.transition?.kind == .uninstall
            && status?.transition?.phase == .bootedAwaitingConfirmation
        guard status?.ownership == .managed || isFinalization else {
            errorMessage = "Only an app-managed fan setup can be uninstalled."
            return
        }
        await performMutation(
            operation: isFinalization ? .finalizingUninstall : .preparingUninstall,
            unknownDetail: "Uninstall may have reached the server, but its resulting state is unknown.",
            success: { updated in
                updated.transition == nil
                    ? "App-managed fan control uninstalled."
                    : "Uninstall prepared. Follow the shutdown checklist when ready."
            }
        ) {
            try await controller.uninstallManaged()
        }
    }

    func convertExactLegacyFan50() async {
        guard status?.legacyState == .exactConvertible else {
            errorMessage = PWMFanError.legacyConversionUnavailable.localizedDescription
            return
        }
        await performMutation(
            operation: .convertingLegacy,
            fallbackPin: .gpio18,
            fallbackBackend: .sysfs,
            unknownDetail: "Legacy conversion may have reached the server, but its resulting state is unknown.",
            success: { _ in
                "Exact legacy setup converted. Restore or discard its backup before changing GPIO."
            }
        ) {
            try await controller.convertExactLegacyFan50()
        }
    }

    func resolveLegacyBackup(
        _ resolution: PWMFanLegacyBackupResolution
    ) async {
        guard status?.legacyState == .backupAwaitingResolution else {
            errorMessage = "No converted legacy backup is awaiting a decision."
            return
        }
        await performMutation(
            operation: resolution == .restore
                ? .restoringLegacyBackup
                : .discardingLegacyBackup,
            unknownDetail: "Legacy backup resolution may have reached the server, but its resulting state is unknown.",
            success: { _ in
                resolution == .restore
                    ? "Legacy fan50 setup restored."
                    : "Legacy backup discarded."
            }
        ) {
            try await controller.resolveLegacyBackup(resolution)
        }
    }

    func apply(dutyPercent: Int, persist: Bool) async {
        guard let status else { return }
        guard status.transition == nil else {
            errorMessage = "Manual duty is unavailable during a prepared change."
            return
        }
        switch status.ownership {
        case .external, .managed:
            break
        case .absent, .conflict:
            errorMessage = "PWM duty cannot be changed for this configuration."
            return
        }

        let dutyPercent = clamped(dutyPercent)
        await performMutation(
            operation: .applying,
            fallbackPin: status.pin,
            fallbackBackend: status.backend,
            unknownDetail: "The PWM-duty command may have reached the server, but its resulting duty is unknown.",
            success: { _ in
                dutyPercent == 0
                    ? "PWM duty set to 0%. Monitor CPU temperature."
                    : "PWM duty set to \(dutyPercent)%."
            }
        ) {
            try await controller.apply(
                dutyPercent: dutyPercent,
                persist: persist
            )
        }
    }

    func restoreAutomatic() async {
        guard status?.canRestoreAutomatic == true else {
            errorMessage = "No verified automatic fan controller is available."
            return
        }
        await performMutation(
            operation: .restoringAutomatic,
            fallbackPin: status?.pin,
            fallbackBackend: status?.backend,
            unknownDetail: "Returning control to gpio-fan may have reached the server, but the active controller is unknown.",
            success: { _ in "Automatic gpio-fan control restored." }
        ) {
            try await controller.restoreAutomatic()
        }
    }

    func recover(_ action: PWMFanRecoveryAction) async {
        guard let status,
              status.recoveryRequired,
              status.recoveryAction == action else {
            errorMessage = "Recovery changed. Refresh detection before continuing."
            return
        }
        guard !isDetectionQuarantined else {
            errorMessage = "Wait for the verification delay before retrying recovery."
            return
        }

        let operation: PWMFanOperation
        switch action {
        case .cancelPreparedChange:
            operation = .cancellingPrepared
        case .completeRollbackPreparation:
            operation = .preparingRollback
        case .finalizePreparedChange:
            operation = .finalizing
        case .completeUninstall:
            operation = .finalizingUninstall
        case .completeLegacyConversion:
            operation = .convertingLegacy
        case .completeLegacyRestore:
            operation = .restoringLegacyBackup
        case .completeLegacyDiscard:
            operation = .discardingLegacyBackup
        case .completeManagedApply:
            operation = .applying
        case .completeStateCleanup:
            operation = .finalizingUninstall
        }

        await performMutation(
            operation: operation,
            fallbackPin: status.pin,
            fallbackBackend: status.backend,
            unknownDetail: "The recovery retry may have reached the server, but its resulting state is unknown.",
            success: { _ in Self.recoverySuccessMessage(action) }
        ) {
            switch action {
            case .cancelPreparedChange:
                return try await controller.cancelPreparedChange()
            case .completeRollbackPreparation:
                return try await controller.prepareRollback()
            case .finalizePreparedChange:
                return try await controller.finalizePreparedChange()
            case .completeUninstall:
                return try await controller.uninstallManaged()
            case .completeLegacyConversion:
                return try await controller.convertExactLegacyFan50()
            case .completeLegacyRestore:
                return try await controller.resolveLegacyBackup(.restore)
            case .completeLegacyDiscard:
                return try await controller.resolveLegacyBackup(.discard)
            case .completeManagedApply:
                return try await controller.completeManagedApply()
            case .completeStateCleanup:
                return try await controller.completeStateCleanup()
            }
        }
    }

    func cancelCurrentOperation() {
        let interruptedOperation = operation
        operationID = UUID()
        operation = nil

        guard let interruptedOperation else { return }
        if interruptedOperation == .detecting {
            hasDetected = false
        } else {
            markMutationUnverified(
                operation: interruptedOperation,
                detail: "The fan operation was interrupted while leaving this screen. Its resulting server state is unknown."
            )
            errorMessage = "Refresh fan detection and verify the expected output before another change."
        }
    }

    private func performMutation(
        operation: PWMFanOperation,
        fallbackPin: PWMFanGPIOPin? = nil,
        fallbackBackend: PWMFanBackend? = nil,
        unknownDetail: String,
        success: (PWMFanStatus) -> String,
        action: () async throws -> PWMFanStatus
    ) async {
        let id = begin(operation)
        do {
            let updated = try await action()
            try Task.checkCancellation()
            guard operationID == id else { return }
            update(with: updated)
            hasDetected = true
            errorMessage = nil
            noticeMessage = updated.verification == .changedButUnverified
                || updated.recoveryRequired
                ? "The command may have reached the server, but its result could not be verified. Wait for detection and check cooling."
                : success(updated)
        } catch is CancellationError {
            guard operationID == id else { return }
            markMutationUnverified(
                operation: operation,
                fallbackPin: fallbackPin,
                fallbackBackend: fallbackBackend,
                detail: unknownDetail
            )
            errorMessage = "The fan operation was interrupted. Wait for detection and verify cooling before another change."
            finish(id)
            return
        } catch {
            guard operationID == id else { return }
            markMutationUnverified(
                operation: operation,
                fallbackPin: fallbackPin,
                fallbackBackend: fallbackBackend,
                detail: unknownDetail
            )
            errorMessage = displayMessage(for: error)
        }
        finish(id)
    }

    private func begin(_ operation: PWMFanOperation) -> UUID {
        let id = UUID()
        operationID = id
        self.operation = operation
        errorMessage = nil
        noticeMessage = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operation = nil
    }

    private func update(
        with status: PWMFanStatus,
        startQuarantine: Bool = true
    ) {
        self.status = status
        if status.verification == .changedButUnverified
            || status.recoveryRequired {
            if startQuarantine {
                beginMutationQuarantine()
            } else {
                detectionSafeAfter = nil
            }
        } else {
            detectionSafeAfter = nil
        }

        if let configuration = status.activeConfiguration {
            selectedMode = configuration.mode
            selectedPin = configuration.pin
            switch configuration {
            case let .manual(value):
                selectedDutyPercent = clamped(value.dutyPercent)
            case let .automatic(value):
                selectedTurnOnCelsius = value.turnOnCelsius
                selectedHysteresisCelsius = value.hysteresisCelsius
            }
        } else {
            if let pin = status.pin {
                selectedPin = pin
            }
            if let dutyPercent = status.dutyPercent {
                selectedDutyPercent = clamped(dutyPercent)
            }
            if status.ownership == .absent {
                if !status.manualControlAvailable,
                   status.automaticControlAvailable {
                    selectedMode = .automatic
                } else if status.manualControlAvailable,
                          !status.automaticControlAvailable {
                    selectedMode = .manual
                }
            }
        }
    }

    private func clamped(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private static func recoverySuccessMessage(
        _ action: PWMFanRecoveryAction
    ) -> String {
        switch action {
        case .cancelPreparedChange:
            return "Prepared change cancellation recovered."
        case .completeRollbackPreparation:
            return "Interrupted rollback preparation completed."
        case .finalizePreparedChange:
            return "Prepared target finalization recovered."
        case .completeUninstall:
            return "App-managed fan uninstall recovered."
        case .completeLegacyConversion:
            return "Legacy conversion recovered. Resolve its backup before another configuration change."
        case .completeLegacyRestore:
            return "Legacy backup restoration recovered."
        case .completeLegacyDiscard:
            return "Legacy backup discard recovered."
        case .completeManagedApply:
            return "App-managed duty and saved default reconciled."
        case .completeStateCleanup:
            return "Casa Native lifecycle publication and cleanup reconciled."
        }
    }

    private func markMutationUnverified(
        operation: PWMFanOperation?,
        fallbackPin: PWMFanGPIOPin? = nil,
        fallbackBackend: PWMFanBackend? = nil,
        detail: String
    ) {
        let previous = status
        let inferredBackend: PWMFanBackend? = {
            if let backend = previous?.backend { return backend }
            if let fallbackBackend { return fallbackBackend }
            return operation == .provisioning ? .sysfs : nil
        }()

        status = PWMFanStatus(
            ownership: .conflict,
            backend: inferredBackend,
            pin: previous?.pin ?? fallbackPin,
            periodNanoseconds: previous?.periodNanoseconds,
            dutyPercent: previous?.dutyPercent,
            isEnabled: nil,
            isRuntimeAvailable: false,
            requiresReboot: previous?.requiresReboot ?? false,
            canRestoreAutomatic: false,
            detail: detail,
            verification: .changedButUnverified,
            activeConfiguration: previous?.activeConfiguration,
            transition: previous?.transition,
            automaticDemand: .unknown,
            legacyState: previous?.legacyState ?? .none,
            recoveryRequired: true,
            manualControlAvailable: previous?.manualControlAvailable ?? false,
            automaticControlAvailable: previous?.automaticControlAvailable ?? false
        )
        hasDetected = false
        noticeMessage = nil
        beginMutationQuarantine()
    }

    private func beginMutationQuarantine() {
        detectionSafeAfter = clock.now.advanced(by: mutationQuarantine)
        verificationCycle = UUID()
    }

    private func displayMessage(for error: any Error) -> String {
        if let fanError = error as? PWMFanError,
           fanError == .missingCredentials {
            return "No SSH sign-in is saved for this server. Return to Settings and save the selected SSH sign-in, or open Terminal to enter it."
        }
        return error.localizedDescription
    }
}

enum PWMFanOperation: Equatable {
    case detecting
    case provisioning
    case applying
    case restoringAutomatic
    case preparingConfiguration
    case cancellingPrepared
    case finalizing
    case preparingRollback
    case preparingUninstall
    case finalizingUninstall
    case convertingLegacy
    case restoringLegacyBackup
    case discardingLegacyBackup

    var progressTitle: String {
        switch self {
        case .detecting:
            return "Checking fan configuration…"
        case .provisioning:
            return "Preparing fan setup…"
        case .applying:
            return "Applying PWM duty…"
        case .restoringAutomatic:
            return "Returning to automatic control…"
        case .preparingConfiguration:
            return "Preparing configuration change…"
        case .cancellingPrepared:
            return "Cancelling prepared change…"
        case .finalizing:
            return "Finalizing prepared target…"
        case .preparingRollback:
            return "Preparing rollback…"
        case .preparingUninstall:
            return "Preparing uninstall…"
        case .finalizingUninstall:
            return "Finalizing uninstall…"
        case .convertingLegacy:
            return "Converting exact legacy setup…"
        case .restoringLegacyBackup:
            return "Restoring legacy backup…"
        case .discardingLegacyBackup:
            return "Discarding legacy backup…"
        }
    }
}

private enum PWMFanConfirmation {
    case provision(PWMFanConfiguration)
    case apply(dutyPercent: Int, persist: Bool, requiresSudo: Bool)
    case restoreAutomatic
    case prepareConfiguration(PWMFanConfiguration, pinChange: Bool)
    case cancelPrepared
    case finalize
    case rollback
    case uninstall
    case finalizeUninstall
    case convertLegacy
    case resolveLegacy(PWMFanLegacyBackupResolution)
    case recover(PWMFanRecoveryAction)
}

private extension PWMFanControlMode {
    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .automatic:
            return "Automatic"
        }
    }
}

@MainActor
private final class PWMFanHostKeyConfirmationModel:
    ObservableObject,
    @unchecked Sendable
{
    @Published private(set) var prompt: SSHHostKeyPrompt?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestApproval(for prompt: SSHHostKeyPrompt) async -> Bool {
        resolve(accepted: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.prompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(accepted: false)
            }
        }
    }

    func resolve(accepted: Bool) {
        prompt = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: accepted)
    }
}
