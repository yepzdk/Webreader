import Foundation

/// What a new reader has no way to discover: the five things this app can do that nothing
/// on screen says it can.
///
/// One list, two surfaces. The start page shows it once and takes a dismissal
/// (`ReaderStore.hintsSeen`); the settings page carries the same rows permanently, beside
/// the keyboard shortcuts, so dismissing it is not the same as losing it. Written once here
/// because copy that exists twice drifts — and both pages escape nothing, so these strings
/// are plain text and pass through `HTML.escape` at the point of use.
///
/// Text, not icons: five glyphs invented for five sentences would be five more things to
/// recognise, and the rows sit in the same hairline list the shortcuts already use.
public enum Hints {
    public struct Hint: Equatable, Sendable {
        /// The verb or control being named — the part a reader has to find on screen.
        public let term: String
        /// One sentence saying what it does and what is surprising about it.
        public let detail: String
    }

    /// The tips in the order they are shown. The arrival route leads: it is the only one
    /// that matters before anything has been read, and the only one whose wording is the
    /// platform's rather than ours.
    ///
    /// Deliberately not a second telling of the empty-recents paragraph, which answers "how
    /// do I get my first article in here" for a page with nothing on it — on a phone the two
    /// would otherwise sit one above the other saying the same thing. This one names the
    /// route and then says what it buys: the article is kept, and keeps working offline.
    public static func all(for platform: Platform) -> [Hint] {
        [arrival(platform)] + [
            // Names the list rather than the page it is on: this copy is read both from the
            // start page, where Settings is somewhere to go, and from the settings page
            // itself, where "in Settings" would be telling you where you already are.
            Hint(term: "Suggested articles",
                 detail: "They come from feeds you choose. The Suggestion sources list holds "
                     + "them, and suggestions can be limited to the languages you read."),
            Hint(term: "Aa",
                 detail: "Behind it: the typeface, the reading width, the text size and five "
                     + "themes."),
            Hint(term: "Hide text",
                 detail: "Select a line in an article and the button appears beside it. What "
                     + "you hide goes from every article, not only this one."),
            Hint(term: "More or less like this",
                 detail: "Every suggested article carries both, and an × that blocks the "
                     + "outlet for good. The list is ranked against what you have read."),
        ]
    }

    private static func arrival(_ platform: Platform) -> Hint {
        switch platform {
        case .iOS:
            // "Share" is the sheet's own name, and the extension is what puts this app in it.
            return Hint(term: "Share",
                        detail: "WebReader sits in Safari's share sheet. What you send it is "
                            + "saved on the device, so it opens again instantly — offline too.")
        case .android:
            // Android calls it the share menu, and an ACTION_SEND filter is what joins it.
            return Hint(term: "Share",
                        detail: "WebReader sits in your browser's share menu. What you send it "
                            + "is saved on the device, so it opens again instantly — offline "
                            + "too.")
        case .macOS, .linux:
            // No sheet to name on a desktop: the app is a link handler, which is the route
            // that keeps working after the first article.
            return Hint(term: "Opening links",
                        detail: "WebReader is a link handler, not just a paste field. What you "
                            + "open is saved on the device, so it opens again instantly — "
                            + "offline too.")
        }
    }

    /// The rows, as one `<dl>`. Escaped here: these strings are ours, but they are page
    /// copy carrying an `×` and an em dash, and the two pages that embed this escape
    /// everything else they print.
    ///
    /// `heading` names the section for a screen reader and is what the two surfaces differ
    /// in — "Before you start" on a page you see once, "Tips" in a list you came looking
    /// for. `dismiss` is the start page's "Got it"; the settings copy has nothing to
    /// dismiss, which is the point of it being there.
    public static func markup(for platform: Platform, heading: String, id: String,
                              dismissible: Bool) -> String {
        let rows = all(for: platform).map { hint in
            """
            <dt>\(HTML.escape(hint.term))</dt>
                <dd>\(HTML.escape(hint.detail))</dd>
            """
        }.joined(separator: "\n    ")
        let dismiss = dismissible ? """

              <p class="tips-dismiss">
                <button type="button" class="link" id="\(id)Dismiss">Got it</button>
              </p>
            """ : ""
        return """
        <section id="\(id)" aria-labelledby="\(id)Title">
          <h2 class="section" id="\(id)Title">\(HTML.escape(heading))</h2>
          <dl class="tips">
            \(rows)
          </dl>\(dismiss)
        </section>
        """
    }

    /// Shared so the two surfaces cannot drift. The same hairline list the keyboard
    /// shortcuts use, stacked rather than two columns: a sentence needs the width, and a
    /// chord does not.
    public static func css() -> String {
        """
        .tips { margin: 0; }
        .tips dt { margin: 0; padding: 10px 2px 0; font-size: 14px; }
        .tips dd {
          margin: 0; padding: 2px 2px 10px; font-size: 13px; line-height: 1.45;
          color: var(--muted); border-bottom: 1px solid var(--border);
        }
        .tips dd:last-of-type { border-bottom: 0; }
        .tips-dismiss { margin: 10px 0 0; font-size: 12px; text-align: right; }
        .tips-dismiss .link { padding: 4px 2px; color: var(--muted); text-decoration: none; }
        .tips-dismiss .link:hover, .tips-dismiss .link:focus-visible {
          color: var(--fg); text-decoration: underline;
        }
        @media (pointer: coarse) {
          .tips-dismiss .link {
            display: inline-flex; align-items: center;
            min-height: \(ReaderChrome.touchTarget)px; padding: 4px 2px;
          }
        }
        """
    }
}
