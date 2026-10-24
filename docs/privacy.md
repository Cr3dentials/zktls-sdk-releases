# Privacy: what the SDK sends, keeps and declares

This page is for whoever fills in your app's App Privacy answers (App Store Connect) and Data safety
form (Google Play). It covers only what the zkTLS SDK itself does. Add what your app does.

*Reviewed by Cr3dentials on 21 October 2026, before the sections on `verify` were added. Counsel's review
is pending.*

## What leaves the device

`verify` sends the first six rows to our backend, the first five before any platform runs and the sixth
when the user leaves the flow; it then fetches the bundles and each platform's pack, and each platform
goes through the front door and the attester, as the rows after them say. Proof mode sends none of the
first six.

| Data | Sent to | Why | Kept |
|---|---|---|---|
| Your app key, `zk_live_…` or `zk_test_…` | Our backend | Names your app, and whether the verification is a test | Not user data |
| The install's id: on iOS, the id of the App Attest key the SDK made for your app on this device (with a test key on a device without App Attest, a random id the SDK made); on Android, a random id the SDK made | Our backend | Counts the install's verifications each hour, and on iOS finds its App Attest key. Our backend derives the run's `user_id_hash` from it and your app's id, so the front door counts the install as a user | With the verification's record. Your server's fetch of the verification does not return it |
| The platform ids and your reference | Our backend | Which platforms to run; the reference comes back to your server in every webhook | With the verification's record. The reference is yours: it must hold no personal data |
| iOS, a live key: once per install, the App Attest attestation of the SDK's key (Apple's certificate chain for it, its public key, a hash of your app's identifier, and Apple's receipt); then, with each start, an assertion (a signature over the start's request, and a counter) | Our backend. To make the attestation, iOS has Apple's App Attest service certify the key ([below](#the-device-check)) | Shows that the start comes from your registered app on a genuine Apple device, for this request, and not a replay | The key's public key and its counter, to check the install's later starts |
| Android, a live key: with each start, a Play Integrity token bound to the SHA-256 of the start's request | Google Play services makes it, with Google ([below](#the-device-check)); then our backend, which has Google decode it | Shows that the start comes from your registered app, installed from Google Play, on a device that meets Google's device integrity check, for this request | Our backend keeps the token's hash for 10 minutes, to accept it once |
| How each platform ended: done, failed (with its reason) or not started | Our backend, when the user leaves the flow | Ends the verification, and the webhooks say so | With the verification's record |
| `verify`'s requests for the trust bundle, the policy bundle and each platform's pack (only the pack's carries a credential: the app credential) | The hosts that serve them: our front door for the trust bundle and the packs, and Google Cloud Storage for the policy bundle | The SDK checks each against keys it pins before anything runs | No user data. The hosts see the phone's IP address, as for any request |
| The app credential: in proof mode yours; with `verify`, the one our backend gives the SDK for your app | The front door (`base_url`) | Identifies your app and its quota | Not user data |
| `user_id_hash`: in proof mode your hash of your own user id; with `verify`, the hash our backend derives from the install's id | The front door | Per-user quota and abuse limits | Only in the front door's memory, as a counter for a one-minute window. Never written to disk or logged |
| `client_region`, the user's country if you pass one | The front door | Ranks the cells when the front door cannot place the phone itself | Not logged or kept |
| The phone's IP address, and the country the front door infers from it | The front door | Ranks the cells, and chooses where a pack that attests reads the platform from ([below](#packs-that-attest)) | The front door's request log keeps the IP address and the user agent for 30 days. For a pack that attests, the session's log line keeps the country, also for 30 days |
| The request to your user's institution, carrying their sign-in cookie | The institution, over the phone's own connection | Fetches the one record being proven | The cookie's bytes reach the capture enclave only XORed with a stream that only the second enclave receives, so neither can read them. The service is designed to run the two on different clouds under different operators; the SDK does not check this |
| The institution's reply | Both enclaves, each holding half | The proof is computed over it | Neither enclave sees the plaintext. It stays on the phone and is deleted when the proof ends |
| The proof, and the statement's public outputs (the proven fact) | The verifier, over TLS 1.3 authenticated against the trust bundle | Checks the proof and signs the claim | Not kept: the verifier returns the claim and stores nothing |
| The signed claim | Your app, which sends it to your backend | What you asked the user to prove | Your app decides |
| Each platform's result: what its pack reads, and the figures the attester signs | The run's result URL, from the phone or, for a pack that attests, from the attester: with `verify`, our backend's, which keeps it with the verification and sends it to your server; in the lab, the one issued for the run ([integration-packs.md](integration-packs.md)) | What your app asked the user to share | Our backend keeps it with the verification, for your server; your server decides what it keeps |
| For a pack that attests: the attested request with the user's session in it, the run's observed result, your nonce, `resultUrl` and `resultToken` | The attester, an enclave, over TLS 1.3 authenticated against the trust bundle | The attester reads the platform's summary itself, signs the figures, and posts the run's result to the result URL: with `verify`, our backend's | Only in the attester's memory, for the run (at most 4 hours). Never logged or stored |

`network_key` never leaves the device. Any stable label works, so there is no need to read the Wi-Fi
network's name for it, which would take a location permission.

In proof mode, the user's password never reaches the SDK. The user types it into the institution's own
sign-in page, and the SDK reads no form field and injects no script. On iOS the page runs in a new
non-persistent data store for each login. On Android the SDK clears the WebView's cookies, web
storage and cache before and after the login. The cookies the SDK reads are wiped from its memory
when the capture ends. A platform's page in `verify` runs the SDK's bridge and the pack's script:
[what confines our script](#what-confines-our-script).

### The device check

A live key's `verify` starts only from your registered app on a genuine device. A test key skips this
section's checks.

- **iOS: App Attest.** The first live verification on an install has the Secure Enclave make a key for
  your app, which never leaves the device, and asks Apple's App Attest service to certify it: that call
  is between the device and Apple, as for any app that uses App Attest
  ([Apple's description](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)).
  The SDK sends the attestation to our backend once, and an assertion, which carries no user data, with
  each start.
- **Android: Play Integrity.** With each live start, the SDK asks Google Play services for a token bound to
  the hash of the start's request. To make it, Google Play services sends Google the request hash and
  information about your app (its package name, version and signing certificate), its Google Play licence
  for the accounts on the device, and the device (an attestation of it from Google Play services). Google
  uses it to check the app and the device, encrypts it, does not transfer it to third parties, and deletes
  it after a fixed retention period. Google lists this for your Data safety form in
  [how the Play Integrity API handles data](https://developer.android.com/google/play/integrity/terms#data-safety).
  Google collects environment details (other apps that could capture the screen or control the device,
  and Play Protect's status) only for an app opted in to them in the Play Console; the SDK does not use
  them. Our backend sends the token to Google to decode, and checks the verdict.

The SDK keeps on the device the install's id (iOS: the App Attest key's id, and whether our backend
registered it, or, with a test key on a device without App Attest, a random id; Android: the random id), in your app's `UserDefaults` and `SharedPreferences`, under keys
and files that start `ai.zktls.`. They go when your app is deleted.

### Packs that attest

The attester reads the platform through a proxy provider, Oxylabs, which is our subprocessor. The read
leaves from a consumer (residential or mobile) address in the user's own country, as the front door
infers it from the phone's IP address, or from a default country when it cannot. The attester's TLS
session with the platform runs inside the proxy's tunnel, so the proxy relays bytes it cannot read: it
sees the platform's host name, when, and how much. The platform sees the proxy's address, not the
phone's. If the tunnel cannot be opened, the attester connects from our cell directly.

For each run, the attester's log keeps the session id, the country it read from, the platform's HTTP
statuses and the timings, for 30 days. It never logs a session value or a collected figure.

## What confines our script

This applies to every platform `verify` runs, and to platform packs in the lab (`runTree`,
[integration-packs.md](integration-packs.md)), not to the proof-mode login above. A pack's run adds code to the platform's own signed-in page: the SDK's bridge, which
reads the platform's endpoints with the user's session, and the script the pack may carry. What holds
them:

- **Only on the platform's pages.** The bridge defines nothing on a page off the platform's own
  `https` domains, on a third-party sign-in page, or in an iframe. Each request the SDK sends the
  bridge carries a random 128-bit id, and the SDK takes one reply to it, from the main frame on the
  platform's domains. A message from anywhere else, or a reply to no pending request, is dropped; the
  run's log counts them at close, without their content. Where the page itself may go is in
  [integration-packs.md](integration-packs.md#where-the-page-may-go).
- **Session values are handed out only on the platform's pages.** A cookie the pack declares is
  handed to the bridge only while the page is on that cookie's own host. The script may then send it,
  or a header captured from the page's own requests, in its `api.fetch` requests to any host on the
  platform's domains. A request that is redirected off them is refused only where it lands: it has
  already reached the other host, with whatever headers the browser forwards on a redirect, though the
  script never sees the reply.
- **A script's result may not carry a session value.** The result is refused if it holds a value the
  script was handed in that call (a cookie, a stored value, or a captured header whose name looks
  secret, such as `Authorization`, `Cookie` or one with `token`, `csrf` or `session` in it) as is,
  URL-encoded or in base64, where that copy is 8 characters or longer. This closes cheap leaks only;
  our review of each script against the data its pack declares remains the guard.

What stays open:

- The bridge and the pack's script run in the page's own JavaScript world, so the platform's scripts
  and ours can see each other.
- For the length of a script's call, the cookies its pack declares, `HttpOnly` ones included, are
  held in that world. The platform's own scripts share it, so they could reach those values, for
  example by replacing a built-in function our script calls.
- The page's own requests are not fenced: its `fetch`, images, beacons and WebSockets, and the forms
  it posts into an iframe, go wherever the platform's code sends them, as in a browser. The SDK does
  not block requests by host, so it does not claim that no data can leave the page.
- What keeps our script to its platform is that the SDK runs only a pack we signed, and we review a
  pack's script before we sign it.

How the run's web data is kept apart from your app's, as `TreeSummary.isolation` reports it:

- **iOS (`ephemeral`):** each run has a new non-persistent `WKWebsiteDataStore`. It cannot see your
  app's cookies and leaves none behind.
- **Android System WebView 123 and later (`profile`):** each run has its own WebView profile,
  `zktls-run-<id>`, never shared with your app's WebViews. WebView will not delete a profile the
  running app process has used, so at close the SDK wipes the profile's cookies, its storage
  (localStorage and IndexedDB) and the Cache Storage of each origin the page visited, and deletes the
  profile when a run begins in a later process of your app. Until then the emptied profile, about
  280 KB, stays on disk, one for each run in that process. Three things stay in it until it is
  deleted: the Cache Storage of iframes at origins the page itself never visited, and of every
  cross-site iframe (kept under the page's site, so not reached even at an origin the page visited);
  and service-worker registrations.
- **Older Android WebViews (`shared`):** Android keeps one WebView store for your app's whole process.
  The SDK wipes it (cookies, web storage, cache, HTTP auth and saved form data) before the page first
  loads, waiting until the cookies are gone, and again at close, when it also clears the Cache Storage
  of each origin the page visited. That wipe clears your own WebViews' data too, so do not run a pack
  while it matters. What this leaves open:
  - while the run is open, your app's WebViews share the store with it;
  - a process killed mid-run leaves the session on disk until the next run's wipe, and the Cache
    Storage that run left is cleared only at the close of a later run whose page visits the same
    origin;
  - the Cache Storage of iframes at origins the page itself never visited, and of every cross-site
    iframe (kept under the page's site, so not reached even at an origin the page visited), and
    service-worker registrations, stay in your app's store: the shared store is never deleted, so
    nothing removes them.

## iOS: the privacy manifest

The SDK carries `PrivacyInfo.xcprivacy`. Xcode includes it in your app, as
`ZktlsSDK_ZktlsSDK.bundle` with Swift Package Manager or as `ZktlsSDK_Privacy.bundle` with
CocoaPods, and adds it to your privacy report. It declares:

- **No tracking**, and no tracking domains.
- **Collected: User ID** (`user_id_hash`), linked to the user, not used for tracking, purpose App
  Functionality.
- **Collected: Coarse Location**, the country the front door infers from the IP address and keeps in
  its logs for 30 days. Linked to the user through the session, not used for tracking, purpose App
  Functionality.
- **Collected: User ID** covers `verify` too: there, `user_id_hash` comes from the install's id.
- **Collected: Device ID**, new in 2.0.0 (`NSPrivacyCollectedDataTypeDeviceID`): `verify`'s install
  id, which our backend keeps with each verification's record. Linked to the user, not used for
  tracking, purpose App Functionality.
- **Required-reason APIs**: file timestamp APIs, reason `C617.1` (metadata of files inside the
  app's container), reached through Rust's `std` and `tokio` crates, which the SDK's release tests read
  from the core's binary; and, new in 2.0.0, user defaults, reason `CA92.1` (your app's own defaults,
  where the SDK's Swift code keeps the install's id).

## App Store Connect: App Privacy answers for the SDK's part

- **Data used to track you:** none.
- **Data linked to you:** Identifiers → User ID; Identifiers → Device ID (`verify`: the install's id,
  which our backend keeps with each verification's record); and Location → Coarse Location. None is used
  for tracking, and all are for App Functionality.
- The sign-in cookie and the institution's reply are processed on the device, and in split form
  that no single party can read. They are not "collected" in Apple's sense.
- Beyond the install's id (Device ID, above), App Attest's attestation and assertions are about your
  app and the device's key, not the user, and carry no user data.
- For a pack that attests, the user's session goes to the attester, which uses it for the one run and
  keeps nothing. We propose it is not "collected" in Apple's sense, which counts data kept longer than
  it takes to serve the request.
- Each platform's result (what its pack reads, and the figures the attester signs) is collected by
  your app: with `verify` it goes to our backend, which keeps it with the verification and sends it to
  your server; in the lab, to the run's result URL. Declare the data types its output holds.

## Android: permissions and the foreground service

The SDK's manifest merges these into your app. Each is here because your Play Console answers must
account for it:

| Entry | Why |
|---|---|
| `INTERNET` | Connections to our backend, the front door, the hosts of the trust and policy bundles, the enclaves (the attester among them), the verifier, and the platform or institution |
| `ACCESS_NETWORK_STATE` | Watching the default network, to reconnect at once on a Wi-Fi to cellular handover |
| `FOREGROUND_SERVICE` | `ZkTlsSessionService`, which keeps a verification's hand-off to the attester and its report of how the platforms ended (up to 10 s), or in proof mode the capture and proof, alive for the seconds they take if the user leaves your app |
| `shortService` | The service's foreground type: a short, user-started task that must finish. Android caps it at about three minutes |

The SDK asks for no runtime permission. `shortService` needs no type-specific permission: Android
defines none, and there is no `FOREGROUND_SERVICE_SHORT_SERVICE`. Play Console's foreground-service
declaration may still ask about `shortService`: if it does, describe it as a verification the user
starts, which hands its result to our service in seconds and is cancelled if interrupted, and link a
short video of the flow. The SDK does not request `POST_NOTIFICATIONS`. Without it, on Android 13 and later, the service still runs, and
its notification appears only in the task manager.

## Google Play: Data safety answers for the SDK's part

Using Google's definitions (collected means sent off the device):

| Data type | Collected | Shared | Processed ephemerally | Required | Purposes |
|---|---|---|---|---|---|
| Personal info → User IDs (`user_id_hash`) | Yes | No: the zkTLS service processes it for you as a service provider | Yes: held only in the front door's memory, for a one-minute window | Yes | App functionality; Fraud prevention, security and compliance |
| Financial info → Other financial info (the proven fact, sent to the verifier) | Yes | No: as above | Yes: the verifier returns the claim and keeps nothing | Yes | App functionality |
| Location → Approximate location (the country the front door infers from the IP address, and the country you pass as `client_region`) | Yes | No: as above | No: the inferred country is kept in the front door's logs for 30 days. `client_region` is not kept | Yes | App functionality; Fraud prevention, security and compliance |
| Personal info → Other info (for a pack that attests, the user's session with the platform) | Yes | No: as above. The proxy provider relays it encrypted and cannot read it | Yes: held only in the attester's memory, for the run | Yes, for a pack that attests | App functionality |
| Device or other IDs (`verify`: the install's id, a random id the SDK keeps) | Yes | No: as above | No: kept with the verification's record | Yes, for `verify` | App functionality; Fraud prevention, security and compliance |

With `verify`, each platform's result is collected too, and not processed ephemerally: our backend keeps
it with the verification, for your server. Declare the data types its output holds, for App
functionality.

With a live key, Play Integrity also has Google collect the data in [the device check](#the-device-check),
for Google's own check of your app and the device. Google's description is meant for your Data safety
form, and Google leaves the answer to you.

The sign-in cookie and the institution's reply in a capture cross the two capture enclaves only in
split form, which neither enclave can read alone. We propose they are not declared, under Google's
end-to-end encryption rule: data sent off the device that is "unreadable by you or anyone other than
the sender and recipient as a result of end-to-end encryption does not need to be disclosed". That
holds only if no one, us included, holds both halves: it rests on the two enclaves being run by
different operators, which is the service's design and which the SDK does not check. That nothing
keeps them is not enough on its own: Google asks you to include ephemerally processed data in the
form. The rule does not cover a pack that attests: the attester reads the session inside its enclave,
so the table declares it.

- **Data is encrypted in transit:** yes. The requests to our backend, the front door and the cells it
  offers (HTTPS, through the platform's own HTTP stack), the connections to the enclaves, the attester and
  the verifier (TLS 1.3, each authenticated against the trust bundle), the connection to the
  institution (its own TLS), and the attester's connection to the platform (its own TLS, inside the
  proxy's tunnel) are all encrypted. The proof connection carries the enclaves' signed capture
  evidence (commitments to the record, the institution's certificate names, and the request with its
  cookie removed), the proof's messages, and the verdict, nullifier and claim coming back; never the
  record's plaintext or the cookies.
- **Users can ask for their data to be deleted:** your policy applies to your data. The zkTLS service
  keeps the quota counter for a minute, in memory; a session's allocation record, which names the
  country, until its one-minute token expires, after which the database deletes it within a day; and
  the logs that hold the IP address and the country for 30 days. With `verify`, our backend also keeps
  each verification's record (the install's id, your reference, the platforms, and each platform's
  result); your server's fetch of it returns all but the install's id.
