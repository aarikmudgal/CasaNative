import XCTest
@testable import CasaNative

@MainActor
final class SSHCredentialsTests: XCTestCase {
    func testCredentialCompletenessRequiresUsernameAndPassword() {
        XCTAssertTrue(
            SSHCredentials(username: " admin ", password: "secret").isComplete
        )
        XCTAssertFalse(
            SSHCredentials(username: " \n ", password: "secret").isComplete
        )
        XCTAssertFalse(
            SSHCredentials(username: "admin", password: "").isComplete
        )
    }

    func testInMemoryStoreKeepsCredentialModesSeparate() async throws {
        let store = InMemorySSHCredentialStore()
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))
        let casaOS = SSHCredentials(username: "casa", password: "casa-password")
        let separate = SSHCredentials(username: "linux", password: "ssh-password")

        try await store.storeCasaOS(casaOS, for: endpoint)
        let separateBeforeSave = try await store.load(
            mode: .separate,
            for: endpoint
        )
        XCTAssertNil(separateBeforeSave)

        try await store.storeSeparate(separate, for: endpoint)

        let loadedCasaOS = try await store.load(mode: .casaOS, for: endpoint)
        let loadedSeparate = try await store.load(mode: .separate, for: endpoint)
        XCTAssertEqual(loadedCasaOS, casaOS)
        XCTAssertEqual(loadedSeparate, separate)
    }

    func testInMemoryStoreUsesNormalizedEndpointOrigin() async throws {
        let store = InMemorySSHCredentialStore()
        let writeURL = try XCTUnwrap(
            URL(string: "HTTP://CasaOS.LOCAL.:80/api/v1")
        )
        let readURL = try XCTUnwrap(URL(string: "http://casaos.local/"))
        let credentials = SSHCredentials(username: "admin", password: "secret")

        try await store.storeCasaOS(credentials, for: writeURL)

        let loaded = try await store.load(mode: .casaOS, for: readURL)
        XCTAssertEqual(loaded, credentials)
    }

    func testInMemoryStoreRejectsIncompleteCredentials() async throws {
        let store = InMemorySSHCredentialStore()
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))

        do {
            try await store.storeSeparate(
                SSHCredentials(username: "admin", password: ""),
                for: endpoint
            )
            XCTFail("Expected incomplete credentials to be rejected")
        } catch let error as SSHCredentialStoreError {
            XCTAssertEqual(error, .incompleteCredentials)
        }

        let loaded = try await store.load(mode: .separate, for: endpoint)
        XCTAssertNil(loaded)
    }

    func testDeleteAllOnlyDeletesMatchingOriginAndIsIdempotent() async throws {
        let store = InMemorySSHCredentialStore()
        let first = try XCTUnwrap(URL(string: "https://first.local"))
        let second = try XCTUnwrap(URL(string: "https://second.local"))
        let credentials = SSHCredentials(username: "admin", password: "secret")

        try await store.storeCasaOS(credentials, for: first)
        try await store.storeSeparate(credentials, for: first)
        try await store.storeCasaOS(credentials, for: second)

        try await store.deleteAll(for: first)
        try await store.deleteAll(for: first)

        let firstCasaOS = try await store.load(mode: .casaOS, for: first)
        let firstSeparate = try await store.load(mode: .separate, for: first)
        let secondCasaOS = try await store.load(mode: .casaOS, for: second)
        XCTAssertNil(firstCasaOS)
        XCTAssertNil(firstSeparate)
        XCTAssertEqual(secondCasaOS, credentials)
    }
}
