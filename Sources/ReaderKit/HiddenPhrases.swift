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
}
