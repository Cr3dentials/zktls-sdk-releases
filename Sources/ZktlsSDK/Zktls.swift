import UIKit

/// A live publishable key's prefix: its starts are attested with App Attest.
let liveKeyPrefix = "zk_live_"

/// The refusal code of a `verify` the SDK cannot make as configured: before `configure`, say.
let notConfigured = "not_configured"

/// The refusal code of a device that could not attest itself.
let deviceNotVerified = "device_not_verified"

/// The refusal code of an install whose App Attest key our backend, or the device, no longer has: the core
/// registers a new key and starts again.
let attestKeyUnknown = "attest_key_unknown"

/// The SDK: `configure(appKey:theme:strings:)` once, when your app launches, then `verify(_:reference:)` per
/// user. `verify` attests the device (a live key), starts a verification with our backend, and runs each
/// platform in its own sign-in page with the SDK's screens, shown over your app. Your server gets a signed
/// webhook per platform, and one when the verification ends; the app learns only how each platform ended.
public enum Zktls {
    /// What `configure` set: the key, the environment (production's when nil), the theme and the strings.
    struct Configured {
        let appKey: String
        let environment: VerifyEnv?
        let theme: ZktlsTheme
        let strings: ZktlsStrings
    }

    /// The last `configure`; nil before the first.
    static let configured = Locked<Configured?>(nil)

    /// One verification at a time: its screens, its pages and its background time.
    private static let turn = Turn()

    /// Sets your app's publishable key, `zk_live_…` or `zk_test_…`, and the screens' `theme` and `strings`.
    /// Any string key of the screens may be replaced, for example with your own translation; words in braces
    /// are filled in by the SDK, so keep them in your text. Call it again to change any of them.
    public static func configure(appKey: String, theme: ZktlsTheme = ZktlsTheme(), strings: [String: String] = [:]) {
        configured.value = Configured(appKey: appKey, environment: nil, theme: theme, strings: ZktlsStrings(strings))
    }

    /// The lab's: runs `verify` against `environment` in place of production, with the SDK's own look.
    @_spi(ZktlsLab) public static func configure(appKey: String, environment: VerifyEnv) {
        configured.value = Configured(appKey: appKey, environment: environment, theme: ZktlsTheme(), strings: ZktlsStrings())
    }

    /// Verifies `platforms` (our platform ids, run in this order) for one user, under your `reference`, which
    /// every webhook carries. Shows the SDK's screens over your app's key window, and returns when the user
    /// leaves the flow, with how each platform ended. Throws `SdkError.Refused` when the verification did not
    /// start (the SDK has told the user why, except for `not_configured`), and another `SdkError` when it could
    /// not start; the SDK has shown its refusal screen for that too. Once the verification has started, this
    /// returns an outcome however its platforms end. Cancelling the calling Task ends the verification and
    /// takes its screens down. One verification runs at a time: a call made while another runs waits for it
    /// to return, then starts.
    @MainActor public static func verify(_ platforms: [String], reference: String) async throws -> VerifyOutcome {
        try await verifyWith { c in try await onDevice(c, .platforms(platforms: platforms, reference: reference)) }
    }

    /// Verifies what `token` carries: the platforms and the reference your server set when it created the
    /// token with `POST /partner/verification-tokens`. Otherwise as `verify(_:reference:)`, one at a time too.
    @MainActor public static func verify(token: String) async throws -> VerifyOutcome {
        try await verifyWith { c in try await onDevice(c, .token(token: token)) }
    }

    /// One verification: refused at once when the SDK is not configured, otherwise `run` with the configuration
    /// as it is now, once every verification called before it has returned.
    static func verifyWith(_ run: (Configured) async throws -> VerifyOutcome) async throws -> VerifyOutcome {
        guard let c = configured.value else {
            throw SdkError.Refused(code: notConfigured, message: "Zktls.verify ran before Zktls.configure: call it when your app starts")
        }
        await turn.take()
        do {
            try Task.checkCancellation()
            let outcome = try await run(c)
            await turn.give()
            return outcome
        } catch is CancellationError {
            await turn.give()
            throw SdkError.Cancelled
        } catch {
            await turn.give()
            throw error
        }
    }

    /// The core's `verify` of `request` on a session of its own, with the host on this device; its screens and
    /// page are taken down however it ends.
    @MainActor private static func onDevice(_ c: Configured, _ request: VerifyRequest) async throws -> VerifyOutcome {
        // The backend calls go through the platform's HTTP stack, process-wide, as every client's do.
        setPlatformHttp(http: URLSessionPlatformHttp.shared)
        // One verify per session: a session of its own, which a cancel of this call cancels in the core.
        let session = Session()
        let lifecycle = ZkTlsLifecycle(host: UIApplication.shared, handle: session.lifecycle())
        lifecycle.onExpiry = { ZktlsSDK.cancel(session: session) }
        let root = keyWindowRoot() ?? UIViewController()
        let host = IOSVerifyHost(
            device: AppAttestHost(live: c.appKey.hasPrefix(liveKeyPrefix)),
            strings: c.strings,
            screens: VerifyScreens(theme: c.theme),
            pages: { notice, ask in TreeWebViewHost(presentingFrom: root, notice: notice, ask: ask) },
            background: lifecycle)
        do {
            let outcome = try await withTaskCancellationHandler {
                try await ZktlsSDK.verify(appKey: c.appKey, request: request, env: c.environment, host: host, session: session)
            } onCancel: {
                ZktlsSDK.cancel(session: session)
            }
            await host.close()
            return outcome
        } catch {
            await host.close()
            throw error
        }
    }
}

/// Turns taken one at a time, in the order they are asked for.
private actor Turn {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func give() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
