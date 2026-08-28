import Foundation

/// Boilerplate sentences the reader removes from articles — "Artiklen fortsætter efter
/// annoncen", ad labels, and whatever the user teaches it by selecting text in the reader.
///
/// A block element is removed only when its ENTIRE text is one of these phrases (compared
/// case- and whitespace-insensitively, trailing punctuation ignored); a paragraph that merely
/// contains a phrase is never touched. That keeps a learned phrase from ever eating prose.
///
/// One flat list, seeded with `defaults` the first time it's read and editable from then on
/// (so a default that misfires can be removed too). Persisted as a JSON array string, like
/// `ReaderHistory`. Pure — the matching itself runs in JS (`hideScript`), where the DOM is.
public struct HiddenPhrases: Equatable {
    public static let defaults = [
        "Artiklen fortsætter efter annoncen",
        "Artiklen fortsætter under annoncen",
        "Annonce",
        "Advertisement",
        "Article continues below advertisement",
        "Story continues below advertisement",
        "Continue reading below",
    ]

    /// Caps keep a stored blob and the popover bounded; a selection longer than
    /// `maxLength` is a paragraph, not boilerplate.
    public static let limit = 100
    public static let maxLength = 200

    /// Newest first, so the popover shows what was just learned at the top.
    public var phrases: [String]

    /// The stock list.
    public init() { phrases = Self.defaults }

    public init(_ phrases: [String]) { self.phrases = phrases }

    /// The comparison key — the Swift twin of `readerNormalize` in `hideScript`, used here
    /// only to dedupe. Lowercase, whitespace collapsed, trailing `.`/`:`/`…` dropped.
    public static func normalize(_ text: String) -> String {
        var key = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = key.last, ".:…".contains(last) { key.removeLast() }
        return key
    }

    /// Adds a phrase (whitespace collapsed). Returns false — nothing stored — when it's
    /// empty, longer than `maxLength`, or already in the list, so the host can beep.
    @discardableResult
    public mutating func add(_ raw: String) -> Bool {
        let phrase = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !phrase.isEmpty, phrase.count <= Self.maxLength else { return false }
        let key = Self.normalize(phrase)
        guard !key.isEmpty, !phrases.contains(where: { Self.normalize($0) == key }) else { return false }
        phrases.insert(phrase, at: 0)
        if phrases.count > Self.limit { phrases.removeLast(phrases.count - Self.limit) }
        return true
    }

    public mutating func remove(_ phrase: String) {
        phrases.removeAll { $0 == phrase }
    }

    /// The storage format: a JSON array of strings.
    public var json: String {
        guard let data = try? JSONSerialization.data(withJSONObject: phrases, options: [])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The list as a JS array literal, safe to interpolate inside a `<script>` — see
    /// `HTML.jsLiteral`. A learned phrase is article text, so it can carry `</script>` or a
    /// line separator.
    public var scriptLiteral: String {
        HTML.jsLiteral(json)
    }

    /// nil (never stored) or garbage → the defaults; a stored array is taken as-is, so an
    /// emptied list stays empty. Non-string or oversized rows are dropped, the cap re-applied.
    public static func fromJSON(_ string: String?) -> HiddenPhrases {
        guard let string, let data = string.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return HiddenPhrases() }
        var list = HiddenPhrases(array.compactMap { row in
            guard let phrase = row as? String, !phrase.isEmpty, phrase.count <= maxLength else { return nil }
            return phrase
        })
        if list.phrases.count > limit { list.phrases.removeLast(list.phrases.count - limit) }
        return list
    }

    /// The JS that does the removing. Defines `readerNormalize(text)` and
    /// `readerHideBlocks(root, phrases)`; shared verbatim by the extraction script (on the
    /// parsed article, so the reader never flashes the blocks) and the reader page (live,
    /// after a phrase is learned). Only block-level elements are candidates: removing an
    /// `<em>` whose text happens to equal "Advertisement" would rewrite a sentence.
    ///
    /// Returns `{ total, hits }` — blocks removed, and per normalized phrase — which feeds
    /// the eye-off badge and the popover's "removed from this article" group.
    public static let hideScript = """
    function readerNormalize(text) {
      return text.toLowerCase().replace(/\\s+/g, ' ').trim().replace(/[\\s.:…]+$/, '');
    }
    function readerHideBlocks(root, phrases) {
      var result = { total: 0, hits: {} };
      if (!root || !phrases.length) { return result; }
      var wanted = {};
      phrases.forEach(function (p) { var n = readerNormalize(p); if (n) { wanted[n] = true; } });
      var BLOCKS = 'p,div,section,aside,header,footer,h1,h2,h3,h4,h5,h6,li,ul,ol,' +
                   'figure,figcaption,blockquote,table,tr,td,th,pre,dd,dt';
      var MEDIA = 'img,video,iframe,picture,svg';
      // ponytail: textContent per block is O(n·depth); fine for article-sized DOMs.
      Array.prototype.slice.call(root.querySelectorAll(BLOCKS)).forEach(function (el) {
        // Document order puts a wrapper before its child; once the wrapper is gone the
        // child is detached and must not be processed again.
        var key = readerNormalize(el.textContent);
        if (!root.contains(el) || !wanted[key]) { return; }
        result.total += 1;
        result.hits[key] = (result.hits[key] || 0) + 1;
        var parent = el.parentNode;
        el.remove();
        // A wrapper left with no text and no media would keep its margins as a gap.
        while (parent && parent !== root && !parent.textContent.trim() && !parent.querySelector(MEDIA)) {
          var next = parent.parentNode;
          parent.remove();
          parent = next;
        }
      });
      return result;
    }
    """

    /// The floating "Hide text" button's styling. The affordance lives in the page rather
    /// than in a menu because the host may not have a menu bar at all (the GTK host has
    /// none), and `window.webkit.messageHandlers` is the same API on WebKitGTK as on
    /// `WKWebView` — so the page-side route is the only one that ports.
    ///
    /// Accent-filled like the pressed rating buttons, and `z-index: 8` keeps it below
    /// `.reader-controls` (10) and the progress line (9): an open popover must never be
    /// crossed by a button floating over the article.
    ///
    /// The button is chrome, so it takes the host platform's sans stack — defaulted, so
    /// the AppKit host and its tests keep calling this with no arguments.
    public static func hideAffordanceCSS(platform: Platform = .macOS) -> String {
        """
        #readerHideBtn {
          position: fixed; top: 0; left: 0; z-index: 8;
          display: none; align-items: center; gap: 6px;
          margin: 0; padding: 6px 10px;
          border: 1px solid var(--accent); border-radius: 6px;
          background: var(--accent); color: #fff;
          font-family: \(platform.sansStack); font-size: 12px; line-height: 1.3;
          cursor: pointer;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12);
          /* The button sits right beside the selection; its own label must not become part
             of it when a drag overshoots. */
          -webkit-user-select: none; user-select: none;
        }
        #readerHideBtn[data-shown="true"] { display: flex; }
        #readerHideBtn svg { display: block; }
        """
    }

    /// Creates the button and wires it to the selection: shown above (or below, at the top
    /// edge) the selection while it is non-empty and inside `<article>`, hidden when the
    /// selection collapses, on scroll, and on Escape.
    ///
    /// Posts `window.getSelection().toString()` to `readerHide` — the exact string the old
    /// menu item sent, so the stored-phrase semantics are unchanged: `add` normalizes, and
    /// matching stays whole-block-text only. The `try`/`catch` is the same shape as every
    /// other `postMessage` in a generated page: a page opened outside the host has no
    /// `webkit` object, and an unregistered name throws.
    ///
    /// Nothing here is platform-specific, and it self-disables where there is no article
    /// (the start page), so it can be dropped into any page that has one.
    public static func hideAffordanceJS() -> String {
        """
        (function () {
          var article = document.querySelector('article');
          if (!article) { return; }
          var ICON = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" ' +
            'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
            'stroke-linejoin="round" aria-hidden="true">' +
            '<path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/>' +
            '<path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/>' +
            '<path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/>' +
            '<path d="m2 2 20 20"/></svg>';
          var btn = document.createElement('button');
          btn.id = 'readerHideBtn';
          btn.type = 'button';
          btn.title = 'Hide this text in every article';
          // Constant markup only — the selected text never takes the markup path.
          btn.innerHTML = ICON + '<span>Hide text</span>';
          document.body.appendChild(btn);

          function hide() { btn.removeAttribute('data-shown'); }
          // The selection has to lie inside the article: the chrome's own labels and the
          // page's heading are not article boilerplate.
          function selectionRange() {
            var sel = window.getSelection();
            if (!sel || sel.isCollapsed || !sel.rangeCount) { return null; }
            if (!sel.toString().trim()) { return null; }
            var range = sel.getRangeAt(0);
            if (!article.contains(range.commonAncestorContainer)) { return null; }
            return range;
          }
          function update() {
            var range = selectionRange();
            if (!range) { hide(); return; }
            var rect = range.getBoundingClientRect();
            if (!rect.width && !rect.height) { hide(); return; }
            // Shown before measuring: display:none has no box to measure.
            btn.setAttribute('data-shown', 'true');
            var w = btn.offsetWidth, h = btn.offsetHeight;
            var left = rect.left + (rect.width - w) / 2;
            left = Math.min(Math.max(8, left), Math.max(8, window.innerWidth - w - 8));
            var top = rect.top - h - 8;
            // A selection starting at the top edge leaves no room above it.
            if (top < 8) { top = Math.min(rect.bottom + 8, window.innerHeight - h - 8); }
            btn.style.left = Math.round(left) + 'px';
            btn.style.top = Math.round(top) + 'px';
          }
          document.addEventListener('selectionchange', update);
          document.addEventListener('mouseup', function (e) {
            // Repositioning under the cursor mid-click would move the button away from
            // the pointer; the selection hasn't changed anyway.
            if (btn.contains(e.target)) { return; }
            update();
          });
          // Fixed positioning doesn't follow the text, so a scrolled selection would leave
          // the button behind. Capture, so a scrollable block inside the article counts.
          window.addEventListener('scroll', hide, true);
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') { hide(); }
          });
          // Focusing a button collapses the document selection, and the posted string is
          // read from the live selection — so the press must not move focus.
          btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
          btn.addEventListener('click', function () {
            var text = window.getSelection().toString();
            hide();
            if (!text.trim()) { return; }
            try { window.webkit.messageHandlers.readerHide.postMessage(text); }
            catch (err) {}
            // The host answers with window.readerSetHidden, which strips the blocks; the
            // selection would otherwise survive inside a removed node.
            var sel = window.getSelection();
            if (sel) { sel.removeAllRanges(); }
            if (window.readerToast) { window.readerToast('Hidden from articles from now on.'); }
          });
        })();
        """
    }
}
