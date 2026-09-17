import Foundation

/// Hiding by pointing at a block, rather than by selecting its words.
///
/// The selection-driven affordance this replaces had two problems. It fought the browser:
/// it chased `selectionchange` across the page during a drag, and on touch it could only
/// try to dodge the system's own Copy / Look Up callout by sitting below the selection,
/// which is where the trailing selection handle is. And it could only ever remove a block
/// whose ENTIRE text was a stored phrase, so a byline, an inline newsletter box, a
/// related-articles list or a figure's leftover whitespace were unreachable.
///
/// This is modal instead, which is what makes it leave selection alone: nothing here
/// listens until the chrome's button turns it on, and while it is on the article is not
/// selectable, because a drag in this mode means "I am aiming", not "I am copying".
///
/// What it changes, and where that is kept: the removal is applied to the live document and
/// the article's body is posted back to the host (`readerHideBlock`), which rewrites this
/// article's cached copy. So a recents row — or an offline open — shows the article as you
/// left it, while a deliberate reload fetches the publisher's version again. Phrase hiding
/// is untouched and still answers the other question: "never show me this label again, in
/// any article". The bar offers it on what you just removed, so a one-line ad label can be
/// escalated from here without going back to selecting text.
public enum BlockPicker {
    /// The chrome button that turns the mode on. Lives in `ReaderChrome.stackButtonIDs`
    /// like every other control in the column, so it collapses behind the burger with them.
    public static let buttonID = "readerPickBtn"

    /// Block-level candidates. The same list `HiddenPhrases.hideScript` matches against,
    /// for the same reason: removing an inline `<em>` would rewrite a sentence rather than
    /// drop a thing.
    static let blocks = "p,div,section,aside,header,footer,h1,h2,h3,h4,h5,h6,li,ul,ol,"
        + "figure,figcaption,blockquote,table,tr,td,th,pre,dd,dt"

    /// What makes an otherwise textless wrapper worth keeping. Shared with the phrase pass
    /// for the same reason the block list is: a figure whose caption went must not be
    /// pruned away with its picture still in it.
    static let media = "img,video,iframe,picture,svg"

    /// How long a removed block's text may be for the bar to offer hiding it everywhere.
    /// Well under `HiddenPhrases.maxLength`, which bounds what may be *stored*: this bounds
    /// what is worth offering, and boilerplate labels are a few words. A longer block is a
    /// piece of this article, not a phrase that recurs in others.
    static let phraseOffer = 80

    /// The mode's paint: the bar it puts at the foot of the window, and the outline on
    /// whatever is about to go.
    ///
    /// The bar is centred on the bottom edge, where the eye already is for the chrome, and
    /// the chrome's toggle is hidden while the mode is on — the bar's own Done is the way
    /// out (so is Escape), and at a phone's width a floating bar and a 48px toggle cannot
    /// both have the bottom edge. `z-index` 8 keeps it below the chrome (10) and the scroll
    /// progress (9), the same slot the affordance it replaces used.
    public static func css(platform: Platform = .macOS) -> String {
        """
        #readerPickBar {
          position: fixed; z-index: 8;
          bottom: calc(var(--safe-bottom) + 14px); left: 50%; transform: translateX(-50%);
          display: none; align-items: center; gap: 8px;
          max-width: calc(100vw - 20px);
          margin: 0; padding: 6px 8px 6px 12px;
          border: 1px solid var(--border); border-radius: 8px;
          background: var(--bg); color: var(--muted);
          font-family: \(platform.sansStack); font-size: 12px; line-height: 1.3;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12);
          -webkit-user-select: none; user-select: none;
        }
        :root[data-picking="true"] #readerPickBar { display: flex; }
        /* The column has nothing to add while the mode is on, and the bar needs the edge. */
        :root[data-picking="true"] .reader-chrome { display: none; }
        #readerPickBar button {
          padding: 5px 10px; font: inherit; color: var(--fg);
          background: var(--bg); border: 1px solid var(--border); border-radius: 6px;
          cursor: pointer;
        }
        #readerPickBar button:hover:not(:disabled) { border-color: var(--accent); color: var(--accent); }
        #readerPickBar button:disabled { opacity: 0.4; cursor: default; }
        #readerPickBar .pick-done { color: var(--accent); border-color: var(--accent); }
        /* Aiming, not reading: the crosshair says what a click will do, and the article
           stops being selectable so a drag cannot start a selection nobody asked for. */
        :root[data-picking="true"] article {
          cursor: crosshair; -webkit-user-select: none; user-select: none;
        }
        /* What is about to go. Outline rather than border: it must not move the text it
           surrounds, and `outline-offset` keeps it clear of the block's own edge. */
        :root[data-picking="true"] [data-pick="true"] {
          outline: 2px solid var(--accent); outline-offset: 2px;
          background: var(--surface);
        }
        /* A keyboard has no pointer to hover with, so while the mode is on the article's
           own blocks take focus and Enter removes the focused one. The ring is the same
           one every other control on the page shows. */
        :root[data-picking="true"] article > [tabindex]:focus-visible {
          outline: 2px solid var(--accent); outline-offset: 2px;
        }
        /* Touch: the bar's buttons reach the same floor as the rest of the chrome, and its
           label is dropped — three finger-sized buttons already fill a phone's width. */
        @media (pointer: coarse) {
          #readerPickBar { padding: 6px; gap: 6px; }
          #readerPickBar .pick-label { display: none; }
          #readerPickBar button {
            display: inline-flex; align-items: center; justify-content: center;
            min-height: \(ReaderChrome.touchTarget)px; padding: 6px 12px; font-size: 14px;
          }
        }
        """
    }

    /// The mode itself.
    ///
    /// Depends on `window.readerNormalize`, which `ReaderChrome.controlsScript` exports from
    /// the copy of `HiddenPhrases.hideScript` it embeds — one definition of "the same text",
    /// so growing a candidate upward and matching a stored phrase cannot disagree about what
    /// a block says. That script is earlier in the page, and both are immediate IIFEs.
    ///
    /// Three things worth knowing:
    ///
    /// - **What a click resolves to.** The innermost block under the pointer, then grown
    ///   upward while the parent says nothing more than the child does — so pointing at a
    ///   paragraph inside a wrapper div takes the wrapper (and its margins) rather than
    ///   leaving an empty box behind, and pointing at a caption or an image inside a
    ///   `<figure>` takes the figure, so the picture goes with its words.
    /// - **Undo is real.** The removed node is kept with its parent and next sibling, so it
    ///   goes back exactly where it was, and the host is told again — the cached copy is
    ///   rewritten either way.
    /// - **Nothing here runs until the mode is on**, and turning it off removes the
    ///   listeners. That is the whole point: the reader's selection is the browser's again.
    public static func js() -> String {
        """
        (function () {
          var article = document.querySelector('article');
          var toggle = document.getElementById('\(buttonID)');
          if (!article || !toggle) { return; }
          var BLOCKS = '\(blocks)';
          var MEDIA = '\(media)';
          var root = document.documentElement;

          var bar = document.createElement('div');
          bar.id = 'readerPickBar';
          var label = document.createElement('span');
          label.className = 'pick-label';
          label.textContent = 'Click a block to remove it';
          var undoBtn = document.createElement('button');
          undoBtn.type = 'button';
          undoBtn.textContent = 'Undo';
          undoBtn.disabled = true;
          var everywhereBtn = document.createElement('button');
          everywhereBtn.type = 'button';
          everywhereBtn.textContent = 'Hide everywhere';
          everywhereBtn.title = 'Hide this text in every article';
          everywhereBtn.disabled = true;
          var doneBtn = document.createElement('button');
          doneBtn.type = 'button';
          doneBtn.className = 'pick-done';
          doneBtn.textContent = 'Done';
          bar.appendChild(label);
          bar.appendChild(undoBtn);
          bar.appendChild(everywhereBtn);
          bar.appendChild(doneBtn);
          document.body.appendChild(bar);

          // Every removal, newest last: the node itself and where it came from, so Undo is a
          // reinsertion rather than a guess.
          var removals = [];
          // The text of the last block removed, when it is short enough to be a phrase —
          // what "Hide everywhere" would teach.
          var lastText = '';
          var marked = null;

          function mark(el) {
            if (marked === el) { return; }
            if (marked) { marked.removeAttribute('data-pick'); }
            marked = el;
            if (marked) { marked.setAttribute('data-pick', 'true'); }
          }

          // The innermost block, grown upward while the parent adds nothing of its own.
          function candidate(node) {
            if (!node || !node.closest) { return null; }
            var el = node.closest(BLOCKS);
            if (!el || !article.contains(el) || el === article) { return null; }
            while (el.parentElement && el.parentElement !== article
                   && article.contains(el.parentElement)) {
              var parent = el.parentElement;
              var tag = parent.tagName;
              var wrapper = window.readerNormalize(parent.textContent)
                === window.readerNormalize(el.textContent);
              var media = tag === 'FIGURE' || tag === 'PICTURE' || tag === 'BLOCKQUOTE';
              if (!wrapper && !media) { break; }
              el = parent;
            }
            return el;
          }

          function remove(el) {
            if (!el || !article.contains(el) || el === article) { return; }
            mark(null);
            removals.push({ node: el, parent: el.parentNode, next: el.nextSibling });
            el.remove();
            // The same tail `readerHideBlocks` runs: a wrapper left with neither text nor
            // media keeps its margins as a gap where the block used to be.
            var parent = removals[removals.length - 1].parent;
            while (parent && parent !== article && parent.parentNode
                   && !parent.textContent.trim() && !parent.querySelector(MEDIA)) {
              var next = parent.parentNode;
              removals.push({ node: parent, parent: next, next: parent.nextSibling });
              parent.remove();
              parent = next;
            }
            // What "Hide everywhere" would teach, and only when that is a sensible thing to
            // teach: a leaf block short enough to be a label — an ad marker, a "continues
            // below" line. A container's `textContent` is its children run together, which
            // is neither a phrase anyone wrote nor one worth storing.
            var text = (el.textContent || '').replace(/\\s+/g, ' ').trim();
            var label = !el.querySelector(BLOCKS) && text.length
              && text.length <= \(phraseOffer);
            lastText = label ? text : '';
            commit();
          }

          function commit() {
            undoBtn.disabled = !removals.length;
            everywhereBtn.disabled = !lastText;
            candidates();
            readerPost('readerHideBlock', article.innerHTML);
          }

          function undo() {
            // Reverse order: a wrapper was removed after the block inside it, so the block
            // needs its wrapper back first.
            var entry = removals.pop();
            while (entry) {
              entry.parent.insertBefore(entry.node, entry.next);
              if (!removals.length || removals[removals.length - 1].parent !== entry.node) { break; }
              entry = removals.pop();
            }
            lastText = '';
            commit();
          }

          // A keyboard route in: while the mode is on, the article's own top-level blocks
          // take focus, and Enter or Space removes the focused one.
          function candidates() {
            Array.prototype.slice.call(article.children).forEach(function (child) {
              if (picking) { child.setAttribute('tabindex', '0'); }
              else { child.removeAttribute('tabindex'); }
            });
          }

          function onMove(e) { mark(candidate(e.target)); }
          function onLeave() { mark(null); }
          function onClick(e) {
            var el = candidate(e.target);
            if (!el) { return; }
            // A block can carry a link, and in this mode a click is aim, not navigation.
            e.preventDefault();
            e.stopPropagation();
            remove(el);
          }
          function onKey(e) {
            if (e.key === 'Escape') { setPicking(false); returnFocus(); return; }
            if (e.key !== 'Enter' && e.key !== ' ') { return; }
            var el = document.activeElement;
            if (!el || !article.contains(el) || bar.contains(el)) { return; }
            e.preventDefault();
            remove(candidate(el));
          }

          var picking = false;
          function setPicking(on) {
            picking = on;
            if (on) { root.setAttribute('data-picking', 'true'); }
            else { root.removeAttribute('data-picking'); }
            toggle.setAttribute('aria-pressed', String(on));
            mark(null);
            candidates();
            if (on) {
              article.addEventListener('pointermove', onMove);
              article.addEventListener('pointerleave', onLeave);
              article.addEventListener('click', onClick, true);
              document.addEventListener('keydown', onKey, true);
            } else {
              article.removeEventListener('pointermove', onMove);
              article.removeEventListener('pointerleave', onLeave);
              article.removeEventListener('click', onClick, true);
              document.removeEventListener('keydown', onKey, true);
            }
          }

          // Leaving the mode gives focus back to the button that started it — unless the
          // column it lives in is collapsed behind the burger, in which case that button has
          // no box and `focus()` would be a no-op leaving <body> focused. Asked as "does it
          // have boxes?", which is also what forces the style the mode just changed to be
          // recalculated before the question is answered.
          function returnFocus() {
            if (toggle.getClientRects().length) { toggle.focus(); return; }
            var burger = document.getElementById('readerChromeToggle');
            if (burger) { burger.focus(); }
          }

          toggle.addEventListener('click', function () { setPicking(!picking); });
          undoBtn.addEventListener('click', undo);
          doneBtn.addEventListener('click', function () {
            setPicking(false);
            returnFocus();
          });
          everywhereBtn.addEventListener('click', function () {
            var text = lastText;
            if (!text) { return; }
            lastText = '';
            everywhereBtn.disabled = true;
            // The phrase pipeline, unchanged: the host stores it and answers with
            // `readerSetHidden`, which strips it from this article and every later one.
            readerPost('readerHide', text);
            if (window.readerToast) { window.readerToast('Hidden from articles from now on.'); }
          });
        })();
        """
    }
}
