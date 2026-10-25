# Partner integration checklist

Work down this page from first contact to production. Each line links the page that answers it.

## 1. From us, before you start

- [ ] Your app registered with us: its iOS bundle ID and Team ID, and its Android package name
      ([what you need from us](integration-ios.md#what-you-need-from-us)).
- [ ] Your test key, `zk_test_…`, and your live key, `zk_live_…`. Both are publishable: they ship in your app.
- [ ] The signing secret of each of your team's webhooks, for your server.
- [ ] The platforms enabled for your app. A test key runs only `zktls-demo`.

## 2. Decide

- [ ] Your minimum OS, at or above ours: iOS 14.0 and Android 7.0 (API 24) ([support matrix](support-matrix.md)).
- [ ] What your app passes as the reference: a value your server already knows, with no personal data
      ([verify](integration-ios.md#verify)).
- [ ] Whether your app passes the platforms itself, or your server prepares each verification with a token
      (`POST /partner/verification-tokens`).
- [ ] Your theme, and the SDK's strings in each language your app supports
      ([theme and strings](integration-ios.md#theme-and-strings)).

## 3. Install

- [ ] iOS: Swift Package Manager or CocoaPods; Android: Maven Central ([README](../README.md)). No token is needed.
- [ ] Pin a version (`from: "2.0.1"`, `~> 2.0`, `2.0.1`). Read the [changelog](../CHANGELOG.md) before every upgrade.

## 4. Integrate

- [ ] `Zktls.configure` once at launch, and `Zktls.verify` when the user starts, as in the
      [iOS guide](integration-ios.md) and the [Android guide](integration-android.md).
- [ ] Your webhook endpoint checks the `Zktls-Signature` header over the raw body, and rejects a `t` more
      than 300 seconds from now ([your server: the webhooks](integration-ios.md#your-server-the-webhooks)).
- [ ] Your server matches results by reference, processes each `platform.finished` once per `runId`, keeps
      deliveries with `"test": true` apart, and handles results that arrive after the user has left the app.
- [ ] Your app offers to finish later when platforms were not started.
- [ ] A handling for every refusal code in the [catalogue](errors.md#refused), and no automatic retry.
- [ ] No Partner API key or webhook secret anywhere in your app or its logs.

## 5. Test

- [ ] With the test key and `zktls-demo`, on the Simulator or an emulator: a signed `platform.finished`, then a
      `verification.finished`, reach your server.
- [ ] Decline the intro. Stop between platforms. Close the sign-in page. Tap a link off the platform. Leave the
      app during a hand-off. Switch from Wi-Fi to cellular. Each ends cleanly, and the user can start again.
- [ ] Kill the app in the middle of the flow: `verification.finished` still arrives, about 2 hours after the
      verification started, with the remaining platforms `not_started`.
- [ ] A delivery with a changed body, or an old `t`, is rejected by your endpoint.
- [ ] With the live key: a TestFlight build on a real iPhone, and a Google Play internal testing build on an
      Android phone with Google Play services ([iOS](integration-ios.md#before-you-submit),
      [Android](integration-android.md#before-you-submit)).
- [ ] Your release build (R8 on Android) launches and completes a verification.

## 6. Store submission

- [ ] iOS privacy: the SDK's manifest is included for you; add its answers to your App Privacy ([privacy](privacy.md)).
- [ ] Export compliance: your counsel's answer, and `ITSAppUsesNonExemptEncryption` in your `Info.plist` ([export compliance](export-compliance.md)).
- [ ] App Review notes on the sign-in pages, and a working demo account for each platform ([store review](store-review.md)).
- [ ] Your right, under each platform's terms, to access the account on the user's behalf (Apple guideline 5.2.2).
- [ ] Google Play Data safety answers for the SDK's part, Play Integrity's included, and the permissions and
      `shortService` foreground service it adds ([privacy](privacy.md)).
- [ ] The SDK's open-source notices in your app's notices screen ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).
      On Android, JNA, kotlinx-coroutines, androidx.webkit, Google Play Integrity and the Kotlin standard
      library also arrive as Maven dependencies under their own licences, Google Play Integrity under
      Google's terms ([Android guide](integration-android.md#install)).
- [ ] The SDK's licence terms, signed with us ([LICENSE](../LICENSE)).

## 7. Go live, and after

- [ ] Release builds configure the live key, `zk_live_…`.
- [ ] Your server uses a Production Partner API key for tokens and fetches.
- [ ] Watch the refusal codes and failure reasons you log. A `device_not_verified` that many users get, or a
      failure that repeats, is a report to us.
- [ ] When asking for support, send: the SDK version, the device and OS, the refusal code or the platform's
      reason, the time, and the `verificationId`. Never send your Partner API key, your webhook secret,
      cookies or user data.
- [ ] Proof mode, if we enabled it for you: its configuration and session code are in the
      [iOS guide](integration-ios.md#proof-mode), and your backend verifies its claims
      ([verifying a claim on your backend](backend-verification.md)).
