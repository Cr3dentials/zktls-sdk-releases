# Integrating the zkTLS SDK on iOS

Your app makes two calls: `Zktls.configure` once, when it launches, and `Zktls.verify` with the platforms
you want and a reference of your choice. The SDK checks the device, starts a verification with our
backend, shows its own screens and opens each platform's sign-in page. An attester reads each platform,
signs the result and posts it to our backend, which sends your server a signed webhook. The results never
pass through your app. This page goes from install to your first test webhook. [Proof mode](#proof-mode),
which we enable per partner, is at the end.

## Requirements

iOS 14.0 or later. The SDK is built and tested with Xcode 26.3 and declares Swift tools 5.9; App Store
uploads need Xcode 26. Devices are arm64. The simulator slice carries arm64 and x86_64, for Apple silicon and Intel Macs.
A live key needs App Attest, which needs a real device ([before you submit](#before-you-submit)); a test
key works on the Simulator.

## Install

Swift Package Manager or CocoaPods, as in the [README](../README.md): `from: "2.0.1"`, or `~> 2.0`. The
package brings its privacy manifest ([privacy.md](privacy.md)). It needs no `Info.plist` key, and no
entitlement for TestFlight and App Store builds: App Attest works from the bundle ID and Team ID you
registered with us. Your App Store Connect export answer is in [export-compliance.md](export-compliance.md).

## What you need from us

- **Your app, registered with us**: its bundle ID and Team ID, its Android package name if it has one, and
  the platforms you want.
- **Its two app keys.** Both are publishable: they ship inside your app, and are not secrets.

  | | Test key, `zk_test_…` | Live key, `zk_live_…` |
  |---|---|---|
  | Platforms | `zktls-demo` only | The platforms enabled for your app |
  | Device check | None: it works on the Simulator | App Attest, on a real device running your registered app |
  | Webhooks | Carry `"test": true` | Carry `"test": false` |
  | Limits, each hour | 30 verifications per install, 100 per app | 10 per install, and your app's limit (1,000 unless we agreed another) |

- **The signing secret of each of your team's webhooks**, `whsec_` followed by 64 hex characters. It stays
  on your server, as does your Partner API key: neither belongs in the app.

`zktls-demo` is a demo bank we host. It accepts any user name with the password `demo`, which its sign-in
page shows, and delivers a realistic result through the same attester, so a test webhook looks like a
live one.

## Configure

Call `Zktls.configure` once, when your app launches:

```swift
import SwiftUI
import ZktlsSDK

@main
struct YourApp: App {
    init() {
        Zktls.configure(appKey: "zk_test_…")         // the test key in debug builds, the live key in release
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

In a UIKit app, call it in `application(_:didFinishLaunchingWithOptions:)`.

## Verify

`Zktls.verify` runs on the main actor, presents the SDK's screens over your app, and returns when the user
leaves the flow:

```swift
import UIKit
import ZktlsSDK

final class VerifyViewController: UIViewController {
    var orderId = "order_8f3k2"                         // yours: a value your server already knows

    @IBAction func verifyTapped() {
        Task {
            do {
                let outcome = try await Zktls.verify(["zktls-demo"], reference: orderId)
                for platform in outcome.platforms {
                    switch platform.status {
                    case .done: break                   // the result is on its way to your server
                    case .failed: break                 // platform.reason says why, for your logs
                    case .notStarted: break             // the user stopped: offer to finish later
                    }
                }
            } catch SdkError.Refused(let code, let message) {
                // The verification did not start. The SDK has already told the user why.
                print("verify refused: \(code): \(message)")   // errors.md
            } catch {
                print("verify failed: \(error)")
            }
        }
    }
}
```

- **The platforms** are our platform ids, in the order the user should see them: 1 to 10, each once.
- **The reference** is any string you choose, 1 to 128 characters of `A-Z`, `a-z`, `0-9`, `.`, `_` and
  `-`, and it comes back unchanged in every webhook for the verification. Use a value your server already
  knows, such as an order id, so a result still matches if your app is killed in the middle of the flow.
  Never put personal data in it.
- **A refusal** (`SdkError.Refused`) means the verification did not start. Except for `not_configured`,
  the SDK has already shown its refusal screen; the codes are in [errors.md](errors.md#refused). Any
  other error means it could not start, most often `Transport` without a network, and the SDK has shown
  its refusal screen for that too ("Verification isn't available right now"), unless your app cancelled
  the call. Once the verification has started, `verify` returns an outcome however its platforms end.

### The outcome

| Field | Meaning |
|---|---|
| `verificationId` | The verification's id. Every webhook for it carries the same id |
| `platforms` | One `PlatformOutcome` per platform, in the order you passed them |
| `platform` | The platform id |
| `status` | `.done`: the run reached the attester, or its result reached us. `.failed`: the run ended in an error first. `.notStarted`: the user stopped the flow on or before this platform |
| `reason` | Why a platform failed, a short code for your logs ([errors.md](errors.md#how-each-platform-ended-in-verify)); `nil` otherwise |

`.done` means the result is on its way, not that it has arrived: act on the webhook. Each platform counts
on its own. **To finish later**, call `verify` again with the platforms that were not started: it is a
new verification, with a new `verificationId`, and you may pass the same reference.

```swift
let remaining = outcome.platforms.filter { $0.status == .notStarted }.map { $0.platform }
```

**To start from your server**, have your server create a token with `POST /partner/verification-tokens`
(its Partner API key in `x-api-key`), with the platforms and the reference, and pass it to the app. The
token is single use and lasts 15 minutes:

```swift
let outcome = try await Zktls.verify(token: token)      // token: "vt_…", from your server
```

## Test with `zktls-demo`

1. Run your app on the Simulator or a device with your test key, and call
   `verify(["zktls-demo"], reference: …)`.
2. Tap **Start** on the intro, then **Continue** on the sign-in notice.
3. Sign in to the demo bank with any user name and the password `demo`.
4. The SDK hands the run to an attester and shows **All done**. `verify` returns with `zktls-demo` as
   `.done`.
5. Within seconds your server receives a `platform.finished` with `"test": true` and the demo bank's
   latest transfer, then a `verification.finished`. Both carry your reference.

`verify` throws `not_configured` when `Zktls.configure` has not run. With a test key,
`platform_unavailable` means a platform other than `zktls-demo`.

## Your server: the webhooks

Every active webhook on your team receives every delivery, test and live, as a JSON `POST`:

- one `platform.finished` for each platform the user started, when its result reaches us or its run
  fails, with the platform's `status` (`done` or `failed`), its `result` (the figures the attester read,
  or `null`), the attester's signed `claim` in base64 (or `null`), and, for a failure, an `error` with a
  `code` and a `message`;
- one `verification.finished` when every platform has ended, listing each as `done`, `failed` or
  `not_started`. A platform the user never started sends no `platform.finished`.

```json
{"event": "platform.finished", "test": true, "verificationId": "7d0f3c52-…", "reference": "order_8f3k2",
 "platform": "zktls-demo", "runId": "c3a5e0d4-…", "status": "done", "complete": true,
 "result": {"evidence": "attested", "transfer": {"amount_minor": "000000012500", "currency": "SGD",
            "status": "completed", "reference": "REF-7C21A94E0B3F"}},
 "claim": "AQAAAG…", "error": null, "finishedAt": "2026-10-23T12:00:08.000Z"}
```

**Check the signature before you trust a delivery.** Each carries
`Zktls-Signature: t=<Unix seconds>,v1=<hex>`, where `v1` is the HMAC-SHA256, keyed with the webhook's
signing secret (the whole string, `whsec_` included), of `t`, a `.`, and the raw request body, in lowercase
hex. Compute it over the raw body bytes, before any JSON parsing; compare it in constant time; and reject
a `t` more than 300 seconds from your clock, so a captured delivery cannot be replayed later. Each retry
is signed again, with its own `t`, over the same body.

The `claim` is the attester's signed claim, which we checked before sending the webhook. To check it
yourself, rather than rely on our backend's check, decode it from base64 and verify it as in
[checking a result](backend-tree-results.md#checking-a-result-typescript-node-22-or-later), with the
operator key, the trust bundle's URL and each platform's policy id, which we give you on request.

Match results by `reference`, process each `platform.finished` once per `runId`, keep deliveries with
`"test": true` apart, and expect results after the user has left your app. A platform handed to an
attester whose result never reaches us fails about 2 hours after the verification started, with the
error code `no_result`. That needs the app to have reported the hand-off, which the SDK does at the end of
the flow: if the app was killed or offline before then, and no result arrives, the platform ends as
`not_started` in `verification.finished`, with no `platform.finished`. Your server can also fetch a
verification with its Partner API key: `GET /partner/verifications/:id`.

## Theme and strings

The layout of the screens is fixed. You set the colours, the logo and the words, when you configure:

```swift
Zktls.configure(
    appKey: "zk_test_…",
    theme: ZktlsTheme(
        accent: UIColor(red: 0.05, green: 0.49, blue: 0.35, alpha: 1),
        background: .systemBackground,
        text: .label,
        logo: UIImage(named: "Logo")),
    strings: [
        "intro.title": NSLocalizedString("Verify your work accounts", comment: ""),
        "finish.title": NSLocalizedString("Thanks, you're all set", comment: ""),
    ])
```

`ZktlsTheme()` with no arguments keeps the SDK's own look. English ships built in; override any string by
its key, for example with your own translations. The keys are the same on Android. Words in braces are
filled in by the SDK, so keep them in your text:

| Key | English |
|---|---|
| `intro.title` | Verify your accounts |
| `intro.body` | You'll sign in to each one on its own page. Only the result is shared. |
| `intro.start` / `intro.cancel` | Start / Not now |
| `next.title` / `next.body` | {done} done / Next: {next} |
| `next.continue` / `next.stop` | Continue / Stop here |
| `failed.title` / `failed.continue` | {platform} couldn't be verified / Continue |
| `finish.title` / `finish.partial` / `finish.close` | All done / Finished {done} of {count} / Close |
| `refusal.device` / `refusal.other` / `refusal.close` | This device can't be verified / Verification isn't available right now / Close |
| `disclosure.title` / `disclosure.body` | Sign in to {platform} / {platform} opens its own sign-in page. Data read: {categories}. |
| `disclosure.accept` / `disclosure.decline` | Continue / Cancel |

In `disclosure.title` and `disclosure.body`, `{platform}` is the site the page signs in to, as the
platform's signed pack names it (for `zktls-demo`, "zkTLS Demo Bank"), or the platform's name when the pack
names none; the other screens use the platform's name. The refusal screen shows `refusal.device` for
`device_not_verified` and `refusal.other` for every other code.

## Things to know

- **The screens.** The SDK presents them with UIKit, over the top-most view controller of your key
  window. SwiftUI apps need nothing extra.
- **Stopping.** **Not now** on the intro, **Stop here** between platforms, **Cancel** on the sign-in
  notice, or closing a sign-in page (its Close button, or a swipe down) ends the flow. The platform the
  user was on, and every later one, are not started. Cancelling the `Task` that runs `verify` ends it too,
  and takes the screens down.
- **Where the page may go.** The sign-in page stays on the platform's domains and on the third-party
  sign-in providers the platform uses ([the rules](integration-packs.md#where-the-page-may-go)). If the
  user follows a link anywhere else, that platform ends as failed, with the reason `navigation_refused`.
- **The sign-in screen** has a bar with the page's host and a Close button, and covers the page while the
  screen is recorded ([store-review.md](store-review.md#the-sign-in-screen)).
- **Your app's web data.** Each run has its own non-persistent web data store, so your own WebViews and
  cookies are untouched.
- **Background time.** The SDK holds background time during each hand-off to the attester, and while it
  reports how the platforms ended (up to 10 s). You add no lifecycle code for `verify`.
- **Logging.** Log the `verificationId`, the statuses, the reasons and the refusal codes. Your Partner
  API key and webhook secrets never belong in the app at all.

## Before you submit

- **Live keys need App Attest, on a real device.** The Simulator has no App Attest, so a live key there
  shows "This device can't be verified" and throws `device_not_verified`. Builds you run from Xcode use
  App Attest's development environment by default, which live keys also refuse, unless you add the App
  Attest capability with its environment set to production. TestFlight and App Store builds always use
  production. Develop with the test key, and try the live key with a TestFlight build on an iPhone or
  iPad.
- **Your registered app.** The build's bundle ID and Team ID must be the ones you registered with us.
- **The live key in release builds.** A test key in a release build runs only `zktls-demo`.
- **App Privacy.** The SDK includes its privacy manifest; add its answers to yours ([privacy.md](privacy.md)).

Then work through the [partner integration checklist](partner-checklist.md): export compliance and App
Review notes.

## Proof mode

Proof mode proves one fact from an institution's account with a zero-knowledge proof: `ZktlsClient`'s
`login`, `capture`, `prove` and `claim`. We enable it per partner; `verify` needs none of this section.

### What proof mode needs from us

Your app credential, the profile and policy ids, the front door URL (`baseUrl`), the trust bundle's URL
and the operator key to pin, and the policy bundle's URL and digest. Pin the keys in your app. Fetch the
bundles yourself, and refetch the trust bundle at least every 30 minutes.

Pass the trust bundle's URL too, as `trustBundleUrl`: the URL that always serves the latest bundle, not
a versioned or immutable copy. Each enclave refreshes its certificate every few hours and may present
the new one before the published bundle lists it, so a copy of the bundle fetched shortly before may not
pin it yet. With the URL, when the capture's two enclaves present such a key, the SDK fetches the bundle
itself, once per session, and connects again; without it, that session fails with `Policy`, and the only
defence is to fetch the bundle right before each session. The verifier `prove` reaches is not covered: a
`Policy("verifier not pinned by the trust bundle: …")` still means your copy is too old.

### Build the session's configuration

One `SessionConfig` per session the user starts. The field names are the same in Swift and Kotlin.

| Field | What it holds | Rules |
|---|---|---|
| `baseUrl` | The front door's URL, from us | `https://` only; anything else fails `capture` with `Policy` |
| `appCredential` | Your app's credential, from us | Never log it. A printed `SessionConfig` shows only `baseUrl`, `profileId` and `policyId` |
| `userIdHash` | Your own hash of your own user id | Never the raw id. The same value for the same user: the front door counts per-user quotas on it. Non-empty, at most 128 characters (a hex SHA-256 is 64) |
| `profileId`, `policyId` | What the session proves, from us | The policy must be one the policy bundle holds for that profile |
| `idempotencyKey` | This session's key | New for every session, never reused: a fresh UUID works. 1 to 117 bytes. The SDK appends `.1`, `.2`, … for each capture of the session |
| `clientRegion` | The user's country, ISO 3166-1 alpha-2 (`"GB"`) | `""` if you do not know it: the SDK then times the cells the front door offers and uses the fastest. It leaves the device ([privacy.md](privacy.md)) |
| `networkKey` | A label for the network the phone is on | Any stable string; it never leaves the device. The SDK remembers its choice of cell under it for up to 24 hours while your app runs, so a label that changes with the network (`"wifi"`, `"cellular"`) lets it choose again after a move; a constant works too. Do not read the Wi-Fi network's name for it: that needs location permission |
| `trustBundleJson` | The trust bundle, as fetched from its URL | At most 30 minutes old. Without `trustBundleUrl`, fetch it right before each session: an enclave that refreshed its certificate since fails the session with `Policy` |
| `trustBundleUrl` | The URL that serves the latest trust bundle, from us | Recommended. `https://` only, or `""` for none; not a versioned copy. When the capture's enclaves present a key your copy does not list yet, the SDK GETs the bundle from it, once per session, through the platform's HTTP client: no credential, no cache, no cookie (on Android, unless your app installs a default `CookieHandler`), no redirect to `http`, within 10 s, and never more than 4 MiB read. It checks the bundle as it checks `trustBundleJson`, against `trustOperatorKey`, and refuses one issued before your copy. The session's later enclave connections, its proof and its claim use it, and so does any later session in your app's process whose copy is older. A revoked enclave, or one of another role or cell, is refused without a fetch. A printed `SessionConfig` never shows it |
| `trustOperatorKey` | The operator's public key the trust bundle must be signed by | PEM or base64 DER; Ed25519, P-256 or RSA. Pinned in your app, never fetched |
| `policyBundleJson` | The signed policy bundle, as fetched from its URL | |
| `policyBundleDigest` | The digest that pins the policy bundle, hex, from us | Pinned in your app |

```swift
let config = SessionConfig(
    baseUrl: frontDoor, appCredential: credential, userIdHash: hash(of: userId),
    profileId: profileId, policyId: policyId,
    idempotencyKey: UUID().uuidString,             // new for every session
    clientRegion: country ?? "", networkKey: "default",
    trustBundleJson: trustBundle, trustBundleUrl: trustBundleURL, trustOperatorKey: operatorKey,
    policyBundleJson: policyBundle, policyBundleDigest: policyBundleDigest)
```

### Run a session

```swift
import UIKit
import ZktlsSDK

final class ProveViewController: UIViewController {
    private var client: ZktlsClient?

    func prove(config: SessionConfig) async {
        let client = ZktlsClient(config: config)             // one client per session the user starts
        self.client = client
        await client.onProgress { phase, percent in
            Task { @MainActor in /* update your progress view: phase, percent */ }
        }
        do {
            try await client.login(host: WebViewLoginPresenter(presentingFrom: self))   // disclosure, then the page
            // Only now, since the login page is the user's to take time over (for example to fetch an SMS code).
            let lifecycle = ZkTlsLifecycle(host: UIApplication.shared, handle: client.lifecycleHandle)
            lifecycle.onExpiry = { client.cancel() }        // iOS ended our background time during the capture
            lifecycle.begin()
            defer { lifecycle.end() }                        // every path from here, including failure
            try await client.capture()
            let report = try await client.prove()
            guard report.accepted else { return show("Not proven: \(report.verdict)") }
            let claim = try await client.claim()           // verified against the trust bundle
            await send(claim.encoded)                      // your backend verifies it again
        } catch let e as SdkError {
            show(message(for: e))                          // errors.md; never retry automatically
        } catch {
            show("Something went wrong. Please try again.")
        }
    }

    func cancelTapped() { client?.cancel() }
}
```

`show`, `send` and `message(for:)` are yours. The sample app's `message(for:)` maps every variant.

### The claim, and your backend

`claim()` returns a `Claim` the SDK has verified against the trust bundle. Your backend cannot trust
the app, so send it `claim.encoded` and have it verify the claim itself.

The claim is the verifier's signed statement that the policy held for the user's account. It carries
the policy's typed `outputs` (each value is JSON of the type the policy declares), the `nullifierHex`
(the same account and statement always give the same value), the `profileId` and `policyId`, the
`verifierEpoch` of the key that signed it, `issuedAt` and `expiresAt` (Unix seconds), and the
verifier's Ed25519 `signatureHex`. `encoded` is its canonical encoding, base64.

Your backend checks what `claim()` checks on the phone:

1. The signature: Ed25519 over the claim's canonical encoding without its signature, by a claim key
   that the trust bundle lists for `verifierEpoch`, on a verifier member that is not revoked, in an
   epoch that is valid.
2. The time: `issuedAt` at most 60 seconds ahead of your clock, and `expiresAt` not passed.
3. No holder binding: the SDK refuses a claim bound to a holder key, and so should you.

And what only your backend knows:

4. `profileId` and `policyId` are the ones you asked for, and the outputs say what you need.
5. The nullifier: if an account may prove a fact once, refuse a nullifier you have already seen.

Our libraries do checks 1 to 3 on your backend, in TypeScript, Go and Rust: [verifying a claim on your backend](backend-verification.md).

### Things to know in proof mode

- **The proof.** `prove` proves each record the policy reads, to the verifier the session was assigned,
  over TLS 1.3 authenticated against the trust bundle. The verifier returns its signed claim with an
  accepted verdict, and `claim()` verifies it. The end-to-end flow has run against a live cell on
  devices ([support matrix](support-matrix.md)).
- **The disclosure.** `WebViewLoginPresenter` shows it before the page, every time. Pass
  `disclosure:` to translate it. A presenter of your own must show an equivalent one ([store-review.md](store-review.md)),
  and close its page when the `Task` running `presentLogin` is cancelled: that is how `cancel()` reaches it.
- **The witness never reaches your code.** `capture` returns an opaque handle that proves once. No API returns its bytes.
- **Cancelling.** `cancel()` ends the verb in flight with `SdkError.Cancelled`, and closes the login
  page if it is open. Cancelling the `Task` that runs a verb does the same.
- **Background.** Begin `ZkTlsLifecycle` only after `login` returns, and let `lifecycle.end()` run on
  every path, including failure. It asks iOS for background time while a session runs, usually about
  30 seconds. `onExpiry` fires only when that time ends during the capture: you cancel, and the user
  starts again when they return. A proof is left to go on when the user returns.
- **Network changes.** `ZkTlsLifecycle` notices a Wi-Fi to cellular handover and reconnects at once.
- **Threads.** Every verb runs on the SDK's own threads, so call them from any task. `onProgress`
  calls you on an SDK thread, except for the `failed` phase a cancel reports, which arrives on the
  thread that cancelled. Hop to the main actor for UI, and do not block in the callback.
- **Error text.** `Transport` and `Policy` carry their text as the associated value:
  `case .Policy(let text)` ([errors.md](errors.md)).
- **Logging.** Log error variants and that text only. Never log a handle, a cookie, or `SessionConfig`:
  `print` and `dump` show every field of a `SessionConfig`, the app credential included.

