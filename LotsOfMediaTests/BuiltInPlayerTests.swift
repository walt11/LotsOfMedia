import XCTest
@testable import LotsOfMedia

/// Which files go to the built-in (VLC) player, and which downloads still need the server to convert them.
final class BuiltInPlayerTests: XCTestCase {
    private var saved: Any?
    override func setUp() {
        saved = UserDefaults.standard.object(forKey: BuiltInPlayer.preferenceKey)
        ProStore.unlockedForTesting = true   // the built-in player is a Pro feature
    }
    override func tearDown() {
        ProStore.unlockedForTesting = false
        if let saved { UserDefaults.standard.set(saved, forKey: BuiltInPlayer.preferenceKey) }
        else { UserDefaults.standard.removeObject(forKey: BuiltInPlayer.preferenceKey) }
    }

    private func item(container: String, video: String = "h264", audio: String = "aac", parts: Int = 1, type: String = "movie") -> PlexMetadata {
        let media: [String: Any] = ["id": 1, "container": container, "videoCodec": video, "audioCodec": audio,
                                    "Part": (1...parts).map { ["id": $0, "key": "/p\($0)"] }]
        let json: [String: Any] = ["ratingKey": "1", "type": type, "title": "T", "Media": [media]]
        return try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func record(_ item: PlexMetadata) -> DownloadRecord { DownloadRecord(serverID: "s", metadata: item, quality: .original) }

    func testOnByDefault() {
        UserDefaults.standard.removeObject(forKey: BuiltInPlayer.preferenceKey)
        XCTAssertTrue(BuiltInPlayer.isEnabled)
    }

    func testOriginalsTheBuiltInPlayerHandlesAreNotConverted() {
        BuiltInPlayer.isEnabled = true
        let mkv = item(container: "mkv", video: "mpeg2video", audio: "dca")
        let media = mkv.primaryMedia!
        XCTAssertFalse(PlaybackDecider.canPlayNatively(media: media, kind: .movie))
        XCTAssertTrue(PlaybackDecider.canPlayOnDevice(media: media, kind: .movie))
        XCTAssertFalse(record(mkv).requiresConversion(media: media, kind: .movie, quality: .original))
        XCTAssertNil(PlaybackDecider.conversionReason(media: media, kind: .movie, quality: .original))
        XCTAssertNotNil(PlaybackDecider.builtInPlayerNote(media: media, kind: .movie))
        // A smaller copy is still made by the server.
        XCTAssertTrue(record(mkv).requiresConversion(media: media, kind: .movie, quality: .low))
    }

    func testTurningItOffConvertsAgain() {
        BuiltInPlayer.isEnabled = false
        let mkv = item(container: "mkv")
        let media = mkv.primaryMedia!
        XCTAssertFalse(PlaybackDecider.canPlayOnDevice(media: media, kind: .movie))
        XCTAssertTrue(record(mkv).requiresConversion(media: media, kind: .movie, quality: .original))
        XCTAssertNotNil(PlaybackDecider.conversionReason(media: media, kind: .movie, quality: .original))
        XCTAssertNil(PlaybackDecider.builtInPlayerNote(media: media, kind: .movie))
    }

    func testMultiPartFilesAndMusicStillConvert() {
        BuiltInPlayer.isEnabled = true
        let split = item(container: "avi", parts: 2)
        XCTAssertFalse(PlaybackDecider.canPlayOnDevice(media: split.primaryMedia!, kind: .movie))
        let ogg = item(container: "ogg", video: "", audio: "vorbis", type: "track")
        XCTAssertFalse(PlaybackDecider.canPlayOnDevice(media: ogg.primaryMedia!, kind: .track))
    }

    func testNativeFilesStayWithApplesPlayer() {
        BuiltInPlayer.isEnabled = true
        let mp4 = item(container: "mp4")
        XCTAssertTrue(PlaybackDecider.canPlayNatively(media: mp4.primaryMedia!, kind: .movie))
        XCTAssertNil(PlaybackDecider.builtInPlayerNote(media: mp4.primaryMedia!, kind: .movie))
    }

    @MainActor func testStreamingRouting() {
        BuiltInPlayer.isEnabled = true
        let mkv = VideoPlayRequest(item: item(container: "mkv"), serverID: "s", startMs: 0, localURL: nil, downloadID: nil)
        let mp4 = VideoPlayRequest(item: item(container: "mp4"), serverID: "s", startMs: 0, localURL: nil, downloadID: nil)
        XCTAssertTrue(BuiltInPlayer.handles(mkv, quality: .original))
        XCTAssertFalse(BuiltInPlayer.handles(mp4, quality: .original))
        // A smaller streaming quality goes through the server instead.
        XCTAssertFalse(BuiltInPlayer.handles(mkv, quality: .q4))
        // Downloaded originals: by what the file is.
        let localMKV = VideoPlayRequest(item: item(container: "mkv"), serverID: "s", startMs: 0,
                                        localURL: URL(fileURLWithPath: "/tmp/x.mkv"), downloadID: "missing")
        XCTAssertTrue(BuiltInPlayer.handles(localMKV, quality: .q4))
        BuiltInPlayer.isEnabled = false
        XCTAssertFalse(BuiltInPlayer.handles(mkv, quality: .original))
    }
}
