import Foundation
import UIKit
import WebKit

/// Whether `host` is one of `domains` or a subdomain of one. A suffix is not a
/// domain: "notbank.example" and "bank.example.evil.example" do not match "bank.example".
func domainAllowed(_ host: String, _ domains: [String]) -> Bool {
    let h = (host.hasPrefix(".") ? String(host.dropFirst()) : host).lowercased()
    return domains.contains { allow in
        let a = (allow.hasPrefix(".") ? String(allow.dropFirst()) : allow).lowercased()
        return !a.isEmpty && (h == a || h.hasSuffix("." + a))
    }
}

/// Converts platform cookies to the SDK's wire form, keeping only the profile's
/// declared domains. Filtering here as well as in Rust is deliberate: the fewer
/// places a stray cookie exists, the fewer places it can leak from.
func cookieEntries(from cookies: [HTTPCookie], allowing domains: [String]) -> [String] {
    cookies.compactMap { c in
        let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
        return domainAllowed(d, domains) ? "\(d)\t\(c.name)=\(c.value)" : nil
    }
}

/// `scheme://host/path` of `url`, host lowercased.
private func pageKey(_ url: URL?) -> String? {
    guard let url, let scheme = url.scheme, let host = url.host?.lowercased() else { return nil }
    return "\(scheme)://\(host)\(url.path.isEmpty ? "/" : url.path)"
}

/// Completion rule, until the profile can declare a success signal: the WebView
/// is on a declared domain but not on the login page itself, and holds a cookie
/// that was not there after the first page load. Login pages set CSRF and
/// load-balancer cookies as they load, so "any cookie" would end the login
/// before the user typed anything.
func loginComplete(page: URL?, loginURL: String, domains: [String], baseline: Set<String>, current: Set<String>) -> Bool {
    guard let here = pageKey(page), let host = page?.host else { return false }
    return domainAllowed(host, domains) && here != pageKey(URL(string: loginURL))
        && !current.subtracting(baseline).isEmpty
}

/// A load superseded by a JavaScript or SSO redirect fails with "cancelled"
/// (-999) or "frame load interrupted" (102); neither ends the login.
func endsLogin(_ error: Error) -> Bool {
    let e = error as NSError
    if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return false }
    if e.domain == "WebKitErrorDomain" && e.code == 102 { return false }
    return true
}

private func cookieName(_ entry: String) -> String {
    let nameValue = entry.split(separator: "\t", maxSplits: 1).last ?? ""
    return String(nameValue.split(separator: "=", maxSplits: 1).first ?? "")
}

/// The default login presenter: a modal `WKWebView` on a non-persistent data
/// store of its own, new for every login. The login cannot read the host app's
/// cookies, and each login's cookies are gone with its page.
///
/// Cookies go from `WKHTTPCookieStore` into the Rust `CookieHandle` in one
/// call. No cookie value is stored in a property, written to disk, passed to
/// JavaScript, or logged. If the Task awaiting `presentLogin` is cancelled, the
/// disclosure or the page closes and no cookies are returned.
public final class WebViewLoginPresenter: NSObject, ZktlsLoginPresenter, WKNavigationDelegate,
    UIAdaptivePresentationControllerDelegate, @unchecked Sendable
{
    private let presenter: UIViewController
    private let disclosure: ([String]) -> LoginDisclosure
    private var answer: CheckedContinuation<Bool, Never>?
    private var continuation: CheckedContinuation<[String], Never>?
    private var shown: (view: UIViewController, from: UIViewController)?
    private var domains: [String] = []
    private var loginURL = ""
    private var baseline: Set<String>?
    private var webView: WKWebView?

    /// A presenter that shows `disclosure(cookieDomains)` first and the login page only on accept.
    public init(
        presentingFrom: UIViewController,
        disclosure: @escaping ([String]) -> LoginDisclosure = LoginDisclosure.standard(domains:)
    ) {
        self.presenter = presentingFrom
        self.disclosure = disclosure
        super.init()
    }

    /// Tests stand in for the dialog; nil is UIKit's alert.
    var ask: ((LoginDisclosure) async -> Bool)?
    /// The login page's data store, while the page is open.
    var dataStore: WKWebsiteDataStore? { webView?.configuration.websiteDataStore }

    /// Shows the disclosure, then the login page if the user accepts, and returns the cookies of
    /// `cookieDomains` once the login completes; no cookies if the user declines or closes the page.
    public func presentLogin(url: String, cookieDomains: [String]) async -> [String] {
        guard let target = URL(string: url) else { return [] }
        return await withTaskCancellationHandler {
            await gated(disclosure(cookieDomains), ask: { await (self.ask ?? self.showDisclosure)($0) }) {
                await self.openLogin(target, url, cookieDomains)
            }
        } onCancel: {
            Task { @MainActor in self.abort() }
        }
    }

    @MainActor
    private func showDisclosure(_ d: LoginDisclosure) async -> Bool {
        await withCheckedContinuation { cont in
            guard !Task.isCancelled else { return cont.resume(returning: false) }
            let alert = UIAlertController(title: d.title, message: d.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: d.decline, style: .cancel) { _ in self.answered(false) })
            alert.addAction(UIAlertAction(title: d.accept, style: .default) { _ in self.answered(true) })
            answer = cont
            show(alert)
        }
    }

    /// UIKit takes the alert down itself when the user taps.
    private func answered(_ accepted: Bool) {
        guard let cont = answer else { return }
        answer = nil
        shown = nil
        cont.resume(returning: accepted)
    }

    @MainActor
    private func openLogin(_ target: URL, _ url: String, _ cookieDomains: [String]) async -> [String] {
        await withCheckedContinuation { cont in
            guard !Task.isCancelled else { return cont.resume(returning: []) }
            domains = cookieDomains
            loginURL = url
            baseline = nil
            continuation = cont
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: cfg)
            web.navigationDelegate = self
            webView = web
            let page = UIViewController()
            page.view = web
            show(page)
            // A swipe-down ends the login as a cancel, not a hang.
            page.presentationController?.delegate = self
            web.load(URLRequest(url: target))
        }
    }

    /// Presents over whatever the app already shows: UIKit presents nothing from a view controller
    /// that is already presenting, and the login would wait forever.
    private func show(_ view: UIViewController) {
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        shown = (view, top)
        top.present(view, animated: true)
    }

    /// Takes down what `show` put up, if it is still up.
    private func hide() {
        guard let (view, from) = shown else { return }
        shown = nil
        if from.presentedViewController === view { from.dismiss(animated: true) }
    }

    /// The Task awaiting `presentLogin` was cancelled: close the disclosure or the page, with no cookies.
    private func abort() {
        if answer != nil {
            hide()
            answered(false)
        }
        finish([])
    }

    /// The first finished page sets the cookie baseline; the login completes
    /// by `loginComplete`. No "tap Done" button the user can press too early.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let page = webView.url
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, webView === self.webView else { return }
            let entries = cookieEntries(from: cookies, allowing: self.domains)
            let names = Set(entries.map(cookieName))
            guard let before = self.baseline else {
                self.baseline = names
                return
            }
            if loginComplete(page: page, loginURL: self.loginURL, domains: self.domains, baseline: before, current: names) {
                self.finish(entries)
            }
        }
    }

    /// A failed navigation ends the login, unless it was superseded by a redirect.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if endsLogin(error) { finish([]) }
    }

    /// Same as `webView(_:didFail:withError:)`, for a navigation that never committed.
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        if endsLogin(error) { finish([]) }
    }

    /// A swipe-down dismissal ends the login as a cancel.
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        shown = nil
        finish([])
    }

    /// Main thread only: every caller is a WebKit or UIKit callback, or `abort`.
    private func finish(_ entries: [String]) {
        guard let cont = continuation else { return }
        continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
        hide()
        cont.resume(returning: entries)
    }
}
