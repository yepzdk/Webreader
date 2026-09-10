import Foundation

/// The command and message vocabulary as JSON, for a host that is not written in Swift.
///
/// It lives here rather than beside the JNI facade because nothing but a test can hold the two
/// ends of that boundary together, and no test could reach it there: `ReaderKitAndroid` is in
/// the package only while cross-compiling, so a renamed `kind` compiled on both sides and
/// degraded at runtime to a logged "unknown command" on a phone. Pinned from `ReaderKitTests`,
/// which builds on macOS and Linux, a rename fails a build instead.
public extension ReaderCommand {
    /// This command as a JSON object, or nil when there is nothing worth sending across.
    var json: [String: Any]? {
        switch self {
        case let .load(url):
            return ["kind": "load", "url": url.absoluteString]
        case let .show(html, baseURL):
            return ["kind": "show", "html": html, "baseUrl": baseURL?.absoluteString as Any]
        case let .evaluate(script):
            // An empty script is the session saying "nothing to push"; sending it would cost a
            // hop across the boundary and a web view round trip to run nothing.
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

public extension Array where Element == ReaderCommand {
    /// The commands as JSON, in order, without the ones that had nothing to say.
    var json: [[String: Any]] { compactMap(\.json) }
}

public extension ReaderSession.MessageBody {
    /// What a page posted, as a host decoded it from its bridge envelope.
    ///
    /// The three shapes are all the pages ever send, and they are the same three WebKit
    /// bridges a posted value into. Anything else is a host bug and is refused rather than
    /// guessed at.
    init?(json: Any?) {
        if let text = json as? String {
            self = .text(text)
        } else if let list = json as? [String] {
            self = .list(list)
        } else if let fields = json as? [String: Any] {
            self = .object(fields.compactMapValues { field -> Value? in
                if let text = field as? String { return .text(text) }
                if let number = field as? Int { return .number(number) }
                return nil
            })
        } else {
            return nil
        }
    }
}
