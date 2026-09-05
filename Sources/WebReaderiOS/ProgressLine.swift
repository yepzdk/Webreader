import ReaderKit
import UIKit
import WebKit

/// The thin page-load progress line pinned to the top edge of the window: shows a sliver
/// as soon as a load starts, grows with `estimatedProgress`, then fills and fades out.
/// The fraction math is the pure `LoadProgress`; this is only the view and animation.
final class ProgressLine {
    /// One shared value with the reader page's own scroll-progress line
    /// (`ReaderChrome.progressCSS`): both read `LoadProgress.lineThickness`.
    private static let height = CGFloat(LoadProgress.lineThickness)

    private let bar = UIView()
    private unowned let container: UIView
    private var width: NSLayoutConstraint?
    /// Last fraction applied, so frequent `estimatedProgress` callbacks that don't move the
    /// displayed value don't churn a fresh constraint each time.
    private var fraction: Double = 0
    private var observer: NSKeyValueObservation?

    init(webView: WKWebView, in container: UIView) {
        self.container = container
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The system accent, as `NSColor.controlAccentColor` is on the Mac and `@accent_color`
        // in the GTK host — and deliberately not the page's own scroll-progress colour, so a
        // hairline parked at 30% can't be mistaken for the reader's. Left as the dynamic
        // `.tintColor` rather than a resolved `CGColor`: UIKit keeps the app's accent on the
        // view hierarchy, so a tint set on the window still reaches the line.
        bar.backgroundColor = .tintColor
        bar.alpha = 0
        // It sits over the top edge of a scrollable page and is never a target, so it must not
        // eat the touches that land in its two and a half points. On the Mac the same strip is
        // under the title bar, where there is nothing to intercept.
        bar.isUserInteractionEnabled = false
        // Front-most, not merely above the web view: the loading cover sits between the two,
        // and progress has to stay readable over it.
        container.addSubview(bar)
        let width = bar.widthAnchor.constraint(equalToConstant: 0)
        // The container's top edge, not the safe area: the generated pages are
        // `viewport-fit=cover` and place their own chrome with `env(safe-area-inset-*)`, so
        // the hairline belongs on the physical edge, exactly where it sits on the Mac.
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.height),
            width,
        ])
        self.width = width
        observer = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.update(webView.estimatedProgress)
        }
    }

    private func update(_ estimated: Double) {
        switch LoadProgress.state(for: estimated) {
        case .hidden:
            bar.alpha = 0
            setFraction(0, animated: false)
        case .loading(let fraction):
            if bar.alpha == 0 { bar.alpha = 1 }
            setFraction(fraction, animated: true)
        case .finished:
            setFraction(1, animated: true)
            UIView.animate(withDuration: 0.25, animations: {
                self.bar.alpha = 0
            }, completion: { [weak self] _ in
                self?.setFraction(0, animated: false)
            })
        }
    }

    /// Sets the line's width to `fraction` of the container by swapping the width
    /// constraint (a multiplier of the container width), optionally animated.
    private func setFraction(_ value: Double, animated: Bool) {
        let clamped = max(0, min(1, value))
        guard clamped != fraction else { return }
        fraction = clamped
        let newWidth = bar.widthAnchor.constraint(
            equalTo: container.widthAnchor, multiplier: CGFloat(clamped == 0 ? 0.0001 : clamped))
        width?.isActive = false
        newWidth.isActive = true
        width = newWidth
        if animated {
            UIView.animate(withDuration: 0.2) { self.container.layoutIfNeeded() }
        } else {
            container.layoutIfNeeded()
        }
    }
}
