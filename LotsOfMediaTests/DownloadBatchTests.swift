import XCTest
@testable import LotsOfMedia

final class DownloadBatchTests: XCTestCase {
    private func record(_ key: String, type: String, state: DownloadRecord.State, batch: String? = "b1") -> DownloadRecord {
        let json: [String: Any] = ["ratingKey": key, "type": type, "title": "Item \(key)", "grandparentTitle": "Show"]
        let m = try! JSONDecoder().decode(PlexMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        var r = DownloadRecord(serverID: "s", metadata: m, quality: .original)
        r.state = state
        r.batchID = batch
        r.batchTitle = batch == nil ? nil : "Road Trip Mix"
        return r
    }

    func testNoAnnouncementUntilWholeBatchFinishes() {
        let a = record("1", type: "track", state: .completed)
        let b = record("2", type: "track", state: .downloading)
        let c = record("3", type: "track", state: .queued)
        XCTAssertNil(DownloadManager.finishedEvent(for: a, batchMembers: [a, b, c]))
    }

    func testSingleSummaryForCompletedPlaylistUsesListen() throws {
        let members = (1...6).map { record("\($0)", type: "track", state: .completed) }
        let e = try XCTUnwrap(DownloadManager.finishedEvent(for: members[5], batchMembers: members))
        XCTAssertEqual(e.title, "Road Trip Mix · 6 songs")
        XCTAssertTrue(e.succeeded)
        XCTAssertTrue(e.isAudio)
    }

    func testSeasonSummaryReportsFailures() throws {
        let members = [record("1", type: "episode", state: .completed),
                       record("2", type: "episode", state: .completed),
                       record("3", type: "episode", state: .failed)]
        let e = try XCTUnwrap(DownloadManager.finishedEvent(for: members[2], batchMembers: members))
        XCTAssertEqual(e.title, "Road Trip Mix · 2 episodes")
        XCTAssertFalse(e.succeeded)
        XCTAssertFalse(e.isAudio)
        XCTAssertNotNil(e.message)
    }

    func testSingleDownloadStillAnnouncedImmediately() throws {
        let r = record("9", type: "track", state: .completed, batch: nil)
        let e = try XCTUnwrap(DownloadManager.finishedEvent(for: r, batchMembers: [r]))
        XCTAssertTrue(e.isAudio)
    }

    func testOldRecordsWithoutBatchFieldsStillDecode() throws {
        let r = record("1", type: "track", state: .completed, batch: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json.removeValue(forKey: "batchID"); json.removeValue(forKey: "batchTitle")
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.batchID)
    }
}
