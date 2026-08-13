import Foundation
import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: AppModel

    @State private var source: ServerEndpoint.Source = .manual
    @StateObject private var discovery = BonjourDiscovery()
    @State private var discoveryError: String?
    @State private var isProbingCommonHost = false
    @State private var attemptedServiceIDs: Set<String> = []

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 38))
                        .foregroundStyle(.tint)
                    Text("Connect to CasaOS")
                        .font(.title2.bold())
                    Text("Use a local address or your Tailscale MagicDNS name.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Connection") {
                Picker("Route", selection: $source) {
                    Text("Local").tag(ServerEndpoint.Source.manual)
                    Text("Tailscale").tag(ServerEndpoint.Source.tailscale)
                }
                .pickerStyle(.segmented)

                TextField(
                    source == .tailscale ? "casaos or https://host.tailnet.ts.net" : "casaos.local or 192.168.1.20",
                    text: $model.endpointText
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onSubmit(connect)

                if let error = model.endpointError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button(action: connect) {
                    if model.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.endpointText.isEmpty)

                if source == .tailscale {
                    Text("For HTTP, use the short MagicDNS hostname while Tailscale is connected. Use the full .ts.net name only with HTTPS configured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Local network") {
                if isSearching || isProbingCommonHost {
                    Label("Searching for CasaOS…", systemImage: "network")
                        .foregroundStyle(.secondary)
                }

                Button(isSearching ? "Stop searching" : "Find advertised CasaOS") {
                    isSearching ? discovery.stop() : discovery.start()
                }

                ForEach(discovery.services) { service in
                    Button {
                        Task { await connect(to: service) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(service.displayName)
                            Text(service.type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let discoveryError {
                    Text(discoveryError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if case let .failed(message) = discovery.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("Casa Native searches automatically. Stock CasaOS does not advertise itself, so reliable multi-server discovery needs the optional Avahi service; manual and Tailscale addresses always work.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Explore with demo data") {
                    model.beginMockMode()
                }
            } footer: {
                Text("Demo mode never contacts your server.")
            }
        }
        .navigationTitle("Casa Native")
        .task { await startAutomaticDiscovery() }
        .onChange(of: discovery.services) { _, services in
            Task { await connectToFirstVerifiedService(in: services) }
        }
        .onDisappear { discovery.stop() }
    }

    private func connect() {
        Task { await model.useEndpoint(source: source) }
    }

    private func connect(to service: BonjourDiscovery.DiscoveredService) async {
        do {
            let endpoint = try await discovery.resolve(service)
            let probe = HTTPCasaOSClient(baseURL: endpoint.url)
            try await probe.verifyServer()
            discoveryError = nil
            await model.useDiscoveredEndpoint(endpoint)
        } catch let error as CasaOSError {
            discoveryError = error.localizedDescription
        } catch {
            discoveryError = "That advertised web service is not CasaOS. \(error.localizedDescription)"
        }
    }

    private func startAutomaticDiscovery() async {
        guard model.connectionState == .needsServer else { return }
        attemptedServiceIDs.removeAll()
        discovery.start()
        isProbingCommonHost = true
        defer { isProbingCommonHost = false }

        do {
            let endpoint = try ServerEndpoint(
                "http://casaos.local",
                source: .bonjour
            )
            try await verifyCasaOS(endpoint)
            guard model.connectionState == .needsServer else { return }
            await model.useDiscoveredEndpoint(endpoint)
        } catch {
            // Most stock installations do not use this hostname. Keep browsing
            // and leave manual entry available without presenting an error.
        }
    }

    private func connectToFirstVerifiedService(
        in services: [BonjourDiscovery.DiscoveredService]
    ) async {
        guard model.connectionState == .needsServer else { return }

        for service in services where attemptedServiceIDs.insert(service.id).inserted {
            do {
                let endpoint = try await discovery.resolve(service)
                try await verifyCasaOS(endpoint)
                guard model.connectionState == .needsServer else { return }
                await model.useDiscoveredEndpoint(endpoint)
                return
            } catch {
                // Generic HTTP Bonjour results are common. Ignore anything that
                // does not pass the exact CasaOS status probe.
            }
        }
    }

    private func verifyCasaOS(_ endpoint: ServerEndpoint) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        let probe = HTTPCasaOSClient(
            baseURL: endpoint.url,
            tokenStore: InMemorySessionTokenStore(),
            session: URLSession(configuration: configuration)
        )
        try await probe.verifyServer()
    }

    private var isSearching: Bool {
        switch discovery.state {
        case .searching, .ready:
            true
        case .stopped, .failed:
            false
        }
    }
}

struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in")
                        .font(.title2.bold())
                    Text(model.displayedEndpoint)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("CasaOS account") {
                TextField("Username", text: $model.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(signIn)

                if let error = model.loginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button(action: signIn) {
                    if model.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Sign in").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.username.isEmpty || password.isEmpty)
            }

            Section {
                Button("Use another server") {
                    Task { await model.disconnect() }
                }
            }
        }
        .navigationTitle("CasaOS")
    }

    private func signIn() {
        Task {
            await model.login(password: password)
            if model.connectionState == .connected { password = "" }
        }
    }
}
