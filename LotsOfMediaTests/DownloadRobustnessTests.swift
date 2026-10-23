import XCTest
@testable import LotsOfMedia

/// Failure handling found in review: full disks, unreadable records, stray folders.
final class DownloadRobustnessTests: XCTestCase {
    private func record(_ key: String) throws -> DownloadRecord {
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"\#(key)","type":"movie","title":"M\#(key)"}"#.utf8))
        return DownloadRecord(serverID: "srv", metadata: meta, quality: .original)
    }

    func testFullDiskErrorsAreStorageProblems() {
        XCTAssertEqual(SegmentPlanner.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), .storage)
        XCTAssertEqual(SegmentPlanner.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .storage)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertEqual(SegmentPlanner.classify(wrapped), .storage)
        XCTAssertEqual(SegmentPlanner.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), .other)
    }

    func testOneBadRecordDoesNotLoseTheOthers() throws {
        let good = try JSONEncoder().encode([try record("1"), try record("2")])
        var items = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [Any])
        items.insert(["id": "broken"], at: 1)   // missing every required field
        let data = try JSONSerialization.data(withJSONObject: items)
        XCTAssertEqual(DownloadStore.decodeRecords(data).map(\.metadata.ratingKey), ["1", "2"])
        XCTAssertEqual(DownloadStore.decodeRecords(good).count, 2)
        XCTAssertTrue(DownloadStore.decodeRecords(Data("not json".utf8)).isEmpty)
    }

    func testOrphanFoldersAreRemovedAndOwnedOnesKept() throws {
        let owned = "robustness_owned", orphan = "robustness_orphan"
        DownloadStore.ensureDirectory(for: owned)
        DownloadStore.ensureDirectory(for: orphan)
        defer { DownloadStore.removeFiles(for: owned); DownloadStore.removeFiles(for: orphan) }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: DownloadStore.root.path)) ?? [])
        DownloadStore.removeOrphans(keeping: existing.subtracting([orphan]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStore.directory(for: owned).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadStore.directory(for: orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStore.indexURL.path) || !existing.contains("downloads.json"),
                      "Files like the index are never touched")
    }
}

/// The Home Screen widget reads what the app saves through the shared keychain group.
final class WidgetDataTests: XCTestCase {
    func testContinueWatchingRoundTrip() {
        let saved = TopShelfSnapshot.load()
        defer { if let saved { saved.save() } else { TopShelfSnapshot.clear() } }
        TopShelfSnapshot(items: [.init(ratingKey: "42", title: "Sintel", subtitle: "8m left", imageURL: URL(string: "http://x/art.jpg"), progress: 0.4)]).save()
        let loaded = TopShelfSnapshot.load()
        XCTAssertEqual(loaded?.items.first?.title, "Sintel")
        XCTAssertEqual(loaded?.items.first?.progress, 0.4)
        XCTAssertEqual(TopShelfSnapshot.link("play", "42", server: nil).absoluteString, "lotsofmedia://play/42")
        TopShelfSnapshot.clear()
        XCTAssertNil(TopShelfSnapshot.load())
    }
}
