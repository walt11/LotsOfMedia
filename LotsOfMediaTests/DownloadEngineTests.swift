import XCTest
@testable import LotsOfMedia

final class SegmentPlannerTests: XCTestCase {
    func testPlanCoversWholeFileWithoutGapsOrOverlap() {
        for total: Int64 in [1, 1000, 32 * 1024 * 1024, 32 * 1024 * 1024 + 1, 4_700_000_123, 80_000_000_000] {
            let segs = SegmentPlanner.plan(totalBytes: total)
            XCTAssertEqual(segs.first?.start, 0)
            XCTAssertEqual(segs.last?.end, total - 1)
            XCTAssertEqual(segs.reduce(0) { $0 + $1.length }, total)
            for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
            XCTAssertLessThanOrEqual(Int64(segs.count), SegmentPlanner.maximumSegmentCount)
            XCTAssertEqual(segs.map(\.index), Array(0..<segs.count))
        }
    }

    func testNoRangeSupportIsSingleSegment() {
        let segs = SegmentPlanner.plan(totalBytes: 5_000_000_000, supportsRanges: false)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].length, 5_000_000_000)
    }

    func testContentRangeParsing() {
        let r = SegmentPlanner.parseContentRange("bytes 100-199/1000")
        XCTAssertEqual(r?.start, 100); XCTAssertEqual(r?.end, 199); XCTAssertEqual(r?.total, 1000)
        XCTAssertNil(SegmentPlanner.parseContentRange("bytes 100-199/*")?.total)
        XCTAssertNil(SegmentPlanner.parseContentRange("garbage"))
    }

    func testErrorClassification() {
        XCTAssertEqual(SegmentPlanner.classify(URLError(.networkConnectionLost)), .network)
        XCTAssertEqual(SegmentPlanner.classify(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(SegmentPlanner.classify(URLError(.cannotConnectToHost)), .unreachableHost)
        XCTAssertEqual(SegmentPlanner.classify(URLError(.cancelled)), .cancelledByUs)
        let forceQuit = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: NSURLErrorCancelledReasonUserForceQuitApplication])
        XCTAssertEqual(SegmentPlanner.classify(forceQuit), .cancelledBySystem)
    }

    func testTaskTagRoundTrip() {
        let tag = SegmentTaskTag(recordID: "abc_123", index: 7, start: 10, end: 99, total: 1000, ranged: true)
        XCTAssertEqual(SegmentTaskTag(tag.encoded), tag)
        XCTAssertNil(SegmentTaskTag("nope"))
    }
}

final class SegmentValidationTests: XCTestCase {
    private let id = "test_validation_\(UUID().uuidString.prefix(6))"
    override func tearDown() { DownloadStore.removeFiles(for: id) }

    private func tempFile(_ bytes: Int) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        return url
    }

    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://x")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testPartialContentMovedIntoPlace() {
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(100), response: response(206, ["Content-Range": "bytes 100-199/1000"]), tag: tag)
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(DownloadStore.fileSize(DownloadStore.segmentURL(id: id, index: 1)), 100)
    }

    func testTruncatedSegmentRejected() {
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(60), response: response(206, ["Content-Range": "bytes 100-199/1000"]), tag: tag)
        guard case .invalid = result else { return XCTFail("\(result)") }
    }

    func testWrongRangeRejected() {
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(100), response: response(206, ["Content-Range": "bytes 0-99/1000"]), tag: tag)
        guard case .invalid = result else { return XCTFail("\(result)") }
    }

    func testFileChangedOnServerDetected() {
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(100), response: response(206, ["Content-Range": "bytes 100-199/2000"]), tag: tag)
        guard case .http(416, _) = result else { return XCTFail("\(result)") }
    }

    func testServerIgnoringRangeWithWholeFile() {
        let tag = SegmentTaskTag(recordID: id, index: 3, start: 300, end: 399, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(1000), response: response(200), tag: tag)
        guard case .wholeFile = result else { return XCTFail("\(result)") }
    }

    func testMalformedEndAndOversizedRangeBodiesAreRejected() {
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        for (header, length) in [("garbage", 100), ("bytes 100-299/1000", 100), ("bytes 100-199/*", 100), ("bytes 100-199/1000", 101)] {
            let result = DownloadSessionDelegate.validateAndMove(location: tempFile(length), response: response(206, ["Content-Range": header]), tag: tag)
            guard case .invalid = result else { return XCTFail("Accepted invalid response: \(header), \(length)") }
        }
    }

    func testHTTPErrorPassesRetryAfter() {
        let tag = SegmentTaskTag(recordID: id, index: 0, start: 0, end: 99, total: 1000, ranged: true)
        let result = DownloadSessionDelegate.validateAndMove(location: tempFile(10), response: response(503, ["Retry-After": "12"]), tag: tag)
        guard case .http(503, 12) = result else { return XCTFail("\(result)") }
    }
}

final class AssemblerTests: XCTestCase {
    private let id = "test_assembly_\(UUID().uuidString.prefix(6))"
    override func tearDown() { DownloadStore.removeFiles(for: id) }

    private func writeSegments(_ segs: [DownloadSegment], skip: Set<Int> = []) {
        DownloadStore.ensureDirectory(for: id)
        for s in segs where !skip.contains(s.index) {
            let bytes = (s.start...s.end).map { UInt8(truncatingIfNeeded: $0) }
            FileManager.default.createFile(atPath: DownloadStore.segmentURL(id: id, index: s.index).path, contents: Data(bytes))
        }
    }

    private func makeSegments(total: Int64, size: Int64) -> [DownloadSegment] {
        stride(from: Int64(0), to: total, by: Int(size)).enumerated().map { i, start in
            DownloadSegment(index: i, start: start, end: min(start + size, total) - 1)
        }
    }

    func testAssemblesInOrderAndVerifies() throws {
        let segs = makeSegments(total: 1000, size: 128)
        writeSegments(segs)
        let name = try Assembler.assemble(id: id, segments: segs, totalBytes: 1000, ext: "mp4")
        let data = try Data(contentsOf: DownloadStore.directory(for: id).appendingPathComponent(name))
        XCTAssertEqual(data.count, 1000)
        XCTAssertEqual(Array(data), (0..<1000).map { UInt8(truncatingIfNeeded: $0) })
    }

    func testAssemblyResumesAfterInterruption() throws {
        let segs = makeSegments(total: 1000, size: 128)
        writeSegments(segs, skip: [5])
        XCTAssertThrowsError(try Assembler.assemble(id: id, segments: segs, totalBytes: 1000, ext: "mp4"))
        XCTAssertEqual(Assembler.assembledCount(id: id), 5)
        // Simulate a crash that left garbage appended past the last confirmed boundary.
        let final = DownloadStore.mediaURL(id: id, ext: "mp4")
        let h = try FileHandle(forWritingTo: final); try h.seekToEnd(); try h.write(contentsOf: Data(repeating: 0xFF, count: 50)); try h.close()
        writeSegments([segs[5]])
        _ = try Assembler.assemble(id: id, segments: segs, totalBytes: 1000, ext: "mp4")
        XCTAssertEqual(Array(try Data(contentsOf: final)), (0..<1000).map { UInt8(truncatingIfNeeded: $0) })
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testWholeFileSurvivesFallbackCleanup() throws {
        let id = "review_" + UUID().uuidString
        defer { DownloadStore.removeFiles(for: id) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 1000).write(to: tmp)
        let tag = SegmentTaskTag(recordID: id, index: 3, start: 300, end: 399, total: 1000, ranged: true)
        let response = HTTPURLResponse(url: URL(string: "http://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        guard case .wholeFile = DownloadSessionDelegate.validateAndMove(location: tmp, response: response, tag: tag) else { return XCTFail("Expected whole file") }
        // The exact cleanup called before moving whole-download in handleCompletion.
        DownloadStore.removeSegmentFiles(for: id)
        XCTAssertEqual(DownloadStore.fileSize(DownloadStore.directory(for: id).appendingPathComponent("whole-download")), 1000)
    }
    func testRangedResponseRequiresContentRange() throws {
        let id = "review_" + UUID().uuidString
        defer { DownloadStore.removeFiles(for: id) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 100).write(to: tmp)
        let tag = SegmentTaskTag(recordID: id, index: 1, start: 100, end: 199, total: 1000, ranged: true)
        let response = HTTPURLResponse(url: URL(string: "http://example.invalid")!, statusCode: 206, httpVersion: nil, headerFields: nil)!
        if case .success = DownloadSessionDelegate.validateAndMove(location: tmp, response: response, tag: tag) {
            XCTFail("Accepted a ranged body with no Content-Range")
        }
    }
    func testCompletedAssemblyCanBeRetriedAfterCheckpointRemoval() throws {
        let id = "review_" + UUID().uuidString
        defer { DownloadStore.removeFiles(for: id) }
        DownloadStore.ensureDirectory(for: id)
        let segments = [DownloadSegment(index: 0, start: 0, end: 99), DownloadSegment(index: 1, start: 100, end: 199)]
        for s in segments { try Data(repeating: 7, count: 100).write(to: DownloadStore.segmentURL(id: id, index: s.index)) }
        _ = try Assembler.assemble(id: id, segments: segments, totalBytes: 200, ext: "mp4")
        // Crash before DownloadManager persists completed: it retries the same assembly on launch.
        XCTAssertNoThrow(try Assembler.assemble(id: id, segments: segments, totalBytes: 200, ext: "mp4"))
        XCTAssertEqual(DownloadStore.fileSize(DownloadStore.mediaURL(id: id, ext: "mp4")), 200)
    }
}

final class OfflineProgressRegressionTests: XCTestCase {
    private func record(server: String = "one") throws -> DownloadRecord {
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"episode","title":"Episode","grandparentTitle":"Same title","grandparentRatingKey":"10"}"#.utf8))
        return DownloadRecord(serverID: server, metadata: item, quality: .original)
    }

    func testProfilesKeepIndependentPositionsAndWatchedState() throws {
        var rec = try record()
        rec.updateProgress(userID: "A", positionMs: 950, durationMs: 1000)
        rec.updateProgress(userID: "B", positionMs: 100, durationMs: 1000)
        XCTAssertTrue(rec.progress(for: "A")!.watched)
        XCTAssertEqual(rec.progress(for: "A")?.offset, 0)
        XCTAssertFalse(rec.progress(for: "B")!.watched)
        XCTAssertEqual(rec.progress(for: "B")?.offset, 100)
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(restored.userProgress, rec.userProgress)
    }

    func testAcknowledgementDoesNotClearNewerOrOtherUserProgress() throws {
        var rec = try record()
        rec.updateProgress(userID: "A", positionMs: 100, durationMs: 1000)
        let old = rec.progress(for: "A")!.revision
        rec.updateProgress(userID: "A", positionMs: 200, durationMs: 1000)
        rec.updateProgress(userID: "B", positionMs: 300, durationMs: 1000)
        rec.acknowledgeProgress(userID: "A", revision: old)
        XCTAssertTrue(rec.progress(for: "A")!.pending)
        XCTAssertTrue(rec.progress(for: "B")!.pending)
        rec.acknowledgeProgress(userID: "A", revision: rec.progress(for: "A")!.revision)
        XCTAssertFalse(rec.progress(for: "A")!.pending)
        XCTAssertTrue(rec.hasPendingProgress)
    }

    func testLegacyMigrationRetainsOwnerAndIsIdempotent() throws {
        var rec = try record()
        rec.pendingSync = true
        rec.pendingSyncUserID = "A"
        rec.offlineViewOffset = 123
        let encoded = try JSONEncoder().encode(rec)
        var restored = try JSONDecoder().decode(DownloadRecord.self, from: encoded)
        restored.migrateProgress()
        let migrated = restored.userProgress
        restored.migrateProgress()
        XCTAssertEqual(restored.userProgress, migrated)
        XCTAssertEqual(restored.progress(for: "A")?.offset, 123)
        XCTAssertNil(restored.progress(for: "B"))
        XCTAssertFalse(restored.pendingSync)
    }

    func testResumeUsesPendingOwnerProgressThenFreshServerPosition() throws {
        var rec = try record()
        rec.updateProgress(userID: "A", positionMs: 100, durationMs: 1000)
        XCTAssertEqual(rec.resumeOffset(for: "A", serverOffset: 50), 100)
        XCTAssertEqual(rec.resumeOffset(for: "B", serverOffset: 50), 50)
        rec.acknowledgeProgress(userID: "A", revision: rec.progress(for: "A")!.revision)
        XCTAssertEqual(rec.resumeOffset(for: "A", serverOffset: 500), 500)
    }

    func testAnonymousProgressIsNotAssignedToNextSignedInUser() throws {
        var rec = try record()
        rec.updateProgress(userID: nil, positionMs: 123, durationMs: 1000)
        XCTAssertNil(rec.progress(for: "A"))
        XCTAssertEqual(rec.progress(for: nil)?.offset, 123)
    }

    func testRewatchDoesNotRetainPendingCompletion() throws {
        var rec = try record()
        rec.updateProgress(userID: "A", positionMs: 950, durationMs: 1000)
        rec.updateProgress(userID: "A", positionMs: 100, durationMs: 1000)
        XCTAssertFalse(rec.progress(for: "A")!.watched)
        XCTAssertEqual(rec.progress(for: "A")?.offset, 100)
    }

    func testSameTitleAcrossServersHasDistinctGroupIdentity() throws {
        XCTAssertNotEqual(try record(server: "one").offlineGroupID, try record(server: "two").offlineGroupID)
    }

    func testForceConversionOverridesNativeHeuristicAndPersists() throws {
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie","title":"Movie","Media":[{"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"id":1,"key":"/file"}]}]}"#.utf8))
        var rec = DownloadRecord(serverID: "server", metadata: item, quality: .original)
        let media = try XCTUnwrap(item.primaryMedia)
        XCTAssertFalse(rec.requiresConversion(media: media, kind: .movie, quality: .original))
        rec.forceConversion = true
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertTrue(restored.requiresConversion(media: media, kind: .movie, quality: .original))
    }
}

final class PlaybackTransitionRegressionTests: XCTestCase {
    func testAdvanceIsExclusiveUntilOriginalRequestCompletes() {
        var gate = PlaybackTransitionGate()
        let first = UUID(), second = UUID()
        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(first))
        XCTAssertFalse(gate.begin(second))
        gate.end(second)
        XCTAssertTrue(gate.isActive)
        gate.end(first)
        XCTAssertTrue(gate.begin(second))
    }

    @MainActor func testDeadlineReturnsEvenIfReportIgnoresCancellation() async {
        let report = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { continuation.resume() }
            }
        }
        let start = ContinuousClock.now
        await PlaybackReportDeadline.wait(for: report, timeout: .milliseconds(20))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(350))
        XCTAssertTrue(report.isCancelled)
        await report.value
    }
}

@MainActor
final class PlaybackQueueEditingTests: XCTestCase {
    private func item(_ key: String, type: String = "episode") throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data("{\"ratingKey\":\"\(key)\",\"title\":\"\(key)\",\"type\":\"\(type)\"}".utf8))
    }
    private func request(_ key: String, server: String = "queue-test") throws -> VideoPlayRequest {
        VideoPlayRequest(item: try item(key), serverID: server, startMs: 0, localURL: nil, downloadID: nil)
    }
    func testVideoQueueReorderAndRemovalPreserveCurrentItem() throws {
        let current = try request("current")
        let player = VideoPlaybackController(request: current, upNext: [try request("a"), try request("b"), try request("c")])
        player.moveUpcoming(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(player.upNext.map(\.item.ratingKey), ["c", "a", "b"])
        player.removeUpcoming(at: IndexSet(integer: 1))
        XCTAssertEqual(player.upNext.map(\.item.ratingKey), ["c", "b"])
        XCTAssertEqual(player.request.id, current.id)
    }
    func testVideoQueueDeduplicationUsesServerAndItem() throws {
        let player = VideoPlaybackController(request: try request("current"))
        player.enqueue([try request("a"), try request("a"), try request("a", server: "other")])
        XCTAssertEqual(player.upNext.count, 2)
        player.playNext(try request("a", server: "other"))
        XCTAssertEqual(player.upNext.count, 2)
        XCTAssertEqual(player.upNext.first?.serverID, "other")
    }
    func testMusicQueueEditsKeepCurrentEntryAndServerIdentity() throws {
        let player = AudioPlayer.shared
        defer { player.stop() }
        player.play([try item("current", type: "track")], serverID: "no-network-test")
        let currentID = player.current?.id
        player.enqueue([try item("a", type: "track"), try item("b", type: "track")], serverID: "second-server")
        player.playNext(try item("next", type: "track"), serverID: "third-server")
        XCTAssertEqual(player.upcoming.map(\.track.ratingKey), ["next", "a", "b"])
        player.moveUpcoming(from: IndexSet(integer: 2), to: 0)
        player.removeUpcoming(at: IndexSet(integer: 1))
        XCTAssertEqual(player.upcoming.map(\.track.ratingKey), ["b", "a"])
        XCTAssertEqual(player.upcoming.map(\.serverID), ["second-server", "second-server"])
        XCTAssertEqual(player.current?.id, currentID)
        XCTAssertEqual(player.index, 0)
    }
    func testDownloadEstimateDistinguishesSourceAndConvertedSize() throws {
        let json = #"{"ratingKey":"estimate","type":"movie","title":"Test","duration":60000,"Media":[{"container":"mp4","videoCodec":"h264","audioCodec":"aac","Part":[{"size":200000000,"container":"mp4"}]}]}"#
        let media = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        XCTAssertTrue(DownloadEstimate.sizeLabel(item: media, quality: .medium).contains("estimate"))
        XCTAssertEqual(DownloadEstimate.sizeLabel(item: media, quality: .original), Fmt.bytes(200_000_000))
        XCTAssertEqual(DownloadEstimate.sizeLabel(item: try item("missing"), quality: .original), "Unknown until download starts")
    }
}
