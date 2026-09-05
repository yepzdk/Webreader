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

/// Everything the process keeps between calls. A class behind a lock rather than globals:
/// JNI makes no promise about which thread arrives, and a reader that corrupted its history
/// because two threads folded at once would be very hard to see.
private final class Bridge {
    static let shared = Bridge()
    private let lock = NSLock()
    private var session: ReaderSession?

    /// Builds the session on the first `start`, and rebuilds it if the host ever starts
    /// again — a second `start` means a new Activity over the same process, which Android
    /// does routinely, and reusing the old session would keep a page state that no longer
    /// matches anything on screen.
    func start(filesDirectory: String, cacheDirectory: String) -> ReaderSession {
        lock.withLock {
            let store = FileStore(fileURL: URL(fileURLWithPath: filesDirectory)
                .appendingPathComponent("reader.json"))
            let cache = ArticleCache(directory: URL(fileURLWithPath: cacheDirectory)
                .appendingPathComponent("articles"))
            let session = ReaderSession(store: store, cache: cache, appName: "WebReader",
                                        platform: .android)
            self.session = session
            return session
        }
    }

    /// The live session, or nil before `start`. Every other call is a no-op until then,
    /// which is the honest answer: there is nothing on screen to act on yet.
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
        let session = Bridge.shared.start(
            filesDirectory: arguments["filesDir"] as? String ?? "",
            cacheDirectory: arguments["cacheDir"] as? String ?? "")
        // `text`, not a URL: the launch link may have arrived in an ACTION_SEND extra with a
        // headline wrapped around it, and normalising it here is what keeps a cold start on a
        // shared article from drawing the start page on the way past.
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return ["commands": encode(session.showStartPage())]
        }
        let shared = session.openShared(text)
        return ["commands": encode(shared.accepted ? shared.commands : session.showStartPage())]
    }
    guard let session = Bridge.shared.current else { return ["commands": []] }

    switch call {
    case "openIncoming":
        guard let url = url(arguments["url"]) else { return ["accepted": false, "commands": []] }
        let opened = session.openIncoming(url)
        return ["accepted": opened.accepted, "commands": encode(opened.commands)]

    case "navigationStarted":
        session.navigationStarted()
        return ["commands": []]

    case "openShared":
        // What another app put in an ACTION_SEND intent, which is very often a headline with
        // a link inside it rather than a bare URL.
        guard let text = arguments["text"] as? String else { return ["accepted": false, "commands": []] }
        let shared = session.openShared(text)
        return ["accepted": shared.accepted, "commands": encode(shared.commands)]

    case "loadsInApp":
        // Navigation policy. The list is `WebURL.loadsInApp`'s, not the host's: `about:` and
        // `data:` are ours as much as `http` is, and a host that asked only about http/https
        // would hand its own generated pages to another app.
        guard let target = url(arguments["url"]) else { return ["value": false] }
        return ["value": session.loadsInApp(target)]

    case "navigationFinished":
        return ["commands": encode(session.navigationFinished(
            url: url(arguments["url"]), generator: arguments["generator"] as? String ?? ""))]

    case "extractionResult":
        guard let url = url(arguments["url"]) else { return ["commands": []] }
        return ["commands": encode(session.extractionResult(
            url: url, result: arguments["result"] as? String,
            title: arguments["title"] as? String))]

    case "loadFailed":
        return ["commands": encode(session.loadFailed(
            url: url(arguments["url"]), code: arguments["code"] as? Int ?? -1009))]

    case "message":
        guard let name = arguments["name"] as? String,
              let body = body(arguments["body"]) else { return ["commands": []] }
        return ["commands": encode(session.message(name, body: body))]

    case "toggleReader":
        return ["commands": encode(session.toggleReader(currentURL: url(arguments["url"])))]

    case "home":
        return ["commands": encode(session.home())]

    case "reload":
        return ["commands": encode(session.reload())]

    case "resetAppearance":
        return ["commands": encode(session.resetAppearance())]

    // The two calls that wait for the network. Kotlin makes them off its main thread, which
    // is what lets this block on the async work rather than inventing a callback into the
    // JVM for a result the host is already waiting for.
    case "suggestions":
        return ["commands": encode(blocking { await session.suggestions() })]

    case "resolveSource":
        guard let url = url(arguments["url"]) else { return ["commands": []] }
        return ["commands": encode(blocking { await session.resolveSource(url) })]

    case "syncStatus":
        // What the settings page says about sync, and — because the page renders the section
        // only for a non-empty summary — whether it shows the section at all. The host owns
        // the folder picker and the wording that goes with it.
        return ["commands": encode(session.syncStatus(
            folder: arguments["folder"] as? String,
            summary: arguments["summary"] as? String ?? ""))]

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
    reply["commands"] = encode(session.applySync(result))
    return reply
}

// MARK: - Values across the boundary

private func url(_ value: Any?) -> URL? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return URL(string: string)
}

/// What a page posted, as the host decoded it from the bridge envelope. The three shapes
/// are all the pages ever send; anything else is a host bug and is refused rather than
/// guessed at.
private func body(_ value: Any?) -> ReaderSession.MessageBody? {
    if let text = value as? String { return .text(text) }
    if let list = value as? [String] { return .list(list) }
    if let fields = value as? [String: Any] {
        return .object(fields.compactMapValues { field in
            if let text = field as? String { return .text(text) }
            if let number = field as? Int { return .number(number) }
            return nil
        })
    }
    return nil
}

private func encode(_ commands: [ReaderCommand]) -> [[String: Any]] {
    commands.compactMap { command in
        switch command {
        case let .load(url):
            return ["kind": "load", "url": url.absoluteString]
        case let .show(html, baseURL):
            return ["kind": "show", "html": html, "baseUrl": baseURL?.absoluteString as Any]
        case let .evaluate(script):
            // An empty script is the session saying "nothing to push"; sending it would cost
            // a JNI hop and a WebView round trip to run nothing.
            return script.isEmpty ? nil : ["kind": "evaluate", "script": script]
        case let .extract(url, script):
            return ["kind": "extract", "url": url.absoluteString, "script": script]
        case .reject:
            return ["kind": "reject"]
        case let .openExternally(url):
            return ["kind": "openExternally", "url": url.absoluteString]
        case .presentSyncSetup:
            return ["kind": "presentSyncSetup"]
        case .fetchSuggestions:
            return ["kind": "fetchSuggestions"]
        case let .resolveSource(url):
            return ["kind": "resolveSource", "url": url.absoluteString]
        }
    }
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
