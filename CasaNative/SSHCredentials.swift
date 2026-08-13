import Foundation
import Security

enum SSHCredentialMode: String, CaseIterable, Identifiable, Sendable {
    case casaOS
    case separate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casaOS:
            "Use CasaOS sign-in"
        case .separate:
            "Use separate SSH sign-in"
        }
    }
}

struct SSHCredentials: Codable, Equatable, Sendable {
    let username: String
    let password: String

    var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}

protocol SSHCredentialStoring: Sendable {
    func storeCasaOS(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws

    func storeSeparate(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws

    func load(
        mode: SSHCredentialMode,
        for endpoint: URL
    ) async throws -> SSHCredentials?

    func deleteAll(for endpoint: URL) async throws
}

enum SSHCredentialStoreError: LocalizedError, Equatable, Sendable {
    case incompleteCredentials
    case invalidCredentialData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .incompleteCredentials:
            "Enter both an SSH username and password."
        case .invalidCredentialData:
            "The saved SSH credentials could not be read."
        case let .unexpectedStatus(status):
            "The SSH credentials could not be saved (Keychain status \(status))."
        }
    }
}

actor SSHCredentialStore: SSHCredentialStoring {
    private enum Service {
        static let casaOS = "CasaNative.SSH.CasaOSCredentials"
        static let separate = "CasaNative.SSH.SeparateCredentials"
    }

    func storeCasaOS(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws {
        try store(credentials, service: Service.casaOS, endpoint: endpoint)
    }

    func storeSeparate(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws {
        try store(credentials, service: Service.separate, endpoint: endpoint)
    }

    func load(
        mode: SSHCredentialMode,
        for endpoint: URL
    ) async throws -> SSHCredentials? {
        let service = switch mode {
        case .casaOS: Service.casaOS
        case .separate: Service.separate
        }
        return try load(service: service, endpoint: endpoint)
    }

    func deleteAll(for endpoint: URL) async throws {
        let account = try EndpointOrigin(endpoint: endpoint).rawValue
        try delete(service: Service.casaOS, account: account)
        try delete(service: Service.separate, account: account)
    }

    private func store(
        _ credentials: SSHCredentials,
        service: String,
        endpoint: URL
    ) throws {
        guard credentials.isComplete else {
            throw SSHCredentialStoreError.incompleteCredentials
        }

        let account = try EndpointOrigin(endpoint: endpoint).rawValue
        let data = try JSONEncoder().encode(credentials)
        let lookup = baseQuery(service: service, account: account)
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(
            lookup as CFDictionary,
            update as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertion = lookup
            insertion[kSecValueData] = data
            insertion[kSecAttrAccessible] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SSHCredentialStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func load(
        service: String,
        endpoint: URL
    ) throws -> SSHCredentials? {
        let account = try EndpointOrigin(endpoint: endpoint).rawValue
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SSHCredentialStoreError.invalidCredentialData
            }
            do {
                let credentials = try JSONDecoder().decode(
                    SSHCredentials.self,
                    from: data
                )
                guard credentials.isComplete else {
                    throw SSHCredentialStoreError.invalidCredentialData
                }
                return credentials
            } catch let error as SSHCredentialStoreError {
                throw error
            } catch {
                throw SSHCredentialStoreError.invalidCredentialData
            }
        case errSecItemNotFound:
            return nil
        default:
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func delete(service: String, account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

actor InMemorySSHCredentialStore: SSHCredentialStoring {
    private struct Key: Hashable {
        let mode: SSHCredentialMode
        let origin: EndpointOrigin
    }

    private var credentialsByKey: [Key: SSHCredentials] = [:]

    func storeCasaOS(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws {
        try store(credentials, mode: .casaOS, endpoint: endpoint)
    }

    func storeSeparate(
        _ credentials: SSHCredentials,
        for endpoint: URL
    ) async throws {
        try store(credentials, mode: .separate, endpoint: endpoint)
    }

    func load(
        mode: SSHCredentialMode,
        for endpoint: URL
    ) async throws -> SSHCredentials? {
        credentialsByKey[
            Key(mode: mode, origin: try EndpointOrigin(endpoint: endpoint))
        ]
    }

    func deleteAll(for endpoint: URL) async throws {
        let origin = try EndpointOrigin(endpoint: endpoint)
        credentialsByKey = credentialsByKey.filter { $0.key.origin != origin }
    }

    private func store(
        _ credentials: SSHCredentials,
        mode: SSHCredentialMode,
        endpoint: URL
    ) throws {
        guard credentials.isComplete else {
            throw SSHCredentialStoreError.incompleteCredentials
        }
        credentialsByKey[
            Key(mode: mode, origin: try EndpointOrigin(endpoint: endpoint))
        ] = credentials
    }
}
