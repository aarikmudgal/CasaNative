import Foundation
import Security

struct SessionTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

struct EndpointOrigin: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(endpoint: URL) throws {
        guard
            let components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            ),
            let rawScheme = components.scheme,
            let rawHost = components.host
        else {
            throw KeychainStoreError.invalidEndpoint
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw KeychainStoreError.invalidEndpoint
        }

        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else {
            throw KeychainStoreError.invalidEndpoint
        }

        let port = components.port
        if let port, !(1...65_535).contains(port) {
            throw KeychainStoreError.invalidEndpoint
        }

        let defaultPort = scheme == "http" ? 80 : 443
        let normalizedPort = port == defaultPort ? nil : port
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        let portSuffix = normalizedPort.map { ":\($0)" } ?? ""

        rawValue = "\(scheme)://\(renderedHost)\(portSuffix)"
    }

    init(endpoint: String) throws {
        guard let url = URL(string: endpoint) else {
            throw KeychainStoreError.invalidEndpoint
        }
        try self.init(endpoint: url)
    }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(endpoint: container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

protocol SessionTokenStore: Sendable {
    func store(_ tokens: SessionTokens, for origin: EndpointOrigin) async throws
    func load(for origin: EndpointOrigin) async throws -> SessionTokens?
    func delete(for origin: EndpointOrigin) async throws
}

extension SessionTokenStore {
    func store(_ tokens: SessionTokens, for endpoint: URL) async throws {
        try await store(tokens, for: EndpointOrigin(endpoint: endpoint))
    }

    func load(for endpoint: URL) async throws -> SessionTokens? {
        try await load(for: EndpointOrigin(endpoint: endpoint))
    }

    func delete(for endpoint: URL) async throws {
        try await delete(for: EndpointOrigin(endpoint: endpoint))
    }
}

enum KeychainStoreError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case unexpectedStatus(OSStatus)
    case invalidTokenData

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The server address cannot be used for secure storage."
        case .unexpectedStatus:
            "Secure storage is unavailable. Make sure the device is unlocked, then try again."
        case .invalidTokenData:
            "The saved CasaOS session is damaged. Sign in again to replace it."
        }
    }
}

actor KeychainStore: SessionTokenStore {
    private let service: String

    init(service: String = "CasaNative.CasaOS.SessionTokens") {
        self.service = service
    }

    func store(_ tokens: SessionTokens, for origin: EndpointOrigin) async throws {
        let data = try JSONEncoder().encode(tokens)
        let lookup = baseQuery(for: origin)
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            update as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertion = lookup
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    func load(for origin: EndpointOrigin) async throws -> SessionTokens? {
        var query = baseQuery(for: origin)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.invalidTokenData
            }
            do {
                return try JSONDecoder().decode(SessionTokens.self, from: data)
            } catch {
                throw KeychainStoreError.invalidTokenData
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(for origin: EndpointOrigin) async throws {
        let status = SecItemDelete(baseQuery(for: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for origin: EndpointOrigin) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: origin.rawValue
        ]
    }
}

actor InMemorySessionTokenStore: SessionTokenStore {
    private var tokensByOrigin: [EndpointOrigin: SessionTokens]

    init(tokensByOrigin: [EndpointOrigin: SessionTokens] = [:]) {
        self.tokensByOrigin = tokensByOrigin
    }

    func store(_ tokens: SessionTokens, for origin: EndpointOrigin) async throws {
        tokensByOrigin[origin] = tokens
    }

    func load(for origin: EndpointOrigin) async throws -> SessionTokens? {
        tokensByOrigin[origin]
    }

    func delete(for origin: EndpointOrigin) async throws {
        tokensByOrigin[origin] = nil
    }
}
