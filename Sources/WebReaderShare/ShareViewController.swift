import UIKit
import UniformTypeIdentifiers
import ReaderKit

/// "Read in WebReader" in the share sheet.
///
/// No interface: there is one thing to do with a link and asking about it would only add a
/// tap. The extension takes the URL, normalises it with the same rules the app's own URL
/// field uses, leaves it in the shared store, and asks the system to open the app.
///
/// The store is what actually carries the link. An app extension has no supported way to
/// launch its host app on iOS, so `open` may well be refused — in which case the link is
/// still waiting the next time the app is opened, which is the behaviour worth having.
final class ShareViewController: UIViewController {
    /// The shared store's identifier and key, spelled the same as in the app. They cannot be
    /// shared as code without a framework target, so they are stated once here with a
    /// comment saying where their twin lives: `Sources/WebReaderiOS/AppDelegate.swift`.
    private static let appGroup = "group.dk.yepz.webreader"
    private static let pendingOpenKey = "reader.pendingOpen"

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            if let url = await extractedURL() {
                UserDefaults(suiteName: Self.appGroup)?
                    .set(url.absoluteString, forKey: Self.pendingOpenKey)
                // `NSExtensionContext.open` is the only documented way an extension may ask
                // for a URL to be opened, and the documentation says iOS supports it for
                // some extension kinds and not others. If the system refuses, nothing is
                // lost: the link is in the shared store and the app picks it up the next
                // time it comes forward. The responder-chain trick that reaches
                // `UIApplication` from an extension is deliberately not used here.
                extensionContext?.open(url: URL(string: "webreader://open")!)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The first link among what was shared. Safari sends a URL attachment; a text selection
    /// or a note sends plain text, which may still be a link — the same two cases the app's
    /// own paste route handles, so it uses the same parser rather than a second one.
    private func extractedURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   let cleaned = WebURL.clipboardURL(from: url.absoluteString) {
                    return cleaned
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let cleaned = WebURL.clipboardURL(from: text) {
                    return cleaned
                }
            }
        }
        return nil
    }

}

private extension NSExtensionContext {
    /// `open(_:completionHandler:)` with the result dropped: there is nothing useful to do
    /// when the system declines, and the shared store has already taken the link.
    func open(url: URL) {
        open(url, completionHandler: nil)
    }
}
