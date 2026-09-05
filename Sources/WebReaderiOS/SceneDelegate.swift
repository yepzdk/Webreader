import UIKit

/// One window, one reader. The scene's whole job is to build the reader, hand it the links
/// the system delivers, and tell sync when the app comes forward.
///
/// The three delivery paths matter separately: `connectionOptions` carries a link that
/// launched the app cold, `openURLContexts` one that arrived while it was running, and
/// `sceneDidBecomeActive` is when a link the share extension left behind is picked up. A
/// host that implements only the middle one loses every link shared while it was closed.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var reader: ReaderViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let reader = ReaderViewController()
        self.reader = reader
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = reader
        self.window = window
        window.makeKeyAndVisible()

        reader.start(with: connectionOptions.urlContexts.first?.url)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        reader?.open(url)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        reader?.applicationDidBecomeActive()
    }
}
