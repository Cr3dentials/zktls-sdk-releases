# Privacy: what the SDK sends, keeps and declares

This page is for whoever fills in your app's App Privacy answers (App Store Connect) and Data safety
form (Google Play). It covers only what the zkTLS SDK itself does. Add what your app does.

*Reviewed by Cr3dentials on 21 October 2026. Counsel's review is pending.*

## What leaves the device

| Data | Sent to | Why | Kept |
|---|---|---|---|
| Your app credential | The front door (`base_url`) | Identifies your app and its quota | Not user data |
| `user_id_hash`, your hash of your own user id | The front door | Per-user quota and abuse limits | Only in the front door's memory, as a counter for a one-minute window. Never written to disk or logged |
| `client_region`, the user's country if you pass one | The front door | Ranks the cells when the front door cannot place the phone itself | Not logged or kept |
| The phone's IP address, and the country the front door infers from it | The front door | Ranks the cells, and chooses where a pack that attests reads the platform from ([below](#packs-that-attest)) | The front door's request log keeps the IP address and the user agent for 30 days. For a pack that attests, the session's log line keeps the country, also for 30 days |
| The request to your user's institution, carrying their sign-in cookie | The institution, over the phone's own connection | Fetches the one record being proven | The cookie's bytes reach the capture enclave only XORed with a stream that only the second enclave receives, so neither can read them. The service is designed to run the two on different clouds under different operators; the SDK does not check this |
| The institution's reply | Both enclaves, each holding half | The proof is computed over it | Neither enclave sees the plaintext. It stays on the phone and is deleted when the proof ends |
| The proof, and the statement's public outputs (the proven fact) | The verifier, over TLS 1.3 authenticated against the trust bundle | Checks the proof and signs the claim | Not kept: the verifier returns the claim and stores nothing |
| The signed claim | Your app, which sends it to your backend | What you asked the user to prove | Your app decides |
| A platform pack's result: what its observed sources collected | Your backend's `resultUrl`, from the phone ([integration-packs.md](integration-packs.md)) | What your app asked the user to share | Your backend decides |
| For a pack that attests: the attested request with the user's session in it, the run's observed result, your nonce, `resultUrl` and `resultToken` | The attester, an enclave, over TLS 1.3 authenticated against the trust bundle | The attester reads the platform's summary itself, signs the figures, and posts the run's result to your backend | Only in the attester's memory, for the run (at most 4 hours). Never logged or stored |

`network_key` never leaves the device. Any stable label works, so there is no need to read the Wi-Fi
network's name for it, which would take a location permission.

The user's password never reaches the SDK. The user types it into the institution's own sign-in
page, and the SDK reads no form field and injects no script. On iOS the page runs in a new
non-persistent data store for each login. On Android the SDK clears the WebView's cookies, web
storage and cache before and after the login. The cookies the SDK reads are wiped from its memory
when the capture ends.

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

This applies to platform packs (`runTree`, [integration-packs.md](integration-packs.md)), not to the
login above. A pack's run adds code to the platform's own signed-in page: the SDK's bridge, which
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
- **Required-reason APIs**: file timestamp APIs, reason `C617.1` (metadata of files inside the
  app's container), reached through Rust's `std` and `tokio` crates. The SDK's release tests read
  this list from the binary.

## App Store Connect: App Privacy answers for the SDK's part

- **Data used to track you:** none.
- **Data linked to you:** Identifiers → User ID, and Location → Coarse Location, both for App
  Functionality.
- The sign-in cookie and the institution's reply are processed on the device, and in split form
  that no single party can read. They are not "collected" in Apple's sense.
- For a pack that attests, the user's session goes to the attester, which uses it for the one run and
  keeps nothing. We propose it is not "collected" in Apple's sense, which counts data kept longer than
  it takes to serve the request.
- What a pack's result carries to your backend is collected by your app: declare the data types its
  output holds.

## Android: permissions and the foreground service

The SDK's manifest merges these into your app. Each is here because your Play Console answers must
account for it:

| Entry | Why |
|---|---|
| `INTERNET` | Connections to the front door, the enclaves, the verifier and the institution |
| `ACCESS_NETWORK_STATE` | Watching the default network, to reconnect at once on a Wi-Fi to cellular handover |
| `FOREGROUND_SERVICE` | `ZkTlsSessionService`, which keeps the capture and proof alive for the seconds they take if the user leaves your app |
| `shortService` | The service's foreground type: a short, user-started task that must finish. Android caps it at about three minutes |

The SDK asks for no runtime permission. `shortService` needs no type-specific permission: Android
defines none, and there is no `FOREGROUND_SERVICE_SHORT_SERVICE`. Play Console's foreground-service
declaration may still ask about `shortService`: if it does, describe it as a proof the user starts,
which takes seconds and is cancelled if interrupted, and link a short video of the flow. The SDK does
not request `POST_NOTIFICATIONS`. Without it, on Android 13 and later, the service still runs, and
its notification appears only in the task manager.

## Google Play: Data safety answers for the SDK's part

Using Google's definitions (collected means sent off the device):

| Data type | Collected | Shared | Processed ephemerally | Required | Purposes |
|---|---|---|---|---|---|
| Personal info → User IDs (`user_id_hash`) | Yes | No: the zkTLS service processes it for you as a service provider | Yes: held only in the front door's memory, for a one-minute window | Yes | App functionality; Fraud prevention, security and compliance |
| Financial info → Other financial info (the proven fact, sent to the verifier) | Yes | No: as above | Yes: the verifier returns the claim and keeps nothing | Yes | App functionality |
| Location → Approximate location (the country the front door infers from the IP address, and the country you pass as `client_region`) | Yes | No: as above | No: the inferred country is kept in the front door's logs for 30 days. `client_region` is not kept | Yes | App functionality; Fraud prevention, security and compliance |
| Personal info → Other info (for a pack that attests, the user's session with the platform) | Yes | No: as above. The proxy provider relays it encrypted and cannot read it | Yes: held only in the attester's memory, for the run | Yes, for a pack that attests | App functionality |

The sign-in cookie and the institution's reply in a capture cross the two capture enclaves only in
split form, which neither enclave can read alone. We propose they are not declared, under Google's
end-to-end encryption rule: data sent off the device that is "unreadable by you or anyone other than
the sender and recipient as a result of end-to-end encryption does not need to be disclosed". That
holds only if no one, us included, holds both halves: it rests on the two enclaves being run by
different operators, which is the service's design and which the SDK does not check. That nothing
keeps them is not enough on its own: Google asks you to include ephemerally processed data in the
form. The rule does not cover a pack that attests: the attester reads the session inside its enclave,
so the table declares it.

- **Data is encrypted in transit:** yes. The requests to the front door and the cells it offers
  (HTTPS, through the platform's own HTTP stack), the connections to the enclaves, the attester and
  the verifier (TLS 1.3, each authenticated against the trust bundle), the connection to the
  institution (its own TLS), and the attester's connection to the platform (its own TLS, inside the
  proxy's tunnel) are all encrypted. The proof connection carries the enclaves' signed capture
  evidence (commitments to the record, the institution's certificate names, and the request with its
  cookie removed), the proof's messages, and the verdict, nullifier and claim coming back; never the
  record's plaintext or the cookies.
- **Users can ask for their data to be deleted:** your policy applies to your data. The zkTLS service
  keeps the quota counter for a minute, in memory; a session's allocation record, which names the
  country, until its one-minute token expires, after which the database deletes it within a day; and
  the logs that hold the IP address and the country for 30 days.
