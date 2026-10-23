import Foundation

/// On-disk layout and persistence for downloads.
///
///   Application Support/Downloads/
///     downloads.json            – all records (atomic writes)
///     <recordID>/seg_<n>        – completed byte-range segments
///     <recordID>/seg_<n>.resume – URLSession resume data for an interrupted segment
///     <recordID>/media.<ext>    – the final assembled file
///     <recordID>/poster.jpg     – artwork for offline browsing
enum DownloadStore {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    static var indexURL: URL { root.appendingPathComponent("downloads.json") }

    /// Pure path computation – no disk access, safe to call from view bodies.
    static func directory(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Creates a record's directory; only callers that are about to write need this.
    @discardableResult
    static func ensureDirectory(for id: String) -> URL {
        let dir = directory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir
    }

    static func segmentURL(id: String, index: Int) -> URL { directory(for: id).appendingPathComponent("seg_\(index)") }
    static func resumeDataURL(id: String, index: Int) -> URL { directory(for: id).appendingPathComponent("seg_\(index).resume") }
    static func mediaURL(id: String, ext: String) -> URL { directory(for: id).appendingPathComponent("media.\(ext)") }
    static func posterURL(id: String) -> URL { directory(for: id).appendingPathComponent("poster.jpg") }
    static func artURL(id: String) -> URL { directory(for: id).appendingPathComponent("art.jpg") }

    /// The saved records. `readable` is false when an index exists but couldn't be read
    /// (e.g. before the first unlock after a restart); the caller must not overwrite it then.
    /// A record that fails to decode is skipped on its own instead of losing the whole list.
    static func load() -> (records: [DownloadRecord], readable: Bool) {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return ([], true) }
        guard let data = try? Data(contentsOf: indexURL) else { return ([], false) }
        return (decodeRecords(data), true)
    }

    static func decodeRecords(_ data: Data) -> [DownloadRecord] {
        if let all = try? JSONDecoder().decode([DownloadRecord].self, from: data) { return all }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return items.compactMap { item in
            (try? JSONSerialization.data(withJSONObject: item)).flatMap { try? JSONDecoder().decode(DownloadRecord.self, from: $0) }
        }
    }

    /// Deletes download folders that no record owns (left behind by a failed delete or a lost index).
    static func removeOrphans(keeping ids: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where !ids.contains(name) {
            var isDir: ObjCBool = false
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Serial queue so saves never block the UI and always land in order.
    private static let ioQueue = DispatchQueue(label: "net.jwalter.LotsOfMedia.downloads.store", qos: .utility)

    static func save(_ records: [DownloadRecord]) {
        ioQueue.async {
            // Offline browsing only needs a lean copy of the metadata.
            let lean = records.map { r -> DownloadRecord in var r = r; r.metadata = r.metadata.trimmedForStorage(); return r }
            guard let data = try? JSONEncoder().encode(lean) else { return }
            try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Waits for pending saves (before suspension).
    static func flush() { ioQueue.sync {} }

    static func removeFiles(for id: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    static func removeSegmentFiles(for id: String) {
        let dir = directory(for: id)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix("seg_") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func usedBytes() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
