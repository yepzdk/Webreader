import Cocoa
import WebKit
import ReaderKit

/// The thin page-load progress line pinned to the top edge of the window: shows a sliver
/// as soon as a load starts, grows with `estimatedProgress`, then fills and fades out.
/// The fraction math is the pure `LoadProgress`; this is only the view and animation.
final class ProgressLine {
    /// A literal 1px reads as nothing on Retina; 2.5 registers as "loading". Matches the
    /// reader page's own scroll-progress line (`ReaderChrome.progressCSS`).
    private static let height: CGFloat = 2.5

    private let bar = NSView()
    private unowned let container: NSView
    private var width: NSLayoutConstraint?
    /// Last fraction applied, so frequent `estimatedProgress` callbacks that don't move the
    /// displayed value don't churn a fresh constraint each time.
    private var fraction: Double = 0
    private var observer: NSKeyValueObservation?

    init(webView: WKWebView, in container: NSView) {
        self.container = container
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.alphaValue = 0
        container.addSubview(bar, positioned: .above, relativeTo: webView)
        let width = bar.widthAnchor.constraint(equalToConstant: 0)
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
            bar.alphaValue = 0
            setFraction(0, animated: false)
        case .loading(let fraction):
            if bar.alphaValue == 0 { bar.alphaValue = 1 }
            setFraction(fraction, animated: true)
        case .finished:
            setFraction(1, animated: true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.bar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.container.layoutSubtreeIfNeeded()
            }
        } else {
            container.layoutSubtreeIfNeeded()
        }
    }
}
