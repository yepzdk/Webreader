import XCTest
@testable import ReaderKit

/// Writes the pages the App Store screenshots are taken from.
///
///     WEBREADER_SHOTS=1 swift test --filter ScreenshotPages
///
/// Gated on the variable because it writes files, and a suite that writes files on every
/// run is one nobody trusts. STORE.md gives the viewport, the pixel ratio and the
/// interaction each frame needs.
///
/// The pages, not the images: capturing is a browser's job and every browser does it
/// differently, so this stops at the part that has to be right — the app's own markup,
/// from the app's own generator, with settings that suit each device.
///
/// Not the simulator, which would give real device frames with a status bar: the app can
/// only be steered from outside through `webreader://open?url=…`, and iOS puts a
/// confirmation dialog in front of a scheme opened by another process. `simctl openurl`
/// raises it on a cold start as well as a warm one, and `simctl` cannot tap it away.
///
/// The content is written for this purpose: no real outlet, no real byline, no real
/// headline. A screenshot is marketing, and marketing carrying somebody else's masthead
/// borrows their reputation to sell ours — and dates the moment their story does. The
/// hosts are the reserved example domains, which belong to nobody.
final class ScreenshotPages: XCTestCase {
    private let article = Article(
        title: "The quiet street experiment that cut traffic by a third",
        byline: "A. Jensen",
        siteName: "example.com",
        content: """
        <p>Six streets closed to through traffic for ninety days, and the counters at
        either end tell the same story: a third fewer cars, and the ones that remain move
        slower. The <a href="https://example.com/transport">transport committee</a> had
        expected displacement onto the ring road. It did not arrive.</p>
        <p>What arrived instead was harder to measure and easier to see. Shopkeepers on
        the closed stretch report longer visits. The bakery on the corner put four tables
        where a delivery bay had been, and has not moved them back since the barriers went
        up in March.</p>
        <p>The council's own survey puts support at 61 percent among people living on the
        affected streets, against 38 percent when the scheme was announced. Opposition is
        steady among those driving through, which is the constituency the scheme was
        designed to inconvenience.</p>
        <blockquote>We assumed the traffic had to go somewhere. Some of it simply stopped
        happening — trips that were never worth making once they took four minutes
        longer.</blockquote>
        <h2>What the counters missed</h2>
        <p>Cycle traffic rose 22 percent over the same period, but the counters cover only
        the two widest streets, so the real figure is probably higher. Walking was not
        measured at all, which the evaluation calls its own largest gap.</p>
        <p>A decision on making the closures permanent is due before the end of the year.
        Two neighbouring districts have asked to be included in whatever comes next.</p>
        """)

    private var history: ReaderHistory {
        var history = ReaderHistory()
        for (title, url) in [
            ("The quiet street experiment that cut traffic by a third",
             "https://example.com/streets/quiet-experiment"),
            ("Why the harbour tunnel keeps missing its own deadlines",
             "https://example.org/infrastructure/harbour-tunnel"),
            ("A century of tide records, finally in one place",
             "https://example.net/climate/tide-records"),
            ("The library that lends tools, seeds and a cargo bike",
             "https://example.org/culture/library-of-things"),
        ] {
            history.record(title: title, url: url)
        }
        return history
    }

    func testWritePages() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WEBREADER_SHOTS"] == "1",
                          "set WEBREADER_SHOTS=1 to write build/screenshots/html")
        let out = URL(fileURLWithPath: "build/screenshots/html")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // A 13" iPad at the phone's settings is half margin, and 17px on that screen is
        // not what anybody reads at arm's length. Each device gets what a reader would
        // pick on it.
        for (device, size, width) in [("iphone", 17, ReaderSettings.Width.normal),
                                      ("ipad", 20, ReaderSettings.Width.wide)] {
            var light = ReaderSettings()
            light.theme = .light
            light.fontSize = size
            light.width = width
            var sepia = light
            sepia.theme = .sepia
            sepia.fontSize = size + 3
            var dark = light
            dark.theme = .dark

            let pages: [(String, String)] = [
                ("reader-light", ReaderPage.html(article: article, settings: light,
                                                 history: history, rating: nil,
                                                 currentURL: "https://example.com/streets/q",
                                                 platform: .iOS)),
                ("reader-sepia", ReaderPage.html(article: article, settings: sepia,
                                                 history: history, rating: nil,
                                                 currentURL: "https://example.com/streets/q",
                                                 platform: .iOS)),
                ("reader-dark", ReaderPage.html(article: article, settings: dark,
                                                history: history, rating: nil,
                                                currentURL: "https://example.com/streets/q",
                                                platform: .iOS)),
                ("start", StartPage.html(appName: "WebReader", settings: light,
                                         history: history, platform: .iOS)),
            ]
            for (name, html) in pages {
                try html.write(to: out.appendingPathComponent("\(device)-\(name).html"),
                               atomically: true, encoding: .utf8)
            }
        }
    }
}
