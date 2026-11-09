import Foundation

enum StreamingQuality: String, CaseIterable, Identifiable {
    case original, q20, q12, q8, q4, q2, q1
    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original (Direct Play)"
        case .q20: return "1080p · 20 Mbps"
        case .q12: return "1080p · 12 Mbps"
        case .q8: return "1080p · 8 Mbps"
        case .q4: return "720p · 4 Mbps"
        case .q2: return "720p · 2 Mbps"
        case .q1: return "480p · 1 Mbps"
        }
    }

    var bitrate: Int? {
        switch self {
        case .original: return nil
        case .q20: return 20_000
        case .q12: return 12_000
        case .q8: return 8_000
        case .q4: return 4_000
        case .q2: return 2_000
        case .q1: return 1_000
        }
    }

    var resolution: String {
        switch self {
        case .original, .q20, .q12, .q8: return "1920x1080"
        case .q4, .q2: return "1280x720"
        case .q1: return "854x480"
        }
    }
}

/// Playback speeds offered for video (both players, iPhone and Apple TV).
enum PlaybackSpeeds {
    static let video: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]
}

/// "+150 ms", "−50 ms", "Off" for the audio sync offset.
enum AudioSyncLabel {
    static func text(_ ms: Int) -> String { ms == 0 ? "Off" : (ms > 0 ? "+\(ms) ms" : "−\(-ms) ms") }
}

enum PlaybackDecider {
    static let nativeVideoContainers: Set<String> = ["mp4", "m4v", "mov"]
    static let nativeVideoCodecs: Set<String> = ["h264", "hevc", "h265", "mpeg4"]
    static let nativeAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac", "pcm"]
    static let nativeAudioContainers: Set<String> = ["mp3", "m4a", "mp4", "aac", "flac", "alac", "wav", "aiff", "caf"]
    static let nativeTextSubtitleCodecs: Set<String> = ["mov_text", "tx3g"]

    /// Whether AVFoundation can play this media as-is (used for direct play and download decisions).
    static func canPlayNatively(media: PlexMedia, kind: PlexMetadata.Kind) -> Bool {
        incompatibilities(media: media, kind: kind).isEmpty
    }

    /// What iOS can't play about this media, in plain words ("MKV files",
    /// "DTS audio"). Empty means the file plays as-is.
    static func incompatibilities(media: PlexMedia, kind: PlexMetadata.Kind) -> [String] {
        let container = (media.container ?? media.parts.first?.container ?? "").lowercased()
        if kind == .track {
            return nativeAudioContainers.contains(container) || container.isEmpty ? [] : ["\(displayName(container)) audio files"]
        }
        var problems: [String] = []
        if !nativeVideoContainers.contains(container) { problems.append("\(displayName(container.isEmpty ? "this" : container)) files") }
        if let v = media.videoCodec?.lowercased(), !nativeVideoCodecs.contains(v) { problems.append("\(displayName(v)) video") }
        let audio = [media.audioCodec, media.parts.first?.selectedAudio?.codec].compactMap { $0?.lowercased() }
        if let a = audio.first(where: { !nativeAudioCodecs.contains($0) }) { problems.append("\(displayName(a)) audio") }
        if media.parts.count > 1 { problems.append("files split into parts") }
        return problems
    }

    /// Whether a file plays on this iPhone as-is: in Apple's player, or else in the built-in player.
    static func canPlayOnDevice(media: PlexMedia, kind: PlexMetadata.Kind) -> Bool {
        canPlayNatively(media: media, kind: kind) || BuiltInPlayer.canPlay(media: media, kind: kind)
    }

    /// One sentence for files only the built-in player can play (no AirPlay or picture-in-picture for them).
    static func builtInPlayerNote(media: PlexMedia, kind: PlexMetadata.Kind) -> String? {
        let problems = incompatibilities(media: media, kind: kind)
        guard !problems.isEmpty, BuiltInPlayer.canPlay(media: media, kind: kind) else { return nil }
        return "Plays in the built-in player (" + ListFormatter.localizedString(byJoining: problems).replacingOccurrences(of: " and ", with: ", ")
            + "). AirPlay and picture-in-picture aren't available for this file."
    }

    /// One sentence explaining why the server converts a download.
    static func conversionReason(media: PlexMedia, kind: PlexMetadata.Kind, quality: DownloadQuality) -> String? {
        let problems = incompatibilities(media: media, kind: kind)
        if !problems.isEmpty, !BuiltInPlayer.canPlay(media: media, kind: kind) {
            return "iPhone can't play " + ListFormatter.localizedString(byJoining: problems).replacingOccurrences(of: " and ", with: " or ")
        }
        if quality != .original, let h = quality.targetHeight { return "Making a smaller \(h)p copy" }
        return nil
    }

    private static func displayName(_ codec: String) -> String {
        switch codec {
        case "dca", "dts", "dts-hd": return "DTS"
        case "truehd": return "Dolby TrueHD"
        case "vc1": return "VC-1"
        case "mpeg2video": return "MPEG-2"
        case "mpeg1video": return "MPEG-1"
        case "msmpeg4", "msmpeg4v2", "msmpeg4v3", "divx", "xvid": return "DivX/Xvid"
        case "wmv3", "wmv2": return "WMV"
        case "wmapro", "wmav2": return "WMA"
        case "av1": return "AV1"
        case "vp9", "vp8": return codec.uppercased()
        case "opus", "vorbis": return codec.capitalized
        case "this": return "these"
        default: return codec.uppercased()
        }
    }

    /// Direct play requires native media, an "original" quality setting, and
    /// that any selected subtitle can be rendered by AVPlayer (otherwise burn-in).
    static func shouldDirectPlay(_ item: PlexMetadata, quality: StreamingQuality) -> Bool {
        guard quality == .original, let media = item.primaryMedia, media.parts.count == 1 else { return false }
        guard canPlayNatively(media: media, kind: item.kind) else { return false }
        if let sub = media.parts.first?.selectedSubtitle, !sub.isSidecarText {
            // Sidecar text is drawn by the app; anything else embedded must be MP4 text.
            if let codec = sub.codec?.lowercased(), !nativeTextSubtitleCodecs.contains(codec) { return false }
        }
        if let audio = media.parts.first?.selectedAudio, let codec = audio.codec?.lowercased(), !nativeAudioCodecs.contains(codec) {
            return false
        }
        return true
    }

    static let streamingProfileExtra = streamingProfile(hevc: true)

    /// `hevc: false` asks for H.264 only: Apple's player doesn't accept every HEVC stream the
    /// server copies into MPEG-TS, so a conversion that failed is retried without it.
    static func streamingProfile(hevc: Bool) -> String {
        [
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=\(hevc ? "h264,hevc" : "h264")&audioCodec=aac,ac3,eac3)",
            "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac,mp3)",
        ].joined(separator: "+")
    }

    /// `burnSubtitleID`: subtitle stream the server burns in; nil = no subtitles in the
    /// video (sidecar text is drawn by the app instead).
    static func transcodeURL(api: PlexServerAPI, item: PlexMetadata, quality: StreamingQuality, sessionID: String,
                             isLocal: Bool, music: Bool = false, musicBitrate: Int = 0, burnSubtitleID: Int? = nil,
                             allowHEVC: Bool = true) -> URL {
        if api.isJellyfin {
            return JellyfinBridge.transcodeURL(api: api, item: item, quality: quality, sessionID: sessionID, music: music,
                                               musicBitrate: musicBitrate, burnSubtitleID: burnSubtitleID, allowHEVC: allowHEVC)
        }
        var q: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "\(item.primaryMediaIndex)"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "subtitles", value: burnSubtitleID == nil ? "none" : "burn"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "location", value: isLocal ? "lan" : "wan"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: streamingProfile(hevc: allowHEVC)),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
        ]
        if music && musicBitrate > 0 {
            q.removeAll { ["directStream", "directStreamAudio"].contains($0.name) }
            q += [URLQueryItem(name: "directStream", value: "0"), URLQueryItem(name: "directStreamAudio", value: "0"),
                  URLQueryItem(name: "audioBitrate", value: "\(musicBitrate)"), URLQueryItem(name: "maxAudioBitrate", value: "\(musicBitrate)")]
        }
        if let bitrate = quality.bitrate {
            q += [
                URLQueryItem(name: "maxVideoBitrate", value: "\(bitrate)"),
                URLQueryItem(name: "videoBitrate", value: "\(bitrate)"),
                URLQueryItem(name: "videoResolution", value: quality.resolution),
                URLQueryItem(name: "videoQuality", value: "100"),
            ]
        } else {
            q += [URLQueryItem(name: "maxVideoBitrate", value: "200000"), URLQueryItem(name: "videoQuality", value: "100")]
        }
        if let burnSubtitleID { q.append(URLQueryItem(name: "subtitleStreamID", value: "\(burnSubtitleID)")) }
        q += PlexClient.queryItems(token: api.token)
        let path = music ? "/music/:/transcode/universal/start.m3u8" : "/video/:/transcode/universal/start.m3u8"
        return api.url(path, query: q)
    }

    static func directURL(api: PlexServerAPI, item: PlexMetadata) -> URL? {
        guard let key = item.primaryPart?.key else { return nil }
        return api.url(key, query: PlexClient.queryItems(token: api.token))
    }
}

/// Tracks for the built-in player, chosen before the file opens.
enum VLCTrackChoice {
    /// The position of the audio track chosen in Plex among the file's audio tracks (VLC's
    /// `:audio-track` numbering), or nil to let VLC pick (Plex's choice is the first anyway).
    static func audioIndex(in item: PlexMetadata) -> Int? {
        guard let part = item.primaryPart, let chosen = part.selectedAudio,
              let n = part.audioStreams.firstIndex(where: { $0.id == chosen.id }), n > 0 else { return nil }
        return n
    }

    /// The Plex language of the audio track at this position in VLC's list, to remember a choice.
    static func audioLanguage(atPosition n: Int, in part: PlexPart) -> String? {
        part.audioStreams.indices.contains(n) ? part.audioStreams[n].languageCode : nil
    }

    /// The same for subtitles. VLC lists the file's own tracks first, then the added sidecar files.
    static func subtitleLanguage(atPosition n: Int, in part: PlexPart) -> String? {
        let ordered = part.subtitleStreams.filter { $0.key == nil } + part.subtitleStreams.filter { $0.key != nil }
        return ordered.indices.contains(n) ? ordered[n].languageCode : nil
    }
}

/// Even Out Volume: the built-in player levels loud and quiet videos (and loud scenes against
/// dialogue) with VLC's dynamic range compressor, so moving between videos doesn't need the
/// remote's volume. On unless turned off in settings.
enum VolumeLeveling {
    static let preferenceKey = "playback.video.evenOutVolume"
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// Louder than about -20 dB is turned down 4:1, then everything is lifted 8 dB, so quiet
    /// files come up and loud ones come down toward the same level.
    static let vlcOptions = [
        ":audio-filter=compressor",
        ":compressor-rms-peak=0.2", ":compressor-attack=25", ":compressor-release=150",
        ":compressor-threshold=-20", ":compressor-ratio=4", ":compressor-knee=5", ":compressor-makeup-gain=8",
    ]
}
