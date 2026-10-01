import Combine
import SwiftUI
import WebKit

@MainActor
final class ContainerBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let name: String
    let launchURL: URL
    let identity: ContainerBrowserIdentity
    let webView: WKWebView
    let credentialStore: any ContainerCredentialStoring
    private let profileStore: ContainerBrowserProfileStore
    private let isDemo: Bool
    private var started = false
    private var lifetime = UUID()
    private var authenticationReply: (@MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
    @Published private(set) var httpChallengeID: UUID?
    private var authenticationScope: HTTPAuthenticationScope?
    private var authorizedHTTP: [HTTPAuthenticationScope: ContainerCredentials] = [:]
    private var resetNavigation: WKNavigation?
    private var resetReply: CheckedContinuation<Void, any Error>?
    private var dialogReply: ((String?) -> Void)?

    private struct HTTPAuthenticationScope: Hashable {
        let origin: EndpointOrigin
        let realm: String?
        let method: String
    }

    struct WebDialog: Identifiable {
        enum Kind { case alert, confirm, prompt }
        let id = UUID()
        let kind: Kind
        let message: String
        let origin: String
        var defaultText = ""
    }

    @Published private(set) var address = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isClearingSession = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var message: String?
    @Published var needsHTTPLogin = false
    @Published private(set) var webDialog: WebDialog?

    init(name: String, launchURL: URL, identity: ContainerBrowserIdentity,
         profileStore: ContainerBrowserProfileStore,
         credentialStore: any ContainerCredentialStoring, isDemo: Bool = false) throws {
        self.name = name
        self.launchURL = launchURL
        self.identity = identity
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.isDemo = isDemo
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = try profileStore.dataStore(for: identity)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        address = identity.launchOrigin.rawValue
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
    }

    func reload() {
        guard !isClearingSession else { return }
        message = nil
        if isDemo {
            webView.loadHTMLString(Self.demoHTML, baseURL: launchURL)
        } else if webView.url == nil {
            webView.load(URLRequest(url: launchURL))
        } else {
            webView.reload()
        }
    }

    func fill(_ credentials: ContainerCredentials, remember: Bool) async throws {
        guard !isClearingSession else { throw ContainerBrowserError.sessionCleanupInProgress }
        // Check again after Keychain work and inside the isolated script. Never submit a form.
        guard identity.allowsCredentialFill(at: webView.url) else {
            throw ContainerBrowserError.untrustedPage
        }
        try await ContainerLoginForm.fill(credentials, in: webView, identity: identity)
        if remember { try await credentialStore.save(credentials, for: identity) }
        message = remember
            ? "Sign-in filled and saved in Keychain. Continue on the app’s page."
            : "Sign-in filled. Continue on the app’s page."
    }

    func signInToHTTP(_ credentials: ContainerCredentials, remember: Bool) async throws {
        guard credentials.isComplete, let challengeID = httpChallengeID,
              let scope = authenticationScope,
              let reply = authenticationReply else { throw ContainerBrowserError.expiredChallenge }
        if remember { try await credentialStore.save(credentials, for: identity) }
        guard httpChallengeID == challengeID else { throw ContainerBrowserError.expiredChallenge }
        authenticationReply = nil
        httpChallengeID = nil
        authenticationScope = nil
        authorizedHTTP[scope] = credentials
        needsHTTPLogin = false
        reply(.useCredential, URLCredential(user: credentials.username, password: credentials.password, persistence: .none))
    }

    func cancelHTTPLogin(ifMatching challengeID: UUID? = nil) {
        if let challengeID, httpChallengeID != challengeID { return }
        let reply = authenticationReply
        authenticationReply = nil
        httpChallengeID = nil
        authenticationScope = nil
        needsHTTPLogin = false
        reply?(.cancelAuthenticationChallenge, nil)
    }

    func close() {
        lifetime = UUID()
        cancelHTTPLogin()
        authorizedHTTP.removeAll()
        resolveDialog(value: nil)
        finishReset(throwing: CancellationError())
        webView.stopLoading()
    }

    func clearSession() async throws {
        guard !isClearingSession else { throw ContainerBrowserError.sessionCleanupInProgress }
        isClearingSession = true
        let allowsGestures = webView.allowsBackForwardNavigationGestures
        let allowsInteraction = webView.isUserInteractionEnabled
        webView.allowsBackForwardNavigationGestures = false
        webView.isUserInteractionEnabled = false
        defer {
            isClearingSession = false
            webView.allowsBackForwardNavigationGestures = allowsGestures
            webView.isUserInteractionEnabled = allowsInteraction
        }
        let currentLifetime = lifetime
        cancelHTTPLogin()
        authorizedHTTP.removeAll()
        resolveDialog(value: nil)
        webView.stopLoading()
        // Dispose of the active document before clearing storage: its timers could otherwise
        // write tokens back into localStorage while WebKit is deleting website data.
        try await withCheckedThrowingContinuation { continuation in
            resetReply = continuation
            resetNavigation = webView.loadHTMLString("<html></html>", baseURL: nil)
            if resetNavigation == nil { finishReset(throwing: ContainerBrowserError.expiredChallenge) }
        }
        try await profileStore.clearSession(for: identity)
        guard lifetime == currentLifetime else { throw CancellationError() }
        isClearingSession = false
        // Recreate the page document so it cannot retain an in-memory token after clearing.
        if isDemo { webView.loadHTMLString(Self.demoHTML, baseURL: launchURL) }
        else { webView.load(URLRequest(url: launchURL)) }
    }

    private func updateState() {
        address = webView.url.flatMap { try? EndpointOrigin(endpoint: $0).rawValue } ?? identity.launchOrigin.rawValue
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        message = nil
        updateState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateState()
        if let resetNavigation, navigation === resetNavigation { finishReset() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        updateState()
        if let resetNavigation, navigation === resetNavigation { finishReset(throwing: error) }
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateState()
        finishReset(throwing: ContainerBrowserError.expiredChallenge)
        message = "The page stopped responding. Reload to continue."
    }

    private func finishReset(throwing error: (any Error)? = nil) {
        let reply = resetReply
        resetReply = nil
        resetNavigation = nil
        if let error { reply?.resume(throwing: error) }
        else { reply?.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard !isClearingSession || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated,
               navigationAction.sourceFrame.isMainFrame,
               scheme == "mailto" || scheme == "tel" {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !isClearingSession, navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !isClearingSession else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest else {
            // System trust evaluation remains authoritative; never accept invalid TLS certificates.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var components = URLComponents()
        components.scheme = space.protocol
        components.host = space.host
        components.port = space.port
        guard identity.allowsCredentialFill(at: components.url) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            message = "Authentication redirected to another address. Open that service in Safari to sign in."
            return
        }
        let scope = HTTPAuthenticationScope(origin: identity.launchOrigin, realm: space.realm, method: space.authenticationMethod)
        if challenge.previousFailureCount == 0, let credentials = authorizedHTTP[scope] {
            completionHandler(.useCredential, URLCredential(user: credentials.username, password: credentials.password, persistence: .none))
            return
        }
        authorizedHTTP[scope] = nil
        cancelHTTPLogin()
        authenticationReply = completionHandler
        httpChallengeID = UUID()
        authenticationScope = scope
        needsHTTPLogin = true
    }

    func resolveDialog(value: String?) {
        let reply = dialogReply
        dialogReply = nil
        webDialog = nil
        reply?(value)
    }

    private func showDialog(_ kind: WebDialog.Kind, message: String, frame: WKFrameInfo,
                            defaultText: String = "", reply: @escaping (String?) -> Void) {
        resolveDialog(value: nil)
        dialogReply = reply
        let origin = frame.request.url.flatMap { try? EndpointOrigin(endpoint: $0).rawValue } ?? "Web page"
        webDialog = WebDialog(kind: kind, message: message, origin: origin, defaultText: defaultText)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        showDialog(.alert, message: message, frame: frame) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        showDialog(.confirm, message: message, frame: frame) { completionHandler($0 != nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        showDialog(.prompt, message: prompt, frame: frame, defaultText: defaultText ?? "", reply: completionHandler)
    }

    // A self-contained fixture: no network requests, no CasaOS actions, no credential validation.
    static let demoHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{font:17px -apple-system;padding:30px;background:#f5f5fa;color:#242438}main{max-width:360px;margin:35px auto;padding:24px;background:white;border-radius:22px}input,button{box-sizing:border-box;width:100%;padding:14px;margin:8px 0;border-radius:12px;border:1px solid #ddd;font:inherit}button{background:#465be8;color:white}small{color:#626277}</style></head>
    <body><main><h1>Container demo</h1><p id="status">Sign in once. Close and reopen to test session retention.</p>
    <form method="post"><label>Username<input autocomplete="username" name="username"></label>
    <label>Password<input autocomplete="current-password" name="password" type="password"></label>
    <button type="submit">Sign in</button></form><small>Local demo only. Use sample credentials.</small></main>
    <script>const f=document.querySelector('form');function show(){if(localStorage.getItem('signedIn')==='yes'){f.hidden=true;document.querySelector('#status').textContent='Signed in — session restored.';}}
    f.addEventListener('submit',e=>{e.preventDefault();localStorage.setItem('signedIn','yes');show();});show();</script></body></html>
    """
}

enum ContainerBrowserError: LocalizedError {
    case untrustedPage
    case expiredChallenge
    case sessionCleanupInProgress
    var errorDescription: String? {
        switch self {
        case .untrustedPage: "Saved sign-in is restricted to this container’s original address. Sign in manually after a redirect."
        case .expiredChallenge: "The sign-in request ended. Reload the page and try again."
        case .sessionCleanupInProgress: "The browser session is being cleared. Try again when cleanup finishes."
        }
    }
}

struct ContainerBrowserView: View {
    @ObservedObject var model: ContainerBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingLogin = false
    @State private var presentedHTTPChallenge: UUID?
    @State private var pendingRemoval: Removal?
    @State private var isChangingStorage = false
    @State private var dialogText = ""

    private enum Removal: String, Identifiable {
        case login, session
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(model.address)
                    .font(.caption.monospaced())
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(.bar)
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(4) }
                if let message = model.message {
                    HStack(alignment: .top) {
                        Text(message).font(.caption)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { model.message = nil }.labelStyle(.iconOnly)
                    }.padding(10).background(.secondary.opacity(0.08))
                }
                ContainerWebView(webView: model.webView)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 20) {
                    Button("Back", systemImage: "chevron.left") { model.webView.goBack() }
                        .disabled(!model.canGoBack).labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                    Button("Forward", systemImage: "chevron.right") { model.webView.goForward() }
                        .disabled(!model.canGoForward).labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                    Spacer(minLength: 0)
                    Button("Sign In", systemImage: "key.fill") {
                        presentedHTTPChallenge = model.httpChallengeID
                        isShowingLogin = true
                    }
                    .disabled(!model.identity.allowsCredentialFill(at: model.webView.url) || isChangingStorage)
                    .frame(minHeight: 44)
                    Spacer(minLength: 0)
                    Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
                        .disabled(isChangingStorage).labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.bar)
                .disabled(model.isClearingSession)
            }
            .navigationTitle(model.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { model.close(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Open in Safari", systemImage: "safari") {
                            if let url = model.webView.url, ["http", "https"].contains(url.scheme ?? "") {
                                UIApplication.shared.open(url)
                            }
                        }
                        Button("Forget Saved Login", systemImage: "key.slash", role: .destructive) { pendingRemoval = .login }
                        Button("Clear Browser Session", systemImage: "trash", role: .destructive) { pendingRemoval = .session }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(isChangingStorage)
                }
            }
            .task { model.start() }
            .onDisappear { model.close() }
            .sheet(isPresented: $isShowingLogin, onDismiss: loginDismissed) {
                ContainerLoginSheet(model: model)
            }
            .onChange(of: model.httpChallengeID) { _, challengeID in
                if let challengeID, !isShowingLogin {
                    presentedHTTPChallenge = challengeID
                    isShowingLogin = true
                }
            }
            .onChange(of: model.webDialog?.id) { _, _ in dialogText = model.webDialog?.defaultText ?? "" }
            .alert(model.webDialog?.origin ?? "Web page", isPresented: Binding(
                get: { model.webDialog != nil },
                set: { if !$0 { model.resolveDialog(value: nil) } }
            )) {
                if model.webDialog?.kind == .prompt { TextField("Response", text: $dialogText) }
                if model.webDialog?.kind != .alert {
                    Button("Cancel", role: .cancel) { model.resolveDialog(value: nil) }
                }
                Button("OK") { model.resolveDialog(value: dialogText) }
            } message: { Text(model.webDialog?.message ?? "") }
            .confirmationDialog(
                pendingRemoval == .login ? "Forget saved login?" : "Clear browser session?",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button(pendingRemoval == .login ? "Forget Login" : "Clear Session", role: .destructive) { removeStorage() }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text(pendingRemoval == .login
                     ? "Removes this container’s saved password from Casa Native’s Keychain. Its browser session stays signed in."
                     : "Removes this container’s cookies and website storage, then reloads its sign-in page. Its saved password remains available.")
            }
        }
    }

    private func loginDismissed() {
        if let presentedHTTPChallenge { model.cancelHTTPLogin(ifMatching: presentedHTTPChallenge) }
        presentedHTTPChallenge = nil
        // A rejected response can create a new challenge while the old sheet is dismissing.
        if let challengeID = model.httpChallengeID {
            Task { @MainActor in
                await Task.yield()
                guard model.httpChallengeID == challengeID else { return }
                presentedHTTPChallenge = challengeID
                isShowingLogin = true
            }
        }
    }

    private func removeStorage() {
        guard let removal = pendingRemoval else { return }
        pendingRemoval = nil
        isChangingStorage = true
        Task {
            defer { isChangingStorage = false }
            do {
                switch removal {
                case .login:
                    try await model.credentialStore.delete(for: model.identity)
                    model.message = "Saved login forgotten."
                case .session: try await model.clearSession()
                }
            } catch { model.message = error.localizedDescription }
        }
    }
}

private struct ContainerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct ContainerLoginSheet: View {
    @ObservedObject var model: ContainerBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var isWorking = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.identity.launchOrigin.rawValue).font(.callout.monospaced()).textSelection(.enabled)
                    TextField("Username or email (optional)", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    Toggle("Remember in Keychain", isOn: $remember)
                } footer: {
                    Text("Use the keyboard’s Passwords button to choose an existing login, or enter it here. Remember saves it securely in Casa Native on this device, not in Apple Passwords.")
                }
                if model.identity.launchOrigin.rawValue.hasPrefix("http://") {
                    Section {
                        Label("This app uses HTTP. Sign-in credentials are not encrypted in transit. Use only a trusted network.", systemImage: "exclamationmark.shield")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Section {
                    Button(model.needsHTTPLogin ? "Sign In" : "Fill Sign-in") { fill() }
                        .disabled(password.isEmpty || isWorking)
                    if isWorking { ProgressView("Accessing Keychain…") }
                    if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
                } footer: {
                    Text("Website forms are filled only after this action. Submit on the app’s page. MFA, passkeys, and unsupported forms remain interactive. Browser sessions persist until the service signs you out.")
                }
            }
            .navigationTitle("\(model.name) Sign-in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isWorking) } }
            .task {
                defer { isWorking = false }
                do {
                    if let credentials = try await model.credentialStore.load(for: model.identity) {
                        username = credentials.username
                        password = credentials.password
                    }
                } catch { errorMessage = error.localizedDescription }
            }
            .onDisappear { password = "" }
        }
    }

    private func fill() {
        isWorking = true
        errorMessage = nil
        let credentials = ContainerCredentials(username: username, password: password)
        Task {
            defer { isWorking = false }
            do {
                if model.needsHTTPLogin { try await model.signInToHTTP(credentials, remember: remember) }
                else { try await model.fill(credentials, remember: remember) }
                password = ""
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
