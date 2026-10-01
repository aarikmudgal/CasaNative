import Foundation
import Security
import WebKit
import XCTest
@testable import CasaNative

@MainActor
final class ContainerBrowserStorageTests: XCTestCase {
    func testIdentityNormalizesOriginsAndIgnoresPaths() throws {
        let first = try identity(
            server: "HTTP://CasaOS.LOCAL.:80/api/v1",
            launch: "HTTPS://APP.LOCAL.:443/sign-in?next=home#form"
        )
        let second = try identity(
            server: "http://casaos.local/",
            launch: "https://app.local/dashboard"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.serverOrigin.rawValue, "http://casaos.local")
        XCTAssertEqual(first.launchOrigin.rawValue, "https://app.local")
        XCTAssertEqual(first.storageKey, second.storageKey)
        XCTAssertEqual(first.storageKey.count, 64)
        XCTAssertTrue(first.storageKey.allSatisfy { $0.isHexDigit })
    }

    func testIdentityIsolatesServerAppAndLaunchSchemeHostPort() throws {
        let original = try identity()
        let alternatives = try [
            identity(server: "https://other.local"),
            identity(server: "http://casaos.local"),
            identity(server: "https://casaos.local:8443"),
            identity(appID: "other-app"),
            identity(appID: "APP"),
            identity(launch: "http://app.local"),
            identity(launch: "https://other-app.local"),
            identity(launch: "https://app.local:8443"),
        ]

        for alternative in alternatives {
            XCTAssertNotEqual(original, alternative)
            XCTAssertNotEqual(original.storageKey, alternative.storageKey)
        }
        XCTAssertEqual(Set(alternatives.map(\.storageKey)).count, alternatives.count)
    }

    func testIdentityAppIDsAreNotDelimiterConcatenated() throws {
        let identifiers = ["app|https://other.local", "app", "app\n", "app\"", "app/../other"]
        let identities = try identifiers.map { try identity(appID: $0) }

        XCTAssertEqual(Set(identities.map(\.storageKey)).count, identifiers.count)
        XCTAssertEqual(identities.map(\.appID), identifiers)
    }

    func testIdentityNormalizesIPv6AndDefaultPort() throws {
        let first = try identity(
            server: "http://[2001:db8::42]:80/api",
            launch: "https://[2001:db8::43]:443/login"
        )
        let second = try identity(
            server: "http://[2001:db8::42]",
            launch: "https://[2001:db8::43]"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allowsCredentialFill(at: URL(string: "https://[2001:db8::43]/home")))
    }

    func testCredentialFillRequiresExactNormalizedLaunchOrigin() throws {
        let profile = try identity()
        let allowed = [
            "https://app.local/login",
            "HTTPS://APP.LOCAL.:443/dashboard?next=home#form",
        ]
        let rejected = [
            "http://app.local/login",
            "https://app.local:8443/login",
            "https://sub.app.local/login",
            "https://app.local.attacker.invalid/login",
            "https://casaos.local/login",
            "https://user:password@app.local/login",
            "https://user@app.local/login",
            "https://@app.local/login",
            "file:///app.local/login",
            "about:blank",
            "/login",
        ]

        for address in allowed {
            XCTAssertTrue(profile.allowsCredentialFill(at: URL(string: address)), address)
        }
        for address in rejected {
            XCTAssertFalse(profile.allowsCredentialFill(at: URL(string: address)), address)
        }
        XCTAssertFalse(profile.allowsCredentialFill(at: nil))
    }

    func testIdentityRejectsUnsupportedURLsEmbeddedCredentialsAndEmptyAppID() {
        XCTAssertThrowsError(try identity(server: "file:///server"))
        XCTAssertThrowsError(try identity(launch: "javascript:alert(1)"))
        XCTAssertThrowsError(try identity(server: "https://user:password@casaos.local"))
        XCTAssertThrowsError(try identity(launch: "https://user@app.local"))
        XCTAssertThrowsError(try identity(launch: "https://@app.local"))
        XCTAssertThrowsError(try identity(appID: " \n "))
    }

    func testCredentialsSupportPasswordOnlyFormsAndCodableRoundTrip() throws {
        let passwordOnly = ContainerCredentials(username: "", password: "test-password")

        XCTAssertTrue(passwordOnly.isComplete)
        XCTAssertFalse(ContainerCredentials(username: "admin", password: "").isComplete)
        let encoded = try JSONEncoder().encode(passwordOnly)
        XCTAssertEqual(
            try JSONDecoder().decode(ContainerCredentials.self, from: encoded),
            passwordOnly
        )
    }

    func testInMemoryCredentialsIsolateServerAppAndLaunchOrigin() async throws {
        let store = InMemoryContainerCredentialStore()
        let first = try identity()
        let others = try [
            identity(server: "https://other.local"),
            identity(appID: "other-app"),
            identity(launch: "https://app.local:8443"),
        ]
        let credentials = ContainerCredentials(username: "", password: "test-password")
        try await store.save(credentials, for: first)

        for other in others {
            let loaded = try await store.load(for: other)
            XCTAssertNil(loaded)
        }
        let sameOrigin = try identity(
            server: "HTTPS://CASAOS.LOCAL.:443/api",
            launch: "HTTPS://APP.LOCAL.:443/another-path"
        )
        let loaded = try await store.load(for: sameOrigin)
        XCTAssertEqual(loaded, credentials)
    }

    func testInMemoryCredentialDeletionKeepsUnrelatedProfiles() async throws {
        let store = InMemoryContainerCredentialStore()
        let first = try identity()
        let sameServer = try identity(appID: "other-app")
        let otherServer = try identity(server: "https://other.local")
        let credentials = ContainerCredentials(username: "admin", password: "test-password")
        for profile in [first, sameServer, otherServer] {
            try await store.save(credentials, for: profile)
        }

        try await store.delete(for: first)
        try await store.delete(for: first)
        let deleted = try await store.load(for: first)
        let sameServerBeforeCleanup = try await store.load(for: sameServer)
        XCTAssertNil(deleted)
        XCTAssertEqual(sameServerBeforeCleanup, credentials)

        let normalizedServer = try XCTUnwrap(URL(string: "HTTPS://CASAOS.LOCAL.:443/api"))
        try await store.deleteAll(for: normalizedServer)
        try await store.deleteAll(for: normalizedServer)
        let sameServerAfterCleanup = try await store.load(for: sameServer)
        let unrelated = try await store.load(for: otherServer)
        XCTAssertNil(sameServerAfterCleanup)
        XCTAssertEqual(unrelated, credentials)
    }

    func testBothCredentialStoresRejectEmptyPassword() async throws {
        let profile = try identity()
        let stores: [any ContainerCredentialStoring] = [
            InMemoryContainerCredentialStore(),
            ContainerCredentialStore(servicePrefix: "CasaNative.Tests.ContainerBrowser.\(UUID())"),
        ]
        for store in stores {
            do {
                try await store.save(
                    ContainerCredentials(username: "admin", password: ""),
                    for: profile
                )
                XCTFail("Expected an empty password to be rejected")
            } catch let error as ContainerBrowserStorageError {
                XCTAssertEqual(error, .incompleteCredentials)
            }
            let loaded = try await store.load(for: profile)
            XCTAssertNil(loaded)
        }
    }

    func testKeychainCredentialRoundTripUpdatesAndDeletesOnlyMatchingServer() async throws {
        let store = ContainerCredentialStore(
            servicePrefix: "CasaNative.Tests.ContainerBrowser.\(UUID())"
        )
        let first = try identity()
        let sameServer = try identity(appID: "other-app")
        let launchPort = try identity(launch: "https://app.local:8443")
        let otherServer = try identity(server: "https://other.local")
        let firstURL = try XCTUnwrap(URL(string: "https://casaos.local"))
        let otherURL = try XCTUnwrap(URL(string: "https://other.local"))
        let credentials = ContainerCredentials(username: "", password: "first-test-password")
        let replacement = ContainerCredentials(username: "admin", password: "second-test-password")
        do {
            for profile in [first, sameServer, otherServer] {
                try await store.save(credentials, for: profile)
            }
            let isolatedPort = try await store.load(for: launchPort)
            XCTAssertNil(isolatedPort)
            let initial = try await store.load(for: first)
            XCTAssertEqual(initial, credentials)

            try await store.save(replacement, for: first)
            let updated = try await store.load(for: first)
            XCTAssertEqual(updated, replacement)
            try await store.delete(for: first)
            try await store.delete(for: first)
            let removed = try await store.load(for: first)
            let otherApp = try await store.load(for: sameServer)
            XCTAssertNil(removed)
            XCTAssertEqual(otherApp, credentials)

            try await store.deleteAll(for: firstURL)
            try await store.deleteAll(for: firstURL)
            let serverRemoved = try await store.load(for: sameServer)
            let unrelated = try await store.load(for: otherServer)
            XCTAssertNil(serverRemoved)
            XCTAssertEqual(unrelated, credentials)
        } catch {
            try? await store.deleteAll(for: firstURL)
            try? await store.deleteAll(for: otherURL)
            throw error
        }
        try await store.deleteAll(for: otherURL)
    }

    func testProfileRegistryReloadReusesPersistentIdentifierAndIsolatesApps() async throws {
        let preferences = ContainerBrowserTestPreferences()
        let firstStore = ContainerBrowserProfileStore(preferences: preferences)
        let first = try identity()
        let otherApp = try identity(appID: "other-app")
        let otherPort = try identity(launch: "https://app.local:8443")
        try autoreleasepool {
            let firstDataStore = try firstStore.dataStore(for: first)
            let otherAppDataStore = try firstStore.dataStore(for: otherApp)
            let otherPortDataStore = try firstStore.dataStore(for: otherPort)
            XCTAssertTrue(firstDataStore.isPersistent)
            XCTAssertNotNil(firstDataStore.identifier)
            XCTAssertNotEqual(firstDataStore.identifier, otherAppDataStore.identifier)
            XCTAssertNotEqual(firstDataStore.identifier, otherPortDataStore.identifier)

            let reloadedStore = ContainerBrowserProfileStore(preferences: preferences)
            let normalized = try identity(
                server: "HTTPS://CASAOS.LOCAL.:443/another-path",
                launch: "https://app.local/another-path"
            )
            let reloadedDataStore = try reloadedStore.dataStore(for: normalized)
            XCTAssertEqual(firstDataStore.identifier, reloadedDataStore.identifier)
        }
        try await firstStore.removeAll(for: URL(string: "https://casaos.local")!)
        XCTAssertTrue(preferences.values.isEmpty)
    }

    func testClearSessionDeletesCookiesButReusesProfileAndPreservesOtherApp() async throws {
        let store = ContainerBrowserProfileStore(preferences: ContainerBrowserTestPreferences())
        let first = try identity()
        let otherApp = try identity(appID: "other-app")
        var firstDataStore: WKWebsiteDataStore? = try autoreleasepool { try store.dataStore(for: first) }
        var otherDataStore: WKWebsiteDataStore? = try autoreleasepool { try store.dataStore(for: otherApp) }
        let identifier = firstDataStore?.identifier
        let cookie = try testCookie()
        await firstDataStore!.httpCookieStore.setCookie(cookie)
        await otherDataStore!.httpCookieStore.setCookie(cookie)

        let before = await firstDataStore!.httpCookieStore.allCookies()
        XCTAssertTrue(before.contains { $0.name == cookie.name })
        try await store.clearSession(for: first)
        let cleared = await firstDataStore!.httpCookieStore.allCookies()
        let preserved = await otherDataStore!.httpCookieStore.allCookies()
        XCTAssertFalse(cleared.contains { $0.name == cookie.name })
        XCTAssertTrue(preserved.contains { $0.name == cookie.name })
        try autoreleasepool {
            let reloadedIdentifier = try store.dataStore(for: first).identifier
            XCTAssertEqual(identifier, reloadedIdentifier)
            firstDataStore = nil
            otherDataStore = nil
        }
        try await store.removeAll(for: URL(string: "https://casaos.local")!)
    }

    func testServerProfileCleanupPreservesUnconnectedServerCookiesAndRegistry() async throws {
        let preferences = ContainerBrowserTestPreferences()
        let store = ContainerBrowserProfileStore(preferences: preferences)
        let first = try identity()
        let sameServer = try identity(appID: "other-app")
        let otherServer = try identity(server: "https://other.local")
        var firstDataStore: WKWebsiteDataStore? = try autoreleasepool { try store.dataStore(for: first) }
        var sameServerDataStore: WKWebsiteDataStore? = try autoreleasepool { try store.dataStore(for: sameServer) }
        var otherDataStore: WKWebsiteDataStore? = try autoreleasepool { try store.dataStore(for: otherServer) }
        let firstIdentifier = firstDataStore?.identifier
        let sameServerIdentifier = sameServerDataStore?.identifier
        let otherIdentifier = otherDataStore?.identifier
        let cookie = try testCookie()
        await firstDataStore!.httpCookieStore.setCookie(cookie)
        await sameServerDataStore!.httpCookieStore.setCookie(cookie)
        await otherDataStore!.httpCookieStore.setCookie(cookie)

        let firstURL = try XCTUnwrap(URL(string: "HTTPS://CASAOS.LOCAL.:443/api"))
        autoreleasepool {
            firstDataStore = nil
            sameServerDataStore = nil
        }
        try await store.removeAll(for: firstURL)
        let reloadedStore = ContainerBrowserProfileStore(preferences: preferences)
        var newFirst: WKWebsiteDataStore? = try autoreleasepool { try reloadedStore.dataStore(for: first) }
        var newSameServer: WKWebsiteDataStore? = try autoreleasepool { try reloadedStore.dataStore(for: sameServer) }
        var preservedOther: WKWebsiteDataStore? = try autoreleasepool { try reloadedStore.dataStore(for: otherServer) }
        let firstCookies = await newFirst!.httpCookieStore.allCookies()
        let sameServerCookies = await newSameServer!.httpCookieStore.allCookies()
        let otherCookies = await preservedOther!.httpCookieStore.allCookies()
        XCTAssertNotEqual(newFirst?.identifier, firstIdentifier)
        XCTAssertNotEqual(newSameServer?.identifier, sameServerIdentifier)
        XCTAssertEqual(preservedOther?.identifier, otherIdentifier)
        XCTAssertFalse(firstCookies.contains { $0.name == cookie.name })
        XCTAssertFalse(sameServerCookies.contains { $0.name == cookie.name })
        XCTAssertTrue(otherCookies.contains { $0.name == cookie.name })

        autoreleasepool {
            newFirst = nil
            newSameServer = nil
            preservedOther = nil
            otherDataStore = nil
        }
        try await reloadedStore.removeAll(for: firstURL)
        try await reloadedStore.removeAll(for: URL(string: "https://other.local")!)
        XCTAssertTrue(preferences.values.isEmpty)
    }

    func testCorruptProfileRegistryIsNotSilentlyOverwritten() async throws {
        let preferences = ContainerBrowserTestPreferences()
        preferences.values["containerBrowserProfileRegistry.v1"] = "not-json"
        let store = ContainerBrowserProfileStore(preferences: preferences)

        XCTAssertThrowsError(try store.dataStore(for: identity())) { error in
            XCTAssertEqual(error as? ContainerBrowserStorageError, .invalidProfileRegistry)
        }
        do {
            try await store.removeAll(for: URL(string: "https://casaos.local")!)
            XCTFail("Expected corrupt registry cleanup to fail")
        } catch let error as ContainerBrowserStorageError {
            XCTAssertEqual(error, .invalidProfileRegistry)
        }
        XCTAssertEqual(preferences.string(forKey: "containerBrowserProfileRegistry.v1"), "not-json")
    }

    func testActiveBrowserRemovalFailureKeepsProfileRegisteredForRetry() async throws {
        let preferences = ContainerBrowserTestPreferences()
        let store = ContainerBrowserProfileStore(preferences: preferences)
        let profile = try identity()
        var configuration: WKWebViewConfiguration? = try autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = try store.dataStore(for: profile)
            return configuration
        }
        let identifier = configuration?.websiteDataStore.identifier
        var browser: WKWebView? = autoreleasepool { WKWebView(frame: .zero, configuration: configuration!) }
        let serverURL = try XCTUnwrap(URL(string: "https://casaos.local"))

        do {
            try await store.removeAll(for: serverURL)
            XCTFail("Expected profile removal to fail while its browser is alive")
        } catch {
            try autoreleasepool {
                let registered = try store.dataStore(for: profile)
                XCTAssertEqual(registered.identifier, identifier)
            }
        }
        XCTAssertEqual(browser?.configuration.websiteDataStore.identifier, identifier)
        autoreleasepool {
            browser = nil
            configuration = nil
        }
        try await store.removeAll(for: serverURL)
        XCTAssertTrue(preferences.values.isEmpty)
    }

    private func identity(
        server: String = "https://casaos.local",
        appID: String = "app",
        launch: String = "https://app.local/login"
    ) throws -> ContainerBrowserIdentity {
        try ContainerBrowserIdentity(
            serverURL: XCTUnwrap(URL(string: server)),
            appID: appID,
            launchURL: XCTUnwrap(URL(string: launch))
        )
    }

    private func testCookie() throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: "app.local",
            .path: "/",
            .name: "container-session-test",
            .value: "test-session-value",
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 3_600),
        ]))
    }
}

private final class ContainerBrowserTestPreferences: AppPreferenceStoring {
    var values: [String: Any] = [:]

    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
