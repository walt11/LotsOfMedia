import Foundation

/// Requests against one Plex Media Server at one resolved address.
struct PlexServerAPI: Sendable {
    let baseURL: URL
    let token: String?
    let serverID: String

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        // Library data must always be fresh (watch state changes constantly), and
        // caching API JSON on disk would only waste space.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Posted (object: the token) when a server answers 401, so the app can check whether the
    /// account's sign-in expired.
    static let unauthorized = Notification.Name("PlexServerAPI.unauthorized")

    // MARK: URL building

    func url(_ path: String, query: [URLQueryItem] = [], includeToken: Bool = false) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        // `path` may already contain a query string (Plex keys often do).
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + (parts[0].hasPrefix("/") ? parts[0] : "/" + parts[0])
        var items = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
        items += query
        if includeToken, let token { items.append(URLQueryItem(name: "X-Plex-Token", value: token)) }
        comps.queryItems = items.isEmpty ? nil : items
        // URLComponents leaves '+' unescaped in queries, which Plex decodes as space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    /// Resized artwork via the server's photo transcoder.
    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return url("/photo/:/transcode", query: [
            URLQueryItem(name: "width", value: "\(width)"), URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"), URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
        ], includeToken: true)
    }

    // MARK: Requests

    @discardableResult
    func data(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
              headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url(path, query: query), timeoutInterval: timeout)
        req.httpMethod = method
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { NotificationCenter.default.post(name: Self.unauthorized, object: token) }
            throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return (data, http)
    }

    func container(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                   headers: [String: String] = [:]) async throws -> PlexContainer {
        // Library browsing is cached so it keeps working offline.
        let cacheKey = LibraryCache.isCacheable(path: path, method: method)
            ? LibraryCache.key(serverID: serverID, token: token, path: path, query: query) : nil
        if let cacheKey, LibraryCache.isOffline, let cached = LibraryCache.read(cacheKey) {
            return try Self.decodeContainer(cached)
        }
        let data: Data
        let cacheGeneration = LibraryCache.generation
        do {
            data = try await self.data(path, query: query, method: method, headers: headers).0
        } catch {
            if let cacheKey, LibraryCache.isConnectivityError(error), let cached = LibraryCache.read(cacheKey) {
                return try Self.decodeContainer(cached)
            }
            throw error
        }
        let decoded = try Self.decodeContainer(data)
        if let cacheKey, !data.isEmpty { LibraryCache.write(data, key: cacheKey, generation: cacheGeneration) }
        return decoded
    }

    static func decodeContainer(_ data: Data) throws -> PlexContainer {
        if data.isEmpty { return try JSONDecoder().decode(PlexResponse.self, from: Data(#"{"MediaContainer":{}}"#.utf8)).MediaContainer }
        return try JSONDecoder().decode(PlexResponse.self, from: data).MediaContainer
    }

    func page(_ path: String, start: Int, size: Int, query: [URLQueryItem] = []) async throws -> PlexContainer {
        try await container(path, query: query + [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
        ])
    }

    // MARK: Library

    func sections() async throws -> [PlexDirectory] {
        try await container("/library/sections").directories
    }

    func homeHubs() async throws -> [PlexHub] {
        try await container("/hubs", query: [
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "includeLibraryPlaylists", value: "1"),
        ]).hubs
    }

    func continueWatching() async throws -> [PlexMetadata] {
        // Newer servers expose a combined Continue Watching hub; fall back to On Deck.
        if let hub = try? await container("/hubs/continueWatching", query: [URLQueryItem(name: "count", value: "20")]).hubs.first,
           !hub.metadata.isEmpty {
            return hub.metadata
        }
        return try await container("/library/onDeck").metadata
    }

    func sectionHubs(_ sectionKey: String) async throws -> [PlexHub] {
        try await container("/hubs/sections/\(sectionKey)", query: [URLQueryItem(name: "count", value: "20")]).hubs
    }

    func metadata(_ ratingKey: String) async throws -> PlexMetadata? {
        try await container("/library/metadata/\(ratingKey)", query: [
            URLQueryItem(name: "includeExtras", value: "0"),
            URLQueryItem(name: "includeOnDeck", value: "1"),
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeChapters", value: "1"),
        ]).metadata.first
    }

    // MARK: Subtitles

    /// A sidecar subtitle converted to SRT by the server.
    func subtitleFile(streamID: Int) async throws -> Data {
        try await data("/library/streams/\(streamID).srt", query: [URLQueryItem(name: "format", value: "srt")], timeout: 30).0
    }

    /// Search online subtitle providers (via the server's agents).
    func searchSubtitles(ratingKey: String, language: String, hearingImpaired: Bool = false) async throws -> [PlexStream] {
        try await container("/library/metadata/\(ratingKey)/subtitles", query: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hearingImpaired", value: hearingImpaired ? "1" : "0"),
            URLQueryItem(name: "forced", value: "0"),
        ]).streams
    }

    /// Ask the server to download a search result and attach it to the item.
    func addSubtitle(ratingKey: String, result: PlexStream) async throws {
        var q = [URLQueryItem(name: "key", value: result.key ?? "")]
        if let c = result.codec { q.append(URLQueryItem(name: "codec", value: c)) }
        if let l = result.languageCode ?? result.language { q.append(URLQueryItem(name: "language", value: l)) }
        if let p = result.providerTitle { q.append(URLQueryItem(name: "providerTitle", value: p)) }
        q.append(URLQueryItem(name: "hearingImpaired", value: result.hearingImpaired == true ? "1" : "0"))
        q.append(URLQueryItem(name: "forced", value: result.forced == true ? "1" : "0"))
        try await data("/library/metadata/\(ratingKey)/subtitles", query: q, method: "PUT", timeout: 30)
    }

    func children(_ ratingKey: String) async throws -> [PlexMetadata] {
        try await container("/library/metadata/\(ratingKey)/children").metadata
    }

    func allLeaves(_ ratingKey: String) async throws -> [PlexMetadata] {
        let leaves = try await container("/library/metadata/\(ratingKey)/allLeaves").metadata
        return leaves.isEmpty ? try await leavesFromChildren(ratingKey) : leaves
    }

    /// Up to `limit` episodes after `episode`, in order: the rest of its season, then later
    /// seasons as needed. Much lighter than `allLeaves` on a long-running show.
    func episodes(after episode: PlexMetadata, limit: Int) async throws -> [PlexMetadata] {
        let byIndex: (PlexMetadata, PlexMetadata) -> Bool = { ($0.index ?? 0) < ($1.index ?? 0) }
        var found: [PlexMetadata] = []
        if let season = episode.parentRatingKey {
            found = try await children(season).filter { $0.isPlayableVideo && ($0.index ?? 0) > (episode.index ?? 0) }.sorted(by: byIndex)
        }
        guard found.count < limit, let show = episode.grandparentRatingKey else { return Array(found.prefix(limit)) }
        let later = try await children(show)
            .filter { $0.kind == .season && ($0.index ?? 0) > (episode.parentIndex ?? 0) }
            .sorted(by: byIndex)
        for season in later where found.count < limit {
            try Task.checkCancellation()
            found += try await children(season.ratingKey).filter(\.isPlayableVideo).sorted(by: byIndex)
        }
        return Array(found.prefix(limit))
    }

    /// Some servers return nothing from allLeaves (e.g. albums with "mixed parents");
    /// walk the children instead (one level of albums or seasons).
    func leavesFromChildren(_ ratingKey: String) async throws -> [PlexMetadata] {
        var found: [PlexMetadata] = []
        for child in try await children(ratingKey) {
            if child.kind == .track || child.isPlayableVideo { found.append(child) }
            else if [.album, .season].contains(child.kind) {
                found += try await children(child.ratingKey).filter { $0.kind == .track || $0.isPlayableVideo }
            }
        }
        return found
    }

    func related(_ ratingKey: String) async -> [PlexHub] {
        (try? await container("/library/metadata/\(ratingKey)/related").hubs) ?? []
    }

    /// Trailers, featurettes, deleted scenes and other extras that can be played.
    func extras(_ ratingKey: String) async -> [PlexMetadata] {
        ((try? await container("/library/metadata/\(ratingKey)/extras").metadata) ?? []).filter(\.isPlayableVideo)
    }

    /// Everything a person (a cast member's `filter`, e.g. "actor=123") is in across these
    /// movie and TV libraries, newest first.
    func titles(withFilter filter: String, in sections: [PlexDirectory]) async -> [PlexMetadata] {
        guard let eq = filter.firstIndex(of: "=") else { return [] }
        let name = String(filter[..<eq]), value = String(filter[filter.index(after: eq)...])
        var found: [PlexMetadata] = []
        for section in sections where ["movie", "show"].contains(section.type ?? "") {
            found += (try? await container("/library/sections/\(section.key)/all", query: [
                URLQueryItem(name: name, value: value), URLQueryItem(name: "sort", value: "originallyAvailableAt:desc"),
            ]).metadata) ?? []
        }
        return found
    }

    func search(_ query: String) async throws -> [PlexHub] {
        try await container("/hubs/search", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "includeCollections", value: "1"),
        ]).hubs.filter { !$0.metadata.isEmpty }
    }

    /// Watch history, newest first. On a server you own, PMS returns every
    /// account's history, so it's narrowed to the owner (account 1); other
    /// users' tokens are already scoped to themselves by the server.
    func history(ownServer: Bool, start: Int = 0, size: Int = 60) async throws -> [PlexMetadata] {
        var q = [URLQueryItem(name: "sort", value: "viewedAt:desc")]
        if ownServer { q.append(URLQueryItem(name: "accountID", value: "1")) }
        return try await page("/status/sessions/history/all", start: start, size: size, query: q).metadata
    }

    func playlists() async throws -> [PlexMetadata] {
        try await container("/playlists").metadata
    }

    func createPlaylist(title: String, items: [PlexMetadata]) async throws -> PlexMetadata {
        _ = try PlaylistCreation.query(title: title, items: items, machineIdentifier: "validate")
        guard let machine = try await container("/identity").machineIdentifier, !machine.isEmpty else { throw PlexError.invalidResponse }
        let query = try PlaylistCreation.query(title: title, items: items, machineIdentifier: machine)
        let response = try await container("/playlists", query: query, method: "POST")
        guard let playlist = response.metadata.first else { throw PlexError.invalidResponse }
        return playlist
    }

    func addToPlaylist(_ ratingKey: String, items: [PlexMetadata]) async throws {
        guard let machine = try await container("/identity").machineIdentifier, !machine.isEmpty else { throw PlexError.invalidResponse }
        let query = try PlaylistCreation.query(title: "Add", items: items, machineIdentifier: machine)
        try await data("/playlists/\(ratingKey)/items", query: query.filter { $0.name == "uri" }, method: "PUT")
    }

    func playlistItems(_ ratingKey: String) async throws -> [PlexMetadata] {
        try await Self.collectPages { start, size in
            try await page("/playlists/\(ratingKey)/items", start: start, size: size)
        }
    }

    /// Advances by the number actually returned, including servers that cap pages.
    static func collectPages(size: Int = 200, fetch: (Int, Int) async throws -> PlexContainer) async throws -> [PlexMetadata] {
        var items: [PlexMetadata] = []
        while true {
            try Task.checkCancellation()
            let page = try await fetch(items.count, size)
            try Task.checkCancellation()
            guard !page.metadata.isEmpty else {
                if let total = page.totalSize, items.count < total { throw PlexError.invalidResponse }
                return items
            }
            items += page.metadata
            if let total = page.totalSize {
                if items.count >= total { return items }
            } else if page.metadata.count < size { return items }
        }
    }

    // MARK: Play state

    func timeline(ratingKey: String, key: String?, state: String, timeMs: Int, durationMs: Int?,
                  sessionID: String) async throws {
        var q = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: key ?? "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ]
        if let durationMs { q.append(URLQueryItem(name: "duration", value: "\(durationMs)")) }
        try await data("/:/timeline", query: q, headers: ["X-Plex-Session-Identifier": sessionID], timeout: 10)
    }

    func setProgress(ratingKey: String, timeMs: Int) async throws {
        try await data("/:/progress", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "state", value: "stopped"),
        ], timeout: 10)
    }

    func scrobble(_ ratingKey: String) async throws {
        try await data("/:/scrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    func unscrobble(_ ratingKey: String) async throws {
        try await data("/:/unscrobble", query: [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
        ])
    }

    /// Takes an item off Continue Watching without changing its progress.
    func removeFromContinueWatching(_ ratingKey: String) async throws {
        try await data("/actions/removeFromContinueWatching", query: [URLQueryItem(name: "ratingKey", value: ratingKey)], method: "PUT")
    }

    /// Persist audio/subtitle choice on the server (used by the transcoder and other clients).
    func selectStreams(partID: Int, audioStreamID: Int?, subtitleStreamID: Int?) async throws {
        var q = [URLQueryItem(name: "allParts", value: "1")]
        if let audioStreamID { q.append(URLQueryItem(name: "audioStreamID", value: "\(audioStreamID)")) }
        if let subtitleStreamID { q.append(URLQueryItem(name: "subtitleStreamID", value: "\(subtitleStreamID)")) }
        try await data("/library/parts/\(partID)", query: q, method: "PUT")
    }

    func stopTranscode(sessionID: String) async {
        _ = try? await data("/video/:/transcode/universal/stop", query: [URLQueryItem(name: "session", value: sessionID)], timeout: 5)
    }
}

struct PageRequestState {
    private(set) var generation = UUID()
    private(set) var isLoading = false
    mutating func reset() { generation = UUID(); isLoading = false }
    mutating func begin() -> UUID? {
        guard !isLoading else { return nil }
        isLoading = true
        return generation
    }
    mutating func finish(_ id: UUID) { if id == generation { isLoading = false } }
}


/// Regular Plex playlists require at least one item and a single media category.
enum PlaylistCreation {
    static func query(title: String, items: [PlexMetadata], machineIdentifier: String) throws -> [URLQueryItem] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PlexError.unsupported("Enter a playlist name.") }
        guard !items.isEmpty else { throw PlexError.unsupported("Choose at least one song or video.") }
        let audio = items.allSatisfy { $0.kind == .track }
        guard audio || items.allSatisfy(\.isPlayableVideo) else { throw PlexError.unsupported("Keep songs and videos in separate playlists.") }
        guard !machineIdentifier.isEmpty, items.allSatisfy({ !$0.ratingKey.isEmpty && $0.ratingKey.allSatisfy(\.isNumber) }) else {
            throw PlexError.unsupported("These items do not have valid library identifiers.")
        }
        var seen = Set<String>()
        let keys = items.map(\.ratingKey).filter { seen.insert($0).inserted }.joined(separator: ",")
        return [URLQueryItem(name: "type", value: audio ? "audio" : "video"),
                URLQueryItem(name: "title", value: title), URLQueryItem(name: "smart", value: "0"),
                URLQueryItem(name: "uri", value: "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)")]
    }
}
