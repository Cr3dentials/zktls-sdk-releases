import SwiftUI
import UIKit
import ZktlsSDK

/// The partner sample app, and the acceptance harness on iOS. It uses only the public package
/// surface: if this file ever needs `@testable import`, the SDK API is wrong.
struct ContentView: View {
    @State private var phase = "idle"
    @State private var percent: UInt8 = 0
    @State private var result = ""
    @State private var client: ZktlsClient?
    @State private var running = false
    // A platform's pack: ZKTLS_PLATFORMS names the platforms (README.md).
    @State private var platforms: [String] = TreeSettings.load().platforms
    @State private var platform: String = TreeSettings.load().platforms.first ?? ""
    @State private var tree: ZktlsClient?

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: Double(percent), total: 100)
                .accessibilityLabel("Proof progress")
            Text(phase).font(.headline)
            Text(result).font(.footnote).multilineTextAlignment(.center)
            Button("Prove my transfer") { Task { await run() } }.disabled(running)
            Picker("Platform", selection: $platform) {
                ForEach(platforms, id: \.self) { Text($0) }
            }
            Button("Run a platform pack") { Task { await runPack() } }.disabled(running || platform.isEmpty)
            Button("Cancel") {
                client?.cancel()
                tree?.cancel()
            }
        }
        .padding()
    }

    private func run() async {
        running = true                                    // one session at a time
        defer { running = false }
        do {
            let s = try await SampleSettings.load()
            let c = ZktlsClient(config: s.config)
            client = c
            let lifecycle = ZkTlsLifecycle(host: UIApplication.shared, handle: c.lifecycleHandle)
            lifecycle.onExpiry = { c.cancel() }                       // iOS ended our background time
            await c.onProgress { p, pc in
                Task { @MainActor in phase = "\(p)"; percent = pc }
            }
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController }).first
            else { return }
            try await c.login(host: WebViewLoginPresenter(presentingFrom: root))   // the disclosure first
            // Only now, since the login page is the user's to take time over, for example to fetch an
            // SMS code.
            lifecycle.begin()
            defer { lifecycle.end() }                                 // every path from here, including failure
            try await c.capture()
            let report = try await c.prove()
            guard report.accepted else {
                result = "Not proven: \(report.verdict)"
                return
            }
            let claim = try await c.claim()
            result = "Proven: " + claim.outputs.map(\.name).joined(separator: ", ")
        } catch {
            // A failure before the freeze ends that session; neither the SDK nor this app retries.
            result = message(for: error) + " Tap to start again."
        }
    }

    /// A platform's pack, the user present: the SDK shows the disclosure, opens the platform's sign-in
    /// page and collects in the page. The data reaches our backend at the result URL: the SDK posts it,
    /// or for a pack that attests, the attester does once it has taken the run. The app gets a summary only.
    private func runPack() async {
        running = true
        defer { running = false }
        let s = TreeSettings.load()
        let platformId = platform
        do {
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow)?.rootViewController }).first
            else { return }
            let issued = try await s.issueRun(platformId: platformId)
            let bundles = try await s.bundles()
            let c = ZktlsClient()
            tree = c
            defer { tree = nil }
            let lifecycle = ZkTlsLifecycle(host: UIApplication.shared, handle: c.lifecycleHandle)
            lifecycle.onExpiry = { c.cancel() }                       // iOS ended our background time
            defer { lifecycle.end() }                                 // every path, including failure
            await c.onProgress { p, pc in
                // A pack that attests uploads to the attester: hold background time until runTree returns.
                if p == .attesting { lifecycle.begin() }
                Task { @MainActor in phase = "\(p)"; percent = pc }
            }
            let host = TreeWebViewHost(presentingFrom: root, disclosure: disclosure(for: platformId))
            let summary = try await c.runTree(config: s.config(platformId: platformId, run: issued, bundles: bundles), host: host)
            result = describe(summary)
        } catch let e as SdkError {
            result = message(for: e) + " Tap to start again."
        } catch {
            result = "No run: \(error.localizedDescription)"
        }
    }
}

/// Your disclosure, in your words and approved for your app (docs/privacy.md): the SDK shows it before the
/// platform's pages open, and opens nothing if the user declines.
func disclosure(for platformId: String) -> TreeDisclosure {
    TreeDisclosure(
        title: "Connect your account",
        message: "The app opens \(platformId)'s own sign-in page. You sign in there yourself; the app never sees "
            + "your password. After you sign in, the app reads the data this check needs from your account on this device.",
        accept: "Continue",
        decline: "Not now")
}

/// What the app learns from a run: how it ended and each source's counts, never the data.
func describe(_ s: TreeSummary) -> String {
    var lines = [s.succeeded ? "Collected" : "Not collected: \(s.error)"]
    lines += s.sources.map { "\($0.storeAs): \($0.rows) rows, \($0.pages) pages" }
    let result = s.handedOff ? "handed to the attester, which posts the result" : s.delivered ? "result delivered" : "result not delivered: \(s.deliveryError)"
    lines.append("\(s.durationMs / 1000) s; " + result)
    return lines.joined(separator: "\n")
}

/// What the user reads for each error (docs/errors.md). Exhaustive: a new variant fails this build.
func message(for error: Error) -> String {
    guard let e = error as? SdkError else { return "Something went wrong." }
    switch e {
    case .NotLoggedIn: return "Sign-in was not completed."
    case .SessionLost: return "The connection dropped before your record was captured."
    case .Cancelled: return "Cancelled."
    case .WrongEvidence, .Truncated, .ExtraResponse, .Reordered: return "Your institution's reply could not be verified."
    case .LimitExceeded: return "This check is not available right now. Try again later."
    case .InsufficientMemory: return "Your phone is short of memory. Close other apps, then try again."
    case .Transport: return "A network problem. Check your connection."
    case .Policy: return "This check is not available right now."
    }
}

/// The sample's settings: build settings copied into Info.plist (see README.md), and the three
/// published documents fetched with URLSession, the platform HTTP client.
struct SampleSettings {
    let config: SessionConfig

    static func load() async throws -> SampleSettings {
        func key(_ k: String) -> String { Bundle.main.object(forInfoDictionaryKey: k) as? String ?? "" }
        func fetch(_ k: String) async throws -> String { try await fetchText(key(k)) }
        let config = SessionConfig(
            baseUrl: key("ZKTLS_BASE_URL"),
            appCredential: key("ZKTLS_APP_CREDENTIAL"),
            userIdHash: key("ZKTLS_USER_ID_HASH"),
            profileId: key("ZKTLS_PROFILE_ID"),
            policyId: key("ZKTLS_POLICY_ID"),
            idempotencyKey: UUID().uuidString,
            clientRegion: key("ZKTLS_CLIENT_REGION"),
            // Any stable label for the network works, such as the carrier's MCC-MNC (not the Wi-Fi
            // name, which needs location permission); it never leaves the device. The sample uses one.
            networkKey: "sample",
            trustBundleJson: try await fetch("ZKTLS_TRUST_BUNDLE_URL"),
            // Where the SDK refetches it, once, if an enclave's key is newer than this copy.
            trustBundleUrl: key("ZKTLS_TRUST_BUNDLE_URL"),
            // Pinned in the app, never fetched: the bundle is checked against it.
            trustOperatorKey: key("ZKTLS_TRUST_OPERATOR_KEY"),
            policyBundleJson: try await fetch("ZKTLS_POLICY_BUNDLE_URL"),
            policyBundleDigest: key("ZKTLS_POLICY_BUNDLE_DIGEST"))
        return SampleSettings(config: config)
    }
}

func fetchText(_ address: String) async throws -> String {
    guard let url = URL(string: address) else { throw URLError(.badURL) }
    // URLSession's async data(from:) is iOS 15; the sample runs on 14.
    return try await withCheckedThrowingContinuation { cont in
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data { cont.resume(returning: String(decoding: data, as: UTF8.self)) }
            else { cont.resume(throwing: error ?? URLError(.badServerResponse)) }
        }.resume()
    }
}

/// A tree run's settings, build settings copied into Info.plist as the proof's are: your front door and
/// app credential, the operator key that signs the packs, the platforms to offer, and your backend's
/// endpoint that issues each run's result URL and token.
struct TreeSettings {
    let baseUrl: String
    let appCredential: String
    let userIdHash: String
    let clientRegion: String
    let trustOperatorKey: String
    let runsUrl: String
    let platforms: [String]
    let trustBundleUrl: String
    let policyBundleUrl: String
    let policyBundleDigest: String

    static func load() -> TreeSettings {
        func key(_ k: String) -> String { Bundle.main.object(forInfoDictionaryKey: k) as? String ?? "" }
        return TreeSettings(
            baseUrl: key("ZKTLS_BASE_URL"),
            appCredential: key("ZKTLS_APP_CREDENTIAL"),
            userIdHash: key("ZKTLS_USER_ID_HASH"),
            clientRegion: key("ZKTLS_CLIENT_REGION"),
            trustOperatorKey: key("ZKTLS_TRUST_OPERATOR_KEY"),
            runsUrl: key("ZKTLS_RUNS_URL"),
            platforms: key("ZKTLS_PLATFORMS").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            trustBundleUrl: key("ZKTLS_TRUST_BUNDLE_URL"),
            policyBundleUrl: key("ZKTLS_POLICY_BUNDLE_URL"),
            policyBundleDigest: key("ZKTLS_POLICY_BUNDLE_DIGEST"))
    }

    /// The trust bundle and the pinned policy bundle, which a pack that attests needs; "" when unset.
    func bundles() async throws -> (trust: String, policy: String) {
        (trustBundleUrl.isEmpty ? "" : try await fetchText(trustBundleUrl),
         policyBundleUrl.isEmpty ? "" : try await fetchText(policyBundleUrl))
    }

    /// Your backend's call for a run: it asks ours for the run's result URL and token, which only it may
    /// read results with. A test server can stand in for both and take the app credential.
    func issueRun(platformId: String) async throws -> (url: String, token: String, params: String) {
        guard let url = URL(string: runsUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appCredential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["platform_id": platformId])
        let sent = request
        // URLSession's async data(for:) is iOS 15; the sample runs on 14.
        let data: Data = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: sent) { data, response, error in
                if let data, (response as? HTTPURLResponse)?.statusCode == 200 { cont.resume(returning: data) }
                else { cont.resume(throwing: error ?? URLError(.badServerResponse)) }
            }.resume()
        }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultUrl = reply["result_url"] as? String,
              let token = reply["result_token"] as? String
        else { throw URLError(.cannotParseResponse) }
        // A check's run inputs, as our backend received them: the SDK takes them as JSON text.
        let params = try (reply["params"] as? [String: Any]).map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        } ?? ""
        return (resultUrl, token, params)
    }

    func config(platformId: String, run: (url: String, token: String, params: String),
                bundles: (trust: String, policy: String)) -> TreeRunConfig {
        TreeRunConfig(
            baseUrl: baseUrl, appCredential: appCredential, userIdHash: userIdHash,
            idempotencyKey: UUID().uuidString, clientRegion: clientRegion, networkKey: "sample",
            platformId: platformId,
            // Read only for a pack that attests.
            trustBundleJson: bundles.trust, trustBundleUrl: trustBundleUrl, trustOperatorKey: trustOperatorKey,
            policyBundleJson: bundles.policy, policyBundleDigest: policyBundleDigest,
            relyingPartyNonceHex: "", resultUrl: run.url, resultToken: run.token, paramsJson: run.params)
    }
}
