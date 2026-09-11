import Foundation

/// Reader mode's pure core: extracting an article from a page and rendering it as a
/// clean, distraction-free page. Everything here is string/JSON work — unit-tested;
/// the WebKit orchestration (when to extract, applying the result) lives in the host.

/// An article extracted by Readability, decoded from its `parse()` result. Codable both
/// ways: the same shape is what `ArticleCache` keeps on disk.
public struct Article: Codable, Equatable, Sendable {
    public let title: String
    public let byline: String?
    public let siteName: String?
    /// The Readability-cleaned article body HTML (`<script>` is stripped upstream).
    public let content: String
    /// Blocks the hidden-phrase pass removed, per normalized phrase — what the eye-off badge
    /// and the popover's grouping show. Empty when nothing matched (or nothing was sent).
    public let hiddenHits: [String: Int]
    /// The page's lead image (`og:image`), absolute and http(s), or nil when the page named
    /// none. Carried through to recents so the start page can show a thumbnail (#25).
    public let image: String?

    public init(title: String, byline: String?, siteName: String?, content: String,
                hiddenHits: [String: Int] = [:], image: String? = nil) {
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.content = content
        self.hiddenHits = hiddenHits
        self.image = image
    }

    /// Only the decoder is hand-written (for tolerance); with the key spelled out here the
    /// compiler synthesizes `encode(to:)`, so a new field can't be forgotten on the way out.
    private enum CodingKeys: String, CodingKey {
        case title, byline, siteName, content, image, hiddenHits = "hidden"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        byline = try c.decodeIfPresent(String.self, forKey: .byline)
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        content = try c.decode(String.self, forKey: .content)
        // Tolerant: a missing or malformed map is "no hits", never a failed article.
        hiddenHits = (try? c.decodeIfPresent([String: Int].self, forKey: .hiddenHits)) ?? [:]
        // Absent in every article cached before #25, and in any page that names no image.
        image = try c.decodeIfPresent(String.self, forKey: .image)
    }
}

/// The reader's appearance settings, adjustable from the in-reader "Aa" popover and
/// persisted per app. Plain persisted state like page zoom — there is no baked plist
/// default to layer over. Pure so decoding/encoding is unit-testable.
public struct ReaderSettings: Equatable, Sendable {
    public enum FontFamily: String, CaseIterable, Sendable {
        case serif, sans
        /// The CSS font stack for the platform the page will be displayed on. The macOS
        /// stacks are the reader's original design; `Platform` explains why the choice is a
        /// value rather than a compile-time branch.
        ///
        /// Deliberately undefaulted: every caller is a page fragment that already knows its
        /// platform, so a site someone forgets to thread should fail to compile rather than
        /// quietly render Apple faces on a machine that has none of them installed.
        func css(on platform: Platform) -> String {
            switch self {
            case .serif: return platform.serifStack
            case .sans: return platform.sansStack
            }
        }
    }

    public enum Width: String, CaseIterable, Sendable {
        case narrow, normal, wide
        var css: String {
            switch self {
            case .narrow: return "36rem"
            case .normal: return "42rem"
            case .wide: return "52rem"
            }
        }

        /// What the setting means where `css` cannot mean anything.
        ///
        /// A phone's viewport is about 26rem, so every one of those three max-widths is wider
        /// than the screen and the control does nothing at all there. The measure that is left
        /// is the gutter, so on a compact viewport the setting picks that instead: `normal`
        /// stays where the 24px baseline already was, and the other two are visibly narrower
        /// and wider than it. A percentage rather than pixels, because a 320px phone and a
        /// 480px one want the same proportion, not the same margin.
        var compactGutter: String {
            switch self {
            case .narrow: return "12%"
            case .normal: return "6%"
            case .wide: return "2%"
            }
        }
    }

    public enum LineHeight: String, CaseIterable, Sendable {
        case compact, normal, relaxed
        var css: String {
            switch self {
            case .compact: return "1.4"
            case .normal: return "1.6"
            case .relaxed: return "1.8"
            }
        }
    }

    /// `auto` follows the host: the system light/dark appearance, or — where the host can
    /// resolve one — the desktop's whole palette (`ReaderPalette`, #16). The explicit
    /// themes pin their own palette regardless of either, which is what they are for.
    public enum Theme: String, CaseIterable, Sendable {
        case auto, light, sepia, dark, black
    }

    /// How inline quotations (»…«, “…”) are set: a left border on the paragraph with the
    /// quote in medium weight, or plain italics.
    public enum QuoteStyle: String, CaseIterable, Sendable {
        case bordered, italic
    }

    /// Whether a list of articles shows lead-image thumbnails (#25). An enum rather than a
    /// Bool so it decodes and encodes exactly like every other setting — including keeping
    /// the default when a stored value is unrecognised.
    public enum ArticleImages: String, CaseIterable, Sendable {
        case on, off
    }

    /// Which of the start page's two lists comes first. An enum rather than a Bool for the
    /// same reason `ArticleImages` is one: it decodes, encodes and falls back to the default
    /// exactly like every other setting.
    public enum StartPageOrder: String, CaseIterable, Sendable {
        case recentsFirst, suggestionsFirst
    }

    /// Which edge the reader's controls sit against.
    ///
    /// A handedness setting, and only a touch device can have one: a tablet is held, and the
    /// hand holding it is the hand that reaches the chrome. Where a mouse does the reaching
    /// the corner it starts from costs nothing, so the pointer layouts read this too but
    /// nobody has to.
    public enum ControlSide: String, CaseIterable, Sendable {
        case right, left
    }

    public var fontSize = 17
    public var fontFamily = FontFamily.serif
    public var width = Width.normal
    public var lineHeight = LineHeight.normal
    public var theme = Theme.auto
    public var quoteStyle = QuoteStyle.bordered
    /// Thumbnails beside the start page's recents and suggestions, and beside the reader
    /// popover's two groups (#33) — one switch per surface, since each page shows only its
    /// own lists and a thumbnail nobody sees is a request nobody asked for.
    ///
    /// On by default — the images are the point of the feature — and off is a real choice:
    /// with a surface off, its rows carry no image, reserve no column and fetch nothing,
    /// which is what the start page did before #25.
    public var startPageThumbnails = ArticleImages.on
    public var readerThumbnails = ArticleImages.on
    /// Which list the start page leads with. Recents by default, which is where the page has
    /// always started; someone who mostly comes here to find something new scrolls past
    /// their own history to reach it, and on a phone that history is the whole first screen.
    ///
    /// Unconditional, with no viewport branch: the cramped screen is what makes the order
    /// matter, but a reader who wants suggestions first wants them first in a window too,
    /// and one order is one thing to explain rather than two that disagree at 60rem.
    public var startPageOrder = StartPageOrder.recentsFirst
    /// The edge the reader's chrome sits against. Right by default, which is where it has
    /// always been and which suits the majority hand.
    public var controlSide = ControlSide.right
    /// The colour links and pressed controls take (#45).
    ///
    /// A short list rather than a colour well, because the value has to clear 4.5:1 against
    /// four backgrounds and a free choice cannot be made to. Each name resolves to its own
    /// hex per theme — the shade that reads on sepia is not the one that reads on black —
    /// and `ReaderPaletteTests` recomputes every pair rather than trusting this comment.
    public enum Accent: String, CaseIterable, Sendable {
        case blue, teal, violet, rust, moss
    }

    /// Hosts the reader stays out of the way on.
    ///
    /// A paywalled site cannot be logged into through an extracted copy of it: the login
    /// form, the cookie banner it hides behind and the "you are now signed in" answer are
    /// all the site's own page (#44). Naming the host rather than the article is what makes
    /// that work — signing in is several pages long, and every one of them has to be the
    /// site's.
    ///
    /// A setting rather than a suggestion preference, so it travels between devices with
    /// the rest of them: signing in on the iPad should not leave the phone extracting the
    /// paywall notice.
    public var originalHosts: Set<String> = []
    /// Blue, which is what every reader already has.
    public var accent = Accent.blue

    /// How loudly the accent is applied (#45, second pass).
    ///
    /// The hue answers *which* colour; this answers *how much of it*, and they are separate
    /// questions: someone who wants links barely distinguishable from the prose still has a
    /// favourite colour for the one place it shows. Four levels, quietest last:
    ///
    /// - `text` — the body colour. Links are revealed by their underline alone, which is
    ///   the only tell that works for a reader who cannot separate the hues anyway.
    /// - `bright` — the saturated shades, which is what 0.13.0 shipped.
    /// - `tinted` — the ink with the hue mixed in at the same lightness. Measured against
    ///   the page it lands within a point of the body text's own contrast.
    /// - `hushed` — the quietest that still clears 4.5:1 as a colour in its own right.
    ///
    /// `hushed` by default: the saturated links read as noise in a page whose whole point
    /// is the absence of it, and every shipped reader was looking at `bright` until now.
    public enum Highlight: String, CaseIterable, Sendable {
        case text, bright, tinted, hushed
    }

    public var highlight = Highlight.hushed

    public init() {}

    public static let fontSizeRange = 12...28

    /// Tolerant decode of a settings payload — a `WKScriptMessage.body` dictionary or
    /// a `JSONSerialization` object. Unknown fields are ignored and the font size is clamped,
    /// so a garbled payload can never poison the reader.
    ///
    /// `onto` is what an absent field falls back to, and it is the reason a page may post only
    /// the fields it owns: the host seeds this with the settings as stored, so a payload
    /// carrying one key changes one key. Defaulting it to a fresh `ReaderSettings` keeps the
    /// "missing means default" behaviour for every other caller.
    public static func decode(_ value: Any?, onto base: ReaderSettings = ReaderSettings()) -> ReaderSettings {
        guard let dict = value as? [String: Any] else { return base }
        var settings = base
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
        if let raw = dict["quoteStyle"] as? String, let value = QuoteStyle(rawValue: raw) {
            settings.quoteStyle = value
        }
        // 0.11.0 stored one `startPageImages`, when the start page was the only surface with
        // thumbnails. It meant "no thumbnails", so it seeds both switches rather than leaving
        // the reader's on and fetching images the user had already opted out of. Only the two
        // current keys are ever written.
        if let raw = dict["startPageImages"] as? String, let value = ArticleImages(rawValue: raw) {
            settings.startPageThumbnails = value
            settings.readerThumbnails = value
        }
        if let raw = dict["startPageThumbnails"] as? String, let value = ArticleImages(rawValue: raw) {
            settings.startPageThumbnails = value
        }
        if let raw = dict["readerThumbnails"] as? String, let value = ArticleImages(rawValue: raw) {
            settings.readerThumbnails = value
        }
        if let raw = dict["startPageOrder"] as? String, let value = StartPageOrder(rawValue: raw) {
            settings.startPageOrder = value
        }
        if let raw = dict["controlSide"] as? String, let value = ControlSide(rawValue: raw) {
            settings.controlSide = value
        }
        if let raw = dict["accent"] as? String, let value = Accent(rawValue: raw) {
            settings.accent = value
        }
        if let raw = dict["highlight"] as? String, let value = Highlight(rawValue: raw) {
            settings.highlight = value
        }
        if let hosts = dict["originalHosts"] as? [String] {
            settings.originalHosts = Set(hosts.filter { !$0.isEmpty })
        }
        return settings
    }

    /// The storage format as a `JSONSerialization` object, so a sync device file can nest
    /// it without round-tripping through a string.
    public var jsonObject: [String: Any] {
        [
            "fontSize": fontSize,
            "fontFamily": fontFamily.rawValue,
            "width": width.rawValue,
            "lineHeight": lineHeight.rawValue,
            "theme": theme.rawValue,
            "quoteStyle": quoteStyle.rawValue,
            "startPageThumbnails": startPageThumbnails.rawValue,
            "readerThumbnails": readerThumbnails.rawValue,
            "startPageOrder": startPageOrder.rawValue,
            "controlSide": controlSide.rawValue,
            // Sorted, because two devices holding the same set must write the same bytes or
            // sync rewrites the file forever.
            "accent": accent.rawValue,
            "highlight": highlight.rawValue,
            "originalHosts": originalHosts.sorted(),
        ]
    }

    /// The settings as a JSON string — the storage format, and (JSON being valid JS)
    /// what the reader page's script is seeded with.
    public var json: String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject,
                                                    options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes stored JSON, with the same tolerance as `decode` — nil/garbage means the
    /// fallback, never an error.
    public static func fromJSON(_ string: String?,
                                onto base: ReaderSettings = ReaderSettings()) -> ReaderSettings {
        guard let string, let data = string.data(using: .utf8) else { return base }
        return decode(try? JSONSerialization.jsonObject(with: data), onto: base)
    }

    /// Which of the two thumbnail switches governs a page's lists.
    ///
    /// The raw value is the settings key, so the page's `data-thumbs` decision, the chrome
    /// script's live lookup and the settings page's checkbox ids all name the field exactly
    /// once. A page with no article lists (settings, offline) has no scope.
    public enum ThumbnailScope: String, CaseIterable {
        case startPage = "startPageThumbnails"
        case reader = "readerThumbnails"
    }

    /// The switch governing `scope`.
    public func thumbnails(_ scope: ThumbnailScope) -> ArticleImages {
        switch scope {
        case .startPage: return startPageThumbnails
        case .reader: return readerThumbnails
        }
    }
}

public enum Reader {
    /// What `extractionScript` returns on one of our own reader documents (they carry the
    /// generator `<meta>`), instead of extracting the rendering a second time. `decode`
    /// treats it as "no article"; the host treats it as "already the reader".
    public static let ownPageSentinel = "webreader-page"

    /// What `extractionScript` returns for a document that is not a web page at all — a feed,
    /// an XML file, anything an engine chose to render as markup rather than hand back.
    ///
    /// Distinct from "not an article", which leaves the site on screen as the honest answer:
    /// there is no site here to leave, only a file — and the two engines disagree about what
    /// to do with one. WebKit refuses to display it and cancels the response; Chromium renders
    /// its own XML view, which Readability will happily extract into an article made of angle
    /// brackets. This is the one answer that covers both.
    public static let notAPageSentinel = "webreader-not-a-page"

    /// Wraps inline quotations in `<span class="q">` so the page can style them, and marks a
    /// paragraph that opens with a quote `qp` (quotation plus attribution — the common shape
    /// of "»…,« siger X"). Text nodes only, and only inside `<p>`; a pair must open and
    /// close in the same text node.
    static let quoteScript = """
    function readerWrapQuotes(root) {
      var PAIRS = { '»': '«', '“': '”', '”': '”', '„': '“', '"': '"' };
      var OPEN = /[»“”„"]/;
      Array.prototype.forEach.call(root.querySelectorAll('p'), function (p) {
        var doc = p.ownerDocument;
        var walker = doc.createTreeWalker(p, 4 /* NodeFilter.SHOW_TEXT */);
        var nodes = [];
        while (walker.nextNode()) { nodes.push(walker.currentNode); }
        nodes.forEach(function (node) {
          if (node.parentNode.closest('code, pre')) { return; }
          var text = node.nodeValue, frag = null, cut = 0, i = 0;
          while (i < text.length) {
            var rel = text.slice(i).search(OPEN);
            if (rel < 0) { break; }
            var start = i + rel;
            var end = text.indexOf(PAIRS[text[start]], start + 1);
            // ponytail: a quote that closes in another node (a link inside it) stays plain;
            // cross-node matching isn't worth the code until it shows up.
            if (end < 0) { i = start + 1; continue; }
            frag = frag || doc.createDocumentFragment();
            frag.appendChild(doc.createTextNode(text.slice(cut, start)));
            var q = doc.createElement('span');
            q.className = 'q';
            q.textContent = text.slice(start, end + 1);
            frag.appendChild(q);
            cut = i = end + 1;
          }
          if (!frag) { return; }
          frag.appendChild(doc.createTextNode(text.slice(cut)));
          node.parentNode.replaceChild(frag, node);
        });
        if (p.querySelector('.q') && OPEN.test(p.textContent.trim().charAt(0))) { p.classList.add('qp'); }
      });
    }
    """

    /// Reads the page's own lead image — the one the publisher nominated for a link
    /// preview — for the start page's recents thumbnails (#25).
    ///
    /// `og:image` (then Twitter's equivalent) rather than the first `<img>` in the body: an
    /// editorially chosen image beats a logo or a tracking pixel, which is what the first
    /// body image usually is. Read from the LIVE document, because Readability's result
    /// carries no image field and patching the vendored copy to expose one is not on.
    ///
    /// Absolutised against the document, since the start page is an `about:blank` document
    /// where a relative URL resolves to nothing, and restricted to http(s): the value is
    /// somebody else's markup, and no other scheme has any business in an `<img src>`.
    static let leadImageScript = """
    function readerLeadImage() {
      var selectors = ['meta[property="og:image"]', 'meta[property="og:image:url"]',
                       'meta[name="twitter:image"]', 'meta[name="twitter:image:src"]'];
      for (var i = 0; i < selectors.length; i++) {
        var tag = document.querySelector(selectors[i]);
        var raw = tag && tag.getAttribute('content');
        if (!raw || !raw.trim()) { continue; }
        try {
          var url = new URL(raw.trim(), document.baseURI);
          if (url.protocol === 'http:' || url.protocol === 'https:') { return url.href; }
        } catch (err) {}
      }
      return null;
    }
    """

    /// The script the host evaluates on a loaded page. Returns `ownPageSentinel` for our own
    /// reader document (back/forward can land on one), otherwise gates on the cheap
    /// `isProbablyReaderable` check, parses a CLONE of the document (Readability's parse is
    /// destructive), strips the `hiding` phrases, wraps quotations, and returns the article as
    /// a JSON string — or `null` when the page isn't an article. The IIFE keeps the vendored
    /// sources out of the page's global scope.
    ///
    /// The post-passes run on a `DOMParser` document: no browsing context, so the article's
    /// images aren't fetched a first time just to be filtered.
    public static func extractionScript(hiding hidden: HiddenPhrases = HiddenPhrases()) -> String {
        """
        (function() {
        \(ReadabilityJS.readability)
        \(ReadabilityJS.readerable)
        \(HiddenPhrases.hideScript)
        \(quoteScript)
        \(leadImageScript)
        if (document.querySelector('meta[name="generator"][content="WebReader"]')) { return "\(ownPageSentinel)"; }
        // Readability is for HTML. An engine that renders XML in place hands this script a
        // perfectly parseable document whose "article" would be the markup itself.
        var type = (document.contentType || '').toLowerCase();
        if (type && type !== 'text/html' && type !== 'application/xhtml+xml') {
          return "\(notAPageSentinel)";
        }
        if (!isProbablyReaderable(document)) { return null; }
        var article = new Readability(document.cloneNode(true)).parse();
        if (!article || !article.content) { return null; }
        var doc = new DOMParser().parseFromString(article.content, 'text/html');
        var hidden = readerHideBlocks(doc.body, \(hidden.scriptLiteral));
        readerWrapQuotes(doc.body);
        return JSON.stringify({
          title: article.title || document.title || "",
          byline: article.byline,
          siteName: article.siteName,
          content: doc.body.innerHTML,
          hidden: hidden.hits,
          image: readerLeadImage()
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
    /// `history` is the recents list. The popover shows the newest few of them, and its rows
    /// post the chosen URL to the host (`readerOpen`), which validates and navigates. Titles
    /// are escaped there too — they come from other sites' pages.
    ///
    /// `currentURL` is the article this page is showing, as the *cleaned* key
    /// `ReaderHistory.record` was given (`URLCleaner.clean(source).absoluteString`) — it is
    /// compared against the stored rows, so a raw URL silently matches nothing and the
    /// article on screen comes back as row one. nil excludes nothing.
    ///
    /// `hidden` is the phrase list for the third popover; the page also re-applies it live
    /// when the host learns a new phrase (`window.readerSetHidden`).
    ///
    /// `platform` selects the font stacks. It defaults to macOS so the AppKit host and its
    /// call sites need no argument; a GTK host passes `.linux` and gets faces that actually
    /// resolve there.
    ///
    /// `palette` is the desktop palette for `Theme.auto` and defaults to nil, which keeps
    /// the `prefers-color-scheme` fallback the AppKit host relies on. See `ReaderPalette`.
    public static func html(article: Article,
                            settings: ReaderSettings = ReaderSettings(),
                            history: ReaderHistory = ReaderHistory(),
                            hidden: HiddenPhrases = HiddenPhrases(),
                            rating: TopicPreferences.Rating? = nil,
                            currentURL: String? = nil,
                            platform: Platform = .macOS,
                            palette: ReaderPalette? = nil) -> String {
        let title = HTML.escape(article.title)
        // Byline and site name merge into one muted meta line; either may be absent.
        let meta = [article.byline, article.siteName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(HTML.escape)
            .joined(separator: " \u{00B7} ")
        let metaLine = meta.isEmpty ? "" : "<p class=\"meta\">\(meta)</p>"
        let sans = platform.sansStack
        // Hit counts are keyed by normalized phrase — plain ASCII/word text — but they came
        // from a page, so they take the same `</`-safe route as the phrase list.
        let hits = (try? JSONSerialization.data(withJSONObject: article.hiddenHits, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        <!doctype html>
        <html lang="en"\(ReaderChrome.themeAttribute(settings, thumbnails: .reader))>
        <head>
        <meta charset="utf-8">
        \(ReaderChrome.viewportMeta)
        <meta name="color-scheme" content="light dark">
        <meta name="generator" content="WebReader">
        <title>\(title)</title>
        \(ReaderChrome.transportScript(platform: platform))
        <style>
          \(ReaderChrome.indent(ReaderChrome.themeCSS(settings, platform: platform,
                                                      palette: palette), by: 10))
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
          main {
            max-width: var(--reader-width); margin: 0 auto;
            padding-top: \(ReaderChrome.inset(ReaderChrome.topHeadroom, "top"));
            padding-bottom: \(ReaderChrome.inset(96, "bottom"));
            padding-left: max(24px, var(--safe-left));
            padding-right: max(24px, var(--safe-right));
          }
          /* Two overrides of the head, for the two things that can be up there.

             The base headroom clears the top backdrop, which is where the article can start
             without the fade greying its first line. A coarse pointer with room for the
             chrome at the top — a tablet — grows the buttons to the touch floor, so both the
             cluster and the fade below it reach further down.

             A compact viewport has moved the chrome to the bottom-right corner and hidden
             the backdrop, so nothing is up there but the progress hairline and the headroom
             goes back to being the article's own. Last, so it wins where both match. The
             96px foot is what clears the toggle, which ends 58px up. */
          @media (pointer: coarse) {
            main { padding-top: \(ReaderChrome.inset(ReaderChrome.touchTopHeadroom, "top")); }
          }
          @media \(ReaderChrome.compactViewport) {
            main {
              padding-top: \(ReaderChrome.inset(48, "top"));
              /* Here the width setting is the gutter: `max-width` is unreachable on a screen
                 narrower than the narrowest of them, so without this all three read alike. */
              padding-left: max(var(--reader-gutter), var(--safe-left));
              padding-right: max(var(--reader-gutter), var(--safe-right));
            }
          }
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
          /* Inline quotations are wrapped in .q at extraction; a paragraph opening with one
             is .qp. Bordered by default; data-quotes="italic" swaps the treatment. Medium
             weight needs a face that has one (New York and Noto Serif do; Georgia and
             Liberation Serif fall back to regular, and the border still carries the quote). */
          article p.qp { padding-left: 14px; border-left: 3px solid var(--border); }
          article .q { font-weight: 500; }
          :root[data-quotes="italic"] article p.qp { padding-left: 0; border-left: 0; }
          :root[data-quotes="italic"] article .q { font-weight: inherit; font-style: italic; }
          /* Appearance ("Aa") popover and recents list. Chrome UI, so it keeps the sans
             stack and fixed sizes regardless of the reading settings. */
          \(ReaderChrome.indent(ReaderChrome.controlsCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.navCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.progressCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.backdropCSS(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.toastCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(HiddenPhrases.hideAffordanceCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.readNextCSS(platform: platform), by: 10))
          \(ReaderChrome.indent(ReaderChrome.chromeCSS(platform: platform,
                                                       collapsible: true), by: 10))
        </style>
        </head>
        <body>
          \(ReaderChrome.backdrop())
          \(ReaderChrome.progressBar())
          \(ReaderChrome.indent(ReaderChrome.chrome(
                nav: ReaderChrome.navHome(),
                controls: ReaderChrome.controls(
                    recents: history.recents(limit: ReaderChrome.popoverRecents,
                                             excluding: currentURL),
                    canClear: !history.entries.isEmpty,
                    showsRating: true, rating: rating,
                    showsHidden: true, showsOriginal: true, showsQuotes: true),
                collapsible: true), by: 2))
          <main>
            <header>
              <h1>\(title)</h1>
              \(metaLine)
            </header>
            <article>\(article.content)</article>
            \(ReaderChrome.readNextMarkup())
          </main>
          \(ReaderChrome.toastMarkup())
          <script>
          \(ReaderChrome.indent(ReaderChrome.controlsScript(settings: settings,
                                                             thumbnails: .reader,
                                                             hidden: hidden,
                                                             hitsJSON: HTML.jsLiteral(hits),
                                                             platform: platform,
                                                             hostedAccent: settings.theme == .auto
                                                                 && palette != nil), by: 10))
          \(ReaderChrome.indent(ReaderChrome.progressScript(), by: 10))
          \(ReaderChrome.indent(ReaderChrome.toastScript(), by: 10))
          \(ReaderChrome.indent(HiddenPhrases.hideAffordanceJS(), by: 10))
          </script>
        </body>
        </html>
        """
    }
}
