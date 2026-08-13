import CryptoKit
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
import Security

struct SSHHostIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    let hostname: String
    let port: Int

    init(hostname: String, port: Int) throws {
        var normalizedHost = hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedHost.hasPrefix("[") && normalizedHost.hasSuffix("]") {
            normalizedHost.removeFirst()
            normalizedHost.removeLast()
        }
        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }

        guard !normalizedHost.isEmpty, (1...65_535).contains(port) else {
            throw SSHConnectionError.invalidTarget
        }
        self.hostname = normalizedHost
        self.port = port
    }

    init(serverURL: URL, port: Int) throws {
        guard let host = serverURL.host else {
            throw SSHConnectionError.invalidTarget
        }
        try self.init(hostname: host, port: port)
    }

    var description: String {
        let renderedHost = hostname.contains(":") ? "[\(hostname)]" : hostname
        return "\(renderedHost):\(port)"
    }
}

protocol SSHPinnedHostKeyStoring: Sendable {
    func load(for host: SSHHostIdentity) async throws -> Data?
    /// Pins `key` only when no key exists and returns the authoritative pin.
    /// Existing pins are never replaced without an explicit `delete`.
    func pin(_ key: Data, for host: SSHHostIdentity) async throws -> Data
    func delete(for host: SSHHostIdentity) async throws
}

enum SSHHostKeyStoreError: LocalizedError, Equatable, Sendable {
    case invalidKeyData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKeyData:
            "The saved SSH server identity could not be read."
        case let .unexpectedStatus(status):
            "The SSH server identity could not be saved (Keychain status \(status))."
        }
    }
}

actor SSHHostKeyStore: SSHPinnedHostKeyStoring {
    private let service: String

    init(service: String = "CasaNative.SSH.HostKeys") {
        self.service = service
    }

    func load(for host: SSHHostIdentity) async throws -> Data? {
        try loadStoredKey(for: host)
    }

    func pin(_ key: Data, for host: SSHHostIdentity) async throws -> Data {
        guard !key.isEmpty else { throw SSHHostKeyStoreError.invalidKeyData }

        if let savedKey = try loadStoredKey(for: host) {
            return savedKey
        }

        var insertion = baseQuery(for: host)
        insertion[kSecValueData] = key
        insertion[kSecAttrAccessible] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another connection or store instance pinned this host first.
            guard let savedKey = try loadStoredKey(for: host) else {
                throw SSHHostKeyStoreError.unexpectedStatus(status)
            }
            return savedKey
        default:
            throw SSHHostKeyStoreError.unexpectedStatus(status)
        }
    }

    func delete(for host: SSHHostIdentity) async throws {
        let status = SecItemDelete(baseQuery(for: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHHostKeyStoreError.unexpectedStatus(status)
        }
    }

    private func loadStoredKey(for host: SSHHostIdentity) throws -> Data? {
        var query = baseQuery(for: host)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw SSHHostKeyStoreError.invalidKeyData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SSHHostKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for host: SSHHostIdentity) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: host.description,
        ]
    }
}

actor InMemorySSHPinnedHostKeyStore: SSHPinnedHostKeyStoring {
    private var keys: [SSHHostIdentity: Data] = [:]

    func load(for host: SSHHostIdentity) async throws -> Data? {
        keys[host]
    }

    func pin(_ key: Data, for host: SSHHostIdentity) async throws -> Data {
        guard !key.isEmpty else { throw SSHHostKeyStoreError.invalidKeyData }
        if let savedKey = keys[host] {
            return savedKey
        }
        keys[host] = key
        return key
    }

    func delete(for host: SSHHostIdentity) async throws {
        keys[host] = nil
    }
}

struct SSHHostKeyPrompt: Identifiable, Equatable, Sendable {
    let host: SSHHostIdentity
    let fingerprint: String

    var id: String { "\(host.description)|\(fingerprint)" }
}

struct SSHHostKeyChangedError: LocalizedError, Equatable, Sendable {
    let host: SSHHostIdentity
    let savedFingerprint: String
    let presentedFingerprint: String

    var errorDescription: String? {
        "SSH server identity changed for \(host.description). Connection was blocked."
    }
}

struct SSHHostKeyRejectedError: LocalizedError, Sendable {
    var errorDescription: String? {
        "SSH server identity was not trusted."
    }
}

struct SSHHostKeyVerifier: Sendable {
    typealias Confirmation = @Sendable (SSHHostKeyPrompt) async -> Bool

    let host: SSHHostIdentity
    let store: any SSHPinnedHostKeyStoring
    let confirmation: Confirmation

    func validate(_ presentedKey: Data) async throws {
        guard !presentedKey.isEmpty else {
            throw SSHHostKeyStoreError.invalidKeyData
        }

        if let savedKey = try await store.load(for: host) {
            try Self.requireMatch(
                savedKey: savedKey,
                presentedKey: presentedKey,
                host: host
            )
            return
        }

        let prompt = SSHHostKeyPrompt(
            host: host,
            fingerprint: SSHHostKeyPinningDelegate.fingerprint(
                for: presentedKey
            )
        )
        guard await confirmation(prompt) else {
            throw SSHHostKeyRejectedError()
        }

        let authoritativeKey = try await store.pin(presentedKey, for: host)
        try Self.requireMatch(
            savedKey: authoritativeKey,
            presentedKey: presentedKey,
            host: host
        )
    }

    private static func requireMatch(
        savedKey: Data,
        presentedKey: Data,
        host: SSHHostIdentity
    ) throws {
        guard savedKey == presentedKey else {
            throw SSHHostKeyChangedError(
                host: host,
                savedFingerprint: SSHHostKeyPinningDelegate.fingerprint(
                    for: savedKey
                ),
                presentedFingerprint: SSHHostKeyPinningDelegate.fingerprint(
                    for: presentedKey
                )
            )
        }
    }
}

/// Shares one first-use decision across parallel connection candidates.
/// `ClientBootstrap` may race IPv4 and IPv6 channels for the same host.
actor SSHHostKeyValidationCoordinator {
    private struct InFlight {
        let id: UUID
        let presentedKey: Data
        let task: Task<Void, any Error>
    }

    private let verifier: SSHHostKeyVerifier
    private var inFlight: InFlight?

    init(
        host: SSHHostIdentity,
        store: any SSHPinnedHostKeyStoring,
        confirmation: @escaping SSHHostKeyVerifier.Confirmation
    ) {
        verifier = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: confirmation
        )
    }

    func validate(_ presentedKey: Data) async throws {
        if let existing = inFlight {
            try await existing.task.value
            guard existing.presentedKey != presentedKey else { return }

            // The first key is now authoritative, so a different key is
            // evaluated as a mismatch without another trust prompt.
            try await verifier.validate(presentedKey)
            return
        }

        let id = UUID()
        let verifier = self.verifier
        let task = Task {
            try await verifier.validate(presentedKey)
        }
        inFlight = InFlight(
            id: id,
            presentedKey: presentedKey,
            task: task
        )

        do {
            try await task.value
            clearInFlight(id: id)
        } catch {
            clearInFlight(id: id)
            throw error
        }
    }

    private func clearInFlight(id: UUID) {
        guard inFlight?.id == id else { return }
        inFlight = nil
    }
}

final class SSHHostKeyPinningDelegate:
    NIOSSHClientServerAuthenticationDelegate,
    @unchecked Sendable
{
    typealias Confirmation = @Sendable (SSHHostKeyPrompt) async -> Bool

    private let coordinator: SSHHostKeyValidationCoordinator

    init(
        host: SSHHostIdentity,
        store: any SSHPinnedHostKeyStoring,
        confirmation: @escaping Confirmation
    ) {
        coordinator = SSHHostKeyValidationCoordinator(
            host: host,
            store: store,
            confirmation: confirmation
        )
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        guard let presentedKey = Self.serialized(hostKey) else {
            validationCompletePromise.fail(
                SSHHostKeyStoreError.invalidKeyData
            )
            return
        }
        Task {
            do {
                try await coordinator.validate(presentedKey)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    private static func serialized(_ key: NIOSSHPublicKey) -> Data? {
        let openSSH = String(openSSHPublicKey: key)
        let components = openSSH.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard
            components.count == 2,
            let serialized = Data(base64Encoded: String(components[1]))
        else {
            return nil
        }
        return serialized
    }

    static func fingerprint(for key: Data) -> String {
        let digest = SHA256.hash(data: key)
        let base64 = Data(digest)
            .base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }
}
