import Foundation
import CryptoKit

/// Disk cache of library responses (sections, items, hubs, playlists), so
/// browsing keeps working without a connection. Entries are scoped to the
/// server *and* the profile's token, so one Home user never sees another's
/// cached library. Artwork is cached separately by ImageLoader's URLCache.
enum LibraryCache {
    /// Only library browsing is cached; play state, transcodes, DVR and
    /// download-queue calls must always hit the server.
    static let cacheablePrefixes = ["/library/", "/hubs", "/playlists"]
    static let maxBytes: Int64 = 80 * 1024 * 1024

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _offline = false
    /// Bumped by `clear()`: a write submitted before it (an old session's response) is dropped.
    nonisolated(unsafe) private static var _generation = 0
    /// Taken when a request starts and passed to `write`, so a response that arrives after a
    /// sign-out (an old session's request) is discarded.
    static var generation: Int { lock.withLock { _generation } }

    /// Set when the device or the server is unreachable: reads go straight to
    /// the cache instead of waiting for a request to time out.
    static var isOffline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    static var directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Set while work must see the server's current state (e.g. syncing a
    /// downloaded playlist, where a stale list could delete the wrong songs).
    @TaskLocal static var requireFresh = false

    static func isCacheable(path: String, method: String) -> Bool {
        // Search results are one-off: caching each query would push out the library itself.
        method == "GET" && !requireFresh && !path.hasPrefix("/hubs/search") && cacheablePrefixes.contains { path.hasPrefix($0) }
    }

    static func key(serverID: String, token: String?, path: String, query: [URLQueryItem]) -> String {
        let q = query.filter { $0.name != "X-Plex-Token" }
            .map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        let raw = [serverID, token ?? "", path, q].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key))
    }

    static func write(_ data: Data, key: String, generation requestGeneration: Int? = nil) {
        // Responses arrive concurrently: write, count and trim on one serial queue, off the caller
        // (an offline fallback, so a read just before the write lands simply misses).
        let url = directory.appendingPathComponent(key)
        let submitted = requestGeneration ?? generation
        guard submitted == generation else { return }
        maintenance.async {
            guard submitted == generation else { return }
            try? data.write(to: url, options: .atomic)
            writesSinceTrim += 1
            guard writesSinceTrim >= 50 else { return }
            writesSinceTrim = 0
            trim()
        }
    }
    /// Blocks until queued writes have landed (tests).
    static func waitForPendingWrites() { maintenance.sync {} }
    /// Serializes the write counter and trimming.
    private static let maintenance = DispatchQueue(label: "net.jwalter.LotsOfMedia.libraryCache", qos: .utility)
    /// Only touched on `maintenance`.
    nonisolated(unsafe) private static var writesSinceTrim = 0

    /// Drops the least recently written entries once the cache passes its size cap.
    static func trim(limit: Int64 = maxBytes) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    /// Empties the cache (sign-out), keeping the directory.
    /// Runs in order with queued writes; writes from before the clear are discarded.
    static func clear() {
        lock.withLock { _generation += 1 }
        maintenance.sync {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Network failures (as opposed to server errors) fall back to the cache.
    static func isConnectivityError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost,
                .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed,
                .internationalRoamingOff].contains(e.code)
    }
}
