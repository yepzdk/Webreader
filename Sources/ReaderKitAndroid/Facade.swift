import Foundation
import ReaderKit

/// The reader, as two C functions.
///
/// Android's host is Kotlin, so the boundary is JNI, and JNI is at its least troublesome
/// when it carries nothing but strings. Everything therefore goes through one dispatcher:
/// a call name, a JSON object in, a JSON object out. Adding a call later touches the switch
/// below and the Kotlin side that names it — never the C shim, never the build.
///
/// The session on this side is stateful and owns its own persistence, exactly as the Linux
/// host's does: given the app's files and cache directories once, it uses `FileStore` and
/// `ArticleCache` and Kotlin never sees a preference key. What Kotlin owns is the WebView,
/// the intents, and the document tree sync reads through — the things a JVM is actually
/// holding.

/// Everything the process keeps between calls, and the turn-taking that makes it safe.
///
/// The session is single-threaded by design; Kotlin is not. The sync cycle and the two calls
/// that wait for the network arrive on a background executor while the UI thread posts
/// messages, navigation and extraction results. So the lock is held for the whole of a call
/// rather than for the moment it takes to read the session out — a reader that folded its
/// history while the other thread rewrote page state would be very hard to see.
private final class Bridge {
    static let shared = Bridge()
    private let lock = NSLock()
    private var session: ReaderSession?

    /// Builds the session and answers the call that built it, under one lock.
    ///
    /// Rebuilds it if the host ever starts again — a second `start` means a new Activity over
    /// the same process, which Android does routinely, and reusing the old session would keep
    /// a page state that no longer matches anything on screen.
    func start(filesDirectory: String, cacheDirectory: String,
               then body: (ReaderSession) -> [String: Any]) -> [String: Any] {
        lock.withLock {
            let store = FileStore(fileURL: URL(fileURLWithPath: filesDirectory)
                .appendingPathComponent("reader.json"))
            let cache = ArticleCache(directory: URL(fileURLWithPath: cacheDirectory)
                .appendingPathComponent("articles"))
            let session = ReaderSession(store: store, cache: cache, appName: "WebReader",
                                        platform: .android)
            self.session = session
            return body(session)
        }
    }

    /// Runs `body` on the live session with every other call locked out, or answers nil
    /// before `start` — which is the honest answer: there is nothing on screen to act on yet.
    func withSession<T>(_ body: (ReaderSession) -> T) -> T? {
        lock.withLock {
            guard let session else { return nil }
            return body(session)
        }
    }

    /// The session for the two calls that must let go of it while they wait on the network.
    /// What they await reaches no session state at all; what they do with the answer goes
    /// back through `withSession`.
    var current: ReaderSession? { lock.withLock { session } }
}

/// One call. `name` selects it, `json` carries its arguments, and the reply is a JSON object
/// the caller owns and must hand to `readerkit_free`.
@_cdecl("readerkit_call")
public func readerkit_call(_ name: UnsafePointer<CChar>,
                           _ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let call = String(cString: name)
    let arguments = (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)))
        as? [String: Any] ?? [:]
    return duplicate(reply(for: call, arguments: arguments))
}

/// Releases what `readerkit_call` returned. `strdup` on this side, `free` on either — the
/// C shim frees the reply as soon as it has copied it into a Java string.
@_cdecl("readerkit_free")
public func readerkit_free(_ string: UnsafeMutablePointer<CChar>?) {
    free(string)
}

// MARK: - Dispatch

private func reply(for call: String, arguments: [String: Any]) -> [String: Any] {
    // `start` is the one call that may arrive without a session, because it makes one.
    if call == "start" {
        return Bridge.shared.start(
            filesDirectory: arguments["filesDir"] as? String ?? "",
            cacheDirectory: arguments["cacheDir"] as? String ?? "") { session in
            // `text`, not a URL: the launch link may have arrived in an ACTION_SEND extra
            // with a headline wrapped around it, and normalising it here is what keeps a cold
            // start on a shared article from drawing the start page on the way past.
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                return ["accepted": true, "commands": session.showStartPage().json]
            }
            let shared = session.openShared(text)
            // `accepted` because a refusal is the host's to answer for: the start page it
            // gets instead says nothing about the link it handed over, and the warm path
            // rejects audibly for exactly this.
            return ["accepted": shared.accepted,
                    "commands": (shared.accepted ? shared.commands
                                                 : session.showStartPage()).json]
        }
    }

    // The two calls that wait for the network let go of the session while they wait: what
    // they await reaches no session state, and the answer is applied under the lock again.
    // Kotlin makes both off its main thread, which is what lets this block on the async work
    // rather than inventing a callback into the JVM for a result the caller is waiting for.
    switch call {
    case "suggestions":
        guard let session = Bridge.shared.current,
              let request = Bridge.shared.withSession({ $0.suggestionRequest() })
        else { return ["commands": []] }
        let items = blocking { await session.suggestions(for: request) }
        return Bridge.shared.withSession { answering($0, ["commands": $0.showSuggestions(items).json]) }
            ?? ["commands": []]

    case "resolveSource":
        guard let session = Bridge.shared.current, let url = url(arguments["url"])
        else { return ["commands": []] }
        let source = blocking { await session.resolveSource(url) }
        return Bridge.shared.withSession { answering($0, ["commands": $0.sourceResolved(source).json]) }
            ?? ["commands": []]

    default:
        return Bridge.shared.withSession { answering($0, dispatch(call, session: $0, arguments: arguments)) }
            ?? ["commands": []]
    }
}

/// Adds what every answer carries regardless of what was asked.
///
/// `reading` is which surface is up, and the host paints by it: the reader is the one page
/// with nothing to say about the phone, so it is the one page whose system bars go away. It
/// rides on every reply rather than on a command because a back or forward restore changes
/// the answer without issuing one — the web view walks its own history, and the only thing
/// that knows what landed is the session.
private func answering(_ session: ReaderSession, _ reply: [String: Any]) -> [String: Any] {
    var reply = reply
    reply["reading"] = session.isShowingReader
    return reply
}

/// Everything that answers without waiting for anything, and therefore runs start to finish
/// under the lock.
private func dispatch(_ call: String, session: ReaderSession,
                      arguments: [String: Any]) -> [String: Any] {
    switch call {
    case "openIncoming":
        guard let url = url(arguments["url"]) else { return ["accepted": false, "commands": []] }
        let opened = session.openIncoming(url)
        return ["accepted": opened.accepted, "commands": opened.commands.json]

    case "navigationStarted":
        session.navigationStarted()
        return ["commands": []]

    case "openShared":
        // What another app put in an ACTION_SEND intent, which is very often a headline with
        // a link inside it rather than a bare URL.
        guard let text = arguments["text"] as? String else { return ["accepted": false, "commands": []] }
        let shared = session.openShared(text)
        return ["accepted": shared.accepted, "commands": shared.commands.json]

    case "loadsInApp":
        // Navigation policy. The list is `WebURL.loadsInApp`'s, not the host's: `about:` and
        // `data:` are ours as much as `http` is, and a host that asked only about http/https
        // would hand its own generated pages to another app.
        guard let target = url(arguments["url"]) else { return ["value": false] }
        return ["value": session.loadsInApp(target)]

    case "navigationFinished":
        return ["commands": session.navigationFinished(
            url: url(arguments["url"]), generator: arguments["generator"] as? String ?? "").json]

    case "extractionResult":
        guard let url = url(arguments["url"]) else { return ["commands": []] }
        return ["commands": session.extractionResult(
            url: url, result: arguments["result"] as? String,
            title: arguments["title"] as? String).json]

    case "loadFailed":
        return ["commands": session.loadFailed(
            url: url(arguments["url"]), code: arguments["code"] as? Int ?? -1009).json]

    case "message":
        guard let name = arguments["name"] as? String,
              let body = ReaderSession.MessageBody(json: arguments["body"]) else { return ["commands": []] }
        return ["commands": session.message(name, body: body).json]

    case "toggleReader":
        return ["commands": session.toggleReader(currentURL: url(arguments["url"])).json]

    case "back":
        // Back, as the reader means it. Answers with nothing when it has no destination of its
        // own, and the host then falls through to the web view's history — or leaves the app,
        // which on Android is what Back means once there is nowhere left to go.
        //
        // Asked once and answered from that one answer: `back()` pops, so calling it twice to
        // fill two fields would walk two places back and show the wrong one.
        let commands = session.back()
        return ["commands": commands.json, "handled": !commands.isEmpty,
                "fallback": session.backFallback == .webViewHistory ? "webViewHistory" : "leave"]

    case "home":
        return ["commands": session.home().json]

    case "reload":
        return ["commands": session.reload().json]

    case "resetAppearance":
        return ["commands": session.resetAppearance().json]

    case "palette":
        // The colours a host has to paint where no page reaches: the cover a site loads
        // behind, the window under a document that has not painted yet, and the strips the
        // system bars leave beside an inset web view. The Apple hosts read the theme off the
        // store directly; Kotlin cannot, so it asks.
        //
        // `dark` is the host's answer for `.auto` — the same question the pages put to
        // `prefers-color-scheme`, asked of the one side that knows.
        //
        // `followsSystem` is what the answer was for: only under `.auto` may a host let its
        // web view decide anything about light and dark. Pinned, the theme is the user's
        // answer and the page carries it.
        let theme = ReaderStore.settings(store: session.store).theme
        let palette = ReaderPalette.stock(for: theme,
                                          prefersDark: arguments["dark"] as? Bool ?? false)
        return ["background": palette.bg, "text": palette.muted, "dark": palette.isDark,
                "followsSystem": theme == .auto, "commands": []]

    case "coverMessage":
        // The word on the cover while a site loads, from the same list the Apple and GTK
        // hosts draw from, with the same point size. A native cover on three platforms is
        // three views; what it says is one implementation, or the app introduces itself
        // differently depending on the phone in your hand.
        return ["message": LoadProgress.randomCoverMessage(),
                "size": LoadProgress.coverLabelSize, "commands": []]

    case "syncStatus":
        // What the settings page says about sync, and — because the page renders the section
        // only for a non-empty summary — whether it shows the section at all. The host owns
        // the folder picker and the wording that goes with it.
        return ["commands": session.syncStatus(
            folder: arguments["folder"] as? String,
            summary: arguments["summary"] as? String ?? "").json]

    case "syncPeers":
        return sync(session, arguments: arguments)

    default:
        return ["commands": []]
    }
}

/// A whole sync cycle over device files the host read from the document tree, and the file
/// it should write back.
///
/// The Storage Access Framework has no path, so `SyncFolder` cannot reach it — but the fold
/// never needed a filesystem, only the peers' bytes. `MemoryDeviceFiles` is what makes the
/// cycle a pure function here, and the host writes exactly what it is told to, or nothing.
private func sync(_ session: ReaderSession, arguments: [String: Any]) -> [String: Any] {
    guard let deviceID = arguments["deviceId"] as? String,
          let deviceName = arguments["deviceName"] as? String else { return ["commands": []] }
    let states = (arguments["states"] as? [String] ?? []).compactMap(DeviceState.fromJSON)
    let files = MemoryDeviceFiles(states: states)
    let engine = SyncEngine(folder: files, store: session.store,
                            device: DeviceState.Device(id: deviceID, name: deviceName))
    guard let result = try? engine.sync() else {
        // A cycle that failed leaves local state exactly as it was; there is nothing for the
        // host to do but try again on its next trigger.
        return ["commands": [], "peers": []]
    }
    var reply: [String: Any] = ["peers": result.peers, "commands": []]
    if let written = files.written {
        reply["writeFileName"] = written.fileName
        reply["writeContents"] = written.json
    }
    reply["commands"] = session.applySync(result).json
    return reply
}

// MARK: - Values across the boundary

private func url(_ value: Any?) -> URL? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return URL(string: string)
}

/// Runs an async call to completion on the calling thread.
///
/// The host promises this thread is not its main one — the contract says so for both calls
/// that reach here — so blocking it is the cheapest correct answer. The alternative, calling
/// back into the JVM when the work lands, would need an upcall and a global `JavaVM` for the
/// sake of a result the caller is already sitting and waiting for.
private func blocking<T>(_ work: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task {
        box.value = await work()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// A copy the caller owns. Swift's own buffer dies with the `String`, and handing JNI a
/// pointer into it is the kind of bug that only shows up under load.
private func duplicate(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: []))
        ?? Data("{\"commands\":[]}".utf8)
    return String(decoding: data, as: UTF8.self).withCString { strdup($0) }
}
