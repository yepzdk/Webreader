import CWebKitGTK
import Foundation
import ReaderKit

/// The GTK4 application shell: process lifecycle, incoming links, the one window, the web
/// view, the accelerators that stand in for the deleted menu bar, the clipboard and zoom.
/// The reader itself — page state, script messages, offline fallback, history — is
/// `ReaderHost`; this type is the GApplication/GTK orchestration, i.e. the Linux
/// counterpart of the AppKit host's `AppDelegate` minus the reader logic.
///
/// Every GObject handler here is an `@convention(c)` closure with no captures, the only
/// shape convertible to a C function pointer, and recovers this object from `user_data`.
/// `Unmanaged.passUnretained` does not retain, so the instance must outlive the main loop:
/// `main.swift` keeps it in a top-level `let`.
final class Application {
    /// The application id, matching `App/Info.plist`'s bundle id and the `.desktop` file.
    private static let applicationID = "dk.yepz.webreader"
    /// The window title when no article is on screen. A constant, not a bundle lookup:
    /// there is no bundle on Linux.
    private static let appName = "WebReader"
    /// The XDG directory component. Deliberately the command name and not the reverse-DNS
    /// id, which reads as a mistake under `~/.cache`.
    private static let xdgName = "webreader"
    /// Same as the AppKit host's initial content size.
    private static let windowSize = (width: Int32(1200), height: Int32(800))
    /// The launch flag issue #16 asks for so open-from-clipboard can be bound in Hyprland.
    private static let clipboardFlag = "--clipboard"

    private let app: UnsafeMutablePointer<GtkApplication>
    /// The argv handed to GLib: the process arguments minus our own flags, so a flag is
    /// never mistaken for a file to open.
    private let arguments: [String]
    private let store: KeyValueStore
    private let cache: ArticleCache

    /// Built on the first activation or `open` (see `presentWindow`), so a link arriving at
    /// cold launch is the first thing the view ever loads and a second `open` on the running
    /// instance reuses this window instead of stacking another one.
    private var window: UnsafeMutablePointer<GtkWidget>?
    /// The view itself, kept for zoom. Typed rather than opaque because
    /// `WEBKIT_DECLARE_DERIVABLE_TYPE` defines `struct _WebKitWebView`, so ClangImporter
    /// gives a real `UnsafeMutablePointer`; the two unit boundaries below take the
    /// `OpaquePointer` spelling instead, so neither has to agree with us on an imported
    /// C type name.
    private var webView: UnsafeMutablePointer<WebKitWebView>?
    private var host: ReaderHost?
    /// Held for the window's lifetime: the strip reaches its GObject callbacks unretained.
    private var progress: ProgressStrip?
    /// Likewise: the cover's watchdog callback reaches it unretained.
    private var loadingCover: LoadingCover?

    /// Set by `--clipboard` and consumed by the first activation. Issue #16 wants
    /// open-from-clipboard bindable in Hyprland so it works while the app is unfocused,
    /// which makes it a launch flag rather than only an accelerator. It is a launch flag in
    /// the strict sense: a second `webreader --clipboard` while we are running reaches the
    /// primary instance as a bare `activate` (GLib parses argv in the remote process and
    /// only forwards files), so the flag belongs to this process's own launch. Consumed
    /// rather than left armed, so a later plain `webreader` cannot be hijacked by whatever
    /// happens to be on the clipboard.
    private var clipboardRequest: Bool

    init(processArguments: [String] = CommandLine.arguments) {
        clipboardRequest = processArguments.contains(Self.clipboardFlag)
        arguments = processArguments.filter { $0 != Self.clipboardFlag }
        // `DefaultsStore` is macOS-only in practice: corelibs-Foundation's `UserDefaults`
        // location is not a contract worth persisting a user's settings behind. Every
        // `ReaderStore` value is already a JSON string, so a file-backed store drops in.
        store = FileStore(fileURL: XDG.configDirectory(Self.xdgName)
            .appendingPathComponent("settings.json"))
        cache = ArticleCache(directory: XDG.cacheDirectory(Self.xdgName)
            .appendingPathComponent("articles"))
        // `G_APPLICATION_FLAGS_NONE` is deprecated since GLib 2.74 in favour of
        // `G_APPLICATION_DEFAULT_FLAGS`; we need HANDLES_OPEN either way, which is what
        // routes a `.desktop` `%u` (and `xdg-open`) to the `open` signal.
        app = gtk_application_new(Self.applicationID, wr_application_handles_open())

        let this = Unmanaged.passUnretained(self).toOpaque()
        // Both signals: with HANDLES_OPEN, `activate` fires when there are no arguments and
        // `open` fires with the links. Together they are the equivalent of the AppKit host's
        // `application(_:open:)` plus `applicationDidFinishLaunching`.
        let activated: WRActivateFunc = { _, data in
            Application.from(data).activate()
        }
        let opened: WROpenFunc = { _, files, count, _, data in
            Application.from(data).open(files: files, count: count)
        }
        wr_connect_activate(wr_gapplication(UnsafeMutableRawPointer(app)), activated, this)
        wr_connect_open(wr_gapplication(UnsafeMutableRawPointer(app)), opened, this)
    }

    /// Runs the main loop and returns the process's exit status.
    func run() -> Int32 {
        // GLib takes a C argv, so the strings are duplicated for the call and freed after.
        // NUL-terminated as well as counted, which is the shape a real `main()` passes.
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { g_strdup($0) }
        argv.append(nil)
        defer { for case let string? in argv { g_free(string) } }
        return argv.withUnsafeMutableBufferPointer { buffer in
            g_application_run(wr_gapplication(UnsafeMutableRawPointer(app)),
                              Int32(buffer.count - 1), buffer.baseAddress)
        }
    }

    /// Recovers the shell from a signal handler's `user_data`. Unretained: see the type's
    /// note on lifetime.
    private static func from(_ data: UnsafeMutableRawPointer?) -> Application {
        Unmanaged<Application>.fromOpaque(data!).takeUnretainedValue()
    }

    // MARK: - Activation

    /// Launched with no link: show the start page, then — only if this process was launched
    /// with `--clipboard` — try the clipboard. The start page goes up first because reading
    /// the clipboard is necessarily asynchronous on Wayland (it is a cross-process transfer,
    /// there is no synchronous variant) and an empty window while that lands looks broken.
    private func activate() {
        let host = presentWindow()
        host.goHome()
        if clipboardRequest {
            clipboardRequest = false
            openFromClipboard()
        }
    }

    /// Launched with one or more links (a browser picker, `xdg-open`, the `.desktop`
    /// handler). Single-window model: the first usable link wins and the rest are ignored,
    /// as in the AppKit host's `application(_:open:)`.
    private func open(files: UnsafeMutablePointer<OpaquePointer?>?, count: Int32) {
        let coldLaunch = self.host == nil
        let host = presentWindow()
        var opened = false
        if let files {
            for index in 0..<Int(count) {
                guard let file = files[index] else { continue }
                // Allocated: `g_file_get_uri` is transfer-full even though `files` is
                // borrowed.
                guard let raw = g_file_get_uri(file) else { continue }
                let string = String(cString: raw)
                g_free(raw)
                // `openIncoming` cleans and then drops anything that isn't http(s), so the
                // same test tells us whether a link was really handed over.
                guard let url = URL(string: string), WebURL.isWebURL(url) else { continue }
                host.openIncoming(url)
                opened = true
                break
            }
        }
        // Nothing usable in the argument list (a `file://` path, say). At cold launch the
        // window would otherwise come up blank; on a running instance, leave whatever the
        // user is reading alone rather than throwing it away for a link we rejected.
        if !opened, coldLaunch { host.goHome() }
    }

    // MARK: - Window

    /// The window and everything in it, built once and raised on every entry point.
    @discardableResult
    private func presentWindow() -> ReaderHost {
        let host = self.host ?? buildWindow()
        if let window {
            gtk_window_present(wr_window(UnsafeMutableRawPointer(window)))
        }
        return host
    }

    private func buildWindow() -> ReaderHost {
        // Everything GTK-side waits until here: `activate`/`open` are emitted after
        // GApplication's `startup`, which is where GtkApplication runs `gtk_init`.
        registerCommands()
        let window = gtk_application_window_new(app)!
        let windowRef = wr_window(UnsafeMutableRawPointer(window))
        gtk_window_set_title(windowRef, Self.appName)
        gtk_window_set_default_size(windowRef, Self.windowSize.width, Self.windowSize.height)
        // No menu bar, and none missing: issue #16 deletes the whole thing. The compositor
        // owns quit/hide/minimize, WebKitGTK owns the edit verbs and its own context menu,
        // appearance/recents/settings live in the web shell, and what genuinely needs the
        // host is bound below as an accelerator. Since no `GMenuModel` is ever installed
        // with `gtk_application_set_menubar`, GtkApplicationWindow has nothing to show.

        // `WebKitWebView:user-content-manager` is construct-only, so the manager exists
        // before the view and the view is built around it (`wr_web_view_new` wraps the
        // `g_object_new` varargs call Swift cannot make).
        let userContent = webkit_user_content_manager_new()!
        let widget = wr_web_view_new(userContent)!
        let view = wr_web_view(UnsafeMutableRawPointer(widget))!

        // The overlay exists so the load-progress hairline can sit above the page instead of
        // stealing a strip of its height.
        let overlay = gtk_overlay_new()!
        let overlayRef = wr_overlay(UnsafeMutableRawPointer(overlay))!
        gtk_overlay_set_child(overlayRef, widget)
        gtk_window_set_child(windowRef, overlay)

        // Added before the progress strip, so the hairline is the later overlay child and
        // keeps painting over the cover.
        let cover = LoadingCover(overlay: overlayRef)

        let host = ReaderHost(webView: OpaquePointer(view), userContentManager: userContent,
                              store: store, cache: cache, palette: OmarchyTheme.current)
        host.loadingCover = cover
        host.onTitleChange = { [weak self] title in self?.setWindowTitle(title) }
        // Before anything is loaded: `connectSignals` attaches the
        // `script-message-received::<name>` handlers and only then registers the names,
        // which is the order the WebKit header asks for — the reverse races the first
        // message against its own registration.
        host.connectSignals()
        // Already TRUE by default here, unlike the AppKit host — stated anyway so the two
        // hosts read the same and a future default cannot quietly take Tab away (#26).
        if let settings = webkit_web_view_get_settings(view) {
            webkit_settings_set_enable_tabs_to_links(settings, 1)
        }

        // Zoom is a multiplier (1.0 = 100%). Applied before the first load so no page is
        // ever drawn at the wrong size for a frame.
        webkit_web_view_set_zoom_level(view, ReaderStore.zoom(store: store))

        self.window = window
        self.webView = view
        self.host = host
        loadingCover = cover
        progress = ProgressStrip(overlay: overlayRef, webView: OpaquePointer(view))
        return host
    }

    /// The window title follows the document on screen — `ReaderHost` reports the web view's
    /// `<title>` and nothing else, which is why an article headline, a non-article page and
    /// the settings page each name themselves. With no menu bar and no title bar of our own,
    /// the compositor's bar and window switcher are the only places that headline can show.
    /// `""` — WebKit has no title for the page — falls back to the app name, which is what
    /// the AppKit host shows permanently.
    private func setWindowTitle(_ title: String) {
        guard let window else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? Self.appName : trimmed
        gtk_window_set_title(wr_window(UnsafeMutableRawPointer(window)), text)
    }

    // MARK: - Commands

    /// The host actions issue #16 keeps from the deleted menu bar — its eight, plus Actual
    /// Size, because zoom in and out without a way back to 100% is a trap. All **Ctrl**
    /// chords: Hyprland owns Super, so a Super bind never reaches the app at all.
    private enum Command: String, CaseIterable {
        case toggleReader = "toggle-reader"
        case home = "home"
        case reload = "reload"
        case zoomIn = "zoom-in"
        case zoomOut = "zoom-out"
        case zoomReset = "zoom-reset"
        case openClipboard = "open-clipboard"
        case copyURL = "copy-url"
        case settings = "settings"

        /// `gtk_accelerator_parse` syntax: character keys are spelled by keyval name, so
        /// `plus`, `minus` and `comma` rather than the symbols. All nine parse — checked
        /// against `gtk_shortcut_trigger_parse_string`, which shares that parser — and none
        /// needs a `<Shift>` it does not name: where a layout puts `+` behind Shift, GDK
        /// reports Shift as *consumed* by the translation and drops it before matching.
        var accelerator: String {
            switch self {
            case .toggleReader: return "<Control><Shift>r"
            case .home: return "<Control><Shift>h"
            case .reload: return "<Control>r"
            case .zoomIn: return "<Control>plus"
            case .zoomOut: return "<Control>minus"
            case .zoomReset: return "<Control>0"
            case .openClipboard: return "<Control><Shift>o"
            case .copyURL: return "<Control><Shift>c"
            case .settings: return "<Control>comma"
            }
        }
    }

    /// One `GSimpleAction` per command on the application's `GActionMap`, each with its
    /// accelerator. No `GtkShortcutController` is built here and none is needed, because
    /// this *is* the shortcut-controller path: `gtk_window_set_application` gives every
    /// window a `gtk_shortcut_controller_new_for_model` over the application's accels,
    /// scoped `GTK_SHORTCUT_SCOPE_GLOBAL` in `GTK_PHASE_CAPTURE` (gtkwindow.c). Capture
    /// runs from the window *down* to the focus widget, so an application accel is matched
    /// before the `WebKitWebView` is offered the key. Runtime-verified on Hyprland: all
    /// nine chords fire with the view focused, and installing a second global controller by
    /// hand changes nothing — `gtk_shortcut_trigger_parse_string` builds the same
    /// `GtkKeyvalTrigger`, matched by the same `gdk_key_event_matches`, and GTK stops at the
    /// first shortcut that handles the key, so neither does it double-fire.
    ///
    /// A `<Shift>` chord that looks dead under `wtype` is an artifact of that injector, not
    /// a bug here. `wtype` uploads a synthetic keymap whose letter key carries the
    /// *unshifted* keysym at every level, so `wtype -M ctrl -M shift -k r` delivers keyval
    /// `r` with Shift set where a real Ctrl+Shift+R delivers `R`; `gdk_key_event_matches`
    /// upper-cases the accel's keyval whenever the accel carries Shift, so it looks for `R`
    /// and the injected `r` cannot match. Verify these chords with a real key press or with
    /// `hyprctl dispatch 'hl.dsp.send_shortcut{ mods = "CTRL SHIFT", key = "r" }'`.
    private func registerCommands() {
        // One handler for all of them, dispatching on the action's own name, so the table
        // above stays the single place a binding is described.
        let activated: WRActionFunc = { action, _, data in
            guard let action,
                  let name = g_action_get_name(wr_action(UnsafeMutableRawPointer(action)))
            else { return }
            Application.from(data).perform(Command(rawValue: String(cString: name)))
        }
        let this = Unmanaged.passUnretained(self).toOpaque()
        for command in Command.allCases {
            guard let action = g_simple_action_new(command.rawValue, nil) else { continue }
            wr_connect_action(action, activated, this)
            g_action_map_add_action(wr_action_map(UnsafeMutableRawPointer(app)),
                                    wr_action(UnsafeMutableRawPointer(action)))
            wr_set_accel(app, "app." + command.rawValue, command.accelerator)
            // `g_simple_action_new` is transfer-full and the action map took its own
            // reference.
            g_object_unref(UnsafeMutableRawPointer(action))
        }
    }

    private func perform(_ command: Command?) {
        guard let command, let host else { return }
        switch command {
        case .toggleReader: host.toggleReader()
        case .home: host.goHome()
        case .reload: host.reload()
        case .zoomIn: applyZoom(currentZoom + ReaderStore.zoomStep)
        case .zoomOut: applyZoom(currentZoom - ReaderStore.zoomStep)
        case .zoomReset: applyZoom(1.0)
        case .openClipboard: openFromClipboard()
        case .copyURL: copyURL()
        case .settings: host.openSettings()
        }
    }

    // MARK: - Zoom

    private var currentZoom: Double {
        guard let webView else { return 1.0 }
        return webkit_web_view_get_zoom_level(webView)
    }

    /// Clamped to `ReaderStore`'s bounds and persisted, so zoom survives a relaunch exactly
    /// as `pageZoom` does on macOS.
    private func applyZoom(_ raw: Double) {
        guard let webView else { return }
        let clamped = ReaderStore.clampZoom(raw)
        webkit_web_view_set_zoom_level(webView, clamped)
        ReaderStore.setZoom(clamped, store: store)
    }

    // MARK: - Clipboard

    /// Reads the clipboard and, if it holds something `WebURL.clipboardURL` accepts, opens
    /// it. Nothing happens otherwise — the AppKit host beeps here, and there is no
    /// equivalent worth inventing under a compositor.
    private func openFromClipboard() {
        guard let display = gdk_display_get_default(),
              let clipboard = gdk_display_get_clipboard(display) else { return }
        // A one-shot callback, so the retained reference is balanced by `takeRetainedValue`
        // — unlike the signal handlers, this one cannot fire twice.
        let finished: GAsyncReadyCallback = { source, result, data in
            let shell = Unmanaged<Application>.fromOpaque(data!).takeRetainedValue()
            guard let source,
                  let raw = gdk_clipboard_read_text_finish(OpaquePointer(source), result, nil)
            else { return }
            let text = String(cString: raw)
            g_free(raw)
            guard let url = WebURL.clipboardURL(from: text) else { return }
            shell.presentWindow().openIncoming(url)
        }
        gdk_clipboard_read_text_async(clipboard, nil, finished,
                                      Unmanaged.passRetained(self).toOpaque())
    }

    /// The window has no address bar, so this is the way a URL gets out of the app.
    private func copyURL() {
        guard let string = host?.urlToCopy(),
              let display = gdk_display_get_default(),
              let clipboard = gdk_display_get_clipboard(display) else { return }
        gdk_clipboard_set_text(clipboard, string)
    }
}
