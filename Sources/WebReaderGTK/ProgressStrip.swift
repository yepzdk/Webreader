import CWebKitGTK
import ReaderKit

/// The thin page-load progress line pinned to the top edge of the window: shows a sliver
/// as soon as a load starts, grows with `estimated-load-progress`, then fills and fades out.
/// The GTK counterpart of the AppKit host's `ProgressLine` — the fraction math is the same
/// pure `LoadProgress`, only the view and animation are rewritten.
///
/// Must be kept alive for the window's lifetime: `self` reaches the GObject callbacks
/// unretained through `user_data`, so releasing the strip while the web view still emits
/// `notify::estimated-load-progress` would leave a dangling pointer.
final class ProgressStrip {
    /// Repaint cadence and length of the fade-out, matching the AppKit host's 0.25 s.
    private static let fadeIntervalMS: UInt32 = 16
    private static let fadeSteps = 16

    /// A `GtkDrawingArea`, not a `GtkProgressBar`: a progress bar renders a trough node plus
    /// a progress node, so a bare hairline means overriding Adwaita's trough background,
    /// border, min-height and padding on every theme. (`GtkWidget` itself is abstract.)
    private let bar: UnsafeMutablePointer<GtkWidget>
    /// `WEBKIT_DECLARE_DERIVABLE_TYPE` defines the instance struct, so ClangImporter sees a
    /// complete type here — unlike the overlay, which stays an `OpaquePointer`.
    private let webView: UnsafeMutablePointer<WebKitWebView>

    /// Last fraction and alpha painted, so the frequent `estimated-load-progress`
    /// notifications that don't move the displayed value don't queue a fresh frame each time.
    private var fraction: Double = 0
    private var alpha: Double = 0
    /// The running fade's `g_timeout_add` id, 0 when no fade is in flight.
    private var fadeSource: UInt32 = 0
    private var fadeStep = 0

    init(overlay: OpaquePointer, webView: OpaquePointer) {
        self.webView = wr_web_view(UnsafeMutableRawPointer(webView))
        _ = Self.installStyle

        let bar = gtk_drawing_area_new()!
        self.bar = bar
        gtk_widget_add_css_class(bar, Self.cssClass)
        // Full width, natural height, hugging the top edge: the strip spans the overlay and
        // paints only `fraction` of it, so a window resize needs no extra plumbing — GTK
        // re-allocates the area and the draw function sees the new width. (`GtkWidget` has
        // no `width` property, so there is no `notify::width` to follow.) `measure-overlay`
        // stays at its FALSE default, so this never influences the window's minimum size.
        gtk_widget_set_valign(bar, GTK_ALIGN_START)
        gtk_drawing_area_set_content_height(
            UnsafeMutableRawPointer(bar).assumingMemoryBound(to: GtkDrawingArea.self),
            Int32(LoadProgress.lineThickness.rounded(.up)))
        // A strip across the whole top edge would otherwise swallow clicks meant for the page.
        gtk_widget_set_can_target(bar, 0)
        gtk_widget_set_visible(bar, 0)

        let this = Unmanaged.passUnretained(self).toOpaque()
        gtk_drawing_area_set_draw_func(
            UnsafeMutableRawPointer(bar).assumingMemoryBound(to: GtkDrawingArea.self),
            { _, cr, width, _, data in
                guard let cr, let data else { return }
                Unmanaged<ProgressStrip>.fromOpaque(data).takeUnretainedValue()
                    .draw(cr, width: Double(width))
            }, this, nil)
        gtk_overlay_add_overlay(wr_overlay(UnsafeMutableRawPointer(overlay)), bar)

        wr_connect_notify(UnsafeMutableRawPointer(webView), "estimated-load-progress", { _, _, data in
            guard let data else { return }
            Unmanaged<ProgressStrip>.fromOpaque(data).takeUnretainedValue().progressChanged()
        }, this)
    }

    // MARK: - Style

    private static let cssClass = "webreader-progress-strip"

    /// One display-wide CSS rule, installed once: the provider is global, so doing this per
    /// instance would stack duplicates on the display.
    ///
    /// Accent-coloured to match the AppKit host, and deliberately *not* the reader page's own
    /// scroll-progress colour (`var(--fg)`): an accent hairline parked at 30% reads as a stuck
    /// load, so the two lines must stay visibly distinct. The literal is a fallback for themes
    /// that don't define `@accent_color` — GTK drops the failing declaration, not the rule.
    private static let installStyle: Void = {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, """
            .\(ProgressStrip.cssClass) { color: #3584e4; color: @accent_color; }
            """)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            wr_style_provider(UnsafeMutableRawPointer(provider)),
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }()

    // MARK: - Painting

    private func draw(_ cr: OpaquePointer, width: Double) {
        guard alpha > 0, fraction > 0 else { return }
        // The CSS `color`, so the strip follows the theme's accent without caching it.
        var rgba = GdkRGBA()
        gtk_widget_get_color(bar, &rgba)
        rgba.alpha *= Float(alpha)
        gdk_cairo_set_source_rgba(cr, &rgba)
        // Height from the shared constant rather than the allocation, so the hairline is the
        // same 2.5 px the reader page's own progress line uses.
        cairo_rectangle(cr, 0, 0, width * fraction, LoadProgress.lineThickness)
        cairo_fill(cr)
    }

    private func show(fraction newFraction: Double, alpha newAlpha: Double) {
        let clamped = max(0, min(1, newFraction))
        guard clamped != fraction || newAlpha != alpha else { return }
        fraction = clamped
        alpha = newAlpha
        gtk_widget_set_visible(bar, clamped > 0 && newAlpha > 0 ? 1 : 0)
        gtk_widget_queue_draw(bar)
    }

    // MARK: - Progress

    private func progressChanged() {
        switch LoadProgress.state(for: webkit_web_view_get_estimated_load_progress(webView)) {
        case .hidden:
            cancelFade()
            show(fraction: 0, alpha: 0)
        case .loading(let value):
            cancelFade()
            show(fraction: value, alpha: 1)
        case .finished:
            show(fraction: 1, alpha: 1)
            startFade()
        }
    }

    // MARK: - Fade-out

    private func startFade() {
        guard fadeSource == 0 else { return }
        fadeStep = Self.fadeSteps
        fadeSource = g_timeout_add(Self.fadeIntervalMS, { data in
            guard let data else { return 0 }
            return Unmanaged<ProgressStrip>.fromOpaque(data).takeUnretainedValue().fadeTick()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Returns `G_SOURCE_CONTINUE`/`G_SOURCE_REMOVE` — spelled as their values, since GLib
    /// defines them as macros the Swift importer can't see.
    private func fadeTick() -> Int32 {
        fadeStep -= 1
        guard fadeStep > 0 else {
            fadeSource = 0
            show(fraction: 0, alpha: 0)
            return 0
        }
        show(fraction: fraction, alpha: Double(fadeStep) / Double(Self.fadeSteps))
        return 1
    }

    /// A new load cancels an in-flight fade, so the two never drive the strip at once.
    private func cancelFade() {
        guard fadeSource != 0 else { return }
        g_source_remove(fadeSource)
        fadeSource = 0
    }
}
