import UIKit

/// The iOS/iPadOS entry point. Everything that matters happens in `SceneDelegate` and
/// `ReaderViewController`; this exists because UIKit needs somewhere to answer the scene
/// question and because process-level state, if the app ever grows any, belongs here rather
/// than in a scene that can be created and destroyed several times over.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// The App Group both the app and the share extension write through.
///
/// Without it the extension would keep its own copy of settings and recents in its own
/// container, and a link shared from Safari would land in a store the app never reads —
/// the failure is silent, which is why the identifier is spelled once, here.
enum AppGroup {
    static let identifier = "group.dk.yepz.webreader"

    /// The key the share extension leaves a link under. The extension cannot reliably ask
    /// the system to open another app, so the handoff is a value in the shared store and a
    /// `webreader://open` nudge; the value is what actually carries the link, and it
    /// survives the app being closed at the time.
    static let pendingOpenKey = "reader.pendingOpen"

    /// The shared defaults, or the app's own if the App Group is missing from the build's
    /// entitlements. The fallback keeps such a build running instead of crashing at launch,
    /// but it does split the app's state from the extension's — which is why the identifier
    /// is a constant and not a string typed twice.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
