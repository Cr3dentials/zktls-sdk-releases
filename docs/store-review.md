# Store review: the login WebView and its cookies

Your app shows a bank's (or another institution's) own sign-in page, and the zkTLS SDK reads that
page's sign-in cookies. Reviewers ask about this, so this page gives you the facts and the words.

## What the user sees

Before the sign-in page opens, the SDK's default presenter shows this, with the institution's domains
filled in:

> **Sign in to bank.example**
>
> To prove this, the app opens bank.example's own sign-in page. After you sign in, it reads the
> sign-in cookies for bank.example on this device and uses them once, to fetch the record you are
> proving. They are not stored, and they are deleted when the proof ends. The app receives only the
> proven result, not your account data or your password.
>
> [Not now] [Continue]

"Not now", Back, or a tap outside the dialog opens nothing and reads nothing. You may translate the
text by passing your own `LoginDisclosure`; keep every fact it states. If you replace
`WebViewLoginPresenter` with your own presenter, your presenter must show an equivalent disclosure
before it presents the page.

## What is read, and what is not

- **Only the cookies of the domains the signed profile declares**, and only after the user has
  signed in on the institution's own page. The SDK filters them twice, in Swift or Kotlin and again
  in its Rust core.
- **Never the password or any form field.** In `login`, the SDK injects no JavaScript and adds no
  JavaScript interface. The page runs the institution's own scripts, as in a browser. (A platform
  pack's run differs: [what confines our script](privacy.md#what-confines-our-script).)
- **iOS:** the page runs in a new non-persistent `WKWebsiteDataStore` for each login. It cannot see
  your app's cookies and leaves none behind.
- **Android:** `CookieManager`, web storage and the WebView cache are shared by the whole process. The
  SDK clears all three before and after the login, so the institution's cookies and stored data do
  not outlive it; do not run a login while your own WebViews' cookies or stored data matter.

## Where the cookies go

*Reviewed by Cr3dentials on 21 October 2026. Counsel's review is pending.*

In a capture (`login`, then `capture`):

1. From the platform's cookie store into the SDK's Rust core in one call. They are held in an
   opaque handle your app cannot read, and never logged.
2. Into one request to the institution, sent over the phone's own network connection. The TLS
   records are built with the help of the capture enclave. The cookie's bytes reach that enclave only
   XORed with a random stream that only a second enclave receives, so neither can read them. The
   service is designed to run the two enclaves on different clouds under different operators; the
   SDK does not check this.
3. Nowhere else. When the capture ends, the SDK wipes them from memory. The one exception is a
   capture that ends with `SessionLost`: the cookies then wait for the new capture the user may start,
   and are wiped when it ends, or once nothing holds them any more: cancelling the session or
   releasing the client lets go of them (on Android the memory is wiped when the garbage collector
   frees it).

In a platform pack that attests (`runTree`, [integration-packs.md](integration-packs.md#a-pack-that-attests-detached)):

1. When the pack's steps have succeeded, the SDK takes the session the attested request needs from
   the page, closes it, and seals that session into one upload.
2. To one enclave, the attester, over TLS 1.3 authenticated against the trust bundle. The attester
   holds the session only in memory, uses it to read the platform's one summary, and drops it when
   the run ends, within 4 hours. It never logs or stores it.
3. The attester reads the platform through a proxy provider, from an address in the user's own
   country ([privacy.md](privacy.md#packs-that-attest)). Its TLS session with the platform runs
   inside the proxy's tunnel, so the proxy cannot read the session.

[privacy.md](privacy.md) lists everything that leaves the device.

## The sign-in screen

When your app runs a platform pack (`runTree`, [integration-packs.md](integration-packs.md)), the SDK
shows the platform's page in a screen of its own:

- **The host bar.** A thin bar above the page shows a padlock, the host of the page the user is on
  (never its path), and a Close button. The host follows every page the user reaches, so they can
  check which site's page they are on. A host the SDK refuses never appears: its
  page never loads, and the run ends
  ([where the page may go](integration-packs.md#where-the-page-may-go)). Close cancels the run, as
  Back on Android and a swipe down on iOS do. The bar has the SDK's own plain style; it cannot be
  themed.
- **Screen capture.**
  - **Android:** the SDK's WebView window is marked `FLAG_SECURE`, so screenshots, screen recordings
    and the recent-apps thumbnail come out black. The page's JavaScript alerts, confirmations and
    prompts are never shown, on either platform: each is answered at once (a confirmation as no).
    Not covered: the date and select pickers the WebView opens, and the disclosure shown before the
    run, which holds only the fixed text your app passes.
  - **iOS** cannot block screenshots. While the screen is recorded or mirrored, and whenever your app
    stops being active (so before iOS takes the app-switcher snapshot), the SDK covers the page with a
    plain view that reads "The sign-in is hidden while the screen is recorded."
- **Permissions are denied.** On Android every permission the page asks for is denied: camera,
  microphone, location and any other. On iOS 15 and later the camera, microphone and motion are
  denied, and the page's location calls always fail. On iOS 14 the location calls fail too, but the
  system prompt for the camera or microphone may still appear.
- **Downloads are refused.** On Android none starts; on iOS the download is cancelled, and the run
  goes on.
- **Settings the SDK fixes:** no file or content access; no mixed content; Safe Browsing on
  (Android) and the fraudulent-website warning on (iOS); link previews off (iOS); remote debugging
  of the page only in your app's debug builds. On Android the WebView debugging flag is process-wide,
  so a release build of your app that turns it on for its own WebViews makes this page inspectable
  too; and in a debuggable build the SDK turns it on for the run and off when the run closes, for
  every WebView in your app's process, so turn it on again after a run if your own WebViews need it.
- **Left on:** the system password manager and autofill. They are the user's own, and sign-in needs
  them.

## Notes for App Review

Paste into App Store Connect → App Review Information → Notes, filling in the brackets:

> This app uses the zkTLS SDK to let the user prove [the fact, e.g. "a completed transfer"] from
> their own [institution] account. When the user taps [button], the app first shows a disclosure,
> then opens [institution]'s own sign-in page in an in-app browser. The user signs in on that page;
> the app never sees or stores their password. The SDK uses the resulting session cookie once, to
> fetch the one record being proven directly from [institution] over the device's own connection,
> and then deletes it. The app receives only the proven result.
>
> Network: the SDK opens a TLS connection to [institution]'s HTTPS server, and connections to the
> zkTLS verification service: HTTPS requests to its front door at [your base_url host] and, to
> find the nearest, to the cells it offers; WebSocket-over-TLS connections to the enclave hosts it
> assigns to each session; and a TLS 1.3 connection to the verifier it assigns to the session. It
> uses no VPN, packet tunnel, or background network entitlement.
>
> [For a platform pack that attests, replace the paragraph above with: the SDK opens the platform's
> own pages in an in-app browser, then one TLS 1.3 connection to the zkTLS enclave the front door at
> [your base_url host] assigns to the run, which reads the platform's summary with the user's session
> and posts the result to [your backend's host]. It uses no VPN, packet tunnel, or background network
> entitlement.]
>
> Demo account: [credentials for a test account at the institution, or the review build's test profile].

Give the reviewer a working demo account. A login the reviewer cannot complete is the most likely
rejection.

## What this answers

**Apple.**
- Guideline 5.1.1, Data Collection and Storage: consent is given before access, and only what the
  feature needs is read.
- 5.1.2, Data Use and Sharing: the cookie serves one request the user asked for and is not shared.
- 5.2.2, Third-Party Sites/Services: you must be permitted, under the institution's terms, to
  access the account on the user's behalf. That is yours to confirm with the institution.

**Google Play.** The User Data policy's "Prominent Disclosure and Consent": the disclosure is in the
app, appears before access, names the data and its use, and needs an affirmative tap. Declining
opens nothing. The Data safety answers are in [privacy.md](privacy.md).
