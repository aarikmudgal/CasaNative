import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var pendingPowerState: PowerState?
    @State private var powerError: String?
    @State private var isPowering = false
    @State private var isConfirmingDisconnect = false
    @State private var isDisconnecting = false
    @State private var hasCasaOSSSHCredentials: Bool?
    @State private var isShowingCasaOSSSHSetup = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Mode", value: model.mockMode ? "Demo" : "CasaOS")

                if !model.mockMode {
                    LabeledContent("Connected via", value: connectionSourceTitle)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Server address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.displayedEndpoint)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)

                Button(
                    disconnectButtonTitle,
                    systemImage: model.mockMode
                        ? "xmark.circle"
                        : "rectangle.portrait.and.arrow.right",
                    role: model.mockMode ? nil : .destructive
                ) {
                    isConfirmingDisconnect = true
                }
                .disabled(isDisconnecting || isPowering)
            } header: {
                Text("Server")
            } footer: {
                Text(model.mockMode
                     ? "Demo mode uses sample data and never contacts a server."
                     : "The saved address is used for this CasaOS connection.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $model.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(appearanceTitle(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Appearance")
            }

            Section {
                Picker("Credentials", selection: $model.sshCredentialMode) {
                    ForEach(SSHCredentialMode.allCases) { mode in
                        Text(mode == .casaOS ? "CasaOS sign-in" : "Separate sign-in")
                            .tag(mode)
                    }
                }

                if model.sshCredentialMode == .casaOS {
                    if hasCasaOSSSHCredentials == nil {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking saved sign-in…")
                                .foregroundStyle(.secondary)
                        }
                    } else if hasCasaOSSSHCredentials == true {
                        Label("CasaOS sign-in ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        if let error = model.sshCredentialError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        Button(
                            "Save CasaOS Sign-in for SSH",
                            systemImage: "key.fill"
                        ) {
                            isShowingCasaOSSSHSetup = true
                        }
                    }
                }

                NavigationLink {
                    SSHTerminalView(
                        serverURL: model.serverURL,
                        credentialMode: model.sshCredentialMode,
                        credentialStore: model.sshCredentialStore,
                        defaultUsername: model.username
                    )
                } label: {
                    Label("Open SSH Terminal", systemImage: "terminal")
                }
                .disabled(!canOpenSSHTerminal)
            } header: {
                Text("SSH Terminal")
            } footer: {
                Text(sshFooter)
            }

            Section {
                NavigationLink {
                    FanControlDestinationView(model: model)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PWM Fan Control")
                            Text(model.mockMode
                                 ? "Explore safely with a simulated fan"
                                 : "Manual PWM or automatic temperature policy")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "fan.fill")
                    }
                }
            } header: {
                Text("Hardware")
            } footer: {
                Text(model.mockMode
                     ? "Demo fan controls are local to this app and never contact a server."
                     : "Detection is read-only. Confirmed SSH changes use staged setup, reboot or full-shutdown checklists, and an explicit final decision.")
            }

            Section {
                Button("Restart CasaOS", systemImage: "arrow.clockwise") {
                    pendingPowerState = .restart
                }
                .disabled(model.mockMode || isPowering)
                Button("Shut down CasaOS", systemImage: "power", role: .destructive) {
                    pendingPowerState = .shutdown
                }
                .disabled(model.mockMode || isPowering)

                if isPowering {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Sending power command…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Server Power")
            } footer: {
                Text(model.mockMode
                     ? "Power controls are unavailable in demo mode."
                     : "CasaOS may close the connection before confirming a power command.")
            }

            Section {
                LabeledContent("App", value: "Casa Native")
                LabeledContent("Version", value: appVersion)
            } header: {
                Text("About")
            } footer: {
                Text("Lightweight personal CasaOS client for iOS 26 and newer.")
            }
        }
        .navigationTitle("Settings")
        .task(id: model.sshCredentialMode) {
            await refreshCasaOSSSHCredentialStatus()
        }
        .sheet(isPresented: $isShowingCasaOSSSHSetup) {
            CasaOSSSHCredentialSetupView(model: model) {
                hasCasaOSSSHCredentials = true
            }
        }
        .confirmationDialog(
            model.mockMode ? "Exit demo mode?" : "Disconnect from CasaOS?",
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            if model.mockMode {
                Button("Exit Demo") {
                    disconnect()
                }
            } else {
                Button("Disconnect and Forget Server", role: .destructive) {
                    disconnect()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.mockMode
                 ? "You’ll return to server setup."
                 : "This signs out and removes the saved server address from this iPhone.")
        }
        .confirmationDialog(
            powerDialogTitle,
            isPresented: Binding(
                get: { pendingPowerState != nil },
                set: { if !$0 { pendingPowerState = nil } }
            ),
            titleVisibility: .visible
        ) {
            if pendingPowerState == .shutdown {
                Button("Shut Down", role: .destructive) {
                    submitPendingPowerState()
                }
            } else {
                Button("Restart") {
                    submitPendingPowerState()
                }
            }
            Button("Cancel", role: .cancel) { pendingPowerState = nil }
        } message: {
            Text(powerDialogMessage)
        }
        .alert("Power command failed", isPresented: Binding(
            get: { powerError != nil },
            set: { if !$0 { powerError = nil } }
        )) {
            Button("OK", role: .cancel) { powerError = nil }
        } message: {
            Text(powerError ?? "Unknown error")
        }
    }

    private var connectionSourceTitle: String {
        switch model.activeEndpoint?.source {
        case .bonjour: "Local discovery"
        case .tailscale: "Tailscale"
        case .manual: "Server address"
        case nil: "Server address"
        }
    }

    private var disconnectButtonTitle: String {
        model.mockMode ? "Exit demo mode" : "Disconnect and forget server"
    }

    private var sshFooter: String {
        if model.mockMode {
            return "SSH is unavailable in demo mode."
        }
        if model.sshCredentialMode == .casaOS {
            return "Reuses the CasaOS username and password without asking again in Terminal. Restored sessions from an older build need one secure re-authentication here. This works only when the Linux SSH account has the same credentials."
        }
        return "Uses a separate Linux SSH sign-in stored in the device-only Keychain. Sessions are destroyed when Terminal loses focus."
    }

    private var canOpenSSHTerminal: Bool {
        guard !model.mockMode else { return false }
        return model.sshCredentialMode == .separate
            || hasCasaOSSSHCredentials == true
    }

    private func refreshCasaOSSSHCredentialStatus() async {
        guard model.sshCredentialMode == .casaOS else {
            hasCasaOSSSHCredentials = nil
            return
        }
        hasCasaOSSSHCredentials = await model.hasCasaOSCredentialsForSSH()
    }

    private var appVersion: String {
        guard let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, !shortVersion.isEmpty else {
            return "—"
        }
        return shortVersion
    }

    private var powerDialogTitle: String {
        pendingPowerState == .shutdown ? "Shut down CasaOS?" : "Restart CasaOS?"
    }

    private var powerDialogMessage: String {
        if pendingPowerState == .shutdown {
            "CasaOS and all running apps will become unavailable until the server is powered on again."
        } else {
            "CasaOS and all running apps will be briefly unavailable while the server restarts."
        }
    }

    private func appearanceTitle(for mode: AppearanceMode) -> String {
        mode == .system ? "System" : mode.title
    }

    private func disconnect() {
        isDisconnecting = true
        Task {
            await model.disconnect()
            isDisconnecting = false
        }
    }

    private func submitPendingPowerState() {
        guard let state = pendingPowerState else { return }
        pendingPowerState = nil
        Task { await setPower(state) }
    }

    private func setPower(_ state: PowerState) async {
        isPowering = true
        defer { isPowering = false }
        do {
            try await model.client.setPowerState(state)
        } catch {
            powerError = error.localizedDescription
        }
    }
}

private struct CasaOSSSHCredentialSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    let onSaved: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(model: AppModel, onSaved: @escaping () -> Void) {
        self.model = model
        self.onSaved = onSaved
        _username = State(initialValue: model.username)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("CasaOS username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("CasaOS password", text: $password)
                        .textContentType(.password)
                        .onSubmit(save)
                } header: {
                    Text("Confirm CasaOS Sign-in")
                } footer: {
                    Text("Casa Native verifies this with CasaOS, then keeps it in the device-only Keychain for direct SSH sign-in. It is never written to app preferences or logs.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: save) {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Verify and Save").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isSaving
                            || username.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            || password.isEmpty
                    )
                }
            }
            .navigationTitle("SSH Sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                try await model.saveCasaOSCredentialsForSSH(
                    username: username,
                    password: password
                )
                password = ""
                errorMessage = nil
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
