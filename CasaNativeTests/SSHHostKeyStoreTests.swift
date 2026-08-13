#if canImport(UIKit)
import Foundation
import XCTest
@testable import CasaNative

@MainActor
final class SSHHostKeyStoreTests: XCTestCase {
    func testHostIdentityNormalizesDNSAndIPv6Hosts() throws {
        let dns = try SSHHostIdentity(hostname: " CasaOS.LOCAL... ", port: 22)
        let ipv6 = try SSHHostIdentity(hostname: "[2001:DB8::1]", port: 2222)

        XCTAssertEqual(dns.hostname, "casaos.local")
        XCTAssertEqual(dns.description, "casaos.local:22")
        XCTAssertEqual(ipv6.hostname, "2001:db8::1")
        XCTAssertEqual(ipv6.description, "[2001:db8::1]:2222")
    }

    func testHostIdentityRejectsEmptyHostsAndInvalidPorts() {
        XCTAssertThrowsError(try SSHHostIdentity(hostname: " ", port: 22))
        XCTAssertThrowsError(try SSHHostIdentity(hostname: "host", port: 0))
        XCTAssertThrowsError(try SSHHostIdentity(hostname: "host", port: 65_536))
    }

    func testFingerprintUsesOpenSSHStyleSHA256Format() {
        XCTAssertEqual(
            SSHHostKeyPinningDelegate.fingerprint(for: Data()),
            "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"
        )
    }

    func testInMemoryPinIsScopedByHostAndPortAndNeverOverwrites() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let standardPort = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let alternatePort = try SSHHostIdentity(hostname: "casaos.local", port: 2222)
        let firstKey = Data([1, 2, 3])
        let replacement = Data([4, 5, 6])

        let initialPin = try await store.pin(firstKey, for: standardPort)
        let authoritativePin = try await store.pin(replacement, for: standardPort)

        XCTAssertEqual(initialPin, firstKey)
        XCTAssertEqual(authoritativePin, firstKey)
        let savedStandard = try await store.load(for: standardPort)
        let savedAlternate = try await store.load(for: alternatePort)
        XCTAssertEqual(savedStandard, firstKey)
        XCTAssertNil(savedAlternate)
    }

    func testVerifierPromptsOnceThenAcceptsMatchingPinnedKeySilently() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let key = Data([1, 2, 3])
        let recorder = HostKeyPromptRecorder(accepted: true)
        let verifier = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: { prompt in await recorder.confirm(prompt) }
        )

        try await verifier.validate(key)
        try await verifier.validate(key)

        let prompts = await recorder.recordedPrompts()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.host, host)
        XCTAssertEqual(
            prompts.first?.fingerprint,
            SSHHostKeyPinningDelegate.fingerprint(for: key)
        )
    }

    func testVerifierBlocksChangedPinnedKeyWithoutPrompting() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let savedKey = Data([1, 2, 3])
        let changedKey = Data([3, 2, 1])
        _ = try await store.pin(savedKey, for: host)
        let recorder = HostKeyPromptRecorder(accepted: true)
        let verifier = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: { prompt in await recorder.confirm(prompt) }
        )

        do {
            try await verifier.validate(changedKey)
            XCTFail("Expected changed host key to be blocked")
        } catch let error as SSHHostKeyChangedError {
            XCTAssertEqual(error.host, host)
            XCTAssertEqual(
                error.savedFingerprint,
                SSHHostKeyPinningDelegate.fingerprint(for: savedKey)
            )
            XCTAssertEqual(
                error.presentedFingerprint,
                SSHHostKeyPinningDelegate.fingerprint(for: changedKey)
            )
        }

        let prompts = await recorder.recordedPrompts()
        XCTAssertTrue(prompts.isEmpty)
        let stillPinned = try await store.load(for: host)
        XCTAssertEqual(stillPinned, savedKey)
    }

    func testVerifierDoesNotPinRejectedKey() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let verifier = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: { _ in false }
        )

        do {
            try await verifier.validate(Data([1, 2, 3]))
            XCTFail("Expected rejected host key to fail")
        } catch is SSHHostKeyRejectedError {
            // Expected.
        }

        let saved = try await store.load(for: host)
        XCTAssertNil(saved)
    }

    func testConcurrentFirstUseCannotReplaceWinningPin() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let firstKey = Data([1, 1, 1])
        let secondKey = Data([2, 2, 2])
        let first = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: { _ in true }
        )
        let second = SSHHostKeyVerifier(
            host: host,
            store: store,
            confirmation: { _ in true }
        )

        async let firstResult = Self.verificationResult(first, key: firstKey)
        async let secondResult = Self.verificationResult(second, key: secondKey)
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter(\.isSuccess).count, 1)
        XCTAssertEqual(results.filter(\.isChangedKey).count, 1)
        let saved = try await store.load(for: host)
        XCTAssertTrue(saved == firstKey || saved == secondKey)
    }

    func testCoordinatorSharesOnePromptAcrossMatchingConnectionCandidates() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let key = Data([1, 2, 3])
        let recorder = HostKeyPromptRecorder(accepted: true)
        let coordinator = SSHHostKeyValidationCoordinator(
            host: host,
            store: store,
            confirmation: { prompt in await recorder.confirm(prompt) }
        )

        async let firstResult = Self.coordinatedVerificationResult(
            coordinator,
            key: key
        )
        async let secondResult = Self.coordinatedVerificationResult(
            coordinator,
            key: key
        )
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter(\.isSuccess).count, 2)
        let prompts = await recorder.recordedPrompts()
        XCTAssertEqual(prompts.count, 1)
    }

    func testCoordinatorPinsOneParallelCandidateAndBlocksDifferentKey() async throws {
        let store = InMemorySSHPinnedHostKeyStore()
        let host = try SSHHostIdentity(hostname: "casaos.local", port: 22)
        let firstKey = Data([1, 1, 1])
        let secondKey = Data([2, 2, 2])
        let recorder = HostKeyPromptRecorder(accepted: true)
        let coordinator = SSHHostKeyValidationCoordinator(
            host: host,
            store: store,
            confirmation: { prompt in await recorder.confirm(prompt) }
        )

        async let firstResult = Self.coordinatedVerificationResult(
            coordinator,
            key: firstKey
        )
        async let secondResult = Self.coordinatedVerificationResult(
            coordinator,
            key: secondKey
        )
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter(\.isSuccess).count, 1)
        XCTAssertEqual(results.filter(\.isChangedKey).count, 1)
        let prompts = await recorder.recordedPrompts()
        XCTAssertEqual(prompts.count, 1)
    }

    nonisolated private static func verificationResult(
        _ verifier: SSHHostKeyVerifier,
        key: Data
    ) async -> HostKeyVerificationResult {
        do {
            try await verifier.validate(key)
            return .success
        } catch is SSHHostKeyChangedError {
            return .changedKey
        } catch {
            return .unexpectedFailure
        }
    }

    nonisolated private static func coordinatedVerificationResult(
        _ coordinator: SSHHostKeyValidationCoordinator,
        key: Data
    ) async -> HostKeyVerificationResult {
        do {
            try await coordinator.validate(key)
            return .success
        } catch is SSHHostKeyChangedError {
            return .changedKey
        } catch {
            return .unexpectedFailure
        }
    }
}

private enum HostKeyVerificationResult {
    case success
    case changedKey
    case unexpectedFailure

    var isSuccess: Bool { self == .success }
    var isChangedKey: Bool { self == .changedKey }
}

private actor HostKeyPromptRecorder {
    private let accepted: Bool
    private var prompts: [SSHHostKeyPrompt] = []

    init(accepted: Bool) {
        self.accepted = accepted
    }

    func confirm(_ prompt: SSHHostKeyPrompt) -> Bool {
        prompts.append(prompt)
        return accepted
    }

    func recordedPrompts() -> [SSHHostKeyPrompt] {
        prompts
    }
}
#endif
