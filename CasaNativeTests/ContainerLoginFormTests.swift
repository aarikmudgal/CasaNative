import UIKit
import WebKit
import XCTest
@testable import CasaNative

@MainActor
final class ContainerLoginFormTests: XCTestCase {
    private var windows: [UIWindow] = []
    private let trustedURL = URL(string: "https://login.casa.local:8443/signin")!
    private let credentials = ContainerCredentials(
        username: "a\"'\\<>&雪🦊\u{2028}@example.test",
        password: "p\"'\\</script><>&🔐\u{2029}"
    )

    func testFillsExactValuesWithNativeSetterAndEventsWithoutSubmitting() async throws {
        let webView = try await load("""
            <form method="post" action="/session">
                <input id="username" autocomplete="username">
                <input id="password" type="password" autocomplete="current-password">
                <button>Sign in</button>
            </form>
            <script>
                window.submitCount = 0;
                window.wrapperSetterCalls = 0;
                window.inputCount = 0;
                window.changeCount = 0;
                document.querySelector('form').addEventListener('submit', event => {
                    event.preventDefault(); window.submitCount++;
                });
                for (const input of document.querySelectorAll('input')) {
                    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                    Object.defineProperty(input, 'value', {
                        get() { return native.get.call(this); },
                        set(value) { window.wrapperSetterCalls++; native.set.call(this, value); }
                    });
                    input.addEventListener('input', () => window.inputCount++);
                    input.addEventListener('change', () => window.changeCount++);
                }
            </script>
            """)

        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())

        let state = try await dictionary("""
            ({ username: document.getElementById('username').value,
               password: document.getElementById('password').value,
               submitCount: window.submitCount, wrapperSetterCalls: window.wrapperSetterCalls,
               inputCount: window.inputCount, changeCount: window.changeCount })
            """, in: webView)
        XCTAssertEqual(state["username"] as? String, credentials.username)
        XCTAssertEqual(state["password"] as? String, credentials.password)
        XCTAssertEqual(state["submitCount"] as? Int, 0)
        XCTAssertEqual(state["wrapperSetterCalls"] as? Int, 0)
        XCTAssertEqual(state["inputCount"] as? Int, 2)
        XCTAssertEqual(state["changeCount"] as? Int, 2)
    }

    func testSupportsPasswordOnlyAndEmptyActionSPAForms() async throws {
        for formAttributes in ["method='post' action='/session'", "", "action=''"] {
            let webView = try await load("""
                <form \(formAttributes)><input id="password" type="password"></form>
                <script>
                    window.submitCount = 0;
                    document.querySelector('form').addEventListener('submit', event => {
                        event.preventDefault(); window.submitCount++;
                    });
                </script>
                """)

            try await ContainerLoginForm.fill(
                ContainerCredentials(username: "", password: credentials.password),
                in: webView,
                identity: identity()
            )

            let state = try await dictionary("""
                ({ password: document.getElementById('password').value, submitCount: window.submitCount })
                """, in: webView)
            XCTAssertEqual(state["password"] as? String, credentials.password)
            XCTAssertEqual(state["submitCount"] as? Int, 0)
        }
    }

    func testSupportsEmailAndFormlessSignIn() async throws {
        for html in [
            "<form method='post'><input type='email' id='username'><input type='password'></form>",
            "<input id='username' autocomplete='username'><input type='password'>"
        ] {
            let webView = try await load(html)
            try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())
            let values = try await inputValues(in: webView)
            XCTAssertEqual(values, [credentials.username, credentials.password])
        }
    }

    func testNormalizedOriginPreservesExactSchemeAndPortTrust() async throws {
        let pageURL = try XCTUnwrap(URL(string: "HTTPS://LOGIN.CASA.LOCAL.:8443/signin"))
        let webView = try await load("<form method='post'><input><input type='password'></form>", baseURL: pageURL)

        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())

        try await assertInputValues([credentials.username, credentials.password], in: webView)
    }

    func testRejectsOffOriginAndUserinfoPagesWithoutFilling() async throws {
        for address in [
            "http://login.casa.local:8443/signin",
            "https://login.casa.local:8444/signin",
            "https://other.casa.local:8443/signin",
            "https://user:secret@login.casa.local:8443/signin"
        ] {
            let webView = try await load(
                "<form method='post'><input autocomplete='username'><input type='password'></form>",
                baseURL: try XCTUnwrap(URL(string: address))
            )

            await assertRejected(webView, error: .untrustedPage)
            try await assertInputValues(["", ""], in: webView)
        }
    }

    func testJavaScriptIndependentlyRejectsChangedOriginBeforeAnyWrite() async throws {
        let webView = try await load("<form method='post'><input><input type='password'></form>")
        for expectedOrigin in [
            "http://login.casa.local:8443",
            "https://login.casa.local:8444",
            "https://other.casa.local:8443"
        ] {
            let result = try await webView.callAsyncJavaScript(
                ContainerLoginForm.source,
                arguments: [
                    "username": credentials.username,
                    "password": credentials.password,
                    "expectedOrigin": expectedOrigin
                ],
                in: nil,
                contentWorld: .defaultClient
            )
            XCTAssertEqual(result as? String, "untrusted")
            try await assertInputValues(["", ""], in: webView)
        }
    }

    func testRejectsCrossOriginActionsAndSubmitterOverrides() async throws {
        for html in [
            "<form method='post' action='https://evil.test/session'><input><input type='password'></form>",
            "<form method='post' action='http://login.casa.local:8443/session'><input><input type='password'></form>",
            "<form method='post' action='https://login.casa.local:8444/session'><input><input type='password'></form>",
            "<form method='post' action='https://user:secret@login.casa.local:8443/session'><input><input type='password'></form>",
            "<form method='post'><input><input type='password'><button formaction='https://evil.test/session'>Sign in</button></form>",
            "<form id='login' method='post'><input><input type='password'></form><input type='image' form='login' formaction='https://evil.test/session'>",
            "<base href='https://evil.test/'><form method='post' action='session'><input><input type='password'></form>"
        ] {
            let webView = try await load(html)
            await assertRejected(webView, error: .untrustedPage)
            let values = try await inputValues(in: webView)
            XCTAssertTrue(values.allSatisfy(\.isEmpty))
        }
    }

    func testRejectsExplicitGETAndFrameTargets() async throws {
        for attributes in [
            "method='get'", "method='get' action='/session'", "action='/session'",
            "method='post' target='sign-in-frame'", "method='post' target='_blank'"
        ] {
            let webView = try await load("<form \(attributes)><input><input type='password'></form>")
            await assertRejected(webView)
            try await assertInputValues(["", ""], in: webView)
        }
        for submitter in [
            "<button formmethod='get'>Sign in</button>",
            "<button formtarget='sign-in-frame'>Sign in</button>",
            "<input type='image' formmethod='get'>",
            "<input type='image' formtarget='sign-in-frame'>"
        ] {
            let webView = try await load("""
                <form method='post'><input><input type='password'>\(submitter)</form>
                """)
            await assertRejected(webView)
            let values = try await inputValues(in: webView)
            XCTAssertTrue(values.allSatisfy(\.isEmpty))
        }
        let baseTargetWebView = try await load("""
            <base target='sign-in-frame'><form method='post'><input><input type='password'></form>
            """)
        await assertRejected(baseTargetWebView)
        try await assertInputValues(["", ""], in: baseTargetWebView)
    }

    func testRejectsRegistrationPasswordChangesAndAmbiguousForms() async throws {
        for html in [
            "<form method='post'><input><input type='password' autocomplete='new-password'></form>",
            "<form method='post'><input type='password'><input type='password'></form>",
            "<form method='post'><input type='password' autocomplete='current-password'><input type='password' autocomplete='new-password'></form>",
            "<form method='post'><input type='password'></form><form method='post'><input type='password'></form>",
            "<form method='post'><input name='username'><input name='full-name'><input type='password'></form>"
        ] {
            let webView = try await load(html)
            await assertRejected(webView)
            let values = try await inputValues(in: webView)
            XCTAssertTrue(values.allSatisfy(\.isEmpty))
        }
    }

    func testRejectsDisabledReadonlyAndHiddenPasswordFields() async throws {
        for attributes in [
            "disabled", "readonly", "hidden", "style='display:none'", "style='visibility:hidden'"
        ] {
            let webView = try await load("<form method='post'><input><input type='password' \(attributes)></form>")
            await assertRejected(webView)
            try await assertInputValues(["", ""], in: webView)
        }
        let webView = try await load("""
            <form method='post' style='opacity:0'><input><input type='password'></form>
            """)
        await assertRejected(webView)
        try await assertInputValues(["", ""], in: webView)
    }

    func testDoesNotFillIframesEvenWhenSameOrigin() async throws {
        let frameForm = "<form method='post'><input><input type='password'></form>"
        let webView = try await load("""
            <form method='post'><input id='username'><input id='password' type='password'></form>
            <iframe srcdoc="\(frameForm)"></iframe>
            """)

        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())

        let frameValues = try await webView.evaluateJavaScript("""
            Array.from(document.querySelector('iframe').contentDocument.querySelectorAll('input')).map(input => input.value)
            """)
        XCTAssertEqual(frameValues as? [String], ["", ""])
        try await assertInputValues([credentials.username, credentials.password], in: webView)
    }

    func testIframeOnlyLoginRequiresManualSignIn() async throws {
        let webView = try await load("""
            <iframe srcdoc="<form method='post'><input><input type='password'></form>"></iframe>
            """)

        await assertRejected(webView)

        let frameValues = try await webView.evaluateJavaScript("""
            Array.from(document.querySelector('iframe').contentDocument.querySelectorAll('input')).map(input => input.value)
            """)
        XCTAssertEqual(frameValues as? [String], ["", ""])
    }

    func testDoesNotOverwriteDifferentExistingDetails() async throws {
        for html in [
            "<form method='post'><input value='someone-else'><input type='password'></form>",
            "<form method='post'><input name='username' readonly value='someone-else'><input type='password'></form>",
            "<form method='post'><input name='username' disabled value='someone-else'><input type='password'></form>",
            "<form method='post'><input name='username' type='hidden' value='someone-else'><input type='password'></form>",
            "<form method='post'><input><input type='password' value='different-secret'></form>"
        ] {
            let webView = try await load(html)
            let before = try await inputValues(in: webView)

            await assertRejected(webView, error: .existingValues)

            try await assertInputValues(before, in: webView)
        }
    }

    func testDoesNotTreatUnavailableUsernameAsPasswordOnlyLogin() async throws {
        for attributes in ["readonly", "disabled", "hidden", "type='hidden' name='username'"] {
            let webView = try await load("<form method='post'><input \(attributes)><input type='password'></form>")

            await assertRejected(webView)

            try await assertInputValues(["", ""], in: webView)
        }
    }

    func testMatchingExistingDetailsDoNotDispatchEventsAgain() async throws {
        let webView = try await load("""
            <form method='post'><input><input type='password'></form>
            <script>
                window.inputCount = 0;
                document.addEventListener('input', () => window.inputCount++);
            </script>
            """)
        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())
        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())

        let inputCount = try await webView.evaluateJavaScript("window.inputCount")
        XCTAssertEqual(inputCount as? Int, 2)
        try await assertInputValues([credentials.username, credentials.password], in: webView)
    }

    func testRejectsMissingPasswordAndLineBreakSanitizationWithoutPartialFill() async throws {
        let webView = try await load("<form method='post'><input><input type='password'></form>")
        for pair in [
            (ContainerCredentials(username: "user", password: ""), ContainerLoginForm.FillError.incompleteCredentials),
            (ContainerCredentials(username: "user", password: "secret\nvalue"), ContainerLoginForm.FillError.unsupportedForm)
        ] {
            do {
                try await ContainerLoginForm.fill(pair.0, in: webView, identity: identity())
                XCTFail("Expected unsafe or incomplete credentials to be rejected")
            } catch {
                XCTAssertEqual(error as? ContainerLoginForm.FillError, pair.1)
            }
            try await assertInputValues(["", ""], in: webView)
        }
        let emailWebView = try await load("<form method='post'><input type='email'><input type='password'></form>")
        do {
            try await ContainerLoginForm.fill(
                ContainerCredentials(username: " user@example.test ", password: credentials.password),
                in: emailWebView,
                identity: identity()
            )
            XCTFail("Expected browser credential sanitization to be rejected")
        } catch {
            XCTAssertEqual(error as? ContainerLoginForm.FillError, .unsupportedForm)
        }
        try await assertInputValues(["", ""], in: emailWebView)
    }

    private func identity() throws -> ContainerBrowserIdentity {
        try ContainerBrowserIdentity(
            serverURL: URL(string: "https://casa.local")!,
            appID: "example-container",
            launchURL: trustedURL
        )
    }

    private func assertRejected(
        _ webView: WKWebView,
        error expected: ContainerLoginForm.FillError = .unsupportedForm,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await ContainerLoginForm.fill(credentials, in: webView, identity: identity())
            XCTFail("Expected credential fill to be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ContainerLoginForm.FillError, expected, file: file, line: line)
        }
    }

    private func dictionary(_ script: String, in webView: WKWebView) async throws -> [String: Any] {
        let value = try await webView.evaluateJavaScript(script)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func inputValues(in webView: WKWebView) async throws -> [String] {
        let value = try await webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('input')).map(input => input.value)"
        )
        return try XCTUnwrap(value as? [String])
    }

    private func assertInputValues(
        _ expected: [String],
        in webView: WKWebView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let values = try await inputValues(in: webView)
        XCTAssertEqual(values, expected, file: file, line: line)
    }

    private func load(_ html: String, baseURL: URL? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 800), configuration: configuration)
        let controller = UIViewController()
        controller.view.addSubview(webView)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The XCTest host must provide a connected window scene."
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 800)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows.append(window)

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            waiter.finish(.failure(LoadingError.timedOut))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            waiter.completion = { continuation.resume(with: $0) }
            webView.loadHTMLString(html, baseURL: baseURL ?? trustedURL)
        }
        webView.navigationDelegate = nil
        return webView
    }

    private enum LoadingError: Error {
        case timedOut
    }

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var completion: ((Result<Void, any Error>) -> Void)?

        func finish(_ result: Result<Void, any Error>) {
            let callback = completion
            completion = nil
            callback?(result)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(error))
        }
    }
}
