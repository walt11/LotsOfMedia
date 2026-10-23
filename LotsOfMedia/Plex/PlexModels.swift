import Foundation

// MARK: - Container

struct PlexResponse: Decodable {
    let MediaContainer: PlexContainer
}

struct PlexContainer: Decodable {
    var size: Int?
    var totalSize: Int?
    var offset: Int?
    var title1: String?
    var title2: String?
    var identifier: String?
    var machineIdentifier: String?
    var friendlyName: String?
    var version: String?
    var librarySectionID: Int?
    var viewGroup: String?
    /// Set on play queue responses.
    var playQueueID: Int?
    var metadata: [PlexMetadata]
    var directories: [PlexDirectory]
    var hubs: [PlexHub]
    var downloadQueues: [DownloadQueueInfo]
    /// Subtitle search results (`/library/metadata/{id}/subtitles`).
    var streams: [PlexStream]
    var downloadQueueItems: [DownloadQueueItemInfo]
    var addedQueueItems: [DownloadQueueItemInfo]

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, title1, title2, identifier, machineIdentifier, friendlyName, version
        case librarySectionID, viewGroup, playQueueID
        case Metadata, Directory, Hub, DownloadQueue, DownloadQueueItem, AddedQueueItems, Stream
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = c.lossyInt(.size)
        totalSize = c.lossyInt(.totalSize)
        offset = c.lossyInt(.offset)
        title1 = c.lossyString(.title1)
        title2 = c.lossyString(.title2)
        identifier = c.lossyString(.identifier)
        machineIdentifier = c.lossyString(.machineIdentifier)
        friendlyName = c.lossyString(.friendlyName)
        version = c.lossyString(.version)
        librarySectionID = c.lossyInt(.librarySectionID)
        viewGroup = c.lossyString(.viewGroup)
        playQueueID = c.lossyInt(.playQueueID)
        metadata = c.lossyArray(PlexMetadata.self, .Metadata)
        directories = c.lossyArray(PlexDirectory.self, .Directory)
        hubs = c.lossyArray(PlexHub.self, .Hub)
        downloadQueues = c.lossyArray(DownloadQueueInfo.self, .DownloadQueue)
        streams = c.lossyArray(PlexStream.self, .Stream)
        downloadQueueItems = c.lossyArray(DownloadQueueItemInfo.self, .DownloadQueueItem)
        addedQueueItems = c.lossyArray(DownloadQueueItemInfo.self, .AddedQueueItems)
    }
}

// MARK: - Server-side download queue (PMS >= 1.41.9)

struct DownloadQueueInfo: Decodable {
    var id: Int
    var status: String?
    enum CodingKeys: String, CodingKey { case id, status }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        status = c.lossyString(.status)
    }
}

struct DownloadQueueItemInfo: Decodable {
    struct Transcode: Decodable {
        var progress: Double?
        var size: Int64?
        var complete: Bool?
        enum CodingKeys: String, CodingKey { case progress, size, complete }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            progress = c.lossyDouble(.progress)
            size = c.lossyInt64(.size)
            complete = c.lossyBool(.complete)
        }
    }
    var id: Int
    var key: String?
    /// deciding | waiting | processing | available | error | expired
    var status: String?
    var error: String?
    var transcodeSession: Transcode?

    enum CodingKeys: String, CodingKey { case id, key, status, error, TranscodeSession }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        key = c.lossyString(.key)
        status = c.lossyString(.status)
        error = c.lossyString(.error)
        transcodeSession = try? c.decodeIfPresent(Transcode.self, forKey: .TranscodeSession)
    }
}

// MARK: - Library sections / directories

struct PlexDirectory: Codable, Hashable, Identifiable {
    var key: String
    var title: String
    var type: String?
    var thumb: String?
    var art: String?
    var uuid: String?
    var agent: String?
    var fastKey: String?
    var count: Int?

    var id: String { key + (uuid ?? "") }

    enum CodingKeys: String, CodingKey { case key, title, type, thumb, art, uuid, agent, fastKey, count }

    init(key: String, title: String, type: String?) {
        self.key = key; self.title = title; self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lossyString(.key) ?? ""
        title = c.lossyString(.title) ?? ""
        type = c.lossyString(.type)
        thumb = c.lossyString(.thumb)
        art = c.lossyString(.art)
        uuid = c.lossyString(.uuid)
        agent = c.lossyString(.agent)
        fastKey = c.lossyString(.fastKey)
        count = c.lossyInt(.count)
    }

    var systemImage: String {
        switch type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo.on.rectangle"
        default: return "folder"
        }
    }
}

// MARK: - Hubs

struct PlexHub: Decodable, Identifiable {
    var hubIdentifier: String?
    var title: String
    var type: String?
    var key: String?
    var size: Int?
    var more: Bool?
    var style: String?
    var metadata: [PlexMetadata]
    var directories: [PlexDirectory]

    var id: String { (hubIdentifier ?? "") + title + (key ?? "") }

    enum CodingKeys: String, CodingKey { case hubIdentifier, title, type, key, size, more, style, Metadata, Directory }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubIdentifier = c.lossyString(.hubIdentifier)
        title = c.lossyString(.title) ?? ""
        type = c.lossyString(.type)
        key = c.lossyString(.key)
        size = c.lossyInt(.size)
        more = c.lossyBool(.more)
        style = c.lossyString(.style)
        metadata = c.lossyArray(PlexMetadata.self, .Metadata)
        directories = c.lossyArray(PlexDirectory.self, .Directory)
    }
}

// MARK: - Metadata

struct PlexTag: Codable, Hashable {
    var tag: String
    var thumb: String?
    var role: String?
    /// Library filter for this tag, e.g. "genre=27".
    var filter: String?

    enum CodingKeys: String, CodingKey { case tag, thumb, role, filter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = c.lossyString(.tag) ?? ""
        thumb = c.lossyString(.thumb)
        role = c.lossyString(.role)
        filter = c.lossyString(.filter)
    }
}

/// Intro / credits markers (PMS intro & credit detection).
struct PlexMarker: Codable, Hashable {
    var type: String
    var startTimeOffset: Int
    var endTimeOffset: Int
    var final: Bool?

    enum CodingKeys: String, CodingKey { case type, startTimeOffset, endTimeOffset, final }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lossyString(.type) ?? ""
        startTimeOffset = c.lossyInt(.startTimeOffset) ?? 0
        endTimeOffset = c.lossyInt(.endTimeOffset) ?? 0
        final = c.lossyBool(.final)
    }
    var isIntro: Bool { type == "intro" }
    var isCredits: Bool { type == "credits" || type == "credit" }
}

/// A chapter mark in a video (requested with includeChapters=1).
struct PlexChapter: Codable, Hashable {
    var title: String
    var startTimeOffset: Int
    var endTimeOffset: Int?
    enum CodingKeys: String, CodingKey { case tag, startTimeOffset, endTimeOffset, index }
    init(title: String, startTimeOffset: Int, endTimeOffset: Int?) {
        self.title = title; self.startTimeOffset = startTimeOffset; self.endTimeOffset = endTimeOffset
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTimeOffset = c.lossyInt(.startTimeOffset) ?? 0
        endTimeOffset = c.lossyInt(.endTimeOffset)
        title = c.lossyString(.tag) ?? "Chapter \(c.lossyInt(.index) ?? 0)"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .tag)
        try c.encode(startTimeOffset, forKey: .startTimeOffset)
        try c.encodeIfPresent(endTimeOffset, forKey: .endTimeOffset)
    }
}

struct PlexStream: Codable, Hashable, Identifiable {
    var id: Int
    var streamType: Int          // 1 video, 2 audio, 3 subtitle
    var codec: String?
    var language: String?
    var languageCode: String?
    var displayTitle: String?
    var extendedDisplayTitle: String?
    var title: String?
    var selected: Bool?
    var isDefault: Bool?
    var forced: Bool?
    var key: String?             // set for external (sidecar) subtitles
    var channels: Int?
    /// Video only: transfer characteristics ("smpte2084" = HDR10/PQ, "arib-std-b67" = HLG).
    var colorTrc: String?
    var doviPresent: Bool?
    var bitrate: Int?
    /// Video only: frames per second (23.976, 25, 59.94…).
    var frameRate: Double?
    /// Audio only: the server's loudness analysis — gain (dB) to bring the track (or its
    /// album) to a common level.
    var gain: Double?
    var albumGain: Double?
    /// Subtitle search results only.
    var providerTitle: String?
    var score: Double?
    var hearingImpaired: Bool?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, language, languageCode, displayTitle, extendedDisplayTitle, title, selected, key, channels, forced
        case providerTitle, score, hearingImpaired, colorTrc, bitrate, frameRate, gain, albumGain
        case doviPresent = "DOVIPresent"
        case isDefault = "default"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        streamType = c.lossyInt(.streamType) ?? 0
        codec = c.lossyString(.codec)
        language = c.lossyString(.language)
        languageCode = c.lossyString(.languageCode)
        displayTitle = c.lossyString(.displayTitle)
        extendedDisplayTitle = c.lossyString(.extendedDisplayTitle)
        title = c.lossyString(.title)
        selected = c.lossyBool(.selected)
        isDefault = c.lossyBool(.isDefault)
        forced = c.lossyBool(.forced)
        key = c.lossyString(.key)
        channels = c.lossyInt(.channels)
        colorTrc = c.lossyString(.colorTrc)
        doviPresent = c.lossyBool(.doviPresent)
        bitrate = c.lossyInt(.bitrate)
        frameRate = c.lossyDouble(.frameRate)
        gain = c.lossyDouble(.gain)
        albumGain = c.lossyDouble(.albumGain)
        providerTitle = c.lossyString(.providerTitle)
        score = c.lossyDouble(.score)
        hearingImpaired = c.lossyBool(.hearingImpaired)
    }

    var label: String { extendedDisplayTitle ?? displayTitle ?? language ?? "Track \(id)" }

    static let textSubtitleCodecs: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "smi", "sami", "txt", "text"]
    /// A sidecar text subtitle the app can fetch from the server and draw itself.
    var isSidecarText: Bool { key != nil && Self.textSubtitleCodecs.contains((codec ?? "").lowercased()) }
}

struct PlexPart: Codable, Hashable {
    var id: Int
    var key: String?
    var duration: Int?
    var file: String?
    var size: Int64?
    var container: String?
    var streams: [PlexStream]

    enum CodingKeys: String, CodingKey { case id, key, duration, file, size, container, streams = "Stream" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        key = c.lossyString(.key)
        duration = c.lossyInt(.duration)
        file = c.lossyString(.file)
        size = c.lossyInt64(.size)
        container = c.lossyString(.container)
        streams = c.lossyArray(PlexStream.self, .streams)
    }

    var audioStreams: [PlexStream] { streams.filter { $0.streamType == 2 } }
    var subtitleStreams: [PlexStream] { streams.filter { $0.streamType == 3 } }
    var selectedAudio: PlexStream? { audioStreams.first { $0.selected == true } ?? audioStreams.first }
    var selectedSubtitle: PlexStream? { subtitleStreams.first { $0.selected == true } }
}

struct PlexMedia: Codable, Hashable {
    var id: Int
    var duration: Int?
    var bitrate: Int?
    var width: Int?
    var height: Int?
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var audioChannels: Int?
    var videoResolution: String?
    var optimizedForStreaming: Bool?
    var parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, width, height, container, videoCodec, audioCodec, audioChannels, videoResolution, optimizedForStreaming
        case parts = "Part"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        duration = c.lossyInt(.duration)
        bitrate = c.lossyInt(.bitrate)
        width = c.lossyInt(.width)
        height = c.lossyInt(.height)
        container = c.lossyString(.container)
        videoCodec = c.lossyString(.videoCodec)
        audioCodec = c.lossyString(.audioCodec)
        audioChannels = c.lossyInt(.audioChannels)
        videoResolution = c.lossyString(.videoResolution)
        optimizedForStreaming = c.lossyBool(.optimizedForStreaming)
        parts = c.lossyArray(PlexPart.self, .parts)
    }

    /// Resolution class Plex assigns ("1080", "720", "4k"…) as a line count.
    /// Uses the class rather than pixel height so a 1920×800 scope film counts as 1080p.
    var resolutionClass: Int? {
        switch videoResolution?.lowercased() {
        case "4k": return 2160
        case "sd": return 480
        case let r?: if let n = Int(r.replacingOccurrences(of: "p", with: "")) { return n }
        case nil: break
        }
        guard let height else { return nil }
        if let width, width >= 1800 { return max(height, 1080) }   // widescreen 1080p
        if let width, width >= 1200 { return max(height, 720) }
        return height
    }

    var resolutionLabel: String? {
        guard let r = videoResolution else { return nil }
        switch r.lowercased() {
        case "4k": return "4K"
        case "sd": return "SD"
        default: return r.hasSuffix("p") ? r : r + "p"
        }
    }
}

struct PlexMetadata: Codable, Hashable, Identifiable {
    var ratingKey: String
    var key: String?
    var guid: String?
    /// The season's and show's Plex guids (episodes and seasons), for the Watchlist.
    var parentGuid: String?
    var grandparentGuid: String?
    var type: String?
    var subtype: String?
    var title: String
    var titleSort: String?
    var originalTitle: String?
    var summary: String?
    var tagline: String?
    var year: Int?
    var index: Int?
    var parentIndex: Int?
    var parentTitle: String?
    var grandparentTitle: String?
    var parentRatingKey: String?
    var grandparentRatingKey: String?
    var parentKey: String?
    var grandparentKey: String?
    var thumb: String?
    var art: String?
    var parentThumb: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var duration: Int?
    var viewOffset: Int?
    var viewCount: Int?
    var leafCount: Int?
    var viewedLeafCount: Int?
    var childCount: Int?
    var addedAt: Int?
    var lastViewedAt: Int?
    /// History entries only.
    var viewedAt: Int?
    var originallyAvailableAt: String?
    var contentRating: String?
    var studio: String?
    var rating: Double?
    var audienceRating: Double?
    var librarySectionID: Int?
    var librarySectionTitle: String?
    var playlistItemID: String?
    var playlistType: String?
    var smart: Bool?
    var composite: String?
    var media: [PlexMedia]
    var genres: [PlexTag]
    var directors: [PlexTag]
    var roles: [PlexTag]
    var markers: [PlexMarker] = []
    var chapters: [PlexChapter] = []

    var id: String { ratingKey.isEmpty ? (key ?? title) : ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, parentGuid, grandparentGuid, type, subtype, title, titleSort, originalTitle, summary, tagline, year, index, parentIndex
        case parentTitle, grandparentTitle, parentRatingKey, grandparentRatingKey, parentKey, grandparentKey
        case thumb, art, parentThumb, grandparentThumb, grandparentArt, duration, viewOffset, viewCount
        case leafCount, viewedLeafCount, childCount, addedAt, lastViewedAt, viewedAt, originallyAvailableAt, contentRating
        case studio, rating, audienceRating, librarySectionID, librarySectionTitle, playlistType, playlistItemID, smart, composite
        case media = "Media", genres = "Genre", directors = "Director", roles = "Role", markers = "Marker", chapters = "Chapter"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ratingKey = c.lossyString(.ratingKey) ?? ""
        key = c.lossyString(.key)
        guid = c.lossyString(.guid)
        parentGuid = c.lossyString(.parentGuid)
        grandparentGuid = c.lossyString(.grandparentGuid)
        type = c.lossyString(.type)
        subtype = c.lossyString(.subtype)
        title = c.lossyString(.title) ?? ""
        titleSort = c.lossyString(.titleSort)
        originalTitle = c.lossyString(.originalTitle)
        summary = c.lossyString(.summary)
        tagline = c.lossyString(.tagline)
        year = c.lossyInt(.year)
        index = c.lossyInt(.index)
        parentIndex = c.lossyInt(.parentIndex)
        parentTitle = c.lossyString(.parentTitle)
        grandparentTitle = c.lossyString(.grandparentTitle)
        parentRatingKey = c.lossyString(.parentRatingKey)
        grandparentRatingKey = c.lossyString(.grandparentRatingKey)
        parentKey = c.lossyString(.parentKey)
        grandparentKey = c.lossyString(.grandparentKey)
        thumb = c.lossyString(.thumb)
        art = c.lossyString(.art)
        parentThumb = c.lossyString(.parentThumb)
        grandparentThumb = c.lossyString(.grandparentThumb)
        grandparentArt = c.lossyString(.grandparentArt)
        duration = c.lossyInt(.duration)
        viewOffset = c.lossyInt(.viewOffset)
        viewCount = c.lossyInt(.viewCount)
        leafCount = c.lossyInt(.leafCount)
        viewedLeafCount = c.lossyInt(.viewedLeafCount)
        childCount = c.lossyInt(.childCount)
        addedAt = c.lossyInt(.addedAt)
        lastViewedAt = c.lossyInt(.lastViewedAt)
        viewedAt = c.lossyInt(.viewedAt)
        originallyAvailableAt = c.lossyString(.originallyAvailableAt)
        contentRating = c.lossyString(.contentRating)
        studio = c.lossyString(.studio)
        rating = c.lossyDouble(.rating)
        audienceRating = c.lossyDouble(.audienceRating)
        librarySectionID = c.lossyInt(.librarySectionID)
        librarySectionTitle = c.lossyString(.librarySectionTitle)
        playlistItemID = c.lossyString(.playlistItemID)
        playlistType = c.lossyString(.playlistType)
        smart = c.lossyBool(.smart)
        composite = c.lossyString(.composite)
        media = c.lossyArray(PlexMedia.self, .media)
        genres = c.lossyArray(PlexTag.self, .genres)
        directors = c.lossyArray(PlexTag.self, .directors)
        roles = c.lossyArray(PlexTag.self, .roles)
        markers = c.lossyArray(PlexMarker.self, .markers)
        chapters = c.lossyArray(PlexChapter.self, .chapters).sorted { $0.startTimeOffset < $1.startTimeOffset }
    }

    static func == (a: PlexMetadata, b: PlexMetadata) -> Bool {
        a.ratingKey == b.ratingKey && a.key == b.key && a.viewOffset == b.viewOffset && a.viewCount == b.viewCount
            && a.viewedLeafCount == b.viewedLeafCount
    }
    func hash(into h: inout Hasher) { h.combine(ratingKey); h.combine(key) }
}

extension PlexMetadata {
    /// Drops data that's only useful online (full stream lists, long cast lists)
    /// so persisted download records stay small.
    func trimmedForStorage() -> PlexMetadata {
        var m = self
        m.roles = Array(roles.prefix(12))
        m.directors = Array(directors.prefix(3))
        m.genres = Array(genres.prefix(4))
        for i in m.media.indices {
            for j in m.media[i].parts.indices {
                // Keep only a song's loudness gain, so Sound Check works for downloads offline.
                m.media[i].parts[j].streams = kind == .track
                    ? m.media[i].parts[j].streams.filter { $0.streamType == 2 && ($0.gain != nil || $0.albumGain != nil) }.prefix(1).map { $0 }
                    : []
            }
        }
        return m
    }

    enum Kind { case movie, show, season, episode, artist, album, track, photo, photoAlbum, clip, playlist, collection, other }

    var kind: Kind {
        switch type {
        case "movie": return .movie
        case "show": return .show
        case "season": return .season
        case "episode": return .episode
        case "artist": return .artist
        case "album": return .album
        case "track": return .track
        case "photo": return .photo
        case "photoalbum": return .photoAlbum
        case "clip": return .clip
        case "playlist": return .playlist
        case "collection": return .collection
        default: return .other
        }
    }

    var isPlayableVideo: Bool { [.movie, .episode, .clip].contains(kind) }
    var isLeaf: Bool { [.movie, .episode, .clip, .track, .photo].contains(kind) }
    var isWatched: Bool {
        if let leafCount, leafCount > 0, let viewedLeafCount { return viewedLeafCount >= leafCount }
        return (viewCount ?? 0) > 0
    }
    var progress: Double? {
        guard let viewOffset, let duration, duration > 0, viewOffset > 0 else { return nil }
        return min(1, Double(viewOffset) / Double(duration))
    }
    var unwatchedCount: Int? {
        guard let leafCount, let viewedLeafCount else { return nil }
        return max(0, leafCount - viewedLeafCount)
    }

    /// Poster-style art, preferring the show's poster for episodes.
    var posterThumb: String? {
        switch kind {
        case .episode: return grandparentThumb ?? parentThumb ?? thumb
        case .season: return thumb ?? parentThumb
        case .track: return parentThumb ?? thumb ?? grandparentThumb
        case .playlist: return thumb ?? composite
        default: return thumb
        }
    }

    var backdrop: String? { art ?? grandparentArt }

    var displayTitle: String {
        if kind == .episode, let gp = grandparentTitle { return gp }
        return title
    }

    var subtitleLine: String? {
        switch kind {
        case .episode:
            let code = [parentIndex.map { "S\($0)" }, index.map { "E\($0)" }].compactMap { $0 }.joined()
            return code.isEmpty ? title : "\(code) · \(title)"
        case .season: return parentTitle
        case .album: return parentTitle ?? year.map(String.init)
        case .track: return grandparentTitle ?? parentTitle
        default: return year.map(String.init)
        }
    }

    var primaryMedia: PlexMedia? { media.first }
    var primaryPart: PlexPart? { media.first?.parts.first }
}

// MARK: - plex.tv resources

struct PlexConnection: Codable, Hashable {
    var `protocol`: String?
    var address: String?
    var port: Int?
    var uri: String
    var local: Bool
    var relay: Bool
    var IPv6: Bool?

    init(uri: String, local: Bool, relay: Bool) {
        self.uri = uri; self.local = local; self.relay = relay
    }

    enum CodingKeys: String, CodingKey { case `protocol`, address, port, uri, local, relay, IPv6 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocol = c.lossyString(.protocol)
        address = c.lossyString(.address)
        port = c.lossyInt(.port)
        uri = c.lossyString(.uri) ?? ""
        local = c.lossyBool(.local) ?? false
        relay = c.lossyBool(.relay) ?? false
        IPv6 = c.lossyBool(.IPv6)
    }

    /// Lower is better: local direct, then remote direct https, remote http, relay.
    var rank: Int {
        if relay { return 4 }
        if local { return uri.hasPrefix("https") ? 0 : 1 }
        return uri.hasPrefix("https") ? 2 : 3
    }
}

struct PlexServer: Codable, Hashable, Identifiable {
    var name: String
    var clientIdentifier: String
    var accessToken: String?
    var owned: Bool
    var productVersion: String?
    var presence: Bool?
    var connections: [PlexConnection]
    var isManual: Bool = false

    var id: String { clientIdentifier }

    enum CodingKeys: String, CodingKey { case name, clientIdentifier, accessToken, owned, productVersion, presence, connections, isManual, provides }

    init(name: String, clientIdentifier: String, accessToken: String?, owned: Bool, connections: [PlexConnection], isManual: Bool) {
        self.name = name; self.clientIdentifier = clientIdentifier; self.accessToken = accessToken
        self.owned = owned; self.connections = connections; self.isManual = isManual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lossyString(.name) ?? "Plex Server"
        clientIdentifier = c.lossyString(.clientIdentifier) ?? UUID().uuidString
        accessToken = c.lossyString(.accessToken)
        owned = c.lossyBool(.owned) ?? false
        productVersion = c.lossyString(.productVersion)
        presence = c.lossyBool(.presence)
        connections = c.lossyArray(PlexConnection.self, .connections)
        isManual = c.lossyBool(.isManual) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(clientIdentifier, forKey: .clientIdentifier)
        try c.encodeIfPresent(accessToken, forKey: .accessToken)
        try c.encode(owned, forKey: .owned)
        try c.encodeIfPresent(productVersion, forKey: .productVersion)
        try c.encodeIfPresent(presence, forKey: .presence)
        try c.encode(connections, forKey: .connections)
        try c.encode(isManual, forKey: .isManual)
    }
}

/// Raw plex.tv resource used only to filter for servers.
struct PlexResource: Decodable {
    var provides: String?
    var server: PlexServer
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PlexServer.CodingKeys.self)
        provides = c.lossyString(.provides)
        server = try PlexServer(from: decoder)
    }
}

struct PlexUser: Codable {
    var id: Int?
    var uuid: String?
    var username: String?
    var title: String?
    var email: String?
    var thumb: String?
}

extension PlexMetadata {
    /// What kind of extra a video is, from its `subtype`.
    static func extraKind(_ subtype: String?) -> String {
        switch subtype {
        case "trailer": "Trailer"
        case "behindTheScenes": "Behind the Scenes"
        case "deletedScene": "Deleted Scene"
        case "featurette": "Featurette"
        case "interview": "Interview"
        case "sceneOrSample": "Scene"
        case "short": "Short"
        default: "Extra"
        }
    }
}
