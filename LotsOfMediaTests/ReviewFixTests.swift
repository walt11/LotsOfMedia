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

    func testHEVCCanBeLeftOutOfTheStreamingProfile() throws {
        let video = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"M"}"#.utf8))
        let api = PlexServerAPI(baseURL: URL(string: "https://example.com")!, token: nil, serverID: "s")
        func profile(_ allow: Bool) -> String {
            let url = PlaybackDecider.transcodeURL(api: api, item: video, quality: .original, sessionID: "t", isLocal: true, allowHEVC: allow)
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value ?? ""
        }
        XCTAssertTrue(profile(true).contains("videoCodec=h264,hevc"))
        XCTAssertTrue(profile(false).contains("videoCodec=h264&"))
    }
}
