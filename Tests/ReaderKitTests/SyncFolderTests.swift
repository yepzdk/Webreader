import XCTest
@testable import ReaderKit

/// The folder devices exchange files through, and a full cycle over it. Real files in a
/// temp directory, like `ArticleCacheTests`.
final class SyncFolderTests: XCTestCase {
    private var root: URL!
    private var folder: SyncFolder!
    private let me = DeviceState.Device(id: "me", name: "This Mac")
    private let them = DeviceState.Device(id: "them", name: "The iPad")

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFolderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = SyncFolder(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ device: DeviceState.Device, settings: ReaderSettings = ReaderSettings(),
                       settingsUpdatedAt: Double = 0, titles: [(String, String, Double)] = [],
                       clearedAt: Double? = nil, writtenAt: Double = 1) -> DeviceState {
        var history = ReaderHistory()
        history.entries = titles.map { ReaderHistory.Entry(title: $0.0, url: $0.1, readAt: $0.2) }
        history.clearedAt = clearedAt
        return DeviceState(device: device, writtenAt: writtenAt,
                           settingsUpdatedAt: settingsUpdatedAt, settings: settings,
                           history: history)
    }

    private func engine(_ store: KeyValueStore, at now: Double) -> SyncEngine {
        SyncEngine(folder: folder, store: store, device: me, clock: { now })
    }

    // MARK: - Folder

    func testWriteCreatesTheFolderAndPeersExcludesOurOwnFile() throws {
        try folder.write(state(me, titles: [("Mine", "https://a.test/mine", 10)]))
        try folder.write(state(them, titles: [("Theirs", "https://a.test/theirs", 20)]))

        XCTAssertEqual(try folder.peers(excluding: me.id).map(\.device.id), [them.id])
        XCTAssertEqual(folder.state(of: me.id)?.history.entries.map(\.title), ["Mine"])
        XCTAssertEqual(folder.directory.lastPathComponent, "WebReader")
    }

    func testStrayAndUnreadableFilesAreSkippedNotFatal() throws {
        try folder.write(state(them, titles: [("Theirs", "https://a.test/theirs", 20)]))
        // What a folder actually accumulates: half-written files, a stray note, a
        // conflicted copy from some other app.
        for (name, contents) in [("truncated.json", "{\"v\":1,\"dev"),
                                 ("notes.json", "[1,2,3]"),
                                 ("README.txt", "hello")] {
            try Data(contents.utf8).write(to: folder.directory.appendingPathComponent(name))
        }

        XCTAssertEqual(try folder.peers(excluding: me.id).map(\.device.id), [them.id])
    }

    func testPeersIsEmptyBeforeAnyoneHasSyncedAndThrowsWhenTheFolderIsGone() throws {
        XCTAssertEqual(try folder.peers(excluding: me.id).count, 0)

        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try folder.peers(excluding: me.id)) { error in
            XCTAssertEqual(error as? SyncError, .folderUnreadable(root.path))
        }
    }

    func testWriteRefusesToRecreateAFolderThatWasDeleted() throws {
        try folder.write(state(me))
        try FileManager.default.removeItem(at: root)

        XCTAssertThrowsError(try folder.write(state(me))) { error in
            XCTAssertEqual(error as? SyncError, .folderUnreadable(root.path))
        }
        // Nothing resurrected: publishing into a path no sync client knows about would
        // look like working sync while the devices drift apart.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - A cycle

    func testFirstCyclePublishesLocalStateAndNothingElse() throws {
        let store = MemoryStore()
        var settings = ReaderSettings()
        settings.theme = .sepia
        ReaderStore.setSettings(settings, store: store, at: 100)
        var history = ReaderHistory()
        history.record(title: "Read", url: "https://a.test/read", at: 110)
        ReaderStore.setHistory(history, store: store)

        let result = try engine(store, at: 500).sync()

        XCTAssertFalse(result.changedSettings)
        XCTAssertFalse(result.changedHistory)
        XCTAssertEqual(result.peers, [])
        let published = folder.state(of: me.id)
        XCTAssertEqual(published?.settings, settings)
        XCTAssertEqual(published?.settingsUpdatedAt, 100)
        XCTAssertEqual(published?.history.entries.map(\.title), ["Read"])
        XCTAssertEqual(published?.device, me)
        XCTAssertEqual(store.string(forKey: ReaderStore.Key.syncLastSuccess), "500.0")
    }

    func testCycleAdoptsNewerSettingsAndMergesRecents() throws {
        let store = MemoryStore()
        ReaderStore.setSettings(ReaderSettings(), store: store, at: 100)
        var mine = ReaderHistory()
        mine.record(title: "Mine", url: "https://a.test/mine", at: 110)
        ReaderStore.setHistory(mine, store: store)
        var theirs = ReaderSettings()
        theirs.theme = .dark
        theirs.fontSize = 22
        try folder.write(state(them, settings: theirs, settingsUpdatedAt: 200,
                               titles: [("Theirs", "https://a.test/theirs", 300)]))

        let result = try engine(store, at: 500).sync()

        XCTAssertTrue(result.changedSettings)
        XCTAssertTrue(result.changedHistory)
        XCTAssertEqual(result.peers, ["The iPad"])
        XCTAssertEqual(ReaderStore.settings(store: store), theirs)
        // Stamped with the winning device's time, so this device doesn't become the author.
        XCTAssertEqual(ReaderStore.settingsUpdatedAt(store: store), 200)
        XCTAssertEqual(ReaderStore.history(store: store).entries.map(\.title),
                       ["Theirs", "Mine"])
        // …and what it publishes is the merged state, so the third device gets both rows.
        XCTAssertEqual(folder.state(of: me.id)?.history.entries.map(\.title), ["Theirs", "Mine"])
    }

    /// The regression Linux found: with full-precision timestamps a state came back out of
    /// its own file slightly unequal to the one that went in, so every cycle "changed"
    /// something and rewrote the file — an upload loop over nothing. Real wall-clock values
    /// here, not round numbers, because round numbers can't catch it.
    func testACycleThatLearnedNothingDoesNotRewriteTheFile() throws {
        let store = MemoryStore()
        ReaderStore.setSettings(ReaderSettings(), store: store, at: 1_788_172_957.170757)
        var history = ReaderHistory()
        history.record(title: "Read", url: "https://a.test/read", at: 1_788_172_957.645378)
        ReaderStore.setHistory(history, store: store)

        try engine(store, at: 1_788_172_958.123456).sync()
        let first = folder.state(of: me.id)
        let second = try engine(store, at: 1_788_172_999.987654).sync()

        XCTAssertEqual(folder.state(of: me.id)?.writtenAt, first?.writtenAt)
        XCTAssertEqual(first?.writtenAt, 1_788_172_958.123)
        XCTAssertFalse(second.changedHistory)
        XCTAssertFalse(second.changedSettings)
    }

    func testAClearOnAnotherDeviceEmptiesTheListAndStaysEmpty() throws {
        let store = MemoryStore()
        var mine = ReaderHistory()
        mine.record(title: "Mine", url: "https://a.test/mine", at: 100)
        ReaderStore.setHistory(mine, store: store)
        try folder.write(state(them, clearedAt: 200))

        XCTAssertTrue(try engine(store, at: 500).sync().changedHistory)
        XCTAssertEqual(ReaderStore.history(store: store).entries, [])
        XCTAssertEqual(ReaderStore.history(store: store).clearedAt, 200)

        // The other device comes back online still carrying its pre-clear list: the
        // tombstone this device now holds keeps it out.
        try folder.write(state(them, titles: [("Old", "https://a.test/old", 150)]))
        XCTAssertFalse(try engine(store, at: 600).sync().changedHistory)
        XCTAssertEqual(ReaderStore.history(store: store).entries, [])
    }

    func testAFolderThatWentAwayLeavesLocalStateUntouched() throws {
        let store = MemoryStore()
        var settings = ReaderSettings()
        settings.theme = .black
        ReaderStore.setSettings(settings, store: store, at: 100)
        var history = ReaderHistory()
        history.record(title: "Read", url: "https://a.test/read", at: 110)
        ReaderStore.setHistory(history, store: store)
        let before = store.values

        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try engine(store, at: 500).sync())

        XCTAssertEqual(store.values, before)
    }
}
