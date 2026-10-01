import Foundation
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import CasaNative

@MainActor
final class ContainerBrowserModelTests: XCTestCase {
    private let serverURL = URL(string: "https://demo.casanative.invalid")!
    private let launchURL = URL(string: "https://demo.casanative.invalid/session-demo")!
    private let credentials = ContainerCredentials(username: "demo-user", password: "test-password")

    func testHTTPChallengePresentsNativePasswordAutoFillSheet() async throws {
        let fixture = try makeFixture()
        let model = try fixture.requireModel()
        let host = fixture.showBrowserChrome()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.webView.isDescendant(of: host.view), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let replies = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            replies.append(disposition, credential)
        }
        while host.presentedViewController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try XCTUnwrap(host.presentedViewController, "HTTP sign-in must present an explicit native sheet")
        sheet.view.layoutIfNeeded()
        func textFields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        var fields = textFields(in: sheet.view)
        while fields.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fields = textFields(in: sheet.view)
        }
        XCTAssertTrue(fields.contains { $0.textContentType == .username })
        XCTAssertTrue(fields.contains { $0.textContentType == .password && $0.isSecureTextEntry })
        // Allow the native presentation and local Keychain-loading task to settle before visual proof.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.needsHTTPLogin)
        XCTAssertTrue(replies.values.isEmpty)
        let renderer = UIGraphicsImageRenderer(bounds: sheet.view.bounds)
        let screenshot = renderer.image { _ in sheet.view.drawHierarchy(in: sheet.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Native container Keychain sign-in"
        attachment.lifetime = .keepAlways
        add(attachment)
        model.cancelHTTPLogin()
        XCTAssertEqual(replies.values.first?.disposition, .cancelAuthenticationChallenge)
        host.dismiss(animated: false)
    }

    func testDemoSessionPersistsAcrossModelAndProfileRegistryRecreation() async throws {
        let preferences = BrowserModelTestPreferences()
        let identity = try makeIdentity()
        let credentialsStore = InMemoryContainerCredentialStore()
        let firstProfiles = ContainerBrowserProfileStore(preferences: preferences)
        let firstFixture = try makeFixture(
            identity: identity,
            profiles: firstProfiles,
            credentialsStore: credentialsStore
        )
        var firstIdentifier: UUID?
        do {
            let model = try firstFixture.requireModel()
            firstIdentifier = model.webView.configuration.websiteDataStore.identifier
            try await start(model)
            let initial = try await state(in: model)
            XCTAssertFalse(initial["hidden"] as? Bool ?? true)
            try await model.fill(credentials, remember: false)
            _ = try await model.webView.evaluateJavaScript("document.querySelector('form').requestSubmit()")
            let signedIn = try await state(in: model)
            XCTAssertEqual(signedIn["session"] as? String, "yes")
            XCTAssertEqual(signedIn["hidden"] as? Bool, true)
        }
        autoreleasepool { firstFixture.dispose() }

        let reloadedProfiles = ContainerBrowserProfileStore(preferences: preferences)
        let secondFixture = try makeFixture(
            identity: identity,
            profiles: reloadedProfiles,
            credentialsStore: credentialsStore
        )
        let secondModel = try secondFixture.requireModel()
        try await start(secondModel)

        XCTAssertEqual(secondModel.webView.configuration.websiteDataStore.identifier, firstIdentifier)
        let restored = try await state(in: secondModel)
        XCTAssertEqual(restored["session"] as? String, "yes")
        XCTAssertEqual(restored["hidden"] as? Bool, true)
        XCTAssertTrue((restored["status"] as? String ?? "").contains("session restored"))
        let savedLogin = try await credentialsStore.load(for: identity)
        XCTAssertNil(savedLogin)
    }

    func testRememberConsentStoresOnlyAfterSuccessfulExplicitFillWithoutSubmitting() async throws {
        let store = InMemoryContainerCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        try await start(model)

        let before = try await inputs(in: model)
        let savedBeforeFill = try await store.load(for: model.identity)
        XCTAssertEqual(before, ["", ""])
        XCTAssertNil(savedBeforeFill)

        try await model.fill(credentials, remember: false)

        let notRemembered = try await store.load(for: model.identity)
        let valuesWithoutRemembering = try await inputs(in: model)
        let unsubmitted = try await state(in: model)
        XCTAssertNil(notRemembered)
        XCTAssertEqual(valuesWithoutRemembering, [credentials.username, credentials.password])
        XCTAssertTrue(unsubmitted["session"] is NSNull)
        XCTAssertEqual(unsubmitted["hidden"] as? Bool, false)

        try await model.fill(credentials, remember: true)

        let remembered = try await store.load(for: model.identity)
        XCTAssertEqual(remembered, credentials)
        XCTAssertTrue(model.message?.contains("saved in Keychain") == true)
        let stillUnsubmitted = try await state(in: model)
        XCTAssertTrue(stillUnsubmitted["session"] is NSNull)
        XCTAssertEqual(stillUnsubmitted["hidden"] as? Bool, false)
    }

    func testSavedCredentialsDoNotAutomaticallyFillOnStart() async throws {
        let store = InMemoryContainerCredentialStore()
        let identity = try makeIdentity()
        try await store.save(credentials, for: identity)
        let fixture = try makeFixture(identity: identity, credentialsStore: store)
        let model = try fixture.requireModel()

        try await start(model)

        let values = try await inputs(in: model)
        XCTAssertEqual(values, ["", ""])
        let saved = try await store.load(for: identity)
        XCTAssertEqual(saved, credentials)
    }

    func testUnsupportedFillDoesNotSaveLogin() async throws {
        let store = InMemoryContainerCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        _ = try await load("<html><body><p>Manual sign-in required</p></body></html>", in: model)

        do {
            try await model.fill(credentials, remember: true)
            XCTFail("Expected the unsupported form to reject credential fill")
        } catch {
            XCTAssertEqual(error as? ContainerLoginForm.FillError, .unsupportedForm)
        }

        let saved = try await store.load(for: model.identity)
        XCTAssertNil(saved)
        XCTAssertNil(model.message)
    }

    func testOffOriginFillDoesNotSaveOrWriteCredentials() async throws {
        let store = InMemoryContainerCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        let redirectedURL = try XCTUnwrap(URL(string: "https://other.casanative.invalid/signin"))
        _ = try await load(
            "<html><body><form method='post'><input name='username'><input type='password'></form></body></html>",
            in: model,
            baseURL: redirectedURL
        )

        do {
            try await model.fill(credentials, remember: true)
            XCTFail("Expected off-origin credential fill to fail")
        } catch ContainerBrowserError.untrustedPage {
            // The browser model rejects the page before either form filling or saving.
        }

        let saved = try await store.load(for: model.identity)
        let values = try await inputs(in: model)
        XCTAssertNil(saved)
        XCTAssertEqual(values, ["", ""])
    }

    func testClearSessionReplacesOldDocumentBeforeErasingThenReloadsSignIn() async throws {
        let store = InMemoryContainerCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        try await start(model)
        try await store.save(credentials, for: model.identity)
        let identifier = model.webView.configuration.websiteDataStore.identifier
        _ = try await model.webView.evaluateJavaScript("""
            localStorage.setItem('signedIn', 'yes');
            window.oldDocumentMarker = 'old';
            window.sessionWriter = setInterval(() => localStorage.setItem('signedIn', 'yes'), 1);
            document.querySelector('form').requestSubmit();
            """)
        let before = try await state(in: model)
        XCTAssertEqual(before["session"] as? String, "yes")
        XCTAssertEqual(before["hidden"] as? Bool, true)

        var clearing: Task<Void, any Error>?
        var observedCleanupLock = false
        let finishedPages = try await awaitNavigation(in: model, expectedURL: model.launchURL, onNavigationFinished: { url in
            guard url == "about:blank" else { return }
            observedCleanupLock = true
            XCTAssertTrue(model.isClearingSession)
            XCTAssertFalse(model.webView.allowsBackForwardNavigationGestures)
            XCTAssertFalse(model.webView.isUserInteractionEnabled)
            model.reload()
            XCTAssertEqual(model.webView.url?.absoluteString, "about:blank")
        }) {
            clearing = Task { try await model.clearSession() }
        }
        try await XCTUnwrap(clearing).value
        XCTAssertTrue(observedCleanupLock)
        XCTAssertFalse(model.isClearingSession)
        XCTAssertTrue(model.webView.allowsBackForwardNavigationGestures)
        XCTAssertTrue(model.webView.isUserInteractionEnabled)
        XCTAssertEqual(finishedPages.first, "about:blank")
        XCTAssertEqual(finishedPages.last, model.launchURL.absoluteString)
        XCTAssertEqual(model.webView.configuration.websiteDataStore.identifier, identifier)

        // The previous document's timer must not repopulate storage after the clear.
        try await Task.sleep(for: .milliseconds(100))
        let after = try await state(in: model)
        let oldMarker = try await model.webView.evaluateJavaScript("typeof window.oldDocumentMarker")
        XCTAssertTrue(after["session"] is NSNull)
        XCTAssertEqual(after["hidden"] as? Bool, false)
        XCTAssertEqual(oldMarker as? String, "undefined")
        let savedLogin = try await store.load(for: model.identity)
        XCTAssertEqual(savedLogin, credentials)
    }

    func testHTTPBasicChallengeWaitsForExplicitUserResponseWithoutPersistingInWebKit() async throws {
        let store = InMemoryContainerCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        let existing = ContainerCredentials(username: "saved-user", password: "saved-test-password")
        try await store.save(existing, for: model.identity)
        let replies = AuthenticationReplies()

        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            replies.append(disposition, credential)
        }

        XCTAssertTrue(model.needsHTTPLogin)
        XCTAssertTrue(replies.values.isEmpty)
        try await model.signInToHTTP(credentials, remember: false)
        XCTAssertFalse(model.needsHTTPLogin)
        XCTAssertEqual(replies.values.count, 1)
        let response = try XCTUnwrap(replies.values.first)
        XCTAssertEqual(response.disposition, .useCredential)
        XCTAssertEqual(response.credential?.user, credentials.username)
        XCTAssertEqual(response.credential?.password, credentials.password)
        XCTAssertEqual(response.credential?.persistence, URLCredential.Persistence.none)
        let unchanged = try await store.load(for: model.identity)
        XCTAssertEqual(unchanged, existing)
    }

    func testAuthorizedHTTPResponseReusesOnlySameRealmAndRequestsOtherRealmExplicitly() async throws {
        let fixture = try makeFixture()
        let model = try fixture.requireModel()
        let initial = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            initial.append(disposition, credential)
        }
        try await model.signInToHTTP(credentials, remember: false)

        let repeated = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            repeated.append(disposition, credential)
        }
        XCTAssertFalse(model.needsHTTPLogin)
        XCTAssertEqual(repeated.values.count, 1)
        XCTAssertEqual(repeated.values.first?.disposition, .useCredential)
        XCTAssertEqual(repeated.values.first?.credential?.password, credentials.password)
        XCTAssertEqual(repeated.values.first?.credential?.persistence, URLCredential.Persistence.none)

        let otherRealm = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge(realm: "Another container realm")) { disposition, credential in
            otherRealm.append(disposition, credential)
        }
        XCTAssertTrue(model.needsHTTPLogin)
        XCTAssertTrue(otherRealm.values.isEmpty)
        model.cancelHTTPLogin()
        XCTAssertEqual(otherRealm.values.first?.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(otherRealm.values.first?.credential)
    }

    func testFailedHTTPCredentialAndClosedModelRequireNewExplicitResponse() async throws {
        let fixture = try makeFixture()
        let model = try fixture.requireModel()
        model.webView(model.webView, didReceive: challenge()) { _, _ in }
        try await model.signInToHTTP(credentials, remember: false)
        let retry = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge(previousFailureCount: 1)) { disposition, credential in
            retry.append(disposition, credential)
        }
        XCTAssertTrue(model.needsHTTPLogin)
        XCTAssertTrue(retry.values.isEmpty)
        model.close()
        XCTAssertEqual(retry.values.first?.disposition, .cancelAuthenticationChallenge)

        let afterClose = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            afterClose.append(disposition, credential)
        }
        XCTAssertTrue(model.needsHTTPLogin)
        XCTAssertTrue(afterClose.values.isEmpty)
        model.cancelHTTPLogin()
    }

    func testHTTPChallengeRejectsOtherOriginAndKeepsSystemTLSTrustHandling() throws {
        let fixture = try makeFixture()
        let model = try fixture.requireModel()
        let redirectedReplies = AuthenticationReplies()
        model.webView(
            model.webView,
            didReceive: challenge(host: "other.casanative.invalid")
        ) { disposition, credential in
            redirectedReplies.append(disposition, credential)
        }

        XCTAssertFalse(model.needsHTTPLogin)
        XCTAssertEqual(redirectedReplies.values.first?.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(redirectedReplies.values.first?.credential)
        let trustReplies = AuthenticationReplies()
        model.webView(
            model.webView,
            didReceive: challenge(authenticationMethod: NSURLAuthenticationMethodServerTrust)
        ) { disposition, credential in
            trustReplies.append(disposition, credential)
        }
        XCTAssertEqual(trustReplies.values.first?.disposition, .performDefaultHandling)
        XCTAssertNil(trustReplies.values.first?.credential)
    }

    func testCancelledHTTPChallengeCannotBeAnsweredAfterSuspendedCredentialSave() async throws {
        let store = SuspendedBrowserCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        let replies = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            replies.append(disposition, credential)
        }
        let signingIn = Task { try await model.signInToHTTP(credentials, remember: true) }
        try await waitForSave(in: store)

        model.cancelHTTPLogin()
        await store.resumeSave()
        await assertExpiredChallenge(signingIn)

        XCTAssertFalse(model.needsHTTPLogin)
        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(replies.values.first?.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(replies.values.first?.credential)
    }

    func testReplacementHTTPChallengeCannotReceiveReplyFromPreviousSuspendedSignIn() async throws {
        let store = SuspendedBrowserCredentialStore()
        let fixture = try makeFixture(credentialsStore: store)
        let model = try fixture.requireModel()
        let originalReplies = AuthenticationReplies()
        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            originalReplies.append(disposition, credential)
        }
        let originalSignIn = Task { try await model.signInToHTTP(credentials, remember: true) }
        try await waitForSave(in: store)
        let replacementReplies = AuthenticationReplies()

        model.webView(model.webView, didReceive: challenge()) { disposition, credential in
            replacementReplies.append(disposition, credential)
        }
        await store.resumeSave()
        await assertExpiredChallenge(originalSignIn)

        XCTAssertEqual(originalReplies.values.count, 1)
        XCTAssertEqual(originalReplies.values.first?.disposition, .cancelAuthenticationChallenge)
        XCTAssertTrue(replacementReplies.values.isEmpty)
        XCTAssertTrue(model.needsHTTPLogin)
        let replacement = ContainerCredentials(username: "replacement-user", password: "replacement-test-password")
        try await model.signInToHTTP(replacement, remember: false)
        XCTAssertFalse(model.needsHTTPLogin)
        XCTAssertEqual(replacementReplies.values.count, 1)
        XCTAssertEqual(replacementReplies.values.first?.disposition, .useCredential)
        XCTAssertEqual(replacementReplies.values.first?.credential?.user, replacement.username)
        XCTAssertEqual(replacementReplies.values.first?.credential?.password, replacement.password)
    }

    func testDisconnectClearsDemoCredentialsProfilesAndKeepsUnrelatedServer() async throws {
        let preferences = BrowserModelTestPreferences(values: [
            "mockModeEnabled": true,
            "savedEndpoint": "http://previous.local",
            "casaOSUsername": "demo-user",
        ])
        let store = InMemoryContainerCredentialStore()
        let profiles = ContainerBrowserProfileStore(preferences: preferences)
        let demoIdentity = try makeIdentity()
        let otherServerURL = URL(string: "https://other.casanative.invalid")!
        let otherIdentity = try ContainerBrowserIdentity(
            serverURL: otherServerURL,
            appID: "other-container",
            launchURL: launchURL
        )
        let demoIdentifier = try autoreleasepool { try profiles.dataStore(for: demoIdentity).identifier }
        let otherIdentifier = try autoreleasepool { try profiles.dataStore(for: otherIdentity).identifier }
        try await store.save(credentials, for: demoIdentity)
        try await store.save(credentials, for: otherIdentity)
        let demoServerURL = serverURL
        addTeardownBlock { @MainActor in
            do {
                try await profiles.removeAll(for: demoServerURL)
                try await profiles.removeAll(for: otherServerURL)
            } catch {
                XCTFail("Browser profile teardown failed: \(error)")
            }
        }
        let model = AppModel(
            sshCredentialStore: InMemorySSHCredentialStore(),
            containerCredentialStore: store,
            containerBrowserProfiles: profiles,
            preferences: preferences
        )

        await model.disconnect()

        XCTAssertEqual(model.connectionState, .needsServer)
        XCTAssertFalse(model.mockMode)
        XCTAssertFalse(model.isForgettingServer)
        XCTAssertNil(model.disconnectError)
        XCTAssertEqual(model.endpointText, "")
        XCTAssertEqual(model.username, "")
        XCTAssertNil(preferences.string(forKey: "savedEndpoint"))
        XCTAssertNil(preferences.string(forKey: "casaOSUsername"))
        let demoCredentials = try await store.load(for: demoIdentity)
        let otherCredentials = try await store.load(for: otherIdentity)
        XCTAssertNil(demoCredentials)
        XCTAssertEqual(otherCredentials, credentials)
        try autoreleasepool {
            let reloadedDemoIdentifier = try profiles.dataStore(for: demoIdentity).identifier
            let reloadedOtherIdentifier = try profiles.dataStore(for: otherIdentity).identifier
            XCTAssertNotEqual(reloadedDemoIdentifier, demoIdentifier)
            XCTAssertEqual(reloadedOtherIdentifier, otherIdentifier)
        }
    }

    func testDisconnectCleanupFailurePreservesConnectionAndSavedCredentials() async throws {
        let preferences = BrowserModelTestPreferences(values: [
            "mockModeEnabled": true,
            "savedEndpoint": "http://previous.local",
            "casaOSUsername": "demo-user",
            "containerBrowserProfileRegistry.v1": "corrupt-registry",
        ])
        let store = InMemoryContainerCredentialStore()
        let identity = try makeIdentity()
        try await store.save(credentials, for: identity)
        let model = AppModel(
            sshCredentialStore: InMemorySSHCredentialStore(),
            containerCredentialStore: store,
            preferences: preferences
        )
        let priorEndpointText = model.endpointText

        await model.disconnect()

        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertTrue(model.mockMode)
        XCTAssertFalse(model.isForgettingServer)
        XCTAssertNotNil(model.disconnectError)
        XCTAssertEqual(model.endpointText, priorEndpointText)
        XCTAssertEqual(model.username, "demo-user")
        XCTAssertEqual(preferences.string(forKey: "savedEndpoint"), "http://previous.local")
        XCTAssertEqual(preferences.string(forKey: "casaOSUsername"), "demo-user")
        XCTAssertEqual(preferences.string(forKey: "containerBrowserProfileRegistry.v1"), "corrupt-registry")
        let saved = try await store.load(for: identity)
        XCTAssertEqual(saved, credentials)
    }

    private func makeIdentity() throws -> ContainerBrowserIdentity {
        try ContainerBrowserIdentity(serverURL: serverURL, appID: UUID().uuidString, launchURL: launchURL)
    }

    private func makeFixture(
        identity: ContainerBrowserIdentity? = nil,
        profiles: ContainerBrowserProfileStore? = nil,
        credentialsStore: any ContainerCredentialStoring = InMemoryContainerCredentialStore()
    ) throws -> BrowserFixture {
        let profileStore = profiles ?? ContainerBrowserProfileStore(preferences: BrowserModelTestPreferences())
        let identity = try identity ?? makeIdentity()
        let model = try autoreleasepool {
            try ContainerBrowserModel(
                name: "Container test",
                launchURL: launchURL,
                identity: identity,
                profileStore: profileStore,
                credentialStore: credentialsStore,
                isDemo: true
            )
        }
        let fixture = try autoreleasepool { try BrowserFixture(model: model) }
        let serverURL = self.serverURL
        addTeardownBlock { @MainActor in
            autoreleasepool { fixture.dispose() }
            do {
                try await profileStore.removeAll(for: serverURL)
            } catch {
                XCTFail("Browser fixture teardown failed: \(error)")
            }
        }
        return fixture
    }

    private func start(_ model: ContainerBrowserModel) async throws {
        _ = try await awaitNavigation(in: model, expectedURL: model.launchURL) { model.start() }
    }

    private func load(
        _ html: String,
        in model: ContainerBrowserModel,
        baseURL: URL? = nil
    ) async throws -> [String] {
        let url = baseURL ?? model.launchURL
        return try await awaitNavigation(in: model, expectedURL: url) {
            model.webView.loadHTMLString(html, baseURL: url)
        }
    }

    private func awaitNavigation(
        in model: ContainerBrowserModel,
        expectedURL: URL,
        onNavigationFinished: ((String) -> Void)? = nil,
        action: () -> Void
    ) async throws -> [String] {
        let waiter = BrowserNavigationWaiter(model: model, expectedURL: expectedURL)
        waiter.onNavigationFinished = onNavigationFinished
        model.webView.navigationDelegate = waiter
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            waiter.finish(.failure(BrowserTestError.timedOut))
        }
        defer {
            deadline.cancel()
            model.webView.navigationDelegate = model
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter.completion = { continuation.resume(with: $0) }
            action()
        }
    }

    private func state(in model: ContainerBrowserModel) async throws -> [String: Any] {
        let result = try await model.webView.evaluateJavaScript("""
            ({session: localStorage.getItem('signedIn'),
              hidden: document.querySelector('form').hidden,
              status: document.querySelector('#status').textContent})
            """)
        return try XCTUnwrap(result as? [String: Any])
    }

    private func inputs(in model: ContainerBrowserModel) async throws -> [String] {
        let result = try await model.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('input')).map(input => input.value)"
        )
        return try XCTUnwrap(result as? [String])
    }

    private func challenge(
        host: String = "demo.casanative.invalid",
        authenticationMethod: String = NSURLAuthenticationMethodHTTPBasic,
        realm: String = "Container test",
        previousFailureCount: Int = 0
    ) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: host,
                port: 443,
                protocol: "https",
                realm: realm,
                authenticationMethod: authenticationMethod
            ),
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: BrowserChallengeSender()
        )
    }

    private func waitForSave(in store: SuspendedBrowserCredentialStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await store.hasPendingSave { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserTestError.timedOut
    }

    private func assertExpiredChallenge(
        _ task: Task<Void, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected the original HTTP challenge to expire", file: file, line: line)
        } catch ContainerBrowserError.expiredChallenge {
            // Cancellation or replacement must prevent the old response from being delivered.
        } catch {
            XCTFail("Unexpected HTTP challenge error: \(error)", file: file, line: line)
        }
    }
}

private enum BrowserTestError: Error {
    case timedOut
}

@MainActor
private final class BrowserFixture {
    private var model: ContainerBrowserModel?
    private let window: UIWindow

    init(model: ContainerBrowserModel) throws {
        self.model = model
        let frame = CGRect(x: 0, y: 0, width: 640, height: 800)
        model.webView.frame = frame
        let controller = UIViewController()
        controller.view.addSubview(model.webView)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            "The host app must have a connected window scene for visible WebKit tests"
        )
        window = UIWindow(windowScene: scene)
        window.frame = frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    func requireModel() throws -> ContainerBrowserModel {
        try XCTUnwrap(model)
    }

    func showBrowserChrome() -> UIHostingController<ContainerBrowserView> {
        if let scene = window.windowScene { window.frame = scene.effectiveGeometry.coordinateSpace.bounds }
        let controller = UIHostingController(rootView: ContainerBrowserView(model: model!))
        window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return controller
    }

    func dispose() {
        model?.close()
        model?.webView.navigationDelegate = nil
        model?.webView.uiDelegate = nil
        model?.webView.removeFromSuperview()
        model = nil
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class BrowserNavigationWaiter: NSObject, WKNavigationDelegate {
    private weak var model: ContainerBrowserModel?
    private let expectedURL: URL
    private var finishedPages: [String] = []
    var completion: ((Result<[String], any Error>) -> Void)?
    var onNavigationFinished: ((String) -> Void)?

    init(model: ContainerBrowserModel, expectedURL: URL) {
        self.model = model
        self.expectedURL = expectedURL
    }

    func finish(_ result: Result<[String], any Error>) {
        let reply = completion
        completion = nil
        reply?(result)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        model?.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedPages.append(webView.url?.absoluteString ?? "")
        onNavigationFinished?(webView.url?.absoluteString ?? "")
        model?.webView(webView, didFinish: navigation)
        if webView.url == expectedURL { finish(.success(finishedPages)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        model?.webView(webView, didFail: navigation, withError: error)
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        model?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let model else { decisionHandler(.cancel); return }
        model.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
}

@MainActor
private final class AuthenticationReplies {
    struct Reply {
        let disposition: URLSession.AuthChallengeDisposition
        let credential: URLCredential?
    }
    private(set) var values: [Reply] = []

    func append(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        values.append(Reply(disposition: disposition, credential: credential))
    }
}

private final class BrowserChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private actor SuspendedBrowserCredentialStore: ContainerCredentialStoring {
    private var saved: [ContainerBrowserIdentity: ContainerCredentials] = [:]
    private var pendingSave: CheckedContinuation<Void, Never>?
    var hasPendingSave: Bool { pendingSave != nil }

    func save(_ credentials: ContainerCredentials, for identity: ContainerBrowserIdentity) async throws {
        await withCheckedContinuation { pendingSave = $0 }
        saved[identity] = credentials
    }

    func load(for identity: ContainerBrowserIdentity) async throws -> ContainerCredentials? { saved[identity] }
    func delete(for identity: ContainerBrowserIdentity) async throws { saved[identity] = nil }
    func deleteAll(for serverURL: URL) async throws {
        let origin = try EndpointOrigin(endpoint: serverURL)
        saved = saved.filter { $0.key.serverOrigin != origin }
    }

    func resumeSave() {
        let reply = pendingSave
        pendingSave = nil
        reply?.resume()
    }
}

private final class BrowserModelTestPreferences: AppPreferenceStoring {
    private var values: [String: Any]

    init(values: [String: Any] = [:]) { self.values = values }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
