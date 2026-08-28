import Foundation

/// Which of the app's own generated documents is on screen.
///
/// The host tracks this with flags rather than inferring it from `webView.url`, because a
/// `loadHTMLString` page has no URL of its own (WebKit reports `about:blank`). The
/// transitions are subtle enough to have shipped a bug — 0.10.0 cleared the flag on the very
/// navigation that set it, leaving the start page on screen with every message handler gated
/// shut — so the decision itself lives here, in the testable target, and the host only wires
/// WebKit's callbacks to it.
public struct PageState: Equatable, Sendable {
    public enum Page: String, Sendable {
        case none, startPage, settings, reader, fallback

        /// The `<meta name="generator">` a restored document identifies itself by. The
        /// reader's is matched EXACTLY by the extraction script, so it must stay "WebReader".
        public var generator: String? {
            switch self {
            case .startPage: return "WebReader Start"
            case .settings: return "WebReader Settings"
            case .reader: return "WebReader"
            case .none, .fallback: return nil
            }
        }

        public init?(generator: String) {
            switch generator {
            case "WebReader Start": self = .startPage
            case "WebReader Settings": self = .settings
            case "WebReader": self = .reader
            default: return nil
            }
        }
    }

    public private(set) var page: Page = .none
    /// True between starting one of our own `loadHTMLString` loads and its `didFinish`.
    public private(set) var isPending = false

    public init() {}

    /// The app is loading one of its own documents. The page is set now and survives the
    /// navigation callbacks that follow.
    public mutating func willShow(_ page: Page) {
        self.page = page
        isPending = true
    }

    /// Forgets the current page — the host's paths that explicitly leave a generated page
    /// (opening a link, rendering the reader, the offline fallback).
    public mutating func clear() {
        page = .none
        isPending = false
    }

    /// A navigation started. Anything we did not just start ourselves means the page on
    /// screen is about to be replaced — including back/forward off one of our own documents,
    /// which is a real history entry.
    public mutating func navigationStarted() {
        guard !isPending else { return }
        page = .none
    }

    /// A navigation finished. Returns the page now on screen; `nil` means "not one of ours —
    /// ask the document" (`restored(generator:)`), which is how back/forward onto a generated
    /// page is recognised.
    @discardableResult
    public mutating func navigationFinished() -> Page? {
        if isPending {
            isPending = false
            return page
        }
        return nil
    }

    /// Re-establishes the page from a restored document's generator marker.
    public mutating func restored(generator: String) {
        guard let restored = Page(generator: generator) else { return }
        page = restored
    }

    /// Whether the page on screen may post to the host's script message handlers. A live
    /// website must never reach them.
    public var isOwnPage: Bool {
        page != .none && page != .fallback || isPending
    }

    public var isShowingStartPage: Bool { page == .startPage }
    public var isShowingSettings: Bool { page == .settings }
}
