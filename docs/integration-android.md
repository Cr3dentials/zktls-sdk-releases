# Integrating the zkTLS SDK on Android

## Requirements

Android 7.0 (API 24) or later; compileSdk 36. Kotlin 2.1 or later: the AAR carries Kotlin 2.2
metadata. The AAR carries the core for arm64-v8a, armeabi-v7a, x86_64 and x86; the 64-bit libraries
are 16 KB-page aligned for Android 15 and later.

## Install

```kotlin
dependencies {
    implementation("xyz.cr3dentials:zktls-sdk:1.0.0")                  // from mavenCentral()
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")  // coroutines, and MainScope()
}
```

The AAR merges its permissions and its foreground service into your manifest ([privacy.md](privacy.md)),
and its R8 keep rules into your release build. It brings JNA, kotlinx-coroutines, androidx.webkit and
the Kotlin standard library as Maven dependencies, each under its own licence (JNA: LGPL-2.1-or-later or
Apache-2.0, at your choice; the other three: Apache-2.0); your licence tooling lists them. The
open-source notices of the core compiled into the AAR are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md),
and the AAR carries the same file.

## What you need from us

The same as on iOS: your app credential, the profile and policy ids, `baseUrl`, the trust bundle's URL
and the operator key to pin, and the policy bundle's URL and digest. Pass the trust bundle's URL as
`trustBundleUrl` as well, the URL that always serves the latest bundle: an enclave may present a
refreshed certificate before the published bundle lists it, and with the URL the SDK refetches the
bundle once per session when the capture's two enclaves or the attester do, instead of failing
with `Policy`. The refetch sends no credential and uses no cache, and no cookie unless your app
installs a default `CookieHandler`, which `HttpURLConnection` uses for every request. The verifier
`prove` reaches is not covered
([the iOS guide](integration-ios.md#what-you-need-from-us) explains it).

## Build the session's configuration

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

## Run a session

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

## Things to know

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
- **The notification.** It reads "Verifying", in a channel named "Verification". Define
  `zktls_session_notification_title`, `zktls_session_channel_name` and the drawable
  `zktls_session_notification_icon` in your app's resources to translate or rebrand it.
- **Threads.** The verbs are `suspend` functions that run on the SDK's own threads, so call them from
  any coroutine. `onProgress` calls you on an SDK thread, except for the `FAILED` phase a cancel
  reports, which arrives on the thread that called `cancel()`. Do not block in the callback.
- **Minification** needs nothing from you: the AAR's consumer rules keep what the core loads through JNA.
- **Error text.** `SdkException.Transport` and `.Policy` carry their text in `e.v1`. Their `e.message`
  reads `v1=<text>`, so match and log `e.v1` ([errors.md](errors.md)).
- **Other exceptions.** A fault inside the SDK that is not an `SdkException` reaches you as
  `InternalException` from the generated bindings. Catch it, as the snippet's last `catch` does, and report it.
- **Logging.** Never log a handle, a cookie, or `SessionConfig`: its `toString()` prints every field,
  the app credential included.

## Before you submit

Work through the [partner integration checklist](partner-checklist.md): Data safety, the foreground
service, and a test account for review.
