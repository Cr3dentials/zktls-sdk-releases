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

/// `verify`'s host on iOS: the device's attestation (`AppAttestHost`), the screens (`screens`, over the app's
/// own), each platform's page (`pages`, a `TreeWebViewHost` behind the SDK's own sign-in notice, which it makes
/// from the pack it runs) and `background` time. The core calls it in the flow's order, one call at a time,
/// from its own threads; no call throws but those the contract gives an error.
final class IOSVerifyHost: VerifyHost, @unchecked Sendable {
    /// Makes a platform's page from what makes its notice and what asks it.
    typealias Pages = (
        _ notice: @escaping (_ platform: String, _ categories: [String]) -> TreeDisclosure,
        _ ask: @escaping (TreeDisclosure) async -> Bool
    ) -> TreeHost

    private let device: AppAttestHost
    private let strings: ZktlsStrings
    private let screens: ScreenPresenter
    private let pages: Pages
    private let background: BackgroundTime
    /// The page of the platform in flight, which `close` closes.
    private let page = Locked<TreeHost?>(nil)

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

    func showIntro(names: [String]) async -> Bool { await screens.ask(strings.intro(names)) }

    func showNext(finished: String, next: String) async -> Bool { await screens.ask(strings.next(finished: finished, next: next)) }

    func showFailed(name: String) async { _ = await screens.ask(strings.failed(name)) }

    func showFinish(outcome: VerifyOutcome) async { _ = await screens.ask(strings.finish(outcome)) }

    // The message is for the app's logs: the user reads only which kind of refusal it is.
    func showRefusal(code: String, message: String) async { _ = await screens.ask(strings.refusal(code)) }

    /// The next platform's page, behind the SDK's sign-in notice in the app's strings, naming the site the page
    /// signs in to and the data the pack reads. Its decline, or a tap outside it, ends the run with exactly
    /// "the user declined", which the core counts as that platform and every later one not started.
    func treeHost() -> TreeHost {
        let strings = self.strings
        let screens = self.screens
        let p = pages(
            { platform, categories in
                let s = strings.disclosure(platform: platform, categories: categories)
                return TreeDisclosure(title: s.title, message: s.body ?? "", accept: s.accept, decline: s.decline ?? "")
            },
            { d in
                await screens.ask(VerifyScreen(title: d.title, body: d.message.isEmpty ? nil : d.message, accept: d.accept, decline: d.decline))
            })
        page.value = p
        return p
    }

    func beginBackground() { background.begin() }

    func endBackground() { background.end() }

    /// The verification is over, or its caller gave up: every screen and page taken down, background time released.
    func close() async {
        screens.dismissAll()
        await page.value?.finish()
        background.end()
    }
}
