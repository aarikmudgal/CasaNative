import Combine
import Foundation
import SwiftUI

protocol AppPreferenceStoring: AnyObject {
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: AppPreferenceStoring {}

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System Default"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case checking
        case needsServer
        case needsLogin
        case connected
    }

    private static let endpointKey = "savedEndpoint"
    private static let mockKey = "mockModeEnabled"
    private static let appearanceKey = "appearanceMode"
    private static let sshCredentialModeKey = "sshCredentialMode"
    private static let usernameKey = "casaOSUsername"
    private let preferences: any AppPreferenceStoring

    @Published var connectionState: ConnectionState = .checking
    @Published var endpointText = ""
    @Published var endpointError: String?
    @Published var username = ""
    @Published var loginError: String?
    @Published private(set) var sshCredentialError: String?
    @Published var isWorking = false
    @Published var appearanceMode: AppearanceMode {
        didSet {
            preferences.set(appearanceMode.rawValue, forKey: Self.appearanceKey)
        }
    }
    @Published var sshCredentialMode: SSHCredentialMode {
        didSet {
            preferences.set(
                sshCredentialMode.rawValue,
                forKey: Self.sshCredentialModeKey
            )
        }
    }
    @Published var mockMode: Bool {
        didSet {
            guard !Self.hasMockModeLaunchOverride() else { return }
            preferences.set(mockMode, forKey: Self.mockKey)
        }
    }

    @Published private(set) var activeEndpoint: ServerEndpoint?
    @Published private(set) var client: any CasaOSClient
    let sshCredentialStore: any SSHCredentialStoring

    init(
        sshCredentialStore: any SSHCredentialStoring = SSHCredentialStore(),
        preferences: any AppPreferenceStoring = UserDefaults.standard
    ) {
        self.preferences = preferences
        appearanceMode = AppearanceMode(
            rawValue: preferences.string(forKey: Self.appearanceKey) ?? ""
        ) ?? .system
        sshCredentialMode = SSHCredentialMode(
            rawValue: preferences.string(
                forKey: Self.sshCredentialModeKey
            ) ?? ""
        ) ?? .casaOS
        mockMode = preferences.bool(forKey: Self.mockKey)
        client = MockCasaOSClient()
        self.sshCredentialStore = sshCredentialStore
        username = preferences.string(forKey: Self.usernameKey) ?? ""

        if mockMode {
            endpointText = "http://casaos.local"
            connectionState = .connected
        } else if let saved = preferences.string(forKey: Self.endpointKey) {
            endpointText = saved
            configureSavedEndpoint(saved)
        } else {
            connectionState = .needsServer
        }
    }

    static func hasMockModeLaunchOverride(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        let key = "-\(mockKey)"
        return arguments.contains(key)
            || arguments.contains { $0.hasPrefix(key + "=") }
    }

    func beginMockMode() {
        mockMode = true
        client = MockCasaOSClient()
        activeEndpoint = nil
        endpointText = "http://casaos.local"
        endpointError = nil
        loginError = nil
        connectionState = .connected
    }

    func useEndpoint(source: ServerEndpoint.Source = .manual) async {
        isWorking = true
        defer { isWorking = false }

        do {
            let endpoint = try ServerEndpoint(endpointText, source: source)
            let candidate = HTTPCasaOSClient(baseURL: endpoint.url)
            try await candidate.verifyServer()
            activeEndpoint = endpoint
            client = candidate
            endpointText = endpoint.url.absoluteString
            endpointError = nil
            mockMode = false
            preferences.set(endpoint.url.absoluteString, forKey: Self.endpointKey)
            connectionState = try await restoreValidatedSession(using: candidate)
                ? .connected
                : .needsLogin
        } catch {
            endpointError = error.localizedDescription
        }
    }

    func useDiscoveredEndpoint(_ endpoint: ServerEndpoint) async {
        endpointText = endpoint.url.absoluteString
        await useEndpoint(source: endpoint.source)
    }

    func login(password: String) async {
        guard !username.isEmpty, !password.isEmpty else {
            loginError = "Enter your CasaOS username and password."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try await client.login(username: username, password: password)
            if sshCredentialMode == .casaOS {
                do {
                    try await sshCredentialStore.storeCasaOS(
                        SSHCredentials(username: username, password: password),
                        for: serverURL
                    )
                    sshCredentialError = nil
                } catch {
                    sshCredentialError = "CasaOS sign-in succeeded, but its SSH credentials could not be saved. Save them again in Settings."
                }
            }
            preferences.set(username, forKey: Self.usernameKey)
            loginError = nil
            connectionState = .connected
        } catch {
            loginError = error.localizedDescription
        }
    }

    func disconnect() async {
        let endpoint = activeEndpoint?.url
        await client.logout()
        if let endpoint {
            try? await sshCredentialStore.deleteAll(for: endpoint)
        }
        activeEndpoint = nil
        mockMode = false
        preferences.removeObject(forKey: Self.endpointKey)
        endpointText = ""
        username = ""
        sshCredentialError = nil
        preferences.removeObject(forKey: Self.usernameKey)
        connectionState = .needsServer
    }

    func hasCasaOSCredentialsForSSH() async -> Bool {
        guard !mockMode else { return false }
        return (try? await sshCredentialStore.load(
            mode: .casaOS,
            for: serverURL
        )) != nil
    }

    func saveCasaOSCredentialsForSSH(
        username: String,
        password: String
    ) async throws {
        let cleanUsername = username.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !cleanUsername.isEmpty, !password.isEmpty else {
            throw SSHCredentialStoreError.incompleteCredentials
        }

        try await client.login(username: cleanUsername, password: password)
        try await sshCredentialStore.storeCasaOS(
            SSHCredentials(username: cleanUsername, password: password),
            for: serverURL
        )
        sshCredentialError = nil
        self.username = cleanUsername
        preferences.set(cleanUsername, forKey: Self.usernameKey)
    }

    func showConnection() {
        connectionState = activeEndpoint == nil ? .needsServer : .needsLogin
    }

    var displayedEndpoint: String {
        mockMode ? "Mock server" : (activeEndpoint?.url.absoluteString ?? endpointText)
    }

    var serverURL: URL {
        activeEndpoint?.url ?? URL(string: "http://casaos.local")!
    }

    private func configureSavedEndpoint(_ saved: String) {
        do {
            let endpoint = try ServerEndpoint(saved, source: inferSource(saved))
            activeEndpoint = endpoint
            client = HTTPCasaOSClient(baseURL: endpoint.url)
            Task {
                do {
                    try await (client as? HTTPCasaOSClient)?.verifyServer()
                    connectionState = try await restoreValidatedSession(using: client)
                        ? .connected
                        : .needsLogin
                } catch {
                    endpointError = error.localizedDescription
                    connectionState = .needsServer
                }
            }
        } catch {
            endpointError = error.localizedDescription
            connectionState = .needsServer
        }
    }

    private func inferSource(_ value: String) -> ServerEndpoint.Source {
        value.localizedCaseInsensitiveContains(".ts.net") ? .tailscale : .manual
    }

    private func restoreValidatedSession(
        using client: any CasaOSClient
    ) async throws -> Bool {
        guard try await client.restoreSession() else { return false }
        do {
            try await client.validateSession()
            return true
        } catch CasaOSError.unauthorized {
            return false
        }
    }
}
