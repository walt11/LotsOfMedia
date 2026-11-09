import XCTest
@testable import LotsOfMedia

/// Runs the app's requests against a real Jellyfin server on this Mac (http://localhost:8096,
/// user "tester" / "testpass", with Movies, Shows and Music libraries, and Dashboard → Playback →
/// "Minimum resume duration" set to 0 so the short sample videos keep a resume point). Skipped
/// when there's no server.
@MainActor
final class JellyfinLiveTests: XCTestCase {
    private static let address = "http://localhost:8096"
    private var server: PlexServer!
    private var api: PlexServerAPI!

    override func setUp() async throws {
        guard let info = try? await JellyfinAuth.info(address: Self.address) else {
            throw XCTSkip("No Jellyfin server at \(Self.address)")
        }
        server = try await JellyfinAuth.signIn(info, username: "tester", password: "testpass")
        ServerDirectory.shared.upsert(server)
        api = PlexServerAPI(baseURL: URL(string: info.url)!, token: server.accessToken, serverID: server.id)
        LibraryCache.isOffline = false
    }

    override func tearDown() async throws {
        if let server { ServerDirectory.shared.remove(id: server.id) }
    }

    /// Like XCTUnwrap, without an autoclosure (so the value can come from an `await`).
    private func unwrap<T>(_ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let value else {
            XCTFail("nil " + message, file: file, line: line)
            throw XCTSkip("missing value")
        }
        return value
    }

    private func section(_ type: String) async throws -> PlexDirectory {
        try unwrap(try await api.sections().first { $0.type == type }, "no \(type) library")
    }

    private func all(_ section: PlexDirectory, _ query: [URLQueryItem] = []) async throws -> PlexContainer {
        try await api.page("/library/sections/\(section.key)/all", start: 0, size: 50, query: query)
    }

    /// Holiday picks search titles for the holiday's words (here, words in the sample library's
    /// titles), keep only real word matches, and put movies first.
    func testHolidayPicks() async throws {
        let holiday = Holiday(id: "test-\(UUID().uuidString)", rowTitle: "Test Picks", keywords: ["sample", "second", "ample"])
        let picks = await api.holidayPicks(holiday)
        let titles = Set(picks.map(\.title))
        XCTAssertTrue(titles.contains("Sample Movie"), "\(titles)")
        XCTAssertTrue(titles.contains { $0.hasPrefix("Second Movie") }, "\(titles)")
        XCTAssertTrue(picks.allSatisfy(holiday.matches), "\(titles)")
        XCTAssertEqual(picks.count, Set(picks.map(\.ratingKey)).count)
    }

    func testSignInAndConnection() async throws {
        XCTAssertTrue(server.isJellyfin)
        XCTAssertNotNil(server.jellyfinUserID)
        let ok = await ConnectionResolver.probe(uri: Self.address, timeout: 5, expectedID: server.id)
        XCTAssertTrue(ok)
        let resolved = try await ConnectionResolver.resolve(server)
        XCTAssertEqual(resolved, Self.address)
        let identity = try await api.container("/identity")
        XCTAssertEqual(identity.machineIdentifier, server.id)
        let info = try await JellyfinAuth.info(address: Self.address)
        let quick = await JellyfinAuth.quickConnectEnabled(info)
        XCTAssertTrue(quick)
        let code = try await JellyfinAuth.startQuickConnect(info)
        XCTAssertFalse(code.code.isEmpty)
        let approved = await JellyfinAuth.checkQuickConnect(info, code)
        XCTAssertFalse(approved)
    }

    func testLibrariesAndMovies() async throws {
        let sections = try await api.sections()
        XCTAssertEqual(Set(sections.compactMap(\.type)), ["movie", "show", "artist"], "\(sections.map(\.title))")
        let movies = try await section("movie")
        let page = try await all(movies)
        XCTAssertEqual(page.metadata.map { String($0.title.prefix(12)) }.sorted(), ["Sample Movie", "Second Movie"], "\(page.metadata.map(\.title))")
        XCTAssertEqual(page.totalSize, 2)
        let sorted = try await all(movies, [URLQueryItem(name: "sort", value: "addedAt:desc")])
        XCTAssertEqual(sorted.metadata.count, 2)
        let firstPage = try await api.page("/library/sections/\(movies.key)/all", start: 0, size: 1)
        XCTAssertEqual(firstPage.metadata.count, 1)
        XCTAssertEqual(firstPage.totalSize, 2)
        _ = try await api.container("/library/sections/\(movies.key)/genre")
        _ = try await api.container("/library/sections/\(movies.key)/decade")
        let unwatched = try await all(movies, [URLQueryItem(name: "unwatched", value: "1")])
        XCTAssertEqual(unwatched.metadata.count, page.metadata.filter { !$0.isWatched }.count)
        XCTAssertTrue(unwatched.metadata.allSatisfy { !$0.isWatched })
    }

    func testMovieDetailVersionsSubtitlesAndPlayback() async throws {
        let movies = try await all(try await section("movie")).metadata
        let second = try unwrap(movies.first { $0.title.hasPrefix("Second Movie") })
        let detail = try unwrap(try await api.metadata(second.ratingKey))
        XCTAssertEqual(detail.media.count, 2, "two files of one movie are two versions")
        XCTAssertEqual(Set(detail.media.compactMap(\.resolutionLabel)), ["1080p", "SD"], "\(detail.media.map(\.videoResolution))")
        XCTAssertEqual(Set(detail.media.compactMap(\.container)), ["mkv", "mp4"])

        let sample = try unwrap(movies.first { $0.title == "Sample Movie" })
        let full = try unwrap(try await api.metadata(sample.ratingKey))
        XCTAssertEqual(full.year, 2023)
        let part = try unwrap(full.primaryPart)
        let sub = try unwrap(part.subtitleStreams.first, "the .srt beside the file")
        XCTAssertTrue(sub.isSidecarText)
        let srt = String(data: try await api.subtitleFile(streamID: sub.id), encoding: .utf8) ?? ""
        XCTAssertTrue(srt.contains("Hello from a subtitle"), srt)
        XCTAssertTrue(PlaybackDecider.shouldDirectPlay(full, quality: .original))

        let direct = try unwrap(PlaybackDecider.directURL(api: api, item: full))
        var req = URLRequest(url: direct)
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (bytes, resp) = try await URLSession.shared.data(for: req)
        XCTAssertTrue([200, 206].contains((resp as? HTTPURLResponse)?.statusCode), "\(resp)")
        XCTAssertGreaterThan(bytes.count, 100)

        let hls = PlaybackDecider.transcodeURL(api: api, item: full, quality: .q2, sessionID: UUID().uuidString, isLocal: true)
        let (playlist, hlsResp) = try await URLSession.shared.data(from: hls)
        XCTAssertEqual((hlsResp as? HTTPURLResponse)?.statusCode, 200, String(data: playlist, encoding: .utf8) ?? "")
        XCTAssertTrue(String(data: playlist, encoding: .utf8)?.hasPrefix("#EXTM3U") == true)
        await api.stopTranscode(sessionID: "none")

        let art = try unwrap(api.imageURL(full.thumb ?? "/Items/\(full.ratingKey)/Images/Primary", width: 200, height: 300))
        let (_, artResp) = try await URLSession.shared.data(from: art)
        XCTAssertNotNil(artResp as? HTTPURLResponse)
    }

    func testProgressWatchedAndRating() async throws {
        let movie = try unwrap(try await all(try await section("movie")).metadata.first { $0.title == "Sample Movie" })
        let session = UUID().uuidString
        try await api.timeline(ratingKey: movie.ratingKey, key: nil, state: "playing", timeMs: 5_000, durationMs: 60_000, sessionID: session)
        try await api.timeline(ratingKey: movie.ratingKey, key: nil, state: "playing", timeMs: 20_000, durationMs: 60_000, sessionID: session)
        try await api.timeline(ratingKey: movie.ratingKey, key: nil, state: "stopped", timeMs: 21_000, durationMs: 60_000, sessionID: session)
        var fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertEqual(Double(fresh.viewOffset ?? 0), 21_000, accuracy: 1500)
        let resume = try await api.continueWatching()
        XCTAssertTrue(resume.contains { $0.ratingKey == movie.ratingKey }, "\(resume.map(\.title))")

        try await api.setProgress(ratingKey: movie.ratingKey, timeMs: 30_000)
        fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertEqual(Double(fresh.viewOffset ?? 0), 30_000, accuracy: 1500)

        try await api.scrobble(movie.ratingKey)
        fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertTrue(fresh.isWatched)
        try await api.unscrobble(movie.ratingKey)
        try await api.removeFromContinueWatching(movie.ratingKey)
        fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertFalse(fresh.isWatched)

        try await api.rate(movie.ratingKey, rating: 10)
        fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertEqual(fresh.userRating, 10)
        try await api.rate(movie.ratingKey, rating: nil)
        fresh = try unwrap(try await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(movie.ratingKey) })
        XCTAssertNil(fresh.userRating)
        let history = try await api.history(ownServer: true)
        _ = history
    }

    func testShowsSeasonsAndEpisodes() async throws {
        let shows = try await all(try await section("show")).metadata
        let show = try unwrap(shows.first, "no shows")
        XCTAssertEqual(show.kind, .show)
        XCTAssertEqual(show.leafCount, 3)
        let seasons = try await api.children(show.ratingKey)
        XCTAssertEqual(seasons.map(\.kind), [.season])
        let episodes = try await api.children(try unwrap(seasons.first).ratingKey)
        XCTAssertEqual(episodes.map(\.index), [1, 2, 3])
        XCTAssertEqual(episodes.first?.grandparentRatingKey, show.ratingKey)
        let leaves = try await api.allLeaves(show.ratingKey)
        XCTAssertEqual(leaves.count, 3)
        let later = try await api.episodes(after: try unwrap(episodes.first), limit: 5)
        XCTAssertEqual(later.map(\.index), [2, 3])
        _ = try await api.container("/library/onDeck")
        let hubs = try await api.homeHubs()
        XCTAssertTrue(hubs.contains { $0.title.hasPrefix("Recently Added") }, "\(hubs.map(\.title))")
        let sectionHubs = try await api.sectionHubs(try await section("show").key)
        XCTAssertFalse(sectionHubs.isEmpty)
        let episode = try unwrap(try await api.metadata(try unwrap(episodes.first).ratingKey))
        XCTAssertEqual(episode.grandparentTitle, show.title)
        _ = await api.related(episode.ratingKey)
        _ = await api.extras(show.ratingKey)
    }

    func testMusicPlaylistsAndSearch() async throws {
        let music = try await section("artist")
        let artists = try await all(music).metadata
        let artist = try unwrap(artists.first, "no artists")
        XCTAssertEqual(artist.kind, .artist)
        let albums = try await api.children(artist.ratingKey)
        let album = try unwrap(albums.first, "no albums")
        XCTAssertEqual(album.kind, .album)
        let tracks = try await api.children(album.ratingKey)
        XCTAssertEqual(tracks.map(\.title), ["Song 1", "Song 2"])
        XCTAssertEqual(tracks.first?.parentTitle, "Album")
        let songs = try await all(music, [URLQueryItem(name: "type", value: "10")]).metadata
        XCTAssertEqual(songs.count, 2)
        let albumList = try await all(music, [URLQueryItem(name: "type", value: "9")]).metadata
        XCTAssertEqual(albumList.map(\.kind), [.album])
        let artistTracks = try await api.allLeaves(artist.ratingKey)
        XCTAssertEqual(artistTracks.count, 2)
        let track = try unwrap(tracks.first)
        XCTAssertTrue(PlaybackDecider.canPlayNatively(media: try unwrap(track.primaryMedia), kind: .track))
        let (audio, audioResp) = try await URLSession.shared.data(from: try unwrap(PlaybackDecider.directURL(api: api, item: track)))
        XCTAssertEqual((audioResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(audio.count, 1000)

        let playlist = try await api.createPlaylist(title: "Live Test Mix", items: [track])
        try await api.addToPlaylist(playlist.ratingKey, items: [try unwrap(tracks.last)])
        let items = try await api.playlistItems(playlist.ratingKey)
        XCTAssertEqual(items.map(\.title), ["Song 1", "Song 2"])
        let lists = try await api.playlists()
        XCTAssertTrue(lists.contains { $0.ratingKey == playlist.ratingKey && $0.playlistType == "audio" })
        try await api.data("/playlists/\(playlist.ratingKey)/items/\(try unwrap(items.last?.playlistItemID))/move", method: "PUT")
        try await api.data("/playlists/\(playlist.ratingKey)/items/\(try unwrap(items.first?.playlistItemID))", method: "DELETE")
        let remaining = try await api.playlistItems(playlist.ratingKey)
        XCTAssertEqual(remaining.count, 1)
        try await api.data("/playlists/\(playlist.ratingKey)", method: "DELETE")

        let results = try await api.search("Sample")
        XCTAssertTrue(results.contains { $0.metadata.contains { $0.title == "Sample Movie" } }, "\(results.map(\.title))")
        let dvrs = try await api.liveDVRs()
        XCTAssertTrue(dvrs.isEmpty)
    }
}
