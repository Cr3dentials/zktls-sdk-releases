import Foundation
import UIKit
import WebKit
import os

/// What the user is told before `runTree` opens a platform's pages, and the two answers. The SDK ships
/// no wording for it yet: pass the text your review approved. Nothing opens until the user accepts.
public struct TreeDisclosure: Sendable {
    /// The dialog's title.
    public let title: String
    /// What the run reads and what leaves the device.
    public let message: String
    /// The button that starts the run.
    public let accept: String
    /// The button that ends it before anything is read.
    public let decline: String

    /// A disclosure with the given text.
    public init(title: String, message: String, accept: String, decline: String) {
        self.title = title
        self.message = message
        self.accept = accept
        self.decline = decline
    }
}

/// The bridge script, as the package ships it: the Swift package's resource bundle, or the pod's
/// `ZktlsSDK_Bridge` (CocoaPods has no `Bundle.module`).
func treeBridgeSource() -> String {
    #if SWIFT_PACKAGE
    let bundle: Bundle? = .module
    #else
    let bundle = Bundle(for: TreeWebViewHost.self).url(forResource: "ZktlsSDK_Bridge", withExtension: "bundle")
        .flatMap(Bundle.init(url:))
    #endif
    guard let url = bundle?.url(forResource: "bridge", withExtension: "js"),
          let source = try? String(contentsOf: url, encoding: .utf8)
    else { return "" }
    return source
}

/// The script injected at every document start: the bridge's configuration, then the bridge. A new
/// document gets the patterns in force, so a capture or a watch survives the page's navigations, and
/// the pack's domains, which a script's requests are held to.
func treeDocumentScript(bridge: String, neverRecord: [String], capture: String?, watch: String?, domains: [String]) -> String {
    var config: [String: Any] = ["never_record": neverRecord, "domains": domains]
    if let capture { config["capture"] = capture }
    if let watch { config["watch"] = watch }
    let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
    return "window.__zktlsConfig = \(String(decoding: data, as: UTF8.self));\n" + bridge
}

/// A bridge event as the host buffers it for `drainEvents`: its JSON, unless it is on a never_record
/// address, which the bridge does not record and the host drops if it ever arrives.
func treeEventJSON(_ event: Any, neverRecord: [String]) -> String? {
    guard let e = event as? [String: Any], let url = e["url"] as? String,
          JSONSerialization.isValidJSONObject(e),
          let data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])
    else { return nil }
    if neverRecord.contains(where: { url.contains($0) }) { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// A bridge request's id: 128 random bits, so the page cannot answer a request it was not sent.
func treeReplyId() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// The origin of a page at `url`, as the page's `location.origin` reads it.
func treeOrigin(_ url: String) -> String {
    guard let u = URLComponents(string: url), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return "" }
    let port = u.port.map { scheme == "https" && $0 == 443 ? "" : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
}

/// `call`, run only in a document of `origin`: the host checks the committed page on its own turn, but
/// an evaluation runs in whatever document the main frame holds when it arrives. Anywhere else it does nothing
/// and answers `[location.origin]`, which the page cannot forge.
func treeGuarded(_ call: String, origin: String) -> String {
    "(location.origin === \(jsLiteral(origin)) ? (\(call)) : [location.origin])"
}

/// The origin a guarded call found in place of the one checked, from its answer; nil when it ran.
func treeMoved(_ result: Any?) -> String? {
    (result as? [Any])?.first as? String
}

/// Of the cookies the store sends to `url`, the one set on `url`'s own path whose value starts with
/// `prefix`. Cookies with that prefix on a parent path, which a script may read, are not it.
func treeCookieValue(_ cookies: [HTTPCookie], url: String, prefix: String) -> String? {
    guard let target = URL(string: url), let host = target.host?.lowercased() else { return nil }
    func bare(_ p: String) -> String {
        var s = p
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    func domainMatches(_ domain: String) -> Bool {
        let d = domain.lowercased()
        guard d.hasPrefix(".") else { return host == d } // host-only
        return host == String(d.dropFirst()) || host.hasSuffix(d)
    }
    return cookies.first {
        domainMatches($0.domain) && bare($0.path) == bare(target.path) && (!$0.isSecure || target.scheme == "https")
            && $0.value.hasPrefix(prefix)
    }?.value
}

/// A JavaScript literal for `value`: JSON, so no string of the pack's can break out of its quotes.
func jsLiteral(_ value: Any) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]) {
        let s = String(decoding: data, as: UTF8.self)
        return String(s.dropFirst().dropLast())
    }
    return "null"
}

/// The browser `runTree` drives: a modal `WKWebView` on a non-persistent data store of its own, new for
/// every run, with the bridge injected at every document start. The pack's `ConfinementPolicy` decides
/// every navigation, popup, bridge message, script run and cookie read; a refusal ends the run.
///
/// Session values stay out of this class. The page applies them when it fetches; `cookies` and
/// `sessionMaterial` hand them to the Rust core in one call each, for the attested read, which seals
/// them at once. None is stored in a property, written to disk or logged.
public final class TreeWebViewHost: NSObject, TreeHost, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate,
    @unchecked Sendable
{
    /// Blocks every http load, so mixed content never loads.
    static let httpBlocked = #"[{"trigger":{"url-filter":"^http:"},"action":{"type":"block"}}]"#
    /// Denies geolocation in every frame: the page is told no, and no prompt shows.
    /// Its prototype too, which the getter on `Navigator.prototype` still reaches.
    static let noGeolocation = "(function(){var d=function(s,e){if(e)e({code:1,message:'denied',PERMISSION_DENIED:1});};var w=function(s,e){d(s,e);return 0;};try{Object.defineProperty(navigator,'geolocation',{value:{getCurrentPosition:d,watchPosition:w,clearWatch:function(){}},configurable:false});}catch(_){}try{var p=Geolocation.prototype;Object.defineProperty(p,'getCurrentPosition',{value:d,writable:false,configurable:false});Object.defineProperty(p,'watchPosition',{value:w,writable:false,configurable:false});}catch(_){}})();"

    private let presenter: UIViewController
    private let disclosure: TreeDisclosure
    private let bridge: String
    private(set) var webView: WKWebView?
    private var shown: (view: UIViewController, from: UIViewController)?
    private var policy: ConfinementPolicy?
    private var neverRecord: [String] = []
    private var domains: [String] = []
    private var capture: String?
    private var watch: String?
    private var events: [String] = []
    private var replies: [String: CheckedContinuation<[String: Any], Never>] = [:]
    private var loading: CheckedContinuation<Error?, Never>?
    /// Whether the load in flight's own navigation has committed. Another navigation's commit, such as a reload
    /// the page starts while the load is pending, is not the load's.
    private var committed = false
    /// The navigation the load in flight opened, and what it opens (nil: a reload). WebKit keeps one navigation
    /// across a reply's redirects. Nil when WebKit gave none: then any commit is the load's, as before.
    private var ours: WKNavigation?
    private var pending: URLRequest?
    /// The page cancelled the load in flight before it committed (a reload or a navigation of its own), and
    /// whether the load was opened once more because of it.
    private var superseded = false
    private var reopened = false
    /// Why the run ended, once the page went where the policy refuses: every host call then fails with it.
    private var refusal: String?
    /// Once the page closed (Close, a swipe down, `finish`), every host call fails with `pageClosed`.
    private var closed = false
    /// What every host call throws once the run's page is closed: the core ends the run on it, as Cancelled.
    static let pageClosed = "the page closed"
    /// Bridge messages dropped this run: from another origin or frame, of no known kind, or answering no
    /// pending request.
    private(set) var dropped = 0
    /// The main frame's URL as of its last commit, and of the page's moves within that document since.
    /// The bar above the page follows it.
    private(set) var committedUrl = "" { didSet { showHost() } }
    /// The page under its host bar, while the run is open.
    private var page: TreePageController?
    private var urlWatch: NSKeyValueObservation?
    /// The URL of the main-frame reply WebKit is about to commit, when it asked about one.
    private var responseUrl: String?
    /// Blank popups not yet decided: hidden, never shown; each goes once its first navigation is decided, or at close.
    private var probes: [WKWebView] = []
    private lazy var probeNavigation = ProbeNavigation(self)
    private let probeUI = ProbeUI()
    /// Blank popups released so far.
    private(set) var probesReleased = 0
    /// How many times the host read its cookie store.
    private(set) var cookieReads = 0
    private static let maxEvents = 1000

    /// Tests stand in for the dialog; nil is UIKit's alert.
    var ask: ((TreeDisclosure) async -> Bool)?
    /// Opens a request in the WebView; tests load local pages in its place.
    var open: @MainActor (WKWebView, URLRequest) -> WKNavigation? = { $0.load($1) }
    /// Test hook: sees each script just before it is evaluated in the page, before the origin guard wraps it.
    var onEvaluate: @MainActor (String) -> Void = { _ in }
    /// Evaluates a script in the WebView; tests evaluate it in another document in its place.
    var evaluateIn: @MainActor (WKWebView, String, @escaping @MainActor @Sendable (Any?, Error?) -> Void) -> Void = {
        $0.evaluateJavaScript($1, completionHandler: $2)
    }

    /// A host that shows `disclosure` first and the platform's pages only on accept.
    public init(presentingFrom: UIViewController, disclosure: TreeDisclosure) {
        self.presenter = presentingFrom
        self.disclosure = disclosure
        self.bridge = treeBridgeSource()
        super.init()
    }

    // MARK: TreeHost

    /// Presents the WebView on the pack's login page, the bridge injected at every document start.
    /// Answers "ephemeral": the run's data store is its own, and goes with it.
    public func begin(loginUrl: String, neverRecord: [String], policy: ConfinementPolicy) async throws -> String {
        let domains = policy.bridgeDomains()
        guard let target = URL(string: loginUrl), !bridge.isEmpty else { throw failed("the bridge did not load") }
        let accepted = await (ask ?? showDisclosure)(disclosure)
        guard accepted else { throw failed("the user declined") }
        guard let noHttp = await Self.noHttp() else { throw failed("the http block did not compile") }
        try await onMain {
            // A new run: the last one's refusal or close, if any, ended with it.
            self.refusal = nil
            self.closed = false
            self.dropped = 0
            self.committedUrl = ""
            self.responseUrl = nil
            self.policy = policy
            self.neverRecord = neverRecord
            self.domains = domains
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .nonPersistent()
            cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
            cfg.preferences.isFraudulentWebsiteWarningEnabled = true
            cfg.userContentController.add(noHttp)
            cfg.userContentController.add(WeakMessages(self), name: "zktls")
            let web = WKWebView(frame: .zero, configuration: cfg)
            // Safari's Web Inspector for the app's debug builds only.
            #if DEBUG
            if #available(iOS 16.4, *) { web.isInspectable = true }
            #endif
            web.navigationDelegate = self
            web.uiDelegate = self
            web.allowsLinkPreview = false // a preview loads the link outside the policy
            // The page's moves within its document (pushState, a fragment): with no load in flight,
            // WebKit's URL is the committed document's.
            self.urlWatch = web.observe(\.url) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.followSameDocument(web) }
            }
            self.webView = web
            self.installScripts()
            let page = TreePageController(web: web) { [weak self] in self?.close() }
            self.page = page
            self.show(page)
            page.presentationController?.delegate = self
        }
        try await load(URLRequest(url: target), timeoutMs: 30_000)
        return "ephemeral"
    }

    /// Loads `url` and waits for it, at most `timeoutMs`.
    public func navigate(url: String, timeoutMs: UInt64) async throws {
        try await checkRefused()
        guard let target = URL(string: url) else { throw failed("not a URL") }
        try await load(URLRequest(url: target), timeoutMs: timeoutMs)
    }

    /// Reloads the page.
    public func refresh() async throws {
        try await checkRefused()
        try await load(nil, timeoutMs: 30_000)
    }

    /// The main frame's URL as it last committed, the page's moves within the document included.
    public func currentUrl() async throws -> String {
        try await checkRefused()
        return await MainActor.run { self.committedUrl }
    }

    /// Whether the WebView's cookie store holds the cookie; its value is compared, never returned.
    public func cookiePresent(domain: String, name: String, value: String?) async throws -> Bool {
        try await checkRefused()
        let cookies = try await allCookies()
        return cookies.contains { c in
            domainAllowed(c.domain, [domain]) && c.name == name && (value == nil || c.value == value)
        }
    }

    /// Whether the page stores `key`; its value is compared, never returned.
    public func localStoragePresent(url: String?, key: String, value: String?) async throws -> Bool {
        try await checkRefused()
        if let url, let want = URL(string: url.replacingOccurrences(of: "*", with: "")) {
            let here = await MainActor.run { URL(string: self.committedUrl) }
            guard here?.scheme == want.scheme, here?.host?.lowercased() == want.host?.lowercased() else { return false }
        }
        let script = "window.__zktlsBridge ? __zktlsBridge.storagePresent(\(jsLiteral(key)), \(jsLiteral(value ?? NSNull()))) : false"
        return (try await evaluate(script) as? Bool) ?? false
    }

    /// Whether `selector` matches an element on the page.
    public func elementPresent(selector: String) async throws -> Bool {
        try await checkRefused()
        let script = "window.__zktlsBridge ? __zktlsBridge.elementPresent(\(jsLiteral(selector))) : false"
        do {
            return try await evaluate(script) as? Bool ?? false
        } catch {
            try await checkRefused() // a refusal or the close, not the page's own failure
            return false
        }
    }

    /// A request the page makes with the site's own cookies, through the bridge.
    public func pageFetch(request: TreeFetchRequest) async throws -> TreeFetchResponse {
        try await checkRefused()
        var r: [String: Any] = [
            "url": request.url, "method": request.method,
            "headers": request.headers.map { [$0.name, $0.value] },
            "timeout_ms": request.timeoutMs, "max_body_bytes": request.maxBodyBytes,
        ]
        if let body = request.body { r["body"] = body }
        if let bearer = request.bearerCookie { r["bearer_cookie"] = bearer }
        if let key = request.storageKey, let header = request.storageHeader {
            r["storage_header"] = ["key": key, "header": header]
        }
        if let pattern = request.capturedPattern {
            r["from_captured"] = ["url_pattern": pattern, "headers": request.capturedHeaders]
        }
        let answer = await ask(bridgeMethod: "pageFetch", argument: r, timeoutMs: request.timeoutMs + 5_000)
        try await checkRefused()
        return TreeFetchResponse(
            status: UInt16(clamping: (answer["status"] as? Int) ?? 0),
            finalUrl: answer["final_url"] as? String ?? "",
            body: answer["body"] as? String ?? "",
            retryAfter: answer["retry_after"] as? String,
            error: answer["error"] as? String,
            fatal: answer["fatal"] as? String
        )
    }

    /// Starts recording the header names of the page's requests to `urlPattern`.
    public func startHeaderCapture(urlPattern: String) async throws {
        try await setPattern(capture: .some(urlPattern), watch: nil, call: "startCapture(\(jsLiteral(urlPattern)))")
    }

    /// Stops recording request headers.
    public func stopHeaderCapture() async throws {
        try await setPattern(capture: .some(nil), watch: nil, call: "stopCapture()")
    }

    /// Starts reading the page's own replies on `urlPattern`.
    public func watchResponses(urlPattern: String) async throws {
        try await setPattern(capture: nil, watch: .some(urlPattern), call: "startWatch(\(jsLiteral(urlPattern)))")
    }

    /// Stops reading the page's replies.
    public func stopWatching() async throws {
        try await setPattern(capture: nil, watch: .some(nil), call: "stopWatch()")
    }

    /// Every event the bridge recorded since the last drain, as its JSON.
    public func drainEvents() async throws -> String {
        return try await MainActor.run {
            try self.throwIfRefused()
            let batch = "[" + self.events.joined(separator: ",") + "]"
            self.events = []
            return batch
        }
    }

    /// The cookies of `domains`, for the attested read; the SDK seals them at once.
    public func cookies(domains: [String]) async throws -> [String] {
        try await checkRefused()
        return cookieEntries(from: try await allCookies(), allowing: domains)
    }

    /// The session material one collect declares, for the attested read; the SDK seals it at once.
    public func sessionMaterial(request: TreeSessionRequest) async throws -> [String] {
        try await checkRefused()
        var s: [String: Any] = [:]
        if let bearer = request.bearerCookie { s["bearer_cookie"] = bearer }
        if let key = request.storageKey, let header = request.storageHeader {
            s["storage_header"] = ["key": key, "header": header]
        }
        if let pattern = request.capturedPattern {
            s["from_captured"] = ["url_pattern": pattern, "headers": request.capturedHeaders]
        }
        let answer = await ask(bridgeMethod: "sessionMaterial", argument: s, timeoutMs: 10_000)
        try await checkRefused()
        if answer["kind"] == nil { throw failed(answer["error"] as? String ?? "no answer from the page") }
        if let missing = answer["missing"] as? [String], !missing.isEmpty {
            throw failed("the page holds no \(missing.joined(separator: ", "))")
        }
        let pairs = answer["headers"] as? [[String]] ?? []
        return pairs.compactMap { $0.count == 2 ? "\($0[0])\t\($0[1])" : nil }
    }

    /// Runs a function of the pack's script: loads the script into this document once, then calls the
    /// function through the bridge and returns the bridge's answer as its JSON.
    public func runScript(request: TreeScriptRequest) async throws -> String {
        try await checkRefused()
        // The load carries the run's token: it goes only into the pack's own pages.
        let loaded = try await evaluate(checking: [.script], request.load)
        try await checkRefused()
        // The page's words are marked as its own, so they never read as the host's refusal.
        guard let reason = loaded as? String else { throw failed("the script did not load") }
        guard reason.isEmpty else { throw failed("the page: \(reason)") }
        guard let argument = try? JSONSerialization.jsonObject(with: Data(request.argument.utf8)) as? [String: Any] else {
            throw failed("the script's argument is not an object")
        }
        // The node's cookies, HttpOnly ones too, go to the bridge with the call and never to the core.
        let answer = await ask(
            bridgeMethod: "runScript", argument: argument, timeoutMs: request.timeoutMs, cookies: request.cookies, also: [.script])
        try await checkRefused()
        guard JSONSerialization.isValidJSONObject(answer), let data = try? JSONSerialization.data(withJSONObject: answer) else {
            throw failed("the script's answer is not JSON")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Closes the WebView. Called once, whatever the run's result.
    public func finish() async {
        await MainActor.run { self.close() }
    }

    // MARK: Bridge messages

    /// The bridge's channel, as `WeakMessages` hands it over. The policy hears only the main frame on the
    /// pack's own pages; anything else, a message of no known kind and a reply to no pending request are
    /// dropped and counted.
    @MainActor func received(body: Any, origin: String, isMainFrame: Bool, from view: WKWebView?) {
        // Only the run's own WebView: a blank popup shares the channel and its opener's origin.
        guard view != nil, view === webView,
              policy?.decide(url: origin, frame: isMainFrame ? .mainFrame : .subframe, action: .bridge).allowed == true,
              let body = body as? [String: Any], let kind = body["kind"] as? String
        else {
            dropped += 1
            return
        }
        switch kind {
        case "event":
            if events.count < Self.maxEvents, let e = body["event"], let json = treeEventJSON(e, neverRecord: neverRecord) {
                events.append(json)
            }
        case "fetch", "session_material", "script":
            guard let id = body["id"] as? String, let cont = replies.removeValue(forKey: id) else {
                dropped += 1
                return
            }
            cont.resume(returning: body)
        default:
            dropped += 1
        }
    }

    // MARK: Confinement

    /// On the main actor: ends the run with `d`'s refusal, failing every call waiting on the page and the
    /// load in flight. The first refusal stands.
    @MainActor private func refuse(_ d: ConfinementDecision) {
        guard refusal == nil else { return }
        let reason = "\(d.reason): \(d.host)"
        refusal = reason
        for (_, cont) in replies { cont.resume(returning: ["status": 0, "error": reason]) }
        replies = [:]
        loaded(failed(reason))
    }

    @MainActor private func throwIfRefused() throws {
        if let refusal { throw failed(refusal) }
        if closed { throw failed(Self.pageClosed) }
    }

    /// Every host call but `begin` and `finish` starts here: once the run is refused, it fails with the refusal,
    /// and once the page closed, with `pageClosed`.
    private func checkRefused() async throws {
        try await MainActor.run { try self.throwIfRefused() }
    }

    /// On the main actor: refuses `actions` unless the main frame is on the pack's own pages, both as it last
    /// committed and as WebKit shows it (a load the app starts shows its URL before it commits). Answers the
    /// committed URL.
    @MainActor private func onPlatformPage(_ actions: [ConfinementAction]) throws -> String {
        guard let policy, let web = webView else { throw failed(Self.pageClosed) }
        for action in actions {
            for url in [committedUrl, web.url?.absoluteString ?? ""] {
                let d = policy.decide(url: url, frame: .mainFrame, action: action)
                if !d.allowed { refuse(d) }
            }
        }
        try throwIfRefused()
        return committedUrl
    }

    /// The committed main frame's host on the bar, never its path, and nothing for a page the policy refuses.
    @MainActor private func showHost() {
        guard let policy else { return }
        let shown = policy.decide(url: committedUrl, frame: .mainFrame, action: .navigate).allowed
        page?.bar.show(shown ? policy.displayHost(url: committedUrl) : "")
    }

    @MainActor private func followSameDocument(_ web: WKWebView) {
        if web === webView, !web.isLoading { committedUrl = web.url?.absoluteString ?? "" }
    }

    /// The content rule that blocks every http load; nil if WebKit cannot compile it.
    @MainActor static func noHttp() async -> WKContentRuleList? {
        await withCheckedContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "zktls-no-http", encodedContentRuleList: httpBlocked
            ) { list, _ in c.resume(returning: list) }
        }
    }

    // MARK: Plumbing

    private func failed(_ reason: String) -> TreeHostError { .Failed(reason: reason) }

    private func onMain(_ body: @escaping @MainActor () throws -> Void) async throws {
        try await MainActor.run { try body() }
    }

    @MainActor
    private func installScripts() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Self.noGeolocation, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let source = treeDocumentScript(bridge: bridge, neverRecord: neverRecord, capture: capture, watch: watch, domains: domains)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// `capture` and `watch` are double optionals: nil leaves a pattern as it is, `.some(nil)` clears it.
    private func setPattern(capture: String??, watch: String??, call: String) async throws {
        try await checkRefused()
        await MainActor.run {
            if let capture { self.capture = capture }
            if let watch { self.watch = watch }
            self.installScripts()
        }
        _ = try await evaluate("window.__zktlsBridge && __zktlsBridge.\(call)")
    }

    /// Evaluates `script` in the page. With `actions`, only while the policy allows them on the main frame,
    /// asked on the main-actor turn that sends it, and only in a document of the origin asked about.
    private func evaluate(checking actions: [ConfinementAction] = [], _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                do {
                    guard let web = self.webView else { throw self.failed(Self.pageClosed) }
                    let here = actions.isEmpty ? self.committedUrl : try self.onPlatformPage(actions)
                    self.onEvaluate(script)
                    let sent = actions.isEmpty ? script : treeGuarded(script, origin: treeOrigin(here))
                    self.evaluateIn(web, sent) { result, error in
                        if let error { return cont.resume(throwing: self.failed(error.localizedDescription)) }
                        if !actions.isEmpty, let origin = treeMoved(result) {
                            return cont.resume(throwing: self.failed(self.moved(to: origin, from: here, actions)))
                        }
                        cont.resume(returning: result)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Calls a bridge method that answers on the channel, and waits for its answer. It goes only to the pack's
    /// own pages (as `also` too: a script's call carries its token), asked before the cookie store is read and
    /// again on the main-actor turn it is sent; `cookies`,
    /// the node's, join `argument` on that turn, HttpOnly ones too: they go to the bridge, never to the core.
    /// A call not sent answers with the refusal, which the caller then throws.
    private func ask(
        bridgeMethod: String, argument: [String: Any], timeoutMs: UInt64, cookies: [TreeScriptCookie] = [],
        also: [ConfinementAction] = []
    ) async -> [String: Any] {
        let id = treeReplyId()
        let timeout = Task {
            try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await MainActor.run { self.replies.removeValue(forKey: id)?.resume(returning: ["status": 0, "error": "no answer from the page"]) }
        }
        defer { timeout.cancel() }
        let actions: [ConfinementAction] = [.bridge] + also + (cookies.isEmpty ? [] : [.cookie])
        // Every path resumes once: the bridge's answer, the timeout, a refusal, a failed call, or the page closing.
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                guard let here = try? self.onPlatformPage(actions) else { return cont.resume(returning: self.unsent()) }
                let wanted = cookies.contains { self.policy?.displayHost(url: $0.url) == self.policy?.displayHost(url: here) }
                self.readCookies(wanted) { store in
                    guard let web = self.webView, let here = try? self.onPlatformPage(actions) else {
                        return cont.resume(returning: self.unsent())
                    }
                    var argument = argument
                    if !cookies.isEmpty { argument["cookies"] = self.cookieArgument(cookies, store: store, here: here) }
                    self.replies[id] = cont
                    let script = "__zktlsBridge.\(bridgeMethod)(\(jsLiteral(id)), \(jsLiteral(argument)))"
                    self.onEvaluate(script)
                    self.evaluateIn(web, treeGuarded(script, origin: treeOrigin(here))) { result, error in
                        if let origin = treeMoved(result) {
                            let why = self.moved(to: origin, from: here, actions)
                            self.replies.removeValue(forKey: id)?.resume(returning: ["status": 0, "error": why])
                        } else if let error, let pending = self.replies.removeValue(forKey: id) {
                            pending.resume(returning: ["status": 0, "error": "the page: \(error.localizedDescription)"])
                        }
                    }
                }
            }
        }
    }

    /// A guarded call found the document of `origin` where the checked page `here` was: nothing was delivered.
    /// Where the policy refuses `actions` there, the run ends, naming that page's host (the checked page's
    /// when it has none); on another of the pack's own pages the call is lost, as when the page navigates.
    /// Answers why.
    @MainActor private func moved(to origin: String, from here: String, _ actions: [ConfinementAction]) -> String {
        guard let policy else { return refusal ?? Self.pageClosed }
        for action in actions {
            var d = policy.decide(url: origin + "/", frame: .mainFrame, action: action)
            if d.host.isEmpty { d.host = policy.displayHost(url: here) }
            if !d.allowed { refuse(d) }
        }
        return refusal ?? "the page navigated"
    }

    /// What a bridge call the host did not send answers: the run's refusal, or the page having closed.
    @MainActor private func unsent() -> [String: Any] {
        ["status": 0, "error": refusal ?? Self.pageClosed]
    }

    /// The node's cookies as the bridge takes them: a value only for a cookie on the host the main frame is on.
    @MainActor private func cookieArgument(_ cookies: [TreeScriptCookie], store: [HTTPCookie], here: String) -> [[String: Any]] {
        cookies.map { c in
            let own = policy?.displayHost(url: c.url) == policy?.displayHost(url: here)
            let value = own ? treeCookieValue(store, url: c.url, prefix: c.valuePrefix) : nil
            return ["url": c.url, "value_prefix": c.valuePrefix, "value": value ?? NSNull()]
        }
    }

    /// The cookie store's cookies to `body`, on a main-actor turn of their own; none, at once, unless `wanted`.
    @MainActor private func readCookies(_ wanted: Bool, _ body: @escaping @MainActor @Sendable ([HTTPCookie]) -> Void) {
        guard wanted, let web = webView else { return body([]) }
        cookieReads += 1
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies(body)
    }

    private func allCookies() async throws -> [HTTPCookie] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                guard self.webView != nil else { return cont.resume(throwing: self.failed(Self.pageClosed)) }
                self.readCookies(true) { cont.resume(returning: $0) }
            }
        }
    }

    /// Loads `request` (a reload when nil) and waits for the page, at most `timeoutMs`.
    private func load(_ request: URLRequest?, timeoutMs: UInt64) async throws {
        let timeout = Task {
            try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await MainActor.run { self.loaded(self.failed("the page did not load in \(timeoutMs) ms")) }
        }
        defer { timeout.cancel() }
        let error: Error? = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                guard let web = self.webView else { return cont.resume(returning: self.failed(Self.pageClosed)) }
                self.loading?.resume(returning: self.failed("superseded by another load"))
                self.loading = cont
                self.committed = false
                self.superseded = false
                self.reopened = false
                self.pending = request
                self.ours = self.start(web, request)
            }
        }
        if let error { throw error }
    }

    private func start(_ web: WKWebView, _ request: URLRequest?) -> WKNavigation? {
        if let request { return open(web, request) }
        return web.reload()
    }

    /// The page took the load's place before it committed and has finished loading: the load is opened once
    /// more. A second time, the load fails rather than end on a page it did not open.
    private func reopen(_ web: WKWebView) {
        guard !reopened else {
            return loaded(failed("the page went elsewhere before \(pending?.url?.absoluteString ?? "the reload") loaded"))
        }
        reopened = true
        superseded = false
        os_log("tree navigate: the page took the load's place before it committed; opening it once more")
        ours = start(web, pending)
    }

    private func loaded(_ error: Error?) {
        loading?.resume(returning: error)
        loading = nil
    }

    @MainActor
    private func showDisclosure(_ d: TreeDisclosure) async -> Bool {
        await withCheckedContinuation { cont in
            let alert = UIAlertController(title: d.title, message: d.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: d.decline, style: .cancel) { _ in self.shown = nil; cont.resume(returning: false) })
            alert.addAction(UIAlertAction(title: d.accept, style: .default) { _ in self.shown = nil; cont.resume(returning: true) })
            show(alert)
        }
    }

    /// Presents over whatever the app already shows, as the login presenter does.
    private func show(_ view: UIViewController) {
        var top = presenter
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        shown = (view, top)
        top.present(view, animated: true)
    }

    private func close() {
        closed = true
        if webView != nil { os_log("tree run closed; dropped bridge messages: %ld", dropped) }
        urlWatch = nil
        probes.forEach(release)
        probes = []
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zktls")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        events = []
        loaded(failed(Self.pageClosed))
        for (_, cont) in replies { cont.resume(returning: ["status": 0, "error": Self.pageClosed]) }
        replies = [:]
        if let (view, from) = shown, from.presentedViewController === view { from.dismiss(animated: true) }
        shown = nil
        page = nil
    }

    // MARK: WKNavigationDelegate

    /// Every navigation the page or the host starts, redirects included, before it is made. One the policy
    /// refuses is cancelled; in the main frame it ends the run. A navigation to a new window is decided as a
    /// popup.
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // A download link: nothing starts, and the page goes on, as Android's download listener.
        if #available(iOS 14.5, *), navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard let policy else { return decisionHandler(.cancel) }
        let url = navigationAction.request.url?.absoluteString ?? ""
        // A blank new window: decided at its first navigation (createWebViewWith).
        if navigationAction.targetFrame == nil, isBlank(url) { return decisionHandler(.allow) }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        let d = policy.decide(
            url: url, frame: main ? .mainFrame : .subframe,
            action: navigationAction.targetFrame == nil ? .popup : .navigate)
        if d.allowed { return decisionHandler(.allow) }
        if main { refuse(d) }
        decisionHandler(.cancel)
    }

    /// No downloads: a reply WebKit cannot show is not loaded.
    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame {
            responseUrl = navigationResponse.canShowMIMEType ? navigationResponse.response.url?.absoluteString : nil
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// A new document: its URL is what the checks read, the reply's own where WebKit asked about one (a
    /// page from the back/forward cache comes without). Only a finish after one ends the load: a late
    /// finish of the page being replaced is not the load's own. A commit the policy refuses ends the run,
    /// though every main-frame navigation was decided before it started.
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if ours == nil || navigation === ours { committed = true }
        committedUrl = responseUrl ?? webView.url?.absoluteString ?? ""
        responseUrl = nil
        if let d = policy?.decide(url: committedUrl, frame: .mainFrame, action: .navigate), !d.allowed {
            webView.stopLoading()
            refuse(d)
        }
    }

    /// The page finished loading.
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        followSameDocument(webView) // moves the page made while it loaded
        if committed {
            loaded(nil)
        } else if superseded, loading != nil {
            reopen(webView)
        }
    }

    /// A new document: the old one's bridge will answer nothing more, so every call still waiting on it
    /// fails now rather than at its timeout.
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        responseUrl = nil // the last load's, which may never have committed
        for (_, cont) in replies { cont.resume(returning: ["status": 0, "error": "the page navigated"]) }
        replies = [:]
    }

    /// The page failed to load.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if endsLogin(error) { loaded(failed(error.localizedDescription)) }
    }

    /// The page failed before it started loading.
    public func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        responseUrl = nil
        let e = error as NSError
        if let ours, navigation === ours, !committed, e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled {
            superseded = true
        }
        if endsLogin(error) { loaded(failed(error.localizedDescription)) }
    }

    // MARK: WKUIDelegate

    /// window.open, target=_blank and OAuth popups never open a second WebView: one the policy allows loads
    /// in this one, any other ends the run. A window opened blank, which a sign-in script sends somewhere
    /// later, gets a hidden probe that is never shown: its first navigation is decided the same way. Either
    /// way only the URL loads, as a GET, as on Android: a popup's form post (a third-party iframe's
    /// `target=_blank` form, say) is never replayed as the app's own POST with the platform's cookies.
    public func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let policy else { return nil }
        if isBlank(navigationAction.request.url?.absoluteString ?? "") {
            let probe = WKWebView(frame: .zero, configuration: configuration) // WebKit requires its configuration
            probe.navigationDelegate = probeNavigation
            probe.uiDelegate = probeUI
            probes.append(probe)
            return probe
        }
        popup(to: navigationAction.request.url, from: webView)
        return nil
    }

    /// A popup going to `url`: allowed, its URL loads in place in `web` as a GET; refused, the run ends.
    @MainActor private func popup(to url: URL?, from web: WKWebView?) {
        guard let policy else { return }
        let d = policy.decide(url: url?.absoluteString ?? "", frame: .mainFrame, action: .popup)
        if !d.allowed { return refuse(d) }
        if let url, let web { _ = open(web, URLRequest(url: url)) }
    }

    /// Where a blank popup went first: allowed, it loads in place in the run's WebView; refused, the run
    /// ends. Either way the probe goes, once.
    @MainActor fileprivate func probeNavigated(_ probe: WKWebView, to url: URL?) {
        guard let i = probes.firstIndex(where: { $0 === probe }) else { return }
        probes.remove(at: i)
        popup(to: url, from: webView)
        DispatchQueue.main.async { self.release(probe) } // not from inside its own callback
    }

    @MainActor private func release(_ probe: WKWebView) {
        probe.navigationDelegate = nil
        probe.uiDelegate = nil
        probe.stopLoading()
        probesReleased += 1
    }

    /// No camera or microphone.
    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    /// No motion or orientation.
    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    /// A swipe-down closes the run, as the bar's close does: every call still waiting fails.
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        shown = nil
        close()
    }
}

/// The empty page a new window opens on, before a script sends it somewhere.
private func isBlank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" }

/// A blank popup's navigations: the blank page itself loads; its first other main-frame navigation is
/// cancelled and decided by the host. The subresources of a document the opener writes into the blank
/// page do load (an image, a script, a fetch), as they would in the opener; no other document does, in
/// the main frame or an iframe.
private final class ProbeNavigation: NSObject, WKNavigationDelegate {
    weak var host: TreeWebViewHost?
    init(_ host: TreeWebViewHost) { self.host = host }
    func webView(
        _ probe: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if isBlank(navigationAction.request.url?.absoluteString ?? "") { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if navigationAction.targetFrame?.isMainFrame != false { host?.probeNavigated(probe, to: navigationAction.request.url) }
    }
}

/// A blank popup's prompts: every one refused. Not the host's own delegate, whose createWebViewWith would load
/// in place into the probe: a window the probe opens is not created, and the camera, microphone and motion are
/// denied. It shows no JavaScript panel (alert, confirm, prompt), as the host's own shows none: WebKit answers
/// them at once when the delegate does not.
private final class ProbeUI: NSObject, WKUIDelegate {
    func webView(
        _ probe: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    @available(iOS 15.0, *)
    func webView(
        _ probe: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    @available(iOS 15.0, *)
    func webView(
        _ probe: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

/// `WKUserContentController` holds its handlers strongly; this holds the host weakly, so closing the run
/// frees it.
private final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var host: TreeWebViewHost?
    init(_ host: TreeWebViewHost) { self.host = host }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let o = message.frameInfo.securityOrigin
        let origin = "\(o.protocol)://\(o.host)" + (o.port != 0 ? ":\(o.port)" : "")
        host?.received(body: message.body, origin: origin, isMainFrame: message.frameInfo.isMainFrame, from: message.webView)
    }
}
