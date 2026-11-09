import XCTest
@testable import LotsOfMedia

final class FeatureBatchTests: XCTestCase {
    private func meta(_ json: [String: Any]) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func track(_ key: String, plays: Int = 0, lastPlayed: Date? = nil, added: Int = 0) throws -> PlexMetadata {
        var j: [String: Any] = ["ratingKey": key, "type": "track", "title": "Song \(key)", "viewCount": plays, "addedAt": added]
        if let lastPlayed { j["lastViewedAt"] = Int(lastPlayed.timeIntervalSince1970) }
        return try meta(j)
    }
    private func record(_ key: String, kind: String = "movie", bytes: Int64 = 100, watched: Bool = false,
                        show: String? = nil, completed: Date = Date(), lastPlayed: Date? = nil) throws -> DownloadRecord {
        var j: [String: Any] = ["ratingKey": key, "type": kind, "title": "Item \(key)", "viewCount": watched ? 1 : 0, "viewOffset": 0]
        if let show { j["grandparentTitle"] = show; j["grandparentRatingKey"] = "show-\(show)" }
        if let lastPlayed { j["lastViewedAt"] = Int(lastPlayed.timeIntervalSince1970) }
        var r = DownloadRecord(serverID: "s", metadata: try meta(j), quality: .original)
        r.state = .completed
        r.totalBytes = bytes
        r.completedAt = completed
        return r
    }

    // MARK: Playlist sync

    func testPlaylistSyncAddsNewAndRemovesOnlyWhenAsked() {
        var c = DownloadCollection(id: "s_p", serverID: "s", ratingKey: "p", title: "Mix", thumb: nil, playlistType: "audio",
                                   itemIDs: ["s_1", "s_2", "s_3"])
        c.autoDownloadNew = true
        c.removeMissing = false
        var plan = PlaylistSyncPlan.make(collection: c, serverKeys: ["1", "3", "4"], usedElsewhere: [])
        XCTAssertEqual(plan.toDownload, ["4"])
        XCTAssertEqual(plan.toRemove, [], "Removal is a separate preference")
        XCTAssertEqual(plan.order, ["s_1", "s_3", "s_4", "s_2"], "Removed items stay downloaded, listed last")

        c.autoDownloadNew = false
        c.removeMissing = true
        plan = PlaylistSyncPlan.make(collection: c, serverKeys: ["1", "3", "4"], usedElsewhere: [])
        XCTAssertEqual(plan.toDownload, [])
        XCTAssertEqual(plan.toRemove, ["s_2"])
        XCTAssertEqual(plan.order, ["s_1", "s_3"])
    }

    func testPlaylistSyncKeepsItemsAnotherPlaylistUses() {
        var c = DownloadCollection(id: "s_p", serverID: "s", ratingKey: "p", title: "Mix", thumb: nil, playlistType: "audio", itemIDs: ["s_1", "s_2"])
        c.removeMissing = true
        let plan = PlaylistSyncPlan.make(collection: c, serverKeys: ["1"], usedElsewhere: ["s_2"])
        XCTAssertEqual(plan.toRemove, [], "Another downloaded playlist still needs it")
    }

    func testPlaylistSyncDeduplicatesRepeatedSongs() {
        var c = DownloadCollection(id: "s_p", serverID: "s", ratingKey: "p", title: "Mix", thumb: nil, playlistType: "audio", itemIDs: [])
        c.autoDownloadNew = true
        let plan = PlaylistSyncPlan.make(collection: c, serverKeys: ["7", "7", "8"], usedElsewhere: [])
        XCTAssertEqual(plan.toDownload, ["7", "8"])
    }

    // MARK: Mixes

    func testMixRules() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 86_400
        let recent = try track("1", plays: 9, lastPlayed: now.addingTimeInterval(-2 * day))
        let old = try track("2", plays: 20, lastPlayed: now.addingTimeInterval(-200 * day))
        let never = try track("3")
        let monthAgo = try track("4", plays: 1, lastPlayed: now.addingTimeInterval(-40 * day))

        XCTAssertEqual(MusicMix.mostPlayed([recent, old, never, monthAgo]).map(\.ratingKey), ["2", "1", "4"])
        XCTAssertEqual(MusicMix.rediscover([recent, old, never, monthAgo], now: now).map(\.ratingKey), ["2"])
        XCTAssertEqual(Set(MusicMix.notPlayedSince([recent, old, never, monthAgo], days: 30, now: now).map(\.ratingKey)), ["2", "3", "4"])
        XCTAssertEqual(MusicMix.unique([recent, recent, old]).count, 2)
    }

    // MARK: Watch Later

    func testWatchLaterDropsWatchedOnlyWhenEnabled() throws {
        let a = try meta(["ratingKey": "a", "type": "movie", "title": "A"])
        let b = try meta(["ratingKey": "b", "type": "movie", "title": "B"])
        let bWatched = try meta(["ratingKey": "b", "type": "movie", "title": "B", "viewCount": 1])
        XCTAssertEqual(MediaPreferences.refreshWatchLater([a, b], fresh: ["b": bWatched], removeWatched: true).map(\.ratingKey), ["a"])
        XCTAssertEqual(MediaPreferences.refreshWatchLater([a, b], fresh: ["b": bWatched], removeWatched: false).map(\.ratingKey), ["a", "b"])
    }

    // MARK: Storage cleanup

    func testCleanupSuggestions() throws {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        let records = [
            try record("m1", bytes: 5_000, watched: true),
            try record("m2", bytes: 9_000, watched: false),
            try record("e1", kind: "episode", bytes: 1_000, watched: true, show: "Show A"),
            try record("e2", kind: "episode", bytes: 1_000, watched: true, show: "Show A"),
            try record("e3", kind: "episode", bytes: 1_000, watched: true, show: "Show B"),
            try record("e4", kind: "episode", bytes: 1_000, watched: false, show: "Show B"),
            try record("t1", kind: "track", bytes: 10, completed: old),
            try record("t2", kind: "track", bytes: 10, completed: old, lastPlayed: now),
        ]
        let groups = CleanupSuggestions.make(records: records, now: now, largestCount: 2)
        XCTAssertEqual(groups[.watchedVideos]?.flatMap(\.recordIDs), [records[0].id])
        XCTAssertEqual(groups[.finishedShows]?.count, 1, "Show B still has an unwatched episode")
        XCTAssertEqual(Set(groups[.finishedShows]?.first?.recordIDs ?? []), [records[2].id, records[3].id])
        XCTAssertEqual(groups[.largest]?.flatMap(\.recordIDs), [records[1].id, records[0].id])
        XCTAssertEqual(groups[.rarelyPlayedMusic]?.flatMap(\.recordIDs), [records[6].id], "Recently played music isn't suggested")
        XCTAssertEqual(CleanupSuggestions.bytes(of: [records[0].id, records[0].id, records[1].id], records: records), 14_000)
    }

    func testCleanupNeverSuggestsUnsyncedProgress() throws {
        var r = try record("m1", watched: true)
        r.updateProgress(userID: "u", positionMs: 10, durationMs: 1000)
        XCTAssertTrue(CleanupSuggestions.make(records: [r]).values.allSatisfy(\.isEmpty))
    }

    // MARK: Troubleshooting report

    func testReportRedactsTokens() {
        let raw = """
        url https://1-2-3-4.abc.plex.direct:32400/video/:/transcode/universal/start.m3u8?path=/x&X-Plex-Token=SECRET123&session=s
        X-Plex-Token: SECRET456
        headers {"X-Plex-Token":"SECRET789"} https://plex.tv/api?token=SECRETABC authToken=SECRETDEF
        """
        let red = PlaybackReport.redact(raw)
        for secret in ["SECRET123", "SECRET456", "SECRET789", "SECRETABC", "SECRETDEF"] {
            XCTAssertFalse(red.contains(secret), "\(secret) leaked")
        }
        XCTAssertTrue(red.contains("session=s"), "Non-secret parameters are kept")
    }

    func testReportTextIsRedacted() {
        var d = PlaybackDiagnostics()
        d.add("Connection", [("Address", "host?X-Plex-Token=abc"), ("Empty", nil)])
        let text = PlaybackReport.text(d)
        XCTAssertFalse(text.contains("abc"))
        XCTAssertFalse(text.contains("Empty"), "Rows without a value are left out")
    }

    // MARK: Languages

    func testVLCMenuChoicesMapToPlexLanguages() throws {
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(#"""
        {"id": 1, "Stream": [
          {"id": 10, "streamType": 2, "languageCode": "eng"},
          {"id": 11, "streamType": 2, "languageCode": "spa"},
          {"id": 20, "streamType": 3, "languageCode": "fra", "key": "/library/streams/20"},
          {"id": 21, "streamType": 3, "languageCode": "deu"}
        ]}
        """#.utf8))
        XCTAssertEqual(VLCTrackChoice.audioLanguage(atPosition: 1, in: part), "spa")
        XCTAssertNil(VLCTrackChoice.audioLanguage(atPosition: 2, in: part))
        // VLC lists the file's own subtitles first, whatever order Plex gives them in.
        XCTAssertEqual(VLCTrackChoice.subtitleLanguage(atPosition: 0, in: part), "deu")
        XCTAssertEqual(VLCTrackChoice.subtitleLanguage(atPosition: 1, in: part), "fra")
    }

    func testLanguagePreferencePicksMatchingStreams() throws {
        let part = try JSONDecoder().decode(PlexPart.self, from: Data(#"""
        {"id": 1, "Stream": [
          {"id": 10, "streamType": 2, "languageCode": "eng", "selected": true},
          {"id": 11, "streamType": 2, "languageCode": "spa"},
          {"id": 20, "streamType": 3, "languageCode": "spa", "forced": true},
          {"id": 21, "streamType": 3, "languageCode": "spa"},
          {"id": 22, "streamType": 3, "languageCode": "eng", "selected": true}
        ]}
        """#.utf8))
        XCTAssertEqual(LanguagePreference.change(for: part, audio: "spa", subtitle: "spa"),
                       .init(audioStreamID: 11, subtitleStreamID: 21), "Full subtitles beat forced ones")
        XCTAssertEqual(LanguagePreference.change(for: part, audio: "eng", subtitle: "off"), .init(audioStreamID: nil, subtitleStreamID: 0))
        XCTAssertNil(LanguagePreference.change(for: part, audio: "eng", subtitle: "eng"), "Already matching")
        XCTAssertNil(LanguagePreference.change(for: part, audio: "fra", subtitle: nil), "No French track: leave it alone")
    }

    // MARK: Offline cache

    func testLibraryCacheScopesAndSkipsPlayState() {
        let a = LibraryCache.key(serverID: "s", token: "userA", path: "/library/sections", query: [])
        let b = LibraryCache.key(serverID: "s", token: "userB", path: "/library/sections", query: [])
        XCTAssertNotEqual(a, b, "Each profile has its own cache")
        let q1 = LibraryCache.key(serverID: "s", token: "t", path: "/hubs", query: [.init(name: "a", value: "1"), .init(name: "b", value: "2")])
        let q2 = LibraryCache.key(serverID: "s", token: "t", path: "/hubs", query: [.init(name: "b", value: "2"), .init(name: "a", value: "1")])
        XCTAssertEqual(q1, q2, "Query order doesn't matter")
        XCTAssertTrue(LibraryCache.isCacheable(path: "/library/metadata/1", method: "GET"))
        XCTAssertTrue(LibraryCache.isCacheable(path: "/playlists/5/items", method: "GET"))
        XCTAssertFalse(LibraryCache.isCacheable(path: "/playlists", method: "POST"))
        XCTAssertFalse(LibraryCache.isCacheable(path: "/:/timeline", method: "GET"))
        XCTAssertFalse(LibraryCache.isCacheable(path: "/downloadQueue/1", method: "GET"))
        LibraryCache.$requireFresh.withValue(true) {
            XCTAssertFalse(LibraryCache.isCacheable(path: "/playlists/5/items", method: "GET"), "Syncs must see live data")
        }
    }

    func testLibraryCacheRoundTripAndTrim() throws {
        let key = LibraryCache.key(serverID: "test", token: UUID().uuidString, path: "/library/sections", query: [])
        LibraryCache.write(Data("hello".utf8), key: key)
        LibraryCache.waitForPendingWrites()   // writes land on the cache's own queue
        XCTAssertEqual(LibraryCache.read(key), Data("hello".utf8))
        LibraryCache.trim(limit: 0)
        XCTAssertNil(LibraryCache.read(key))
    }

    // MARK: Listening session

    func testSavedSessionRoundTrip() throws {
        let saved = AudioPlayer.SavedSession(items: [.init(track: try track("1"), serverID: "s"), .init(track: try track("2"), serverID: "t")],
                                             index: 1, position: 42.5, shuffled: true, originalOrder: [1, 0])
        let decoded = try JSONDecoder().decode(AudioPlayer.SavedSession.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.items.map(\.serverID), ["s", "t"])
        XCTAssertEqual(decoded.index, 1)
        XCTAssertEqual(decoded.position, 42.5)
        XCTAssertEqual(decoded.originalOrder, [1, 0])
        XCTAssertTrue(decoded.shuffled)
    }
}

final class MusicHomeTests: XCTestCase {
    private func playlist(_ key: String, type: String = "audio", viewed: Int? = nil, added: Int = 0) throws -> PlexMetadata {
        var j: [String: Any] = ["ratingKey": key, "type": "playlist", "title": key, "playlistType": type, "addedAt": added]
        if let viewed { j["lastViewedAt"] = viewed }
        return try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: j))
    }

    func testPlaylistsSortByMostRecentlyPlayed() throws {
        let list = try [playlist("old", viewed: 100), playlist("new", viewed: 900), playlist("never-new", added: 50),
                        playlist("never-old", added: 10), playlist("video", type: "video", viewed: 999)]
        XCTAssertEqual(MusicPlaylists.recentlyPlayedFirst(list).map(\.ratingKey), ["new", "old", "never-new", "never-old"])
    }

    func testNewHomeSectionsSlotInAfterTheirNeighbour() {
        let saved = MediaPreferences.HomeLayout(order: ["recent", "shortcuts", "albums"])
        let defaults = ["shortcuts", "recent", "playlists", "albums", "favorites"]
        XCTAssertEqual(saved.normalized(defaults: defaults).order, ["recent", "playlists", "shortcuts", "albums", "favorites"])
    }
}

final class PlaylistDefaultsTests: XCTestCase {
    func testNewSongsDownloadByDefault() {
        let c = DownloadCollection(id: "s_p", serverID: "s", ratingKey: "p", title: "Mix", thumb: nil, playlistType: "audio", itemIDs: ["s_1"])
        XCTAssertTrue(c.keepsUpdated, "Downloaded playlists pick up new songs unless turned off")
        let plan = PlaylistSyncPlan.make(collection: c, serverKeys: ["1", "2"], usedElsewhere: [])
        XCTAssertEqual(plan.toDownload, ["2"])
        XCTAssertEqual(plan.toRemove, [], "Removal stays opt-in")
    }

    /// Shuffle picks the first song at random too, instead of always starting with song 1.
    func testShuffleRandomizesTheFirstSong() {
        let songs = Array(0..<10)
        var firsts = Set<Int>()
        for _ in 0..<500 {
            let order = AudioPlayer.shuffled(songs, first: nil)
            XCTAssertEqual(order.sorted(), songs, "Every song exactly once")
            firsts.insert(order[0])
        }
        XCTAssertEqual(firsts, Set(songs), "Any song can come first")
        // A tapped song stays first; the rest are still shuffled.
        var seconds = Set<Int>()
        for _ in 0..<500 {
            let order = AudioPlayer.shuffled(songs, first: 4)
            XCTAssertEqual(order[0], 4)
            XCTAssertEqual(order.sorted(), songs)
            seconds.insert(order[1])
        }
        XCTAssertEqual(seconds, Set(songs).subtracting([4]))
    }
}
