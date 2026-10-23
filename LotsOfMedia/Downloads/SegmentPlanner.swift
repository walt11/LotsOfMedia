import Foundation

/// Pure helpers for the download engine (kept free of I/O so they're unit-testable).
enum SegmentPlanner {
    static let minimumSegmentSize: Int64 = 32 * 1024 * 1024
    static let maximumSegmentCount: Int64 = 512

    /// Splits a file into byte ranges. Each range is downloaded by its own
    /// background task, so an interruption can only ever cost the part of a
    /// segment that was in flight – never the whole file. Tasks are created in
    /// a bounded window, so the segment count only affects the index size.
    static func plan(totalBytes: Int64, supportsRanges: Bool = true) -> [DownloadSegment] {
        guard totalBytes > 0 else { return [] }
        guard supportsRanges else { return [DownloadSegment(index: 0, start: 0, end: totalBytes - 1)] }
        let byCount = (totalBytes + maximumSegmentCount - 1) / maximumSegmentCount
        let size = max(minimumSegmentSize, byCount)
        var out: [DownloadSegment] = []
        var start: Int64 = 0
        var index = 0
        while start < totalBytes {
            let end = min(start + size, totalBytes) - 1
            out.append(DownloadSegment(index: index, start: start, end: end))
            start = end + 1
            index += 1
        }
        return out
    }

    /// Parses `Content-Range: bytes 0-99/1000` → (0, 99, 1000). Total may be `*`.
    static func parseContentRange(_ header: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let range = parts[0].split(separator: "-", maxSplits: 1)
        guard range.count == 2, let s = Int64(range[0]), let e = Int64(range[1]) else { return nil }
        return (s, e, Int64(parts[1]))
    }

    enum FailureKind: Equatable {
        /// Connectivity problem; retry indefinitely when the network allows.
        case network
        /// Host-level failure: the server address may have changed (e.g. left home Wi-Fi).
        case unreachableHost
        /// We cancelled it (pause/delete).
        case cancelledByUs
        /// System cancelled it (app force-quit, background limits) – resumable.
        case cancelledBySystem
        /// Local disk problem.
        case storage
        case other
    }

    static func classify(_ error: Error) -> FailureKind {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return .storage }
        // Foundation file APIs (moving a finished piece, writing the final file) report a full disk this way.
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .storage }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ENOSPC) { return .storage }
        guard ns.domain == NSURLErrorDomain else { return .other }
        switch ns.code {
        case NSURLErrorCancelled:
            if ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil { return .cancelledBySystem }
            return .cancelledByUs
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive, NSURLErrorTimedOut,
             NSURLErrorBackgroundSessionWasDisconnected:
            return .network
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return .unreachableHost
        case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotMoveFile:
            return .storage
        default:
            return .other
        }
    }

    /// Exponential backoff capped at 60s.
    static func backoff(attempts: Int) -> TimeInterval {
        min(60, pow(2, Double(min(max(attempts, 0), 6))))
    }
}
