import CWebKitGTK
import ReaderKit

/// The plain screen shown in place of a site while it loads (#24). The GTK counterpart of the
/// AppKit host's `LoadingCover`: the page background, and the word "Loading" in the secondary
/// text colour with a brighter band travelling across it — which is what says "still working"
/// on a screen that is otherwise completely still. The top-edge progress hairline carries the
/// rest.
///
/// Native rather than a generated page for the reasons spelled out in the AppKit counterpart,
/// and with one more specific to this host: `webkit_web_view_load_html` reports the `base_uri`
/// as the view's URI, so an extra own-document load is exactly the hazard `PageState.willShow`
/// exists to disambiguate. An overlay child sidesteps the question.
///
/// A `GtkDrawingArea` drawn with cairo rather than a `GtkLabel`: the shimmer needs the text
/// filled with a moving gradient, which no label property offers. Same shape as
/// `ProgressStrip` — a draw function plus a `g_timeout` — and the same lifetime rule: it must
/// be kept alive for the window's lifetime, because `self` reaches the callbacks unretained.
final class LoadingCover {
    /// Repaint cadence of the shimmer, matching `ProgressStrip`'s fade.
    private static let frameMS: UInt32 = 16

    private let area: UnsafeMutablePointer<GtkWidget>
    /// The `g_timeout_add` ids, 0 when not armed.
    private var watchdog: UInt32 = 0
    private var ticker: UInt32 = 0

    /// Where the highlight is in its cycle: 0 puts it entirely off the label's left edge,
    /// `1 + spread` entirely off the right, so one cycle is one clean pass.
    private var phase: Double = 0
    private var background = Colour.grey
    private var base = Colour.grey
    private var highlight = Colour.grey
    /// The message this appearance of the cover is showing, picked once per load.
    private var message = ""

    /// Whether the cover is currently up. The show/hide calls are spread across every path
    /// that changes what's on screen, so they must be idempotent.
    private(set) var isVisible = false

    init(overlay: OpaquePointer, webView: OpaquePointer) {
        let area = gtk_drawing_area_new()!
        self.area = area
        // Fill the overlay rather than hug the text, so the site behind is covered edge to
        // edge; the draw function centres the word itself. `measure-overlay` stays at its
        // FALSE default, so this never influences the window's minimum size.
        gtk_widget_set_hexpand(area, 1)
        gtk_widget_set_vexpand(area, 1)
        gtk_widget_set_visible(area, 0)

        let this = Unmanaged.passUnretained(self).toOpaque()
        gtk_drawing_area_set_draw_func(
            UnsafeMutableRawPointer(area).assumingMemoryBound(to: GtkDrawingArea.self),
            { _, cr, width, height, data in
                guard let cr, let data else { return }
                Unmanaged<LoadingCover>.fromOpaque(data).takeUnretainedValue()
                    .draw(cr, width: Double(width), height: Double(height))
            }, this, nil)

        // Added before `ProgressStrip`, so the hairline is the later overlay child and stays
        // painted on top of this.
        gtk_overlay_add_overlay(wr_overlay(UnsafeMutableRawPointer(overlay)), area)

        // The cover keeps its own eye on the load rather than being fed progress by the host:
        // whether it may come down is its business, and `ProgressStrip` watching the same
        // property is no obstacle.
        wr_connect_notify(UnsafeMutableRawPointer(webView), "estimated-load-progress",
                          { _, _, data in
            guard let data else { return }
            Unmanaged<LoadingCover>.fromOpaque(data).takeUnretainedValue().noteProgress()
        }, this)
    }

    /// The load moved, so it is not stuck: start the silence over.
    private func noteProgress() {
        guard isVisible else { return }
        armWatchdog()
    }

    private func armWatchdog() {
        cancel(&watchdog)
        watchdog = g_timeout_add(UInt32(LoadProgress.coverStallPatience * 1000), { data in
            guard let data else { return 0 }
            let cover = Unmanaged<LoadingCover>.fromOpaque(data).takeUnretainedValue()
            cover.watchdog = 0
            cover.hide()
            return 0  // G_SOURCE_REMOVE — a macro the Swift importer can't see.
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Visibility

    /// Covers the web view, painted from `palette` so the page it precedes doesn't arrive as
    /// a change of colour.
    func show(palette: ReaderPalette) {
        background = Self.colour(palette.bg)
        base = Self.colour(palette.muted)
        highlight = Self.colour(palette.fg)
        message = LoadProgress.randomCoverMessage()
        phase = 0
        gtk_widget_set_visible(area, 1)
        isVisible = true
        gtk_widget_queue_draw(area)
        startShimmer()
        armWatchdog()
    }

    /// Reveals whatever is behind the cover. Called from every path that settles what's on
    /// screen — a rendered page of ours, an extraction that declined, a failed load, the
    /// reader toggle — and from the watchdog.
    func hide() {
        cancel(&watchdog)
        // Nothing to look at, so stop spending frames on it.
        cancel(&ticker)
        guard isVisible else { return }
        isVisible = false
        gtk_widget_set_visible(area, 0)
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

    // MARK: - Shimmer

    private func startShimmer() {
        // Someone who has asked the desktop for less movement gets the word, held still.
        guard wr_animations_enabled() != 0, ticker == 0 else { return }
        ticker = g_timeout_add(Self.frameMS, { data in
            guard let data else { return 0 }
            return Unmanaged<LoadingCover>.fromOpaque(data).takeUnretainedValue().tick()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Returns `G_SOURCE_CONTINUE`/`G_SOURCE_REMOVE` — spelled as their values, since GLib
    /// defines them as macros the Swift importer can't see.
    private func tick() -> Int32 {
        guard isVisible else { ticker = 0; return 0 }
        let span = 1 + LoadProgress.coverShimmerSpread
        phase += span * (Double(Self.frameMS) / 1000) / LoadProgress.coverShimmerPeriod
        if phase > span { phase -= span }
        gtk_widget_queue_draw(area)
        return 1
    }

    private func cancel(_ source: inout UInt32) {
        guard source != 0 else { return }
        g_source_remove(source)
        source = 0
    }

    // MARK: - Painting

    private func draw(_ cr: OpaquePointer, width: Double, height: Double) {
        cairo_set_source_rgb(cr, background.red, background.green, background.blue)
        cairo_paint(cr)

        // cairo's "toy" text API rather than Pango: one word in the UI font, and pulling in
        // PangoCairo would mean another shim for one call.
        cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, LoadProgress.coverLabelSize)
        var extents = cairo_text_extents_t()
        cairo_text_extents(cr, message, &extents)
        guard extents.width > 0 else { return }
        let x = (width - extents.width) / 2 - extents.x_bearing
        let y = (height - extents.height) / 2 - extents.y_bearing

        // The gradient spans `spread` label-widths and slides with `phase`, with the three
        // stops the AppKit host uses. EXTEND_PAD holds the base colour beyond both ends, so
        // the word is fully painted at every moment and only the highlight travels.
        let spread = LoadProgress.coverShimmerSpread * extents.width
        let trailing = x + phase * extents.width
        if let sweep = cairo_pattern_create_linear(trailing - spread, y, trailing, y) {
            cairo_pattern_add_color_stop_rgb(sweep, 0, base.red, base.green, base.blue)
            cairo_pattern_add_color_stop_rgb(sweep, 0.5, highlight.red, highlight.green,
                                             highlight.blue)
            cairo_pattern_add_color_stop_rgb(sweep, 1, base.red, base.green, base.blue)
            cairo_pattern_set_extend(sweep, CAIRO_EXTEND_PAD)
            cairo_set_source(cr, sweep)
            cairo_pattern_destroy(sweep)
        } else {
            cairo_set_source_rgb(cr, base.red, base.green, base.blue)
        }
        cairo_move_to(cr, x, y)
        cairo_show_text(cr, message)
    }

    /// A colour in the form cairo wants it. `GdkRGBA` stores `Float` and every cairo entry
    /// point takes `Double`, so the conversion happens once here rather than at each of the
    /// eight places a component is passed.
    private struct Colour {
        let red: Double
        let green: Double
        let blue: Double

        static let grey = Colour(red: 0.5, green: 0.5, blue: 0.5)
    }

    /// A `ReaderPalette` colour, parsed by GTK. It reads the same CSS spellings the palette is
    /// written in (`#rrggbb`, `rgba(…)`), so the host needs no parser of its own.
    private static func colour(_ css: String) -> Colour {
        var rgba = GdkRGBA()
        guard gdk_rgba_parse(&rgba, css) != 0 else { return .grey }
        return Colour(red: Double(rgba.red), green: Double(rgba.green), blue: Double(rgba.blue))
    }
}
