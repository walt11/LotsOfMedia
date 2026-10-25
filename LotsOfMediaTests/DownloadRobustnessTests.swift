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

final class JellyfinProgressOwnerTests: XCTestCase {
    /// Offline progress on a Jellyfin download belongs to the Jellyfin user who played it: another
    /// user signing in to the same server (same Plex profile) doesn't see it or sync it.
    func testProgressStaysWithTheJellyfinUser() {
        let id = JellyfinBridge.idPrefix + "owner-test"
        var server = PlexServer(name: "JF", clientIdentifier: id, accessToken: "a", owned: true, connections: [], isManual: false)
        server.jellyfinUserID = "userA"
        ServerDirectory.shared.upsert(server)
        defer { ServerDirectory.shared.remove(id: id) }
        let meta = try! JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"T"}"#.utf8))
        var rec = DownloadRecord(serverID: id, metadata: meta, quality: .original)
        rec.updateProgress(userID: "plexProfile", positionMs: 60_000, durationMs: 600_000)
        XCTAssertEqual(rec.progress(for: "plexProfile")?.pending, true)

        server.jellyfinUserID = "userB"
        ServerDirectory.shared.upsert(server)
        XCTAssertNil(rec.progress(for: "plexProfile"), "user B doesn't get user A's progress")

        server.jellyfinUserID = "userA"
        ServerDirectory.shared.upsert(server)
        XCTAssertEqual(rec.progress(for: "plexProfile")?.offset, 60_000, "it's still there for user A")
    }
}

final class CapturedDownloadOwnerTests: XCTestCase {
    func testLatePlaybackProgressRemainsWithCapturedJellyfinOwner() throws {
        let id = "jellyfin:captured-owner-test"
        var server = PlexServer(name: "JF", clientIdentifier: id, accessToken: "a", owned: true, connections: [], isManual: false)
        server.jellyfinUserID = "A"
        ServerDirectory.shared.upsert(server)
        defer { ServerDirectory.shared.remove(id: id) }
        let owner = DownloadRecord.playbackUserID(serverID: id, plexUserID: "plex")
        let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"T"}"#.utf8))
        var record = DownloadRecord(serverID: id, metadata: metadata, quality: .original)
        server.jellyfinUserID = "B"
        server.accessToken = "b"
        ServerDirectory.shared.upsert(server)
        record.updateProgress(userID: owner, positionMs: 50_000, durationMs: 600_000)
        XCTAssertNil(record.progress(for: "plex"))
        XCTAssertEqual(record.progress(for: owner)?.offset, 50_000)
        let progress = try XCTUnwrap(record.progress(for: owner))
        record.acknowledgeProgress(ownerKey: record.ownerKey(owner), revision: progress.revision)
        XCTAssertEqual(record.progress(for: owner)?.pending, false)
        XCTAssertNil(record.progress(for: "plex"))
    }
}
