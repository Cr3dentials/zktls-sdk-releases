import Foundation

/// The host's login WebView. `WebViewLoginPresenter` is the default; a partner
/// may supply their own if they need their own chrome.
public protocol ZktlsLoginPresenter {
    /// Presents `url`, waits for the user to authenticate, and returns
    /// `"<domain>\t<name>=<value>"` entries for `cookieDomains`.
    func presentLogin(url: String, cookieDomains: [String]) async -> [String]
}

/// The partner-facing API: seven verbs over one Rust core.
///
/// An actor, so a session's state cannot be raced from two threads — the Rust
/// core is thread-safe but the flow is not: capture must precede prove, and a
/// witness proves once.
public actor ZktlsClient {
    private let config: SessionConfig?
    private let session: Session
    private let cookies = Locked<CookieHandle?>(nil)
    private var witness: WitnessHandle?
    private var report: ProofReport?

    /// A client for one flow: create one per session the user starts.
    public init(config: SessionConfig) {
        // Allocate and the RTT probe go through the platform's HTTP stack, so they follow the system's
        // proxy and VPN settings; the first client installs it for the process.
        setPlatformHttp(http: URLSessionPlatformHttp.shared)
        self.config = config
        self.session = Session()
    }

    /// A client for `runTree`, whose configuration comes with each run. Its `login`, `capture` and `claim`
    /// refuse: they need a `SessionConfig`.
    public init() {
        setPlatformHttp(http: URLSessionPlatformHttp.shared)
        self.config = nil
        self.session = Session()
    }

    /// This client's `SessionConfig`, which the proof flow's verbs need.
    private func sessionConfig() throws -> SessionConfig {
        guard let config else { throw SdkError.Policy("this client has no SessionConfig: create it with one to log in, capture and claim") }
        return config
    }

    /// Whether `cancel()` has been called on this client's session.
    public var isCancelled: Bool { session.isCancelled() }

    /// This client's lifecycle handle: build `ZkTlsLifecycle` on it after `login`.
    public nonisolated var lifecycleHandle: LifecycleHandle { session.lifecycle() }

    /// This session's field telemetry, a JSON array: the device lab's reading (`telemetry.rs`).
    nonisolated var telemetryJson: String { zktlsTelemetryJson(session: session) }

    /// The device lab's switch for protocol version 2 (implementation plan X1): each `capture()` prepares
    /// the proof's session while it runs. Off by default, as on Android, until the lab's last gate.
    nonisolated func prepareDuringCapture(_ on: Bool) { zktlsPrepareDuringCapture(session: session, on: on) }

    /// Shows the disclosure, then the profile's login page, and keeps the resulting cookies for `capture()`.
    @discardableResult
    public func login(host: ZktlsLoginPresenter) async throws -> CookieHandle {
        let config = try sessionConfig()
        let handle = try await cancellable {
            try await ZktlsSDK.login(cfg: config, host: PresenterBridge(host), session: session)
        }
        cookies.value = handle
        // Stored, then checked: a cancel that lands as the login returns must not leave them here.
        if session.isCancelled() {
            cookies.value = nil
            throw SdkError.Cancelled
        }
        return handle
    }

    /// Fetches the record through the allocated cell, using the cookies `login` returned. The client
    /// lets go of them when the capture ends, unless it ends with `SdkError.SessionLost`: then
    /// `capture()` may run again with the same login.
    @discardableResult
    public func capture() async throws -> WitnessHandle {
        let config = try sessionConfig()
        guard let c = cookies.value else {
            throw session.isCancelled() ? SdkError.Cancelled : SdkError.NotLoggedIn
        }
        do {
            let handle = try await cancellable {
                try await ZktlsSDK.capture(cfg: config, cookies: c, session: session)
            }
            cookies.value = nil
            witness = handle
            return handle
        } catch {
            if error as? SdkError != .SessionLost { cookies.value = nil }
            throw error
        }
    }

    /// Proves the policy's statement about the captured record to the verifier of the cell the capture
    /// ran in, consuming the witness.
    @discardableResult
    public func prove() async throws -> ProofReport {
        guard let witness else { throw SdkError.SessionLost }
        // The handle is spent by the call; dropping our reference lets Rust free it.
        self.witness = nil
        let r = try await cancellable {
            try await ZktlsSDK.prove(witness: witness, session: session)
        }
        report = r
        return r
    }

    /// Returns the signed claim from `prove`, verified against the trust bundle.
    public func claim() async throws -> Claim {
        let config = try sessionConfig()
        guard let report else { throw SdkError.SessionLost }
        return try await cancellable { try await ZktlsSDK.claim(cfg: config, report: report, session: session) }
    }

    /// Runs a pack's tree in `host`'s WebView (`TreeWebViewHost` is the default): the user signs in and
    /// the tree collects in the page. For a pack that attests, the SDK then uploads the session once to
    /// the attester and returns when it accepts it (`Detached`, `handedOff`): the app may close, and the
    /// attester reads the endpoint, signs the claim and posts the result. Returns a summary; the data
    /// goes to your backend, never to the app.
    public func runTree(config: TreeRunConfig, host: TreeHost) async throws -> TreeSummary {
        try await cancellable { try await ZktlsSDK.runTree(cfg: config, host: host, session: session) }
    }

    /// Registers a callback that receives every phase change of this client's session.
    public func onProgress(_ body: @escaping @Sendable (Phase, UInt8) -> Void) {
        ZktlsSDK.progress(session: session, sink: CallbackSink(body))
    }

    /// Cancels this client's session and lets go of its cookies: the verb in flight, `login` included,
    /// fails with `SdkError.Cancelled`. Cancelling the Task that awaits a verb does the same.
    /// Synchronous, so a background-expiry handler can call it before it returns.
    public nonisolated func cancel() {
        ZktlsSDK.cancel(session: session)
        cookies.value = nil
    }

    /// Runs a verb so that cancelling the calling Task cancels the session: the Rust call does not
    /// see Swift Task cancellation by itself.
    private func cancellable<T>(_ verb: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler(operation: verb, onCancel: { self.cancel() })
    }
}

/// A value behind a lock, for state that a synchronous or `@Sendable` caller also touches.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class PresenterBridge: LoginHost, @unchecked Sendable {
    private let inner: ZktlsLoginPresenter
    init(_ inner: ZktlsLoginPresenter) { self.inner = inner }
    func presentLogin(url: String, cookieDomains: [String]) async -> [String] {
        await inner.presentLogin(url: url, cookieDomains: cookieDomains)
    }
}

private final class CallbackSink: ProgressSink, @unchecked Sendable {
    private let body: @Sendable (Phase, UInt8) -> Void
    init(_ body: @escaping @Sendable (Phase, UInt8) -> Void) { self.body = body }
    func onProgress(phase: Phase, percent: UInt8) { body(phase, percent) }
}

/// Allocate, the cell probe, `runTree`'s pack and its result over `URLSession`, so they inherit the
/// system's proxy, VPN and captive-portal handling. A failure is status 0 or 0 ms,
/// which the Rust core reads as unreachable.
final class URLSessionPlatformHttp: PlatformHttp, @unchecked Sendable {
    static let shared = URLSessionPlatformHttp(session: .shared)
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    func postJson(url: String, body: Data) async -> PlatformResponse {
        guard let u = URL(string: url) else { return PlatformResponse(status: 0, body: Data()) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = await send(req), let http = resp as? HTTPURLResponse else {
            return PlatformResponse(status: 0, body: Data())
        }
        return PlatformResponse(status: UInt16(clamping: http.statusCode), body: data)
    }

    func postBytes(url: String, headers: [PlatformHeader], body: Data) async -> PlatformResponse {
        guard let u = URL(string: url) else { return PlatformResponse(status: 0, body: Data()) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        // Exactly the headers given: the core sends the result's type and encoding and the run's token.
        for h in headers { req.setValue(h.value, forHTTPHeaderField: h.name) }
        req.httpBody = body
        guard let (data, resp) = await send(req), let http = resp as? HTTPURLResponse else {
            return PlatformResponse(status: 0, body: Data())
        }
        return PlatformResponse(status: UInt16(clamping: http.statusCode), body: data)
    }

    func getBytes(url: String, headers: [PlatformHeader], maxBytes: UInt64) async -> PlatformResponse {
        guard let u = URL(string: url) else { return PlatformResponse(status: 0, body: Data()) }
        // No cache and no cookie: each GET reads the document as served now, with only the headers given.
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        // Exactly the headers given: the core asks for the platform's pack with the app's credential.
        for h in headers { req.setValue(h.value, forHTTPHeaderField: h.name) }
        let config = session.configuration
        config.urlCache = nil
        config.httpCookieStorage = nil
        let task = Locked<URLSessionDataTask?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                // A session per GET, for its delegate: a task's own delegate is iOS 15, and the floor is 14.
                let get = BoundedGet(maxBytes: maxBytes) { cont.resume(returning: $0) }
                let t = URLSession(configuration: config, delegate: get, delegateQueue: nil).dataTask(with: req)
                task.value = t
                t.resume()
                // A cancel that came before `task` was set found nothing to cancel.
                if Task.isCancelled { t.cancel() }
            }
        } onCancel: {
            task.value?.cancel()
        }
    }

    func headMs(url: String) async -> UInt32 {
        guard let u = URL(string: url) else { return 0 }
        var req = URLRequest(url: u, timeoutInterval: 3)
        req.httpMethod = "HEAD"
        let t0 = Date()
        guard await send(req) != nil else { return 0 }
        return max(1, UInt32(Date().timeIntervalSince(t0) * 1000))
    }

    /// A data task as one async call: URLSession's own async `data(for:)` is iOS 15, and the
    /// floor is 14. A transport failure, or a cancel of the calling Task, is nil.
    private func send(_ req: URLRequest) async -> (Data, URLResponse)? {
        let task = Locked<URLSessionDataTask?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                let t = session.dataTask(with: req) { data, resp, _ in
                    cont.resume(returning: data.flatMap { d in resp.map { (d, $0) } })
                }
                task.value = t
                t.resume()
                // A cancel that came before `task` was set found nothing to cancel.
                if Task.isCancelled { t.cancel() }
            }
        } onCancel: {
            task.value?.cancel()
        }
    }
}

/// One `getBytes` read to at most `maxBytes` of its body as URLSession hands it over, decoded: a declared
/// length over the cap, or a body that grows past it, cancels the task, and the call answers 413 with no
/// body. A redirect to a URL that is not https is not followed: the call answers the redirect itself.
/// A transport failure, or a cancel, is status 0.
final class BoundedGet: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: UInt64
    private let done: (PlatformResponse) -> Void
    // Touched only on the session's serial delegate queue.
    private var status: UInt16 = 0
    private var body = Data()
    private var tooLarge = false

    init(maxBytes: UInt64, done: @escaping (PlatformResponse) -> Void) {
        self.maxBytes = maxBytes
        self.done = done
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = UInt16(clamping: (response as? HTTPURLResponse)?.statusCode ?? 0)
        // -1 when the length is not declared.
        tooLarge = response.expectedContentLength > Int64(clamping: maxBytes)
        completionHandler(tooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !tooLarge else { return }
        guard UInt64(body.count + data.count) <= maxBytes else {
            tooLarge = true
            body = Data()
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The session holds its delegate until it is invalidated.
        session.finishTasksAndInvalidate()
        if tooLarge {
            done(PlatformResponse(status: 413, body: Data()))
        } else if error == nil {
            done(PlatformResponse(status: status, body: body))
        } else {
            done(PlatformResponse(status: 0, body: Data()))
        }
    }
}

/// Printing a run's config shows where it points and which pack it runs, never the app credential, the
/// user hash, the idempotency key, the network label, the nonce or the run's params.
extension TreeRunConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `TreeRunConfig(baseUrl: …, platformId: …)`.
    public var description: String { "TreeRunConfig(baseUrl: \(baseUrl), platformId: \(platformId))" }

    /// The same as `description`.
    public var debugDescription: String { description }

    /// What `dump` and debuggers show: `baseUrl` and `platformId`.
    public var customMirror: Mirror { Mirror(self, children: ["baseUrl": baseUrl, "platformId": platformId]) }
}

/// Printing a config (`print`, `dump`, string interpolation, a crash reporter) shows where the session
/// points, never the app credential, the user hash, the idempotency key or the network label.
extension SessionConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// `SessionConfig(baseUrl: …, profileId: …, policyId: …)`.
    public var description: String {
        "SessionConfig(baseUrl: \(baseUrl), profileId: \(profileId), policyId: \(policyId))"
    }

    /// The same as `description`.
    public var debugDescription: String { description }

    /// What `dump` and debuggers show: `baseUrl`, `profileId` and `policyId`.
    public var customMirror: Mirror {
        Mirror(self, children: ["baseUrl": baseUrl, "profileId": profileId, "policyId": policyId])
    }
}
