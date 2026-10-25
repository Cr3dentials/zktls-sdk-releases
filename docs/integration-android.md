# Integrating the zkTLS SDK on Android

Your app makes two calls: `Zktls.configure` once, when it starts, and `Zktls.verify` with the platforms
you want and a reference of your choice. The SDK checks the device, starts a verification with our
backend, shows its own screens as dialogs over your activity, and opens each platform's sign-in page. An
attester reads each platform, signs the result and posts it to our backend, which sends your server a
signed webhook. The results never pass through your app. This page goes from install to your first test
webhook; what is the same on both platforms (the keys, the outcome, the webhooks, the strings) is in
[the iOS guide](integration-ios.md), linked from each section. [Proof mode](#proof-mode), which we enable
per partner, is at the end.

## Requirements

Android 7.0 (API 24) or later; compileSdk 36. Kotlin 2.1 or later: the AAR carries Kotlin 2.2
metadata. The AAR carries the core for arm64-v8a, armeabi-v7a, x86_64 and x86; the 64-bit libraries
are 16 KB-page aligned for Android 15 and later. A live key needs Google Play Integrity: a build installed
from Google Play, on a device with Google Play services ([before you submit](#before-you-submit)); a test
key works on an emulator.

## Install

```kotlin
dependencies {
    implementation("xyz.cr3dentials:zktls-sdk:2.0.1")                  // from mavenCentral()
    // Only if nothing else brings it to your code (androidx.lifecycle's lifecycleScope does) and your code
    // uses it, such as MainScope() (proof mode, below): the SDK's is a runtime dependency only.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}
```

The AAR merges its permissions and its foreground service into your manifest ([privacy.md](privacy.md)),
and its R8 keep rules into your release build. It brings JNA, kotlinx-coroutines (core and android),
androidx.webkit, Google Play Integrity and the Kotlin standard library as Maven dependencies, each under its
own licence: JNA, LGPL-2.1-or-later or Apache-2.0, at your choice; kotlinx-coroutines, androidx.webkit and
the Kotlin standard library, Apache-2.0. Google Play Integrity (`com.google.android.play:integrity`) and
the Google Play services libraries it brings are under Google's own terms, not an open-source licence (see
each library's POM, and the
[Play Integrity API Terms of Service](https://developer.android.com/google/play/integrity/terms)). Your
licence tooling lists them. The open-source notices of the core compiled into the AAR are in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md), and the AAR carries the same file.

## What you need from us

The same as on iOS ([what you need from us](integration-ios.md#what-you-need-from-us)): your app
registered with us, with its package name; its test key, `zk_test_…`, which needs no device check and
runs only `zktls-demo`, and its live key, `zk_live_…`, which runs only from your registered app on a
device that passes Play Integrity; and the signing secret of each of your team's webhooks, which stays on
your server.

## Configure

Call `Zktls.configure` once, when your app starts, in your `Application` class:

```kotlin
import ai.zktls.sdk.*
import android.app.Application

class YourApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Zktls.configure(appKey = "zk_test_…")         // the test key in debug builds, the live key in release
    }
}
```

Name the class in your manifest's `<application android:name=".YourApp">`. Calling `configure` again
replaces the key, the theme and the strings.

## Verify

`Zktls.verify` is a `suspend` function. Pass it the activity on screen, the platform ids and your
reference. It shows the SDK's screens as dialogs over that activity, and returns when the user leaves the
flow:

```kotlin
import ai.zktls.sdk.*
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

class VerifyActivity : ComponentActivity() {
    private val orderId = "order_8f3k2"                  // yours: a value your server already knows

    fun onVerifyClicked() {
        lifecycleScope.launch {
            try {
                val outcome = Zktls.verify(this@VerifyActivity, listOf("zktls-demo"), reference = orderId)
                for (platform in outcome.platforms) {
                    when (platform.status) {
                        PlatformStatus.DONE -> {}        // the result is on its way to your server
                        PlatformStatus.FAILED -> {}      // platform.reason says why, for your logs
                        PlatformStatus.NOT_STARTED -> {} // the user stopped: offer to finish later
                    }
                }
            } catch (e: SdkException.Refused) {
                // The verification did not start. The SDK has already told the user why.
                Log.w("Verify", "refused: ${e.code}: ${e.message}")   // errors.md
            } catch (e: SdkException) {
                // It could not start: the SDK has shown its refusal screen for this too.
                Log.w("Verify", "failed", e)
            } catch (e: CancellationException) {
                throw e                          // the activity is going: let the cancel through
            } catch (e: Exception) {
                Log.e("Verify", "unexpected", e) // an internal error from the SDK: report it to us
            }
        }
    }
}
```

`lifecycleScope` comes with androidx.activity and AppCompat, and the activity's end cancels it, which ends
the verification and takes its dialogs down. Any coroutine scope works. The platforms, the reference,
the refusal and the outcome are as on iOS ([verify](integration-ios.md#verify),
[the outcome](integration-ios.md#the-outcome)); in Kotlin a status is `PlatformStatus.DONE`, `FAILED` or
`NOT_STARTED`, and a refusal's `e.code` and `e.message` are its code and its message. Any other
`SdkException` means the verification could not start, and the SDK has shown its refusal screen for it
too, unless the call was cancelled; once started, `verify` returns an outcome. One verification
runs at a time: a call made while another runs waits for it to return, then starts.

**To finish later**, call `verify` again with the platforms that were not started. **To start from your
server**, pass the token it created with `POST /partner/verification-tokens`:

```kotlin
val remaining = outcome.platforms.filter { it.status == PlatformStatus.NOT_STARTED }.map { it.platform }
val fromServer = Zktls.verify(this@VerifyActivity, token)   // token: "vt_…", from your server
```

## Test with `zktls-demo`

On an emulator or a phone, with your test key: call `verify(activity, listOf("zktls-demo"), reference)`,
tap **Start**, then **Continue**, and sign in to the demo bank with any user name and the password `demo`.
`verify` returns with `zktls-demo` as `PlatformStatus.DONE`, and your server receives a `platform.finished`
with `"test": true`, then a `verification.finished`, as on iOS
([test with `zktls-demo`](integration-ios.md#test-with-zktls-demo)). The webhooks, and how your server
checks their signature, are in [your server: the webhooks](integration-ios.md#your-server-the-webhooks).

## Theme and strings

```kotlin
import android.graphics.Color

Zktls.configure(
    appKey = "zk_test_…",
    theme = ZktlsTheme(
        accent = 0xFF0E7C5A.toInt(),
        background = Color.WHITE,
        text = Color.BLACK,
        logo = R.drawable.logo,
    ),
    strings = mapOf(
        "intro.title" to getString(R.string.verify_intro_title),
        "finish.title" to getString(R.string.verify_finish_title),
    ),
)
```

Colours are ARGB colour ints, such as `ContextCompat.getColor(this, R.color.brand)`, and `logo` is a
drawable resource id. A `null`, or `ZktlsTheme()` with no arguments, keeps the SDK's own look. English
ships built in; override any string by its key. The keys and their English are the same as on iOS
([the table](integration-ios.md#theme-and-strings)). Words in braces are filled in by the SDK, so keep
them in your text.

## Things to know

- **The screens.** They are dialogs over the activity you pass. The SDK has no activity of its own, so
  keep that activity in front until `verify` returns.
- **Stopping.** **Not now** on the intro, **Stop here** between platforms, **Cancel**, Back or a tap
  outside the sign-in notice, or closing a sign-in page or pressing Back on it, ends the flow. The
  platform the user was on, and every later one, are not started.
- **Where the page may go.** The sign-in page stays on the platform's domains and on the third-party
  sign-in providers the platform uses ([the rules](integration-packs.md#where-the-page-may-go)). If the
  user follows a link anywhere else, that platform ends as failed, with the reason `navigation_refused`.
- **The sign-in screen** has a bar with the page's host and a Close button, and is kept out of screenshots
  and recordings ([store-review.md](store-review.md#the-sign-in-screen)).
- **Your app's web data.** On Android System WebView 123 and later, each run has its own WebView profile.
  On older WebViews, the run wipes your app's WebView cookies, web storage and cache before and after, so
  do not start a verification while your own WebViews' data matters.
- **Your app's `CookieHandler`.** The SDK's HTTP client is the JDK's `HttpURLConnection`, which uses a
  default `CookieHandler` for every request in the process. The SDK installs none: if your app installs
  one, it also sees `verify`'s calls to our backend and its fetches of the bundles and packs.
- **The foreground service.** The SDK runs its `shortService`, `ZkTlsSessionService`, during each
  hand-off, and while it reports how the platforms ended (up to 10 s). You add no lifecycle code for
  `verify`.
- **The notification.** It reads "Verifying", in a channel named "Verification". To translate or rebrand
  it, define `zktls_session_notification_title`, `zktls_session_channel_name` and the drawable
  `zktls_session_notification_icon` in your app's resources.
- **Minification** needs nothing from you: the AAR's consumer rules keep what the core loads through JNA.
- **Other exceptions.** A fault inside the SDK that is not an `SdkException` reaches you as
  `InternalException`, from the generated bindings. Catch it too, and report it.
- **Logging.** Log the `verificationId`, the statuses, the reasons and the refusal codes. Your Partner
  API key and webhook secrets never belong in the app at all.

## Before you submit

- **Live keys need Play Integrity.** A live key works only in a build installed from Google Play (an
  internal testing track is enough), on a device with Google Play services that passes Play's device
  integrity check. Builds installed from Android Studio or as an APK, emulators, and phones without
  Google Play services show "This device can't be verified" and throw `device_not_verified`. Develop
  with the test key, and try the live key with an internal testing build on a phone.
- **Your registered app.** The build's package name must be the one you registered with us.
- **The live key in release builds.** A test key in a release build runs only `zktls-demo`.
- **The manifest.** The SDK adds `INTERNET`, `ACCESS_NETWORK_STATE` and `FOREGROUND_SERVICE` (type
  `shortService`), and asks for no runtime permission ([privacy.md](privacy.md)).

Then work through the [partner integration checklist](partner-checklist.md): Data safety, the foreground
service, and App Review notes.

## Proof mode

Proof mode proves one fact from an institution's account with a zero-knowledge proof: `ZktlsClient`'s
`login`, `capture`, `prove` and `claim`. We enable it per partner; `verify` needs none of this section.

### What proof mode needs from us

The same as on iOS ([what proof mode needs from us](integration-ios.md#what-proof-mode-needs-from-us)):
your app credential, the profile and policy ids, `baseUrl`, the trust bundle's URL and the operator key to
pin, and the policy bundle's URL and digest. Pass the trust bundle's URL as `trustBundleUrl` as well, the
URL that always serves the latest bundle: an enclave may present a refreshed certificate before the
published bundle lists it, and with the URL the SDK refetches the bundle once per session when the
capture's two enclaves do, instead of failing with `Policy`. The refetch sends no credential and uses no
cache, and no cookie unless your app installs a default `CookieHandler`. The verifier `prove` reaches is
not covered.

### Build the session's configuration

One `SessionConfig` per session the user starts, with the same fields and rules as on iOS: see the
table in [the iOS guide](integration-ios.md#build-the-sessions-configuration). `idempotencyKey` is new
for every session (1 to 117 bytes), and `networkKey` never leaves the device.

```kotlin
val config = SessionConfig(
    baseUrl = frontDoor, appCredential = credential, userIdHash = hash(userId),
    profileId = profileId, policyId = policyId,
    idempotencyKey = java.util.UUID.randomUUID().toString(),   // new for every session
    clientRegion = country ?: "", networkKey = "default",
    trustBundleJson = trustBundle, trustBundleUrl = trustBundleUrl, trustOperatorKey = operatorKey,
    policyBundleJson = policyBundle, policyBundleDigest = policyBundleDigest,
)
```

### Run a session

```kotlin
import ai.zktls.sdk.*
import android.app.Activity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ProveActivity : Activity() {
    private val scope = MainScope()
    private var client: ZktlsClient? = null

    fun prove(config: SessionConfig) {
        if (client != null) return                                   // one session at a time
        val client = ZktlsClient(config).also { this.client = it }   // one client per session
        val lifecycle = ZkTlsLifecycle(this, client.lifecycleHandle)  // one per session, too
        client.onProgress { phase, percent -> runOnUiThread { /* update your progress bar */ } }
        scope.launch {
            try {
                client.login(WebViewLoginPresenter(this@ProveActivity))   // disclosure, then the page
                // Only now, since the login page is the user's to take time over (for example to fetch
                // an SMS code). A short foreground service keeps the session alive if the user leaves
                // the app; when Android ends it, cancel.
                try {
                    ZkTlsSessionService.start(this@ProveActivity, lifecycle) { client.cancel() }
                } catch (e: IllegalStateException) {
                    // ForegroundServiceStartNotAllowedException (API 31+): the login finished while the
                    // app was in the background. The session goes on without the service.
                }
                lifecycle.begin()
                client.capture()
                val report = client.prove()
                if (!report.accepted) return@launch show("Not proven: ${report.verdict}")
                val claim = client.claim()                   // verified against the trust bundle
                send(claim.encoded)                          // your backend verifies it again
            } catch (e: SdkException) {
                show(message(e))                             // errors.md; never retry automatically
            } catch (e: CancellationException) {
                throw e                                      // the activity is going: show nothing
            } catch (e: Exception) {
                show("Something went wrong. Please try again.")   // InternalException: report it
            } finally {
                lifecycle.end()                               // every path, including failure
                ZkTlsSessionService.stop(this@ProveActivity)
                this@ProveActivity.client = null
            }
        }
    }

    fun cancelTapped() { client?.cancel() }

    override fun onDestroy() {
        scope.cancel()                                       // cancels the session in flight
        super.onDestroy()
    }
}
```

`show`, `send` and `message` are yours. The sample app maps every variant.

### Things to know in proof mode

- **The proof.** `prove` proves each record the policy reads, to the verifier the session was assigned,
  over TLS 1.3 authenticated against the trust bundle. The verifier returns its signed claim with an
  accepted verdict, and `claim()` verifies it. The end-to-end flow has run against a live cell on
  devices ([support matrix](support-matrix.md)).
- **The claim**, and what your backend checks before it trusts one: as on iOS
  ([the claim, and your backend](integration-ios.md#the-claim-and-your-backend)).
- **The disclosure.** `WebViewLoginPresenter` shows it before the page, every time. Pass `disclosure`
  to translate it. A `ZktlsLoginPresenter` of your own must show an equivalent one before it opens the
  page ([store-review.md](store-review.md)), and close its page when the coroutine running
  `presentLogin` is cancelled: that is how `cancel()` reaches it.
- **The witness** never reaches your code: `capture` returns an opaque handle that proves once.
- **Cookies and web storage.** Android's `CookieManager`, web storage and WebView cache are shared by
  the whole process. The login clears all three before and after, so do not run a login while your
  own WebViews' cookies or stored data matter.
- **One session at a time.** `ZkTlsSessionService` holds one session: a second `start` takes over the
  first's timeout callback, and the first's `stop` ends the second's service. Guard as the snippet does.
- **Cancelling.** `cancel()` ends the verb in flight with `SdkException.Cancelled`, and closes the
  login page if it is open. Cancelling the coroutine that runs a verb cancels the session too; the
  coroutine then ends with its `CancellationException`. Cancel your scope when the activity goes.
- **The foreground service** is a `shortService`. Start it only after `login` returns, and stop it on
  every path, including failure. From API 31, Android refuses to start it while your app is in the
  background (`ForegroundServiceStartNotAllowedException`), which is why the snippet catches it.
  Android ends the service after about three minutes.
- **Threads.** The verbs are `suspend` functions that run on the SDK's own threads, so call them from
  any coroutine. `onProgress` calls you on an SDK thread, except for the `FAILED` phase a cancel
  reports, which arrives on the thread that called `cancel()`. Do not block in the callback.
- **Error text.** `SdkException.Transport` and `.Policy` carry their text in `e.v1`. Their `e.message`
  reads `v1=<text>`, so match and log `e.v1` ([errors.md](errors.md)).
- **Other exceptions.** A fault inside the SDK that is not an `SdkException` reaches you as
  `InternalException` from the generated bindings. Catch it, as the snippet's last `catch` does, and report it.
- **Logging.** Never log a handle, a cookie, or `SessionConfig`: its `toString()` prints every field,
  the app credential included.

