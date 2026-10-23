import XCTest
import AVFoundation
@testable import LotsOfMediaTV

private func meta(_ j: [String: Any]) throws -> PlexMetadata {
    let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [j]]])
    return try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
}

/// Up Next: when it appears and what it says.
final class TVUpNextTests: XCTestCase {
    func testStartsAtTheEndCredits() throws {
        let ep = try meta(["ratingKey": "1", "type": "episode", "title": "Pilot", "duration": 1_800_000,
                           "Marker": [["type": "intro", "startTimeOffset": 30_000, "endTimeOffset": 90_000],
                                      ["type": "credits", "startTimeOffset": 1_700_000, "endTimeOffset": 1_800_000]]])
        XCTAssertEqual(TVUpNext.trigger(for: ep, durationMs: 1_800_000), 1_700_000)
    }

    func testThirtySecondsBeforeTheEndWithoutCredits() throws {
        let ep = try meta(["ratingKey": "1", "type": "episode", "title": "Pilot", "duration": 90_000])
        XCTAssertEqual(TVUpNext.trigger(for: ep, durationMs: 90_000), 60_000)
        XCTAssertNil(TVUpNext.trigger(for: ep, durationMs: 45_000), "Clips under a minute get no Up Next")
    }

    func testStartsAtTheFinalCreditsNotCreditsOverTheLastScene() throws {
        let ep = try meta(["ratingKey": "1", "type": "episode", "title": "Pilot", "duration": 1_800_000,
                           "Marker": [["type": "credits", "startTimeOffset": 1_620_000, "endTimeOffset": 1_680_000],
                                      ["type": "credits", "startTimeOffset": 1_740_000, "endTimeOffset": 1_800_000, "final": true]]])
        XCTAssertEqual(TVUpNext.trigger(for: ep, durationMs: 1_800_000), 1_740_000)
        let unflagged = try meta(["ratingKey": "1", "type": "episode", "title": "Pilot", "duration": 1_800_000,
                                  "Marker": [["type": "credits", "startTimeOffset": 1_620_000, "endTimeOffset": 1_680_000],
                                             ["type": "credits", "startTimeOffset": 1_740_000, "endTimeOffset": 1_800_000]]])
        XCTAssertEqual(TVUpNext.trigger(for: unflagged, durationMs: 1_800_000), 1_740_000)
    }

    func testCountdownRunsWithPlaybackFromWhereItAppeared() {
        var c = TVUpNextCountdown()
        // Resumed (or jumped) well past the start of the credits: the full countdown, not zero.
        XCTAssertEqual(c.secondsLeft(atMs: 1_760_000), 10)
        XCTAssertEqual(c.secondsLeft(atMs: 1_761_000), 9)
        XCTAssertEqual(c.secondsLeft(atMs: 1_761_000), 9, "Paused: no time passes")
        // A skip forward doesn't use up the countdown.
        XCTAssertEqual(c.secondsLeft(atMs: 1_771_000), 9)
        for s in 1...9 { _ = c.secondsLeft(atMs: 1_771_000 + s * 1000) }
        XCTAssertEqual(c.secondsLeft(atMs: 1_780_000), 0)
        c.reset()
        XCTAssertEqual(c.secondsLeft(atMs: 1_740_000), 10)
    }

    func testLabel() throws {
        let next = try meta(["ratingKey": "2", "type": "episode", "title": "Second", "index": 2, "parentIndex": 1])
        XCTAssertEqual(TVUpNext.label(next), "S1 E2 · Second")
    }
}

/// Matching the TV's picture mode to a video.
final class TVDisplayMatchTests: XCTestCase {
    private func movie(frameRate: Double?, dovi: Bool = false, trc: String? = nil) throws -> PlexMetadata {
        var stream: [String: Any] = ["id": 1, "streamType": 1]
        if let frameRate { stream["frameRate"] = frameRate }
        if dovi { stream["DOVIPresent"] = true }
        if let trc { stream["colorTrc"] = trc }
        return try meta(["ratingKey": "m", "type": "movie", "title": "Film",
                         "Media": [["id": 1, "width": 3840, "height": 2160, "Part": [["id": 1, "Stream": [stream]]]]]])
    }

    func testNoCriteriaWithoutAFrameRate() throws {
        XCTAssertNil(TVDisplayMatch.criteria(for: try movie(frameRate: nil)))
    }

    func testCriteriaForSDRAndHDRFiles() throws {
        XCTAssertNotNil(TVDisplayMatch.criteria(for: try movie(frameRate: 23.976)))
        XCTAssertNotNil(TVDisplayMatch.criteria(for: try movie(frameRate: 23.976, dovi: true)))
        XCTAssertNotNil(TVDisplayMatch.criteria(for: try movie(frameRate: 59.94, trc: "smpte2084")))
    }
}

/// Bringing back the music queue: which position wins, and upgrading older saves.
final class TVMusicRestoreTests: XCTestCase {
    private func saved(_ id: UUID?) throws -> TVMusicPlayer.SavedQueue {
        let songs = try (1...3).map { try meta(["ratingKey": "\($0)", "type": "track", "title": "Song \($0)"]) }
        return TVMusicPlayer.SavedQueue(items: songs, index: 0, positionMs: 1_000, serverID: "s", snapshotID: id)
    }

    func testAMatchingCheckpointIsUsed() throws {
        let id = UUID()
        let plan = TVMusicPlayer.restorePlan(saved: try saved(id), checkpoint: .init(index: 2, positionMs: 42_000, snapshotID: id))
        XCTAssertEqual(plan.index, 2); XCTAssertEqual(plan.positionMs, 42_000); XCTAssertFalse(plan.rewriteQueue)
    }

    func testAnotherQueuesCheckpointIsIgnored() throws {
        let plan = TVMusicPlayer.restorePlan(saved: try saved(UUID()), checkpoint: .init(index: 2, positionMs: 42_000, snapshotID: UUID()))
        XCTAssertEqual(plan.index, 0); XCTAssertEqual(plan.positionMs, 1_000)
    }

    func testOlderSavesAreRewritten() throws {
        let plan = TVMusicPlayer.restorePlan(saved: try saved(nil), checkpoint: nil)
        XCTAssertTrue(plan.rewriteQueue, "A save without a snapshot ID is rewritten so later checkpoints match")
        XCTAssertEqual(plan.positionMs, 1_000)
    }

    func testOlderSaveFilesDecode() throws {
        let songs = [["ratingKey": "1", "type": "track", "title": "Song"]]
        let json = try JSONSerialization.data(withJSONObject: ["items": songs, "index": 0, "positionMs": 5, "serverID": "s"])
        XCTAssertNil(try JSONDecoder().decode(TVMusicPlayer.SavedQueue.self, from: json).snapshotID)
    }
}

/// Live TV's recent and last channels are kept per profile; without one they're the server's.
final class TVLiveTVProfileKeyTests: XCTestCase {
    func testRecentChannelsArePerProfile() {
        XCTAssertEqual(LiveTVStore.profileKey("live.recent.", "srv", profile: "sam"), "live.recent.srv|sam")
        XCTAssertNotEqual(LiveTVStore.profileKey("live.recent.", "srv", profile: "sam"), LiveTVStore.profileKey("live.recent.", "srv", profile: "alex"))
        XCTAssertEqual(LiveTVStore.profileKey("live.recent.", "srv", profile: nil), "live.recent.srv")
    }
}

/// Top Shelf links carry their server.
final class TVTopShelfLinkTests: XCTestCase {
    func testLinksRoundTrip() throws {
        let link = try XCTUnwrap(TopShelfSnapshot.parse(TopShelfSnapshot.link("item", "55", server: "srv")))
        XCTAssertEqual(link.action, "item"); XCTAssertEqual(link.key, "55"); XCTAssertEqual(link.server, "srv")
    }

    /// Top Shelf links name the profile whose Continue Watching they came from.
    func testTopShelfLinkCarriesProfile() throws {
        let link = try XCTUnwrap(TopShelfSnapshot.parse(TopShelfSnapshot.link("play", "7", server: "srv", user: "abc-uuid")))
        XCTAssertEqual(link.user, "abc-uuid"); XCTAssertEqual(link.server, "srv")
        XCTAssertNil(try XCTUnwrap(TopShelfSnapshot.parse(TopShelfSnapshot.link("play", "7", server: "srv"))).user)
    }

    /// The profile's name rides along for the Top Shelf heading; snapshots saved before it still load.
    func testSnapshotKeepsProfileName() throws {
        let saved = TopShelfSnapshot(items: [], serverID: "srv", userID: "abc-uuid", userName: "Sam")
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.userName, "Sam"); XCTAssertEqual(decoded.userID, "abc-uuid")
        let old = try JSONDecoder().decode(TopShelfSnapshot.self, from: Data(#"{"items":[],"serverID":"srv","userID":"abc-uuid"}"#.utf8))
        XCTAssertNil(old.userName)
    }
}

/// Back on the Live TV page, press by press: deep in the guide → the first channel (on now) →
/// the playing corner window → the tab bar (where Down reaches the filters, then the guide).
final class TVLiveBackTests: XCTestCase {
    private let nowSlot = LiveTVStore.slot(containing: Date())

    func testScrolledGuideGoesFirstToTheFirstChannel() {
        XCTAssertTrue(TVLiveBack.awayFromNow(windowStart: nowSlot, nowSlot: nowSlot, focusedRow: 6), "scrolled down")
        XCTAssertTrue(TVLiveBack.awayFromNow(windowStart: nowSlot.addingTimeInterval(1800), nowSlot: nowSlot, focusedRow: 0), "later in time")
        XCTAssertFalse(TVLiveBack.awayFromNow(windowStart: nowSlot, nowSlot: nowSlot, focusedRow: 0))
        XCTAssertEqual(TVLiveBack.step(awayFromNow: true, windowCanTakeFocus: true), .firstChannel)
        XCTAssertEqual(TVLiveBack.step(awayFromNow: true, windowCanTakeFocus: false), .firstChannel)
    }

    func testTheWindowTakesFocusOnlyWhilePlayingInTheCorner() {
        XCTAssertTrue(TVLiveBack.windowCanTakeFocus(playing: true, fullScreen: false, windowFocused: false))
        XCTAssertFalse(TVLiveBack.windowCanTakeFocus(playing: false, fullScreen: false, windowFocused: false), "nothing playing")
        XCTAssertFalse(TVLiveBack.windowCanTakeFocus(playing: true, fullScreen: true, windowFocused: false), "full screen")
        XCTAssertFalse(TVLiveBack.windowCanTakeFocus(playing: true, fullScreen: false, windowFocused: true), "already focused")
    }

    /// The whole sequence, with each press updating the state the way the page does.
    func testSequenceWithAChannelPlaying() {
        var row = 6, windowStart = nowSlot.addingTimeInterval(3600), windowFocused = false
        var route: [TVLiveBack] = []
        for _ in 0..<3 {
            let step = TVLiveBack.step(
                awayFromNow: TVLiveBack.awayFromNow(windowStart: windowStart, nowSlot: nowSlot, focusedRow: row),
                windowCanTakeFocus: TVLiveBack.windowCanTakeFocus(playing: true, fullScreen: false, windowFocused: windowFocused))
            route.append(step)
            switch step {
            case .firstChannel: row = 0; windowStart = nowSlot
            case .window: windowFocused = true
            case .tabBar: break
            }
        }
        XCTAssertEqual(route, [.firstChannel, .window, .tabBar])
    }

    func testSequenceWithNothingPlaying() {
        XCTAssertEqual(TVLiveBack.step(awayFromNow: true, windowCanTakeFocus: false), .firstChannel)
        XCTAssertEqual(TVLiveBack.step(awayFromNow: false, windowCanTakeFocus: false), .tabBar)
    }
}

/// The corner window pauses under the screen saver, and what happens when the app comes back.
@MainActor
final class TVLiveScreenSaverTests: XCTestCase {
    private var now: TVLiveNow { .shared }

    /// A channel in the corner window. With no server connection nothing is tuned, so the player
    /// just has no item; playing it still puts it into the playing state.
    private func playInCorner() throws -> AVPlayer {
        let json = try JSONSerialization.data(withJSONObject: ["id": "test-1", "vcn": "2.1", "title": "Test"])
        now.watch(try JSONDecoder().decode(LiveChannel.self, from: json), session: TVSession())
        now.isFullScreen = false
        let player = try XCTUnwrap(now.player)
        player.play()
        return player
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    override func tearDown() async throws { now.stop() }

    func testScreenSaverPausesTheCornerWindowAndAQuickReturnResumes() throws {
        let player = try playInCorner()
        XCTAssertNotEqual(player.timeControlStatus, .paused)
        post(UIApplication.willResignActiveNotification)
        XCTAssertEqual(player.timeControlStatus, .paused, "the screen saver pauses the corner window")
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertNotEqual(player.timeControlStatus, .paused, "a quick look away picks up again")
        XCTAssertNotNil(now.channel)
    }

    func testALongScreenSaverClosesTheChannel() throws {
        _ = try playInCorner()
        let start = Date()
        now.appWillResignActive(at: start)
        now.appDidBecomeActive(at: start.addingTimeInterval(20))
        XCTAssertNil(now.channel, "after longer the channel closes and the guide shows")
        XCTAssertNil(now.player)
    }

    func testFullScreenKeepsPlaying() throws {
        let player = try playInCorner()
        now.isFullScreen = true
        post(UIApplication.willResignActiveNotification)
        XCTAssertNotEqual(player.timeControlStatus, .paused, "full screen keeps the TV awake, so it isn't paused")
        post(UIApplication.didBecomeActiveNotification)
        XCTAssertNotNil(now.channel)
    }
}
