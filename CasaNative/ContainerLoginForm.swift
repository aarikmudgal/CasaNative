import Foundation
import WebKit

/// Fills a supported sign-in form only after an explicit user action. It never submits the form.
@MainActor
enum ContainerLoginForm {
    enum FillError: LocalizedError, Equatable {
        case untrustedPage
        case unsupportedForm
        case existingValues
        case incompleteCredentials
        case pageUnavailable

        var errorDescription: String? {
            switch self {
            case .untrustedPage:
                "This page is outside this app's saved origin. Return to the app's original address before filling credentials."
            case .unsupportedForm:
                "This page does not have one supported sign-in form. Sign in manually; registration, password changes, frames, and unsafe form actions are not filled."
            case .existingValues:
                "This form already contains different sign-in details. Clear those fields before filling saved credentials, or sign in manually."
            case .incompleteCredentials:
                "Enter the sign-in details before filling this form."
            case .pageUnavailable:
                "The sign-in page is not ready. Wait for it to finish loading and try again, or sign in manually."
            }
        }
    }

    static func fill(
        _ credentials: ContainerCredentials,
        in webView: WKWebView,
        identity: ContainerBrowserIdentity
    ) async throws {
        guard identity.allowsCredentialFill(at: webView.url) else {
            throw FillError.untrustedPage
        }
        guard !credentials.password.isEmpty else {
            throw FillError.incompleteCredentials
        }

        let result: Any?
        do {
            // Arguments keep secrets out of script source. A nil frame targets only the main frame.
            result = try await webView.callAsyncJavaScript(
                source,
                arguments: [
                    "username": credentials.username,
                    "password": credentials.password,
                    "expectedOrigin": identity.launchOrigin.rawValue
                ],
                in: nil,
                contentWorld: .defaultClient
            )
        } catch {
            throw FillError.pageUnavailable
        }

        switch result as? String {
        case "filled":
            return
        case "untrusted":
            throw FillError.untrustedPage
        case "existing":
            throw FillError.existingValues
        case "incomplete":
            throw FillError.incompleteCredentials
        default:
            throw FillError.unsupportedForm
        }
    }

    // No listeners, page-value harvesting, persisted scripts, or submission are installed.
    static let source = #"""
    const normalizedOrigin = value => {
        try {
            const url = new URL(value);
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
            const hostname = url.hostname.toLowerCase().replace(/\.+$/, '');
            if (!hostname) return null;
            const port = url.port ? ':' + url.port : '';
            return url.protocol.toLowerCase() + '//' + hostname + port;
        } catch {
            return null;
        }
    };
    const trustedDocument = () => window === window.top && normalizedOrigin(location.href) === expectedOrigin;
    if (!trustedDocument()) return 'untrusted';
    if (typeof username !== 'string' || typeof password !== 'string' || !password) return 'incomplete';
    // HTML input value sanitization removes line breaks; do not silently change saved credentials.
    if (/[\r\n]/.test(username) || /[\r\n]/.test(password)) return 'unsupported';

    const editable = input => {
        if (!(input instanceof HTMLInputElement) || input.disabled || input.readOnly || input.matches(':disabled')) return false;
        if (input.type === 'hidden' || input.hidden || input.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
        const style = getComputedStyle(input);
        if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) return false;
        for (let parent = input.parentElement; parent; parent = parent.parentElement) {
            if (Number(getComputedStyle(parent).opacity) === 0) return false;
        }
        const rect = input.getBoundingClientRect();
        return input.getClientRects().length > 0 && rect.width > 0 && rect.height > 0;
    };
    const autocompleteTokens = input => (input.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
    const passwordInputs = Array.from(document.querySelectorAll('input')).filter(input => input.type === 'password');
    const visiblePasswords = passwordInputs.filter(editable);
    if (visiblePasswords.length !== 1) return 'unsupported';
    const passwordInput = visiblePasswords[0];
    const form = passwordInput.form;
    const group = form
        ? Array.from(form.elements).filter(element => element instanceof HTMLInputElement)
        : Array.from(document.querySelectorAll('input')).filter(input => !input.form);
    const groupPasswords = group.filter(input => input.type === 'password');
    if (groupPasswords.length !== 1 || groupPasswords.some(input => autocompleteTokens(input).includes('new-password'))) return 'unsupported';

    if (form) {
        const action = (form.getAttribute('action') || '').trim();
        let destination;
        try {
            destination = new URL(action || location.href, document.baseURI);
        } catch {
            return 'unsupported';
        }
        if (normalizedOrigin(destination.href) !== expectedOrigin) return 'untrusted';
        const baseTarget = document.querySelector('base[target]')?.getAttribute('target') || '';
        const target = (form.getAttribute('target') || baseTarget).trim().toLowerCase();
        if (target && target !== '_self') return 'unsupported';
        // Many SPA forms omit method/action and handle submit in JavaScript. Permit that shape,
        // but never fill a form explicitly configured to send passwords in a GET URL.
        if (form.method.toLowerCase() !== 'post' && (form.hasAttribute('method') || action)) return 'unsupported';
        // form.elements excludes image submitters, including those associated with form="...".
        const submitters = Array.from(document.querySelectorAll('button, input')).filter(element =>
            element.form === form && !element.disabled && ((element instanceof HTMLButtonElement && element.type === 'submit') ||
            (element instanceof HTMLInputElement && ['submit', 'image'].includes(element.type))));
        for (const submitter of submitters) {
            if (submitter.hasAttribute('formaction')) {
                let override;
                try {
                    override = new URL(submitter.getAttribute('formaction') || location.href, document.baseURI);
                } catch {
                    return 'unsupported';
                }
                if (normalizedOrigin(override.href) !== expectedOrigin) return 'untrusted';
            }
            if (submitter.hasAttribute('formmethod') && submitter.formMethod.toLowerCase() !== 'post') return 'unsupported';
            if (submitter.hasAttribute('formaction') && form.method.toLowerCase() !== 'post' &&
                !(submitter.hasAttribute('formmethod') && submitter.formMethod.toLowerCase() === 'post')) return 'unsupported';
            const overrideTarget = (submitter.getAttribute('formtarget') || '').trim().toLowerCase();
            if (overrideTarget && overrideTarget !== '_self') return 'unsupported';
        }
    }

    const textInputs = group.filter(input => ['text', 'email', 'tel'].includes(input.type));
    const hiddenAccounts = group.filter(input => input.type === 'hidden' &&
        (autocompleteTokens(input).includes('username') ||
        /(^|[^a-z0-9])(user(name)?|email|login|account)([^a-z0-9]|$)/i.test([input.name, input.id].join(' '))));
    const unavailableAccounts = [...textInputs.filter(input => !editable(input)), ...hiddenAccounts];
    if (unavailableAccounts.some(input => input.value && input.value !== username)) return 'existing';
    // A fixed or hidden account field is not a password-only sign-in form.
    if (unavailableAccounts.length) return 'unsupported';
    const usernameInputs = textInputs.filter(editable);
    // Do not guess whether other editable text fields belong to registration or a password-change flow.
    if (usernameInputs.length > 1) return 'unsupported';
    const usernameInput = usernameInputs[0] || null;
    if (usernameInput && !username) return 'incomplete';
    if ((usernameInput && usernameInput.value && usernameInput.value !== username) ||
        (passwordInput.value && passwordInput.value !== password)) return 'existing';

    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (!setter || !trustedDocument()) return 'untrusted';
    const fields = usernameInput ? [[usernameInput, username], [passwordInput, password]] : [[passwordInput, password]];
    const changed = fields.filter(([input, value]) => input.value !== value);
    // Check browser sanitization without putting a changed credential value in the document.
    for (const [input, value] of fields) {
        const probe = input.cloneNode(false);
        setter.call(probe, value);
        if (probe.value !== value) return 'unsupported';
    }
    // Native setters work with controlled React-style inputs without invoking page-defined setters.
    for (const [input, value] of changed) setter.call(input, value);
    if (fields.some(([input, value]) => input.value !== value)) {
        // Changed fields were empty. Restore them if the browser sanitized a credential value.
        for (const [input] of changed) setter.call(input, '');
        return 'unsupported';
    }
    for (const [input] of changed) {
        input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    }
    return 'filled';
    """#
}
