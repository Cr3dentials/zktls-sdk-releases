# Platform packs and `runTree`, in the lab

A partner's app runs platforms with `Zktls.verify` ([iOS](integration-ios.md),
[Android](integration-android.md)), which fetches each platform's pack, the bundles and the keys itself
and runs each pack with `runTree`. This page is for pack authors and the device lab: what a pack is, how
one is made and published, and how to run one on its own with `runTree`, behind the SDK's lab opt-in. A
partner's app needs none of it, and the lab API may change in any release.

`runTree` runs a platform's **pack** in the SDK's own WebView while the user is present: the user signs
in to the platform and the pack collects their data in the page. For a pack that attests, the SDK then
hands the user's session to an enclave, the **attester**, which reads the platform's summary itself and
signs the figures it extracts; the user may close the app as soon as the attester has taken the run
([`Detached`](#a-pack-that-attests-detached)).

## What a pack is

A pack is one JSON document per platform, a few kilobytes, that we author and publish:

- **The tree:** the steps the WebView follows. It opens the sign-in page, waits for the user to sign
  in, and reads the platform's own endpoints from inside the page with the user's session. The steps
  are a fixed set of generic ones; a pack may also carry our script
  ([where the page may go](#where-the-page-may-go)).
- **The sources:** each `collect` step reads one endpoint, pages through it within declared caps, and
  keeps the rows and fields it names. Everything a `collect` reads is labelled **observed**: the phone
  read it, and nothing vouches for it.
- **The attest block**, when the platform supports it: the summary endpoint the attester reads, the
  fields it signs, and the account it reads them for. Those figures are labelled **attested**, and the
  attester's signed claim carries them.
- **The envelope:** the platform's domains and any third-party sign-in hosts (the WebView is held to
  them: [where the page may go](#where-the-page-may-go)), the addresses the SDK never
  records on (sign-in and account-security pages), and the categories of data the pack collects, which
  the sign-in notice and your store answers name ([privacy.md](privacy.md)).

Your app never sees the data. The SDK posts it to the result URL issued for the run, or for a pack that
attests the attester does ([backend-tree-results.md](backend-tree-results.md)), and `runTree` returns a
summary.

## How a pack is made

1. **Author.** We write the pack from the platform's own requests: which endpoint holds the data, how
   it pages, which fields are needed and which personal fields are dropped before anything leaves the
   phone.
2. **Validate.** The pack is checked with the same rules the SDK applies when it loads one: only the
   generic steps, every address on the platform's domains and `https`, every reference to an earlier
   step's data defined, and caps on every source. A pack that breaks a rule is refused with a reason,
   before it is published, and again by the SDK on the phone.
3. **Sign.** A pack that attests names a policy. That policy, with the exact profile the attester
   reads, goes into the signed policy bundle, which the SDK pins by its signing keys. The attester
   takes the request, the fields and the claim's lifetime from its own copy of that bundle, never from
   the phone.
4. **Check the attested read.** Before a platform's pack ships with an attest block, we run its
   attested read through the attester against a real account: the platform must answer the attester's
   request over HTTP/1.1, and every field must be found in the reply. A platform that does not pass
   ships without an attest block, so its sources are observed only, until it does.
5. **Sign and publish.** We sign the pack with the operator key the SDK pins for the trust bundle,
   and our API serves it by platform id. The SDK fetches it for each run and runs it only with that
   signature, so a pack our API serves but we did not sign never reaches the WebView.

## When a platform changes

A platform that changes its pages or endpoints gets a new pack version, which our API serves once we
sign it: no app changes, and the next run uses it. Within one launch, the SDK never runs an
older version of a platform's pack than one it already ran. The version and SHA-256 of the pack a run
used travel with its result.

## Running a pack in the lab

### The lab opt-in

`runTree` and what only it takes or returns (`TreeRunConfig`, `TreeHost`, `TreeWebViewHost`,
`TreeDisclosure`, `TreeSummary`, `TreeSource`, `SourceEvidence`), and `VerifyEnv`, are behind the lab
opt-in. Without it, the compiler refuses them.

- **Swift:** import the module with its lab interface, in each file that names them:
  `@_spi(ZktlsLab) import ZktlsSDK`.
- **Kotlin:** opt in on the declaration or the file that uses them, `@OptIn(ZktlsLabApi::class)` or
  `@file:OptIn(ZktlsLabApi::class)`, or mark a declaration of your own `@ZktlsLabApi` to pass the
  requirement on to its callers.

### Run one pack

```swift
@_spi(ZktlsLab) import ZktlsSDK

let client = ZktlsClient()                                   // a client for tree runs
let host = TreeWebViewHost(presentingFrom: viewController, disclosure: disclosure) // the lab's notice text
let summary = try await client.runTree(config: TreeRunConfig(
    baseUrl: frontDoor, appCredential: credential, userIdHash: hash(of: userId),
    idempotencyKey: UUID().uuidString, clientRegion: "GB", networkKey: "wifi",
    platformId: "deel-contractor",                            // the platform the user verifies
    trustBundleJson: trustBundle, trustBundleUrl: trustBundleURL, trustOperatorKey: operatorKey,
    policyBundleJson: policyBundle, policyBundleKeys: policyBundleKeys,   // the keys, not a digest
    relyingPartyNonceHex: "",                                 // or a 32-byte nonce, hex
    resultUrl: run.resultUrl, resultToken: run.resultToken,   // issued for this run
    paramsJson: ""),                                          // the check's run inputs, or "" for none
    host: host)
```

```kotlin
@OptIn(ZktlsLabApi::class)
suspend fun runPack(activity: Activity, disclosure: TreeDisclosure, run: IssuedRun): TreeSummary {
    val client = ZktlsClient()                               // a client for tree runs
    return client.runTree(TreeRunConfig(
        baseUrl = frontDoor, appCredential = credential, userIdHash = hash(userId),
        idempotencyKey = UUID.randomUUID().toString(), clientRegion = "GB", networkKey = "wifi",
        platformId = "deel-contractor",
        trustBundleJson = trustBundle, trustBundleUrl = trustBundleUrl, trustOperatorKey = operatorKey,
        policyBundleJson = policyBundle, policyBundleKeys = policyBundleKeys,   // the keys, not a digest
        relyingPartyNonceHex = "", resultUrl = run.resultUrl, resultToken = run.resultToken,
        paramsJson = "",
    ), TreeWebViewHost(activity, disclosure))
}
```

`IssuedRun`, `frontDoor`, `credential` and the bundles are yours: the lab's own server, or our backend,
issues the run's result URL and token.

`policyBundleKeys` are the keys the policy bundle must be signed with: Ed25519 public keys, 64 lowercase
hex characters each, the attester's own policy keys (`verify` uses the ones the SDK compiles in). The SDK
refuses a bundle signed with any other key, and one older than a version it has accepted under the same
key while the app runs, with `Policy("policy bundle: not signed with one of policy_bundle_keys")` or
`Policy("policy bundle: version N is older than version M already seen")`. There is no digest to pin, so
a new version of the bundle needs no new build. They are read only for a pack that attests: an observed
pack takes an empty list. (Proof mode's `SessionConfig` still pins its policy bundle by digest.)

`paramsJson` carries the run's inputs when the check takes any: a JSON object as text, as the backend received it
when it created the run (at most 16 KiB). Pass `""` for a check without inputs. The SDK refuses anything else before
the WebView opens.

`trustOperatorKey` is read on every run: it checks the pack's signature. The trust and policy bundles,
and `trustBundleUrl`, are read only for a pack that attests. Everything is checked before the WebView opens: a platform we
publish no pack for, a pack we did not sign, a pack the SDK's rules refuse, and an attested pack whose
profile is not the one the pinned policy bundle holds are refused with `Policy`, and the user sees
nothing.

### The lab's sign-in notice

`TreeWebViewHost` shows the `TreeDisclosure` you pass, as given, before the platform's page opens: pass
the text your review approved. (`verify` shows its own notice, from its `disclosure.*` strings, naming
the site the page signs in to, the pack's `provider.name` or, when it has none, the platform's name, and
the data its pack reads.) Declining it ends the run with `Cancelled`, as closing the page
does, and nothing is posted to the result URL; before 2.0.0, a decline failed the run and posted a failed
result. A `TreeHost` of your own reports a decline by failing `begin` with exactly "the user declined",
and, once the user has closed the page, fails every call but `finish` with exactly "the page closed".

### `verify` against another environment

`Zktls.configure(appKey:environment:)` (Kotlin `Zktls.configure(appKey, environment)`), behind the same
opt-in, makes `verify` run against a `VerifyEnv` in place of production: `backendUrl`, `trustBundleUrl`
and `policyBundleUrl`, each `https://`; `operatorKey`, PEM; and `policyKeys`, as `policyBundleKeys`. The
screens keep the SDK's own look and words. An environment the SDK cannot use is refused with
`Policy("verify env: …")` before anything is sent ([errors.md](errors.md#policy)).

### How the run ended

`TreeSummary` says how the run ended:

| Field | Meaning |
|---|---|
| `succeeded` | The pack's steps succeeded and, for a pack that attests, the attester took the run (`handedOff`) |
| `error` | The platform's reason when the steps failed, in the pack's words (for example, the user did not sign in) |
| `sources` | Each observed source's key, and how many rows and pages it read. The attested source goes to your backend only |
| `claim` | Empty: for a pack that attests, the attester posts the claim to your backend |
| `delivered`, `deliveryError` | Whether the phone's post reached the result URL ([errors](errors.md#a-result-that-did-not-arrive)); `false` and empty on a hand-off |
| `handedOff` | A pack that attests: the attester accepted the run, and posts its result |

A run that fails before the attester accepts it throws, as the other verbs do ([errors.md](errors.md)),
and nothing is posted; its data is not kept on the phone.

## A pack that attests: `Detached`

Once the pack's steps succeed, a pack that attests has one thing left to do on the phone. The SDK seals
the session the attested request needs as it leaves the WebView, closes the page, reports `Attesting`,
and uploads once to the attester: the attested request with the user's session in it, the run's observed
result, your nonce, and your `resultUrl` and `resultToken`. The attester posts to `resultUrl`, so for a
pack that attests it must be an https URL whose host is a DNS name on port 443, with no IP address and
no user info: the SDK checks this, and that the policy's read fits the attester's 4 hours, before the
WebView opens, and refuses with `Policy`. The host must also be one we have allowed the attester to post
to; the attester refuses any other (`Policy("attester refused the upload: result host not allowed")`).
The attester is an enclave your trust bundle pins; the SDK uploads only to one that publishes a claim
key, and refuses any other with `Policy` before sending anything. An attester refreshes its certificate
every few hours and may present the new one before the published bundle lists it, and the upload comes
after the user has signed in: pass `trustBundleUrl` (the URL that serves the latest bundle), and the SDK
refetches the bundle once and uploads to the same allocation, instead of failing the run with `Policy`
and losing the sign-in. Without it, fetch the trust bundle right before each run.

When the attester accepts the upload, `onProgress` reports `Detached` (80 %), and `runTree` returns
with `handedOff` true. There is no `Done` for such a run:

- **The app may close.** Tell the user they can leave. The attester reads the platform from our cell,
  through a proxy whose address is in the user's own country ([privacy.md](privacy.md#packs-that-attest)),
  signs the claim, and posts the run's one result to `resultUrl` with the observed sources, the attested
  source and the claim ([a result from the attester](backend-tree-results.md#a-result-from-the-attester)).
  Your app sees no claim and no attested figure; your backend learns how the run ended from that result.
- **Until `Detached`, the run needs the app.** The upload takes seconds, at most 120 s, after which it
  fails with `Transport`. If the user may leave during it, hold background time as for a capture: begin
  `ZkTlsLifecycle` (and on Android `ZkTlsSessionService`) when `onProgress` reports `Attesting`, and end
  it when `runTree` returns (`verify` does this itself). Before the acceptance, a busy attester
  (`Transport("attester error: attester busy")`) or a dropped connection, which a new run may get past,
  and a refusal (`Policy("attester refused the upload: …")`), which a new run would meet again, throw,
  never report `Detached`, and hand nothing off: the user starts a new run, signing in again.

## Where the page may go

This holds for every platform `verify` runs too; there, a refusal fails that platform with the reason
`navigation_refused`. A pack names two sets of hosts, and the SDK decides every page load and popup in its WebView against
them before it starts:

- **The platform's domains**, its own hosts. A plain entry is that host exactly; an entry with a
  leading dot, such as `.portal.example`, is `portal.example` and every subdomain of it.
- **`sign_in_domains`**, the hosts of a third-party sign-in the platform offers, such as
  `accounts.google.com` for "Continue with Google" or `appleid.apple.com` for "Continue with Apple".
  Each is an exact host. A pack without them allows no third-party sign-in: the user's tap on
  "Continue with Google" ends the run.

What each may do:

- **The page** (the WebView's main frame) loads only over `https`, on the platform's domains or a
  sign-in host. Link clicks, redirects and form posts are decided too. Anything else is cancelled
  before it loads: another host, `http`, an `about:blank` or `data:` address, or a redirect at its
  first hop off the list, even one that would lead back to the platform. The run then
  ends with `SdkError.Policy("navigation_refused: <host>")`.
- **Popups** (`window.open`, `target="_blank"`, a sign-in window) never open a second window. A popup
  whose address passes the same rule loads in place, in the same WebView; any other ends the run as a
  navigation does. A blank `window.open()` is decided at its first navigation. Only the popup's
  address loads, as a GET, on both platforms: a popup that posts a form loses the form's body.
- **The SDK's bridge**, the code that reads the platform's endpoints from inside the page, runs only
  while the page is on the platform's domains. The pack's script, and the SDK's reads of the cookies
  the pack declares, run there too, and not on an address the pack records nothing on. A sign-in host
  gets none of them. A script, a cookie read or a bridge request the run meets while the page is
  anywhere else ends the run with `SdkError.Policy("origin_refused: <host>")`.
- **iframes** may load any `https` host, `about:blank` and `about:srcdoc`: sign-in pages embed
  third-party challenges and captchas. The bridge never runs in one. An `http` iframe is cancelled,
  and the run goes on; iOS also cancels any other iframe that is not `https`, such as a `data:` one.
- **A script's own request** (`api.fetch`) that is redirected off the platform's domains, or onto an
  address the pack records nothing on, fails with `redirect_refused: <host>`. The script never sees
  the other host's reply; it handles the error itself, and your app does not see it.

`<host>` is the host alone, never the path or query, and may be empty (a `data:` address has none).
Both refusals are `Policy` errors, so match on the prefix, as in [errors.md](errors.md#reading-the-text-of-transport-and-policy).
A user who tapped a link off the platform can start a new run. A refusal that repeats at the same
host is a report to us, with the host: the pack may need it as a sign-in host.

`TreeSummary.isolation` says how the run's web data was kept apart from your app's
([privacy.md](privacy.md#what-confines-our-script) has the details):

| `isolation` | Where | Meaning |
|---|---|---|
| `profile` | Android, Android System WebView 123 and later | The run had a WebView profile of its own |
| `shared` | Android, older WebViews | The run used your app's WebView store, wiped before and after |
| `ephemeral` | iOS | The run had a new non-persistent data store |
| empty | Both | The run never had a page: it failed before the page opened, or the page opened and its first load failed. A declined sign-in notice returns no summary: `runTree` throws `Cancelled` |

It reaches your app only: the result posted to the result URL does not carry it. What the user sees
around the page, the host bar and the capture protection, is in
[store-review.md](store-review.md#the-sign-in-screen).
