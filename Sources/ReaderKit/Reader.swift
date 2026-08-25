import Foundation

/// Reader mode's pure core: extracting an article from a page and rendering it as a
/// clean, distraction-free page. Everything here is string/JSON work — unit-tested;
/// the WebKit orchestration (when to extract, applying the result) lives in the host.

/// An article extracted by Readability, decoded from its `parse()` result.
public struct Article: Decodable, Equatable {
    public let title: String
    public let byline: String?
    public let siteName: String?
    /// The Readability-cleaned article body HTML (`<script>` is stripped upstream).
    public let content: String
}

/// The reader's appearance settings, adjustable from the in-reader "Aa" popover and
/// persisted per app. Plain persisted state like page zoom — there is no baked plist
/// default to layer over. Pure so decoding/encoding is unit-testable.
public struct ReaderSettings: Equatable {
    public enum FontFamily: String, CaseIterable {
        case serif, sans
        /// The CSS font stack. The serif stack matches the reader's original design;
        /// sans matches the meta-line stack used elsewhere in the generated pages.
        var css: String {
            switch self {
            case .serif: return "ui-serif, \"New York\", Georgia, serif"
            case .sans: return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Arial, sans-serif"
            }
        }
    }

    public enum Width: String, CaseIterable {
        case narrow, normal, wide
        var css: String {
            switch self {
            case .narrow: return "36rem"
            case .normal: return "42rem"
            case .wide: return "52rem"
            }
        }
    }

    public enum LineHeight: String, CaseIterable {
        case compact, normal, relaxed
        var css: String {
            switch self {
            case .compact: return "1.4"
            case .normal: return "1.6"
            case .relaxed: return "1.8"
            }
        }
    }

    /// `auto` follows the system light/dark appearance (the original behavior); the
    /// explicit themes pin a palette regardless of system appearance.
    public enum Theme: String, CaseIterable {
        case auto, light, sepia, dark, black
    }

    public var fontSize = 17
    public var fontFamily = FontFamily.serif
    public var width = Width.normal
    public var lineHeight = LineHeight.normal
    public var theme = Theme.auto

    public init() {}

    public static let fontSizeRange = 12...28

    /// Tolerant decode of a settings payload — a `WKScriptMessage.body` dictionary or
    /// a `JSONSerialization` object. Missing/unknown fields keep their defaults and
    /// the font size is clamped, so a garbled payload can never poison the reader.
    public static func decode(_ value: Any?) -> ReaderSettings {
        guard let dict = value as? [String: Any] else { return ReaderSettings() }
        var settings = ReaderSettings()
        if let size = dict["fontSize"] as? Int {
            settings.fontSize = min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
        }
        if let raw = dict["fontFamily"] as? String, let value = FontFamily(rawValue: raw) {
            settings.fontFamily = value
        }
        if let raw = dict["width"] as? String, let value = Width(rawValue: raw) {
            settings.width = value
        }
        if let raw = dict["lineHeight"] as? String, let value = LineHeight(rawValue: raw) {
            settings.lineHeight = value
        }
        if let raw = dict["theme"] as? String, let value = Theme(rawValue: raw) {
            settings.theme = value
        }
        return settings
    }

    /// The settings as a JSON string — the storage format, and (JSON being valid JS)
    /// what the reader page's script is seeded with.
    public var json: String {
        let dict: [String: Any] = [
            "fontSize": fontSize,
            "fontFamily": fontFamily.rawValue,
            "width": width.rawValue,
            "lineHeight": lineHeight.rawValue,
            "theme": theme.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes stored JSON, with the same tolerance as `decode` — nil/garbage means
    /// defaults, never an error.
    public static func fromJSON(_ string: String?) -> ReaderSettings {
        guard let string, let data = string.data(using: .utf8) else { return ReaderSettings() }
        return decode(try? JSONSerialization.jsonObject(with: data))
    }
}

public enum Reader {
    /// The script the host evaluates on a loaded page. Gates on the cheap
    /// `isProbablyReaderable` check, parses a CLONE of the document (Readability's
    /// parse is destructive), and returns the article as a JSON string — or `null`
    /// when the page isn't an article. The IIFE keeps the vendored sources out of
    /// the page's global scope.
    public static var extractionScript: String {
        """
        (function() {
        \(ReadabilityJS.readability)
        \(ReadabilityJS.readerable)
        if (!isProbablyReaderable(document)) { return null; }
        var article = new Readability(document.cloneNode(true)).parse();
        if (!article || !article.content) { return null; }
        return JSON.stringify({
          title: article.title || document.title || "",
          byline: article.byline,
          siteName: article.siteName,
          content: article.content
        });
        })()
        """
    }

    /// Decodes an `evaluateJavaScript` result into an `Article`. The script returns
    /// a JSON string or null, but be tolerant of anything else WebKit hands back —
    /// nil means "no article", never an error.
    public static func decode(_ jsResult: Any?) -> Article? {
        guard let json = jsResult as? String, !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(Article.self, from: Data(json.utf8))
    }
}

/// Renders an extracted article as the reader page. Shares the `--bg` light/dark
/// pattern with `StartPage`/`OfflineFallback`.
public enum ReaderPage {
    /// The complete reader document, loaded by the host as its OWN document via
    /// `loadHTMLString(_:baseURL:)` with the article URL as base — so relative image
    /// URLs keep resolving, and the article page's still-running JS dies with its
    /// document. (An in-place DOM swap was reverted within a second on hydrating
    /// sites — React re-rendering after `didFinish` — see #76.) Title and byline/site
    /// are escaped; `article.content` is inserted as-is (it's the Readability-cleaned
    /// HTML of the page the user was already viewing).
    ///
    /// Appearance is driven by `settings`, baked in as CSS custom properties plus a
    /// `data-theme` attribute; the in-page "Aa" popover adjusts the same properties
    /// live and posts the new settings to the host (`readerSettings`) for persistence.
    ///
    /// `history` is the recents list, baked into a sibling popover; its rows post the
    /// chosen URL to the host (`readerOpen`), which validates and navigates.
    /// Titles are escaped there too — they come from other sites' pages.
    public static func html(article: Article,
                            settings: ReaderSettings = ReaderSettings(),
                            history: ReaderHistory = ReaderHistory()) -> String {
        let title = HTML.escape(article.title)
        // Byline and site name merge into one muted meta line; either may be absent.
        let meta = [article.byline, article.siteName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(HTML.escape)
            .joined(separator: " \u{00B7} ")
        let metaLine = meta.isEmpty ? "" : "<p class=\"meta\">\(meta)</p>"
        let sans = ReaderSettings.FontFamily.sans.css
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings))>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(title)</title>
        <style>
          \(ReaderChrome.indent(ReaderChrome.themeCSS(settings), by: 10))
          * { box-sizing: border-box; }
          html, body { margin: 0; }
          body {
            background: var(--bg);
            color: var(--fg);
            font-family: var(--reader-font);
            font-size: var(--reader-size);
            line-height: var(--reader-leading);
            -webkit-font-smoothing: antialiased;
          }
          main { max-width: var(--reader-width); margin: 0 auto; padding: 48px 24px 96px; }
          header { margin-bottom: 40px; padding-bottom: 20px; border-bottom: 1px solid var(--border); }
          h1 { font-size: 1.65em; line-height: 1.25; letter-spacing: -0.01em; margin: 0; }
          .meta {
            color: var(--muted); margin: 10px 0 0;
            font: 0.82em/1.5 \(sans);
          }
          article h2 { font-size: 1.3em; line-height: 1.3; margin: 1.6em 0 0.6em; }
          article h3 { font-size: 1.12em; line-height: 1.3; margin: 1.4em 0 0.5em; }
          article p { margin: 0 0 1.2em; }
          article a { color: var(--accent); }
          article img, article video { max-width: 100%; height: auto; }
          article figure { margin: 28px 0; }
          article figcaption {
            color: var(--muted); font-size: 0.76em; margin-top: 8px;
            font-family: \(sans);
          }
          article blockquote {
            margin: 24px 0; padding-left: 16px;
            border-left: 3px solid var(--border); color: var(--muted);
          }
          article pre {
            overflow-x: auto; background: var(--surface);
            padding: 12px 14px; border-radius: 6px; font-size: 0.82em;
          }
          article code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
          article table { display: block; overflow-x: auto; border-collapse: collapse; }
          article td, article th { border: 1px solid var(--border); padding: 6px 10px; }
          article hr { border: 0; border-top: 1px solid var(--border); margin: 32px 0; }
          /* Appearance ("Aa") popover and recents list. Chrome UI, so it keeps the sans
             stack and fixed sizes regardless of the reading settings. */
          \(ReaderChrome.indent(ReaderChrome.controlsCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.progressCSS(), by: 10))
        </style>
        </head>
        <body>
          \(ReaderChrome.progressBar())
          \(ReaderChrome.indent(ReaderChrome.controls(history: history), by: 2))
          <main>
            <header>
              <h1>\(title)</h1>
              \(metaLine)
            </header>
            <article>\(article.content)</article>
          </main>
          <script>
          \(ReaderChrome.indent(ReaderChrome.controlsScript(settings: settings), by: 10))
          \(ReaderChrome.indent(ReaderChrome.progressScript(), by: 10))
          </script>
        </body>
        </html>
        """
    }
}
