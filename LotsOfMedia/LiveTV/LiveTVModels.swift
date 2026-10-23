import Foundation

// MARK: - DVR & channels

/// A DVR configured on the server (tuner device + guide lineup).
struct LiveDVR: Decodable, Hashable {
    var key: String
    var epgIdentifier: String          // e.g. "tv.plex.providers.epg.cloud:2"
    var lineupTitle: String?
    var tunerCount: Int
    var deviceModel: String?

    enum CodingKeys: String, CodingKey { case key, epgIdentifier, lineupTitle, Device }
    struct Device: Decodable { var tuners: String?; var model: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lossyString(.key) ?? ""
        epgIdentifier = c.lossyString(.epgIdentifier) ?? ""
        lineupTitle = c.lossyString(.lineupTitle)
        let devices = (try? c.decodeIfPresent([Device].self, forKey: .Device)) ?? []
        tunerCount = devices.compactMap { $0.tuners.flatMap(Int.init) }.reduce(0, +)
        deviceModel = devices.first?.model
    }
}

struct LiveChannel: Decodable, Hashable, Identifiable {
    var id: String          // lineup channel key; also what the tune endpoint takes
    var number: String      // "5.1"
    var title: String       // "CBS"
    var callSign: String?
    var thumb: String?
    var isHD: Bool

    enum CodingKeys: String, CodingKey { case id, vcn, title, callSign, thumb, isHd }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.id) ?? ""
        number = c.lossyString(.vcn) ?? ""
        title = c.lossyString(.title) ?? ""
        callSign = c.lossyString(.callSign)
        thumb = c.lossyString(.thumb)
        isHD = c.lossyBool(.isHd) ?? false
    }

    /// Numeric sort so 9.1 comes before 16.1.
    var sortKey: [Int] { number.split(separator: ".").map { Int($0) ?? 0 } }
}

// MARK: - Airings (guide entries)

/// One broadcast of a program on a channel.
struct LiveAiring: Decodable, Hashable, Identifiable {
    var ratingKey: String
    var key: String?
    var guid: String?
    var grandparentGuid: String?
    var type: String?
    var title: String
    var grandparentTitle: String?
    var summary: String?
    var contentRating: String?
    var year: Int?
    var index: Int?
    var parentIndex: Int?
    var art: String?
    var thumb: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var genres: [String]
    var beginsAt: Date
    var endsAt: Date
    var channelID: String
    var channelTitle: String?
    var channelNumber: String?
    var channelThumb: String?
    var isPremiere: Bool
    var resolution: String?

    var id: String { channelID + "@" + String(Int(beginsAt.timeIntervalSince1970)) }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, grandparentGuid, type, title, grandparentTitle, summary, contentRating, year, index, parentIndex
        case art, thumb, grandparentThumb, grandparentArt, Genre, Media
    }
    struct Tag: Decodable { var tag: String? }
    struct Airing: Decodable {
        var beginsAt: Int?, endsAt: Int?, channelIdentifier: String?, channelTitle: String?, channelVcn: String?
        var channelThumb: String?, premiere: String?, videoResolution: String?
        enum CodingKeys: String, CodingKey { case beginsAt, endsAt, channelIdentifier, channelTitle, channelVcn, channelThumb, premiere, videoResolution }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            beginsAt = c.lossyInt(.beginsAt); endsAt = c.lossyInt(.endsAt)
            channelIdentifier = c.lossyString(.channelIdentifier); channelTitle = c.lossyString(.channelTitle)
            channelVcn = c.lossyString(.channelVcn); channelThumb = c.lossyString(.channelThumb)
            premiere = c.lossyString(.premiere); videoResolution = c.lossyString(.videoResolution)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = Self.decodeAll(from: decoder)
        guard let first = all.first else {
            throw DecodingError.dataCorruptedError(forKey: .Media, in: c, debugDescription: "No airing")
        }
        self = first
    }

    /// A program's metadata can list several airings (one per Media); each becomes a LiveAiring.
    static func decodeAll(from decoder: Decoder) -> [LiveAiring] {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return [] }
        let media = c.lossyArray(Airing.self, .Media)
        var base = LiveAiring(
            ratingKey: c.lossyString(.ratingKey) ?? "", key: c.lossyString(.key), guid: c.lossyString(.guid),
            grandparentGuid: c.lossyString(.grandparentGuid), type: c.lossyString(.type), title: c.lossyString(.title) ?? "",
            grandparentTitle: c.lossyString(.grandparentTitle), summary: c.lossyString(.summary),
            contentRating: c.lossyString(.contentRating), year: c.lossyInt(.year), index: c.lossyInt(.index),
            parentIndex: c.lossyInt(.parentIndex), art: c.lossyString(.art), thumb: c.lossyString(.thumb),
            grandparentThumb: c.lossyString(.grandparentThumb), grandparentArt: c.lossyString(.grandparentArt),
            genres: c.lossyArray(Tag.self, .Genre).compactMap(\.tag), beginsAt: .distantPast, endsAt: .distantPast,
            channelID: "", isPremiere: false)
        return media.compactMap { m in
            guard let b = m.beginsAt, let e = m.endsAt, let ch = m.channelIdentifier else { return nil }
            base.beginsAt = Date(timeIntervalSince1970: TimeInterval(b))
            base.endsAt = Date(timeIntervalSince1970: TimeInterval(e))
            base.channelID = ch
            base.channelTitle = m.channelTitle
            base.channelNumber = m.channelVcn
            base.channelThumb = m.channelThumb
            base.isPremiere = m.premiere == "1"
            base.resolution = m.videoResolution
            return base
        }
    }

    private init(ratingKey: String, key: String?, guid: String?, grandparentGuid: String?, type: String?, title: String,
                 grandparentTitle: String?, summary: String?, contentRating: String?, year: Int?, index: Int?, parentIndex: Int?,
                 art: String?, thumb: String?, grandparentThumb: String?, grandparentArt: String?, genres: [String],
                 beginsAt: Date, endsAt: Date, channelID: String, isPremiere: Bool) {
        self.ratingKey = ratingKey; self.key = key; self.guid = guid; self.grandparentGuid = grandparentGuid
        self.type = type; self.title = title; self.grandparentTitle = grandparentTitle; self.summary = summary
        self.contentRating = contentRating; self.year = year; self.index = index; self.parentIndex = parentIndex
        self.art = art; self.thumb = thumb; self.grandparentThumb = grandparentThumb; self.grandparentArt = grandparentArt
        self.genres = genres; self.beginsAt = beginsAt; self.endsAt = endsAt; self.channelID = channelID; self.isPremiere = isPremiere
    }

    var isEpisode: Bool { type == "episode" }
    var isMovie: Bool { type == "movie" }
    /// Shows are the series name; episodes add their episode title below.
    var showTitle: String { isEpisode ? (grandparentTitle ?? title) : title }
    var episodeLine: String? {
        guard isEpisode else { return year.map(String.init) }
        let code = [parentIndex.map { "S\($0)" }, index.map { "E\($0)" }].compactMap { $0 }.joined()
        let name = (title == grandparentTitle) ? nil : title
        let parts = [code.isEmpty ? nil : code, name].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var backdrop: String? { art ?? grandparentArt ?? thumb }
    var poster: String? { grandparentThumb ?? thumb }

    func isOnAir(at date: Date = Date()) -> Bool { beginsAt <= date && date < endsAt }
    func progress(at date: Date = Date()) -> Double {
        let total = endsAt.timeIntervalSince(beginsAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(beginsAt) / total))
    }
    var timeRange: String { Fmt.timeRange(beginsAt, endsAt) }
}

/// Decodes Metadata arrays where each program may carry several airings.
struct LiveAiringList: Decodable {
    var airings: [LiveAiring]
    enum CodingKeys: String, CodingKey { case MediaContainer }
    enum MC: String, CodingKey { case Metadata }
    private struct Item: Decodable {
        var airings: [LiveAiring]
        init(from decoder: Decoder) throws { airings = LiveAiring.decodeAll(from: decoder) }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mc = try c.nestedContainer(keyedBy: MC.self, forKey: .MediaContainer)
        airings = ((try? mc.decodeIfPresent([Item].self, forKey: .Metadata)) ?? []).flatMap(\.airings)
    }
}

// MARK: - Recordings

/// A recording rule ("This Episode" or "All Episodes" of a show).
struct LiveSubscription: Decodable, Hashable, Identifiable {
    var id: String
    var type: Int                       // 4 = one episode/airing, 2 = series, 1 = movie
    var title: String                   // option name, e.g. "All Episodes"
    var airingsType: String?
    var itemTitle: String
    var itemThumb: String?
    var guid: String?
    var settings: [String: String]
    var upcoming: [ScheduledRecording]

    var isSeries: Bool { type == 2 }

    enum CodingKeys: String, CodingKey { case key, type, title, airingsType, Directory, Video, Setting, MediaGrabOperation }
    struct Item: Decodable {
        var title: String?, thumb: String?, guid: String?
        enum CodingKeys: String, CodingKey { case title, thumb, guid }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.lossyString(.title); thumb = c.lossyString(.thumb); guid = c.lossyString(.guid)
        }
    }
    struct Setting: Decodable {
        var id: String, value: String?
        enum CodingKeys: String, CodingKey { case id, value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.id) ?? ""; value = c.lossyString(.value)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.key) ?? ""
        type = c.lossyInt(.type) ?? 0
        title = c.lossyString(.title) ?? ""
        airingsType = c.lossyString(.airingsType)
        let item = (try? c.decodeIfPresent(Item.self, forKey: .Directory)) ?? (try? c.decodeIfPresent(Item.self, forKey: .Video))
        itemTitle = item?.title ?? title
        itemThumb = item?.thumb
        guid = item?.guid
        settings = Dictionary(c.lossyArray(Setting.self, .Setting).map { ($0.id, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        upcoming = c.lossyArray(ScheduledRecording.self, .MediaGrabOperation)
    }
}

/// One airing the server will record (or is recording).
struct ScheduledRecording: Decodable, Hashable, Identifiable {
    var id: String
    var subscriptionID: String?
    var status: String               // "scheduled", "inprogress", "error"…
    var airing: LiveAiring?
    var percent: Double?

    var isRecording: Bool { status == "inprogress" }

    enum CodingKeys: String, CodingKey { case id, mediaSubscriptionID, status, Metadata, percent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.id) ?? UUID().uuidString
        subscriptionID = c.lossyString(.mediaSubscriptionID)
        status = c.lossyString(.status) ?? "scheduled"
        percent = c.lossyDouble(.percent)
        airing = try? c.decodeIfPresent(LiveAiring.self, forKey: .Metadata)
    }
}

/// Options the server offers for recording a program ("This Episode", "All Episodes").
struct RecordingOption: Decodable, Hashable, Identifiable {
    var type: Int
    var title: String
    var parameters: String
    var targetLibrarySectionID: String?
    var targetSectionLocationID: String?
    var settings: [Setting]
    var isSeries: Bool { type == 2 }
    var id: Int { type }

    struct Setting: Decodable, Hashable {
        var id: String, value: String, choices: [(value: String, label: String)]
        enum CodingKeys: String, CodingKey { case id, value, enumValues }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lossyString(.id) ?? ""
            value = c.lossyString(.value) ?? ""
            choices = (c.lossyString(.enumValues) ?? "").split(separator: "|").compactMap { pair in
                let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1].removingPercentEncoding ?? parts[1])
            }
        }
        static func == (a: Setting, b: Setting) -> Bool { a.id == b.id && a.value == b.value }
        func hash(into h: inout Hasher) { h.combine(id); h.combine(value) }
    }

    enum CodingKeys: String, CodingKey { case type, title, parameters, targetLibrarySectionID, targetSectionLocationID, Setting }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lossyInt(.type) ?? 0
        title = c.lossyString(.title) ?? ""
        parameters = c.lossyString(.parameters) ?? ""
        targetLibrarySectionID = c.lossyString(.targetLibrarySectionID)
        targetSectionLocationID = c.lossyString(.targetSectionLocationID)
        settings = c.lossyArray(Setting.self, .Setting)
    }

    func setting(_ id: String) -> Setting? { settings.first { $0.id == id } }
}

/// Result of tuning a channel: the live session to stream.
struct LiveSession {
    var path: String            // "/livetv/sessions/<uuid>"
    var ratingKey: String
    var airing: LiveAiring?

    /// Reads a tune response. A response without a grab operation means no
    /// tuner could take the channel (busy, or no signal).
    static func parseTune(_ data: Data) throws -> LiveSession {
        struct Resp: Decodable {
            struct MC: Decodable {
                var message: String?
                var MediaSubscription: [Sub]?
            }
            struct Sub: Decodable { var MediaGrabOperation: [Op]? }
            struct Op: Decodable { var Metadata: Meta? }
            struct Meta: Decodable {
                var key: String?, ratingKey: String?
                enum CodingKeys: String, CodingKey { case key, ratingKey }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    key = c.lossyString(.key); ratingKey = c.lossyString(.ratingKey)
                }
            }
            var MediaContainer: MC
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let meta = resp.MediaContainer.MediaSubscription?.first?.MediaGrabOperation?.first?.Metadata,
              let key = meta.key else {
            throw PlexError.unsupported(resp.MediaContainer.message ?? "Couldn't tune this channel.")
        }
        // The full airing (with times) rides along in the same payload.
        struct AiringResp: Decodable {
            struct MC: Decodable { var MediaSubscription: [Sub]? }
            struct Sub: Decodable { var MediaGrabOperation: [Op]? }
            struct Op: Decodable { var Metadata: LiveAiring? }
            var MediaContainer: MC
        }
        let airing = (try? JSONDecoder().decode(AiringResp.self, from: data))?.MediaContainer.MediaSubscription?.first?.MediaGrabOperation?.first?.Metadata
        return LiveSession(path: key, ratingKey: meta.ratingKey ?? key, airing: airing)
    }

}

// MARK: - API

/// Decodes `MediaContainer.<key>` as an array, where the key is chosen at runtime.
private struct MediaContainerList<T: Decodable>: Decodable {
    static var keyInfo: CodingUserInfoKey { CodingUserInfoKey(rawValue: "mediaContainerKey")! }
    let items: [T]
    struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let mc = try c.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "MediaContainer"))
        let k = decoder.userInfo[Self.keyInfo] as? String ?? ""
        items = (try? mc.decodeIfPresent([T].self, forKey: Key(stringValue: k))) ?? []
    }
}

extension PlexServerAPI {
    private func decodeMC<T: Decodable>(_ type: T.Type, _ path: String, key: String, query: [URLQueryItem] = [],
                                       method: String = "GET", timeout: TimeInterval = 20) async throws -> [T] {
        let (data, _) = try await data(path, query: query, method: method, timeout: timeout)
        let decoder = JSONDecoder()
        decoder.userInfo[MediaContainerList<T>.keyInfo] = key
        return try decoder.decode(MediaContainerList<T>.self, from: data).items
    }

    func liveDVRs() async throws -> [LiveDVR] {
        // Live TV here is Plex's DVR; a Jellyfin server has no Live TV tab.
        if isJellyfin { return [] }
        return try await decodeMC(LiveDVR.self, "/livetv/dvrs", key: "Dvr")
    }

    func liveChannels(epg: String) async throws -> [LiveChannel] {
        try await decodeMC(LiveChannel.self, "/\(epg)/lineups/dvr/channels", key: "Channel")
            .sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
    }

    /// Guide entries overlapping [from, to).
    func liveGrid(epg: String, from: Date, to: Date) async throws -> [LiveAiring] {
        // ">" and "<" are part of Plex's filter syntax; escaped so URL parsing keeps them.
        let path = "/\(epg)/grid?type=1,4&endsAt%3E=\(Int(from.timeIntervalSince1970))&beginsAt%3C=\(Int(to.timeIntervalSince1970))"
        let (data, _) = try await data(path, timeout: 40)
        return try JSONDecoder().decode(LiveAiringList.self, from: data).airings
    }

    /// Every upcoming airing of a program (for "Other airings").
    func liveProgram(_ key: String) async throws -> [LiveAiring] {
        let (data, _) = try await data(key)
        return try JSONDecoder().decode(LiveAiringList.self, from: data).airings
    }

    /// Starts a live stream on a free tuner.
    func tune(dvr: String, channel: String) async throws -> LiveSession {
        let (data, _) = try await data("/livetv/dvrs/\(dvr)/channels/\(channel)/tune", method: "POST", timeout: 30)
        return try LiveSession.parseTune(data)
    }

    func recordingRules() async throws -> [LiveSubscription] {
        try await decodeMC(LiveSubscription.self, "/media/subscriptions", key: "MediaSubscription",
                           query: [URLQueryItem(name: "includeGrabs", value: "1")])
    }

    func scheduledRecordings() async throws -> [ScheduledRecording] {
        try await decodeMC(ScheduledRecording.self, "/media/subscriptions/scheduled", key: "MediaGrabOperation")
    }

    func recordingOptions(guid: String) async throws -> [RecordingOption] {
        let (data, _) = try await data("/media/subscriptions/template", query: [URLQueryItem(name: "guid", value: guid)])
        struct Resp: Decodable {
            struct MC: Decodable { var SubscriptionTemplate: [T]? }
            struct T: Decodable { var MediaSubscription: [RecordingOption]? }
            var MediaContainer: MC
        }
        return try JSONDecoder().decode(Resp.self, from: data).MediaContainer.SubscriptionTemplate?.first?.MediaSubscription ?? []
    }

    /// Creates a recording rule from a template option, with setting overrides.
    func createRecording(_ option: RecordingOption, prefs: [String: String], locationID: String?) async throws {
        var items = URLComponents(string: "?" + option.parameters)?.queryItems ?? []
        if let s = option.targetLibrarySectionID { items.append(URLQueryItem(name: "targetLibrarySectionID", value: s)) }
        if let l = option.targetSectionLocationID ?? locationID { items.append(URLQueryItem(name: "targetSectionLocationID", value: l)) }
        items.append(URLQueryItem(name: "includeGrabs", value: "1"))
        items.append(URLQueryItem(name: "type", value: "\(option.type)"))
        var merged = Dictionary(option.settings.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
        prefs.forEach { merged[$0] = $1 }
        for (k, v) in merged.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: "prefs[\(k)]", value: v)) }
        try await data("/media/subscriptions", query: items, method: "POST", timeout: 30)
    }

    func updateRecording(id: String, prefs: [String: String]) async throws {
        let items = prefs.map { URLQueryItem(name: "prefs[\($0)]", value: $1) }
        try await data("/media/subscriptions/\(id)", query: items, method: "PUT")
    }

    func deleteRecording(id: String) async throws {
        try await data("/media/subscriptions/\(id)", method: "DELETE")
    }

    /// First folder of a library section (new recordings are filed there).
    func sectionLocationID(_ sectionID: String) async -> String? {
        guard let (data, _) = try? await data("/library/sections/\(sectionID)") else { return nil }
        struct Resp: Decodable {
            struct MC: Decodable { var Directory: [D]? ; var Location: [L]? }
            struct D: Decodable { var Location: [L]? }
            struct L: Decodable {
                var id: String?
                enum CodingKeys: String, CodingKey { case id }
                init(from decoder: Decoder) throws { id = try decoder.container(keyedBy: CodingKeys.self).lossyString(.id) }
            }
            var MediaContainer: MC
        }
        guard let mc = (try? JSONDecoder().decode(Resp.self, from: data))?.MediaContainer else { return nil }
        return mc.Location?.first?.id ?? mc.Directory?.first?.Location?.first?.id
    }

    /// A library show matching a guide show (to set up downloads for its recordings).
    func libraryShow(guid: String) async -> PlexMetadata? {
        try? await container("/library/all", query: [URLQueryItem(name: "guid", value: guid), URLQueryItem(name: "type", value: "2")]).metadata.first
    }

    /// Prepares the server's conversion for `liveStreamURL` (must precede the stream request).
    func liveDecision(streamURL: URL) async throws {
        guard var comps = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = comps.path.replacingOccurrences(of: "start.m3u8", with: "decision")
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8))
        }
        struct D: Decodable {
            struct MC: Decodable { var generalDecisionCode: Int?; var generalDecisionText: String? }
            var MediaContainer: MC
        }
        // 1xxx = OK; 2xxx/3xxx/4xxx = the server can't convert this right now.
        if let mc = try? JSONDecoder().decode(D.self, from: data).MediaContainer, let code = mc.generalDecisionCode, code >= 2000 {
            throw PlexError.unsupported(mc.generalDecisionText ?? "Your server can't convert this channel right now.")
        }
    }

    /// Waits until the converted stream has its first segment, so the player
    /// doesn't give up on an empty playlist while the server warms up.
    func waitForLiveSegments(streamURL: URL, timeout: TimeInterval = 30) async throws {
        let (master, _) = try await Self.session.data(from: streamURL)
        guard let line = String(data: master, encoding: .utf8)?.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
              let variant = URL(string: String(line), relativeTo: streamURL) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let (data, resp) = try? await Self.session.data(from: variant), (resp as? HTTPURLResponse)?.statusCode == 200,
               String(data: data, encoding: .utf8)?.contains("#EXTINF") == true { return }
            try await Task.sleep(for: .milliseconds(700))
        }
        throw PlexError.unsupported("Your server didn't start the channel in time. It may be busy converting other videos.")
    }

    /// HLS stream of a live session, converted for iPhone.
    func liveStreamURL(session: LiveSession, sessionID: String, quality: StreamingQuality, isLocal: Bool) -> URL {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "path", value: session.path),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "location", value: isLocal ? "lan" : "wan"),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionID),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: PlaybackDecider.streamingProfileExtra),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
        ]
        // Broadcasts are 1080i MPEG-2: always re-encoded, so cap at 1080p unless the user chose lower.
        let bitrate = quality.bitrate ?? 8_000
        q += [
            URLQueryItem(name: "maxVideoBitrate", value: "\(bitrate)"),
            URLQueryItem(name: "videoBitrate", value: "\(bitrate)"),
            URLQueryItem(name: "videoResolution", value: quality.resolution),
            URLQueryItem(name: "videoQuality", value: "100"),
        ]
        q += PlexClient.queryItems(token: token)
        return url("/video/:/transcode/universal/start.m3u8", query: q)
    }
}

// MARK: - Categories

/// Program categories for filtering the guide, from each listing's genres and type.
enum GuideCategory: String, CaseIterable, Identifiable {
    case movies = "Movies", sports = "Sports", news = "News", kids = "Kids", series = "Series"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .movies: "film"
        case .sports: "sportscourt"
        case .news: "newspaper"
        case .kids: "figure.and.child.holdinghands"
        case .series: "tv"
        }
    }

    func matches(_ airing: LiveAiring) -> Bool {
        let genres = airing.genres.map { $0.lowercased() }
        func has(_ words: [String]) -> Bool { genres.contains { g in words.contains { g.contains($0) } } }
        switch self {
        case .movies: return airing.isMovie
        case .sports: return has(["sport", "football", "basketball", "baseball", "soccer", "hockey", "golf", "tennis", "racing", "wrestling", "boxing"])
        case .news: return has(["news", "weather", "public affairs"])
        case .kids: return has(["children", "kids", "animation", "family", "cartoon"])
        case .series: return airing.isEpisode && !has(["news", "sport"])
        }
    }
}
