import CarPlay
import XCTest
import Intents
import MediaPlayer
@testable import LotsOfMedia

/// CarPlay and Siri run without the phone UI, so they find the server on their own.
final class CarPlayTests: XCTestCase {
    private func server(_ id: String, owned: Bool) -> PlexServer {
        PlexServer(name: id, clientIdentifier: id, accessToken: "t", owned: owned, connections: [], isManual: false)
    }

    private func item(_ json: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }
    private func track(_ key: String, _ title: String = "Song", artist: String? = nil) throws -> PlexMetadata {
        try item(#"{"ratingKey":"\#(key)","type":"track","title":"\#(title)"\#(artist.map { #","grandparentTitle":"\#($0)""# } ?? "")}"#)
    }

    func testUsesSavedServerOrTheSameDefaultAsThePhone() {
        let servers = [server("shared", owned: false), server("mine", owned: true)]
        XCTAssertEqual(StandaloneServer.serverID(selected: "shared", servers: servers), "shared")
        // Never chosen by hand: the owned server, as the phone picks on launch.
        XCTAssertEqual(StandaloneServer.serverID(selected: nil, servers: servers), "mine")
        // A saved server that's gone falls back too.
        XCTAssertEqual(StandaloneServer.serverID(selected: "removed", servers: servers), "mine")
        XCTAssertNil(StandaloneServer.serverID(selected: nil, servers: []))
    }

    @MainActor func testServerChoiceIsSavedForCarPlay() {
        let key = "selectedServerID"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let app = AppState()
        app.select(serverID: "abc")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "abc")
    }

    // MARK: A–Z

    func testLettersUseTheSortTitle() throws {
        let items = try [
            item(#"{"ratingKey":"1","type":"track","title":"2 Step"}"#),
            item(#"{"ratingKey":"2","type":"track","title":"(Amazing Love) You Are My King","titleSort":"Amazing Love You Are My King"}"#),
            item(#"{"ratingKey":"3","type":"track","title":"Alive Again"}"#),
            item(#"{"ratingKey":"4","type":"track","title":"The Climb","titleSort":"Climb"}"#),
            item(#"{"ratingKey":"5","type":"track","title":"Éternal"}"#),
        ]
        let groups = CarPlayAlphabet.groups(items)
        XCTAssertEqual(groups.map(\.letter), ["#", "A", "C", "E"])
        XCTAssertEqual(groups[1].items.map(\.ratingKey), ["2", "3"])
        XCTAssertEqual(groups[2].items.map(\.ratingKey), ["4"])
    }

    // MARK: Radio

    func testRadioStartsWithTheSeedAndNeverRepeats() throws {
        let seed = try track("1")
        let similar = [try track("2"), try track("1"), try track("2"), try track("3"), try item(#"{"ratingKey":"9","type":"album","title":"A"}"#)]
        XCTAssertEqual(MusicRadio.assemble(seed: seed, similar: similar).map(\.ratingKey), ["1", "2", "3"])
        let many = try (2...200).map { try track("\($0)") }
        XCTAssertEqual(MusicRadio.assemble(seed: seed, similar: many).count, MusicRadio.length)
    }

    func testRadioMixesInTheArtistEveryThirdSong() throws {
        let artist = try (1...3).map { try track("a\($0)") }
        let others = try (1...6).map { try track("o\($0)") }
        XCTAssertEqual(MusicRadio.interleave(artist, others).map(\.ratingKey),
                       ["o1", "o2", "a1", "o3", "o4", "a2", "o5", "o6", "a3"])
    }

    func testGenreFilterDecodes() throws {
        let album = try item(#"{"ratingKey":"5","type":"album","title":"A","Genre":[{"tag":"Rock","filter":"genre=27"}]}"#)
        XCTAssertEqual(album.genres.first?.filter, "genre=27")
    }

    // MARK: Siri

    func testSiriPicksTheBestMatch() throws {
        let playlist = try item(#"{"ratingKey":"p","type":"playlist","title":"Road Trip","playlistType":"audio"}"#)
        let album = try item(#"{"ratingKey":"al","type":"album","title":"Road Trip Songs","parentTitle":"Band"}"#)
        let song = try track("s", "Road Trip", artist: "Someone")
        let other = try track("o", "Holiday Road", artist: "Lindsey")
        let all = [album, song, playlist, other]

        // Exact titles beat partial ones; with no kind given, a playlist wins the tie.
        XCTAssertEqual(SiriMedia.best(for: "road trip", artist: nil, wanted: nil, in: all)?.ratingKey, "p")
        // "Play the song Road Trip"
        XCTAssertEqual(SiriMedia.best(for: "Road Trip", artist: nil, wanted: .track, in: all)?.ratingKey, "s")
        // Ignores case, accents and punctuation.
        XCTAssertEqual(SiriMedia.best(for: "ROAD-TRÍP!", artist: nil, wanted: .playlist, in: all)?.ratingKey, "p")
        XCTAssertNil(SiriMedia.best(for: "Jazz Classics", artist: nil, wanted: nil, in: all))
    }

    func testSiriArtistNarrowsSongs() throws {
        let a = try track("a", "Home", artist: "Phillip Phillips")
        let b = try track("b", "Home", artist: "Michael Bublé")
        XCTAssertEqual(SiriMedia.best(for: "Home", artist: "Michael Buble", wanted: .track, in: [a, b])?.ratingKey, "b")
    }

    func testSiriKindFromTheRequest() {
        XCTAssertEqual(SiriMedia.kind(for: .playlist, search: nil), .playlist)
        XCTAssertEqual(SiriMedia.kind(for: .song, search: nil), .track)
        // "Play Holly Starr" arrives as an artist name only.
        let artistOnly = INMediaSearch(mediaType: .unknown, sortOrder: .unknown, mediaName: nil, artistName: "Holly Starr",
                                       albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil)
        XCTAssertEqual(SiriMedia.kind(for: .unknown, search: artistOnly), .artist)
        XCTAssertNil(SiriMedia.kind(for: .unknown, search: nil))
    }
}

/// CarPlay Home's album tiles and playlist details.
final class CarPlayHomeTests: XCTestCase {
    private func meta(_ j: [String: Any]) throws -> PlexMetadata {
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [j]]])
        return try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
    }

    @MainActor func testRecentlyPlayedAlbumsAreUniqueAndInOrder() throws {
        let songs = try [
            meta(["ratingKey": "1", "type": "track", "title": "A", "parentRatingKey": "10", "parentTitle": "First Album", "grandparentTitle": "Band", "parentThumb": "/a.jpg"]),
            meta(["ratingKey": "2", "type": "track", "title": "B", "parentRatingKey": "20", "parentTitle": "Second Album"]),
            meta(["ratingKey": "3", "type": "track", "title": "C", "parentRatingKey": "10", "parentTitle": "First Album"]),
        ]
        let albums = CarPlayController.albums(of: songs)
        XCTAssertEqual(albums.map(\.ratingKey), ["10", "20"])
        XCTAssertEqual(albums.first?.title, "First Album")
        XCTAssertEqual(albums.first?.parentTitle, "Band")
        XCTAssertEqual(albums.first?.thumb, "/a.jpg")
        XCTAssertEqual(albums.first?.kind, .album)
    }

    @MainActor func testPlaylistDetailShowsCountAndLength() throws {
        XCTAssertEqual(CarPlayController.playlistDetail(try meta(["ratingKey": "p", "type": "playlist", "title": "Road Trip", "leafCount": 24, "duration": 5_520_000])),
                       "24 songs · 1 hr 32 min")
        XCTAssertEqual(CarPlayController.playlistDetail(try meta(["ratingKey": "p", "type": "playlist", "title": "One", "leafCount": 1, "duration": 200_000])),
                       "1 song · 3 min")
        XCTAssertNil(CarPlayController.playlistDetail(try meta(["ratingKey": "p", "type": "playlist", "title": "Empty"])))
    }
}

/// "Play HR2 in LotsOfMedia": however Siri spells what it heard.
final class SiriSpokenNameTests: XCTestCase {
    private func playlist(_ key: String, _ title: String) throws -> PlexMetadata {
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["ratingKey": key, "type": "playlist", "title": title, "playlistType": "audio"]]]])
        return try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
    }

    @MainActor func testHR2MatchesHoweverItIsHeard() throws {
        let all = try [playlist("hr2", "HR2"), playlist("hr", "HR Mix"), playlist("other", "Road Trip 2")]
        for heard in ["HR2", "hr2", "HR 2", "H R 2", "H.R. 2", "HR two", "h r two"] {
            XCTAssertEqual(SiriMedia.best(for: heard, artist: nil, wanted: .playlist, in: all)?.ratingKey, "hr2", "Heard as “\(heard)”")
        }
    }

    func testCompactForm() {
        XCTAssertEqual(SiriMedia.compact("H.R. Two"), "hr2")
        XCTAssertEqual(SiriMedia.compact("Road Trip 2"), "roadtrip2")
    }
}

/// CarPlay Home tiles carry a name (and on iOS 26 a subtitle) under each picture.
final class CarPlayTileTests: XCTestCase {
    @MainActor func testTilesHaveTitles() {
        let image = CarPlayController.symbolTile("music.note")
        let row = CarPlayController.tileRow("Recently Added", tiles: [(image, "Album One", "Artist A"), (image, "Album Two", nil)])
        if #available(iOS 26.0, *) {
            let elements = row.elements.compactMap { $0 as? CPListImageRowItemRowElement }
            XCTAssertEqual(elements.map(\.title), ["Album One", "Album Two"])
            XCTAssertEqual(elements.first?.subtitle, "Artist A")
            CarPlayController.setTileImages([image, image], in: row)
            XCTAssertEqual((row.elements.first as? CPListImageRowItemRowElement)?.title, "Album One", "Loading artwork keeps the names")
        } else if #available(iOS 17.4, *) {
            XCTAssertEqual(row.imageTitles, ["Album One", "Album Two"])
        }
    }
}

/// Seeking from CarPlay's Now Playing: the shuffle button doesn't flash, and the song being
/// scrubbed keeps playing instead of the next one starting on top of it.
final class CarPlaySeekTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var raised = false }

    private func songs(_ n: Int) throws -> [PlexMetadata] {
        let items = (1...n).map { ["ratingKey": "\($0)", "type": "track", "title": "Song \($0)", "duration": 240_000] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": items]])
        return try PlexServerAPI.decodeContainer(data).metadata
    }

    // MARK: Shuffle

    @MainActor func testShuffleAndRepeatButtonsAreReusedOnEveryRedraw() {
        let buttons = CarPlayModeButtons()
        let first = buttons.all, again = buttons.all
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first[0] is CPNowPlayingShuffleButton)
        XCTAssertTrue(first[1] is CPNowPlayingRepeatButton)
        // CarPlay re-draws a button it's handed anew, which is what made shuffle flash.
        XCTAssertTrue(first[0] === again[0], "Same shuffle button")
        XCTAssertTrue(first[1] === again[1], "Same repeat button")
    }

    @MainActor func testSeekingKeepsShuffleAndDoesNotRedrawTheButtons() throws {
        let player = AudioPlayer.shared
        defer { player.stop(); if player.shuffled { player.toggleShuffle() } }
        if player.shuffled { player.toggleShuffle() }
        player.play(try songs(6), serverID: "carplay-seek-no-network", shuffle: true)
        XCTAssertTrue(player.shuffled)
        let order = player.queue.map(\.id), song = player.current?.id

        let redrawn = Flag()
        withObservationTracking { _ = CarPlayController.buttonsKey(player) } onChange: { redrawn.raised = true }
        player.seek(to: 30)
        player.seek(to: 200)
        player.seek(to: 5)

        XCTAssertFalse(redrawn.raised, "Seeking doesn't re-draw the Now Playing buttons")
        XCTAssertTrue(player.shuffled)
        XCTAssertEqual(player.queue.map(\.id), order, "The shuffled order is untouched")
        XCTAssertEqual(player.current?.id, song)
        XCTAssertEqual(MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType, .items,
                       "CarPlay's shuffle button reads on throughout")
    }

    @MainActor func testPausingAndSeekingDoNotRedrawTheButtonsButASongChangeDoes() throws {
        let player = AudioPlayer.shared
        defer { player.stop() }
        if player.shuffled { player.toggleShuffle() }
        player.play(try songs(3), serverID: "carplay-seek-no-network")

        let redrawn = Flag()
        withObservationTracking { _ = CarPlayController.buttonsKey(player) } onChange: { redrawn.raised = true }
        player.pause()
        player.seek(to: 60)
        XCTAssertFalse(redrawn.raised, "Play state and position have their own observation")
        player.next()
        XCTAssertTrue(redrawn.raised, "A new song re-draws (the heart follows the song)")
    }

    // MARK: Playing after a seek

    @MainActor func testSeekBeforeTheSongLoadsStartsThereOnPlay() throws {
        let player = AudioPlayer.shared
        defer { player.stop() }
        if player.shuffled { player.toggleShuffle() }
        player.play(try songs(3), serverID: "carplay-seek-no-network", startAt: 1)
        player.seek(to: 42)
        XCTAssertEqual(player.currentTime, 42)
        player.resume()
        XCTAssertEqual(player.current?.track.ratingKey, "2", "Still the song that was scrubbed")
        XCTAssertEqual(player.currentTime, 42, "Playing starts from the seek, not the top")
    }

    func testCrossfadeIsSkippedWhenSeekingPastItsStart() {
        // A 4-minute song with a 6-second crossfade: the overlap starts at 3:54.
        XCTAssertEqual(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 6, playhead: 30), 234)
        XCTAssertEqual(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 6, playhead: 233.9), 234)
        // Scrubbed into the fade or beyond: no boundary, so the next song can't start early on
        // top of this one; the usual gapless change happens at the end instead.
        XCTAssertNil(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 6, playhead: 234))
        XCTAssertNil(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 6, playhead: 238))
        // The playhead isn't known yet (still seeking).
        XCTAssertNil(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 6, playhead: .nan))
    }

    func testCrossfadeNeedsItTurnedOnAndALongEnoughSong() {
        XCTAssertNil(AudioPlayer.crossfadeStart(length: 240, fadeSeconds: 0, playhead: 0))
        XCTAssertNil(AudioPlayer.crossfadeStart(length: 18, fadeSeconds: 6, playhead: 0), "Too short to overlap")
        XCTAssertNil(AudioPlayer.crossfadeStart(length: .nan, fadeSeconds: 6, playhead: 0), "Length not loaded yet")
        XCTAssertEqual(AudioPlayer.crossfadeStart(length: 19, fadeSeconds: 6, playhead: 0), 13)
    }

    func testBufferingAfterASeekStaysPlayingButHoldsTheScrubber() {
        XCTAssertTrue(AudioPlayer.countsAsPlaying(.waitingToPlayAtSpecifiedRate), "Play/pause doesn't flicker while buffering")
        XCTAssertEqual(AudioPlayer.nowPlayingRate(.waitingToPlayAtSpecifiedRate), 0, "The scrubber waits for sound")
        XCTAssertTrue(AudioPlayer.countsAsPlaying(.playing))
        XCTAssertEqual(AudioPlayer.nowPlayingRate(.playing), 1)
        XCTAssertFalse(AudioPlayer.countsAsPlaying(.paused))
        XCTAssertEqual(AudioPlayer.nowPlayingRate(.paused), 0)
    }
}
