import Foundation
import WebKit
import ReaderKit

extension ReaderWebController {
    // MARK: - Navigation policy

    // Web content and our own about:/data: pages load in the window; other schemes
    // (mailto:, msteams:, …) can't render here and go to their owning app.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !WebURL.loadsInApp(url) {
            services.openExternally(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // target=_blank / window.open: load in the same view rather than dropping it.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if WebURL.loadsInApp(url) {
                webView.load(URLRequest(url: url))
            } else {
                services.openExternally(url)
            }
        }
        return nil
    }

    // MARK: - Reader auto-entry

    // A new navigation means whatever it lands on is a fresh page, not our reader
    // rendering — except the reader document's own load, marked by `pendingReaderRender`.
    @MainActor
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !pendingReaderRender { isShowingReader = false }
        // Our generated pages are real history entries, so back/forward can navigate AWAY
        // from one without going through any of the paths that reset these flags — left set,
        // they gate every message handler against the page actually on screen. But
        // `loadHTMLString` fires this too, and the load THIS app just started must not clear
        // the flag it just set. `PageState` owns that distinction (and is tested on it).
        pageState.navigationStarted()
        // Someone else's page is on its way: cover it rather than let the site paint itself
        // only to be replaced by the reader a moment later (#24).
        if coverSuppressedOnce {
            coverSuppressedOnce = false
        } else {
            loadingCover?.show(theme: ReaderStore.settings(store: store).theme)
        }
        // Whatever is loading isn't the start page any more; a late result must not land on it.
        suggestionTask?.cancel()
    }

    // Every real page that finishes loading is offered to the reader; pages that don't
    // extract stay as they are. The reader document's own didFinish just marks it as
    // showing; a toggle back to the original suppresses one round.
    @MainActor
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if pendingReaderRender {
            pendingReaderRender = false
            isShowingReader = true
            // The article is up; its popover's suggested group catches up when it can (#33).
            // Usually free — arriving from the start page leaves the feeds warm in
            // `FeedFetcher`'s cache — but a link opened from another app fetches here.
            if suggestionsSuppressedOnce {
                suggestionsSuppressedOnce = false
            } else {
                loadSuggestions()
            }
            return
        }
        if suppressReaderOnce {
            suppressReaderOnce = false
            // The reader toggle asked for the original page; showing it is the whole point.
            loadingCover?.hide()
            return
        }
        // Our own start/settings load has landed; the page it set still stands.
        if let own = pageState.navigationFinished() {
            if own == .startPage { loadSuggestions() }
            return
        }
        // A recents row asked for this page explicitly — it rejects audibly if extraction
        // fails, since the user asked for that article. Any finished load consumes the
        // request.
        let requested = enterReaderForURL != nil && enterReaderForURL == webView.url
        enterReaderForURL = nil
        // The start page is up and interactive; the suggestions catch up when they can.
        if isShowingStartPage { loadSuggestions() }
        guard !isShowingReader, !isShowingFallback, !isShowingStartPage, !isShowingSettings
        else { return }
        // Anything that isn't a real web page here is a back/forward restore of one of our
        // own `loadHTMLString` documents (they carry no URL of their own — `about:blank`),
        // so ask the document what it is rather than trying to extract it.
        guard let url = webView.url, WebURL.isWebURL(url) else {
            loadingCover?.hide()
            remarkOwnPage()
            return
        }
        // A restored reader entry is handled by `enterReader`'s own sentinel; a restored
        // start or settings page has to be recognised from its generator marker.
        webView.evaluateJavaScript(Self.generatorScript) { @MainActor [weak self] result, _ in
            guard let self, self.webView.url == url else { return }
            let generator = (result as? String) ?? ""
            switch PageState.Page(generator: generator) {
            case .startPage:
                self.pageState.restored(generator: generator)
                // Reused bytes, not a fresh render: hand it the current settings before the
                // suggestions arrive, since filling a list reveals thumbnails and this
                // document's idea of the switch is as old as it is.
                self.pushSettings()
                self.loadSuggestions()
            case .settings:
                self.pageState.restored(generator: generator)
            default:
                // Including the reader, which `enterReader`'s own sentinel recognises.
                self.enterReader(from: url, manual: requested)
            }
        }
    }

    // MARK: - Load failures

    @MainActor
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    @MainActor
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFallbackIfNeeded(for: error)
    }

    /// Replaces the view with the offline page for genuine top-level load failures,
    /// ignoring cancellations/policy interruptions that aren't real errors.
    func showFallbackIfNeeded(for error: Error) {
        let nsError = error as NSError
        pageState.clear()
        // The load a recents row asked for never arrived; cleared before the ignorable
        // guard because cancelled loads are the likeliest way a row's navigation dies.
        enterReaderForURL = nil
        guard !OfflineFallback.isIgnorable(errorCode: nsError.code) else {
            loadingCover?.hide()
            return
        }

        failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        // A saved copy beats an error page — the article is what was asked for; a reload
        // fetches the live page again once the network is back. Not when the user just asked
        // for the ORIGINAL page (the reader toggle): then the offline page is the honest
        // answer, and its didFinish consumes `suppressReaderOnce` exactly as before.
        if !suppressReaderOnce, let failed = failedURL,
           let cached = cache.article(for: URLCleaner.clean(failed)) {
            // The load that just failed is the network answer for this whole render; asking
            // the feeds now only poisons their cache with an empty result.
            suggestionsSuppressedOnce = true
            renderReader(cached, source: URLCleaner.clean(failed))
            return
        }
        let html = OfflineFallback.html(appName: appName, host: failedURL?.host,
                                        kind: OfflineFallback.classify(errorCode: nsError.code),
                                        platform: platform)
        isShowingFallback = true
        loadOwnPage(html, baseURL: nil)
    }
}
