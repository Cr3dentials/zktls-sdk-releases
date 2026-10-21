# Changelog

Every change a partner can notice, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html): a release that changes the public API is at
least a minor release, and one whose entry has a `### Breaking` section is a major release.

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
