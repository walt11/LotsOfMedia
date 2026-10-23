import XCTest
import AVFoundation
import SwiftUI
import Vision
@testable import LotsOfMedia

final class MediaFeatureTests: XCTestCase {
    private func item(_ values: [String: Any]) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: values))
    }
    func testRepeatRulesDistinguishNaturalEndFromSkip() {
        XCTAssertEqual(RepeatMode.one.nextIndex(current: 1, count: 3, naturalEnd: true), 1)
        XCTAssertEqual(RepeatMode.one.nextIndex(current: 1, count: 3, naturalEnd: false), 2)
        XCTAssertNil(RepeatMode.one.nextIndex(current: 2, count: 3, naturalEnd: false))
        XCTAssertEqual(RepeatMode.all.nextIndex(current: 2, count: 3, naturalEnd: true), 0)
        XCTAssertNil(RepeatMode.off.nextIndex(current: 2, count: 3, naturalEnd: true))
        XCTAssertNil(RepeatMode.all.nextIndex(current: 0, count: 0, naturalEnd: true))
        XCTAssertNil(RepeatMode.all.nextIndex(current: -1, count: 3, naturalEnd: true))
    }
    func testASongWaitingWithoutMovingCountsAsStuck() {
        XCTAssertTrue(AudioPlayer.isStuck(from: 0, now: 0), "Never left the start")
        XCTAssertTrue(AudioPlayer.isStuck(from: 83, now: 83.2), "A blip of progress is still stuck")
        XCTAssertFalse(AudioPlayer.isStuck(from: 0, now: 4), "It played a few seconds and is just rebuffering")
        XCTAssertTrue(AudioPlayer.isStuck(from: .nan, now: .nan), "The player can't even say where it is")
    }
    func testSongSearchCombinesArtistAlbumAndTitleTokens() throws {
        let song = try item(["ratingKey": "1", "type": "track", "title": "Déjà Vu", "grandparentTitle": "The Artist", "parentTitle": "First Album"])
        XCTAssertTrue(LibrarySongFilter.matches(song, query: "DEJA artist album"))
        XCTAssertTrue(LibrarySongFilter.matches(song, query: "  \n "))
        XCTAssertFalse(LibrarySongFilter.matches(song, query: "artist missing"))
    }
    @MainActor func testFavoritesPersistAndSeparateServerProfileAndMode() throws {
        let name = "MediaFeatureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = MediaPreferences(defaults: defaults)
        let scope = MediaPreferences.scope(user: "a", server: "b")
        let song = try item(["ratingKey": "1", "type": "track", "title": "Song"])
        let movie = try item(["ratingKey": "2", "type": "movie", "title": "Movie"])
        prefs.toggle(song, scope: scope); prefs.toggle(movie, scope: scope)
        XCTAssertEqual(prefs.favorites(scope: scope, mode: .music).map(\.ratingKey), ["1"])
        XCTAssertEqual(prefs.favorites(scope: scope, mode: .watch).map(\.ratingKey), ["2"])
        XCTAssertTrue(prefs.favorites(scope: MediaPreferences.scope(user: "other", server: "b"), mode: .music).isEmpty)
        XCTAssertTrue(prefs.favorites(scope: MediaPreferences.scope(user: "a", server: "other"), mode: .music).isEmpty)
        XCTAssertTrue(MediaPreferences(defaults: defaults).isFavorite(song, scope: scope))
        prefs.toggle(song, scope: scope)
        XCTAssertFalse(prefs.isFavorite(song, scope: scope))
        XCTAssertNotEqual(MediaPreferences.scope(user: "ab", server: "c"), MediaPreferences.scope(user: "a", server: "bc"))
    }
    @MainActor func testHomeLayoutRepairsStaleSectionsAndRemainsModeSpecific() throws {
        let name = "MediaFeatureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = MediaPreferences(defaults: defaults)
        prefs.setLayout(.init(order: ["favorites", "favorites", "obsolete"], hidden: ["recent", "obsolete"]), scope: "one", mode: .music)
        let layout = prefs.layout(scope: "one", mode: .music)
        XCTAssertEqual(layout.order.first, "favorites")
        XCTAssertEqual(Set(layout.order), Set(MediaPreferences.homeSections(.music)))
        XCTAssertEqual(layout.order.count, Set(layout.order).count)
        XCTAssertEqual(layout.hidden, ["recent"])
        XCTAssertEqual(prefs.layout(scope: "one", mode: .watch).order, MediaPreferences.homeSections(.watch))
        XCTAssertEqual(prefs.layout(scope: "two", mode: .music).hidden, MediaPreferences.hiddenByDefault(.music), "A new profile starts with the calm default Home")
    }
    @MainActor func testPlaybackPreferencesKeepModesIndependent() throws {
        let name = "MediaFeatureTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = MediaPreferences(defaults: defaults)
        prefs.setCellular(false, mode: .music)
        prefs.musicBitrate = 192
        XCTAssertFalse(prefs.allowsCellular(.music))
        XCTAssertTrue(prefs.allowsCellular(.watch))
        XCTAssertEqual(prefs.videoQuality, .original)
        XCTAssertEqual(MediaPreferences(defaults: defaults).musicBitrate, 192)
    }
    func testDownloadPlanCountsUniqueFilesAndUnknownSizes() throws {
        let known = try item(["ratingKey": "1", "type": "track", "title": "Song", "Media": [["Part": [["size": 1000]]]]])
        let unknown = try item(["ratingKey": "2", "type": "track", "title": "Other"])
        let plan = DownloadPlan(items: [known, known, unknown], quality: .original)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.knownBytes, 1000)
        XCTAssertEqual(plan.unknownCount, 1)
        XCTAssertTrue(plan.sizeLabel.contains("unknown"))
        XCTAssertEqual(DownloadPlan(items: [], quality: .original).sizeLabel, "No items")
    }
    func testPlaylistOccurrenceIDsSurviveDecodingAndPersistence() throws {
        let a = try item(["ratingKey": "4", "type": "track", "title": "Same song", "playlistItemID": 10])
        let b = try item(["ratingKey": "4", "type": "track", "title": "Same song", "playlistItemID": "11"])
        XCTAssertEqual(a.ratingKey, b.ratingKey)
        XCTAssertNotEqual(a.playlistItemID, b.playlistItemID)
        XCTAssertEqual(try JSONDecoder().decode(PlexMetadata.self, from: JSONEncoder().encode(a)).playlistItemID, "10")
    }
    func testHandoffUsesCorrectMediaAndOffsetWithoutEmbeddingToken() throws {
        let song = try item(["ratingKey": "42", "type": "track", "title": "Song"])
        let query = try HandoffRequest.query(item: song, offset: -3, machine: "server", serverURL: URL(string: "https://example.com:32400")!)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["type"], "audio")
        XCTAssertEqual(values["offset"], "0")
        XCTAssertEqual(values["port"], "32400")
        XCTAssertEqual(values["uri"], "server://server/com.plexapp.plugins.library/library/metadata/42")
        XCTAssertNil(values["X-Plex-Token"])
        let bad = try item(["ratingKey": "../42", "type": "track", "title": "Bad"])
        XCTAssertThrowsError(try HandoffRequest.query(item: bad, offset: 0, machine: "s", serverURL: URL(string: "https://example.com")!))
    }
    func testHandoffRejectsProtocolErrorsInsideSuccessfulHTTP() throws {
        XCTAssertThrowsError(try HandoffRequest.validateResponse(Data(#"<Response code="500" status="Failed"/>"#.utf8)))
        XCTAssertThrowsError(try HandoffRequest.validateResponse(Data(#"{"Response":{"code":400}}"#.utf8)))
        XCTAssertNoThrow(try HandoffRequest.validateResponse(Data(#"<Response code="200" status="OK"/>"#.utf8)))
        XCTAssertNoThrow(try HandoffRequest.validateResponse(Data()))
    }
    @MainActor func testSleepEndBelongsToOnlyItsPlayerAndConsumesOnce() {
        let timer = PlaybackSleepTimer()
        let music = AVPlayer(), video = AVPlayer()
        timer.finishItem(player: music)
        XCTAssertTrue(timer.endsWithItem(for: music))
        XCTAssertFalse(timer.consumeEnd(for: video))
        XCTAssertTrue(timer.consumeEnd(for: music))
        XCTAssertFalse(timer.consumeEnd(for: music))
        timer.set(minutes: 15, player: video)
        XCTAssertFalse(timer.isSet(for: music))
        XCTAssertTrue(timer.isSet(for: video))
        XCTAssertNotNil(timer.deadline)
        timer.cancel()
        XCTAssertFalse(timer.isSet(for: video))
    }
    func testMusicBitrateForcesAudioTranscode() throws {
        let song = try item(["ratingKey": "4", "type": "track", "title": "Song"])
        let api = PlexServerAPI(baseURL: URL(string: "https://example.com")!, token: nil, serverID: "s")
        let url = PlaybackDecider.transcodeURL(api: api, item: song, quality: .original, sessionID: "test", isLocal: false, music: true, musicBitrate: 128)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["audioBitrate"], "128")
        XCTAssertEqual(query["directStreamAudio"], "0")
        XCTAssertEqual(query["directStream"], "0")
        XCTAssertEqual(url.path, "/music/:/transcode/universal/start.m3u8")
    }
}

final class PageTitleLayoutTests: XCTestCase {
    @MainActor func testPageTitlesShareOneNavigationRow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let previousMode = UserDefaults.standard.object(forKey: "mediaMode")
        let app = AppState()
        app.mediaMode = .music
        app.selectedTab = .library
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: MainTabView()
            .environment(app)
            .environment(DownloadManager.shared)
            .environment(AudioPlayer.shared)
            .environment(NetworkMonitor.shared)
            .environment(LiveTVStore.shared)
            .preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            if let previousMode { UserDefaults.standard.set(previousMode, forKey: "mediaMode") }
            else { UserDefaults.standard.removeObject(forKey: "mediaMode") }
        }
        for tab in [AppState.Tab.library, .downloads, .search] {
            app.selectedTab = tab
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            let bars = descendants(window).compactMap { $0 as? UINavigationBar }.filter { !$0.isHidden && $0.alpha > 0 }
            XCTAssertFalse(bars.isEmpty, "The navigation title and actions must remain visible")
            for bar in bars { XCTAssertLessThanOrEqual(bar.bounds.height, tab == .search ? 120 : 64, "Do not reserve an additional large-title row") }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([recognition])
            let expected = tab == .library ? "Library" : tab == .downloads ? "Downloads" : "Search"
            let headings = (recognition.results ?? []).filter { $0.topCandidates(1).first?.string == expected && $0.boundingBox.midY > 0.5 }
            XCTAssertFalse(headings.isEmpty, "The actual rendered page heading must be visible above the content")
            if let heading = headings.first, let bar = bars.first {
                let titleTop = (1 - heading.boundingBox.maxY) * window.bounds.height
                let barTop = bar.convert(bar.bounds, to: window).minY
                XCTAssertLessThan(titleTop - barTop, 24, "The heading must start in the first navigation row")
                XCTAssertLessThan(heading.boundingBox.minX * window.bounds.width, 32, "Root titles must align with the left content margin")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Listen-\(tab)-title-layout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

final class PlayerDiscoveryTests: XCTestCase {
    func testGDMReplyFromAPlayer() throws {
        let reply = "HTTP/1.0 200 OK\r\nContent-Type: plex/media-player\r\nResource-Identifier: abc123\r\nName: Living Room TV\r\nPort: 32500\r\nProduct: Plex for Apple TV\r\nProtocol-Capabilities: timeline,playback,navigation\r\n"
        let p = try XCTUnwrap(PlayerDiscovery.parseGDM(reply, from: "192.168.68.20"))
        XCTAssertEqual(p.id, "abc123")
        XCTAssertEqual(p.name, "Living Room TV")
        XCTAssertEqual(p.baseURL?.absoluteString, "http://192.168.68.20:32500")
        XCTAssertEqual(p.sources, [.network])
    }

    func testServersAndNonPlayersAreIgnored() {
        let server = "HTTP/1.0 200 OK\r\nContent-Type: plex/media-server\r\nResource-Identifier: srv\r\nName: WaltUgreen\r\nPort: 32400\r\n"
        XCTAssertNil(PlayerDiscovery.parseGDM(server, from: "192.168.68.85"))
        let remote = "HTTP/1.0 200 OK\r\nResource-Identifier: r1\r\nName: Remote\r\nProtocol-Capabilities: navigation\r\n"
        XCTAssertNil(PlayerDiscovery.parseGDM(remote, from: "192.168.68.9"))
    }

    func testPlayMediaSendsTheServerTokenAndPlayQueue() throws {
        let song = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"42","type":"track","title":"Song"}"#.utf8))
        let q = try HandoffRequest.playMediaQuery(item: song, offset: -5, machine: "srv", serverURL: URL(string: "https://example.com:32400")!,
                                                   playQueueID: 7, serverToken: "server-token")
        let d = Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(d["key"], "/library/metadata/42")
        XCTAssertEqual(d["offset"], "0")
        XCTAssertEqual(d["type"], "music")
        XCTAssertEqual(d["port"], "32400")
        XCTAssertEqual(d["containerKey"], "/playQueues/7?own=1&window=200")
        XCTAssertEqual(d["token"], "server-token")
    }
}

