import Foundation

enum DownloadQuality: String, Codable, CaseIterable, Identifiable {
    /// Best playable quality: the untouched file when iOS can play it,
    /// otherwise converted by the server with no quality cap (the video is
    /// remuxed into MP4 without re-encoding whenever its codec allows).
    case original
    case high      // 1080p ~ 10 Mbps
    case medium    // 720p ~ 4 Mbps
    case low       // 480p ~ 1.5 Mbps

    var id: String { rawValue }

    /// Older versions stored "auto", which had the same meaning as `.original` now.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DownloadQuality(rawValue: raw) ?? .original
    }

    var label: String {
        switch self {
        case .original: return "Original Quality"
        case .high: return "1080p (10 Mbps)"
        case .medium: return "720p (4 Mbps)"
        case .low: return "480p (1.5 Mbps)"
        }
    }

    var detail: String {
        switch self {
        case .original:
            return BuiltInPlayer.isEnabled
                ? "Full quality, as the original file. MKV, AVI and similar files play in the built-in player"
                : "Full quality. Formats iPhone can't play (MKV, AVI, DTS…) are converted to MP4 by your server automatically"
        default: return "Smaller file, converted by your server before downloading"
        }
    }

    /// Vertical resolution class of the converted copy (nil = source).
    var targetHeight: Int? {
        switch self {
        case .original: return nil
        case .high: return 1080
        case .medium: return 720
        case .low: return 480
        }
    }

    /// Whether converting `media` to this quality would actually make a smaller,
    /// lower-resolution copy. A "1080p" copy of a 480p file is just a bigger file.
    func isReduction(of media: PlexMedia?) -> Bool {
        guard let height = targetHeight, let target = transcodeTarget else { return true }
        guard let media else { return true }                  // unknown source: allow
        if let source = media.resolutionClass, height >= source { return false }
        if let bitrate = media.bitrate, bitrate > 0, target.bitrate >= bitrate { return false }
        return true
    }

    /// Qualities worth offering for an item: always Original, plus any real reduction.
    static func choices(for item: PlexMetadata) -> [DownloadQuality] {
        // Music is always kept original; containers (shows, seasons) mix sources,
        // so they offer everything and each item is checked when it's prepared.
        if [.track, .album, .artist].contains(item.kind) { return [.original] }
        guard item.isLeaf else { return allCases }
        return allCases.filter { $0 == .original || $0.isReduction(of: item.primaryMedia) }
    }

    /// Bitrate/resolution caps for server-side conversion; nil = keep source quality.
    var transcodeTarget: (bitrate: Int, resolution: String)? {
        switch self {
        case .original: return nil
        case .high: return (10_000, "1920x1080")
        case .medium: return (4_000, "1280x720")
        case .low: return (1_500, "854x480")
        }
    }
}

struct DownloadSegment: Codable, Hashable {
    var index: Int
    var start: Int64
    /// Inclusive end offset.
    var end: Int64
    var done: Bool = false
    var attempts: Int = 0
    /// Base URL the most recent task for this segment used. Resume data is only
    /// valid against the same host, so it is discarded if the endpoint changes.
    var lastBaseURL: String?

    var length: Int64 { end - start + 1 }
}

struct DownloadRecord: Codable, Identifiable, Hashable {
    enum Source: Codable, Hashable {
        /// Direct original file: /library/parts/{id}/{ts}/file.ext
        case file(partKey: String)
        /// Server download queue item (converted media).
        case queue(queueID: Int, itemID: Int)
    }

    enum State: String, Codable {
        case queued        // waiting to be prepared
        case preparing     // server is converting
        case downloading   // segments in flight or waiting to be scheduled
        case paused
        case assembling    // stitching segments into the final file
        case completed
        case failed
    }

    let id: String
    let serverID: String
    var metadata: PlexMetadata
    var quality: DownloadQuality
    var source: Source?
    var state: State = .queued
    var totalBytes: Int64?
    var segments: [DownloadSegment] = []
    var assembledSegments: Int = 0
    var fileExtension: String = "mp4"
    var fileName: String?
    var preparationProgress: Double?
    var lastError: String?
    var createdAt: Date = Date()
    var completedAt: Date?
    var prepareAttempts: Int = 0
    var forceConversion: Bool?
    var isConverted: Bool = false
    /// Why the server converts this download ("iPhone can't play MKV files"), for display.
    var conversionReason: String?
    /// The source container, so finished downloads can say "Converted from MKV".
    var sourceContainer: String?

    // Offline playback progress awaiting sync to the server.
    var offlineViewOffset: Int?
    var offlineWatched: Bool = false
    var pendingSync: Bool = false
    /// Plex Home user whose offline progress is pending, so it syncs to the right account.
    var pendingSyncUserID: String?
    /// Downloads started together (a playlist, season, show…) share a batch so
    /// they're announced once, when the whole group has finished.
    var batchID: String?
    var batchTitle: String?

    /// Independent progress for each profile; the legacy fields above are migrated on load.
    var userProgress: [String: OfflineProgress]?

    static func progressKey(_ userID: String?) -> String { userID.map { "user:" + $0 } ?? "anonymous" }
    var hasPendingProgress: Bool { pendingSync || userProgress?.values.contains(where: \.pending) == true }
    func progress(for userID: String?) -> OfflineProgress? { userProgress?[Self.progressKey(userID)] }

    func resumeOffset(for userID: String?, serverOffset: Int?) -> Int {
        if let progress = progress(for: userID), progress.pending { return progress.offset }
        return serverOffset ?? 0
    }

    mutating func migrateProgress() {
        if pendingSync {
            let key = Self.progressKey(pendingSyncUserID)
            if userProgress?[key] == nil {
                if userProgress == nil { userProgress = [:] }
                userProgress?[key] = OfflineProgress(offset: offlineViewOffset ?? 0, watched: offlineWatched, pending: true)
            }
            pendingSync = false
            offlineWatched = false
            offlineViewOffset = nil
        }
    }

    mutating func updateProgress(userID: String?, positionMs: Int, durationMs: Int?) {
        migrateProgress()
        let watched = durationMs.map { $0 > 0 && Double(positionMs) / Double($0) > 0.9 } ?? false
        if userProgress == nil { userProgress = [:] }
        userProgress?[Self.progressKey(userID)] = OfflineProgress(offset: watched ? 0 : positionMs, watched: watched, pending: true)
    }

    mutating func acknowledgeProgress(userID: String?, revision: UUID) {
        let key = Self.progressKey(userID)
        guard userProgress?[key]?.revision == revision else { return }
        userProgress?[key]?.pending = false
    }

    func requiresConversion(media: PlexMedia, kind: PlexMetadata.Kind, quality: DownloadQuality) -> Bool {
        // Originals the built-in player can play are kept as-is (no waiting on the server).
        forceConversion == true || !PlaybackDecider.canPlayOnDevice(media: media, kind: kind) || (kind != .track && quality != .original)
    }

    var offlineGroupID: String {
        [serverID, metadata.type ?? "other", metadata.grandparentRatingKey ?? metadata.parentRatingKey ?? metadata.ratingKey]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
    var offlineGroupTitle: String { metadata.grandparentTitle ?? metadata.parentTitle ?? "Other" }

    // New fields are optional so records saved by earlier versions still decode.
    private var _subtitleFiles: [SubtitleFile]?
    private var _waitingForSpace: Bool?

    /// Subtitle files saved next to the media for offline use.
    var subtitleFiles: [SubtitleFile] {
        get { _subtitleFiles ?? [] }
        set { _subtitleFiles = newValue.isEmpty ? nil : newValue }
    }
    /// Paused because the storage limit was reached; resumes when space frees up.
    var waitingForSpace: Bool {
        get { _waitingForSpace ?? false }
        set { _waitingForSpace = newValue ? true : nil }
    }

    struct SubtitleFile: Codable, Hashable {
        var streamID: Int
        var label: String
        var fileName: String
        var selected: Bool
    }

    init(serverID: String, metadata: PlexMetadata, quality: DownloadQuality) {
        self.id = DownloadRecord.makeID(serverID: serverID, ratingKey: metadata.ratingKey)
        self.serverID = serverID
        self.metadata = metadata
        self.quality = quality
    }

    static func makeID(serverID: String, ratingKey: String) -> String {
        let safe = (serverID + "_" + ratingKey).map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return String(safe)
    }

    var downloadedSegmentBytes: Int64 { segments.filter(\.done).reduce(0) { $0 + $1.length } }

    var isAudio: Bool { metadata.kind == .track }

    static func == (a: DownloadRecord, b: DownloadRecord) -> Bool {
        a.id == b.id && a.state == b.state && a.segments == b.segments && a.lastError == b.lastError
            && a.preparationProgress == b.preparationProgress && a.totalBytes == b.totalBytes
            && a.offlineViewOffset == b.offlineViewOffset && a.userProgress == b.userProgress
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// A playlist the user downloaded as a whole. Playlist membership can't be
/// derived from item metadata (unlike seasons or albums), so it's stored.
struct DownloadCollection: Codable, Identifiable, Hashable {
    let id: String              // serverID_ratingKey
    let serverID: String
    let ratingKey: String
    var title: String
    var thumb: String?
    var playlistType: String?   // "audio" | "video"
    /// Record IDs in playlist order.
    var itemIDs: [String]
    var createdAt: Date = Date()

    var isAudio: Bool { playlistType == "audio" }

    /// Download items added to the playlist on the server. On unless turned off (nil = on).
    var autoDownloadNew: Bool?
    var downloadsNewItems: Bool { autoDownloadNew != false }
    /// Delete downloads of items removed from the playlist (kept if another downloaded playlist has them).
    var removeMissing: Bool?
    var lastSynced: Date?
    var keepsUpdated: Bool { downloadsNewItems || removeMissing == true }
}

/// What a playlist sync should do, given the server's current items.
struct PlaylistSyncPlan: Equatable {
    var toDownload: [String]       // ratingKeys new on the server
    var toRemove: [String]         // record IDs no longer in the playlist
    var order: [String]            // record IDs in the server's order

    static func make(collection c: DownloadCollection, serverKeys: [String], usedElsewhere: Set<String>) -> PlaylistSyncPlan {
        var seen = Set<String>()
        let keys = serverKeys.filter { seen.insert($0).inserted }
        let ids = keys.map { DownloadRecord.makeID(serverID: c.serverID, ratingKey: $0) }
        let known = Set(c.itemIDs)
        let current = Set(ids)
        let new = c.downloadsNewItems ? zip(keys, ids).filter { !known.contains($0.1) }.map(\.0) : []
        let gone = c.removeMissing == true ? c.itemIDs.filter { !current.contains($0) && !usedElsewhere.contains($0) } : []
        // Without removal, songs taken off the playlist stay downloaded and listed at the end.
        let order = (c.downloadsNewItems ? ids : ids.filter(known.contains))
            + (c.removeMissing == true ? [] : c.itemIDs.filter { !current.contains($0) })
        return PlaylistSyncPlan(toDownload: new, toRemove: gone, order: order)
    }
}

struct OfflineProgress: Codable, Hashable {
    var revision = UUID()
    var offset: Int
    var watched: Bool
    var pending: Bool
}
