import XCTest
@testable import CasaNative

@MainActor
final class InMemorySessionTokenStoreTests: XCTestCase {
    func testKeychainErrorsHaveUserFacingDescriptions() {
        XCTAssertEqual(
            KeychainStoreError.invalidEndpoint.localizedDescription,
            "The server address cannot be used for secure storage."
        )
        XCTAssertEqual(
            KeychainStoreError.unexpectedStatus(-1).localizedDescription,
            "Secure storage is unavailable. Make sure the device is unlocked, then try again."
        )
        XCTAssertEqual(
            KeychainStoreError.invalidTokenData.localizedDescription,
            "The saved CasaOS session is damaged. Sign in again to replace it."
        )
    }

    func testStartsEmptyThenStoresAndLoadsTokens() async throws {
        let store = InMemorySessionTokenStore()
        let origin = try EndpointOrigin(endpoint: "http://casaos.local")
        let tokens = SessionTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let initial = try await store.load(for: origin)
        XCTAssertNil(initial)

        try await store.store(tokens, for: origin)

        let loaded = try await store.load(for: origin)
        XCTAssertEqual(loaded, tokens)
    }

    func testEquivalentURLsShareNormalizedOrigin() async throws {
        let store = InMemorySessionTokenStore()
        let writeURL = try XCTUnwrap(
            URL(string: "HTTP://CasaOS.LOCAL.:80/api/v1")
        )
        let readURL = try XCTUnwrap(URL(string: "http://casaos.local/"))
        let tokens = SessionTokens(accessToken: "access")

        try await store.store(tokens, for: writeURL)

        let loaded = try await store.load(for: readURL)
        XCTAssertEqual(loaded, tokens)
    }

    func testSchemeAndNonDefaultPortUseSeparateEntries() async throws {
        let store = InMemorySessionTokenStore()
        let http = try EndpointOrigin(endpoint: "http://casaos.local")
        let https = try EndpointOrigin(endpoint: "https://casaos.local")
        let customPort = try EndpointOrigin(
            endpoint: "http://casaos.local:8080"
        )
        let tokens = SessionTokens(accessToken: "access")

        try await store.store(tokens, for: http)

        let secureTokens = try await store.load(for: https)
        let customPortTokens = try await store.load(for: customPort)
        XCTAssertNil(secureTokens)
        XCTAssertNil(customPortTokens)
    }

    func testStoreOverwritesAndDeleteIsIdempotent() async throws {
        let store = InMemorySessionTokenStore()
        let origin = try EndpointOrigin(endpoint: "http://casaos.local")
        let first = SessionTokens(accessToken: "first")
        let replacement = SessionTokens(accessToken: "replacement")

        try await store.store(first, for: origin)
        try await store.store(replacement, for: origin)
        let overwritten = try await store.load(for: origin)
        XCTAssertEqual(overwritten, replacement)

        try await store.delete(for: origin)
        try await store.delete(for: origin)

        let loaded = try await store.load(for: origin)
        XCTAssertNil(loaded)
    }
}
