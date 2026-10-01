import CryptoKit
import Foundation
import Security
import WebKit

struct ContainerBrowserIdentity: Hashable, Sendable {
    let serverOrigin: EndpointOrigin
    let appID: String
    let launchOrigin: EndpointOrigin
    let storageKey: String

    init(serverURL: URL, appID: String, launchURL: URL) throws {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContainerBrowserStorageError.invalidAppID
        }
        serverOrigin = try Self.origin(for: serverURL)
        self.appID = appID
        launchOrigin = try Self.origin(for: launchURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        storageKey = Self.digest(try encoder.encode(Fields(
            serverOrigin: serverOrigin,
            appID: appID,
            launchOrigin: launchOrigin
        )))
    }

    func allowsCredentialFill(at url: URL?) -> Bool {
        guard let url, let origin = try? Self.origin(for: url) else {
            return false
        }
        return origin == launchOrigin
    }

    fileprivate static func origin(for url: URL) throws -> EndpointOrigin {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.user == nil, components.password == nil else {
            throw ContainerBrowserStorageError.invalidURL
        }
        do {
            return try EndpointOrigin(endpoint: url)
        } catch {
            throw ContainerBrowserStorageError.invalidURL
        }
    }

    fileprivate static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fields: Codable {
        let serverOrigin: EndpointOrigin
        let appID: String
        let launchOrigin: EndpointOrigin
    }
}

struct ContainerCredentials: Codable, Equatable, Sendable {
    let username: String
    let password: String

    // Some container apps, such as password-only dashboards, have no username.
    var isComplete: Bool { !password.isEmpty }
}

protocol ContainerCredentialStoring: Sendable {
    func save(
        _ credentials: ContainerCredentials,
        for identity: ContainerBrowserIdentity
    ) async throws
    func load(for identity: ContainerBrowserIdentity) async throws -> ContainerCredentials?
    func delete(for identity: ContainerBrowserIdentity) async throws
    func deleteAll(for serverURL: URL) async throws
}

enum ContainerBrowserStorageError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidAppID
    case incompleteCredentials
    case invalidCredentialData
    case unexpectedStatus(OSStatus)
    case invalidProfileRegistry
    case profileCleanupInProgress

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The app address must use HTTP or HTTPS without embedded credentials."
        case .invalidAppID:
            "The container app has no valid identifier."
        case .incompleteCredentials:
            "Enter the app password before saving its sign-in."
        case .invalidCredentialData:
            "The saved app sign-in could not be read. Save it again."
        case .unexpectedStatus:
            "Secure storage is unavailable. Unlock the device, then try again."
        case .invalidProfileRegistry:
            "The saved app browser profiles could not be read."
        case .profileCleanupInProgress:
            "App browser profiles are being removed. Try again when cleanup finishes."
        }
    }
}

actor ContainerCredentialStore: ContainerCredentialStoring {
    private let servicePrefix: String

    init(servicePrefix: String = "CasaNative.ContainerBrowser.Credentials") {
        self.servicePrefix = servicePrefix
    }

    func save(
        _ credentials: ContainerCredentials,
        for identity: ContainerBrowserIdentity
    ) async throws {
        guard credentials.isComplete else {
            throw ContainerBrowserStorageError.incompleteCredentials
        }
        let data = try JSONEncoder().encode(credentials)
        let lookup = baseQuery(for: identity)
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertion = lookup
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ContainerBrowserStorageError.unexpectedStatus(addStatus)
            }
        default:
            throw ContainerBrowserStorageError.unexpectedStatus(status)
        }
    }

    func load(for identity: ContainerBrowserIdentity) async throws -> ContainerCredentials? {
        var query = baseQuery(for: identity)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(ContainerCredentials.self, from: data),
                  credentials.isComplete else {
                throw ContainerBrowserStorageError.invalidCredentialData
            }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw ContainerBrowserStorageError.unexpectedStatus(status)
        }
    }

    func delete(for identity: ContainerBrowserIdentity) async throws {
        try delete(matching: baseQuery(for: identity))
    }

    func deleteAll(for serverURL: URL) async throws {
        let origin = try ContainerBrowserIdentity.origin(for: serverURL)
        try delete(matching: serviceQuery(for: origin))
    }

    private func delete(matching query: [CFString: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContainerBrowserStorageError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for identity: ContainerBrowserIdentity) -> [CFString: Any] {
        var query = serviceQuery(for: identity.serverOrigin)
        query[kSecAttrAccount] = identity.storageKey
        return query
    }

    private func serviceQuery(for origin: EndpointOrigin) -> [CFString: Any] {
        let serverKey = ContainerBrowserIdentity.digest(Data(origin.rawValue.utf8))
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "\(servicePrefix).\(serverKey)",
            kSecAttrSynchronizable: false,
        ]
    }
}

actor InMemoryContainerCredentialStore: ContainerCredentialStoring {
    private var credentialsByIdentity: [ContainerBrowserIdentity: ContainerCredentials] = [:]

    func save(
        _ credentials: ContainerCredentials,
        for identity: ContainerBrowserIdentity
    ) async throws {
        guard credentials.isComplete else {
            throw ContainerBrowserStorageError.incompleteCredentials
        }
        credentialsByIdentity[identity] = credentials
    }

    func load(for identity: ContainerBrowserIdentity) async throws -> ContainerCredentials? {
        credentialsByIdentity[identity]
    }

    func delete(for identity: ContainerBrowserIdentity) async throws {
        credentialsByIdentity[identity] = nil
    }

    func deleteAll(for serverURL: URL) async throws {
        let origin = try ContainerBrowserIdentity.origin(for: serverURL)
        credentialsByIdentity = credentialsByIdentity.filter { $0.key.serverOrigin != origin }
    }
}

@MainActor
final class ContainerBrowserProfileStore {
    private static let registryKey = "containerBrowserProfileRegistry.v1"
    private let preferences: any AppPreferenceStoring
    private var removingServers: Set<EndpointOrigin> = []

    init(preferences: any AppPreferenceStoring = UserDefaults.standard) {
        self.preferences = preferences
    }

    func dataStore(for identity: ContainerBrowserIdentity) throws -> WKWebsiteDataStore {
        guard !removingServers.contains(identity.serverOrigin) else {
            throw ContainerBrowserStorageError.profileCleanupInProgress
        }
        var registry = try loadRegistry()
        if let profile = registry[identity.storageKey] {
            guard profile.serverOrigin == identity.serverOrigin else {
                throw ContainerBrowserStorageError.invalidProfileRegistry
            }
            return WKWebsiteDataStore(forIdentifier: profile.identifier)
        }
        let profile = Profile(serverOrigin: identity.serverOrigin, identifier: UUID())
        registry[identity.storageKey] = profile
        try saveRegistry(registry)
        return WKWebsiteDataStore(forIdentifier: profile.identifier)
    }

    func clearSession(for identity: ContainerBrowserIdentity) async throws {
        let store = try dataStore(for: identity)
        await store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    // Every WKWebView using these profiles must be released before removal.
    // Failed removals remain registered so cleanup can be retried.
    func removeAll(for serverURL: URL) async throws {
        let origin = try ContainerBrowserIdentity.origin(for: serverURL)
        guard !removingServers.contains(origin) else {
            throw ContainerBrowserStorageError.profileCleanupInProgress
        }
        removingServers.insert(origin)
        defer { removingServers.remove(origin) }

        let profiles = try loadRegistry().filter { $0.value.serverOrigin == origin }
        for (key, profile) in profiles {
            try await removeProfile(identifier: profile.identifier)
            // Reload after suspension so profiles for other servers are preserved.
            var registry = try loadRegistry()
            guard registry[key] == profile else { continue }
            registry[key] = nil
            try saveRegistry(registry)
        }
    }

    private func removeProfile(identifier: UUID) async throws {
        try await prepareProfileForRemoval(identifier: identifier)
        var remainingRetries = 20
        while true {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                return
            } catch {
                let failure = error as NSError
                // WebKit releases its network session asynchronously after the final view
                // and data store references are released. Retry only that transient state.
                let isStillReleasing = failure.domain == "WKWebSiteDataStore"
                    && failure.code == WKError.unknown.rawValue
                    && ["Data store is in use", "Data store is in use (by network process)"]
                        .contains(failure.localizedDescription)
                guard isStillReleasing, remainingRetries > 0 else { throw error }
                remainingRetries -= 1
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func prepareProfileForRemoval(identifier: UUID) async throws {
        // Some WebKit runtimes cannot remove a named store that was allocated but never
        // materialized on disk. Initialize it through the public cookie API, not private
        // filesystem paths. This inert reserved-domain cookie never makes a network request.
        // The subsequent removal must still succeed; no filesystem failure is suppressed.
        var store: WKWebsiteDataStore? = autoreleasepool { WKWebsiteDataStore(forIdentifier: identifier) }
        guard let marker = HTTPCookie(properties: [
            .domain: "casanative-cleanup.invalid", .path: "/",
            .name: "CasaNativeProfileCleanup", .value: "1",
            .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 60),
        ]) else { throw ContainerBrowserStorageError.invalidProfileRegistry }
        var cookies: WKHTTPCookieStore? = store!.httpCookieStore
        await cookies!.setCookie(marker)
        autoreleasepool { cookies = nil; store = nil }
    }

    private struct Profile: Codable, Equatable {
        let serverOrigin: EndpointOrigin
        let identifier: UUID
    }

    private func loadRegistry() throws -> [String: Profile] {
        guard let saved = preferences.string(forKey: Self.registryKey) else { return [:] }
        guard let data = saved.data(using: .utf8),
              let registry = try? JSONDecoder().decode([String: Profile].self, from: data),
              Set(registry.values.map(\.identifier)).count == registry.count,
              registry.values.allSatisfy({ $0.identifier != Self.zeroIdentifier }) else {
            throw ContainerBrowserStorageError.invalidProfileRegistry
        }
        return registry
    }

    private func saveRegistry(_ registry: [String: Profile]) throws {
        if registry.isEmpty {
            preferences.removeObject(forKey: Self.registryKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(registry)
        guard let saved = String(data: data, encoding: .utf8) else {
            throw ContainerBrowserStorageError.invalidProfileRegistry
        }
        preferences.set(saved, forKey: Self.registryKey)
    }

    private static let zeroIdentifier = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
