import Foundation

/// Jellyfin servers, seen through the same requests the rest of the app makes to Plex.
///
/// Every library request (`/library/sections/…/all`, `/hubs`, `/:/timeline`…) is answered
/// from Jellyfin's API and returned as the JSON a Plex server would send, so browsing,
/// playback, downloads, the offline cache and Sound Check work unchanged. Keys and artwork
/// paths in those answers are Jellyfin paths (`/Videos/{id}/stream`, `/Items/{id}/Images/Primary`),
/// which `PlexServerAPI.url` signs with the Jellyfin token.
struct JellyfinBridge: Sendable {
    /// Jellyfin servers' IDs start with this, so any request can tell which kind of server it's for.
    static let idPrefix = "jellyfin:"

    let baseURL: URL
    let token: String?
    let serverID: String
    var userID: String

    init(api: PlexServerAPI) {
        baseURL = api.baseURL
        token = api.token
        serverID = api.serverID
        userID = ServerDirectory.shared.server(id: api.serverID)?.jellyfinUserID ?? ""
    }

    // MARK: Identity and requests

    /// The `Authorization` header Jellyfin expects from a client.
    static func authorization(token: String?) -> String {
        var parts = [
            "Client=\"\(PlexClient.product)\"", "Device=\"\(PlexClient.deviceKind)\"",
            "DeviceId=\"\(PlexClient.identifier)\"", "Version=\"\(PlexClient.version)\"",
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    static func request(_ url: URL, token: String?, method: String = "GET", body: Any? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authorization(token: token), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + (parts[0].hasPrefix("/") ? parts[0] : "/" + parts[0])
        var items = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
        items += query
        comps.queryItems = items.isEmpty ? nil : items
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    /// One Jellyfin request; the body as JSON (or nil when the server sends none).
    @discardableResult
    func call(_ path: String, _ query: [URLQueryItem] = [], method: String = "GET", body: Any? = nil,
              timeout: TimeInterval = 20) async throws -> Any? {
        let data = try await raw(path, query, method: method, body: body, timeout: timeout)
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func raw(_ path: String, _ query: [URLQueryItem] = [], method: String = "GET", body: Any? = nil,
             timeout: TimeInterval = 20) async throws -> Data {
        let req = Self.request(url(path, query), token: token, method: method, body: body, timeout: timeout)
        let (data, resp) = try await PlexServerAPI.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { NotificationCenter.default.post(name: PlexServerAPI.unauthorized, object: token) }
            throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    /// Jellyfin 10.9 moved per-user routes (`/Users/{id}/Items/…`) to `?userId=` forms; servers
    /// before it only have the old ones.
    private func compat<T>(_ attempt: (_ modern: Bool) async throws -> T) async throws -> T {
        do { return try await attempt(true) } catch PlexError.http(404, _) { return try await attempt(false) }
    }

    /// One item with everything the detail page uses.
    private func item(_ id: String, fields: String = JellyfinBridge.detailFields) async throws -> JSON {
        try await compat { modern in
            modern ? try await object("/Items/\(id)", [.init(name: "userId", value: userID), .init(name: "Fields", value: fields)])
                : try await object("/Users/\(userID)/Items/\(id)", [.init(name: "Fields", value: fields)])
        }
    }

    private func object(_ path: String, _ query: [URLQueryItem] = []) async throws -> JSON {
        (try await call(path, query) as? JSON) ?? [:]
    }

    private func items(_ path: String, _ query: [URLQueryItem] = []) async throws -> (items: [JSON], total: Int?) {
        let result = try await call(path, query)
        if let list = result as? [JSON] { return (list, list.count) }
        let obj = result as? JSON ?? [:]
        return (obj["Items"] as? [JSON] ?? [], obj["TotalRecordCount"] as? Int)
    }

    // MARK: Routing

    typealias JSON = [String: Any]

    /// Answers one Plex-style request with Plex-style JSON (or the raw body, for files).
    func respond(path fullPath: String, query extra: [URLQueryItem], method: String, headers: [String: String]) async throws -> Data {
        let split = fullPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = split[0]
        var query = split.count > 1 ? (URLComponents(string: "?" + split[1])?.queryItems ?? []) : []
        query += extra
        let q = Query(query)
        let seg = path.split(separator: "/").map(String.init)

        /// The `*` parts of `pattern` when the path has its shape ("library/sections/*/all").
        func match(_ seg: [String], _ pattern: String) -> [String]? {
            let want = pattern.split(separator: "/").map(String.init)
            guard want.count == seg.count else { return nil }
            var captured: [String] = []
            for (w, s) in zip(want, seg) {
                if w == "*" { captured.append(s) } else if w != s { return nil }
            }
            return captured
        }

        // Jellyfin's own paths (stream keys, subtitle files, artwork) pass straight through.
        if let first = seg.first, ["Videos", "Audio", "Items", "Users", "Shows", "System"].contains(first) {
            return try await raw(path, query.filter { !$0.name.hasPrefix("X-Plex") }, method: method)
        }

        if match(seg, "identity") != nil {
            let info = try await object("/System/Info/Public")
            return container(["machineIdentifier": Self.idPrefix + (info["Id"] as? String ?? ""),
                              "friendlyName": info["ServerName"] ?? "Jellyfin", "version": info["Version"] ?? ""])

        } else if method == "GET", match(seg, "library/sections") != nil {
            return container(["Directory": try await libraries().map(\.directory)])

        } else if method == "GET", let c = match(seg, "library/sections/*/all") {
            let id = c[0]
            return try await libraryItems(sectionID: id, q: q)
        } else if method == "GET", let c = match(seg, "library/sections/*/collections") {
            let id = c[0]
            let (list, total) = try await items("/Items", common(q) + [
                .init(name: "IncludeItemTypes", value: "BoxSet"), .init(name: "Recursive", value: "true"),
                .init(name: "SortBy", value: "SortName"),
            ] + paging(q))
            _ = id
            return metadataContainer(list, total: total)
        } else if method == "GET", let c = match(seg, "library/sections/*/folder") {
            let id = c[0]
            let (list, total) = try await items("/Items", common(q) + [.init(name: "ParentId", value: id),
                                                                       .init(name: "SortBy", value: "IsFolder,SortName")] + paging(q))
            return metadataContainer(list, total: total)
        } else if method == "GET", let c = match(seg, "library/sections/*/genre") {
            let id = c[0]
            let (list, _) = try await items("/Genres", [.init(name: "ParentId", value: id), .init(name: "userId", value: userID),
                                                        .init(name: "SortBy", value: "SortName")])
            return container(["Directory": list.map { ["key": $0["Id"] as? String ?? "", "title": $0["Name"] as? String ?? ""] }])
        } else if method == "GET", let c = match(seg, "library/sections/*/decade") {
            let id = c[0]
            let filters = try await object("/Items/Filters", [.init(name: "ParentId", value: id), .init(name: "userId", value: userID)])
            let decades = Set((filters["Years"] as? [Int] ?? []).map { $0 / 10 * 10 }).sorted(by: >)
            return container(["Directory": decades.map { ["key": "\($0)", "title": "\($0)s"] }])
        } else if method == "GET", match(seg, "library/sections/*/firstCharacter") != nil {
            return container(["Directory": [JSON]()])
        } else if (match(seg, "library/sections/*") ?? match(seg, "library/sections/*/*")) != nil {
            return container([:])

        } else if method == "GET", match(seg, "hubs") != nil {
            return container(["Hub": try await homeHubs()])
        } else if method == "GET", match(seg, "hubs/continueWatching") != nil {
            let resume = try await resumeItems(parent: nil)
            return container(["Hub": [hub("home.continue", "Continue Watching", resume, type: "mixed")]])
        } else if method == "GET", match(seg, "library/onDeck") != nil {
            return metadataContainer(try await nextUp(parent: nil))
        } else if method == "GET", let c = match(seg, "hubs/sections/*") {
            let id = c[0]
            return container(["Hub": try await sectionHubs(id)])
        } else if method == "GET", match(seg, "hubs/search") != nil {
            return container(["Hub": try await search(q["query"] ?? "", limit: Int(q["limit"] ?? "") ?? 20)])

        } else if method == "GET", let c = match(seg, "library/metadata/*") {
            let ids = c[0]
            return try await metadata(ids)
        } else if let c = (method == "GET" ? match(seg, "library/metadata/*/children") : nil) ?? (method == "GET" ? match(seg, "library/collections/*/children") : nil) {
            let id = c[0]
            return metadataContainer(try await children(of: id))
        } else if method == "GET", let c = match(seg, "library/metadata/*/allLeaves") {
            let id = c[0]
            return metadataContainer(try await leaves(of: id))
        } else if method == "GET", let c = match(seg, "library/metadata/*/related") {
            let id = c[0]
            let similar = try await items("/Items/\(id)/Similar", [.init(name: "userId", value: userID), .init(name: "Limit", value: "20"),
                                                                   .init(name: "Fields", value: Self.listFields)]).items
            return container(["Hub": similar.isEmpty ? [] : [hub("related.similar", "More Like This", similar, type: "mixed")]])
        } else if method == "GET", let c = match(seg, "library/metadata/*/similar") {
            let id = c[0]
            return metadataContainer(try await items("/Items/\(id)/Similar", [.init(name: "userId", value: userID),
                                                                             .init(name: "Limit", value: "30"),
                                                                             .init(name: "Fields", value: Self.listFields)]).items)
        } else if method == "GET", let c = match(seg, "library/metadata/*/extras") {
            let id = c[0]
            return metadataContainer(try await extras(of: id))
        } else if method == "GET", match(seg, "library/metadata/*/nearest") != nil {
            return container([:])
        } else if method == "GET", let c = match(seg, "library/metadata/*/subtitles") {
            let id = c[0]
            return try await searchSubtitles(itemID: id, language: q["language"] ?? "en")
        } else if method == "PUT", let c = match(seg, "library/metadata/*/subtitles") {
            let id = c[0]
            guard let key = q["key"] else { throw PlexError.invalidResponse }
            try await call("/Items/\(id)/RemoteSearch/Subtitles/\(key)", method: "POST", timeout: 30)
            return container([:])

        } else if method == "GET", let c = match(seg, "library/streams/*") {
            let file = c[0]
            let id = Int(file.split(separator: ".").first ?? "") ?? 0
            guard let key = Self.subtitleKey(for: id) else { throw PlexError.http(404, nil) }
            return try await raw(key)
        } else if method == "PUT", let c = match(seg, "library/parts/*") {
            let partID = c[0]
            Self.setStreamSelection(partID: Int(partID) ?? 0, audio: q["audioStreamID"].flatMap(Int.init),
                                    subtitle: q["subtitleStreamID"].flatMap(Int.init))
            return container([:])
        } else if let c = match(seg, "jellyfin/lyrics/*") {
            let id = c[0]
            return try await lyrics(itemID: id)

        } else if method == "GET", match(seg, "playlists") != nil {
            let (list, total) = try await items("/Items", [
                .init(name: "userId", value: userID), .init(name: "IncludeItemTypes", value: "Playlist"),
                .init(name: "Recursive", value: "true"), .init(name: "SortBy", value: "SortName"),
                .init(name: "Fields", value: Self.listFields + ",ChildCount"),
            ])
            return metadataContainer(list, total: total)
        } else if method == "POST", match(seg, "playlists") != nil {
            let ids = Self.itemIDs(fromURI: q["uri"])
            let made = try await call("/Playlists", method: "POST", body: [
                "Name": q["title"] ?? "Playlist", "Ids": ids, "UserId": userID,
                "MediaType": q["type"] == "audio" ? "Audio" : "Video",
            ]) as? JSON
            guard let newID = made?["Id"] as? String else { throw PlexError.invalidResponse }
            return container(["Metadata": [["ratingKey": newID, "key": "/playlists/\(newID)/items", "type": "playlist",
                                            "title": q["title"] ?? "Playlist", "playlistType": q["type"] ?? "video"]]])
        } else if method == "GET", let c = match(seg, "playlists/*") {
            let id = c[0]
            let found = try await item(id)
            return metadataContainer([found])
        } else if method == "DELETE", let c = match(seg, "playlists/*") {
            let id = c[0]
            try await call("/Items/\(id)", method: "DELETE")
            return container([:])
        } else if method == "PUT", match(seg, "playlists/*") != nil {
            return container([:])
        } else if method == "GET", let c = match(seg, "playlists/*/items") {
            let id = c[0]
            let (list, total) = try await items("/Playlists/\(id)/Items", [.init(name: "userId", value: userID),
                                                                           .init(name: "Fields", value: Self.listFields)] + paging(q))
            return metadataContainer(list, total: total)
        } else if method == "PUT", let c = match(seg, "playlists/*/items") {
            let id = c[0]
            let ids = Self.itemIDs(fromURI: q["uri"])
            try await call("/Playlists/\(id)/Items", [.init(name: "ids", value: ids.joined(separator: ",")),
                                                      .init(name: "userId", value: userID)], method: "POST")
            return container([:])
        } else if method == "DELETE", let c = match(seg, "playlists/*/items/*") {
            let id = c[0]
            let entry = c[1]
            try await call("/Playlists/\(id)/Items", [.init(name: "entryIds", value: entry)], method: "DELETE")
            return container([:])
        } else if method == "PUT", let c = match(seg, "playlists/*/items/*/move") {
            let id = c[0]
            let entry = c[1]
            try await movePlaylistEntry(playlistID: id, entry: entry, after: q["after"])
            return container([:])

        } else if match(seg, ":/timeline") != nil {
            try await reportTimeline(q, sessionID: headers["X-Plex-Session-Identifier"] ?? UUID().uuidString)
            return container([:])
        } else if match(seg, ":/progress") != nil {
            guard let id = q["key"] else { throw PlexError.invalidResponse }
            try await reportStopped(itemID: id, positionMs: Int(q["time"] ?? "") ?? 0, sessionID: UUID().uuidString)
            return container([:])
        } else if match(seg, ":/scrobble") != nil {
            guard let id = q["key"] else { throw PlexError.invalidResponse }
            try await setPlayed(id, played: true)
            return container([:])
        } else if match(seg, ":/unscrobble") != nil {
            guard let id = q["key"] else { throw PlexError.invalidResponse }
            try await setPlayed(id, played: false)
            return container([:])
        } else if match(seg, ":/rate") != nil {
            guard let id = q["key"] else { throw PlexError.invalidResponse }
            let rating = Double(q["rating"] ?? "") ?? -1
            let likes: [URLQueryItem] = rating < 0 ? [] : [.init(name: "likes", value: rating >= 6 ? "true" : "false")]
            try await compat { modern in
                modern ? try await call("/UserItems/\(id)/Rating", likes + [.init(name: "userId", value: userID)], method: rating < 0 ? "DELETE" : "POST")
                    : try await call("/Users/\(userID)/Items/\(id)/Rating", likes, method: rating < 0 ? "DELETE" : "POST")
            }
            return container([:])
        } else if match(seg, "actions/removeFromContinueWatching") != nil {
            guard let id = q["ratingKey"] else { throw PlexError.invalidResponse }
            try await reportStopped(itemID: id, positionMs: 0, sessionID: UUID().uuidString)
            return container([:])

        } else if match(seg, "video/:/transcode/universal/stop") != nil {
            _ = try? await call("/Videos/ActiveEncodings", [.init(name: "deviceId", value: PlexClient.identifier),
                                                            .init(name: "playSessionId", value: q["session"])], method: "DELETE", timeout: 5)
            return container([:])
        } else if method == "GET", match(seg, "status/sessions/history/all") != nil {
            let (list, total) = try await items("/Items", [
                .init(name: "userId", value: userID), .init(name: "Recursive", value: "true"), .init(name: "IsPlayed", value: "true"),
                .init(name: "IncludeItemTypes", value: "Movie,Episode"), .init(name: "SortBy", value: "DatePlayed"),
                .init(name: "SortOrder", value: "Descending"), .init(name: "Fields", value: Self.listFields),
            ] + paging(q))
            return metadataContainer(list, total: total, viewedAt: true)
        } else if ((method == "GET" ? match(seg, "library/all") : nil) ?? (method == "GET" ? match(seg, "transcode/sessions") : nil)) != nil {
            return container([:])
        } else {
            // Plex-only features (Live TV, the download queue, players on the network…).
            throw PlexError.http(501, "Not available on Jellyfin servers.")
        }
    }

    // MARK: Libraries

    struct Library {
        var id: String
        var name: String
        var collectionType: String?
        var imageTag: String?
        /// The Plex section type the app's screens expect.
        var plexType: String {
            switch collectionType {
            case "tvshows": "show"
            case "music": "artist"
            case "photos": "photo"
            default: "movie"
            }
        }
        var directory: JSON {
            var d: JSON = ["key": id, "title": name, "type": plexType, "uuid": id]
            if imageTag != nil { d["thumb"] = "/Items/\(id)/Images/Primary" }
            return d
        }
    }

    private static let libraryLock = NSLock()
    nonisolated(unsafe) private static var libraryCache: [String: [Library]] = [:]

    /// Libraries the app can show (not playlists, Live TV or channels), remembered per server.
    func libraries() async throws -> [Library] {
        let (list, _) = try await items("/UserViews", [.init(name: "userId", value: userID)])
        let libs = list.compactMap { v -> Library? in
            let type = v["CollectionType"] as? String
            guard !["playlists", "livetv", "channels", "folders", "books"].contains(type ?? "") else { return nil }
            return Library(id: v["Id"] as? String ?? "", name: v["Name"] as? String ?? "Library", collectionType: type,
                           imageTag: (v["ImageTags"] as? JSON)?["Primary"] as? String)
        }
        Self.libraryLock.withLock { Self.libraryCache[serverID] = libs }
        return libs
    }

    private func library(_ id: String) async -> Library? {
        if let found = Self.libraryLock.withLock({ Self.libraryCache[serverID]?.first { $0.id == id } }) { return found }
        return try? await libraries().first { $0.id == id }
    }

    /// Plex's `type` numbers (1 movie, 2 show, 4 episode, 8 artist, 9 album, 10 track, 18 collection).
    private static func itemTypes(plexType: String?, collectionType: String?) -> String {
        switch plexType {
        case "1": return "Movie"
        case "2": return "Series"
        case "3": return "Season"
        case "4": return "Episode"
        case "8": return "MusicArtist"
        case "9": return "MusicAlbum"
        case "10": return "Audio"
        case "13": return "Photo"
        case "18": return "BoxSet"
        default:
            switch collectionType {
            case "tvshows": return "Series"
            case "music": return "MusicArtist"
            case "photos": return "Photo,PhotoAlbum"
            case "homevideos": return "Video"
            case "musicvideos": return "MusicVideo"
            case "movies": return "Movie"
            default: return "Movie,Series,Video"
            }
        }
    }

    private func libraryItems(sectionID: String, q: Query) async throws -> Data {
        let lib = await library(sectionID)
        let types = Self.itemTypes(plexType: q["type"], collectionType: lib?.collectionType)
        var query = common(q) + paging(q) + Self.sort(q["sort"])
        if let genre = q["genre"] { query.append(.init(name: "GenreIds", value: genre)) }
        // A cast or crew member's titles (their page).
        if let person = q["actor"] ?? q["director"] ?? q["writer"] { query.append(.init(name: "PersonIds", value: person)) }
        if let decade = q["decade"].flatMap(Int.init) {
            query.append(.init(name: "Years", value: (decade..<decade + 10).map(String.init).joined(separator: ",")))
        }
        if q["unwatched"] == "1" { query.append(.init(name: "IsPlayed", value: "false")) }
        if q["resolution"] == "4k" { query.append(.init(name: "Is4K", value: "true")) }
        // Artists come from their own endpoint (folders of albums aren't items in a music library).
        if types == "MusicArtist" {
            let (list, total) = try await items("/Artists/AlbumArtists", query + [.init(name: "ParentId", value: sectionID)])
            return metadataContainer(list, total: total)
        }
        let photos = lib?.collectionType == "photos" && q["type"] == nil
        query += [.init(name: "ParentId", value: sectionID), .init(name: "IncludeItemTypes", value: photos ? nil : types),
                  .init(name: "Recursive", value: photos ? "false" : "true")]
        let (list, total) = try await items("/Items", query.filter { $0.value != nil })
        return metadataContainer(list, total: total)
    }

    private static func sort(_ plexSort: String?) -> [URLQueryItem] {
        let parts = (plexSort ?? "titleSort").split(separator: ":").map(String.init)
        let descending = parts.count > 1 && parts[1] == "desc"
        let field: String = switch parts[0] {
        case "addedAt": "DateCreated,SortName"
        case "originallyAvailableAt", "year": "PremiereDate,ProductionYear,SortName"
        case "rating": "CriticRating,SortName"
        case "audienceRating": "CommunityRating,SortName"
        case "lastViewedAt", "viewedAt": "DatePlayed,SortName"
        case "viewCount": "PlayCount,SortName"
        case "duration": "Runtime,SortName"
        case "random": "Random"
        default: "SortName"
        }
        return [.init(name: "SortBy", value: field), .init(name: "SortOrder", value: descending ? "Descending" : "Ascending")]
    }

    // MARK: Hubs

    private func homeHubs() async throws -> [JSON] {
        var hubs: [JSON] = []
        let resume = (try? await resumeItems(parent: nil)) ?? []
        if !resume.isEmpty { hubs.append(hub("home.continue", "Continue Watching", resume, type: "mixed")) }
        let next = (try? await nextUp(parent: nil)) ?? []
        if !next.isEmpty { hubs.append(hub("home.ondeck", "Next Up", next, type: "episode", key: "/library/onDeck")) }
        // Each library's Recently Added, asked for all at once (kept in library order).
        let libs = try await libraries().filter { ["movies", "tvshows", "music", "homevideos", nil].contains($0.collectionType) }
        let latestByLibrary = await withTaskGroup(of: (String, Items).self) { group in
            for lib in libs { group.addTask { (lib.id, Items(list: (try? await latest(parent: lib.id)) ?? [])) } }
            var found: [String: Items] = [:]
            for await (id, items) in group { found[id] = items }
            return found
        }
        for lib in libs {
            guard let latest = latestByLibrary[lib.id]?.list, !latest.isEmpty else { continue }
            let type = lib.collectionType == "music" ? "album" : lib.plexType
            hubs.append(hub("home.recentlyadded.\(lib.id)", "Recently Added in \(lib.name)", latest, type: type,
                            key: "/library/sections/\(lib.id)/all?sort=addedAt:desc\(lib.collectionType == "music" ? "&type=9" : "")"))
        }
        return hubs
    }

    /// Decoded JSON handed between tasks (it's read-only once decoded).
    private struct Items: @unchecked Sendable { let list: [JSON] }

    private func sectionHubs(_ id: String) async throws -> [JSON] {
        let lib = await library(id)
        var hubs: [JSON] = []
        let resume = (try? await resumeItems(parent: id)) ?? []
        if !resume.isEmpty { hubs.append(hub("section.continue", "Continue Watching", resume, type: "mixed")) }
        if lib?.collectionType == "tvshows" {
            let next = (try? await nextUp(parent: id)) ?? []
            if !next.isEmpty { hubs.append(hub("section.ondeck", "Next Up", next, type: "episode")) }
        }
        let latest = (try? await latest(parent: id)) ?? []
        if !latest.isEmpty {
            hubs.append(hub("section.recentlyadded", "Recently Added", latest, type: lib?.plexType ?? "movie",
                            key: "/library/sections/\(id)/all?sort=addedAt:desc\(lib?.collectionType == "music" ? "&type=9" : "")"))
        }
        let types = Self.itemTypes(plexType: lib?.collectionType == "music" ? "9" : nil, collectionType: lib?.collectionType)
        let top = (try? await items("/Items", [
            .init(name: "userId", value: userID), .init(name: "ParentId", value: id), .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: types), .init(name: "SortBy", value: "CommunityRating,SortName"),
            .init(name: "SortOrder", value: "Descending"), .init(name: "Limit", value: "20"), .init(name: "Fields", value: Self.listFields),
        ]).items) ?? []
        if !top.isEmpty { hubs.append(hub("section.toprated", "Top Rated", top, type: lib?.plexType ?? "movie")) }
        if lib?.collectionType == "music" {
            let played = (try? await items("/Items", [
                .init(name: "userId", value: userID), .init(name: "ParentId", value: id), .init(name: "Recursive", value: "true"),
                .init(name: "IncludeItemTypes", value: "Audio"), .init(name: "SortBy", value: "DatePlayed"),
                .init(name: "SortOrder", value: "Descending"), .init(name: "IsPlayed", value: "true"), .init(name: "Limit", value: "20"),
                .init(name: "Fields", value: Self.listFields),
            ]).items) ?? []
            if !played.isEmpty { hubs.append(hub("music.recentlyplayed", "Recently Played", played, type: "track")) }
        }
        return hubs
    }

    private func resumeItems(parent: String?) async throws -> [JSON] {
        let query: [URLQueryItem] = [
            .init(name: "Limit", value: "20"), .init(name: "MediaTypes", value: "Video"),
            .init(name: "Fields", value: Self.listFields), .init(name: "ParentId", value: parent),
        ].filter { $0.value != nil }
        return try await compat { modern in
            modern ? try await items("/UserItems/Resume", query + [.init(name: "userId", value: userID)]).items
                : try await items("/Users/\(userID)/Items/Resume", query).items
        }
    }

    private func nextUp(parent: String?) async throws -> [JSON] {
        try await items("/Shows/NextUp", [
            .init(name: "userId", value: userID), .init(name: "Limit", value: "20"),
            .init(name: "Fields", value: Self.listFields), .init(name: "ParentId", value: parent),
        ].filter { $0.value != nil }).items
    }

    private func latest(parent: String) async throws -> [JSON] {
        let query: [URLQueryItem] = [.init(name: "ParentId", value: parent), .init(name: "Limit", value: "20"),
                                     .init(name: "Fields", value: Self.listFields)]
        return try await compat { modern in
            modern ? try await items("/Items/Latest", query + [.init(name: "userId", value: userID)]).items
                : try await items("/Users/\(userID)/Items/Latest", query).items
        }
    }

    private func hub(_ id: String, _ title: String, _ list: [JSON], type: String, key: String? = nil) -> JSON {
        var h: JSON = ["hubIdentifier": id, "title": title, "type": type, "size": list.count, "Metadata": list.map(map)]
        if let key { h["key"] = key; h["more"] = list.count >= 20 }
        return h
    }

    private func search(_ term: String, limit: Int) async throws -> [JSON] {
        guard !term.isEmpty else { return [] }
        let (list, _) = try await items("/Items", [
            .init(name: "userId", value: userID), .init(name: "searchTerm", value: term), .init(name: "Recursive", value: "true"),
            .init(name: "Limit", value: "\(limit * 4)"), .init(name: "Fields", value: Self.listFields),
            .init(name: "IncludeItemTypes", value: "Movie,Series,Episode,MusicArtist,MusicAlbum,Audio,BoxSet,Playlist,Video"),
        ])
        let groups: [(String, String, String)] = [
            ("Movie", "movie", "Movies"), ("Video", "movie", "Videos"), ("Series", "show", "Shows"), ("Episode", "episode", "Episodes"),
            ("MusicArtist", "artist", "Artists"), ("MusicAlbum", "album", "Albums"), ("Audio", "track", "Tracks"),
            ("BoxSet", "collection", "Collections"), ("Playlist", "playlist", "Playlists"),
        ]
        return groups.compactMap { jfType, plexType, title in
            let found = list.filter { $0["Type"] as? String == jfType }.prefix(limit)
            return found.isEmpty ? nil : hub("search.\(plexType)", title, Array(found), type: plexType)
        }
    }

    // MARK: Items

    private func metadata(_ ids: String) async throws -> Data {
        let list = ids.split(separator: ",").map(String.init)
        if list.count > 1 {
            let (found, _) = try await items("/Items", [.init(name: "userId", value: userID), .init(name: "Ids", value: ids),
                                                        .init(name: "Fields", value: Self.detailFields)])
            return metadataContainer(found)
        }
        let detail = try await item(ids)
        var mapped = map(detail)
        // Intro and credits (Jellyfin 10.10's media segments; older servers just have none).
        if ["Episode", "Movie", "Video"].contains(detail["Type"] as? String ?? "") {
            let markers = await segments(itemID: ids)
            if !markers.isEmpty { mapped["Marker"] = markers }
        }
        return container(["Metadata": [mapped]])
    }

    private func segments(itemID: String) async -> [JSON] {
        guard let obj = try? await object("/MediaSegments/\(itemID)", [
            .init(name: "includeSegmentTypes", value: "Intro"), .init(name: "includeSegmentTypes", value: "Outro"),
        ]), let list = obj["Items"] as? [JSON] else { return [] }
        let outros = list.filter { $0["Type"] as? String == "Outro" }
        return list.compactMap { s in
            guard let type = s["Type"] as? String, let start = s["StartTicks"] as? Double, let end = s["EndTicks"] as? Double else { return nil }
            var m: JSON = ["type": type == "Intro" ? "intro" : "credits",
                           "startTimeOffset": Int(start / 10_000), "endTimeOffset": Int(end / 10_000)]
            if type == "Outro", (s["StartTicks"] as? Double) == outros.compactMap({ $0["StartTicks"] as? Double }).max() { m["final"] = true }
            return m
        }
    }

    private func children(of id: String) async throws -> [JSON] {
        let parent = try await item(id, fields: "ParentId")
        let base: [URLQueryItem] = [.init(name: "userId", value: userID), .init(name: "Fields", value: Self.listFields)]
        switch parent["Type"] as? String {
        case "Series":
            return try await items("/Shows/\(id)/Seasons", base).items
        case "Season":
            let series = parent["SeriesId"] as? String ?? parent["ParentId"] as? String ?? ""
            return try await items("/Shows/\(series)/Episodes", base + [.init(name: "seasonId", value: id)]).items
        case "MusicArtist":
            return try await items("/Items", base + [
                .init(name: "AlbumArtistIds", value: id), .init(name: "IncludeItemTypes", value: "MusicAlbum"),
                .init(name: "Recursive", value: "true"), .init(name: "SortBy", value: "ProductionYear,SortName"),
                .init(name: "SortOrder", value: "Descending"),
            ]).items
        case "MusicAlbum":
            return try await items("/Items", base + [.init(name: "ParentId", value: id),
                                                     .init(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName")]).items
        case "Playlist":
            return try await items("/Playlists/\(id)/Items", base).items
        default:
            return try await items("/Items", base + [.init(name: "ParentId", value: id), .init(name: "SortBy", value: "SortName")]).items
        }
    }

    private func leaves(of id: String) async throws -> [JSON] {
        let parent = try await item(id, fields: "ParentId")
        let base: [URLQueryItem] = [.init(name: "userId", value: userID), .init(name: "Fields", value: Self.listFields)]
        switch parent["Type"] as? String {
        case "Series":
            return try await items("/Shows/\(id)/Episodes", base).items
        case "MusicArtist":
            return try await items("/Items", base + [
                .init(name: "ArtistIds", value: id), .init(name: "IncludeItemTypes", value: "Audio"), .init(name: "Recursive", value: "true"),
                .init(name: "SortBy", value: "Album,ParentIndexNumber,IndexNumber,SortName"),
            ]).items
        case "Season", "MusicAlbum", "Playlist":
            return try await children(of: id)
        default:
            return try await items("/Items", base + [.init(name: "ParentId", value: id), .init(name: "Recursive", value: "true"),
                                                     .init(name: "IsFolder", value: "false"), .init(name: "SortBy", value: "SortName")]).items
        }
    }

    private func extras(of id: String) async throws -> [JSON] {
        let base: [URLQueryItem] = [.init(name: "userId", value: userID)]
        async let special = try? items("/Items/\(id)/SpecialFeatures", base).items
        async let trailers = try? items("/Items/\(id)/LocalTrailers", base).items
        let all = (await trailers ?? []).map { var t = $0; t["ExtraType"] = "Trailer"; return t } + (await special ?? [])
        return all.map { var e = $0; e["Type"] = "Clip"; return e }
    }

    private func setPlayed(_ id: String, played: Bool) async throws {
        try await compat { modern in
            modern ? try await call("/UserPlayedItems/\(id)", [.init(name: "userId", value: userID)], method: played ? "POST" : "DELETE")
                : try await call("/Users/\(userID)/PlayedItems/\(id)", method: played ? "POST" : "DELETE")
        }
    }

    private func movePlaylistEntry(playlistID: String, entry: String, after: String?) async throws {
        let list = try await items("/Playlists/\(playlistID)/Items", [.init(name: "userId", value: userID)]).items
        let ids = list.compactMap { $0["PlaylistItemId"] as? String }.filter { $0 != entry }
        let target = after.flatMap { a in ids.firstIndex(of: a).map { $0 + 1 } } ?? 0
        try await call("/Playlists/\(playlistID)/Items/\(entry)/Move/\(target)", method: "POST")
    }

    // MARK: Playback reports

    private static let reportLock = NSLock()
    nonisolated(unsafe) private static var startedSessions: Set<String> = []
    /// Sessions already reported stopped: a late "playing" or "paused" report (the player settling
    /// after the end) mustn't open a new session on the server.
    nonisolated(unsafe) private static var stoppedSessions: Set<String> = []

    private func reportTimeline(_ q: Query, sessionID: String) async throws {
        guard let id = q["ratingKey"] else { throw PlexError.invalidResponse }
        let ms = Int(q["time"] ?? "") ?? 0
        let state = q["state"] ?? "playing"
        if state == "stopped" {
            Self.reportLock.withLock {
                _ = Self.startedSessions.remove(sessionID)
                if Self.stoppedSessions.count > 200 { Self.stoppedSessions.removeAll() }
                Self.stoppedSessions.insert(sessionID)
            }
            try await reportStopped(itemID: id, positionMs: ms, sessionID: sessionID)
            return
        }
        let body: JSON = ["ItemId": id, "PositionTicks": Int64(ms) * 10_000, "IsPaused": state == "paused",
                          "PlaySessionId": sessionID, "CanSeek": true, "PlayMethod": "DirectPlay"]
        guard !Self.reportLock.withLock({ Self.stoppedSessions.contains(sessionID) }) else { return }
        let first = Self.reportLock.withLock { Self.startedSessions.insert(sessionID).inserted }
        try await call(first ? "/Sessions/Playing" : "/Sessions/Playing/Progress", method: "POST", body: body, timeout: 10)
    }

    /// Ends a playback session at a position; Jellyfin saves it as the resume point (or marks it
    /// played near the end), which is also how offline progress is synced.
    private func reportStopped(itemID: String, positionMs: Int, sessionID: String) async throws {
        try await call("/Sessions/Playing/Stopped", method: "POST",
                       body: ["ItemId": itemID, "PositionTicks": Int64(positionMs) * 10_000, "PlaySessionId": sessionID], timeout: 10)
    }

    // MARK: Subtitles and lyrics

    private func searchSubtitles(itemID: String, language: String) async throws -> Data {
        let code = Locale.Language(identifier: language).languageCode?.identifier(.alpha3) ?? language
        let list = (try await call("/Items/\(itemID)/RemoteSearch/Subtitles/\(code)", timeout: 30) as? [JSON]) ?? []
        let streams: [JSON] = list.map { r in
            ["id": 0, "streamType": 3, "key": r["Id"] as? String ?? "", "codec": (r["Format"] as? String)?.lowercased() ?? "srt",
             "language": r["ThreeLetterISOLanguageName"] as? String ?? code, "languageCode": code,
             "displayTitle": r["Name"] as? String ?? "", "providerTitle": r["ProviderName"] as? String ?? "",
             "score": r["CommunityRating"] as? Double ?? 0, "hearingImpaired": r["HearingImpaired"] as? Bool ?? false]
        }
        return container(["Stream": streams])
    }

    /// Jellyfin's timed lyrics as LRC text, which the lyrics screen reads.
    private func lyrics(itemID: String) async throws -> Data {
        let obj = try await object("/Audio/\(itemID)/Lyrics")
        let lines = obj["Lyrics"] as? [JSON] ?? []
        let text = lines.map { line -> String in
            let words = line["Text"] as? String ?? ""
            guard let ticks = line["Start"] as? Double else { return words }
            let seconds = ticks / 10_000_000
            return String(format: "[%02d:%05.2f]", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)) + words
        }.joined(separator: "\n")
        return Data(text.utf8)
    }

    // Subtitle files are fetched by stream ID (`/library/streams/{id}.srt`), so each text
    // subtitle's Jellyfin path is remembered under the ID given to it.
    private static let streamLock = NSLock()
    nonisolated(unsafe) private static var subtitleKeys: [Int: String] = [:]
    nonisolated(unsafe) private static var selections: [Int: (audio: Int?, subtitle: Int?)] = [:]

    static func subtitleKey(for streamID: Int) -> String? { streamLock.withLock { subtitleKeys[streamID] } }

    static func setStreamSelection(partID: Int, audio: Int?, subtitle: Int?) {
        streamLock.withLock {
            var s = selections[partID] ?? (nil, nil)
            if let audio { s.audio = audio % 1000 }
            if let subtitle { s.subtitle = subtitle == 0 ? -1 : subtitle % 1000 }
            selections[partID] = s
        }
    }

    /// The audio and subtitle stream indexes chosen for a file (`-1` subtitle: off).
    static func selection(partID: Int) -> (audio: Int?, subtitle: Int?) { streamLock.withLock { selections[partID] ?? (nil, nil) } }

    // MARK: Mapping to Plex JSON

    static let listFields = "Overview,Genres,DateCreated,ChildCount,RecursiveItemCount,ProductionYear,PremiereDate,OfficialRating,"
        + "CommunityRating,CriticRating,SortName,ParentId,MediaSources,MediaStreams,Studios,ProviderIds"
    static let detailFields = listFields + ",People,Chapters,Taglines,Trickplay"

    private func paging(_ q: Query) -> [URLQueryItem] {
        var out: [URLQueryItem] = []
        if let start = q["X-Plex-Container-Start"] { out.append(.init(name: "StartIndex", value: start)) }
        if let size = q["X-Plex-Container-Size"] { out.append(.init(name: "Limit", value: size)) }
        return out
    }

    private func common(_ q: Query) -> [URLQueryItem] {
        [.init(name: "userId", value: userID), .init(name: "Fields", value: Self.listFields), .init(name: "EnableTotalRecordCount", value: "true")]
    }

    private func container(_ fields: JSON) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["MediaContainer": fields])) ?? Data(#"{"MediaContainer":{}}"#.utf8)
    }

    private func metadataContainer(_ list: [JSON], total: Int? = nil, viewedAt: Bool = false) -> Data {
        var mapped = list.map(map)
        if viewedAt {
            for i in mapped.indices { mapped[i]["viewedAt"] = mapped[i]["lastViewedAt"] }
        }
        var c: JSON = ["size": mapped.count, "Metadata": mapped]
        if let total { c["totalSize"] = total }
        return container(c)
    }

    private static func plexType(_ jf: String?, extra: String?) -> String {
        switch jf {
        case "Movie", "Video", "MusicVideo": "movie"
        case "Series": "show"
        case "Season": "season"
        case "Episode": "episode"
        case "MusicArtist": "artist"
        case "MusicAlbum": "album"
        case "Audio": "track"
        case "Photo": "photo"
        case "PhotoAlbum", "Folder", "CollectionFolder": "photoalbum"
        case "BoxSet": "collection"
        case "Playlist": "playlist"
        case "Trailer", "Clip": "clip"
        default: extra != nil ? "clip" : "movie"
        }
    }

    private static func extraSubtype(_ extra: String?) -> String? {
        switch extra {
        case "Trailer": "trailer"
        case "BehindTheScenes": "behindTheScenes"
        case "DeletedScene": "deletedScene"
        case "Featurette": "featurette"
        case "Interview": "interview"
        case "Scene", "Sample": "sceneOrSample"
        case "Short": "short"
        case nil: nil
        default: "featurette"
        }
    }

    private static func ms(_ ticks: Any?) -> Int? { (ticks as? Double).map { Int($0 / 10_000) } ?? (ticks as? Int).map { $0 / 10_000 } }

    private static func epoch(_ iso: Any?) -> Int? {
        guard let s = iso as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: Self.trimmedFraction(s)) { return Int(d.timeIntervalSince1970) }
        return nil
    }

    /// Jellyfin sends seven fractional digits, more than the formatter reads.
    private static func trimmedFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return s }
        return String(s[..<dot]) + String(s[end...])
    }

    /// Stable number for a Jellyfin ID (a media source's), so file IDs stay the same across requests.
    static func number(_ id: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return Int(hash % 2_000_000) + 1
    }

    private func image(_ itemID: String?, _ tag: String?, kind: String = "Primary") -> String? {
        guard let itemID, !itemID.isEmpty, tag != nil else { return nil }
        return "/Items/\(itemID)/Images/\(kind)"
    }

    /// One Jellyfin item (`BaseItemDto`) as a Plex `Metadata` entry.
    func map(_ j: JSON) -> JSON {
        let id = j["Id"] as? String ?? ""
        let jfType = j["Type"] as? String
        let type = Self.plexType(jfType, extra: j["ExtraType"] as? String)
        let user = j["UserData"] as? JSON ?? [:]
        let tags = j["ImageTags"] as? JSON ?? [:]
        var m: JSON = ["ratingKey": id, "type": type, "title": j["Name"] as? String ?? "", "guid": "jellyfin://\(id)"]
        let isContainer = ["show", "season", "artist", "album", "collection", "playlist", "photoalbum"].contains(type)
        m["key"] = type == "playlist" ? "/playlists/\(id)/items" : "/library/metadata/\(id)" + (isContainer ? "/children" : "")
        if let subtype = Self.extraSubtype(j["ExtraType"] as? String) { m["subtype"] = subtype }
        m["titleSort"] = j["SortName"]
        m["originalTitle"] = j["OriginalTitle"]
        m["summary"] = j["Overview"]
        m["tagline"] = (j["Taglines"] as? [String])?.first
        m["year"] = j["ProductionYear"]
        m["index"] = j["IndexNumber"]
        m["parentIndex"] = j["ParentIndexNumber"]
        m["contentRating"] = j["OfficialRating"]
        m["studio"] = (j["Studios"] as? [JSON])?.first?["Name"]
        m["duration"] = Self.ms(j["RunTimeTicks"])
        m["addedAt"] = Self.epoch(j["DateCreated"])
        if let premiere = j["PremiereDate"] as? String { m["originallyAvailableAt"] = String(premiere.prefix(10)) }
        m["thumb"] = image(id, tags["Primary"] as? String)
        if let backdrops = j["BackdropImageTags"] as? [String], !backdrops.isEmpty {
            m["art"] = "/Items/\(id)/Images/Backdrop/0"
        } else if let parent = j["ParentBackdropItemId"] as? String {
            m["art"] = "/Items/\(parent)/Images/Backdrop/0"
        }

        switch jfType {
        case "Episode":
            m["parentRatingKey"] = j["SeasonId"]
            m["grandparentRatingKey"] = j["SeriesId"]
            m["parentTitle"] = j["SeasonName"]
            m["grandparentTitle"] = j["SeriesName"]
            m["parentThumb"] = image(j["SeasonId"] as? String, j["SeasonId"] as? String)
            m["grandparentThumb"] = image(j["SeriesId"] as? String, j["SeriesPrimaryImageTag"] as? String)
            m["grandparentArt"] = (j["ParentBackdropItemId"] as? String).map { "/Items/\($0)/Images/Backdrop/0" }
            if m["thumb"] == nil, let thumb = (j["ParentThumbItemId"] as? String) { m["thumb"] = "/Items/\(thumb)/Images/Thumb" }
        case "Season":
            m["parentRatingKey"] = j["SeriesId"] ?? j["ParentId"]
            m["parentTitle"] = j["SeriesName"]
            m["parentThumb"] = image(j["SeriesId"] as? String, j["SeriesPrimaryImageTag"] as? String)
            m["parentIndex"] = nil
        case "Audio":
            m["parentRatingKey"] = j["AlbumId"]
            m["parentTitle"] = j["Album"]
            m["grandparentTitle"] = j["AlbumArtist"] ?? (j["Artists"] as? [String])?.first
            m["grandparentRatingKey"] = (j["AlbumArtists"] as? [JSON])?.first?["Id"]
            m["parentThumb"] = image(j["AlbumId"] as? String, j["AlbumPrimaryImageTag"] as? String)
        case "MusicAlbum":
            m["parentTitle"] = j["AlbumArtist"]
            m["parentRatingKey"] = (j["AlbumArtists"] as? [JSON])?.first?["Id"]
        case "Playlist":
            m["playlistType"] = (j["MediaType"] as? String) == "Audio" ? "audio" : ((j["MediaType"] as? String) == "Photo" ? "photo" : "video")
            m["smart"] = false
            m["composite"] = m["thumb"]
            m["leafCount"] = j["ChildCount"]
        default: break
        }
        if let entry = j["PlaylistItemId"] as? String { m["playlistItemID"] = entry }

        // Watch state.
        let played = user["Played"] as? Bool ?? false
        m["viewCount"] = played ? max(user["PlayCount"] as? Int ?? 1, 1) : 0
        if let pos = Self.ms(user["PlaybackPositionTicks"]), pos > 0 { m["viewOffset"] = pos }
        m["lastViewedAt"] = Self.epoch(user["LastPlayedDate"])
        if let likes = user["Likes"] as? Bool { m["userRating"] = likes ? 10 : 2 }
        if ["show", "season"].contains(type) {
            let total = j["RecursiveItemCount"] as? Int ?? j["ChildCount"] as? Int
            if type == "show" { m["childCount"] = j["ChildCount"] }
            if let total {
                m["leafCount"] = total
                m["viewedLeafCount"] = max(0, total - (user["UnplayedItemCount"] as? Int ?? (played ? 0 : total)))
            }
        } else if type == "album" || type == "collection" {
            m["leafCount"] = j["ChildCount"] ?? j["RecursiveItemCount"]
        }

        // Scores and tags.
        var ratings: [JSON] = []
        if let critic = j["CriticRating"] as? Double {
            ratings.append(["image": "jellyfin://critic", "value": critic / 10, "type": "critic"])
            m["rating"] = critic / 10
        }
        if let community = j["CommunityRating"] as? Double {
            ratings.append(["image": "jellyfin://community", "value": community, "type": "audience"])
            m["audienceRating"] = community
        }
        if !ratings.isEmpty { m["Rating"] = ratings }
        m["Genre"] = (j["GenreItems"] as? [JSON])?.map { ["tag": $0["Name"] ?? "", "filter": "genre=\($0["Id"] as? String ?? "")"] }
            ?? (j["Genres"] as? [String])?.map { ["tag": $0] }
        if let people = j["People"] as? [JSON] {
            func tag(_ p: JSON) -> JSON {
                var t: JSON = ["tag": p["Name"] ?? "", "filter": "actor=\(p["Id"] as? String ?? "")"]
                t["role"] = p["Role"]
                if p["PrimaryImageTag"] != nil, let pid = p["Id"] as? String { t["thumb"] = "/Items/\(pid)/Images/Primary" }
                return t
            }
            m["Role"] = people.filter { ["Actor", "GuestStar"].contains($0["Type"] as? String ?? "") }.prefix(40).map(tag)
            m["Director"] = people.filter { $0["Type"] as? String == "Director" }.map(tag)
        }
        if let chapters = j["Chapters"] as? [JSON], !chapters.isEmpty {
            m["Chapter"] = chapters.enumerated().map { i, c -> JSON in
                var ch: JSON = ["tag": c["Name"] as? String ?? "Chapter \(i + 1)", "index": i + 1,
                                "startTimeOffset": Self.ms(c["StartPositionTicks"]) ?? 0]
                if c["ImageTag"] != nil { ch["thumb"] = "/Items/\(id)/Images/Chapter/\(i)" }
                return ch
            }
        }
        if let sources = j["MediaSources"] as? [JSON], ["movie", "episode", "clip", "track"].contains(type) {
            m["Media"] = sources.map { mapSource($0, itemID: id, audio: type == "track", item: j) }
        }
        return m.filter { !($0.value is NSNull) }
    }

    /// A media source (one version of the file) as a Plex `Media` with one `Part`.
    private func mapSource(_ s: JSON, itemID: String, audio: Bool, item: JSON) -> JSON {
        let sourceID = s["Id"] as? String ?? itemID
        let number = Self.number(sourceID)
        let streams = s["MediaStreams"] as? [JSON] ?? []
        let chosen = Self.selection(partID: number)
        let defaultAudio = chosen.audio ?? s["DefaultAudioStreamIndex"] as? Int
        let defaultSubtitle = chosen.subtitle ?? s["DefaultSubtitleStreamIndex"] as? Int
        var container = (s["Container"] as? String ?? "").lowercased()
        // Jellyfin lists every name of a format ("mov,mp4,m4a,3gp,3g2,mj2").
        if container.contains(",") { container = container.contains("mp4") ? "mp4" : String(container.split(separator: ",")[0]) }
        let video = streams.first { $0["Type"] as? String == "Video" }
        let audioStreams = streams.filter { $0["Type"] as? String == "Audio" }
        let selectedAudio = audioStreams.first { $0["Index"] as? Int == defaultAudio } ?? audioStreams.first

        var plexStreams: [JSON] = []
        for st in streams {
            let index = st["Index"] as? Int ?? 0
            let streamID = number * 1000 + index
            var p: JSON = ["id": streamID, "index": index]
            p["codec"] = Self.codec(st["Codec"] as? String)
            p["language"] = st["Language"].flatMap { Locale.current.localizedString(forLanguageCode: $0 as? String ?? "") } ?? st["Language"]
            p["languageCode"] = st["Language"]
            p["displayTitle"] = st["DisplayTitle"]
            p["extendedDisplayTitle"] = st["DisplayTitle"]
            p["title"] = st["Title"]
            p["default"] = st["IsDefault"]
            p["forced"] = st["IsForced"]
            p["bitrate"] = (st["BitRate"] as? Int).map { $0 / 1000 }
            switch st["Type"] as? String {
            case "Video":
                p["streamType"] = 1
                p["frameRate"] = st["RealFrameRate"] ?? st["AverageFrameRate"]
                switch (st["VideoRangeType"] as? String ?? st["VideoRange"] as? String ?? "").uppercased() {
                case let r where r.hasPrefix("DOVI"): p["DOVIPresent"] = true; p["colorTrc"] = "smpte2084"
                case let r where r.hasPrefix("HDR10") || r == "HDR": p["colorTrc"] = "smpte2084"
                case "HLG": p["colorTrc"] = "arib-std-b67"
                default: break
                }
            case "Audio":
                p["streamType"] = 2
                p["channels"] = st["Channels"]
                p["selected"] = index == selectedAudio?["Index"] as? Int
                if audio, let gain = item["NormalizationGain"] as? Double { p["gain"] = gain; p["albumGain"] = gain }
            case "Subtitle":
                p["streamType"] = 3
                p["selected"] = index == defaultSubtitle
                // Text subtitles (in the file or beside it) come from the server as SRT.
                if st["IsTextSubtitleStream"] as? Bool == true {
                    let key = "/Videos/\(itemID)/\(sourceID)/Subtitles/\(index)/0/Stream.srt"
                    p["key"] = key
                    p["codec"] = "srt"
                    Self.streamLock.withLock { Self.subtitleKeys[streamID] = key }
                }
            default:
                continue
            }
            plexStreams.append(p.filter { !($0.value is NSNull) })
        }
        if audio, item["HasLyrics"] as? Bool == true {
            plexStreams.append(["id": number * 1000 + 999, "streamType": 4, "key": "/jellyfin/lyrics/\(itemID)", "codec": "lrc"])
        }

        // Trickplay thumbnails (10.9+): the widest set up to 320 pixels, for scrubbing.
        var indexes: String?
        if let sets = (item["Trickplay"] as? JSON)?[sourceID] as? JSON {
            let infos = sets.values.compactMap { $0 as? JSON }.sorted { ($0["Width"] as? Int ?? 0) < ($1["Width"] as? Int ?? 0) }
            if let info = infos.last(where: { ($0["Width"] as? Int ?? 0) <= 320 }) ?? infos.first,
               let w = info["Width"] as? Int, let h = info["Height"] as? Int, let tw = info["TileWidth"] as? Int,
               let th = info["TileHeight"] as? Int, let count = info["ThumbnailCount"] as? Int, let interval = info["Interval"] as? Int {
                indexes = "jellyfin:\(w):\(h):\(tw):\(th):\(count):\(interval):\(itemID):\(sourceID)"
            }
        }
        let width = video?["Width"] as? Int, height = video?["Height"] as? Int
        var media: JSON = ["id": number, "container": container, "Part": [[
            // The file's extension helps Apple's player recognize the format.
            "id": number, "key": "/\(audio ? "Audio" : "Videos")/\(itemID)/stream\(container.isEmpty ? "" : "." + container)"
                + "?static=true&mediaSourceId=\(sourceID)",
            "duration": Self.ms(s["RunTimeTicks"]) ?? Self.ms(item["RunTimeTicks"]) ?? 0,
            "file": s["Path"] ?? "", "size": s["Size"] ?? 0, "container": container, "Stream": plexStreams,
            "indexes": indexes ?? NSNull(),
        ] as JSON]]
        media["duration"] = Self.ms(s["RunTimeTicks"]) ?? Self.ms(item["RunTimeTicks"])
        media["bitrate"] = (s["Bitrate"] as? Int).map { $0 / 1000 }
        media["width"] = width
        media["height"] = height
        media["videoCodec"] = Self.codec(video?["Codec"] as? String)
        media["audioCodec"] = Self.codec(selectedAudio?["Codec"] as? String)
        media["audioChannels"] = selectedAudio?["Channels"]
        if let width, let height {
            media["videoResolution"] = width >= 3200 || height >= 1800 ? "4k" : height >= 900 || width >= 1800 ? "1080"
                : height >= 650 || width >= 1200 ? "720" : height >= 500 ? "576" : "sd"
        }
        return media.filter { !($0.value is NSNull) }
    }

    /// Jellyfin's codec names in the spelling the playback rules use.
    private static func codec(_ c: String?) -> String? {
        guard let c = c?.lowercased() else { return nil }
        switch c {
        case "subrip": return "srt"
        case "pgssub": return "pgs"
        case "dvd_subtitle", "dvdsub": return "vobsub"
        case "h265": return "hevc"
        case "dts": return "dca"
        default: return c
        }
    }

    /// Item IDs from a Plex playlist URI (`server://…/library/metadata/a,b,c`).
    static func itemIDs(fromURI uri: String?) -> [String] {
        guard let uri, let range = uri.range(of: "/library/metadata/") else { return [] }
        return uri[range.upperBound...].split(separator: ",").map(String.init)
    }

    /// Query items by name (the first value wins).
    struct Query {
        let items: [URLQueryItem]
        init(_ items: [URLQueryItem]) { self.items = items }
        subscript(_ name: String) -> String? { items.first { $0.name == name }?.value }
    }
}

// MARK: - Streaming

extension JellyfinBridge {
    /// HLS from Jellyfin's transcoder: the chosen version, audio track and (burned-in) subtitle,
    /// at the requested quality.
    static func transcodeURL(api: PlexServerAPI, item: PlexMetadata, quality: StreamingQuality, sessionID: String,
                             music: Bool, musicBitrate: Int, burnSubtitleID: Int?, allowHEVC: Bool) -> URL {
        let part = item.primaryPart
        let sourceID = part?.key.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "mediaSourceId" }?.value } ?? item.ratingKey
        var q: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: sourceID), .init(name: "PlaySessionId", value: sessionID),
            .init(name: "DeviceId", value: PlexClient.identifier),
        ]
        if music {
            q += [.init(name: "AudioCodec", value: "aac"), .init(name: "SegmentContainer", value: "ts"),
                  .init(name: "AudioBitrate", value: "\((musicBitrate > 0 ? musicBitrate : 320) * 1000)"),
                  .init(name: "MaxStreamingBitrate", value: "\((musicBitrate > 0 ? musicBitrate : 320) * 1000)")]
            return api.url("/Audio/\(item.ratingKey)/master.m3u8", query: q, includeToken: true)
        }
        q += [.init(name: "VideoCodec", value: allowHEVC ? "h264,hevc" : "h264"), .init(name: "AudioCodec", value: "aac,ac3,eac3"),
              .init(name: "SegmentContainer", value: "ts"), .init(name: "TranscodingMaxAudioChannels", value: "6"),
              .init(name: "BreakOnNonKeyFrames", value: "false")]
        if let audio = part?.selectedAudio { q.append(.init(name: "AudioStreamIndex", value: "\(audio.id % 1000)")) }
        if let burnSubtitleID {
            q += [.init(name: "SubtitleStreamIndex", value: "\(burnSubtitleID % 1000)"), .init(name: "SubtitleMethod", value: "Encode")]
        }
        if let bitrate = quality.bitrate {
            let size = quality.resolution.split(separator: "x").compactMap { Int($0) }
            q += [.init(name: "MaxStreamingBitrate", value: "\(bitrate * 1000)"), .init(name: "VideoBitrate", value: "\(bitrate * 1000)")]
            if size.count == 2 { q += [.init(name: "MaxWidth", value: "\(size[0])"), .init(name: "MaxHeight", value: "\(size[1])")] }
        } else {
            q.append(.init(name: "MaxStreamingBitrate", value: "200000000"))
        }
        return api.url("/Videos/\(item.ratingKey)/master.m3u8", query: q, includeToken: true)
    }
}

// MARK: - Signing in

/// Signs in to a Jellyfin server: with a username and password, or with Quick Connect (a code
/// approved from the Jellyfin app or web page, handy on Apple TV).
enum JellyfinAuth {
    struct ServerInfo { let id: String; let name: String; let version: String; let url: String }
    struct QuickConnect { let secret: String; let code: String }

    static func normalize(_ address: String) -> String {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    /// Checks the address answers as a Jellyfin server (trying the default port when none is given).
    static func info(address: String) async throws -> ServerInfo {
        let base = normalize(address)
        var candidates = [base]
        if let comps = URLComponents(string: base), comps.port == nil, comps.path.isEmpty || comps.path == "/" {
            candidates.append(base + ":8096")
        }
        var lastError: Error = PlexError.noReachableConnection
        for candidate in candidates {
            do {
                guard let url = URL(string: candidate + "/System/Info/Public") else { continue }
                let (data, resp) = try await URLSession.shared.data(for: JellyfinBridge.request(url, token: nil, timeout: 10))
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["Id"] as? String else {
                    throw PlexError.unsupported("That address isn't a Jellyfin server.")
                }
                return ServerInfo(id: id, name: obj["ServerName"] as? String ?? "Jellyfin", version: obj["Version"] as? String ?? "", url: candidate)
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Whether the server's administrator turned Quick Connect on.
    static func quickConnectEnabled(_ server: ServerInfo) async -> Bool {
        guard let url = URL(string: server.url + "/QuickConnect/Enabled"),
              let (data, _) = try? await URLSession.shared.data(for: JellyfinBridge.request(url, token: nil, timeout: 10)) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? Bool ?? false
    }

    static func startQuickConnect(_ server: ServerInfo) async throws -> QuickConnect {
        let obj = try await post(server.url + "/QuickConnect/Initiate", body: nil)
        guard let secret = obj["Secret"] as? String, let code = obj["Code"] as? String else { throw PlexError.invalidResponse }
        return QuickConnect(secret: secret, code: code)
    }

    /// True once the code was approved.
    static func checkQuickConnect(_ server: ServerInfo, _ qc: QuickConnect) async -> Bool {
        var comps = URLComponents(string: server.url + "/QuickConnect/Connect")!
        comps.queryItems = [URLQueryItem(name: "secret", value: qc.secret)]
        guard let url = comps.url, let (data, _) = try? await URLSession.shared.data(for: JellyfinBridge.request(url, token: nil)) else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["Authenticated"] as? Bool ?? false
    }

    static func signIn(_ server: ServerInfo, quickConnect qc: QuickConnect) async throws -> PlexServer {
        try make(server, try await post(server.url + "/Users/AuthenticateWithQuickConnect", body: ["Secret": qc.secret]))
    }

    static func signIn(_ server: ServerInfo, username: String, password: String) async throws -> PlexServer {
        do {
            return try make(server, try await post(server.url + "/Users/AuthenticateByName", body: ["Username": username, "Pw": password]))
        } catch PlexError.http(401, _) {
            throw PlexError.unsupported("Wrong username or password.")
        }
    }

    private static func make(_ server: ServerInfo, _ auth: [String: Any]) throws -> PlexServer {
        guard let token = auth["AccessToken"] as? String, let user = auth["User"] as? [String: Any], let userID = user["Id"] as? String else {
            throw PlexError.invalidResponse
        }
        var s = PlexServer(name: server.name, clientIdentifier: JellyfinBridge.idPrefix + server.id, accessToken: token, owned: true,
                           connections: [PlexConnection(uri: server.url, local: AppStateLocality.looksLocal(server.url), relay: false)],
                           isManual: true)
        s.productVersion = server.version
        s.jellyfinUserID = userID
        s.jellyfinUserName = user["Name"] as? String
        return s
    }

    private static func post(_ address: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw PlexError.invalidResponse }
        let (data, resp) = try await URLSession.shared.data(for: JellyfinBridge.request(url, token: nil, method: "POST", body: body ?? [:], timeout: 15))
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Ends the session on the server (signing out or removing it).
    static func signOut(_ server: PlexServer) async {
        guard let uri = server.connections.first?.uri, let url = URL(string: uri + "/Sessions/Logout") else { return }
        _ = try? await URLSession.shared.data(for: JellyfinBridge.request(url, token: server.accessToken, method: "POST", timeout: 5))
    }
}

/// Whether an address is on the home network (shared by the iPhone and Apple TV apps).
enum AppStateLocality {
    static func looksLocal(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let o = host.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || o[0] == 127 || (o[0] == 192 && o[1] == 168) || (o[0] == 172 && (16...31).contains(o[1]))
            || (o[0] == 169 && o[1] == 254) || (o[0] == 100 && (64...127).contains(o[1]))
    }
}
