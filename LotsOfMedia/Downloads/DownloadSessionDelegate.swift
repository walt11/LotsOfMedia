import Foundation

/// Identifies which record/segment a URLSession task belongs to. Encoded in
/// `taskDescription`, which the background session persists across launches.
struct SegmentTaskTag: Equatable {
    let recordID: String
    let index: Int
    let start: Int64
    let end: Int64
    let total: Int64
    let ranged: Bool

    var expectedLength: Int64 { end - start + 1 }

    var encoded: String { "\(recordID)|\(index)|\(start)|\(end)|\(total)|\(ranged ? 1 : 0)" }

    init(recordID: String, index: Int, start: Int64, end: Int64, total: Int64, ranged: Bool) {
        self.recordID = recordID; self.index = index; self.start = start; self.end = end; self.total = total; self.ranged = ranged
    }

    init?(_ description: String?) {
        guard let parts = description?.split(separator: "|").map(String.init), parts.count == 6,
              let index = Int(parts[1]), let start = Int64(parts[2]), let end = Int64(parts[3]), let total = Int64(parts[4])
        else { return nil }
        self.init(recordID: parts[0], index: index, start: start, end: end, total: total, ranged: parts[5] == "1")
    }
}

enum SegmentResult {
    case success
    /// The server ignored the Range header and sent the entire file, which is complete.
    case wholeFile
    /// The server ignored the Range header and the body isn't usable as-is.
    case rangeIgnored
    case http(status: Int, retryAfter: TimeInterval?)
    case invalid(String)
    case error(Error, hasResumeData: Bool)
}

/// Receives background URLSession callbacks on a private serial queue. Files
/// must be moved before `didFinishDownloadingTo` returns, so that work happens
/// here; state changes are forwarded to the main-actor `DownloadManager`.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "net.jwalter.LotsOfMedia.downloads.delegate"
        return q
    }()

    var onComplete: ((_ tag: SegmentTaskTag, _ taskID: Int, _ result: SegmentResult) -> Void)?
    var onEventsFinished: (() -> Void)?
    /// A scheduled "is the conversion done yet?" check finished (any outcome).
    var onProbeFinished: ((_ recordID: String) -> Void)?

    private let lock = NSLock()
    private var pendingResults: [Int: SegmentResult] = [:]
    private var progress: [String: [Int: Int64]] = [:]

    func progressSnapshot() -> [String: [Int: Int64]] { lock.withLock { progress } }

    func clearProgress(recordID: String, index: Int? = nil) {
        lock.withLock {
            if let index { progress[recordID]?[index] = nil } else { progress[recordID] = nil }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = SegmentTaskTag(downloadTask.taskDescription) else { return }
        lock.withLock { progress[tag.recordID, default: [:]][tag.index] = min(totalBytesWritten, tag.expectedLength) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        guard let tag = SegmentTaskTag(downloadTask.taskDescription) else { return }
        lock.withLock { progress[tag.recordID, default: [:]][tag.index] = min(fileOffset, tag.expectedLength) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = SegmentTaskTag(downloadTask.taskDescription) else { return }
        let result = Self.validateAndMove(location: location, response: downloadTask.response as? HTTPURLResponse, tag: tag)
        lock.withLock { pendingResults[downloadTask.taskIdentifier] = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let desc = task.taskDescription, desc.hasPrefix(DownloadManager.probePrefix) {
            onProbeFinished?(String(desc.dropFirst(DownloadManager.probePrefix.count)))
            return
        }
        guard let tag = SegmentTaskTag(task.taskDescription) else { return }
        var result = lock.withLock { pendingResults.removeValue(forKey: task.taskIdentifier) }
        if let error {
            let ns = error as NSError
            var hasResume = false
            if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !tag.ranged {
                DownloadStore.ensureDirectory(for: tag.recordID)
                // Only un-ranged (single stream) tasks use resume data; see DownloadManager.
                try? data.write(to: DownloadStore.resumeDataURL(id: tag.recordID, index: tag.index), options: .atomic)
                hasResume = true
            }
            result = .error(error, hasResumeData: hasResume)
        }
        let final = result ?? .invalid("Download ended without data")
        let id = task.taskIdentifier
        onComplete?(tag, id, final)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEventsFinished?()
    }

    // MARK: Validation

    static func validateAndMove(location: URL, response: HTTPURLResponse?, tag: SegmentTaskTag) -> SegmentResult {
        let fm = FileManager.default
        guard let response else { return .invalid("No response") }
        let status = response.statusCode
        guard status == 200 || status == 206 else {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .http(status: status, retryAfter: retry)
        }
        guard let size = DownloadStore.fileSize(location) else { return .invalid("Missing temporary file") }

        DownloadStore.ensureDirectory(for: tag.recordID)
        var destination = DownloadStore.segmentURL(id: tag.recordID, index: tag.index)
        var result = SegmentResult.success

        if status == 206 {
            if tag.ranged {
                guard let cr = SegmentPlanner.parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                      cr.start == tag.start, cr.end == tag.end else {
                    return .invalid("Server returned a missing or incorrect byte range")
                }
                guard let total = cr.total else { return .invalid("Server omitted the total file size") }
                if total != tag.total { return .http(status: 416, retryAfter: nil) }
            }
            guard size == tag.expectedLength else {
                return .invalid("Incorrect segment length (\(size) of \(tag.expectedLength) bytes)")
            }
        } else { // 200
            if tag.start == 0 && size == tag.expectedLength {
                result = .success
            } else if size == tag.total {
                destination = DownloadStore.directory(for: tag.recordID).appendingPathComponent("whole-download")
                result = .wholeFile
            } else {
                return .rangeIgnored
            }
        }

        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
        } catch {
            return .error(error, hasResumeData: false)
        }
        return result
    }
}

/// Stitches segments into the final media file. Crash-safe: progress is
/// recorded in a sidecar after every segment, and the output is truncated back
/// to the last confirmed boundary when assembly restarts.
enum Assembler {
    enum AssemblyError: LocalizedError {
        case missingSegment(Int)
        case sizeMismatch(expected: Int64, actual: Int64)
        var errorDescription: String? {
            switch self {
            case .missingSegment(let i): return "Segment \(i) is missing"
            case .sizeMismatch(let e, let a): return "Size mismatch (expected \(e), got \(a))"
            }
        }
    }

    static func sidecarURL(id: String) -> URL { DownloadStore.directory(for: id).appendingPathComponent("assembled") }

    static func assembledCount(id: String) -> Int {
        (try? String(contentsOf: sidecarURL(id: id), encoding: .utf8)).flatMap { Int($0) } ?? 0
    }

    /// Returns the final file name on success.
    static func assemble(id: String, segments: [DownloadSegment], totalBytes: Int64, ext: String) throws -> String {
        let fm = FileManager.default
        DownloadStore.ensureDirectory(for: id)
        let final = DownloadStore.mediaURL(id: id, ext: ext)
        let name = final.lastPathComponent

        // A crash may leave completed output before the manager commits its state.
        // Adopt it before touching checkpoints or segments.
        if DownloadStore.fileSize(final) == totalBytes { return name }

        if segments.count == 1 {
            let seg = DownloadStore.segmentURL(id: id, index: 0)
            if fm.fileExists(atPath: seg.path) {
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                try fm.moveItem(at: seg, to: final)
            }
        } else {
            var done = assembledCount(id: id)
            let prefix = segments.prefix(done).reduce(Int64(0)) { $0 + $1.length }
            if !fm.fileExists(atPath: final.path) {
                fm.createFile(atPath: final.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                done = 0
            }
            let out = try FileHandle(forWritingTo: final)
            defer { try? out.close() }
            try out.truncate(atOffset: UInt64(done == 0 ? 0 : prefix))
            try out.seekToEnd()

            for seg in segments.sorted(by: { $0.index < $1.index }).dropFirst(done) {
                let url = DownloadStore.segmentURL(id: id, index: seg.index)
                guard DownloadStore.fileSize(url) == seg.length else { throw AssemblyError.missingSegment(seg.index) }
                let input = try FileHandle(forReadingFrom: url)
                while true {
                    let chunk = try autoreleasepool { try input.read(upToCount: 8 * 1024 * 1024) }
                    guard let chunk, !chunk.isEmpty else { break }
                    try out.write(contentsOf: chunk)
                }
                try input.close()
                try out.synchronize()
                done += 1
                try String(done).write(to: sidecarURL(id: id), atomically: true, encoding: .utf8)
                try? fm.removeItem(at: url)
            }
        }

        let actual = DownloadStore.fileSize(final) ?? -1
        guard actual == totalBytes else { throw AssemblyError.sizeMismatch(expected: totalBytes, actual: actual) }
        try? fm.removeItem(at: sidecarURL(id: id))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var finalURL = final
        try? finalURL.setResourceValues(values)
        return name
    }
}
