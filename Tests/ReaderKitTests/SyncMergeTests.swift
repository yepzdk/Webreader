import XCTest
@testable import ReaderKit

/// The merge rules two devices' recents and settings are folded together by, and the
/// device-file codec they travel in. Pure — no folder, no I/O.
final class SyncMergeTests: XCTestCase {
    private func history(_ rows: [(String, String, Double?)],
                         clearedAt: Double? = nil) -> ReaderHistory {
        var history = ReaderHistory()
        history.entries = rows.map { ReaderHistory.Entry(title: $0.0, url: $0.1, readAt: $0.2) }
        history.clearedAt = clearedAt
        return history
    }

    private func device(_ id: String, settings: ReaderSettings = ReaderSettings(),
                        settingsUpdatedAt: Double = 0,
                        history: ReaderHistory = ReaderHistory(),
                        writtenAt: Double = 0) -> DeviceState {
        DeviceState(device: DeviceState.Device(id: id, name: "Device " + id),
                    writtenAt: writtenAt, settingsUpdatedAt: settingsUpdatedAt,
                    settings: settings, history: history)
    }

    // MARK: - History

    func testUnionIsNewestFirstAndKeepsTheNewerTitle() {
        let mac = history([("Mac only", "https://a.test/1", 300),
                           ("Old headline", "https://a.test/shared", 100)])
        let pad = history([("Pad only", "https://a.test/2", 200),
                           ("Edited headline", "https://a.test/shared", 400)])

        let merged = mac.merging(pad)

        XCTAssertEqual(merged.entries.map(\.url),
                       ["https://a.test/shared", "https://a.test/1", "https://a.test/2"])
        // One row per URL, carrying the title of the newer read.
        XCTAssertEqual(merged.entries[0].title, "Edited headline")
        XCTAssertEqual(merged.entries[0].readAt, 400)
    }

    func testMergingIsSymmetricAndCapsAtTheLimit() {
        let mac = history((0..<25).map { ("Mac \($0)", "https://a.test/mac/\($0)", Double(100 + $0)) })
        let pad = history((0..<25).map { ("Pad \($0)", "https://a.test/pad/\($0)", Double(200 + $0)) })

        let forward = mac.merging(pad)
        let backward = pad.merging(mac)

        XCTAssertEqual(forward.entries.count, ReaderHistory.limit)
        XCTAssertEqual(forward.entries.map(\.url), backward.entries.map(\.url))
        // The cap keeps the newest, so the whole of the newer device's list survives.
        XCTAssertEqual(forward.entries.prefix(25).map(\.title),
                       (0..<25).reversed().map { "Pad \($0)" })
    }

    func testTombstoneDropsEverythingReadBeforeTheClear() {
        let cleared = ReaderHistory(clearedAt: 500)
        let reader = history([("Before", "https://a.test/before", 400),
                             ("After", "https://a.test/after", 600)])

        let merged = cleared.merging(reader)

        XCTAssertEqual(merged.clearedAt, 500)
        XCTAssertEqual(merged.entries.map(\.title), ["After"])
    }

    /// The acceptance criterion a plain "clear both lists" scheme fails: a device that was
    /// offline during the clear syncs later and must not put the list back.
    func testStaleDeviceCannotResurrectAClearedList() {
        let stale = history([("Old", "https://a.test/old", 100),
                            ("Older", "https://a.test/older", 50)])
        let cleared = ReaderHistory(clearedAt: 200)

        XCTAssertEqual(cleared.merging(stale).entries, [])
        // …and the stale device, having merged, keeps the tombstone rather than its rows.
        let onStaleDevice = stale.merging(cleared)
        XCTAssertEqual(onStaleDevice.entries, [])
        XCTAssertEqual(onStaleDevice.clearedAt, 200)
    }

    func testUntimestampedRowsSortLastAndAreDroppedByATombstone() {
        let legacy = history([("Pre-sync", "https://a.test/legacy", nil)])
        let timed = history([("Read", "https://a.test/read", 10)])

        let merged = legacy.merging(timed)
        XCTAssertEqual(merged.entries.map(\.title), ["Read", "Pre-sync"])

        // Timestamps start with sync, so an untimestamped row predates every clear.
        XCTAssertEqual(legacy.merging(ReaderHistory(clearedAt: 1)).entries, [])
    }

    func testMergingKeepsTheLocalCopyOnATie() {
        let mine = history([("Mine", "https://a.test/x", 100)])
        let theirs = history([("Theirs", "https://a.test/x", 100)])

        XCTAssertEqual(mine.merging(theirs).entries.map(\.title), ["Mine"])
        XCTAssertEqual(theirs.merging(mine).entries.map(\.title), ["Theirs"])
    }

    // MARK: - Fold across devices

    func testSettingsAreLastWriterWinsAcrossDevices() {
        var sepia = ReaderSettings()
        sepia.theme = .sepia
        var dark = ReaderSettings()
        dark.theme = .dark

        let folded = SyncMerge.fold(settings: ReaderSettings(), settingsUpdatedAt: 100,
                                    history: ReaderHistory(),
                                    peers: [device("a", settings: sepia, settingsUpdatedAt: 200),
                                            device("b", settings: dark, settingsUpdatedAt: 300)])

        XCTAssertEqual(folded.settings, dark)
        XCTAssertEqual(folded.settingsUpdatedAt, 300)
    }

    func testLocalSettingsWinATieSoAFoldNeverFlipFlops() {
        var peerSettings = ReaderSettings()
        peerSettings.theme = .black
        var local = ReaderSettings()
        local.theme = .light

        let folded = SyncMerge.fold(settings: local, settingsUpdatedAt: 500,
                                    history: ReaderHistory(),
                                    peers: [device("a", settings: peerSettings,
                                                   settingsUpdatedAt: 500)])

        XCTAssertEqual(folded.settings, local)
    }

    func testFoldDoesNotDependOnPeerOrder() {
        var one = ReaderSettings()
        one.fontSize = 22
        var two = ReaderSettings()
        two.fontSize = 14
        let peers = [device("a", settings: one, settingsUpdatedAt: 400,
                            history: history([("A", "https://a.test/a", 10)])),
                     device("b", settings: two, settingsUpdatedAt: 400,
                            history: history([("B", "https://a.test/b", 20)]))]

        let forward = SyncMerge.fold(settings: ReaderSettings(), settingsUpdatedAt: 0,
                                     history: ReaderHistory(), peers: peers)
        let reversed = SyncMerge.fold(settings: ReaderSettings(), settingsUpdatedAt: 0,
                                      history: ReaderHistory(), peers: peers.reversed())

        XCTAssertEqual(forward, reversed)
        // Two peers writing in the same second: the first-sorting device id wins, so every
        // device reaches the same answer whatever order it reads the folder in.
        XCTAssertEqual(forward.settings.fontSize, 22)
        XCTAssertEqual(forward.history.entries.map(\.title), ["B", "A"])
    }

    // MARK: - Device files

    func testDeviceFileRoundTrips() {
        var settings = ReaderSettings()
        settings.theme = .sepia
        settings.fontSize = 21
        let state = device("6F1C", settings: settings, settingsUpdatedAt: 1_756_000_000,
                           history: history([("Read", "https://a.test/read", 1_756_000_100)],
                                            clearedAt: 1_755_000_000),
                           writtenAt: 1_756_000_200)

        XCTAssertEqual(DeviceState.fromJSON(state.json), state)
        XCTAssertEqual(state.fileName, "6F1C.json")
        // Byte-identical for identical state: an unchanged cycle must not look like a new
        // file to whatever syncs the folder.
        XCTAssertEqual(state.json, DeviceState.fromJSON(state.json)?.json)
    }

    func testDeviceFileDecodeRejectsWhatItCannotMerge() {
        XCTAssertNil(DeviceState.fromJSON(nil))
        XCTAssertNil(DeviceState.fromJSON("not json"))
        XCTAssertNil(DeviceState.fromJSON("[]"))
        // A future format: skipped, not guessed at.
        XCTAssertNil(DeviceState.fromJSON("{\"v\":2,\"device\":{\"id\":\"a\"}}"))
        XCTAssertNil(DeviceState.fromJSON("{\"v\":1,\"device\":{\"name\":\"No id\"}}"))
    }

    func testDeviceFileToleratesMissingAndGarbledFields() {
        let state = DeviceState.fromJSON("""
            {"v":1,"device":{"id":"a"},"settings":{"theme":"nonsense"},"history":"?"}
            """)

        XCTAssertEqual(state?.device.name, "a")
        XCTAssertEqual(state?.settings, ReaderSettings())
        XCTAssertEqual(state?.history, ReaderHistory())
        XCTAssertEqual(state?.settingsUpdatedAt, 0)
    }
}
