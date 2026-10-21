# Integrating the zkTLS SDK on iOS

## Requirements

iOS 14.0 or later. The SDK is built and tested with Xcode 26.3 and declares Swift tools 5.9; App Store
uploads need Xcode 26. Devices are arm64. The simulator slice carries arm64 and x86_64, for Apple silicon and Intel Macs.

## Install

Swift Package Manager or CocoaPods, as in the [README](../README.md). The package brings its privacy
manifest ([privacy.md](privacy.md)). It needs no `Info.plist` key and no entitlement to run; your App
Store Connect export answer is in [export-compliance.md](export-compliance.md).

## What you need from us

Your app credential, the profile and policy ids, the front door URL (`baseUrl`), the trust bundle's URL
and the operator key to pin, and the policy bundle's URL and digest. Pin the keys in your app. Fetch the bundles yourself, and
refetch the trust bundle at least every 30 minutes.

Pass the trust bundle's URL too, as `trustBundleUrl`: the URL that always serves the latest bundle, not
a versioned or immutable copy. Each enclave refreshes its certificate every few hours and may present
the new one before the published bundle lists it, so a copy of the bundle fetched shortly before may not
pin it yet. With the URL, when the capture's two enclaves or `runTree`'s attester present such a
key, the SDK fetches the bundle itself, once per session, and connects again; without it, that session
fails with `Policy` (for `runTree`, after the user has signed in), and the only defence is to fetch the
bundle right before each session. The verifier `prove` reaches is not covered: a
`Policy("verifier not pinned by the trust bundle: …")` still means your copy is too old.

## Build the session's configuration

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
| `trustBundleUrl` | The URL that serves the latest trust bundle, from us | Recommended. `https://` only, or `""` for none; not a versioned copy. When K, T or the attester presents a key your copy does not list yet, the SDK GETs the bundle from it, once per session, through the platform's HTTP client: no credential, no cache, no cookie (on Android, unless your app installs a default `CookieHandler`), no redirect to `http`, within 10 s, and never more than 4 MiB read. It checks the bundle as it checks `trustBundleJson`, against `trustOperatorKey`, and refuses one issued before your copy. The session's later enclave connections, its proof and its claim use it, and so does any later session in your app's process whose copy is older. A revoked enclave, or one of another role or cell, is refused without a fetch. A printed `SessionConfig` never shows it |
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

## Run a session

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

## The claim, and your backend

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

## Things to know

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

## Before you submit

Work through the [partner integration checklist](partner-checklist.md): privacy answers,
export compliance, App Review notes and a demo account.
