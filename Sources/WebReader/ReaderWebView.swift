import WebKit

/// The app's web view: stock `WKWebView` plus one context-menu item in the reader — "Hide
/// Selected Text in Articles" — appended when text is selected. The Edit menu offers the same
/// action; this is just the affordance at the text itself.
final class ReaderWebView: WKWebView {
    /// Set by the host. The item is offered only while `canHideSelection()` — the reader is
    /// showing — so a live site's context menu stays stock.
    var canHideSelection: () -> Bool = { false }
    var onHideSelection: () -> Void = {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard canHideSelection() else { return }
        // ponytail: WebKit offers Copy only over a selection, and tags it with this
        // identifier (private header, stable for years). If it ever changes the item simply
        // stops appearing — the Edit menu still works. Beats an async selection round-trip.
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        guard hasSelection else { return }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Selected Text in Articles",
                     action: #selector(hideSelection(_:)), keyEquivalent: "").target = self
    }

    @objc private func hideSelection(_ sender: Any?) { onHideSelection() }
}
