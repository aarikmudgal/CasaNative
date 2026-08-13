#if canImport(UIKit)
import XCTest
@testable import CasaNative

@MainActor
final class SSHTerminalSessionTests: XCTestCase {
    func testCasaOSModeWithoutSharedCredentialsRequiresReauthentication() async throws {
        let store = InMemorySSHCredentialStore()
        let session = try makeSession(mode: .casaOS, credentialStore: store)

        await session.prepare()

        guard case let .credentialsUnavailable(message) = session.phase else {
            return XCTFail("CasaOS mode must not request credentials in Terminal")
        }
        XCTAssertEqual(
            message,
            SSHConnectionError.sharedCredentialsUnavailable.localizedDescription
        )

        session.requestCredentialEntry()
        guard case .credentialsUnavailable = session.phase else {
            return XCTFail("CasaOS mode must never enter credential form state")
        }
    }

    func testSeparateModeWithoutCredentialsRequestsCredentialEntry() async throws {
        let session = try makeSession(
            mode: .separate,
            credentialStore: InMemorySSHCredentialStore()
        )

        await session.prepare()

        XCTAssertEqual(session.phase, .needsCredentials)
    }

    func testCasaOSModeUsesSavedSharedCredentialsWithoutPrompting() async throws {
        let store = InMemorySSHCredentialStore()
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))
        try await store.storeCasaOS(
            SSHCredentials(username: "admin", password: "secret"),
            for: endpoint
        )
        let session = SSHTerminalSession(
            serverURL: endpoint,
            credentialMode: .casaOS,
            credentialStore: store,
            hostKeyStore: InMemorySSHPinnedHostKeyStore(),
            port: 22,
            defaultUsername: ""
        )

        await session.prepare()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.draftUsername, "admin")
        XCTAssertTrue(session.draftPassword.isEmpty)
    }

    func testCasaOSModeRefusesTerminalCredentialSave() async throws {
        let store = InMemorySSHCredentialStore()
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))
        let session = SSHTerminalSession(
            serverURL: endpoint,
            credentialMode: .casaOS,
            credentialStore: store,
            hostKeyStore: InMemorySSHPinnedHostKeyStore(),
            port: 22,
            defaultUsername: "admin"
        )
        session.draftPassword = "secret"

        await session.saveDraftCredentials()

        guard case .credentialsUnavailable = session.phase else {
            return XCTFail("CasaOS credentials must be captured outside Terminal")
        }
        XCTAssertTrue(session.draftPassword.isEmpty)
        let saved = try await store.load(mode: .casaOS, for: endpoint)
        XCTAssertNil(saved)
    }

    private func makeSession(
        mode: SSHCredentialMode,
        credentialStore: any SSHCredentialStoring
    ) throws -> SSHTerminalSession {
        let endpoint = try XCTUnwrap(URL(string: "https://casaos.local"))
        return SSHTerminalSession(
            serverURL: endpoint,
            credentialMode: mode,
            credentialStore: credentialStore,
            hostKeyStore: InMemorySSHPinnedHostKeyStore(),
            port: 22,
            defaultUsername: ""
        )
    }
}
#endif
