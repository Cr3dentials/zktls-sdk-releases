import Foundation

/// Background time for `verify`'s hand-offs and its end call.
protocol BackgroundTime: AnyObject {
    /// Holds it; a second begin while it is held does nothing.
    func begin()

    /// Releases it; an end while it is not held does nothing.
    func end()
}

/// Background time as a lab run takes it: a background task, and the network path watched.
extension ZkTlsLifecycle: BackgroundTime {}

/// A page that gets ready while the consent screen before it is up.
protocol Preparing: AnyObject {
    /// Starts what the page needs before it loads; nothing loads.
    @MainActor func prepare()
}

extension TreeWebViewHost: Preparing {}

/// `verify`'s host on iOS: the device's attestation (`AppAttestHost`), the screens (`screens`, over the app's
/// own), each platform's page (`pages`, a `TreeWebViewHost`; the consent screen before it says what it reads, so
/// it asks nothing first) and `background` time. The core calls it in the flow's order, one call at a time,
/// from its own threads; no call throws but those the contract gives an error.
final class IOSVerifyHost: VerifyHost, @unchecked Sendable {
    /// Makes a platform's page.
    typealias Pages = () -> TreeHost

    private let device: AppAttestHost
    private let strings: ZktlsStrings
    private let screens: ScreenPresenter
    private let pages: Pages
    private let background: BackgroundTime
    /// The page of the platform in flight, which `close` closes.
    private let page = Locked<TreeHost?>(nil)
    /// The page made while the consent screen was up, for the run the user agreed to.
    private let ready = Locked<TreeHost?>(nil)

    init(device: AppAttestHost, strings: ZktlsStrings, screens: ScreenPresenter, pages: @escaping Pages, background: BackgroundTime) {
        self.device = device
        self.strings = strings
        self.screens = screens
        self.pages = pages
        self.background = background
    }

    func installId() async throws -> String { try await device.installId() }

    func needsRegistration() -> Bool { device.needsRegistration }

    func registerKey(challengeSha256: Data) async throws -> String { try await device.register(challengeSha256: challengeSha256) }

    func registered() { device.registered() }

    func sign(body: Data) async throws -> String { try await device.sign(body: body) }

    func showList(rows: [PlatformRow]) async -> UInt32? { await screens.pick(strings.list(rows)).map { UInt32($0) } }

    /// The next platform's page gets ready while the user reads its consent screen. Declined, it is closed, which
    /// lets its WebView go on the main thread.
    func showConsent(name: String, consent: Consent) async -> Bool {
        let next = pages()
        if let p = next as? Preparing { await MainActor.run { p.prepare() } }
        let agreed = await screens.consent(strings.consent(name: name, consent))
        if let left = ready.value { await left.finish() }
        ready.value = agreed ? next : nil
        if !agreed { await next.finish() }
        return agreed
    }

    // The message is for the app's logs: the user reads only which kind of refusal it is.
    func showRefusal(code: String, message: String) async { _ = await screens.ask(strings.refusal(code)) }

    /// The next platform's page: the one made during its consent screen, else a new one.
    func treeHost() -> TreeHost {
        let p = ready.value ?? pages()
        ready.value = nil
        page.value = p
        return p
    }

    func beginBackground() { background.begin() }

    func endBackground() { background.end() }

    /// The verification is over, or its caller gave up: every screen and page taken down, background time released.
    func close() async {
        await screens.dismissAll()
        await page.value?.finish()
        if let left = ready.value {
            ready.value = nil
            await left.finish()
        }
        background.end()
    }
}
