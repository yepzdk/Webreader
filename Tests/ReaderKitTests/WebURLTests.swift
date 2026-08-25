import XCTest
@testable import ReaderKit

// Tests for the pure "Copy Current URL" decision (no AppKit / pasteboard).

final class URLToCopyTests: XCTestCase {
    func testReturnsAbsoluteStringForLoadedURL() {
        let url = URL(string: "https://outlook.office.com/mail/inbox?id=42")
        XCTAssertEqual(WebURL.urlToCopy(currentURL: url),
                       "https://outlook.office.com/mail/inbox?id=42")
    }

    func testNilWhenNoURL() {
        // No page loaded → nothing to copy → menu item stays disabled.
        XCTAssertNil(WebURL.urlToCopy(currentURL: nil))
    }
}

final class ClipboardURLTests: XCTestCase {
    func testAbsoluteWebURLsPassThrough() {
        XCTAssertEqual(WebURL.clipboardURL(from: "https://example.com/a?b=c"),
                       URL(string: "https://example.com/a?b=c"))
        XCTAssertEqual(WebURL.clipboardURL(from: "http://example.com"),
                       URL(string: "http://example.com"))
        XCTAssertEqual(WebURL.clipboardURL(from: "HTTPS://example.com"),
                       URL(string: "HTTPS://example.com"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(WebURL.clipboardURL(from: "  https://example.com \n"),
                       URL(string: "https://example.com"))
    }

    func testBareHostGetsHTTPS() {
        // Paste-and-go style: a copied "example.com/article" opens as https.
        XCTAssertEqual(WebURL.clipboardURL(from: "example.com/article"),
                       URL(string: "https://example.com/article"))
    }

    func testNonWebSchemesRejected() {
        // These must never navigate from a paste.
        XCTAssertNil(WebURL.clipboardURL(from: "javascript:alert(1)"))
        XCTAssertNil(WebURL.clipboardURL(from: "file:///etc/passwd"))
        XCTAssertNil(WebURL.clipboardURL(from: "mailto:a@b.com"))
    }

    func testProseAndEmptyRejected() {
        XCTAssertNil(WebURL.clipboardURL(from: nil))
        XCTAssertNil(WebURL.clipboardURL(from: ""))
        XCTAssertNil(WebURL.clipboardURL(from: "   \n "))
        // Internal whitespace → it's text, not a URL.
        XCTAssertNil(WebURL.clipboardURL(from: "read example.com later"))
        XCTAssertNil(WebURL.clipboardURL(from: "hello world"))
        // A single word without a dot isn't a host.
        XCTAssertNil(WebURL.clipboardURL(from: "example"))
    }
}

final class IsWebURLTests: XCTestCase {
    func testAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(WebURL.isWebURL(URL(string: "https://x.test")!))
        XCTAssertTrue(WebURL.isWebURL(URL(string: "http://x.test")!))
        XCTAssertTrue(WebURL.isWebURL(URL(string: "HTTPS://x.test")!))
    }

    func testRejectsOtherSchemes() {
        XCTAssertFalse(WebURL.isWebURL(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(WebURL.isWebURL(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(WebURL.isWebURL(URL(string: "mailto:a@b.com")!))
    }
}

final class LoadsInAppTests: XCTestCase {
    func testWebAndOwnContentSchemesLoadInApp() {
        for s in ["https://x.test/a", "HTTP://x.test", "about:blank", "data:text/html,hi", "blob:https://x.test/1"] {
            XCTAssertTrue(WebURL.loadsInApp(URL(string: s)!), s)
        }
    }

    func testOtherSchemesGoToTheSystem() {
        for s in ["mailto:a@b.com", "msteams://l/x", "tel:+4512345678", "facetime:a@b.com"] {
            XCTAssertFalse(WebURL.loadsInApp(URL(string: s)!), s)
        }
    }
}
