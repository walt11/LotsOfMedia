import XCTest
import AVFoundation
@testable import LotsOfMedia

final class PlexHomeTests: XCTestCase {
    func testDecodesV2HomeUsersJSON() throws {
        let json = #"""
        {"id":1,"name":"Home","users":[
          {"id":101,"uuid":"aaa","title":"Walt","username":"walt","thumb":"https://plex.tv/users/aaa/avatar","hasPassword":true,"restricted":false,"admin":true,"guest":false,"protected":true},
          {"id":102,"uuid":"bbb","title":"Kids","thumb":"https://plex.tv/users/bbb/avatar","hasPassword":false,"restricted":true,"admin":false,"guest":false,"protected":false}
        ]}
        """#
        struct Home: Decodable { var users: [PlexHomeUser] }
        let users = try JSONDecoder().decode(Home.self, from: Data(json.utf8)).users
        XCTAssertEqual(users.map(\.uuid), ["aaa", "bbb"])
        XCTAssertTrue(users[0].isProtected && users[0].admin)
        XCTAssertTrue(users[1].restricted && !users[1].isProtected)
    }

    func testParsesLegacyXMLHomeUsers() {
        let xml = #"""
        <MediaContainer friendlyName="myPlex" size="2">
          <User id="101" uuid="aaa" title="Walt" admin="1" protected="1" restricted="0" thumb="https://plex.tv/a"/>
          <User id="102" uuid="bbb" title="Kids" admin="0" protected="0" restricted="1"/>
        </MediaContainer>
        """#
        let users = XMLAttributes.elements(named: "User", in: Data(xml.utf8)).map(PlexHomeUser.init(xml:))
        XCTAssertEqual(users.count, 2)
        XCTAssertEqual(users[0].id, 101)
        XCTAssertTrue(users[0].isProtected)
        XCTAssertTrue(users[1].restricted)
    }

    func testAuthURLHasNoForwardURLAndCarriesPIN() {
        let pin = try! JSONDecoder().decode(PlexAccount.Pin.self, from: Data(#"{"id":5,"code":"abc123"}"#.utf8))
        let url = PlexAccount.authURL(for: pin).absoluteString
        XCTAssertTrue(url.hasPrefix("https://app.plex.tv/auth#?"))
        XCTAssertTrue(url.contains("code=abc123"))
        XCTAssertTrue(url.contains("clientID="))
        XCTAssertFalse(url.contains("forwardUrl"), "app.plex.tv rejects custom-scheme forward URLs")
    }
}

final class PagingRegressionTests: XCTestCase {
    private func page(start: Int, count: Int, total: Int?) throws -> PlexContainer {
        var container: [String: Any] = ["Metadata": (start..<(start + count)).map { ["ratingKey": "\($0)", "title": "Item \($0)"] }]
        if let total { container["totalSize"] = total }
        return try JSONDecoder().decode(PlexResponse.self, from: JSONSerialization.data(withJSONObject: ["MediaContainer": container])).MediaContainer
    }

    func testPlaylistLoadsPastBothOldLimitsAndHandlesServerPageCaps() async throws {
        var starts: [Int] = []
        let items = try await PlexServerAPI.collectPages(size: 200) { start, _ in
            starts.append(start)
            return try self.page(start: start, count: min(100, 1205 - start), total: 1205)
        }
        XCTAssertEqual(items.count, 1205)
        XCTAssertEqual(items.last?.ratingKey, "1204")
        XCTAssertEqual(starts, Array(stride(from: 0, through: 1200, by: 100)))
    }

    func testPlaylistWithoutTotalStopsAtShortPage() async throws {
        var starts: [Int] = []
        let items = try await PlexServerAPI.collectPages(size: 2) { start, _ in
            starts.append(start)
            return try self.page(start: start, count: start == 0 ? 2 : 1, total: nil)
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(starts, [0, 2])
    }

    func testPrematureEmptyPlaylistPageIsAnError() async {
        do {
            _ = try await PlexServerAPI.collectPages { start, _ in try self.page(start: start, count: 0, total: 10) }
            XCTFail("Must not silently truncate")
        } catch {}
    }

    func testOldPageCompletionCannotUnlockNewFilterRequest() {
        var state = PageRequestState()
        let old = state.begin()!
        state.reset()
        let new = state.begin()!
        XCTAssertNotEqual(old, new)
        state.finish(old)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.begin())
        state.finish(new)
        XCTAssertFalse(state.isLoading)
    }
}

final class SessionCredentialRegressionTests: XCTestCase {
    private func server(_ token: String, manual: Bool = false) -> PlexServer {
        PlexServer(name: "Server", clientIdentifier: "server", accessToken: token, owned: true,
                   connections: [PlexConnection(uri: "http://example.invalid", local: true, relay: false)], isManual: manual)
    }

    func testReplacingSessionDropsPreviousManualAccessAndEndpoints() {
        let registry = ServerDirectory(inMemoryServers: [server("owner", manual: true)])
        registry.setEndpoint("http://old.invalid", for: "server")
        let oldAPI = registry.api(for: "server")!
        registry.replaceSessionServers([])
        XCTAssertFalse(registry.authorizes(oldAPI))
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(registry.api(for: "server"))
        XCTAssertNil(registry.endpointURI(for: "server"))
        registry.replaceSessionServers([server("restricted")])
        XCTAssertEqual(registry.api(for: "server")?.token, "restricted")
        XCTAssertFalse(registry.authorizes(oldAPI))
        XCTAssertTrue(registry.authorizes(registry.api(for: "server")!))
    }

    func testFailedDiscoveryNeverProducesSessionToCommit() async {
        let registry = ServerDirectory(inMemoryServers: [server("owner", manual: true)])
        var loadedUser = false
        do {
            let prepared = try await PlexAccount.prepareSession(token: "restricted", discover: { _ in
                throw URLError(.notConnectedToInternet)
            }, loadUser: { _ in
                loadedUser = true
                return PlexUser(id: 2, uuid: "restricted", username: nil, title: nil, email: nil, thumb: nil)
            })
            registry.replaceSessionServers(prepared.servers)
            XCTFail("Discovery failure must abort the transaction")
        } catch {}
        XCTAssertFalse(loadedUser)
        XCTAssertEqual(registry.api(for: "server")?.token, "owner")
    }

    func testPreparedSessionUsesOnlyNewCredentialsWithTargetUserFallback() async throws {
        let target = PlexUser(id: 2, uuid: "restricted", username: nil, title: nil, email: nil, thumb: nil)
        let prepared = try await PlexAccount.prepareSession(token: "new", fallbackUser: target, discover: { token in
            XCTAssertEqual(token, "new")
            return [self.server("new-server-token")]
        }, loadUser: { _ in throw URLError(.timedOut) })
        XCTAssertEqual(prepared.user.uuid, "restricted")
        XCTAssertEqual(prepared.token, "new")
        XCTAssertEqual(prepared.servers.first?.accessToken, "new-server-token")
    }
}

final class SearchDiscoveryTests: XCTestCase {
    func testRecentSearchesTrimDeduplicateAndKeepNewestFirst() {
        XCTAssertEqual(SearchHistory.adding("  alien  ", to: ["Alien", "Dune"]), ["alien", "Dune"])
        XCTAssertEqual(SearchHistory.adding("x", to: ["Dune"]), ["Dune"])
        let history = SearchHistory.adding("Newest", to: (0..<12).map(String.init))
        XCTAssertEqual(history.count, 8)
        XCTAssertEqual(history.first, "Newest")
    }

    func testMediaFiltersIncludeChildrenAndExcludeOtherKinds() {
        XCTAssertTrue(SearchCategory.tv.includes(.episode))
        XCTAssertTrue(SearchCategory.tv.includes(.season))
        XCTAssertFalse(SearchCategory.tv.includes(.movie))
        XCTAssertTrue(SearchCategory.music.includes(.track))
        XCTAssertTrue(SearchCategory.music.includes(.album))
        XCTAssertFalse(SearchCategory.movies.includes(.show))
        XCTAssertTrue(SearchCategory.all.includes(.photo))
    }
}

final class PlaylistCreationTests: XCTestCase {
    private func item(_ key: String, type: String = "track") throws -> PlexMetadata {
        let data = try JSONSerialization.data(withJSONObject: ["ratingKey": key, "type": type, "title": "Media"])
        return try JSONDecoder().decode(PlexMetadata.self, from: data)
    }

    func testPlaylistQueryPreservesSelectionOrderAndDeduplicates() throws {
        let query = try PlaylistCreation.query(title: "  Favorites  ", items: [item("42"), item("9"), item("42")], machineIdentifier: "server-a")
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["title"], "Favorites")
        XCTAssertEqual(fields["type"], "audio")
        XCTAssertEqual(fields["smart"], "0")
        XCTAssertEqual(fields["uri"], "server://server-a/com.plexapp.plugins.library/library/metadata/42,9")
    }

    func testEmptyNamesAndSelectionsAreRejected() throws {
        XCTAssertThrowsError(try PlaylistCreation.query(title: " \n ", items: [item("1")], machineIdentifier: "s"))
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Playlist", items: [], machineIdentifier: "s"))
    }

    func testMoviesAndEpisodesCanMixButSongsCannotMixWithVideo() throws {
        let query = try PlaylistCreation.query(title: "Watch", items: [item("1", type: "movie"), item("2", type: "episode")], machineIdentifier: "s")
        XCTAssertEqual(query.first { $0.name == "type" }?.value, "video")
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Mixed", items: [item("1"), item("2", type: "movie")], machineIdentifier: "s"))
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Albums", items: [item("1", type: "album")], machineIdentifier: "s"))
    }

    func testUnsafeIdentifiersAreRejectedBeforeNetworkMutation() throws {
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Playlist", items: [item("1,2/../3")], machineIdentifier: "s"))
        XCTAssertThrowsError(try PlaylistCreation.query(title: "Playlist", items: [item("1")], machineIdentifier: ""))
    }

    func testSpecialCharactersInTitleStayOneQueryValue() throws {
        let title = "Road & Rain + 100% #1 🎵"
        let query = try PlaylistCreation.query(title: title, items: [item("1")], machineIdentifier: "server-a")
        let api = PlexServerAPI(baseURL: URL(string: "https://example.invalid")!, token: nil, serverID: "server-a")
        let url = api.url("/playlists", query: query)
        let decoded = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(decoded.first { $0.name == "title" }?.value, title)
        XCTAssertEqual(decoded.filter { $0.name == "title" }.count, 1)
    }
}

final class MediaModeFilteringTests: XCTestCase {
    private func item(_ type: String, playlist: String? = nil) throws -> PlexMetadata {
        var data: [String: Any] = ["ratingKey": "1", "type": type, "title": "Media"]
        if let playlist { data["playlistType"] = playlist }
        return try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: data))
    }
    func testMusicModeExcludesEveryVideoAndPhotoKind() throws {
        for kind in ["artist", "album", "track"] { XCTAssertTrue(MediaMode.music.includes(try item(kind))) }
        for kind in ["movie", "show", "season", "episode", "clip", "photo", "collection"] {
            XCTAssertFalse(MediaMode.music.includes(try item(kind)))
        }
    }
    func testWatchModeExcludesMusicAndFiltersPlaylistTypes() throws {
        for kind in ["movie", "show", "season", "episode", "clip"] { XCTAssertTrue(MediaMode.watch.includes(try item(kind))) }
        for kind in ["artist", "album", "track", "photo"] { XCTAssertFalse(MediaMode.watch.includes(try item(kind))) }
        XCTAssertTrue(MediaMode.music.includes(try item("playlist", playlist: "audio")))
        XCTAssertFalse(MediaMode.watch.includes(try item("playlist", playlist: "audio")))
        XCTAssertTrue(MediaMode.watch.includes(try item("playlist", playlist: "video")))
        XCTAssertFalse(MediaMode.music.includes(try item("playlist", playlist: "video")))
        XCTAssertFalse(MediaMode.music.includes(try item("playlist")))
    }
    func testLibraryBoundaries() throws {
        for type in ["artist", "movie", "show", "photo"] {
            let section = try JSONDecoder().decode(PlexDirectory.self, from: Data("{\"key\":\"1\",\"title\":\"Library\",\"type\":\"\(type)\"}".utf8))
            XCTAssertEqual(MediaMode.music.includes(section: section), type == "artist")
            XCTAssertEqual(MediaMode.watch.includes(section: section), type == "movie" || type == "show")
        }
    }
    func testMixedHubsLoseOtherModeItemsAndEmptyRows() throws {
        let json = #"{"MediaContainer":{"Hub":[{"title":"Mixed","hubIdentifier":"mixed","Metadata":[{"ratingKey":"1","type":"track","title":"Song"},{"ratingKey":"2","type":"movie","title":"Movie"}]},{"title":"TV","hubIdentifier":"tv","Metadata":[{"ratingKey":"3","type":"episode","title":"Episode"}]}]}}"#
        let hubs = try JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8)).MediaContainer.hubs
        let music = MediaMode.music.filter(hubs)
        XCTAssertEqual(music.count, 1)
        XCTAssertEqual(music.first?.metadata.map(\.title), ["Song"])
        XCTAssertEqual(MediaMode.watch.filter(hubs).flatMap(\.metadata).map(\.title), ["Movie", "Episode"])
    }
}

@MainActor
final class MediaModeStateTests: XCTestCase {
    func testModesRestoreIndependentTabsAndPersistPreference() {
        let previous = UserDefaults.standard.string(forKey: "mediaMode")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "mediaMode") } else { UserDefaults.standard.removeObject(forKey: "mediaMode") } }
        let app = AppState()
        app.mediaMode = .watch
        app.selectedTab = .live
        app.mediaMode = .music
        XCTAssertEqual(app.selectedTab, .home)
        app.selectedTab = .search
        app.mediaMode = .watch
        XCTAssertEqual(app.selectedTab, .live)
        app.mediaMode = .music
        XCTAssertEqual(app.selectedTab, .search)
        XCTAssertEqual(AppState().mediaMode, .music)
        app.selectedTab = .live
        XCTAssertEqual(app.selectedTab, .home)
    }

    func testChangingModePreservesMusicQueue() throws {
        let previous = UserDefaults.standard.string(forKey: "mediaMode")
        let player = AudioPlayer.shared
        defer {
            player.stop()
            if let previous { UserDefaults.standard.set(previous, forKey: "mediaMode") } else { UserDefaults.standard.removeObject(forKey: "mediaMode") }
        }
        let track = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","title":"Song","type":"track"}"#.utf8))
        player.play([track, track], serverID: "mode-test-no-network")
        let ids = player.queue.map(\.id)
        let app = AppState()
        app.mediaMode = .music
        app.mediaMode = .watch
        app.mediaMode = .music
        XCTAssertEqual(player.queue.map(\.id), ids)
        XCTAssertEqual(player.index, 0)
    }
}

@MainActor
final class PlaybackFocusTests: XCTestCase {
    func testExplicitPlaybackTransfersFocusAndModeChangeDoesNot() {
        let oldMode = UserDefaults.standard.string(forKey: "mediaMode")
        defer {
            if let oldMode { UserDefaults.standard.set(oldMode, forKey: "mediaMode") }
            else { UserDefaults.standard.removeObject(forKey: "mediaMode") }
        }
        let music = AVPlayer()
        let video = AVPlayer()
        PlaybackFocus.claim(music)
        let app = AppState()
        app.mediaMode = .watch
        XCTAssertTrue(PlaybackFocus.owns(music))
        PlaybackFocus.claim(video)
        XCTAssertFalse(PlaybackFocus.owns(music))
        XCTAssertTrue(PlaybackFocus.owns(video))
        app.mediaMode = .music
        XCTAssertTrue(PlaybackFocus.owns(video))
    }
}
