import CWebKitGTK
import ReaderKit

/// The plain screen shown in place of a site while it loads (#24). The GTK counterpart of the
/// AppKit host's `LoadingCover`: solid page background, the word "Loading" in the secondary
/// text colour, and nothing else — the top-edge progress hairline carries the rest.
///
/// Native rather than a generated page for the reasons spelled out in the AppKit
/// counterpart, and with one more that is specific to this host: `webkit_web_view_load_html`
/// reports the `base_uri` as the view's URI, so an extra own-document load is exactly the
/// hazard `PageState.willShow` exists to disambiguate. An overlay child sidesteps the whole
/// question.
///
/// A single `GtkLabel`, not a box wrapping one: with `hexpand`/`vexpand` set and the default
/// FILL alignment the label spans the overlay, and a label already centres its own text.
///
/// Must be kept alive for the window's lifetime, like `ProgressStrip`.
final class LoadingCover {
    /// How long the cover waits before revealing the page regardless. Extraction has no
    /// timeout and neither does WebKit's FINISHED: a page that never settles must not leave
    /// "Loading" on screen for good.
    private static let patienceMS: UInt32 = 10_000

    private static let cssClass = "webreader-loading-cover"

    private let label: UnsafeMutablePointer<GtkWidget>
    /// This cover's own provider, reloaded on every `show` so the cover matches the theme the
    /// page it precedes will paint. Added to the display once — adding per show would stack
    /// duplicate providers, which is what `ProgressStrip.installStyle` guards against.
    private let provider: OpaquePointer
    /// The watchdog's `g_timeout_add` id, 0 when none is armed.
    private var watchdog: UInt32 = 0

    /// Whether the cover is currently up. The show/hide calls are spread across every path
    /// that changes what's on screen, so they must be idempotent.
    private(set) var isVisible = false

    init(overlay: OpaquePointer) {
        let label = gtk_label_new(LoadProgress.coverLabel)!
        self.label = label
        gtk_widget_add_css_class(label, Self.cssClass)
        // Fill the overlay rather than hug the text, so the site behind is covered edge to
        // edge; the label centres the word itself.
        gtk_widget_set_hexpand(label, 1)
        gtk_widget_set_vexpand(label, 1)
        gtk_widget_set_visible(label, 0)

        provider = OpaquePointer(gtk_css_provider_new()!)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            wr_style_provider(UnsafeMutableRawPointer(provider)),
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))

        // Added before `ProgressStrip`, so the hairline is the later overlay child and stays
        // painted on top of this.
        gtk_overlay_add_overlay(wr_overlay(UnsafeMutableRawPointer(overlay)), label)
    }

    /// Covers the web view, painted from `palette` so the page it precedes doesn't arrive as
    /// a change of colour.
    func show(palette: ReaderPalette) {
        gtk_css_provider_load_from_string(
            UnsafeMutablePointer<GtkCssProvider>(provider),
            """
            .\(Self.cssClass) { background-color: \(palette.bg); color: \(palette.muted); }
            """)
        gtk_widget_set_visible(label, 1)
        isVisible = true
        cancelWatchdog()
        watchdog = g_timeout_add(Self.patienceMS, { data in
            guard let data else { return 0 }
            let cover = Unmanaged<LoadingCover>.fromOpaque(data).takeUnretainedValue()
            cover.watchdog = 0
            cover.hide()
            return 0  // G_SOURCE_REMOVE — a macro the Swift importer can't see.
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Reveals whatever is behind the cover. Called from every path that settles what's on
    /// screen — a rendered page of ours, an extraction that declined, a failed load, the
    /// reader toggle — and from the watchdog.
    func hide() {
        cancelWatchdog()
        guard isVisible else { return }
        isVisible = false
        gtk_widget_set_visible(label, 0)
    }

    private func cancelWatchdog() {
        guard watchdog != 0 else { return }
        g_source_remove(watchdog)
        watchdog = 0
    }

    /// The palette the cover should wear for `settings`, given the desktop's own palette (nil
    /// off Omarchy). `.auto` prefers the desktop's colours exactly as the page does, and falls
    /// back to GTK's dark preference — the same question the page's `prefers-color-scheme`
    /// fallback answers for itself.
    static func palette(for settings: ReaderSettings, desktop: ReaderPalette?) -> ReaderPalette {
        if settings.theme == .auto, let desktop { return desktop }
        return ReaderPalette.stock(for: settings.theme,
                                   prefersDark: wr_prefers_dark_theme() != 0)
    }
}
