import XCTest
@testable import LotsOfMedia

/// Versions, ratings, scrub previews, settings backups, Smart Downloads specials and the
/// Jellyfin translation (Jellyfin items read as the Plex shapes the app uses).
@MainActor
final class PlezyParityTests: XCTestCase {
    private func decode(_ json: [String: Any]) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func jellyfinAPI() -> PlexServerAPI {
        PlexServerAPI(baseURL: URL(string: "http://jf.local:8096")!, token: "TOKEN", serverID: JellyfinBridge.idPrefix + "abc")
    }

    /// A Jellyfin episode with two versions (4K HEVC MKV with subtitles, and a 1080p MP4).
    private var jellyfinEpisode: [String: Any] {
        func source(_ id: String, container: String, width: Int, height: Int, codec: String, range: String) -> [String: Any] {
            ["Id": id, "Container": container, "Size": 1_000_000, "Bitrate": 8_000_000, "RunTimeTicks": 26_000_000_000,
             "DefaultAudioStreamIndex": 1,
             "MediaStreams": [
                ["Type": "Video", "Index": 0, "Codec": codec, "Width": width, "Height": height, "VideoRangeType": range,
                 "RealFrameRate": 23.976],
                ["Type": "Audio", "Index": 1, "Codec": "eac3", "Channels": 6, "Language": "eng", "DisplayTitle": "English EAC3 5.1",
                 "IsDefault": true],
                ["Type": "Subtitle", "Index": 2, "Codec": "subrip", "Language": "eng", "DisplayTitle": "English",
                 "IsTextSubtitleStream": true],
                ["Type": "Subtitle", "Index": 3, "Codec": "PGSSUB", "Language": "fre", "IsTextSubtitleStream": false],
            ]]
        }
        return [
            "Id": "ep1", "Type": "Episode", "Name": "Pilot", "SeriesName": "Show", "SeriesId": "show1", "SeasonId": "season1",
            "SeasonName": "Season 1", "IndexNumber": 1, "ParentIndexNumber": 1, "RunTimeTicks": 26_000_000_000,
            "Overview": "It begins.", "PremiereDate": "2024-05-01T00:00:00.0000000Z", "DateCreated": "2024-05-02T10:20:30.1234567Z",
            "ImageTags": ["Primary": "t"], "SeriesPrimaryImageTag": "s", "ParentBackdropItemId": "show1",
            "CommunityRating": 8.4, "CriticRating": 91,
            "UserData": ["Played": false, "PlaybackPositionTicks": 6_000_000_000, "PlayCount": 0, "Likes": true],
            "GenreItems": [["Name": "Drama", "Id": "g1"]],
            "People": [["Name": "Ann", "Id": "p1", "Type": "Actor", "Role": "Lead", "PrimaryImageTag": "x"],
                       ["Name": "Dee", "Id": "p2", "Type": "Director"]],
            "Chapters": [["Name": "Opening", "StartPositionTicks": 0, "ImageTag": "c"],
                         ["Name": "Middle", "StartPositionTicks": 6_000_000_000]],
            "MediaSources": [source("src4k", container: "mkv", width: 3840, height: 2160, codec: "hevc", range: "DOVIWithHDR10"),
                             source("src1080", container: "mov,mp4,m4a,3gp,3g2,mj2", width: 1920, height: 1080, codec: "h264", range: "SDR")],
        ]
    }

    // MARK: Jellyfin

    func testJellyfinEpisodeReadsAsAPlexEpisode() throws {
        let bridge = JellyfinBridge(api: jellyfinAPI())
        let item = try decode(bridge.map(jellyfinEpisode))
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.ratingKey, "ep1")
        XCTAssertEqual(item.grandparentTitle, "Show")
        XCTAssertEqual(item.grandparentRatingKey, "show1")
        XCTAssertEqual(item.parentRatingKey, "season1")
        XCTAssertEqual(item.index, 1)
        XCTAssertEqual(item.duration, 2_600_000)
        XCTAssertEqual(item.viewOffset, 600_000)
        XCTAssertFalse(item.isWatched)
        XCTAssertEqual(item.originallyAvailableAt, "2024-05-01")
        XCTAssertNotNil(item.addedAt)
        XCTAssertEqual(item.thumb, "/Items/ep1/Images/Primary")
        XCTAssertEqual(item.grandparentThumb, "/Items/show1/Images/Primary")
        XCTAssertEqual(item.genres.first?.tag, "Drama")
        XCTAssertEqual(item.roles.first?.tag, "Ann")
        XCTAssertEqual(item.roles.first?.thumb, "/Items/p1/Images/Primary")
        XCTAssertEqual(item.directors.first?.tag, "Dee")
        XCTAssertEqual(item.userRating, 10)
        XCTAssertEqual(item.chapters.map(\.title), ["Opening", "Middle"])
        XCTAssertEqual(item.chapters.first?.thumb, "/Items/ep1/Images/Chapter/0")
        XCTAssertEqual(item.chapters.last?.startTimeOffset, 600_000)
    }

    func testJellyfinVersionsAndStreams() throws {
        let item = try decode(JellyfinBridge(api: jellyfinAPI()).map(jellyfinEpisode))
        XCTAssertEqual(item.media.count, 2)
        let uhd = item.media[0], hd = item.media[1]
        XCTAssertEqual(uhd.resolutionLabel, "4K")
        XCTAssertEqual(uhd.container, "mkv")
        XCTAssertEqual(hd.container, "mp4", "Jellyfin's list of MP4 names becomes mp4")
        XCTAssertEqual(hd.resolutionLabel, "1080p")
        XCTAssertNotEqual(uhd.id, hd.id)
        let part = try XCTUnwrap(uhd.parts.first)
        XCTAssertEqual(part.key, "/Videos/ep1/stream.mkv?static=true&mediaSourceId=src4k")
        XCTAssertEqual(part.streams.first { $0.streamType == 1 }?.doviPresent, true)
        XCTAssertEqual(part.selectedAudio?.codec, "eac3")
        XCTAssertEqual(part.selectedAudio?.channels, 6)
        let text = try XCTUnwrap(part.subtitleStreams.first { $0.codec == "srt" })
        XCTAssertTrue(text.isSidecarText, "Text subtitles come from the server as SRT the app draws")
        XCTAssertEqual(JellyfinBridge.subtitleKey(for: text.id), "/Videos/ep1/src4k/Subtitles/2/0/Stream.srt")
        let image = try XCTUnwrap(part.subtitleStreams.first { $0.codec == "pgs" })
        XCTAssertNil(image.key, "Image subtitles are burned in or played by the built-in player")
        XCTAssertTrue(PlaybackDecider.canPlayNatively(media: hd, kind: .episode))
        XCTAssertFalse(PlaybackDecider.canPlayNatively(media: uhd, kind: .episode))
    }

    func testJellyfinStreamSelectionShowsAsSelected() throws {
        var json = jellyfinEpisode
        var sources = json["MediaSources"] as! [[String: Any]]
        var streams = sources[0]["MediaStreams"] as! [[String: Any]]
        streams.append(["Type": "Audio", "Index": 4, "Codec": "aac", "Channels": 2, "Language": "jpn"])
        sources[0]["MediaStreams"] = streams
        json["MediaSources"] = sources
        let bridge = JellyfinBridge(api: jellyfinAPI())
        let part = try XCTUnwrap(decode(bridge.map(json)).media.first?.parts.first)
        let japanese = try XCTUnwrap(part.audioStreams.first { $0.languageCode == "jpn" })
        let english = try XCTUnwrap(part.subtitleStreams.first { $0.codec == "srt" })
        JellyfinBridge.setStreamSelection(partID: part.id, audio: japanese.id, subtitle: english.id)
        let again = try XCTUnwrap(decode(bridge.map(json)).media.first?.parts.first)
        XCTAssertEqual(again.selectedAudio?.languageCode, "jpn")
        XCTAssertEqual(again.selectedSubtitle?.id, english.id)
        JellyfinBridge.setStreamSelection(partID: part.id, audio: nil, subtitle: 0)   // Plex's "no subtitles"
        XCTAssertNil(try decode(bridge.map(json)).media.first?.parts.first?.selectedSubtitle)
    }

    func testJellyfinTypesAndContainers() throws {
        let bridge = JellyfinBridge(api: jellyfinAPI())
        let series = try decode(bridge.map(["Id": "s", "Type": "Series", "Name": "Show", "ChildCount": 2, "RecursiveItemCount": 20,
                                            "UserData": ["UnplayedItemCount": 5, "Played": false]]))
        XCTAssertEqual(series.kind, .show)
        XCTAssertEqual(series.key, "/library/metadata/s/children")
        XCTAssertEqual(series.leafCount, 20)
        XCTAssertEqual(series.viewedLeafCount, 15)
        XCTAssertEqual(series.childCount, 2)
        let track = try decode(bridge.map(["Id": "t", "Type": "Audio", "Name": "Song", "Album": "LP", "AlbumId": "a",
                                           "AlbumPrimaryImageTag": "x", "AlbumArtist": "Band", "NormalizationGain": -6.5,
                                           "HasLyrics": true,
                                           "MediaSources": [["Id": "t", "Container": "flac", "MediaStreams": [["Type": "Audio", "Index": 0, "Codec": "flac"]]]]]))
        XCTAssertEqual(track.kind, .track)
        XCTAssertEqual(track.parentThumb, "/Items/a/Images/Primary")
        XCTAssertEqual(track.grandparentTitle, "Band")
        XCTAssertEqual(track.primaryPart?.key, "/Audio/t/stream.flac?static=true&mediaSourceId=t")
        XCTAssertEqual(track.primaryPart?.audioStreams.first?.gain, -6.5)
        XCTAssertEqual(track.primaryPart?.streams.first { $0.streamType == 4 }?.key, "/jellyfin/lyrics/t")
        let playlist = try decode(bridge.map(["Id": "pl", "Type": "Playlist", "Name": "Mix", "MediaType": "Audio", "ChildCount": 3]))
        XCTAssertEqual(playlist.kind, .playlist)
        XCTAssertEqual(playlist.playlistType, "audio")
        XCTAssertEqual(playlist.key, "/playlists/pl/items")
        let trailer = try decode(bridge.map(["Id": "x", "Type": "Clip", "Name": "Trailer", "ExtraType": "Trailer"]))
        XCTAssertEqual(trailer.kind, .clip)
        XCTAssertEqual(trailer.subtype, "trailer")
    }

    func testJellyfinURLsCarryItsToken() {
        let api = jellyfinAPI()
        XCTAssertTrue(api.isJellyfin)
        let stream = PlaybackDecider.directURL(api: api, item: try! decode(JellyfinBridge(api: api).map(jellyfinEpisode)))!
        let items = URLComponents(url: stream, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ApiKey" }?.value, "TOKEN")
        XCTAssertFalse(items.contains { $0.name.hasPrefix("X-Plex") }, "Plex's client details are left off")
        let art = api.imageURL("/Items/ep1/Images/Primary", width: 300, height: 450)!.absoluteString
        XCTAssertTrue(art.hasPrefix("http://jf.local:8096/Items/ep1/Images/Primary?"))
        XCTAssertTrue(art.contains("maxWidth=300") && art.contains("ApiKey=TOKEN"))
        let plex = PlexServerAPI(baseURL: URL(string: "http://plex:32400")!, token: "P", serverID: "machine")
        XCTAssertFalse(plex.isJellyfin)
        XCTAssertTrue(plex.imageURL("/library/metadata/1/thumb", width: 10, height: 10)!.absoluteString.contains("/photo/:/transcode"))
    }

    func testJellyfinTranscodeUsesChosenVersionAndAudio() throws {
        let api = jellyfinAPI()
        let item = try decode(JellyfinBridge(api: api).map(jellyfinEpisode))
        MediaVersionChoice.shared.choose(item.media[1], of: item)
        defer { MediaVersionChoice.shared.choose(item.media[0], of: item) }
        let url = PlaybackDecider.transcodeURL(api: api, item: item, quality: .q4, sessionID: "S", isLocal: true,
                                               burnSubtitleID: item.media[1].parts[0].subtitleStreams.last?.id)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(comps.path, "/Videos/ep1/master.m3u8")
        XCTAssertEqual(q["MediaSourceId"], "src1080")
        XCTAssertEqual(q["AudioStreamIndex"], "1")
        XCTAssertEqual(q["SubtitleStreamIndex"], "3")
        XCTAssertEqual(q["SubtitleMethod"], "Encode")
        XCTAssertEqual(q["MaxStreamingBitrate"], "4000000")
        XCTAssertEqual(q["MaxHeight"], "720")
        XCTAssertEqual(q["ApiKey"], "TOKEN")
    }

    func testPlaylistURIsBecomeJellyfinIDs() throws {
        let item = try decode(["ratingKey": "a1b2", "type": "track", "title": "x"])
        let query = try PlaylistCreation.query(title: "Mix", items: [item], machineIdentifier: "jellyfin", opaqueIDs: true)
        XCTAssertEqual(JellyfinBridge.itemIDs(fromURI: query.first { $0.name == "uri" }?.value), ["a1b2"])
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Mix", items: [item], machineIdentifier: "m"),
                             "Plex still needs numeric IDs")
    }

    func testJellyfinServersSurviveAPlexAccountChange() {
        var jf = PlexServer(name: "JF", clientIdentifier: JellyfinBridge.idPrefix + "1", accessToken: "t", owned: true,
                            connections: [PlexConnection(uri: "http://jf:8096", local: true, relay: false)], isManual: true)
        jf.jellyfinUserID = "u"
        let manualPlex = PlexServer(name: "Manual", clientIdentifier: "m", accessToken: "x", owned: true, connections: [], isManual: true)
        let directory = ServerDirectory(inMemoryServers: [jf, manualPlex])
        directory.replaceSessionServers([PlexServer(name: "New", clientIdentifier: "n", accessToken: "y", owned: true, connections: [], isManual: false)])
        XCTAssertEqual(Set(directory.servers.map(\.id)), ["n", jf.id])
        XCTAssertEqual(directory.server(id: jf.id)?.jellyfinUserID, "u")
        XCTAssertTrue(jf.isJellyfin)
        let encoded = try! JSONDecoder().decode(PlexServer.self, from: JSONEncoder().encode(jf))
        XCTAssertEqual(encoded.jellyfinUserID, "u")
    }

    func testJellyfinServerShowsItsOwnUserNotPlexProfiles() {
        var jf = PlexServer(name: "JF", clientIdentifier: JellyfinBridge.idPrefix + "x", accessToken: "t", owned: true,
                            connections: [], isManual: true)
        jf.jellyfinUserName = "tester"
        let plex = PlexServer(name: "Plex", clientIdentifier: "plex-1", accessToken: "p", owned: true, connections: [], isManual: false)
        let app = AppState()
        app.setForTesting(servers: [plex, jf], selected: jf.id, status: .connected)
        XCTAssertEqual(app.jellyfinUser, "tester")
        XCTAssertEqual(app.profileName, "tester")
        XCTAssertNil(app.profileThumb)
        XCTAssertFalse(app.canSwitchUsers)
        XCTAssertEqual(jf.kindLabel(local: true), "Jellyfin · Local")
        XCTAssertEqual(plex.kindLabel(local: false), "Plex · Remote")
        XCTAssertEqual(plex.kindLabel(local: nil), "Plex")
        app.setForTesting(servers: [plex, jf], selected: plex.id, status: .connected)
        XCTAssertNil(app.jellyfinUser)
    }

    // MARK: Versions

    /// Rating keys are only unique within a server: a choice on one isn't another's.
    func testVersionChoiceIsKeptPerServer() throws {
        let json: [String: Any] = ["ratingKey": "v-test-2", "type": "movie", "title": "M", "Media": [
            ["id": 21, "Part": [["id": 1, "key": "/a"]]], ["id": 22, "Part": [["id": 2, "key": "/b"]]],
        ]]
        let saved = MediaVersionChoice.serverID
        defer { MediaVersionChoice.serverID = saved }
        let item = try decode(json)
        MediaVersionChoice.serverID = "server-A"
        MediaVersionChoice.shared.choose(item.media[1], of: item)
        defer { MediaVersionChoice.serverID = "server-A"; MediaVersionChoice.shared.choose(item.media[0], of: item) }
        XCTAssertEqual(try decode(json).primaryMediaIndex, 1)
        MediaVersionChoice.serverID = "server-B"
        XCTAssertEqual(try decode(json).primaryMediaIndex, 0, "the same key on another server keeps its first version")
        MediaVersionChoice.shared.choose(item.media[0], of: item)
        MediaVersionChoice.serverID = "server-A"
        XCTAssertEqual(try decode(json).primaryMediaIndex, 1, "and choosing there doesn't erase server A's choice")
    }

    func testVersionChoiceIsRememberedPerTitle() throws {
        let json: [String: Any] = ["ratingKey": "v-test-1", "type": "movie", "title": "M", "Media": [
            ["id": 11, "videoResolution": "4k", "Part": [["id": 1, "key": "/a"]]],
            ["id": 12, "videoResolution": "1080", "Part": [["id": 2, "key": "/b"]]],
        ]]
        let item = try decode(json)
        XCTAssertEqual(item.primaryMediaIndex, 0)
        MediaVersionChoice.shared.choose(item.media[1], of: item)
        XCTAssertEqual(try decode(json).primaryMediaIndex, 1, "A fresh copy from the server keeps the choice")
        XCTAssertEqual(try decode(json).primaryPart?.key, "/b")
        MediaVersionChoice.shared.choose(item.media[0], of: item)
        XCTAssertNil(MediaVersionChoice.mediaID(for: "v-test-1"), "Choosing the first version clears the choice")
        let url = PlaybackDecider.transcodeURL(api: PlexServerAPI(baseURL: URL(string: "http://p:32400")!, token: "t", serverID: "s"),
                                               item: item, quality: .original, sessionID: "x", isLocal: true)
        XCTAssertTrue(url.absoluteString.contains("mediaIndex=0"))
    }

    func testPlaybackVersionSurvivesServerAndPreferenceChanges() throws {
        let item = try decode(["ratingKey": "frozen-version", "type": "movie", "title": "M", "Media": [
            ["id": 41, "Part": [["id": 1, "key": "/a"]]], ["id": 42, "Part": [["id": 2, "key": "/b"]]],
        ]])
        let previous = MediaVersionChoice.serverID
        MediaVersionChoice.serverID = "frozen-A"
        defer {
            MediaVersionChoice.serverID = "frozen-A"
            MediaVersionChoice.shared.choose(item.media[0], of: item)
            MediaVersionChoice.serverID = previous
        }
        MediaVersionChoice.shared.choose(item.media[1], of: item)
        let requestItem = item.forPlayback(serverID: "frozen-A")
        MediaVersionChoice.shared.choose(item.media[0], of: item)
        MediaVersionChoice.serverID = "frozen-B"
        XCTAssertEqual(requestItem.primaryMediaIndex, 1)
        XCTAssertEqual(item.usingPlaybackVersion(of: requestItem).primaryPart?.key, "/b")
        XCTAssertEqual(item.primaryMediaIndex, 0)
    }

    // MARK: Ratings

    func testScoresFromPlexRatings() throws {
        let item = try decode(["ratingKey": "1", "type": "movie", "title": "M", "Rating": [
            ["image": "imdb://image.rating", "value": 7.8, "type": "audience"],
            ["image": "rottentomatoes://image.rating.ripe", "value": 9.1, "type": "critic"],
            ["image": "rottentomatoes://image.rating.spilled", "value": 4.2, "type": "audience"],
            ["image": "themoviedb://image.rating", "value": 7.5, "type": "audience"],
        ]])
        let scores = item.externalScores
        XCTAssertEqual(scores.map(\.site), [.imdb, .tomatoes, .tomatoesAudience, .tmdb])
        XCTAssertEqual(scores.map(\.text), ["7.8", "91%", "42%", "75%"])
        XCTAssertEqual(scores.map(\.positive), [true, true, false, true])
        let older = try decode(["ratingKey": "2", "type": "movie", "title": "M", "rating": 3.0,
                                "ratingImage": "rottentomatoes://image.rating.rotten"])
        XCTAssertEqual(older.externalScores.first?.text, "30%")
        XCTAssertEqual(older.externalScores.first?.positive, false)
    }

    // MARK: Scrub previews

    func testBIFFramesAreFound() {
        var data = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        data += u32(0) + u32(2) + u32(10_000)
        data += [UInt8](repeating: 0, count: 64 - data.count)
        let first = 64 + 3 * 8
        data += u32(0) + u32(first) + u32(1) + u32(first + 3) + u32(0xffff_ffff) + u32(first + 5)
        data += [1, 2, 3, 4, 5]
        let frames = ScrubPreviews.parseBIF(data)
        XCTAssertEqual(frames?.map(\.ms), [0, 10_000])
        XCTAssertEqual(frames?.map(\.range), [first..<first + 3, first + 3..<first + 5])
        XCTAssertNil(ScrubPreviews.parseBIF(Data("not a bif file at all, just some text padding it out".utf8)))
    }

    func testTrickplayDetailsFromJellyfin() throws {
        var json = jellyfinEpisode
        json["Trickplay"] = ["src4k": ["320": ["Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10,
                                                "ThumbnailCount": 157, "Interval": 10000]]]
        let part = try XCTUnwrap(decode(JellyfinBridge(api: jellyfinAPI()).map(json)).media.first?.parts.first)
        let t = try XCTUnwrap(part.indexes.flatMap(ScrubPreviews.Trickplay.init(indexes:)))
        XCTAssertEqual(t.width, 320)
        XCTAssertEqual(t.perTile, 100)
        XCTAssertEqual(t.count, 157)
        XCTAssertEqual(t.sourceID, "src4k")
    }

    // MARK: Settings backup

    func testSettingsBackupLeavesOutSessionDetails() throws {
        let defaults = UserDefaults(suiteName: "PlezyParityTests")!
        defaults.removePersistentDomain(forName: "PlezyParityTests")
        defaults.set("server-1", forKey: "selectedServerID")
        defaults.set("abc", forKey: "plexTokenBackup")
        defaults.set(true, forKey: "playback.music.soundCheck")
        defaults.set(Data([1, 2, 3]), forKey: "favorites.1:x6:server")
        let data = try SettingsTransfer.export(defaults: defaults, domainName: "PlezyParityTests")
        let restored = UserDefaults(suiteName: "PlezyParityTests.restore")!
        restored.removePersistentDomain(forName: "PlezyParityTests.restore")
        try SettingsTransfer.restore(data, defaults: restored)
        XCTAssertEqual(restored.object(forKey: "playback.music.soundCheck") as? Bool, true)
        XCTAssertEqual(restored.data(forKey: "favorites.1:x6:server"), Data([1, 2, 3]))
        XCTAssertNil(restored.object(forKey: "selectedServerID"))
        XCTAssertNil(restored.object(forKey: "plexTokenBackup"))
        XCTAssertThrowsError(try SettingsTransfer.restore(try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0),
                                                          defaults: restored))
    }

    // MARK: Smart Downloads

    func testSmartDownloadRulesSavedBeforeSpecialsStillLoad() throws {
        let old = #"{"serverID":"s","showRatingKey":"1","showTitle":"Show","keepCount":3,"deleteWatched":true}"#
        let rule = try JSONDecoder().decode(SmartDownloadRule.self, from: Data(old.utf8))
        XCTAssertFalse(rule.includesSpecials)
        var on = rule
        on.includeSpecials = true
        XCTAssertTrue(try JSONDecoder().decode(SmartDownloadRule.self, from: JSONEncoder().encode(on)).includesSpecials)
    }

    func testAudioSyncLabels() {
        XCTAssertEqual(AudioSyncLabel.text(0), "Off")
        XCTAssertEqual(AudioSyncLabel.text(150), "+150 ms")
        XCTAssertEqual(AudioSyncLabel.text(-50), "−50 ms")
        XCTAssertEqual(PlaybackSpeeds.video.first, 0.25)
        XCTAssertEqual(PlaybackSpeeds.video.last, 4)
    }
}
