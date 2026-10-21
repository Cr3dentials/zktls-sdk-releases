# Partner integration checklist

Work down this page from first contact to production. Each line links the page that answers it.

## 1. From us, before you start

- [ ] Your app credential, the profile and policy ids for what you want to prove, and the front door
      URL (`baseUrl`). The front door assigns each session its enclaves and its verifier.
- [ ] The trust bundle's URL and the operator key to pin; the policy bundle's URL and its digest to pin.
- [ ] Confirmation that the production cell is live for your region. Until it is, integrate against the
      test configuration we give you.

## 2. Decide

- [ ] Your minimum OS, at or above ours: iOS 14.0 and Android 7.0 (API 24) ([support matrix](support-matrix.md)).
- [ ] How your app hashes its user id into `userIdHash` (never send the raw id), and how it makes
      `idempotencyKey` new for every session ([the configuration](integration-ios.md#build-the-sessions-configuration)).
- [ ] Where the signed claim goes: to your backend, which verifies it itself before trusting it
      ([the claim, and your backend](integration-ios.md#the-claim-and-your-backend);
      [verifying a claim on your backend](backend-verification.md)).

## 3. Install

- [ ] iOS: Swift Package Manager or CocoaPods; Android: Maven Central ([README](../README.md)). No token is needed.
- [ ] Pin a version (`from: "1.0.0"`, `~> 1.0`, `1.0.0`). Read the [changelog](../CHANGELOG.md) before every upgrade.

## 4. Integrate

- [ ] The session code from the [iOS guide](integration-ios.md) and the [Android guide](integration-android.md),
      starting from the [samples](../samples/ios/README.md), which do exactly that.
- [ ] One `ZktlsClient` per session and one session at a time, and its `ZkTlsLifecycle` built on
      `client.lifecycleHandle` and begun after `login` returns. On iOS, `onExpiry = { client.cancel() }`;
      on Android, start `ZkTlsSessionService` after login with `{ client.cancel() }` as its timeout
      callback (catching the refusal of a start from the background), stop it when the session ends,
      and cancel your coroutine scope when the activity goes.
- [ ] A message for every error in the [catalogue](errors.md), and no automatic retry.
- [ ] Keep the default login presenter, or show an equivalent disclosure in your own ([store review](store-review.md)).
- [ ] Log no handle, cookie or `SessionConfig`.

## 5. Test

- [ ] On a real iPhone at your minimum iOS, and on a mid-range and a low-end Android phone.
- [ ] Decline the disclosure; close the login page; background the app during capture; switch from
      Wi-Fi to cellular mid-session; cancel mid-proof. Each ends cleanly, and the user can start again.
- [ ] Your release build (R8 on Android): the app launches, and a session runs.

## 6. Store submission

- [ ] iOS privacy: the SDK's manifest is included for you; add its answers to your App Privacy ([privacy](privacy.md)).
- [ ] Export compliance: your counsel's answer, and `ITSAppUsesNonExemptEncryption` in your `Info.plist` ([export compliance](export-compliance.md)).
- [ ] App Review notes and a working demo account for the institution's login ([store review](store-review.md)).
- [ ] Your right, under the institution's terms, to access the account on the user's behalf (Apple guideline 5.2.2).
- [ ] Google Play Data safety answers for the SDK's part, and the permissions it adds ([privacy](privacy.md)).
- [ ] The SDK's open-source notices in your app's notices screen ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)).
      On Android, JNA, kotlinx-coroutines, androidx.webkit and the Kotlin standard library also arrive
      as Maven dependencies under their own licences ([Android guide](integration-android.md#install)).
- [ ] The SDK's licence terms, signed with us ([LICENSE](../LICENSE)).

## 7. Go live, and after

- [ ] Point `base_url`, the bundles and the verifier at production; refetch the trust bundle at least every 30 minutes, and pass its URL as `trustBundleUrl`.
- [ ] Watch the error variants you log. A `WrongEvidence` or `claim verify` failure that repeats is a report to us.
- [ ] When asking for support, send: the SDK version, the device and OS, the error variant and message,
      the time, and your app credential's id. Never send cookies, handles or user data.
