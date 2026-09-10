package dk.yepz.webreader

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.format.DateUtils
import android.util.Log
import android.view.HapticFeedbackConstants
import android.webkit.JavascriptInterface
import android.webkit.SslErrorHandler
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
import androidx.core.graphics.toColorInt
import androidx.core.net.toUri
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.isVisible
import androidx.core.view.updateLayoutParams
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.google.android.material.color.MaterialColors
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
     * Bumped by every main-frame navigation start, so a script callback can tell whether the
     * page it was asked about is still the page on screen.
     */
    private var pageGeneration = 0

    /**
     * The URL of the document the web view is loading or showing, or null while one of our own
     * generated pages is up. Only `onReceivedSslError` needs it: that callback fires for
     * subresources as well, and it has no `isForMainFrame` to ask.
     */
    private var mainFrameUrl: String? = null

    /**
     * The cover's watchdog, and the load progress it last saw. A `Handler` rather than a
     * coroutine: it is one delayed check on the main thread, cancelled and re-armed, which is
     * exactly what a `Handler` is.
     */
    private val watchdog = Handler(Looper.getMainLooper())
    private var lastProgress = -1
    private var silentTicks = 0
    /** Whether the document now on screen has had its first paint committed. */
    private var painted = false
    /** A reveal that is waiting for that paint. */
    private var revealWhenPainted = false

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
            // ReaderKit is asked first, because the web view's history also holds every
            // article page that was extracted on the way — going back through one of those
            // re-extracts it and lands on the article being left (#42). When the session has
            // no destination of its own, a site's own pages are exactly what the web view's
            // history is for; and when that is empty too, Back means leave, which is what
            // Android users expect.
            val reply = ReaderBridge.back()
            if (reply.flag("handled")) {
                run(reply)
            } else if (reply.text("fallback") == "webViewHistory" && webView.canGoBack()) {
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
        val started = ReaderBridge.start(filesDir.absolutePath, cacheDir.absolutePath,
                                         linkText(intent))
        // Between building the session and running what it answered: the theme decides whether
        // WebView may repaint the page, and the first render must not be the one that gets it
        // wrong. `start` only built the session — nothing has painted yet.
        applyTheme()
        run(started)
        // A launch link ReaderKit refused leaves the start page up, which says nothing about
        // the link that was handed over; the warm path rejects audibly for the same case.
        // Posted because the haptic needs a view that is attached.
        if (!started.flag("accepted")) binding.root.post { reject() }
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
        watchdog.removeCallbacksAndMessages(null)
        background.shutdown()
        // Detached first: destroying a web view that is still in the hierarchy leaves the
        // parent holding a dead child, and the next inflate finds it.
        binding.root.removeView(webView)
        webView.destroy()
        super.onDestroy()
    }

    /**
     * `uiMode` is in `configChanges`, so a dark-mode switch — including the automatic one at
     * sunset — does not recreate the activity. That is deliberate: the reader's own documents
     * are `loadDataWithBaseURL` renders that `WebView.saveState` does not bring back, so
     * recreation would drop the article on screen. What it costs is anything the theme
     * resolved once at creation, so that is re-applied here.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        applyTheme()
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
        // The stock white flashes between a dark page and the next; behind a transparent web
        // view is the reader's own background, painted by `applyTheme`.
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.webViewClient = Client()
        // Content the web view cannot render — a feed, a PDF, an archive — arrives here
        // instead of as a page, and with no listener at all the load simply stops: whatever
        // was on screen stays, with none of our chrome on it and no way back. Nothing is
        // downloaded, because a file this app cannot read is not something to keep; the answer
        // is ReaderKit's own page, which carries Home.
        webView.setDownloadListener { url, _, _, _, _ ->
            stopWatching()
            failedUrl = url
            binding.progress.hide()
            run(ReaderBridge.loadFailed(url, CANNOT_SHOW_CONTENT), settled = true)
        }
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
            // The keyboard is in here too: `enableEdgeToEdge` turns off `decorFitsSystemWindows`,
            // and from API 30 that makes `adjustResize` inert — nothing resizes the window for
            // the IME any more, so a page's URL field would sit behind it. Asking for both in
            // one go gives the larger of the two edges, which is what the padding wants.
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
                    or WindowInsetsCompat.Type.ime())
            webView.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            binding.progress.updateLayoutParams<FrameLayout.LayoutParams> {
                topMargin = bars.top
            }
            insets
        }
    }

    /**
     * Applies the reader's theme to everything outside the page, and settles the one question
     * WebView is otherwise free to answer for itself.
     *
     * The surfaces first: the window behind a document that has not painted yet, the strips
     * the insets leave beside the web view, and the cover a site loads behind. All three take
     * the reader's own background rather than `colorSurface`, because the theme is a setting
     * with five values and only one of them follows the system — a sepia page between two grey
     * strips is the same mistake as a white flash before a dark one.
     *
     * Then algorithmic darkening, which is only ever right under `auto`. It is what makes
     * `prefers-color-scheme` report dark inside a WebView, which every page under `auto` asks
     * — but it also lets WebView repaint content it decides is light-only while the app is in
     * night mode, and a pinned theme pins `color-scheme` to exactly that. So `light` arrived
     * as near-black and `sepia` as a dark brown: WebView darkening a page that had already
     * themed itself. Pinned, the theme is the user's answer and nothing may second-guess it.
     *
     * Re-applied after every settings change and on a configuration change, because both the
     * colours and that decision are otherwise settled once, when the window is created.
     *
     * The progress line keeps the accent it was inflated with until the activity is recreated.
     * It is a 2.5dp line that shows only while a foreign page loads, and re-colouring it by
     * hand would mean naming the two attributes Material picks for it and getting them to
     * agree with its own defaults.
     */
    private fun applyTheme() {
        enableEdgeToEdge()
        val night = resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val palette = ReaderBridge.palette(night)
        val background = palette.text("background")
            ?.let { runCatching { it.toColorInt() }.getOrNull() }
            ?: MaterialColors.getColor(binding.root, com.google.android.material.R.attr.colorSurface)
        window.setBackgroundDrawable(ColorDrawable(background))
        binding.cover.setBackgroundColor(background)
        // The label on it is a secondary line, so it takes `muted` — the same colour the
        // other hosts paint this word in.
        palette.text("text")
            ?.let { runCatching { it.toColorInt() }.getOrNull() }
            ?.let { binding.coverMessage.setTextColor(it) }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
            WebSettingsCompat.setAlgorithmicDarkeningAllowed(
                webView.settings, palette.flag("followsSystem", default = true))
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
     * [baseUrl] matters twice: the reader page passes the article's URL so relative images
     * resolve, and it is also how this host knows which of our pages it is being handed —
     * only the reader carries one, which is what [applyReadingMode] keys on.
     */
    private fun show(html: String, baseUrl: String?) {
        applyReadingMode(reading = baseUrl != null)
        ownRender = true
        // Our own document owns the frame now, so a late certificate error from an article's
        // subresource is not this page's problem.
        mainFrameUrl = null
        // Deliberately not revealing here. One of ours is the answer, but it is not on screen
        // yet: `loadDataWithBaseURL` has to parse and paint first, and the cover coming down
        // ahead of it showed a frame or two of the page being replaced — the flash this whole
        // arrangement exists to prevent, moved to the end of the load instead of the start.
        // The reveal happens when this document's own load settles.
        webView.loadDataWithBaseURL(baseUrl, html, "text/html", "utf-8", null)
    }

    /**
     * Hides the system bars while the reader is on screen, and brings them back for anything
     * else.
     *
     * The reader page is the one surface with nothing to say about the phone: no address bar,
     * no chrome, one column of text. A clock and a battery above it are precisely the
     * distraction the page exists to remove — so they go, and they return the moment a site,
     * the start page or the settings page is up, where knowing the time is ordinary.
     *
     * Transient by swipe rather than simply gone: a swipe from the edge brings them back for
     * a few seconds without leaving the article, which is how Android offers the time to
     * someone in a full-screen app. `applyInsets` keeps asking for `displayCutout`, so a
     * hidden status bar still does not put the first line under a notch.
     */
    private fun applyReadingMode(reading: Boolean) {
        val controller = WindowInsetsControllerCompat(window, binding.root)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (reading) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    // MARK: - Commands

    /**
     * Runs a reply's commands, in order, and answers whether one of them started a
     * navigation.
     *
     * That answer is the cover's rule, and the only piece of judgement in here: what is on
     * screen has settled unless a command started something new. [settled] marks the callers
     * that know a load has finished — a landing, an extraction, a failure — and a page that
     * never comes out from behind the cover is the failure this arrangement prevents.
     *
     * The reply's own `reading` comes first, before any command: it describes the page the
     * reply was *about*, and a command in the same reply may be replacing it — a render that
     * enters the reader would otherwise be undone by the answer that preceded it. A reply
     * that says nothing about it leaves the bars alone.
     */
    private fun run(reply: ReaderBridge.Reply, settled: Boolean = false): Boolean {
        if (reply.has("reading")) applyReadingMode(reading = reply.flag("reading"))
        var navigating = false
        val commands = reply.commands
        for (index in 0 until commands.length()) {
            if (execute(commands.optJSONObject(index) ?: continue)) navigating = true
        }
        if (settled && !navigating) {
            // Settled says the app has decided what to show, which is not the same as it
            // being on screen: `onPageFinished` is the document loaded, and until the new
            // one paints the web view is still showing the page it replaces. Measured at
            // two frames of the site between the two — the glimpse this whole arrangement
            // exists to prevent, at the end of the load instead of the start.
            if (painted) {
                revealPage()
            } else {
                revealWhenPainted = true
                watchdog.removeCallbacks(::revealAnyway)
                watchdog.postDelayed(::revealAnyway, PAINT_PATIENCE_MS)
            }
        }
        return navigating
    }

    /**
     * The one place a command kind is interpreted, so adding a kind to the contract touches
     * exactly this `when` and nothing else.
     *
     * Answers whether the command started a new navigation, which is what tells the cover
     * that the screen has not settled. Extraction counts: it is the rest of this navigation,
     * not the end of it, and revealing the site while Readability works is the flash the
     * cover exists to prevent.
     */
    private fun execute(command: JSONObject): Boolean {
        when (val kind = command.optString("kind")) {
            "load" -> command.optString("url").let { url ->
                // Someone else's page: the bars come back, because a site is not the surface
                // the reader's own quiet was built for.
                applyReadingMode(reading = false)
                // Recorded before the load, because a certificate is checked before anything
                // commits and `onReceivedSslError` can arrive before `onPageStarted`.
                mainFrameUrl = url
                // Covered before the load is even issued rather than when `onPageStarted`
                // reports it: everything between the two is a window in which the page being
                // left, or the first paint of the one arriving, is on screen uncovered.
                coverPage()
                webView.loadUrl(url)
                return true
            }
            "show" -> {
                show(command.optString("html"), command.optNullableString("baseUrl"))
                return true
            }
            "extract" -> {
                extract(command.optString("url"), command.optString("script"))
                return true
            }
            "evaluate" -> webView.evaluateJavascript(command.optString("script"), null)
            "reject" -> reject()
            "openExternally" -> openExternally(command.optString("url"))
            "presentSyncSetup" -> syncSetup.launch(sync.setupIntent())
            "fetchSuggestions" -> offMain { ReaderBridge.suggestions() }
            "resolveSource" -> command.optString("url").let { url ->
                offMain { ReaderBridge.resolveSource(url) }
            }
            // A newer ReaderKit against an older APK. Dropping the command costs one feature;
            // throwing would cost the article on screen.
            else -> Log.w(TAG, "unknown command $kind")
        }
        return false
    }

    // MARK: - The cover, and what happens when a load never lands

    /**
     * Covers the web view while someone else's page loads (#24), so the site does not paint
     * itself only to be replaced by the reader a moment later.
     *
     * One rule takes it down: the screen has settled on a page the app meant to show. Not a
     * timer, and not "the site has painted something" — a news page paints its masthead long
     * before Readability has an article, and revealing it there is the flash this exists to
     * prevent, moved later in the load rather than removed.
     *
     * Watched from here on in ticks of silence rather than elapsed time, so a slow page that
     * is still moving keeps its cover. Silence all the way to [COVER_GIVE_UP_TICKS] means
     * nothing was ever going to end this load — a page that commits and then hangs produces
     * no error, so WebView would leave the progress line sweeping for as long as the app is
     * open. Reported as the timeout it is, which ReaderKit answers with a page that says so
     * and offers Try Again: an ending, rather than a bare site with no chrome on it.
     */
    private fun coverPage() {
        // Asked on every appearance, because the engine picks from a list: a screen that can
        // now be up for twenty seconds should not be blank, and should not always say the
        // same thing either.
        val words = ReaderBridge.coverMessage()
        binding.coverMessage.text = words.text("message") ?: ""
        binding.coverMessage.textSize = words.number("size", default = 20.0).toFloat()
        binding.cover.isVisible = true
        lastProgress = -1
        silentTicks = 0
        watchdog.removeCallbacksAndMessages(null)
        watchdog.postDelayed(::checkStalled, COVER_SILENCE_MS)
    }

    /** Reveals whatever is behind the cover, the load having arrived somewhere. */
    private fun revealPage() {
        revealWhenPainted = false
        watchdog.removeCallbacks(::revealAnyway)
        binding.cover.isVisible = false
    }

    /**
     * The backstop for a paint that never arrives.
     *
     * Deliberately long: by the time a reveal is waiting, the app has already settled on one
     * of its own pages, so the worst this can do is show it a moment late. Short would be
     * worse than absent — it would race the paint it is waiting for and put the previous page
     * back on screen, which is the bug it sits behind.
     */
    private fun revealAnyway() {
        if (!revealWhenPainted) return
        Log.w(TAG, "revealing the page: settled but no first paint")
        revealPage()
    }

    /** Stops watching, for the paths that ended the load one way or another. */
    private fun stopWatching() {
        watchdog.removeCallbacksAndMessages(null)
        silentTicks = 0
    }

    private fun checkStalled() {
        val progress = webView.progress
        if (progress != lastProgress) {
            lastProgress = progress
            silentTicks = 0
            watchdog.postDelayed(::checkStalled, COVER_SILENCE_MS)
            return
        }
        if (++silentTicks >= COVER_GIVE_UP_TICKS) {
            val url = mainFrameUrl
            Log.w(TAG, "giving up on $url: stalled at $progress%")
            stopWatching()
            binding.progress.hide()
            failedUrl = url
            run(ReaderBridge.loadFailed(url ?: "", NSURL_TIMED_OUT), settled = true)
            return
        }
        watchdog.postDelayed(::checkStalled, COVER_SILENCE_MS)
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
        val generation = pageGeneration
        webView.evaluateJavascript(script) { rawResult ->
            // Extraction takes a moment, and a navigation can land inside it. The result then
            // belongs to a page nobody wants any more: rendering it would file page A's body
            // under page B's key, and read page B's headline while doing it. Both sibling
            // hosts re-check the same thing.
            if (generation != pageGeneration) return@evaluateJavascript
            webView.evaluateJavascript(TITLE_SCRIPT) { rawTitle ->
                if (generation != pageGeneration) return@evaluateJavascript
                run(ReaderBridge.extractionResult(url, jsResult(rawResult), jsResult(rawTitle)),
                    settled = true)
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
            onUiThreadIfAlive { run(reply) }
        }
    }

    /**
     * Runs [body] on the main thread unless the activity has gone.
     *
     * `ExecutorService.shutdown()` neither interrupts the task that is running nor discards
     * the one that is queued, so a cycle or a feed fetch in flight at `onDestroy` still lands
     * — on a destroyed web view, a detached root, and an unregistered result launcher.
     */
    private fun onUiThreadIfAlive(body: () -> Unit) {
        runOnUiThread { if (!isFinishing && !isDestroyed) body() }
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
                // `getCharSequenceExtra`, because a sharing app may put a `SpannableString`
                // there — `getStringExtra` answers null for one, and this route would then
                // refuse the share without so much as a haptic.
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                    ?.takeIf { it.isNotBlank() }
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
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
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
            onUiThreadIfAlive { apply(outcome, announcing) }
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
            onUiThreadIfAlive {
                // The sync summary is relative to now ("Last synced a few minutes ago") and
                // the settings page renders it from what the session was last told, so the
                // one message that builds that page gets a fresh answer first. The only name
                // the host has an opinion about, and this is why.
                if (name == "readerOpenSettings") pushSyncStatus()
                run(ReaderBridge.message(name, body))
                // A theme change repaints what no page covers: the window, the inset strips
                // and the cover the next load hides behind.
                if (name == "readerSettings") applyTheme()
            }
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
            // Whatever a script callback was asked about, it is not this page.
            pageGeneration++
            painted = false
            if (ownRender) {
                ownRender = false
            } else {
                // Someone else's page is on its way: cover it rather than let the site paint
                // itself only to be replaced by the reader a moment later (#24). The line is
                // indeterminate, so it says "still moving" and claims nothing about how far
                // along it is.
                coverPage()
                binding.progress.show()
            }
            run(ReaderBridge.navigationStarted())
        }

        /**
         * The first paint of this document — the moment the web view stops showing the page
         * it is replacing. Android's own name for it, and the only honest cue for taking the
         * cover down: every other callback fires while the old pixels are still up.
         */
        override fun onPageCommitVisible(view: WebView, url: String) {
            painted = true
            if (revealWhenPainted) {
                revealWhenPainted = false
                revealPage()
            }
        }

        override fun onPageFinished(view: WebView, url: String) {
            // However this ended, it ended: nothing left for the watchdog to give up on.
            stopWatching()
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
                run(ReaderBridge.navigationFinished(url, jsResult(raw) ?: ""), settled = true)
            }
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            if (!request.isForMainFrame) return
            stopWatching()
            val url = request.url.toString()
            failedUrl = url
            binding.progress.hide()
            val reply = ReaderBridge.loadFailed(url, urlErrorCode(error.errorCode))
            // The failing load has not finished yet, and starting the replacement from inside
            // this callback races its own `onPageFinished`. Posting puts the new page after
            // the failure has settled — the same order the GTK host gets by rendering from the
            // failure's FINISHED rather than from the failure itself.
            view.post { run(reply, settled = true) }
        }

        /**
         * A certificate the device does not trust.
         *
         * WebView routes this here instead of to `onReceivedError`, and the default
         * implementation cancels the load and tells nobody — which leaves the app showing
         * whatever was there before, or nothing at all on a cold start. `WKWebView` reports
         * the same failure as -1202 through `didFailProvisionalNavigation`, so the Apple hosts
         * have always answered with the page that says the load failed; this is that answer,
         * arrived at through a different callback.
         *
         * Cancelled and never proceeded: a reader that quietly accepts a bad certificate is
         * worse than one that refuses the page. Reported only for the document's own host,
         * because this also fires for subresources and an image with a bad certificate must
         * not replace an article that loaded fine. Compared by host rather than by string:
         * WebView normalises the URL it reports, so the one asked for and the one that failed
         * differ by a trailing slash.
         */
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            handler.cancel()
            stopWatching()
            val failed = error.url ?: return
            if (failed.toUri().host == null || failed.toUri().host != mainFrameUrl?.toUri()?.host) {
                return
            }
            failedUrl = failed
            binding.progress.hide()
            val reply = ReaderBridge.loadFailed(failed, NSURL_SECURE_CONNECTION_FAILED)
            // Posted for the same reason as `onReceivedError`: the failing load has not
            // finished, and rendering from inside this callback races its own finish.
            view.post { run(reply, settled = true) }
        }
    }

    /**
     * Translates a WebView load failure into the `NSURLError` raw value `OfflineFallback`
     * classifies, so the classification — and the list of failures that are not failures —
     * stays in the one place the tests cover instead of gaining a third host-shaped copy.
     *
     * A dead radio reports as `ERROR_HOST_LOOKUP`, which would read as "that site does not
     * exist". So "you're offline" is answered by asking the system whether there is a network
     * at all, which is the same distinction the GTK host puts to GLib — and once that answer
     * is no, everything else is a code `classify` does not name, which is what the generic
     * page is for. Reporting an expired certificate or a blocked cleartext load as -1009
     * would tell someone demonstrably online that they are offline.
     */
    private fun urlErrorCode(code: Int): Int {
        if (!hasNetwork()) return NSURL_NOT_CONNECTED
        return when (code) {
            WebViewClient.ERROR_HOST_LOOKUP -> NSURL_CANNOT_FIND_HOST
            WebViewClient.ERROR_CONNECT, WebViewClient.ERROR_IO -> NSURL_CANNOT_CONNECT
            WebViewClient.ERROR_TIMEOUT -> NSURL_TIMED_OUT
            else -> NSURL_UNKNOWN
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

        /**
         * How long the cover tolerates a load that is not moving. Silence, not elapsed time:
         * the watchdog re-arms whenever `WebView.getProgress` has changed, so a slow page
         * keeps its cover and a stuck one does not.
         */
        const val COVER_SILENCE_MS = 4_000L

        /**
         * Ticks of silence before a load is called over: 20 seconds at four apiece.
         *
         * Long, on purpose, because this is the only threshold left and it is destructive —
         * it replaces whatever was loading with an error page. Doing that to a slow site that
         * was still going to arrive is worse than a few more seconds behind the cover.
         */
        const val COVER_GIVE_UP_TICKS = 5

        /**
         * How long a settled page may take to paint before the cover comes down regardless.
         * Only reachable if `onPageCommitVisible` never arrives for a document the web view
         * says it finished loading, which is why it is long enough never to race it.
         */
        const val PAINT_PATIENCE_MS = 3_000L

        /**
         * WebKit's `WebKitErrorCannotShowMIMEType`, which `OfflinePage.classify` answers with
         * the one kind that offers no Try Again — a feed or a download will answer exactly the
         * same way next time. Not an Android number: the classification is ReaderKit's, and
         * this is the code it already understands for "that was not a web page".
         */
        const val CANNOT_SHOW_CONTENT = 100

        const val NSURL_TIMED_OUT = -1001
        const val NSURL_CANNOT_FIND_HOST = -1003
        const val NSURL_CANNOT_CONNECT = -1004
        const val NSURL_NOT_CONNECTED = -1009
        /** `NSURLErrorUnknown`, which `OfflinePage.classify` answers with its generic page. */
        const val NSURL_UNKNOWN = -1
        /**
         * `NSURLErrorSecureConnectionFailed`, which also answers with the generic page. The
         * cert's own fault — expired, self-signed, wrong host — is not distinguished, because
         * `classify` treats every one of them the same and the page says the same thing.
         */
        const val NSURL_SECURE_CONNECTION_FAILED = -1200

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
