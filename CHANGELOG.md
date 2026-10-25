# Changelog

Every change a partner can notice, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a release that changes the public API is at
least a minor release, and one whose entry has a `### Breaking` section is a major release.

## [2.0.1] - 2026-10-25

### Fixed
- iOS, Swift Package Manager: the package bundles the WebView bridge, so `verify` opens each platform's sign-in
  page. With 2.0.0 every platform failed at once with "The browser could not start: the bridge did not load"
  (lab `runTree` in 1.0.0 too). CocoaPods and Android were not affected.

## [2.0.0] - 2026-10-25

A partner's app makes two calls, `Zktls.configure` once and `Zktls.verify` per user, and
its server gets each platform's result from ours, in a signed webhook.

### Breaking
- `runTree` and the types only it takes or returns leave the partner API (Removed, below). An app that ran
  platform packs with `runTree` calls `Zktls.verify` instead, and its server takes our webhooks instead of
  creating runs: our Partner API no longer creates SDK runs (`POST /partner/browser-session` with
  `"channel": "sdk"` answers 400 with the code `use_verify`).
- `SdkError` (Swift) and `SdkException` (Kotlin) gain the case `Refused`: an exhaustive `switch` or `when`
  over them needs it.

### Added
- `Zktls`, the SDK's facade. iOS: `Zktls.configure(appKey:theme:strings:)`, then
  `Zktls.verify(_:reference:)` or `Zktls.verify(token:)`, `async throws` on the main actor. Android:
  `Zktls.configure(appKey, theme, strings)`, then the `suspend` functions
  `Zktls.verify(activity, platforms, reference)` or `Zktls.verify(activity, token)`. `configure` takes your
  app's publishable key, `zk_live_…` or `zk_test_…`; `verify` takes our platform ids (1 to 10, each once,
  run in that order) and your `reference` (1 to 128 of `A-Z`, `a-z`, `0-9`, `.`, `_` and `-`), which comes
  back unchanged in every webhook. It checks the device (a live key), starts a verification with our
  backend, and runs each platform in its own sign-in page, handing each run to an attester that reads the
  platform and posts the result to our backend. It returns a `VerifyOutcome` once the user leaves the flow:
  its `verificationId` and, per platform, a `PlatformOutcome` with the `status` `done`, `failed` or
  `notStarted` (Kotlin `DONE`, `FAILED`, `NOT_STARTED`) and, for a failure, a `reason`. Never the
  platform's data: your server gets one signed `platform.finished` webhook per platform the user started,
  and one `verification.finished` when every platform has ended. `verify(token:)` runs the platforms and
  the reference your server set with `POST /partner/verification-tokens`. Our backend's address, the
  bundles' URLs and the keys that check them are compiled into the SDK: your app passes no URL, and no key
  but its own app key.
  One verification runs at a time; cancelling the calling task or coroutine ends it.
- Test keys. A `zk_test_` key skips the device check, so it works on the iOS Simulator and Android
  emulators, and runs only the demo platform `zktls-demo` (any user name, the password `demo`). Its
  webhooks carry `"test": true`.
- Device attestation for live keys. iOS: Apple App Attest; the first live verification on an install
  registers the install's key with our backend, and each start then carries an assertion over its request.
  Android: Google Play Integrity's Standard API; each start carries a token bound to the SHA-256 of its
  request. A device that cannot attest itself (a simulator or emulator, a phone without Google Play
  services, a build that is not your registered app, an outage of Apple's or Google's service) gets the
  refusal screen, and `verify` throws `Refused` with `device_not_verified`. The Android library depends on
  `com.google.android.play:integrity`. What these send, and to whom, is in `docs/privacy.md`.
- The SDK's own screens: an intro naming the platforms, a sign-in notice before each platform's page that
  names the data its pack reads, a step between platforms, a notice when a platform could not be verified,
  a finish screen, and a refusal screen. iOS shows them with UIKit, over the top-most view controller of
  the key window; Android as dialogs over the activity you pass. `ZktlsTheme` sets their colours and logo,
  and `strings` replaces any of their words by key (English built in; the same keys on both platforms).
  The SDK holds background time on iOS, and runs its `shortService` on Android, during each hand-off, and
  while it reports how the platforms ended (up to 10 s): your app adds no lifecycle code for `verify`.
- `SdkError.Refused(code, message)`, Kotlin `SdkException.Refused` with `code` and `message`: `verify` did
  not start, and the SDK has shown its refusal screen. `code` is `app_key_invalid`, `device_not_verified`,
  `attest_key_unknown`, `platforms_invalid`, `platform_unavailable`, `reference_invalid`, `token_invalid`,
  `limit_reached` (an hourly limit, our request rate limit, or the limit on device checks for one app or
  one network), `account_inactive` (your team's trial is used up, its subscription has lapsed, or it has not
  accepted the terms; test-key verifications do not count against a trial), `request_invalid` (our backend
  could not read the request) or `unavailable` (our backend could not start it, on our side). Or it is
  `not_configured`, which shows no screen: `verify` ran before `configure`, or, on Android, a live key ran
  in a build with no Play Integrity project number compiled in, which our release gate stops from
  shipping.
- `ConfinementPolicy.providerName()` and `dataCategories()`: what a host's sign-in notice names, the site
  the page signs in to (the signed pack's `provider.name`, else the platform's name) and the data the pack
  reads; `packName()`, the platform's name.

### Changed
- An attested run's policy bundle is pinned by key, not by digest. The SDK accepts a policy bundle signed
  with a key it pins, the attester's own policy keys, and refuses one older than a version it has accepted
  under the same key while the app runs: `Policy("policy bundle: not signed with one of
  policy_bundle_keys")` and `Policy("policy bundle: version N is older than version M already seen")`. So a
  new version of the policy bundle needs no new app. Proof mode keeps its digest:
  `SessionConfig.policyBundleDigest` is unchanged.
- A declined sign-in notice ends the run as `Cancelled`, as closing the page does, and posts nothing.
  Before, it failed the run, and a failed result was posted. In `verify`, it ends that platform and every
  later one as not started; a lab `runTree` throws `Cancelled`. A `TreeHost` of your own reports a decline
  by failing `begin` with exactly "the user declined".
- The SDK's HTTP client on Android: a POST follows no redirect, so a 3xx is its answer and a body and its
  token go only where they were sent; a GET follows at most 5 redirects, each only to https, and drops
  `Authorization` on a redirect to another origin. Neither uses a cache, and neither sends a cookie unless
  your app installs a default `CookieHandler`, which `HttpURLConnection` uses for every request,
  `verify`'s calls to our backend and its bundle fetches included. On iOS likewise: a POST sends no cookie
  and follows no redirect, and a GET follows a redirect only to https and drops `Authorization` on one to
  another origin.
- `PlatformHttp.postBytes` returns the reply's body, an error's included: `verify` reads our backend's
  answers and refusals from it. An app that installs its own `PlatformHttp` must return it. `getBytes` also
  carries `verify`'s GETs, with `Accept` only.
- Two refusals read differently: a GET to a URL that is not https is `Policy("GET URL must be https://")`,
  where it read `base_url must be https://`, and a header a GET may not carry is `Policy("header <name>
  may not go to the GET URL")`, where it read `… may not go to the pack URL`.
- The Android library brings `kotlinx-coroutines-android` at runtime: the SDK's WebView runs on
  `Dispatchers.Main`, whatever scope `verify` is called from. An app whose own code uses it, such as
  `MainScope()`, still declares it: a runtime dependency is not on your compile classpath.
- The integration guides, the checklist, and the privacy and store-review notes describe `configure` and
  `verify`. `docs/integration-packs.md` is now for pack authors, with the lab opt-in.

### Removed
- From the partner API, behind the SDK's lab opt-in (`@_spi(ZktlsLab) import ZktlsSDK` in Swift,
  `@OptIn(ZktlsLabApi::class)` or `@ZktlsLabApi` in Kotlin), for pack authors and our device lab:
  `runTree` (with `ZktlsClient.runTree`), `TreeRunConfig`, `TreeHost`, `TreeWebViewHost`,
  `TreeDisclosure`, `TreeSummary`, `TreeSource` and `SourceEvidence`. `VerifyEnv`, new, is there too: only
  the lab's `Zktls.configure(appKey:environment:)` takes it, to run `verify` against another environment.
  The lab API may change in any release. In the lab, `TreeRunConfig.policyBundleKeys` (Ed25519 public
  keys, 64 lowercase hex characters each) replaces `policyBundleDigest`.

## [1.0.0] - 2026-10-21

The first public release.

### Added
- `ZktlsClient` on iOS and Android: `login`, `capture`, `prove` and `claim` over one Rust core, with
  `onProgress` and `cancel`. Cancelling the task or coroutine that runs a verb cancels the session.
- `runTree`, the seventh verb, with `TreeWebViewHost` as its default host on each platform. It runs a
  platform's pack in the SDK's WebView while the user is present. You pass the platform's id; the SDK
  fetches its pack from our API and runs it only with our operator's signature, checked against the
  `trustOperatorKey` you pin: the user signs in, and the pack collects the platform's data in the page.
  The app receives a `TreeSummary` that counts each source, never the data: the SDK posts the run's
  result once, as one gzipped protobuf (`proto/tree_result.proto`), to the `resultUrl` issued for the
  run, with its token, and the summary says whether it arrived. For a pack that attests, the SDK instead
  uploads the user's session and the observed result once to the attester, an enclave the trust bundle
  pins that publishes a claim key, and returns when it accepts them: the `Detached` phase and
  `TreeSummary.handedOff` say the app may close. The attester then reads the pack's endpoint, signs a
  claim over the fields it extracted, and posts the run's result, the claim included, to the same
  `resultUrl`. A busy attester is a `Transport` error, and nothing is handed off. `ZktlsClient()` makes
  a client for tree runs; its proof-flow verbs refuse with `Policy`. Three new phases, `Collecting`,
  `Attesting` and `Detached`, report the run's progress. `PlatformHttp` gains `postBytes` and
  `getBytes`, which an app that installs its own `PlatformHttp` must implement. A pack may carry our
  script for its platform, which the WebView runs in the page; an app that implements its own
  `TreeHost` implements `runScript` for it.
- `runTree` keeps the platform's page on the platform. The page loads only over https, on the pack's
  domains or on the hosts of a third-party sign-in the pack lists in its new `sign_in_domains` (such as
  `accounts.google.com`); a popup loads in place, as a GET of its address, or is refused. The SDK's code
  in the page, the pack's script and the reads of the cookies a pack declares run only on the
  platform's own pages. Anything else ends the run with `Policy("navigation_refused: <host>")` or
  `Policy("origin_refused: <host>")`. A pack's script whose own request is redirected off the pack's
  domains gets `redirect_refused: <host>`, which it handles itself.
- A pack's `navigate` step ends on the page it opened. On iOS, a page that reloads itself or goes elsewhere
  before that page commits no longer passes for it: `runTree` opens the step's address once more, and a
  second time the step fails with `the page went elsewhere before <url> loaded`. Android's WebView already
  lets the step's own navigation win.
- A pack's attested read asks TEE_K for TLS 1.3 with `TLS_AES_128_GCM_SHA256`, as a capture does. Before,
  an origin that honours the client's order chose ChaCha20, which an attested read refuses, and the run
  failed after sign-in.
- `TreeSummary.isolation` says how the run's web data was kept apart from your app's: `profile`
  (Android, a WebView profile of its own, on Android System WebView 123 and later), `shared` (older
  WebViews: your app's store, wiped before and after), `ephemeral` (iOS), or empty when the run never
  had a page. The result posted to the result URL does not carry it.
- The run's page has a bar above it with a padlock, the page's host and a Close button. Close, Back
  on Android and a swipe down on iOS end the run with `Cancelled`, and nothing is posted. Android keeps
  the window out of screenshots and recordings (`FLAG_SECURE`); iOS covers the page while the screen
  is recorded or mirrored, and in the app switcher.
- The page's requests for the camera, microphone, location and motion are denied, its downloads are
  refused, and its JavaScript alerts, confirmations and prompts are never shown.
- An app that implements its own `TreeHost`: `begin` takes the pack's `ConfinementPolicy`, which
  decides every navigation, popup, bridge message, script run and cookie read, and returns the run's
  isolation. Once the user closes the page, every call but `finish` fails with exactly "the page
  closed", which ends the run as `Cancelled`.
- `capture()` sends the request the policy's profile names, and only that one: the capture enclave
  encrypts it only if it renders from the profile's request template, and signs the template's digest
  into its receipts, which the verifier holds to the trust bundle's entry. So a proof always answers
  the profile's own request, never another request to the same site. A profile with a header the SDK
  has no value for, or a login whose cookies hold a byte a header line cannot carry, is refused with
  `Policy` before anything is sent.
- `capture()` runs only in a cell whose verifier the trust bundle accepts. When the allocation names no
  verifier, it fails with `Transport` before any enclave is reached or the login's cookies are sent,
  instead of capturing receipts `prove()` could not prove. When it names only verifiers the bundle does
  not accept, it fails with `Policy`, as for an enclave the bundle does not pin: refresh the bundle.
- `SessionConfig.trustBundleUrl` and `TreeRunConfig.trustBundleUrl`: the URL that serves the latest
  trust bundle, `https://` only, `""` by default. An enclave may present a refreshed RA-TLS certificate
  before the published bundle lists it, so a copy of the bundle fetched shortly before does not pin it
  yet. With the URL, when the capture's two enclaves or the attester present a key your copy does
  not list yet, the SDK fetches the bundle once per session (per run for `runTree`), within 10 s,
  reading at most 4 MiB, with no credential and no cache, no cookie (on Android, unless your app
  installs a default `CookieHandler`) and no redirect to `http`; checks it
  against `trustOperatorKey`, refuses one issued before your copy, and connects once more with it.
  Nothing reached the enclave before, so the allocation and, for `runTree`, the user's sign-in are kept.
  The session's later enclave connections, its proof and its claim use the refetched bundle, and so does
  any later session in the process whose copy is older, so a revocation it carries holds. The verifier
  `prove` reaches is not covered. A revoked enclave, or one of another role or cell, is refused without a
  fetch; a refetch that fails or does not help is `Policy`, as before, and its text says so. Without the
  URL nothing changes.
- `PlatformHttp.getBytes` takes `maxBytes`: an app that installs its own `PlatformHttp` reads at most that
  much of the body, decoded, uses no cache and no cookie (the SDK's Android client sends one only if your
  app installs a default `CookieHandler`), follows no redirect to `http`, and answers 413
  with no body when the declared length or the body is over it.
- `prove()` proves each record the policy reads to the verifier the session was assigned, over TLS 1.3
  authenticated against the trust bundle, and returns the verifier's signed claim for `claim()`.
  `SessionConfig` has no verifier policy, and `prove()` takes no verifier address.
- `prove()` rides out a network that goes silent mid-proof: while the verifier owes a reply, 8 s with
  nothing received reconnects and resumes the session instead of waiting on TCP.
- `prove()` dials the verifier by the name its cell gives, resolving it at every reconnect and racing
  its IPv6 and IPv4 addresses (RFC 8305). So after a network change a proof reaches the address the
  name has now.
- `prove()`'s reconnect and read deadlines count the time the device slept. After a suspend, a proof
  resumes or ends on waking, instead of waiting out a deadline again. So does its 120-second budget.
- `prove()` refuses a capture 120 seconds old or more with `SessionLost`, counting the time the device
  slept, before it spends any time or data: the verifier would refuse its receipts.
- `prove()` refuses to start, with `InsufficientMemory`, when the phone has less free memory than the
  proof needs at its peak, instead of starting a proof the system would stop partway through.
- iOS: the SDK's threads run at the user-initiated quality of service, as the prover's do, so the
  system does not schedule a proof the user is waiting on as background work.
- `prove()` runs the prover on the phone's performance cores, at most four, and on fewer when the
  memory left beside the proof's peak is short. The first proof sets the count for the app's process.
- A printed `SessionConfig` (`print`, `dump`, `toString()`) shows only `baseUrl`, `profileId` and
  `policyId`, never the app credential or another secret.
- iOS: a Swift package (Swift Package Manager) and a pod (CocoaPods), iOS 14.0 or later, with a
  signed xcframework whose simulator slice also runs on Intel Macs, and a privacy manifest.
- Android: `xyz.cr3dentials:zktls-sdk` on Maven Central, Android 7.0 (API 24) or later, for
  arm64-v8a, armeabi-v7a, x86_64 and x86. The armeabi-v7a library uses NEON, which every ARMv7
  device that shipped with Android 5.0 or later has.
- `WebViewLoginPresenter`: shows a `LoginDisclosure` and opens the institution's sign-in page only on
  accept. Pass your own disclosure to translate it.
- `ZkTlsLifecycle`, built on `ZktlsClient.lifecycleHandle` (a required argument): reconnects at once on
  a network change, and on iOS keeps the session alive in the background for the time iOS allows
  (`BackgroundTaskHost`). On Android, `ZkTlsSessionService` does that as a short foreground service.
  The handle takes only the OS's signals (`onBackgroundExpiry`, `onServiceTimeout`); the verbs drive the
  rest of the session's state inside the core.
- Documentation: the API reference (DocC, Dokka), integration guides, an error catalogue, a support
  matrix, privacy and store-review notes, and an export-compliance draft for counsel.

### Changed
- Two refusals read differently. An enclave whose key the trust bundle lists for another role or cell is
  `Policy("enclave not pinned by the trust bundle: … certificate key belongs to a member of another role
  or cell")`, where it read `… certificate key is not a live epoch key of any member for this role and
  cell`. For `runTree`, an attester whose claim key for its epoch the bundle does not list is
  `… the attester's claim key for this epoch is not listed`, where it read `… the K member publishes no
  claim key for this epoch: it is not an attester`; a K member with no claim key at all still reads so.
