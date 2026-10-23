import XCTest
@testable import LotsOfMedia

/// LotsOfMedia Pro: what's locked without it, and what stays free.
@MainActor
final class ProStoreTests: XCTestCase {
    private var savedCache: Any?
    override func setUp() {
        savedCache = UserDefaults.standard.object(forKey: ProStore.cacheKey)
        UserDefaults.standard.set(false, forKey: ProStore.cacheKey)
        ProStore.unlockedForTesting = false
        ProStore.showsPaywall = false
    }
    override func tearDown() {
        ProStore.showsPaywall = true
        ProStore.unlockedForTesting = false
        if let savedCache { UserDefaults.standard.set(savedCache, forKey: ProStore.cacheKey) }
        else { UserDefaults.standard.removeObject(forKey: ProStore.cacheKey) }
    }

    func testBuiltInPlayerNeedsPro() {
        XCTAssertFalse(ProStore.isUnlocked)
        XCTAssertFalse(BuiltInPlayer.isEnabled, "Without Pro the server converts other formats")
        ProStore.unlockedForTesting = true
        let saved = UserDefaults.standard.object(forKey: BuiltInPlayer.preferenceKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: BuiltInPlayer.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: BuiltInPlayer.preferenceKey) }
        }
        UserDefaults.standard.removeObject(forKey: BuiltInPlayer.preferenceKey)
        XCTAssertTrue(BuiltInPlayer.isEnabled, "On by default with Pro")
    }

    func testCachedPurchaseUnlocksWithoutTheStore() {
        UserDefaults.standard.set(true, forKey: ProStore.cacheKey)
        XCTAssertTrue(ProStore.isUnlocked, "Offline launches, CarPlay and Siri trust the last known state")
    }

    func testDownloadsNeedPro() {
        let manager = DownloadManager.shared
        let before = manager.records.count
        let movie = try! JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"pro-test","type":"movie","title":"Locked"}"#.utf8))
        manager.enqueue([movie], serverID: "pro-test-server")
        XCTAssertEqual(manager.records.count, before, "Nothing is queued without Pro")
        XCTAssertFalse(ProStore.require(.downloads))
    }

    func testEveryFeatureIsDescribed() {
        for f in ProFeature.allCases {
            XCTAssertFalse(f.title.isEmpty); XCTAssertFalse(f.detail.isEmpty)
            XCTAssertNotNil(UIImage(systemName: f.systemImage), "Missing symbol \(f.systemImage)")
        }
        XCTAssertEqual(ProStore.productID, "net.jwalter.LotsOfMedia.pro")
    }
}
