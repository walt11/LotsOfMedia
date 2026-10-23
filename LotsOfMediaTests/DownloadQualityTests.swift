import XCTest
@testable import LotsOfMedia

final class DownloadQualityTests: XCTestCase {
    private func item(resolution: String?, width: Int? = nil, height: Int? = nil, bitrate: Int? = nil, type: String = "movie") -> PlexMetadata {
        var media: [String: Any] = ["id": 1, "container": "mkv", "Part": [["id": 1, "key": "/p"]]]
        if let resolution { media["videoResolution"] = resolution }
        if let width { media["width"] = width }
        if let height { media["height"] = height }
        if let bitrate { media["bitrate"] = bitrate }
        let json: [String: Any] = ["ratingKey": "1", "type": type, "title": "T", "Media": [media]]
        return try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test480pSourceOnlyOffersOriginal() {
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "480", bitrate: 1200)), [.original])
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "sd")), [.original])
    }

    func test720pSourceOffersOnlyLowerTiers() {
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "720", bitrate: 6000)), [.original, .low])
    }

    func test1080pSourceOffersLowerTiersByBitrate() {
        // High-bitrate 1080p: 1080p@10 Mbps is a real reduction in size? No – same resolution class.
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "1080", bitrate: 20000)), [.original, .medium, .low])
        // Low-bitrate 1080p (3 Mbps): 720p@4 Mbps would be bigger, so only 480p is offered.
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "1080", bitrate: 3000)), [.original, .low])
    }

    func test4KSourceOffersEverything() {
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: "4k", bitrate: 60000)), DownloadQuality.allCases)
    }

    func testWidescreenFilmCountsAs1080() {
        // 1920x800 with no resolution label is still a 1080p-class file.
        let wide = item(resolution: nil, width: 1920, height: 800, bitrate: 12000)
        XCTAssertEqual(wide.primaryMedia?.resolutionClass, 1080)
        XCTAssertFalse(DownloadQuality.high.isReduction(of: wide.primaryMedia))
    }

    func testContainersAndMusic() {
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: nil, type: "show")), DownloadQuality.allCases)
        XCTAssertEqual(DownloadQuality.choices(for: item(resolution: nil, type: "album")), [.original])
    }

    func testLegacyAutoDecodesAsOriginal() throws {
        XCTAssertEqual(try JSONDecoder().decode([DownloadQuality].self, from: Data(#"["auto","medium"]"#.utf8)), [.original, .medium])
    }

    /// With the built-in player off, files iPhone can't play are converted (see BuiltInPlayerTests for on).
    func testConversionReasons() {
        let saved = UserDefaults.standard.object(forKey: BuiltInPlayer.preferenceKey)
        BuiltInPlayer.isEnabled = false
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: BuiltInPlayer.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: BuiltInPlayer.preferenceKey) }
        }
        let mkv = item(resolution: "1080")   // helper builds an MKV
        XCTAssertEqual(PlaybackDecider.conversionReason(media: mkv.primaryMedia!, kind: .movie, quality: .original),
                       "iPhone can't play MKV files")
        let json: [String: Any] = ["ratingKey": "2", "type": "movie", "title": "T",
                                   "Media": [["id": 1, "container": "mkv", "videoCodec": "h264", "audioCodec": "dca", "Part": [["id": 1]]]]]
        let dts = try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(PlaybackDecider.conversionReason(media: dts.primaryMedia!, kind: .movie, quality: .original),
                       "iPhone can't play MKV files or DTS audio")
        let mp4: [String: Any] = ["ratingKey": "3", "type": "movie", "title": "T",
                                  "Media": [["id": 1, "container": "mp4", "videoCodec": "h264", "audioCodec": "aac", "Part": [["id": 1]]]]]
        let ok = try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: mp4))
        XCTAssertNil(PlaybackDecider.conversionReason(media: ok.primaryMedia!, kind: .movie, quality: .original))
        XCTAssertEqual(PlaybackDecider.conversionReason(media: ok.primaryMedia!, kind: .movie, quality: .medium), "Making a smaller 720p copy")
    }
}
