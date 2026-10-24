# Errors

Every call returns, or throws one error: `SdkError` in Swift, `SdkException` in Kotlin, with the same
variants. `verify` throws only when the verification did not start: `Refused` for a refusal, another
variant (most often `Transport`) when the start could not be made. Either way the SDK has shown its
refusal screen, except for `not_configured` and a call your app cancelled. Once the verification has
started, `verify` returns an outcome, and a platform that fails is in it, not an error
([how each platform ended](#how-each-platform-ended-in-verify)).
**The SDK never retries, and your app must not retry behind the user's back.** A capture
that failed before the institution's reply was frozen cannot be resumed: resuming would reuse a
secret. So every row below ends, at most, with the user choosing to start a new session.

| Variant | What the user should read | Start again? |
|---|---|---|
| `NotLoggedIn` | Sign-in was not completed. | When they choose |
| `SessionLost` | The connection dropped before the record was captured. | When they choose |
| `Cancelled` | Nothing, or "Cancelled". | When they choose |
| `WrongEvidence`, `Truncated`, `ExtraResponse`, `Reordered` | The institution's reply could not be verified. | Once; if it repeats, report it |
| `LimitExceeded` | This check is not available right now. | Later |
| `InsufficientMemory` | Close other apps, then try again. | When they choose |
| `Transport` | A network problem. | When they choose |
| `Policy` | Depends on the message, below. | Only after the cause is fixed |
| `Refused` | `verify` only: the SDK has shown its refusal screen, except for `not_configured`. Depends on the code, below. | Only after the cause is fixed; `limit_reached` and `unavailable`, later |

### `NotLoggedIn`

`login` ended with no cookie of the profile's domains: the user declined the disclosure, closed the
login page, or signed in to a page that set none. Also raised when `capture` is called before `login`,
or again after a capture that did not end in `SessionLost`: each login serves one capture.

### `SessionLost`

The capture ended before the institution's reply was frozen, because the network dropped or the app
was suspended. Also raised when `prove` or `claim` is called without a capture or a proof to use, and
when `prove` is called 120 seconds or more after its capture: the verifier refuses a capture's receipts
after that, so `prove` refuses first, before it spends any time or data. The 120 seconds count the time
the phone slept. That session is over.

### `Cancelled`

`cancel()` was called, or the Swift `Task` running the verb was cancelled. That includes your app's
own `cancel()` from `ZkTlsLifecycle.onExpiry` (iOS) or from `ZkTlsSessionService`'s timeout callback
(Android), when the system ends the session's background time or its foreground service. In
Kotlin, cancelling the coroutine that runs a verb cancels the session too, and the coroutine ends with
its own `CancellationException` rather than this.

After a cancel, the session's lifecycle handle reads `failed` with the reason `protocolFailure`, as
after a failure. The client's `isCancelled` tells the two apart.

A cancel during `runTree`'s upload for a pack that attests can cross the attester's acceptance already on
its way back: `runTree` then throws `Cancelled`, but the attester has the run, reads the platform and
posts the result. Your backend may hear of a run your app saw cancelled, as after a dropped connection.

`runTree` also ends with `Cancelled` when the user closes its page: its Close button, Back on Android,
a swipe down on iOS. That run posts nothing to the result URL, and the session itself is not
cancelled: `isCancelled` reads false. So does a run whose sign-in notice (the disclosure) the user
declines: it too posts nothing. Before this release, a declined notice failed the run instead, and a
failed result was posted.

### `WrongEvidence`

An enclave's receipt did not match its opening. The session is refused. If it happens again, report
it with the time and your app credential's id: it can mean a faulty enclave.

### `Truncated`

The institution's reply ended before its declared length.

### `ExtraResponse`

The institution sent more than the profile allows.

### `Reordered`

The institution's TLS records arrived out of order.

### `LimitExceeded`

A size or count limit of the profile or the protocol was exceeded.

### `InsufficientMemory`

`prove` did not start: the phone has less free memory than this proof needs at its peak, and the
system would stop your app partway through it. The SDK compares its estimate of the proof's peak with
`os_proc_available_memory()` on iOS, and on Android with the free memory `ActivityManager` reports
(`MemoryInfo.availMem`). The witness is spent, as after any error. Closing other apps frees memory;
the user then starts a new session.

### `Transport`

A network failure on the way to the front door, an enclave or the verifier; also the SDK's own task
failing, and a missing platform HTTP client, both of them bugs to report. The error carries the raw
reason text, not the Rust `Display` form (no `transport: ` prefix): in Swift the associated value,
`case .Transport(let text)`; in Kotlin `e.v1`, because Kotlin's `e.message` reads `v1=<text>`
([reading the text](#reading-the-text-of-transport-and-policy)). Known forms:

| Message | Meaning |
|---|---|
| `verifier unreachable: <address> (<reason>)` / `verifier unreachable: <member> at <address>: <reason>` | The verifier the session was assigned could not be reached |
| `the allocation named no verifier` / `the allocation named no verifier for cell <id>` | The front door assigned the session no verifier: none was ready. `capture` stops before it reaches an enclave or sends the login's cookies. Start a new session later |
| `allocate returned <status>: <body>` | The front door refused the session: 400, a malformed field, and 401 or 403, the app credential (your configuration); 429, a quota (the user starts again later). The body, at most 256 bytes, says more |
| `SDK task failed: <reason>` | The SDK's own task stopped unexpectedly; report it |
| `set_platform_http was never called` | The SDK's platform HTTP client was never installed; this should not happen — report it |
| `our backend is unreachable: <call>` | `verify`: our backend could not be reached for `<call>` (`attest challenge`, `attest key` or `verification start`). Nothing was started; the SDK showed its refusal screen ("Verification isn't available right now"), and the user starts again later |
| `our backend answered <status>: <call>` / `our backend's reply is malformed: <call>` | `verify`: our backend's answer to `<call>` is not one this SDK reads (not the answer, and not a refusal; for the start, also an answer whose platforms are not the ones asked for, in order, or that has none or more than 10). Nothing was started, and the SDK showed its refusal screen; report it with the status |
| `host callback failed: <reason>` | `verify`: the SDK's own iOS or Android layer failed while attesting the device; the SDK showed its refusal screen. Report it |
| `tree host: <reason>` | `runTree`: the WebView host failed while handing the attested read its cookies or session material | Report it |
| `attester error: attester busy` / `attester error: attester not ready` | `runTree`, a pack that attests: the attester has as many runs in flight as it takes, or has not yet started taking them. Nothing was handed off and `Detached` was not reported; the user starts a new run in a minute or two |
| `attester error: policy bundle: <reason>` | `runTree`: the attester could not fetch the policy bundle to check the upload against. Nothing was handed off; the user starts a new run later. A refusal a new run would meet again is a `Policy` error instead (`attester refused the upload: <reason>`) |
| `the allocation named no attester` | `runTree`: the front door assigned no attester, so none was ready. Nothing was sent; the user starts a new run later |
| `the allocation's JWT names no session` | `runTree`: the front door's answer was malformed; nothing was sent. Report it |
| `the attester closed the connection before accepting the upload` / `the attester did not accept the upload within 120 s` / `the attester accepted the upload under another session` / `the enclave answered the upload with something other than an acceptance` | `runTree`: no acceptance of this run came back, so `Detached` was not reported: the connection closed while the upload was sent or answered, the 120 s ran out (in the allocation, the connection or the wait for an answer), or the attester answered for another session. The user starts a new run. If the connection dropped just after the attester accepted, it still posts the result, so your backend may hear of a run your app saw fail |
| Anything else | Forwarded as-is from the capture core (for example a dial timeout, a closed connection, or a protocol error) |

### `Policy`

The session's documents refused the operation. Retrying does not help until the cause is fixed. The
text, `case .Policy(let text)` in Swift and `e.v1` in Kotlin (not `e.message`, which reads
`v1=<text>`), starts with one of:

| Message | Cause | Fix |
|---|---|---|
| `the front door must be https://` | `base_url` is not `https://` | Your configuration |
| `idempotency_key must be 1 to 117 bytes` | `idempotencyKey` is empty or too long | Your configuration |
| `trust bundle: no signature` / `trust bundle: the operator signature does not verify` | The trust bundle is unsigned, or not signed by the key you pinned | Refetch the bundle; check `trust_operator_key` |
| `trust bundle: the operator key PEM does not parse` / `trust bundle: the operator key is neither PEM nor base64 DER` / `trust bundle: the operator key is not an Ed25519, P-256 or RSA public key` | `trust_operator_key` is malformed | Your configuration |
| `trust bundle: version N is older than version M already seen` | An older bundle than one this app already accepted | Refetch the bundle |
| `trust bundle: <parse error>` | The bundle is not valid JSON | Refetch the bundle |
| `enclave not pinned by the trust bundle: <id>` / `enclave not pinned by the trust bundle: the allocation named no verifier the trust bundle accepts` | An enclave the bundle does not list, or a session assigned only verifiers it does not list; `capture` stops before it reaches an enclave. For `runTree`, also an enclave the bundle lists as a capture's, not an attester (`… publishes no claim key for this epoch: it is not an attester`), or an attester whose claim key it does not list (`… the attester's claim key for this epoch is not listed`): nothing is uploaded. An enclave whose key the bundle lists for another role or cell reads `… certificate key belongs to a member of another role or cell`. These two texts are new in this release: before, the first read `… publishes no claim key for this epoch: it is not an attester` and the second `… is not a live epoch key of any member for this role and cell`. Most often your copy predates the enclave's latest certificate: with `trustBundleUrl` set, the SDK has refetched the bundle once already, and the text ends `(with the trust bundle refetched)`, `(the trust bundle refetch failed: <reason>)` or `(the trust bundle was already refetched in this run)` | Set `trustBundleUrl`; without it, fetch the bundle right before each session. If it repeats with the bundle refetched, report it |
| `trust_bundle_url must be https://, or empty` | `trustBundleUrl` is set to something other than an `https://` URL; nothing was sent | Your configuration |
| `policy bundle: <reason>` / `policy bundle is not the pinned one (digest): <reason>` | The policy bundle is malformed, or (a `SessionConfig` session) not the one whose digest you pinned | Refetch it; check `policy_bundle_digest` |
| `policy bundle: not signed with one of policy_bundle_keys` / `policy bundle: version N is older than version M already seen` | `runTree`: the policy bundle is not signed with a key in `policy_bundle_keys`, or is older than one this app already accepted under that key. Nothing has been shown to the user | Refetch the bundle; check `policy_bundle_keys` |
| `no policy <id> in the pinned bundle` / `policy <id> is for profile <id>` | `policy_id` or `profile_id` does not match the bundle | Your configuration |
| `the profile declares no cookie_domains` / `the profile's URL must be https://` / `bad port in the profile's URL` | The profile is malformed | Contact us |
| `profile <id> has N requests; a capture sends one` / `profile <id> needs template values the SDK is not given` / `profile <id> has no secret Cookie header for the login's cookies` / `header <name> has no source: login yields cookies only` | The profile needs something this SDK version cannot give it | Contact us |
| `profile <id>: request policy (<rule>): <reason>` / `the profile's request template: <reason>` | The profile's request template is one the capture enclave refuses, or does not encode | Contact us |
| `the login yielded no cookies` | The sign-in finished without a cookie for the profile's domains | The user signs in again |
| `a cookie holds a byte a header line cannot carry` | A cookie from the sign-in holds a control character or a non-ASCII byte, which a request header cannot carry | Report it |
| `invalid capture config: <reason>` / `malformed response` | The capture could not be set up, or the institution's reply is not what the profile expects | Report it |
| `verifier not pinned by the trust bundle: <member> at <address>: <reason>` | The verifier's key is not one your trust bundle lists: your copy is older than the verifier's current key | Refetch the trust bundle, then start a new session |
| `proof: <reason>` | The prover refused to build the proof from this capture and the pinned policy; nothing was sent | Report it |
| `proof was not accepted: <verdict>` | `claim` was given a report that was not accepted ([below](#a-proof-that-was-not-accepted)) | Tell the user what was not proven |
| `the verifier returned no claim` | The verifier accepted but issued no claim; `verdict` ends with its reason (`; no claim: <reason>`) | Contact us |
| `claim decode: <reason>` / `claim verify: <reason>` | The claim failed verification against the trust bundle | Do not use it; contact us |
| `platform_id must be 1 to 64 letters, digits, '-', '_' or '.'` / `base_url must be https://` | `runTree`: the platform id or the front door is malformed. Nothing has been shown to the user | Your configuration |
| `our API has no pack for platform <id>` | `runTree`: we publish no pack for that platform id | Check `platformId`; contact us |
| `our API is unreachable for the pack` / `the pack fetch answered <status>` | `runTree`: the platform's pack could not be fetched. Nothing has been shown to the user | Start a new run; contact us if it repeats |
| `GET URL must be https://` / `header <name> may not go to the GET URL` | A bug in one of the SDK's GETs: the pack, a bundle, or our backend's attest challenge | Report it |
| `verify env: <field> must be https://` / `verify env: operator_key is empty` / `verify env: operator_key: <reason>` / `verify env: policy_keys must be one or more keys, 64 lowercase hex characters each` | `verify` in the lab, with an environment whose `backend_url`, `trust_bundle_url` or `policy_bundle_url` is not `https://`, whose operator key is missing or not a key (`<reason>` as for `trust bundle: the operator key …`), or whose policy keys are missing or not Ed25519 public keys in lowercase hex. Nothing was sent and no screen was shown | Your configuration |
| `backend_url must be https://` / `header <name> may not go to the backend` | A bug in the SDK's calls to our backend | Report it |
| `pack: the reply is over 512 KiB` / `pack: the reply is not a signed pack` / `pack: the operator signature does not verify` / `pack: the operator key …` | `runTree`: what came back is not a pack we signed, or `trust_operator_key` is malformed or not ours. The SDK runs only a pack the operator signed. Nothing has been shown to the user | Check `trust_operator_key`; contact us if it repeats |
| `tree pack: <code> at <path>: <reason>` | `runTree`: the signed pack breaks a rule of the pack format this SDK version knows; `<code>` is one of `json`, `unsupported_node`, `envelope`, `domain`, `undefined_reference`, `collect`, `caps`, `attest`, `limits`, `script`. Nothing has been shown to the user | Update the SDK; contact us |
| `pack <id> is not platform <id>'s` / `pack version <version> is not dotted numbers` / `pack <id> version <version> is older than one this app already ran` | `runTree`: the signed pack is for another platform, or older than one this app already ran | Contact us |
| `result_url must be https://` / `result_token must be the run's token, visible ASCII without spaces` | `runTree`: the result URL or the run's token from our backend is malformed. Nothing has been shown to the user | Your configuration |
| `params_json must be a JSON object, or empty` / `params_json is N bytes, over 16384` | `runTree`: the run's inputs are not a JSON object as text, or are over 16 KiB. Nothing has been shown to the user | Your configuration |
| `this client has no SessionConfig: create it with one to log in, capture and claim` | `login`, `capture` or `claim` on a client made with `ZktlsClient()` for tree runs | Your code: create the client with a `SessionConfig` |
| `relying_party_nonce_hex must be 64 hex characters` | `runTree`: the nonce is not 32 bytes in hex | Your configuration |
| `policy_bundle_keys must be one or more keys, 64 lowercase hex characters each` | `runTree`: `policy_bundle_keys` is empty, or a pinned policy key is not 64 lowercase hex characters (an Ed25519 public key). Nothing has been shown to the user | Your configuration |
| `the pack's attesters must be KOnly` / `policy <id> is not an attested KOnly policy` / `the pack's profile is not policy <id>'s` / `profile <id> has no attest block` / `profile <id> has no request` | `runTree`: the pack's attested read does not match the policy bundle you pinned. Nothing has been shown to the user | Refetch both; contact us if it repeats |
| `navigation_refused: <host>` | `runTree`: the page or a popup tried to load an address the pack does not allow (another host, `http`, or a redirect off the list), so the SDK cancelled it and ended the run. `<host>` is the host alone, and may be empty ([where the page may go](integration-packs.md#where-the-page-may-go)) | The user left the platform, for example by tapping a link off it, and can start a new run. If it repeats at the same host, report it with the host: a sign-in provider the pack does not list in `sign_in_domains` is refused |
| `origin_refused: <host>` | `runTree`: the run needed the bridge, the pack's script or a declared cookie where they may not run: off the platform's domains (a sign-in host, say) or, for the script and cookies, on an address the pack records nothing on | The user can start a new run; if it repeats at the same host, report it with the host |
| `a Cookie slot that is not secret would send the login in the clear` / `header <name> is not secret: session material goes only into a secret slot` / `header <name> has no source in the run` | `runTree`: the pack's attested request needs a value the run cannot supply safely; the sign-in's secrets were never sent | Contact us |
| `session material is not a header and its value, tab-separated` / `session material names an invalid header <name>` / `session material for <name> is not one header line` | `runTree`: the WebView host returned malformed session material; nothing was sent | Report it |
| `the run's result is over the result URL's 5 MB cap` / `the run's result is over the result URL's 32 MB cap` | `runTree`, a pack that attests: the observed result is larger than the result URL takes, so it was not uploaded and nothing was handed off | Contact us: the pack's caps are too wide |
| `result_url must be an https URL on port 443 whose host is a DNS name, for a pack that attests` | `runTree`: the attester posts the result, and it posts only to such a URL: no IP address, no other port, no user info. Nothing has been shown to the user | Your backend's result URL |
| `the policy's attested read runs for up to <n> s, over the attester's 14400 s` | `runTree`: the pinned policy's attested read may run longer than the attester's 4 hours, so the attester would refuse it. Nothing has been shown to the user | Contact us |
| `the upload is <n> bytes, over the attester's 6 MiB` | `runTree`: the attested request and the observed result together are larger than the attester takes, so nothing was uploaded or handed off | Contact us: the pack's caps are too wide |
| `attester refused the upload: <reason>` | `runTree`: the attester's verdict on this run's upload, in its words, which a new run would meet again. For example `result host not allowed` (your `resultUrl`'s host is not one the attester posts to), `the result token is empty or not visible ASCII`, `request 0 …` (the attested request does not render from the policy), `the policy is not in the policy bundle` / `the policy is not an attested policy` / `the policy's caps.seconds is over the attester's 14400`, `the upload is <n> bytes, over 6 MiB`, `the partial result …` or `the relying-party nonce is …`. Nothing was handed off and `Detached` was not reported | `result host not allowed` and the token: your backend's result URL and token. Anything else: report it with the reason |

### `Refused`

`verify` did not start: our backend refused the start, or the registration of the install's App Attest
key, or the device could not attest itself. Except for `not_configured`, the SDK has already shown its refusal screen ("This device
can't be verified" for `device_not_verified`, "Verification isn't available right now" for any other
code), and no platform ran. In Swift, `catch SdkError.Refused(let code, let message)`; in Kotlin,
`catch (e: SdkException.Refused)` with `e.code` and `e.message` (here `e.message` is the refusal's own
message, not the `v1=<text>` form). `message` is for your logs; `code` is one of:

| `code` | Cause | Fix |
|---|---|---|
| `app_key_invalid` | The app key is unknown or inactive, or is neither a `zk_live_` nor a `zk_test_` key | Your configuration: copy the key from your app's settings again |
| `device_not_verified` | A live key on a device that failed App Attest or Play Integrity, or cannot run them: a simulator or emulator, an Android phone without Google Play services, or one whose Google Play services cannot get a token (offline, say), a build that is not your registered app, or an attestation outage | Test on simulators and emulators with your test key; a live key needs a real device running your registered build |
| `attest_key_unknown` | Our backend did not know the install's App Attest key, even after the SDK registered it once more | Treat it as `device_not_verified`; report it if it repeats |
| `platforms_invalid` | No platform, more than 10, one twice, or an id that is not 1 to 64 letters, digits, `.`, `_` or `-` | Your code |
| `platform_unavailable` | A platform is not enabled for your app, is unknown, is not one `verify` runs, or (with a test key) is not `zktls-demo`; `message` names it | Your configuration |
| `reference_invalid` | The reference is not 1 to 128 letters, digits, `.`, `_` or `-` | Your code |
| `token_invalid` | The token from `POST /partner/verification-tokens` is unknown, already used, older than 15 minutes, or for another app. A start refused after the token was read, such as with `platform_unavailable`, uses it up too | Your server makes a new one |
| `limit_reached` | An hourly limit: 10 verifications per install with a live key (30 with a test key), or your app's limit (1,000 by default with a live key, 100 with a test key). Also our request rate limit, and the limit on device checks for one app or one network | The user starts again later. Contact us if your app's limit is too low |
| `account_inactive` | Your team cannot start verifications: its trial is used up, its subscription has lapsed, or it has not accepted the terms of service; `message` says which. Test-key verifications do not count against a trial | Sign in to the dashboard and accept the terms, or contact us about your plan |
| `request_invalid` | Our backend could not read the SDK's request (413 for a body over 64 KiB). Not expected from your code, unless it passes a reference or platform ids over 64 KiB in all | Update the SDK; report it with the message if it repeats |
| `unavailable` | Our backend could not start the verification just now, on our side (a 5xx with a refusal body; one without, such as a gateway's page, is `Transport("our backend answered <status>: <call>")`) | The user starts again in a little while; report it if it lasts |
| `not_configured` | `Zktls.verify` was called before `Zktls.configure(appKey:)`. On Android, also a live key in a build of the SDK with no Play Integrity project number compiled in, which could never check a device; our release gate stops such a build from shipping. Thrown by the facade before anything starts; no screen is shown | Your code: call `configure` when your app launches |

`platforms_invalid`, `platform_unavailable`, `reference_invalid` and `token_invalid` come from your code or
your setup, so fix them before you release; `account_inactive` comes from your account. Every code but
`device_not_verified` shows "Verification isn't available right now".

Log the variant and, for `Transport` and `Policy`, its text; for `Refused`, its code. Never log a handle or a cookie. A printed
`SessionConfig` (Kotlin's `toString()`, Swift's `print` and `dump`) shows only `baseUrl`, `profileId`
and `policyId`, never the app credential.

## A result that did not arrive

`runTree` posts the run's result to `result_url` once, and never again. When it does not arrive, the run
still returns its summary, with `delivered` false and `deliveryError` saying why:

| `deliveryError` | Meaning |
|---|---|
| `the result URL is unreachable` | The phone could not reach it |
| `the result URL answered <status>` | Our backend refused it: 401, the token is wrong or expired; 409, the attested read was already submitted; 413, the result is too large; 422, the claim did not verify |
| `the run's result is over the result URL's 5 MB cap` / `the run's result is over the result URL's 32 MB cap` | The pack collected more than a result may carry; it was not sent |
| `gzip: <reason>` / `header <name> may not go to the result URL` | A bug; report it |

The user's data is not kept on the phone, so a result that did not arrive is a new run.

For a pack that attests, the phone posts nothing once the attester has the run: `handedOff` is true,
`delivered` false and `deliveryError` empty. The attester posts the result, retrying on its own, and
your backend's deadline for the run tells you if it never arrives
([backend-tree-results.md](backend-tree-results.md#a-result-from-the-attester)).

## How each platform ended in `verify`

Once our backend has started a verification, `verify` returns a `VerifyOutcome` however its platforms
end, never their data: each platform's result reaches your server from ours, in its own webhook.
`PlatformOutcome.status` is:

| `status` | Meaning |
|---|---|
| `Done` | The platform's run reached us: the attester took its read (or its result was delivered). Your server gets its `platform.finished` webhook when the result arrives |
| `Failed` | The run failed; `reason` says why, and your server is told too. The next platform still runs: each counts on its own |
| `NotStarted` | The run never ran: the user declined the intro, chose "Stop here" between platforms, or closed a platform's sign-in page or declined its sign-in notice, which ends that platform and every later one |

A platform the SDK handed to the attester is `Done`. If its result then never reaches us, our backend
fails the run about 2 hours after the verification started, with the error code `no_result`, and your
server's `platform.finished` webhook says so. That needs the app to have reported the hand-off, which the
SDK does at the end of the flow: if the app was killed or offline before then, and no result arrives, the
platform ends as `not_started` in `verification.finished`, with no `platform.finished`.

A failed platform's `reason` is one of these, and only these; the SDK also reports it to our backend,
which sends it to your server as the run's error code:

| `reason` | Meaning |
|---|---|
| `platform_failed` | The platform's own steps failed, for example the sign-in did not finish or the account has no such data |
| `upload_refused` | The attester refused the run's read (the `Policy` message `attester refused the upload: <reason>` for `runTree`) |
| `bundles_unavailable` | The trust or policy bundle could not be fetched, or did not verify (not signed with the keys the SDK pins, or older than one it already accepted); the next platform fetches them again |
| `delivery_failed` | A result the phone posts did not reach us |
| `network` | The connection, or the platform's reply on it, broke off (`Transport`, `SessionLost`, `Truncated`, `ExtraResponse`, `Reordered`) |
| `navigation_refused` | The page went where the platform's pack does not allow, or needed something where it may not run (`navigation_refused: <host>` or `origin_refused: <host>`) |
| `not_logged_in` | The sign-in left no cookie to read the platform with (`NotLoggedIn`) |
| `configuration` | The SDK refused the platform's pack, the policy, or the run's settings (any other `Policy` message, above) |
| `internal` | Anything else; report it |

## A proof that was not accepted

Once the SDK has built the proof's statement, `prove` returns a `ProofReport` rather than throwing,
unless it is cancelled or the verifier cannot be reached. When `accepted` is `false`, `verdict` says why:

| `verdict` starts with | Meaning | Start again? |
|---|---|---|
| `REJECTED` | `REJECTED PredicateRejected`: the statement is false for this account (for example, no such payment); the SDK learns this on the phone and sends nothing. Any other reason: the verifier checked the proof and refused it, or refused the evidence | For `PredicateRejected`, only once something has changed; otherwise once, and report it if it repeats |
| `FAILED` | No verdict: the proof session broke off after the verifier was reached, or did not finish within 120 seconds, counting the time the phone slept | When they choose |

`claim()` refuses both, with `Policy("proof was not accepted: <verdict>")`.

## Reading the text of `Transport` and `Policy`

```swift
} catch SdkError.Policy(let text) where text.hasPrefix("trust bundle:") {
    refetchTrustBundle()                           // yours; then the user starts again
} catch let e as SdkError {
    show(message(for: e))
}
```

```kotlin
} catch (e: SdkException.Policy) {
    if (e.v1.startsWith("trust bundle:")) refetchTrustBundle()   // e.v1, not e.message ("v1=<text>")
    show(message(e))
}
```
