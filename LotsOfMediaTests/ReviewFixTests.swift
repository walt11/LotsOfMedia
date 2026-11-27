import XCTest
@testable import LotsOfMedia

/// Fixes from the October 21 review: local-address detection, subtitle parsing, HEVC retry.
final class ReviewFixTests: XCTestCase {
    private func local(_ s: String) -> Bool { AppState.looksLocal(URL(string: s)!) }

    @MainActor func testLocalAddressesAreOnlyPrivateRanges() {
        XCTAssertTrue(local("http://192.168.1.5:32400"))
        XCTAssertTrue(local("http://10.0.0.2:32400"))
        XCTAssertTrue(local("http://172.20.1.1:32400"))
        XCTAssertTrue(local("http://100.101.102.103:32400"))   // Tailscale
        XCTAssertTrue(local("http://nas.local:32400"))
        XCTAssertTrue(local("https://192-168-1-5.abcdef.plex.direct:32400"))
        XCTAssertTrue(local("http://[fd12:3456::1]:32400"))
        XCTAssertFalse(local("http://172.217.0.1:32400"))      // public 172.x
        XCTAssertFalse(local("https://81-2-3-4.abcdef.plex.direct:32400"))
        XCTAssertFalse(local("https://example.com:32400"))
        XCTAssertFalse(local("http://[2001:db8::1]:32400"))
    }

    func testOverlappingCuesAreShownTogether() {
        let srt = """
        1
        00:00:01,000 --> 00:00:05,000
        First speaker

        2
        00:00:02,000 --> 00:00:04,000
        Second speaker
        \u{20}
        3
        00:00:06,000 --> 00:00:07,000
        After a blank line with a space
        """
        let cues = SubtitleParser.parse(Data(srt.utf8))
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(SubtitleParser.cue(at: 1.5, in: cues)?.text, "First speaker")
        XCTAssertEqual(SubtitleParser.cue(at: 3, in: cues)?.text, "First speaker\nSecond speaker")
        XCTAssertEqual(SubtitleParser.cue(at: 6.5, in: cues)?.text, "After a blank line with a space")
        XCTAssertNil(SubtitleParser.cue(at: 5.5, in: cues))
    }

    func testPlexTransportStreamsOnlyAdvertiseH264() throws {
        let video = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"M"}"#.utf8))
        let api = PlexServerAPI(baseURL: URL(string: "https://example.com")!, token: nil, serverID: "s")
        func profile(_ allow: Bool) -> String {
            let url = PlaybackDecider.transcodeURL(api: api, item: video, quality: .original, sessionID: "t", isLocal: true, allowHEVC: allow)
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value ?? ""
        }
        XCTAssertTrue(profile(true).contains("videoCodec=h264&"))
        XCTAssertFalse(profile(true).contains("hevc"))
        XCTAssertTrue(profile(false).contains("videoCodec=h264&"))
    }

    private func codecItem(container: String, audio: String, selected: String? = nil, kind: String = "track") throws -> PlexMetadata {
        var part: [String: Any] = ["id": 1, "key": "/file"]
        if let selected { part["Stream"] = [["id": 1, "streamType": 2, "codec": selected, "selected": true]] }
        let json: [String: Any] = ["ratingKey": "1", "title": "Codec test", "type": kind,
            "Media": [["container": container, "videoCodec": "h264", "audioCodec": audio, "Part": [part]]]]
        return try JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testMusicCodecMustBeSupportedEvenInNativeContainer() throws {
        for codec in ["dts", "truehd", "vorbis", "wmapro"] {
            let item = try codecItem(container: "m4a", audio: codec)
            XCTAssertFalse(PlaybackDecider.shouldDirectPlay(item, quality: .original), codec)
        }
        for pair in [("m4a", "alac"), ("flac", "flac"), ("wav", "pcm_s24le"), ("aiff", "pcm_s16be"), ("mp3", "mp3")] {
            XCTAssertTrue(PlaybackDecider.shouldDirectPlay(try codecItem(container: pair.0, audio: pair.1), quality: .original))
        }
        XCTAssertFalse(PlaybackDecider.shouldDirectPlay(try codecItem(container: "", audio: "aac"), quality: .original))
    }

    func testSelectedAudioOverridesMediaSummary() throws {
        XCTAssertTrue(PlaybackDecider.shouldDirectPlay(try codecItem(container: "mp4", audio: "dts", selected: "aac", kind: "movie"), quality: .original))
        XCTAssertFalse(PlaybackDecider.shouldDirectPlay(try codecItem(container: "mp4", audio: "aac", selected: "dts", kind: "movie"), quality: .original))
    }

    func testJellyfinHEVCUsesFragmentedMP4AndFallbackUsesTransportStream() throws {
        let item = try codecItem(container: "mp4", audio: "aac", kind: "movie")
        let api = PlexServerAPI(baseURL: URL(string: "https://example.com")!, token: nil, serverID: JellyfinBridge.idPrefix + "test")
        for allow in [true, false] {
            let url = PlaybackDecider.transcodeURL(api: api, item: item, quality: .original, sessionID: "test", isLocal: true, allowHEVC: allow)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "SegmentContainer" }?.value, allow ? "mp4" : "ts")
            XCTAssertEqual(query.first { $0.name == "VideoCodec" }?.value, allow ? "h264,hevc" : "h264")
        }
    }
}
