import Foundation

/// Size/range probing for a download URL.
enum MediaProbe {
    struct Result { let totalBytes: Int64; let acceptsRanges: Bool }

    enum ProbeError: Error { case notReady(retryAfter: TimeInterval?) }

    /// Requests the first byte. A 206 with Content-Range proves range support
    /// and gives the total size; a 200 means the server ignores ranges.
    static func probe(_ url: URL, token: String?) async throws -> Result {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        bytes.task.cancel()
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        switch http.statusCode {
        case 206:
            if let cr = SegmentPlanner.parseContentRange(http.value(forHTTPHeaderField: "Content-Range")), let total = cr.total {
                return Result(totalBytes: total, acceptsRanges: true)
            }
            throw PlexError.invalidResponse
        case 200:
            guard http.expectedContentLength > 0 else { throw PlexError.unsupported("Server didn't report the file size.") }
            return Result(totalBytes: http.expectedContentLength, acceptsRanges: false)
        case 503:
            throw ProbeError.notReady(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default:
            throw PlexError.http(http.statusCode, nil)
        }
    }
}

/// Server-side conversion via the PMS download queue (PMS 1.41.9+). The server
/// transcodes to an iOS-friendly MP4 *before* we download, producing a real
/// file that supports byte ranges – so converted downloads get the same
/// interruption-proof segmented transfer as originals.
enum ServerConversion {
    static let profileExtra = [
        "add-transcode-target(type=videoProfile&context=static&protocol=http&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3)",
        "add-transcode-target(type=musicProfile&context=static&protocol=http&container=mp4&audioCodec=aac)",
    ].joined(separator: "+")

    /// `burnSubtitles`: false when the selected subtitle is sidecar text that's saved
    /// separately (so it isn't also burned into the converted video).
    static func enqueue(api: PlexServerAPI, ratingKey: String, mediaIndex: Int = 0, quality: DownloadQuality,
                        burnSubtitles: Bool = true, forceTranscode: Bool = false) async throws -> (queueID: Int, itemID: Int) {
        let queue = try await api.container("/downloadQueue", method: "POST")
        guard let queueID = queue.downloadQueues.first?.id else { throw PlexError.invalidResponse }
        var caps: [URLQueryItem] = []
        if let target = quality.transcodeTarget {
            caps = [
                URLQueryItem(name: "videoBitrate", value: "\(target.bitrate)"),
                URLQueryItem(name: "peakBitrate", value: "\(target.bitrate)"),
                URLQueryItem(name: "videoResolution", value: target.resolution),
            ]
        } else {
            // Source quality: when video must be re-encoded, keep it visually lossless.
            caps = [URLQueryItem(name: "videoBitrate", value: "100000"), URLQueryItem(name: "peakBitrate", value: "100000")]
        }
        let added = try await api.container("/downloadQueue/\(queueID)/add", query: caps + [
            URLQueryItem(name: "keys", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "protocol", value: "http"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: forceTranscode ? "0" : "1"),
            URLQueryItem(name: "directStreamAudio", value: forceTranscode ? "0" : "1"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "mediaIndex", value: "\(mediaIndex)"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "subtitles", value: burnSubtitles ? "auto" : "none"),
            URLQueryItem(name: "location", value: "lan"),
        ], method: "POST", headers: ["X-Plex-Client-Profile-Extra": profileExtra])
        guard let itemID = added.addedQueueItems.first?.id else { throw PlexError.invalidResponse }
        return (queueID, itemID)
    }

    static func status(api: PlexServerAPI, queueID: Int, itemID: Int) async throws -> DownloadQueueItemInfo? {
        try await api.container("/downloadQueue/\(queueID)/items/\(itemID)").downloadQueueItems.first
    }

    static func restart(api: PlexServerAPI, queueID: Int, itemID: Int) async throws {
        try await api.data("/downloadQueue/\(queueID)/items/\(itemID)/restart", method: "POST")
    }

    static func remove(api: PlexServerAPI, queueID: Int, itemID: Int) async {
        _ = try? await api.data("/downloadQueue/\(queueID)/items/\(itemID)", method: "DELETE", timeout: 8)
    }

    static func mediaPath(queueID: Int, itemID: Int) -> String {
        "/downloadQueue/\(queueID)/item/\(itemID)/media"
    }
}
