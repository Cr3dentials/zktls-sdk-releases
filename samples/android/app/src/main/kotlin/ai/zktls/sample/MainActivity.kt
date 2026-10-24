package ai.zktls.sample

import ai.zktls.sdk.Phase
import ai.zktls.sdk.SdkException
import ai.zktls.sdk.SessionConfig
import ai.zktls.sdk.TreeDisclosure
import ai.zktls.sdk.TreeRunConfig
import ai.zktls.sdk.TreeSummary
import ai.zktls.sdk.TreeWebViewHost
import ai.zktls.sdk.WebViewLoginPresenter
import ai.zktls.sdk.ZkTlsLifecycle
import ai.zktls.sdk.ZkTlsSessionService
import ai.zktls.sdk.Zktls
import ai.zktls.sdk.ZktlsClient
import ai.zktls.sdk.ZktlsLabApi
import ai.zktls.sdk.ZktlsLoginPresenter
import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.TextView
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * The partner sample app, and the acceptance harness on Android. It uses only the public SDK surface:
 * `:sdk` in zktls-sdk, `xyz.cr3dentials:zktls-sdk` from Maven Central in the releases repository.
 *
 * A partner's whole integration is [verify]: `Zktls.configure` once, then `Zktls.verify` per user. Below it
 * are the proof flow and, behind the lab opt-in (`ZktlsLabApi`), one platform's pack on its own.
 *
 * What is NOT here: a retry. A failure before the freeze ends that session; the user taps again.
 */
class MainActivity : Activity() {
    private val scope = MainScope()
    private lateinit var verifyDemo: Button
    private var flow: SampleFlow? = null
    private var next: Result<SampleFlow>? = null
    private lateinit var status: TextView
    private lateinit var bar: ProgressBar
    private lateinit var prove: Button
    private var tree: ZktlsClient? = null
    private lateinit var platform: Spinner
    private lateinit var runPack: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { text = "idle" }
        // Your test key, in verify.json (samples/android/README.md); a partner's app passes its own at launch.
        runCatching { JSONObject(File(getExternalFilesDir(null), "verify.json").readText()).getString("app_key") }
            .onSuccess { Zktls.configure(appKey = it) }
        verifyDemo = Button(this).apply { text = "Verify with zktls-demo"; setOnClickListener { verify() } }
        bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            contentDescription = "Proof progress"
        }
        prove = Button(this).apply { text = "Prove my transfer"; setOnClickListener { start() } }
        // A platform's pack: tree.json names the platforms (samples/android/README.md).
        platform = Spinner(this).apply { contentDescription = "Platform" }
        runPack = Button(this).apply { text = "Run a platform pack"; setOnClickListener { runTree() } }
        val cancel = Button(this).apply { text = "Cancel"; setOnClickListener { flow?.cancel(); tree?.cancel() } }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
            listOf(verifyDemo, bar, status, prove, platform, runPack, cancel).forEach(::addView)
        }
        // targetSdk 36 draws edge to edge from Android 15: pad the root by the system bars, on top
        // of the existing 48px margin, so nothing sits under the status bar or the gesture bar.
        root.setOnApplyWindowInsetsListener { view, insets ->
            val l: Int; val t: Int; val r: Int; val b: Int
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                l = bars.left; t = bars.top; r = bars.right; b = bars.bottom
            } else {
                l = insets.systemWindowInsetLeft
                t = insets.systemWindowInsetTop
                r = insets.systemWindowInsetRight
                b = insets.systemWindowInsetBottom
            }
            view.setPadding(48 + l, 48 + t, 48 + r, 48 + b)
            insets
        }
        setContentView(root)
        next = prepare()
        val platforms = runCatching { TreeSettings.load(this).platforms }.getOrDefault(emptyList())
        platform.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, platforms)
    }

    /**
     * The next session's flow, made ahead. Its client loads the SDK's native core, so with the settings
     * in place a minified build that lost the core's classes fails at launch, not on the first tap: only
     * reading the settings may fail quietly (`map` rethrows what the client throws).
     */
    private fun prepare() = runCatching { SampleSettings.load(this) }.map { SampleFlow(it.config) }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /** The partner's integration: one call, which shows the SDK's screens and returns how each platform ended. */
    private fun verify() = scope.launch {
        verifyDemo.isEnabled = false
        status.text = try {
            val outcome = Zktls.verify(this@MainActivity, listOf("zktls-demo"), reference = "sample-${System.currentTimeMillis()}")
            outcome.platforms.joinToString("\n") { "${it.platform}: ${it.status}" + (it.reason?.let { r -> " ($r)" } ?: "") }
        } catch (e: SdkException.Refused) {
            "Not started: ${e.code}" // the SDK has told the user why, except for not_configured
        } catch (e: SdkException) {
            message(e)
        }
        verifyDemo.isEnabled = true
    }

    private fun start() {
        // Made at launch or after the last session; made now if the settings arrived since.
        val f = next?.getOrNull() ?: prepare().getOrElse {
            status.text = "No settings: ${it.message} (see samples/android/README.md)"
            return
        }
        next = null
        flow = f
        // ZkTlsSessionService has a single companion slot: two overlapping sessions would end
        // each other's service window.
        prove.isEnabled = false
        runPack.isEnabled = false
        // One lifecycle per session, on the client's own handle, which the verbs drive.
        val lifecycle = ZkTlsLifecycle(this, f.client.lifecycleHandle)
        scope.launch {
            val outcome = runCatching {
                f.run(
                    WebViewLoginPresenter(this@MainActivity),
                    onLoggedIn = {
                        // Only now, since the login page is the user's to take time over. The
                        // shortService keeps the capture and proof alive if the user leaves the app.
                        lifecycle.begin()
                        ZkTlsSessionService.start(this@MainActivity, lifecycle) { f.cancel() }
                    },
                ) { phase, percent ->
                    runOnUiThread {
                        status.text = phase.name
                        bar.progress = percent.toInt()
                    }
                }
            }
            status.text = outcome.fold(
                onSuccess = { if (it.accepted) "Proven: ${it.outputs}" else "Not proven: ${it.verdict}" },
                onFailure = { "${message(it)} Tap to start again." })
            lifecycle.end()
            ZkTlsSessionService.stop(this@MainActivity)
            next = prepare()
            prove.isEnabled = true
            runPack.isEnabled = true
        }
    }

    /**
     * A platform's pack, the user present: the SDK shows the disclosure, opens the platform's sign-in page
     * and collects in the page. The data reaches our backend at the result URL: the SDK posts it, or for a
     * pack that attests, the attester does once it has taken the run. The app gets a summary only. One
     * platform's pack on its own is the lab's (`ZktlsLabApi`): a partner's app calls `Zktls.verify`.
     */
    @OptIn(ZktlsLabApi::class)
    private fun runTree() {
        val settings = runCatching { TreeSettings.load(this) }.getOrElse {
            status.text = "No tree settings: ${it.message} (see samples/android/README.md)"
            return
        }
        val platformId = platform.selectedItem as? String ?: run {
            status.text = "tree.json names no platform"
            return
        }
        val client = ZktlsClient()
        tree = client
        prove.isEnabled = false
        runPack.isEnabled = false
        // One lifecycle per run, on the client's own handle. A pack that attests uploads to the attester
        // once the page closes: the shortService keeps that upload alive if the user leaves the app.
        val lifecycle = ZkTlsLifecycle(this, client.lifecycleHandle)
        client.onProgress { phase, percent ->
            runOnUiThread {
                if (phase == Phase.ATTESTING) {
                    lifecycle.begin()
                    try {
                        ZkTlsSessionService.start(this@MainActivity, lifecycle) { client.cancel() }
                    } catch (e: IllegalStateException) {
                        // ForegroundServiceStartNotAllowedException (API 31+): the app is in the background.
                        // The upload goes on without the service.
                    }
                }
                status.text = phase.name
                bar.progress = percent.toInt()
            }
        }
        scope.launch {
            val outcome = runCatching {
                val run = withContext(Dispatchers.IO) { settings.issueRun(platformId) }
                client.runTree(settings.config(platformId, run), TreeWebViewHost(this@MainActivity, disclosure(platformId)))
            }
            status.text = outcome.fold(
                onSuccess = { describe(it) + lab("isolation: ${it.isolation}") },
                onFailure = {
                    if (it is SdkException) "${message(it)} Tap to start again.${lab((it as? SdkException.Policy)?.v1)}"
                    else "No run: ${it.message}"
                })
            lifecycle.end()                                   // every path, including failure
            ZkTlsSessionService.stop(this@MainActivity)
            tree = null
            prove.isEnabled = true
            runPack.isEnabled = true
        }
    }

    /** A debug build's extra line for the device lab: a refusal's reason (a host) or the run's isolation, never data. */
    private fun lab(line: String?) =
        if (line != null && applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) "\n$line" else ""
}

/**
 * Your disclosure, in your words and approved for your app (docs/privacy.md): the SDK shows it before the
 * platform's pages open, and opens nothing if the user declines.
 */
@OptIn(ZktlsLabApi::class)
fun disclosure(platformId: String) = TreeDisclosure(
    title = "Connect your account",
    message = "The app opens $platformId's own sign-in page. You sign in there yourself; the app never sees " +
        "your password. After you sign in, the app reads the data this check needs from your account on this device.",
    accept = "Continue",
    decline = "Not now",
)

/** What the app learns from a run: how it ended and each source's counts, never the data. */
@OptIn(ZktlsLabApi::class)
fun describe(s: TreeSummary): String = buildString {
    append(if (s.succeeded) "Collected" else "Not collected: ${s.error}")
    s.sources.forEach { append("\n${it.storeAs}: ${it.rows} rows, ${it.pages} pages") }
    append("\n${s.durationMs.toLong() / 1000} s; ")
    append(
        when {
            s.handedOff -> "handed to the attester, which posts the result"
            s.delivered -> "result delivered"
            else -> "result not delivered: ${s.deliveryError}"
        },
    )
}

/** What the user reads for each error (docs/errors.md). Exhaustive: a new variant fails this build. */
fun message(e: Throwable): String {
    if (e !is SdkException) return "Something went wrong."
    return when (e) {
        is SdkException.NotLoggedIn -> "Sign-in was not completed."
        is SdkException.SessionLost -> "The connection dropped before your record was captured."
        is SdkException.Cancelled -> "Cancelled."
        is SdkException.WrongEvidence, is SdkException.Truncated,
        is SdkException.ExtraResponse, is SdkException.Reordered -> "Your institution's reply could not be verified."
        is SdkException.LimitExceeded -> "This check is not available right now. Try again later."
        is SdkException.InsufficientMemory -> "Your phone is short of memory. Close other apps, then try again."
        is SdkException.Transport -> "A network problem. Check your connection."
        is SdkException.Policy -> "This check is not available right now."
        is SdkException.Refused ->
            if (e.code == "device_not_verified") "This device can't be verified." else "Verification isn't available right now."
    }
}

/** The four verbs in order, with progress and cancel wired through. */
class SampleFlow(config: SessionConfig) {
    val client = ZktlsClient(config)
    val isCancelled: Boolean get() = client.isCancelled

    fun cancel() = client.cancel()

    suspend fun run(
        presenter: ZktlsLoginPresenter,
        onLoggedIn: () -> Unit = {},
        onProgress: (Phase, UByte) -> Unit,
    ): Outcome {
        client.onProgress(onProgress)
        client.login(presenter)
        onLoggedIn()
        client.capture()
        val report = client.prove()
        if (!report.accepted) return Outcome(false, report.verdict, "")
        val claim = client.claim()
        onProgress(Phase.DONE, 100u)
        return Outcome(true, report.verdict, claim.outputs.joinToString { it.name })
    }

    data class Outcome(val accepted: Boolean, val verdict: String, val outputs: String)
}

/**
 * A tree run's settings (tree.json): your front door and app credential, the operator key that signs the
 * packs, the platforms to offer, and your backend's endpoint that issues each run's result URL and token.
 */
class TreeSettings(
    val baseUrl: String,
    val appCredential: String,
    val trustOperatorKey: String,
    val runsUrl: String,
    val platforms: List<String>,
    val userIdHash: String,
    val clientRegion: String,
    val networkKey: String,
    val trustBundleJson: String,
    val policyBundleJson: String,
    val policyBundleKeys: List<String>,
    val trustBundleUrl: String = "",
) {
    /**
     * Your backend's call for a run: it asks ours for the run's result URL and token, which only it may
     * read results with. A test server can stand in for both and take the app credential.
     */
    fun issueRun(platformId: String): Triple<String, String, String> {
        val c = URL(runsUrl).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.connectTimeout = 10_000
            c.readTimeout = 10_000
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("Authorization", "Bearer $appCredential")
            c.outputStream.use { it.write(JSONObject().put("platform_id", platformId).toString().toByteArray()) }
            if (c.responseCode != 200) throw IOException("the runs URL answered ${c.responseCode}")
            val j = JSONObject(c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) })
            // A check's run inputs, as our backend received them: the SDK takes them as JSON text.
            return Triple(j.getString("result_url"), j.getString("result_token"), j.optJSONObject("params")?.toString() ?: "")
        } finally {
            c.disconnect()
        }
    }

    @OptIn(ZktlsLabApi::class)
    fun config(platformId: String, run: Triple<String, String, String>) = TreeRunConfig(
        baseUrl = baseUrl, appCredential = appCredential, userIdHash = userIdHash,
        idempotencyKey = UUID.randomUUID().toString(), clientRegion = clientRegion, networkKey = networkKey,
        platformId = platformId,
        // Read only for a pack that attests.
        trustBundleJson = trustBundleJson, trustBundleUrl = trustBundleUrl, trustOperatorKey = trustOperatorKey,
        policyBundleJson = policyBundleJson, policyBundleKeys = policyBundleKeys,
        relyingPartyNonceHex = "", resultUrl = run.first, resultToken = run.second, paramsJson = run.third,
    )

    companion object {
        /** `adb push tree.json /sdcard/Android/data/ai.zktls.sample/files/`. */
        fun load(context: Context): TreeSettings =
            parse(JSONObject(File(context.getExternalFilesDir(null), "tree.json").readText()))

        fun parse(j: JSONObject): TreeSettings {
            val p = j.getJSONArray("platforms")
            val k = j.optJSONArray("policy_bundle_keys")
            return TreeSettings(
                baseUrl = j.getString("base_url"),
                appCredential = j.getString("app_credential"),
                trustOperatorKey = j.getString("trust_operator_key"),
                runsUrl = j.getString("runs_url"),
                platforms = List(p.length()) { p.getString(it) },
                userIdHash = j.optString("user_id_hash", "sample"),
                clientRegion = j.optString("client_region"),
                networkKey = j.optString("network_key", "sample"),
                // A pack that attests needs the trust and policy bundles, as session.json has them, and the policy keys.
                trustBundleJson = j.optString("trust_bundle_json"),
                policyBundleJson = j.optString("policy_bundle_json"),
                policyBundleKeys = if (k == null) emptyList() else List(k.length()) { k.getString(it) },
                trustBundleUrl = j.optString("trust_bundle_url"),
            )
        }
    }
}

/** A session's settings: a JSON object with the SessionConfig fields. */
class SampleSettings(val config: SessionConfig) {
    companion object {
        /** `adb push session.json /sdcard/Android/data/ai.zktls.sample/files/`. */
        fun load(context: Context): SampleSettings =
            parse(JSONObject(File(context.getExternalFilesDir(null), "session.json").readText()))

        fun parse(j: JSONObject) = SampleSettings(
            SessionConfig(
                baseUrl = j.getString("base_url"),
                appCredential = j.getString("app_credential"),
                userIdHash = j.getString("user_id_hash"),
                profileId = j.getString("profile_id"),
                policyId = j.getString("policy_id"),
                idempotencyKey = UUID.randomUUID().toString(),
                clientRegion = j.optString("client_region"),
                networkKey = j.optString("network_key", "sample"),
                trustBundleJson = j.getString("trust_bundle_json"),
                trustBundleUrl = j.optString("trust_bundle_url"),
                trustOperatorKey = j.getString("trust_operator_key"),
                policyBundleJson = j.getString("policy_bundle_json"),
                policyBundleDigest = j.getString("policy_bundle_digest")))
    }
}
