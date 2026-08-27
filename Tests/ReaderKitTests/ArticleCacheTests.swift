import XCTest
@testable import ReaderKit

// The on-disk article cache: keys, round trip, misses, and pruning against the recents list.
final class ArticleCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: ArticleCache!
    private let article = Article(title: "T", byline: "By A", siteName: nil,
                                  content: "<p>Body</p>", hiddenHits: ["annonce": 2])
    private let url = URL(string: "https://example.com/a?x=1")!

    override func setUp() {
        // Not created up front: the first store must create it.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleCacheTests-\(UUID().uuidString)")
        cache = ArticleCache(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testKeyIsStableAndDistinct() {
        XCTAssertEqual(ArticleCache.key(for: url), ArticleCache.key(for: url))
        XCTAssertEqual(ArticleCache.key(for: url).count, 16)
        XCTAssertNotEqual(ArticleCache.key(for: url), ArticleCache.key(for: URL(string: "https://example.com/b")!))
    }

    func testStoreCreatesDirectoryAndRoundTrips() {
        XCTAssertNil(cache.article(for: url))
        cache.store(article, for: url)
        XCTAssertEqual(cache.article(for: url), article)
        XCTAssertNil(cache.article(for: URL(string: "https://example.com/other")!))
    }

    func testCorruptOrForeignFileIsAMiss() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(ArticleCache.key(for: url) + ".json")
        try Data("{nope".utf8).write(to: file)
        XCTAssertNil(cache.article(for: url))
        // Right key, wrong URL inside (what a hash collision would look like).
        let other = URL(string: "https://example.com/other")!
        cache.store(article, for: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(ArticleCache.key(for: other) + ".json"),
                                         to: file)
        XCTAssertNil(cache.article(for: url))
    }

    func testPruneKeepsOnlyTheRecents() {
        let a = URL(string: "https://example.com/a")!
        let b = URL(string: "https://example.com/b")!
        let c = URL(string: "https://example.com/c")!
        for u in [a, b, c] { cache.store(article, for: u) }
        cache.prune(keeping: [a.absoluteString, c.absoluteString])
        XCTAssertNotNil(cache.article(for: a))
        XCTAssertNil(cache.article(for: b))
        XCTAssertNotNil(cache.article(for: c))
        cache.prune(keeping: [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPruneOnMissingDirectoryIsANoop() {
        cache.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
