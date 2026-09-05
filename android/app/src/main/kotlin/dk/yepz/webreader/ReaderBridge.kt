package dk.yepz.webreader

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * The only route between Kotlin and ReaderKit.
 *
 * There is exactly one native method, and every reader question goes through it as a name and
 * a JSON object. That is deliberate: a JNI surface with one entry point cannot drift out of
 * step with the Swift side the way a dozen typed signatures would, and adding a call is a new
 * `name` on both sides rather than a new symbol, a new registration and a new ABI to keep.
 * `Sources/ReaderKitAndroid/Facade.swift` is the other end; `Sources/CReaderKitJNI` is the
 * shim that wraps its `readerkit_call` / `readerkit_free`.
 *
 * A Kotlin `object` rather than a class with a companion: the JNI symbol is derived from the
 * declaring class, and `@JvmStatic` on a companion member would move the native declaration to
 * `ReaderBridge$Companion`, so the shim's `Java_dk_yepz_webreader_ReaderBridge_call` would
 * never bind. Instance versus static does not matter — both pass a pointer in the same slot.
 *
 * The Swift side is stateful across calls and owns its own persistence: it is handed the app's
 * files and cache directories by [start] and uses `ReaderKit.FileStore` and
 * `ReaderKit.ArticleCache` from there. Nothing on this side stores reader state.
 *
 * Four facade calls are deliberately absent — `toggleReader`, `home`, `reload` and
 * `resetAppearance`. They exist for a host with a menu or a keyboard; Android, like iOS, has
 * neither, and the generated page chrome carries Home, Settings, Aa and recents itself. Adding
 * one here is three lines the day something invokes it.
 */
internal object ReaderBridge {

    private const val TAG = "ReaderBridge"

    init {
        // `ReaderKitAndroid` is the shim; the Swift runtime `.so`s beside it in `jniLibs` are
        // pulled in by its own DT_NEEDED entries, so they are never loaded by name here.
        System.loadLibrary("ReaderKitAndroid")
    }

    external fun call(name: String, jsonArgs: String): String?

    /**
     * One answer from ReaderKit. Every reply carries a `commands` array — possibly empty — and
     * some carry one or two extra fields beside it.
     */
    class Reply(private val json: JSONObject) {
        val commands: JSONArray = json.optJSONArray("commands") ?: JSONArray()

        fun flag(key: String): Boolean = json.optBoolean(key, false)

        /** Null for both an absent key and a JSON `null`, which the contract uses for "no". */
        fun text(key: String): String? = if (json.isNull(key)) null else json.optString(key)

        fun strings(key: String): List<String> {
            val array = json.optJSONArray(key) ?: return emptyList()
            return (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
        }
    }

    // MARK: - Calls

    /**
     * The first call, and the one that builds the session. Its reply shows the start page, or
     * goes straight to the article when the app was launched by a link — [text] rather than a
     * URL, because a share can arrive as a headline with a link inside it and the same
     * normaliser handles both.
     */
    fun start(filesDir: String, cacheDir: String, text: String?): Reply =
        invoke("start") {
            put("filesDir", filesDir)
            put("cacheDir", cacheDir)
            if (text != null) put("text", text)
        }

    /**
     * A link from an intent. The reply says whether ReaderKit took it — `URLCleaner` and
     * `WebURL.isWebURL` decide, here as everywhere else — so the caller can tell "opening"
     * from "that is not a link".
     */
    fun openIncoming(url: String): Reply = invoke("openIncoming") { put("url", url) }

    /**
     * Text another app shared, which is very often a headline with a link inside it rather
     * than a bare URL. Normalised by the same rule the start page's URL field uses, so the
     * two routes cannot disagree about what counts as a link.
     */
    fun openShared(text: String): Reply = invoke("openShared") { put("text", text) }

    /**
     * Navigation policy: does the web view load this itself, or does it belong to another
     * app? Asked rather than answered here, because the list is longer than http/https —
     * `about:` and `data:` are the app's own pages too.
     */
    fun loadsInApp(url: String): Boolean =
        invoke("loadsInApp") { put("url", url) }.flag("value")

    fun navigationStarted(): Reply = invoke("navigationStarted")

    /** [generator] is the document's `<meta name="generator">` content, `""` when absent. */
    fun navigationFinished(url: String, generator: String): Reply =
        invoke("navigationFinished") {
            put("url", url)
            put("generator", generator)
        }

    /**
     * [result] is the raw string the extraction script returned, omitted for a JS `null`, and
     * [title] the document's own `<title>` — which is the headline a restored reader document
     * has to be re-read from, since its rendering happened in some earlier session.
     */
    fun extractionResult(url: String, result: String?, title: String?): Reply =
        invoke("extractionResult") {
            put("url", url)
            if (result != null) put("result", result)
            if (title != null) put("title", title)
        }

    /** [code] is an `NSURLError` value, so `OfflineFallback.classify` stays shared. */
    fun loadFailed(url: String, code: Int): Reply =
        invoke("loadFailed") {
            put("url", url)
            put("code", code)
        }

    /**
     * One of the seventeen `reader*` messages a generated page posted. [body] is whatever
     * `JSON.stringify` produced for it — a string, an array of strings, or an object — and is
     * handed on untouched; only ReaderKit knows what any of them mean.
     */
    fun message(name: String, body: Any?): Reply =
        invoke("message") {
            put("name", name)
            if (body != null) put("body", body)
        }

    /** Fetches feeds, so the caller must be off the main thread. */
    fun suggestions(): Reply = invoke("suggestions")

    /** Looks a feed up on a site the user pasted; also network-bound, also off-main. */
    fun resolveSource(url: String): Reply = invoke("resolveSource") { put("url", url) }

    /**
     * What the settings page says about sync, and whether it says anything at all: the page
     * draws its Sync section only for a non-empty [summary]. Both strings are the host's,
     * because the host is what owns the folder.
     */
    fun syncStatus(folder: String?, summary: String): Reply =
        invoke("syncStatus") {
            if (folder != null) put("folder", folder)
            put("summary", summary)
        }

    /**
     * The sync fold. [states] is the contents of every device file found in the shared folder;
     * the reply names the one file this device should publish (or nothing), lists the peers it
     * saw, and carries the in-place page updates the merge calls for.
     */
    fun syncPeers(deviceId: String, deviceName: String, states: List<String>): Reply =
        invoke("syncPeers") {
            put("deviceId", deviceId)
            put("deviceName", deviceName)
            put("states", JSONArray(states))
        }

    // MARK: - Plumbing

    private fun invoke(name: String, build: JSONObject.() -> Unit = {}): Reply {
        val args = JSONObject().apply(build)
        val raw = call(name, args.toString())
        if (raw == null) {
            // The shim returns null only when ReaderKit itself could not answer. An empty
            // reply is then the honest result: no commands, so what is on screen stays.
            Log.w(TAG, "no reply for $name")
            return Reply(JSONObject())
        }
        return try {
            Reply(JSONObject(raw))
        } catch (e: org.json.JSONException) {
            // A malformed reply is a bug in the shim, not something the user can act on;
            // dropping it costs one interaction, crashing costs the article being read.
            Log.e(TAG, "unparseable reply for $name", e)
            Reply(JSONObject())
        }
    }
}
