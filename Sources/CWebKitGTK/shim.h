/*
 * CWebKitGTK — the C surface Swift cannot reach on its own.
 *
 * Everything in this header exists because of one ClangImporter limitation: it imports
 * object-like `#define`s of literals, but never function-like macros, and it cannot call
 * C varargs at all. GTK and GObject put a large part of their public API in exactly those
 * two shapes, so from Swift they simply do not exist:
 *
 *   - `g_signal_connect(...)` is a macro over `g_signal_connect_data(...)` (gsignal.h).
 *   - `G_CALLBACK(f)` is a macro casting to `GCallback` (gclosure.h).
 *   - `GTK_WIDGET(o)`, `GTK_WINDOW(o)`, `G_APPLICATION(o)`, … are cast macros (gtkwidget.h,
 *     gtkwindow.h, gapplication.h). WebKit's own casts happen to be `static inline`
 *     functions already, but they are wrapped here too so the Swift side has one uniform
 *     spelling for every cast instead of two.
 *   - `g_object_new(type, name, value, ..., NULL)` is C varargs.
 *
 * The signal connectors are deliberately one typed wrapper per signal rather than a single
 * generic `g_signal_connect_data` passthrough. A passthrough would force every Swift call
 * site to `unsafeBitCast` its `@convention(c)` closure to `GCallback`, which type-checks
 * nothing: a wrong parameter list would compile and then corrupt the stack at the first
 * emission. Here the true callback signature lives in a C typedef, so the C compiler
 * checks each handler against the signal it is being attached to.
 *
 * Header-only `static inline` on purpose: SwiftPM `systemLibrary` targets compile no
 * sources, so keeping the shim in the header lets the module map and the shim be one
 * target instead of two.
 *
 * Swift-side contract for every connector below: the handler must be an `@convention(c)`
 * closure with no captures (a capturing Swift closure cannot become a C function pointer),
 * and host state travels through `user_data` as
 * `Unmanaged.passUnretained(self).toOpaque()`, recovered with
 * `Unmanaged<T>.fromOpaque(data!).takeUnretainedValue()`. `passUnretained` does not keep
 * the host alive — the objects connected here are app-lifetime, held by a top-level `let`.
 */

#ifndef WR_CWEBKITGTK_SHIM_H
#define WR_CWEBKITGTK_SHIM_H

/* The umbrella header; it transitively provides GTK 4, GLib/GIO and JavaScriptCore.
 * Note webkit.h and webkit-web-process-extension.h cannot be included together — we are
 * the UI process, so this is the right one. */
#include <webkit/webkit.h>

G_BEGIN_DECLS

/* ---------------------------------------------------------------------------------------
 * Type casts.
 *
 * Each takes `void *` so Swift can hand over whichever imported pointer type it happens to
 * hold (or an `OpaquePointer`) without a cast dance of its own, and returns the concrete
 * type the GTK/GObject call expects. The checked GObject cast is preserved underneath, so a
 * wrong pointer still trips a runtime GLib warning exactly as it would in C.
 * ------------------------------------------------------------------------------------- */

static inline GtkWidget *wr_widget(void *obj) { return GTK_WIDGET(obj); }
static inline GtkWindow *wr_window(void *obj) { return GTK_WINDOW(obj); }
static inline WebKitWebView *wr_web_view(void *obj) { return WEBKIT_WEB_VIEW(obj); }
static inline GApplication *wr_gapplication(void *obj) { return G_APPLICATION(obj); }
static inline GtkApplication *wr_gtk_application(void *obj) { return GTK_APPLICATION(obj); }
static inline GActionMap *wr_action_map(void *obj) { return G_ACTION_MAP(obj); }
static inline GAction *wr_action(void *obj) { return G_ACTION(obj); }
static inline GObject *wr_object(void *obj) { return G_OBJECT(obj); }
static inline GtkOverlay *wr_overlay(void *obj) { return GTK_OVERLAY(obj); }
static inline GtkStyleProvider *wr_style_provider(void *obj) { return GTK_STYLE_PROVIDER(obj); }
static inline WebKitNavigationPolicyDecision *wr_nav_decision(void *obj)
{
    return WEBKIT_NAVIGATION_POLICY_DECISION(obj);
}

/* ---------------------------------------------------------------------------------------
 * Construction.
 * ------------------------------------------------------------------------------------- */

/**
 * wr_web_view_new:
 * @ucm: the user content manager the view must be born with.
 *
 * `webkit_web_view_new()` takes no arguments and `WebKitWebView:user-content-manager` is
 * construct-only, so the only way to attach our script-message manager is through
 * `g_object_new` — which is varargs, hence this wrapper. Returns a `GtkWidget *` (the
 * view's own return type) with the usual floating-free full ownership of a new GTK widget:
 * it is consumed by whatever container it is added to.
 */
static inline GtkWidget *wr_web_view_new(WebKitUserContentManager *ucm)
{
    return GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW, "user-content-manager", ucm, NULL));
}

/**
 * wr_prefers_dark_theme:
 *
 * Reads `GtkSettings:gtk-application-prefer-dark-theme`, which `g_object_get` can only
 * deliver through varargs. Used to resolve `Theme.auto` for the native loading cover when
 * the desktop supplies no palette of its own (off Omarchy); on Omarchy the palette answers
 * the question outright and this is never consulted.
 */
static inline int wr_prefers_dark_theme(void)
{
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return 0;
    gboolean dark = FALSE;
    g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, NULL);
    return dark ? 1 : 0;
}

/* ---------------------------------------------------------------------------------------
 * Signal callback signatures.
 *
 * Copied from the 2.52 / GTK 4.22 headers and GIR. `void *` stands in for `gpointer` so the
 * Swift side sees a plain `UnsafeMutableRawPointer?`.
 * ------------------------------------------------------------------------------------- */

/* WebKitWebView::load-changed */
typedef void (*WRLoadChangedFunc)(WebKitWebView *view,
                                  WebKitLoadEvent load_event,
                                  void *user_data);

/* WebKitWebView::load-failed — return TRUE to suppress WebKit's stock error page. */
typedef gboolean (*WRLoadFailedFunc)(WebKitWebView *view,
                                     WebKitLoadEvent load_event,
                                     const char *failing_uri,
                                     GError *error,
                                     void *user_data);

/* WebKitWebView::decide-policy — return TRUE once the decision has been made. */
typedef gboolean (*WRDecidePolicyFunc)(WebKitWebView *view,
                                       WebKitPolicyDecision *decision,
                                       WebKitPolicyDecisionType decision_type,
                                       void *user_data);

/* GObject::notify — used for estimated-load-progress and the overlay's width. */
typedef void (*WRNotifyFunc)(GObject *object, GParamSpec *pspec, void *user_data);

/* WebKitUserContentManager::script-message-received.
 * The value is a JSCValue in the 6.0 API (WebKit2GTK 4.x delivered a WebKitJavascriptResult)
 * and is borrowed — g_object_ref it to keep it past the callback. */
typedef void (*WRScriptMessageFunc)(WebKitUserContentManager *manager,
                                    JSCValue *value,
                                    void *user_data);

/* GApplication::activate — launched with no URL. */
typedef void (*WRActivateFunc)(GApplication *app, void *user_data);

/* GApplication::open — launched with one or more URLs (G_APPLICATION_HANDLES_OPEN).
 * @files is borrowed and holds @n_files entries. */
typedef void (*WROpenFunc)(GApplication *app,
                           GFile **files,
                           int n_files,
                           const char *hint,
                           void *user_data);

/* GSimpleAction::activate — the accelerator targets. */
typedef void (*WRActionFunc)(GSimpleAction *action, GVariant *parameter, void *user_data);

/* ---------------------------------------------------------------------------------------
 * Signal connectors.
 *
 * All of them funnel into `g_signal_connect_data(..., NULL, (GConnectFlags) 0)`, which is
 * precisely what the `g_signal_connect` macro expands to. No destroy notify: `user_data` is
 * always an unretained app-lifetime host.
 * ------------------------------------------------------------------------------------- */

static inline gulong wr_connect_load_changed(WebKitWebView *view,
                                             WRLoadChangedFunc handler,
                                             void *user_data)
{
    return g_signal_connect_data(view, "load-changed", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

static inline gulong wr_connect_load_failed(WebKitWebView *view,
                                            WRLoadFailedFunc handler,
                                            void *user_data)
{
    return g_signal_connect_data(view, "load-failed", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

static inline gulong wr_connect_decide_policy(WebKitWebView *view,
                                              WRDecidePolicyFunc handler,
                                              void *user_data)
{
    return g_signal_connect_data(view, "decide-policy", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

/**
 * wr_connect_notify:
 * @instance: any GObject.
 * @property: the property name, e.g. "estimated-load-progress".
 *
 * Builds the `notify::<property>` detail so the handler only fires for the one property
 * instead of every change on the object.
 */
static inline gulong wr_connect_notify(void *instance,
                                       const char *property,
                                       WRNotifyFunc handler,
                                       void *user_data)
{
    char *detailed = g_strdup_printf("notify::%s", property);
    gulong id = g_signal_connect_data(instance, detailed, G_CALLBACK(handler),
                                      user_data, NULL, (GConnectFlags) 0);
    g_free(detailed);
    return id;
}

/**
 * wr_connect_script_message:
 * @name: the handler name, e.g. "readerRetry".
 *
 * The handler name is the signal *detail*, so this builds
 * `script-message-received::<name>`. Connect before calling
 * `webkit_user_content_manager_register_script_message_handler()`, as the WebKit header
 * advises, or the first message can race the registration.
 */
static inline gulong wr_connect_script_message(WebKitUserContentManager *manager,
                                               const char *name,
                                               WRScriptMessageFunc handler,
                                               void *user_data)
{
    char *detailed = g_strdup_printf("script-message-received::%s", name);
    gulong id = g_signal_connect_data(manager, detailed, G_CALLBACK(handler),
                                      user_data, NULL, (GConnectFlags) 0);
    g_free(detailed);
    return id;
}

static inline gulong wr_connect_activate(GApplication *app,
                                         WRActivateFunc handler,
                                         void *user_data)
{
    return g_signal_connect_data(app, "activate", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

static inline gulong wr_connect_open(GApplication *app,
                                     WROpenFunc handler,
                                     void *user_data)
{
    return g_signal_connect_data(app, "open", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

static inline gulong wr_connect_action(GSimpleAction *action,
                                       WRActionFunc handler,
                                       void *user_data)
{
    return g_signal_connect_data(action, "activate", G_CALLBACK(handler),
                                 user_data, NULL, (GConnectFlags) 0);
}

/* ---------------------------------------------------------------------------------------
 * Accelerators.
 * ------------------------------------------------------------------------------------- */

/**
 * wr_set_accel:
 * @detailed_action: e.g. "app.reload".
 * @accel: one accelerator in `gtk_accelerator_parse` syntax, e.g. "&lt;Control&gt;r".
 *
 * `gtk_application_set_accels_for_action` wants a NULL-terminated `const char * const *`.
 * Building that array is awkward from Swift and we never bind more than one chord to an
 * action, so the array is built here.
 */
static inline void wr_set_accel(GtkApplication *app,
                                const char *detailed_action,
                                const char *accel)
{
    const char *accels[] = { accel, NULL };
    gtk_application_set_accels_for_action(app, detailed_action, accels);
}

/**
 * wr_application_handles_open:
 *
 * `GApplicationFlags` is a bit-flag enum, so ClangImporter brings it across as a
 * `RawRepresentable` struct and its enumerators never become Swift globals —
 * `G_APPLICATION_HANDLES_OPEN` is simply not in scope over there. Returning it from C keeps
 * the real enumerator as the single source of the value instead of hard-coding `1 << 2` in
 * Swift, where nothing would catch it if GLib ever renumbered.
 */
static inline GApplicationFlags wr_application_handles_open(void)
{
    return G_APPLICATION_HANDLES_OPEN;
}

G_END_DECLS

#endif /* WR_CWEBKITGTK_SHIM_H */
