package dk.yepz.webreader

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateUtils
import android.util.Log
import android.view.HapticFeedbackConstants
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.activity.addCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.core.net.toUri
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updateLayoutParams
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.google.android.material.snackbar.Snackbar
import dk.yepz.webreader.databinding.ActivityMainBinding
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The whole app, as one full-screen web view.
 *
 * The Android counterpart of the iOS `ReaderViewController` and the GTK host's `ReaderHost`,
 * with one difference that shapes everything below: none of the reader logic is here. Which of
 * our own documents is on screen, when to extract, what the generated pages are allowed to ask
 * for, how a failure is classified, what a recents row means — all of it is ReaderKit's, one
 * `ReaderBridge` call away. This class owns the `WebView`, intents and the Storage Access
 * Framework, and executes the commands ReaderKit sends back.
 *
 * There is no toolbar and no menu, which is not a gap: `Platform.android` already tells the
 * generated pages there are no keyboard commands to advertise, and the page chrome carries
 * Home, Settings, Aa and recents itself — exactly as on iOS.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var sync: SyncFolder

    private val webView: WebView get() = binding.webView

    /**
     * The one thread native calls are made from when they are not made from the main thread.
     * Single, not a pool: the two network-bound calls fetch feeds, a sync cycle walks a
     * document tree that may be network-backed, and none of them is worth running twice over.
     */
    private val background: ExecutorService = Executors.newSingleThreadExecutor()

    /**
     * Set by [show] and consumed by the next `onPageStarted`: the page about to load is one of
     * ours and is already the answer, so the progress line must not go up for it.
     */
    private var ownRender = false

    /**
     * The URL whose main-frame load just failed. `onReceivedError` does not replace
     * `onPageFinished` — the failing load still finishes — and that finish belongs to a page
     * nobody is looking at any more, so it must not be reported as a navigation landing.
     */
    private var failedUrl: String? = null

    /**
     * What the settings page is told about sync, rebuilt after every cycle.
     *
     * In memory only, and that is the whole design: a cycle runs on every resume, so the one
     * moment this could be stale — a cold start before the first cycle lands — is exactly the
     * moment "Waiting for the first sync…" is the true answer. The Apple hosts persist the
     * timestamp because they have a store to put it in; here the store is ReaderKit's, and
     * reader state is the only thing it is for.
     */
    private var syncPeers: List<String> = emptyList()
    private var syncLastSuccess = 0L
    private var syncError: String? = null

    /** Asks for the sync folder. Registered as a field, because that has to happen before the
     *  activity reaches STARTED and a `presentSyncSetup` command can arrive any time after. */
    private val syncSetup = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()) { result ->
        val tree = result.data?.data ?: return@registerForActivityResult
        sync.remember(tree)
        // The folder changed, so what the settings page says about it is wrong until the
        // cycle lands — and the cycle is the slow part.
        pushSyncStatus()
        announce(R.string.sync_folder_chosen)
        runSyncCycle(announcing = true)
    }

    // MARK: - Lifecycle

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        sync = SyncFolder(this)

        applyInsets()
        configureWebView()

        onBackPressedDispatcher.addCallback(this) {
            // Our own generated pages are real back/forward entries, and ReaderKit is written
            // to recognise a restored one from its generator marker. Only when there is no
            // history left does back mean "leave", which is what Android users expect.
            if (webView.canGoBack()) {
                webView.goBack()
            } else {
                isEnabled = false
                onBackPressedDispatcher.onBackPressed()
            }
        }

        // The first call, and the one that builds the session: `filesDir` and `cacheDir` are
        // handed over once and are the only thing ReaderKit needs to own its persistence. The
        // launch link goes in the same call rather than through `openIncoming` afterwards, so
        // a cold start on a shared article never draws the start page on the way past.
        run(ReaderBridge.start(filesDir.absolutePath, cacheDir.absolutePath, linkText(intent)))
        // Before any cycle: this is what makes the settings page draw its Sync section at all.
        pushSyncStatus()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openIncoming(intent)
    }

    override fun onResume() {
        super.onResume()
        webView.onResume()
        // Whatever syncs the folder may have written into it while the app was away. Silent:
        // a folder that has gone missing must not put a message on screen every time the app
        // comes forward.
        runSyncCycle(announcing = false)
    }

    override fun onPause() {
        webView.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        background.shutdown()
        // Detached first: destroying a web view that is still in the hierarchy leaves the
        // parent holding a dead child, and the next inflate finds it.
        binding.root.removeView(webView)
        webView.destroy()
        super.onDestroy()
    }

    // MARK: - The web view

    private fun configureWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // The pages declare `width=device-width, initial-scale=1, viewport-fit=cover`, and
            // WebView reads that meta tag only with the wide viewport on. Overview mode is
            // what then scales a foreign desktop layout down to fit, as a browser does.
            useWideViewPort = true
            loadWithOverviewMode = true
            // Pinch-zoom, without the on-screen +/- widget: the same answer as iOS, where the
            // pages leave pinch available instead of offering page zoom.
            builtInZoomControls = true
            displayZoomControls = false
            // One window. A `target=_blank` therefore arrives at `shouldOverrideUrlLoading`
            // and loads in this same view, which is the app's whole shape.
            setSupportMultipleWindows(false)
            userAgentString = chromeUserAgent(userAgentString)
        }
        // `prefers-color-scheme` inside a WebView reports light unless this is on, and every
        // generated page under `Theme.auto` asks that question. The pages also carry
        // `<meta name="color-scheme" content="light dark">`, which is what stops WebView from
        // additionally force-darkening pixels they have already themed themselves.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(webView.settings, true)
        }
        // The stock white flashes between a dark page and the next; behind a transparent web
        // view is `windowBackground`, which follows the same night mode the pages do.
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.webViewClient = Client()
        // The name is fixed on the Swift side by `ReaderChrome.androidBridge`; a mismatch
        // makes every button on every generated page do nothing.
        webView.addJavascriptInterface(HostInterface(), "readerHost")
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
    }

    /**
     * Android's stock WebView user agent already claims Chrome, but it also carries the `; wv`
     * marker that says "embedded WebView". Sites read it: some serve a cut-down page, some
     * refuse a sign-in outright, and an article that will not load is an article that cannot
     * be extracted. Dropping the marker leaves a plain Chrome-on-Android agent, which is what
     * this app actually behaves like — the same reasoning as the Safari suffix the Mac and iOS
     * hosts add to `WKWebView`'s.
     */
    private fun chromeUserAgent(stock: String): String = stock.replace("; wv)", ")")

    /**
     * Insets the web view by the system bars.
     *
     * The pages place their own chrome with `env(safe-area-inset-*)`, and on iOS that is the
     * whole answer. Android WebView resolves those values from display cutouts only — the
     * status bar and the gesture bar are not in them — so a page drawn to the physical edges
     * would put its buttons under the navigation bar. The host therefore does the insetting
     * the pages cannot see to do, and `windowBackground` fills the strips.
     */
    private fun applyInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            webView.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            binding.progress.updateLayoutParams<FrameLayout.LayoutParams> {
                topMargin = bars.top
            }
            insets
        }
    }

    /**
     * The single place `loadDataWithBaseURL` is called.
     *
     * One funnel, for three reasons that are all silent failures otherwise. The encoding has
     * to be UTF-8, because that is what ReaderKit emits and a mismatch renders mojibake rather
     * than an error. The history URL has to be null, or every generated page leaves a second,
     * phantom entry in the back stack. And this is the only moment the host knows the load
     * about to start is its own answer rather than someone else's page, which is what
     * [ownRender] carries to `onPageStarted`. The GTK host funnels the same call for a fourth
     * reason — setting `PageState.willShow` — that does not apply here only because the page
     * state lives on the Swift side of the bridge and was already set before this command was
     * sent.
     *
     * [baseUrl] matters: the reader page passes the article's URL so relative images resolve.
     */
    private fun show(html: String, baseUrl: String?) {
        ownRender = true
        webView.loadDataWithBaseURL(baseUrl, html, "text/html", "utf-8", null)
    }

    // MARK: - Commands

    /** Runs a reply's commands, in order. */
    private fun run(reply: ReaderBridge.Reply) {
        val commands = reply.commands
        for (index in 0 until commands.length()) {
            execute(commands.optJSONObject(index) ?: continue)
        }
    }

    /**
     * The one place a command kind is interpreted, so adding a kind to the contract touches
     * exactly this `when` and nothing else.
     */
    private fun execute(command: JSONObject) {
        when (val kind = command.optString("kind")) {
            "load" -> webView.loadUrl(command.optString("url"))
            "show" -> show(command.optString("html"), command.optNullableString("baseUrl"))
            "evaluate" -> webView.evaluateJavascript(command.optString("script"), null)
            "reject" -> reject()
            "openExternally" -> openExternally(command.optString("url"))
            "presentSyncSetup" -> syncSetup.launch(sync.setupIntent())
            "extract" -> extract(command.optString("url"), command.optString("script"))
            "fetchSuggestions" -> offMain { ReaderBridge.suggestions() }
            "resolveSource" -> command.optString("url").let { url ->
                offMain { ReaderBridge.resolveSource(url) }
            }
            // A newer ReaderKit against an older APK. Dropping the command costs one feature;
            // throwing would cost the article on screen.
            else -> Log.w(TAG, "unknown command $kind")
        }
    }

    /**
     * The app said no. There is no beep on a phone, and a silent refusal reads as a bug, so it
     * is the error haptic — the one signal that works with the screen unlooked at.
     */
    private fun reject() {
        val effect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            HapticFeedbackConstants.REJECT
        } else {
            HapticFeedbackConstants.LONG_PRESS
        }
        binding.root.performHapticFeedback(effect)
    }

    /**
     * Hands a URL this app cannot render to whatever owns it. Only ever a non-web scheme —
     * ReaderKit sends this command for `mailto:` and friends, and [Client] sends it for the
     * same — so the system can never resolve it back to this app and loop.
     */
    private fun openExternally(url: String) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url.toUri()))
        } catch (e: ActivityNotFoundException) {
            // Nothing on this device handles it. Refusing is the honest answer.
            Log.i(TAG, "no handler for $url", e)
            reject()
        }
    }

    /**
     * Runs the extraction script against the page on screen and hands the raw result back.
     * Whether it is an article, whether it is one of our own reader documents, and what to do
     * about either are all ReaderKit's answers.
     *
     * The title is read in a second hop rather than folded into the extraction script: a
     * restored reader document answers the script with a sentinel and has no article to give a
     * headline, but a rating clicked on it still has to learn the right one, and `document`
     * is the only thing that knows.
     */
    private fun extract(url: String, script: String) {
        webView.evaluateJavascript(script) { rawResult ->
            webView.evaluateJavascript(TITLE_SCRIPT) { rawTitle ->
                run(ReaderBridge.extractionResult(url, jsResult(rawResult), jsResult(rawTitle)))
            }
        }
    }

    /**
     * Makes a native call that waits on the network, off the main thread — which is the
     * promise the facade blocks on rather than calling back into the JVM.
     */
    private fun offMain(call: () -> ReaderBridge.Reply) {
        background.execute {
            val reply = call()
            runOnUiThread { run(reply) }
        }
    }

    // MARK: - Entry points

    /**
     * A link from "Open with", from being the default browser, or from the share sheet.
     *
     * Nothing here inspects the string. `URLCleaner` unwraps the tracking redirects and
     * `WebURL` decides what counts as a link, both on the Swift side, and `accepted` is that
     * decision — the share sheet's route goes through the same normalisation the start page's
     * URL field uses, so "Some headline https://example.test/x" opens rather than being
     * refused for not being a bare URL.
     */
    private fun openIncoming(intent: Intent) {
        val reply = when (intent.action) {
            Intent.ACTION_VIEW ->
                intent.dataString?.takeIf { it.isNotBlank() }?.let { ReaderBridge.openIncoming(it) }
            Intent.ACTION_SEND ->
                intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
                    ?.let { ReaderBridge.openShared(it) }
            else -> null
        } ?: return
        run(reply)
        // Refused: the page on screen is untouched, so say so the way every other explicit
        // open path does.
        if (!reply.flag("accepted")) reject()
    }

    /**
     * The link an intent carries, as text. ACTION_VIEW gives a URL, ACTION_SEND whatever the
     * sharing app wrote — and both go to the same normaliser on the Swift side, so neither
     * this method nor its callers have an opinion about what a link looks like.
     */
    private fun linkText(intent: Intent): String? =
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }?.takeIf { it.isNotBlank() }

    // MARK: - Sync

    /**
     * Reads the shared folder, folds it through ReaderKit and publishes this device's file.
     * [announcing] is on only for the cycle that follows the user choosing a folder: that is
     * the one moment a failure is about something they just did.
     */
    private fun runSyncCycle(announcing: Boolean) {
        val id = deviceId()
        val name = deviceName()
        background.execute {
            val outcome = sync.cycle(id, name)
            runOnUiThread { apply(outcome, announcing) }
        }
    }

    private fun apply(outcome: SyncFolder.Outcome, announcing: Boolean) {
        when (outcome) {
            SyncFolder.Outcome.NotConfigured -> syncError = null
            SyncFolder.Outcome.Unreadable -> {
                syncError = getString(R.string.sync_folder_unreadable)
                if (announcing) announce(R.string.sync_folder_unreadable)
            }
            is SyncFolder.Outcome.WriteFailed -> {
                syncPeers = outcome.reply.strings("peers")
                syncError = getString(R.string.sync_write_failed)
                run(outcome.reply)
                if (announcing) announce(R.string.sync_write_failed)
            }
            is SyncFolder.Outcome.Folded -> {
                syncPeers = outcome.reply.strings("peers")
                syncLastSuccess = System.currentTimeMillis()
                syncError = null
                run(outcome.reply)
            }
        }
        pushSyncStatus()
    }

    /**
     * Tells ReaderKit what the settings page should say about sync. Also what makes the Sync
     * section exist: the page draws it only for a non-empty summary, so a device that has
     * never been asked shows no dead control.
     */
    private fun pushSyncStatus() {
        run(ReaderBridge.syncStatus(sync.displayPath(), syncSummary()))
    }

    /**
     * One line of state: the error if there is one, otherwise when it last synced and who else
     * it can see. The same shape as `ReaderSyncController.summary`, so a Mac and a phone
     * describe the same folder the same way.
     */
    private fun syncSummary(): String {
        syncError?.let { return it }
        if (!sync.isConfigured()) return getString(R.string.sync_off)
        if (syncLastSuccess == 0L) return getString(R.string.sync_waiting)
        val now = System.currentTimeMillis()
        // `getRelativeTimeSpanString` floors to its resolution, so a cycle that landed
        // seconds ago reads "0 minutes ago" — which nobody says. A finer resolution would
        // instead put a second-by-second count in a line nothing refreshes.
        val ago: CharSequence = if (now - syncLastSuccess < DateUtils.MINUTE_IN_MILLIS) {
            getString(R.string.sync_just_now)
        } else {
            DateUtils.getRelativeTimeSpanString(syncLastSuccess, now, DateUtils.MINUTE_IN_MILLIS)
        }
        return when (syncPeers.size) {
            0 -> getString(R.string.sync_summary_alone, ago)
            1 -> getString(R.string.sync_summary_one, ago, syncPeers[0])
            else -> getString(R.string.sync_summary_many, ago, syncPeers.size)
        }
    }

    /**
     * This device's file name in the shared folder, so it publishes over its own file every
     * cycle instead of littering the folder with a new one.
     *
     * `ANDROID_ID` is stable for the life of the install, unique per device, and already
     * hex — which a file name has to be. It is read rather than stored because storing it
     * would mean a preferences file whose only content is a value the system already keeps.
     */
    private fun deviceId(): String =
        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            ?.takeIf { it.isNotBlank() }
            ?: UUID.nameUUIDFromBytes(Build.FINGERPRINT.toByteArray()).toString()

    /**
     * What the other devices' summaries call this one. `Settings.Global.DEVICE_NAME` is what
     * the owner typed into Settings; `Build.MODEL` is the honest fallback and is never empty.
     */
    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: Build.MODEL

    private fun announce(@StringRes message: Int) {
        Snackbar.make(binding.root, message, Snackbar.LENGTH_LONG).show()
    }

    // MARK: - The page's route back

    /**
     * The generated pages' one route to the host. `ReaderChrome.transportScript(platform:)`
     * emits `window.readerHost.postMessage(JSON.stringify({name, body}))` for `.android`, so
     * both the interface name and this envelope are fixed on the Swift side.
     *
     * Nothing here decides whether a message is allowed. Each of the seventeen is honoured
     * only while its own page is showing, and that gate is `PageState` — host-wide handlers
     * are exactly how a live site's JavaScript would otherwise reach them.
     */
    private inner class HostInterface {
        @JavascriptInterface
        fun postMessage(envelope: String) {
            val decoded = try {
                JSONObject(envelope)
            } catch (e: JSONException) {
                Log.w(TAG, "unreadable message envelope", e)
                return
            }
            val name = decoded.optString("name").takeIf { it.isNotEmpty() } ?: return
            // A string, an array of strings, or an object — passed through as JSON, because
            // only ReaderKit knows which of the seventeen means which.
            val body = if (decoded.isNull("body")) null else decoded.opt("body")
            // WebView calls this on its own JavaScript thread; the web view and everything
            // behind the bridge belong to the main one.
            runOnUiThread { run(ReaderBridge.message(name, body)) }
        }
    }

    // MARK: - Navigation

    private inner class Client : WebViewClient() {

        /**
         * Web content loads here; anything else goes to its owning app.
         *
         * The question goes to ReaderKit rather than being answered with a scheme check:
         * `about:` and `data:` are the app's own pages as much as `http` is, and a host that
         * asked only about http/https would hand its own reader rendering to another app.
         *
         * Subframes are left alone deliberately: this fires for them too, and cancelling one
         * to re-issue it on the main view is how an iframe hijacks the page.
         */
        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ): Boolean {
            if (!request.isForMainFrame) return false
            val url = request.url.toString()
            if (ReaderBridge.loadsInApp(url)) return false
            openExternally(url)
            return true
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            if (ownRender) {
                ownRender = false
            } else {
                // Someone else's page is on its way. The line is indeterminate, so it says
                // "still moving" and claims nothing about how far along it is.
                binding.progress.show()
            }
            run(ReaderBridge.navigationStarted())
        }

        override fun onPageFinished(view: WebView, url: String) {
            binding.progress.hide()
            // The finish of a load that already failed. Its replacement page is on its way
            // from `onReceivedError`; reporting this one as a landing would tell ReaderKit
            // that a page nobody is looking at is now on screen.
            if (url == failedUrl) {
                failedUrl = null
                return
            }
            // A back or forward navigation can land on one of our own documents, whose base
            // URL is the article's or `about:blank` — indistinguishable from a foreign page by
            // URL alone. The generator marker is how a restored document says which it is.
            view.evaluateJavascript(GENERATOR_SCRIPT) { raw ->
                run(ReaderBridge.navigationFinished(url, jsResult(raw) ?: ""))
            }
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (!request.isForMainFrame) return
            val url = request.url.toString()
            failedUrl = url
            binding.progress.hide()
            val reply = ReaderBridge.loadFailed(url, urlErrorCode(error.errorCode))
            // The failing load has not finished yet, and starting the replacement from inside
            // this callback races its own `onPageFinished`. Posting puts the new page after
            // the failure has settled — the same order the GTK host gets by rendering from the
            // failure's FINISHED rather than from the failure itself.
            view.post { run(reply) }
        }
    }

    /**
     * Translates a WebView load failure into the `NSURLError` raw value `OfflineFallback`
     * classifies, so the classification — and the list of failures that are not failures —
     * stays in the one place the tests cover instead of gaining a third host-shaped copy.
     *
     * A dead radio reports as `ERROR_HOST_LOOKUP`, which would read as "that site does not
     * exist". So "you're offline" is answered by asking the system whether there is a network
     * at all, which is the same distinction the GTK host puts to GLib.
     */
    private fun urlErrorCode(code: Int): Int {
        if (!hasNetwork()) return NSURL_NOT_CONNECTED
        return when (code) {
            WebViewClient.ERROR_HOST_LOOKUP -> NSURL_CANNOT_FIND_HOST
            WebViewClient.ERROR_CONNECT, WebViewClient.ERROR_IO -> NSURL_CANNOT_CONNECT
            WebViewClient.ERROR_TIMEOUT -> NSURL_TIMED_OUT
            else -> NSURL_NOT_CONNECTED
        }
    }

    private fun hasNetwork(): Boolean {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return true
        val active = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(active) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private companion object {
        const val TAG = "WebReader"

        /** The `<meta name="generator">` content of the current document, or "". */
        const val GENERATOR_SCRIPT =
            "(document.querySelector('meta[name=\"generator\"]')||{}).content || ''"

        const val TITLE_SCRIPT = "document.title"

        const val NSURL_TIMED_OUT = -1001
        const val NSURL_CANNOT_FIND_HOST = -1003
        const val NSURL_CANNOT_CONNECT = -1004
        const val NSURL_NOT_CONNECTED = -1009

        /**
         * Unwraps what `evaluateJavascript` hands back.
         *
         * The result arrives as a **JSON literal**, not as the value: a JS string comes back
         * quoted and backslash-escaped, and a JS `null` comes back as the four characters
         * `null`. Exactly one layer comes off, and only one — the extraction script's result
         * is itself a JSON document in a string, and taking a second layer would parse the
         * article ReaderKit is waiting for into something it never sees.
         */
        fun jsResult(raw: String?): String? {
            if (raw == null) return null
            return try {
                JSONTokener(raw).nextValue() as? String
            } catch (e: JSONException) {
                Log.w(TAG, "unreadable script result", e)
                null
            }
        }

        /** Null for both an absent key and a JSON `null`, which the contract uses for "none". */
        fun JSONObject.optNullableString(key: String): String? =
            if (isNull(key)) null else optString(key)
    }
}
