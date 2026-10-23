import XCTest
@testable import LotsOfMedia

/// Links from the Home Screen widget and Top Shelf name their server, and the library cache
/// copes with many responses arriving at once.
final class SessionIsolationTests: XCTestCase {
    func testLinksCarryTheirServer() throws {
        let url = TopShelfSnapshot.link("play", "1234", server: "abc-server")
        XCTAssertEqual(url.absoluteString, "lotsofmedia://play/1234?server=abc-server")
        let parsed = try XCTUnwrap(TopShelfSnapshot.parse(url))
        XCTAssertEqual(parsed.action, "play")
        XCTAssertEqual(parsed.key, "1234")
        XCTAssertEqual(parsed.server, "abc-server")
    }

    func testOldLinksWithoutAServerStillParse() throws {
        let parsed = try XCTUnwrap(TopShelfSnapshot.parse(URL(string: "lotsofmedia://item/99")!))
        XCTAssertEqual(parsed.action, "item")
        XCTAssertEqual(parsed.key, "99")
        XCTAssertNil(parsed.server)
        XCTAssertNil(TopShelfSnapshot.parse(URL(string: "lotsofmedia://delete/99")!), "Only item and play links are accepted")
        XCTAssertNil(TopShelfSnapshot.parse(URL(string: "https://example.com/play/99")!))
    }

    func testSnapshotsSavedByOlderVersionsStillLoad() throws {
        let old = #"{"items":[{"ratingKey":"7","title":"Movie"}]}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(TopShelfSnapshot.self, from: old)
        XCTAssertEqual(snapshot.items.first?.ratingKey, "7")
        XCTAssertNil(snapshot.serverID)
    }

    func testConcurrentCacheWritesAreSafe() {
        let group = DispatchGroup()
        for i in 0..<400 {
            DispatchQueue.global().async(group: group) {
                LibraryCache.write(Data("response \(i)".utf8), key: "isolation-test-\(i)")
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        LibraryCache.waitForPendingWrites()
        XCTAssertNotNil(LibraryCache.read("isolation-test-399"))
        for i in 0..<400 { try? FileManager.default.removeItem(at: LibraryCache.directory.appendingPathComponent("isolation-test-\(i)")) }
    }
}

/// Search over downloads.
final class OfflineSearchTests: XCTestCase {
    private func record(_ key: String, title: String, type: String, show: String? = nil) throws -> DownloadRecord {
        var j: [String: Any] = ["ratingKey": key, "type": type, "title": title]
        if let show { j["grandparentTitle"] = show }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [j]]])
        let meta = try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
        var r = DownloadRecord(serverID: "s", metadata: meta, quality: .original)
        r.state = .completed
        return r
    }

    func testMatchesTitlesShowsAndArtistsIgnoringCaseAndAccents() throws {
        let records = [try record("1", title: "Café Del Mar", type: "track", show: "Chillout Artist"),
                       try record("2", title: "Pilot", type: "episode", show: "Severance"),
                       try record("3", title: "Sintel", type: "movie")]
        XCTAssertEqual(OfflineSearch.matches(records, query: "cafe", mode: .music).map(\.metadata.title), ["Café Del Mar"])
        XCTAssertEqual(OfflineSearch.matches(records, query: "chillout", mode: .music).map(\.metadata.title), ["Café Del Mar"])
        XCTAssertEqual(OfflineSearch.matches(records, query: "sever", mode: .watch).map(\.metadata.title), ["Pilot"])
        XCTAssertEqual(OfflineSearch.matches(records, query: "sin", mode: .watch, category: .movies).map(\.metadata.title), ["Sintel"])
        XCTAssertTrue(OfflineSearch.matches(records, query: "sin", mode: .watch, category: .tv).isEmpty)
        XCTAssertTrue(OfflineSearch.matches(records, query: "s", mode: .watch).isEmpty, "Two characters at least")
    }
}

/// Lyrics from the server: timed LRC and plain text.
final class LyricsTests: XCTestCase {
    func testParsesTimedLyricsInOrder() throws {
        let lrc = "[ar:Somebody]\n[00:12.50]First line\n[00:05.00]Intro\n[01:02.3][01:30.00]Chorus"
        let lyrics = try XCTUnwrap(Lyrics.parse(lrc))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Intro", "First line", "Chorus", "Chorus"])
        XCTAssertEqual(lyrics.lines.first?.time ?? 0, 5, accuracy: 0.01)
        XCTAssertEqual(lyrics.lines[2].time ?? 0, 62.3, accuracy: 0.01)
        XCTAssertEqual(lyrics.currentLine(at: 13), 1)
        XCTAssertNil(lyrics.currentLine(at: 1))
    }

    func testPlainLyricsKeepTheirLines() throws {
        let lyrics = try XCTUnwrap(Lyrics.parse("\nVerse one\n\nVerse two\n"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Verse one", "", "Verse two"])
        XCTAssertNil(Lyrics.parse("  \n "))
    }

    func testSoundCheckGainComesFromTheAudioStream() throws {
        let json: [String: Any] = ["ratingKey": "1", "type": "track", "title": "Loud",
                                   "Media": [["id": 1, "Part": [["id": 1, "Stream": [["id": 1, "streamType": 2, "gain": "-7.5"]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [json]]])
        let track = try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
        XCTAssertEqual(AudioPlayer.gain(of: track) ?? 0, -7.5, accuracy: 0.001)
    }
}

/// The Downloads readiness summary.
final class OfflineReadinessTests: XCTestCase {
    func testCountsByState() throws {
        func rec(_ key: String, _ state: DownloadRecord.State) throws -> DownloadRecord {
            let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["ratingKey": key, "type": "movie", "title": key]]]])
            var r = DownloadRecord(serverID: "s", metadata: try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first), quality: .original)
            r.state = state
            return r
        }
        let c = OfflineReadinessCard.counts([try rec("a", .completed), try rec("b", .completed), try rec("c", .preparing),
                                             try rec("d", .downloading), try rec("e", .queued), try rec("f", .failed),
                                             try rec("g", .paused)], userID: nil)
        XCTAssertEqual(c.ready, 2); XCTAssertEqual(c.converting, 1); XCTAssertEqual(c.downloading, 2); XCTAssertEqual(c.failed, 1)
        XCTAssertEqual(c.paused, 1, "Paused downloads are their own count, not downloading")
        XCTAssertFalse(c.allReady)
        XCTAssertTrue(OfflineReadinessCard.counts([try rec("a", .completed)], userID: nil).allReady)
    }
}

/// Playback Info's suggestions.
final class PlaybackAdviceTests: XCTestCase {
    func testSuggestsTheBuiltInPlayerForIncompatibleFiles() {
        var f = DiagnosticsBuilder.AdviceFacts()
        f.isConverting = true; f.incompatibilities = ["MKV files"]; f.builtInPlayerOff = true
        XCTAssertTrue(DiagnosticsBuilder.advice(f).contains { $0.contains("Built-in Player") })
    }

    func testSuggestsOriginalQualityWhenConvertingOnlyForSize() {
        var f = DiagnosticsBuilder.AdviceFacts()
        f.isConverting = true; f.qualityIsOriginal = false
        XCTAssertTrue(DiagnosticsBuilder.advice(f).contains { $0.contains("Original") })
    }

    func testRelaySlowServerAndCellularStalls() {
        var f = DiagnosticsBuilder.AdviceFacts()
        f.relay = true; f.serverSpeed = 0.7; f.cellular = true; f.stalls = 2
        let tips = DiagnosticsBuilder.advice(f)
        XCTAssertTrue(tips.contains { $0.contains("Relay") })
        XCTAssertTrue(tips.contains { $0.contains("slower than real time") })
        XCTAssertTrue(tips.contains { $0.contains("cellular") })
    }

    func testNothingToSuggestForDownloads() {
        var f = DiagnosticsBuilder.AdviceFacts()
        f.isDownloaded = true; f.relay = true; f.stalls = 9
        XCTAssertTrue(DiagnosticsBuilder.advice(f).isEmpty)
    }
}

/// The saved queue and its position checkpoint belong together.
final class QueueCheckpointTests: XCTestCase {
    func testCheckpointMustMatchItsQueue() {
        let id = UUID()
        let saved = AudioPlayer.SavedSession(items: [], index: 0, position: 0, shuffled: false, originalOrder: [], snapshotID: id)
        XCTAssertTrue(AudioPlayer.checkpoint(.init(index: 1, position: 5, count: 0, snapshotID: id), matches: saved))
        XCTAssertFalse(AudioPlayer.checkpoint(.init(index: 1, position: 5, count: 0, snapshotID: UUID()), matches: saved),
                       "A checkpoint from another save of the same length is rejected")
        let old = AudioPlayer.SavedSession(items: [], index: 0, position: 0, shuffled: false, originalOrder: [])
        XCTAssertTrue(AudioPlayer.checkpoint(.init(index: 0, position: 1, count: 0), matches: old), "Older saves still match by length")
    }
}

/// Second review: logout clearing and offline queue actions.
final class SecondReviewTests: XCTestCase {
    func testWritesQueuedBeforeClearDoNotComeBack() {
        let key = "clear-barrier-\(UUID().uuidString)"
        LibraryCache.write(Data("old session".utf8), key: key)
        LibraryCache.clear()
        LibraryCache.waitForPendingWrites()
        XCTAssertNil(LibraryCache.read(key), "A response from before sign-out must not be restored")
        LibraryCache.write(Data("new session".utf8), key: key)
        LibraryCache.waitForPendingWrites()
        XCTAssertNotNil(LibraryCache.read(key), "Writes after the clear still land")
        try? FileManager.default.removeItem(at: LibraryCache.directory.appendingPathComponent(key))
    }

    @MainActor func testPlayNextOnADownloadUsesItsServer() throws {
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["ratingKey": "77", "type": "track", "title": "From A"]]]])
        let song = try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
        let app = AppState()
        AudioPlayer.shared.stop()
        defer { AudioPlayer.shared.stop() }
        app.addToQueue(song, next: true, serverID: "server-A")
        XCTAssertEqual(AudioPlayer.shared.current?.serverID, "server-A")
    }
}

/// Third review: in-flight responses after sign-out, and upgrading older saved queues.
final class ThirdReviewTests: XCTestCase {
    func testResponseFromARequestStartedBeforeClearIsDropped() {
        let key = "inflight-\(UUID().uuidString)"
        let startedAt = LibraryCache.generation      // the request starts…
        LibraryCache.clear()                         // …sign-out happens…
        LibraryCache.write(Data("late".utf8), key: key, generation: startedAt)   // …then its response arrives
        LibraryCache.waitForPendingWrites()
        XCTAssertNil(LibraryCache.read(key))
    }

    @MainActor func testOlderSavedQueueIsUpgradedSoCheckpointsMatch() throws {
        let player = AudioPlayer.shared
        player.stop(); player.saveSession(wait: true)
        defer { player.stop(); player.saveSession(wait: true) }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["ratingKey": "1", "type": "track", "title": "Old"]]]])
        let song = try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
        // A queue file from the previous version: no snapshot ID, no checkpoint.
        let legacy = AudioPlayer.SavedSession(items: [.init(track: song, serverID: "s")], index: 0, position: 10, shuffled: false, originalOrder: [0])
        try JSONEncoder().encode(legacy).write(to: AudioPlayer.sessionURL, options: .atomic)
        try? FileManager.default.removeItem(at: AudioPlayer.checkpointURL)

        player.restoreSession()
        player.saveSession(wait: true)   // listening on without editing the queue

        let rewritten = try JSONDecoder().decode(AudioPlayer.SavedSession.self, from: Data(contentsOf: AudioPlayer.sessionURL))
        let checkpoint = try JSONDecoder().decode(AudioPlayer.Checkpoint.self, from: Data(contentsOf: AudioPlayer.checkpointURL))
        XCTAssertNotNil(rewritten.snapshotID, "The queue file is rewritten with a snapshot ID")
        XCTAssertTrue(AudioPlayer.checkpoint(checkpoint, matches: rewritten), "and the checkpoint belongs to it")
    }
}

/// Shuffle: from the last song, and staying on when a song is picked.
final class ShuffleBehaviorTests: XCTestCase {
    private func songs(_ n: Int) throws -> [PlexMetadata] {
        let items = (1...n).map { ["ratingKey": "\($0)", "type": "track", "title": "Song \($0)"] }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": items]])
        return try PlexServerAPI.decodeContainer(data).metadata
    }

    @MainActor func testShuffleFromTheLastSongShufflesTheRestOfThePlaylist() throws {
        let player = AudioPlayer.shared
        defer { player.stop(); if player.shuffled { player.toggleShuffle() } }
        if player.shuffled { player.toggleShuffle() }
        player.play(try songs(6), serverID: "s", startAt: 5)
        XCTAssertEqual(player.current?.track.ratingKey, "6")
        XCTAssertTrue(player.upcoming.isEmpty)

        player.toggleShuffle()
        XCTAssertTrue(player.shuffled)
        XCTAssertEqual(player.current?.track.ratingKey, "6", "The song playing keeps playing")
        XCTAssertEqual(player.index, 0)
        XCTAssertEqual(Set(player.upcoming.map(\.track.ratingKey)), ["1", "2", "3", "4", "5"], "Everything else comes next")

        player.toggleShuffle()
        XCTAssertFalse(player.shuffled)
        XCTAssertEqual(player.queue.map(\.track.ratingKey), ["1", "2", "3", "4", "5", "6"], "Original order comes back")
        XCTAssertEqual(player.current?.track.ratingKey, "6")
    }

    @MainActor func testPickingASongKeepsShuffleOnAndPlayInOrderTurnsItOff() throws {
        let player = AudioPlayer.shared
        defer { player.stop(); if player.shuffled { player.toggleShuffle() } }
        let list = try songs(8)
        player.play(list, serverID: "s", shuffle: true)          // the Shuffle button
        XCTAssertTrue(player.shuffled)

        player.play(list, serverID: "s", startAt: 3)             // then a song picked from the playlist
        XCTAssertTrue(player.shuffled, "Shuffle stays on")
        XCTAssertEqual(player.current?.track.ratingKey, "4", "The picked song plays first")
        XCTAssertEqual(player.queue.count, 8)

        player.play(list, serverID: "s")                          // a Play button
        XCTAssertFalse(player.shuffled, "Play plays in order")
        XCTAssertEqual(player.queue.map(\.track.ratingKey), list.map(\.ratingKey))
    }
}
