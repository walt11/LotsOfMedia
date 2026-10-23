import Foundation

extension PlexServerAPI {
    func allSongs(sectionKey: String, sort: String = "titleSort") async throws -> [PlexMetadata] {
        try await Self.collectPages { start, size in
            try await page("/library/sections/\(sectionKey)/all", start: start, size: size,
                           query: [URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: sort)])
        }.filter { $0.kind == .track }
    }
    func renamePlaylist(_ id: String, title: String) async throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlexError.unsupported("Enter a playlist name.") }
        try await data("/playlists/\(id)", query: [URLQueryItem(name: "title", value: name)], method: "PUT")
    }
    func removePlaylistEntry(_ playlist: String, entryID: String) async throws {
        try await data("/playlists/\(playlist)/items/\(entryID)", method: "DELETE")
    }
    func movePlaylistEntry(_ playlist: String, entryID: String, after: String?) async throws {
        try await data("/playlists/\(playlist)/items/\(entryID)/move", query: after.map { [URLQueryItem(name: "after", value: $0)] } ?? [], method: "PUT")
    }
    func playlistMetadata(_ id: String) async throws -> PlexMetadata? { try await container("/playlists/\(id)").metadata.first }
    func uploadPlaylistArtwork(_ id: String, jpeg: Data) async throws {
        let before = Set(try await playlistPosters(id))
        var request = URLRequest(url: url("/library/metadata/\(id)/posters"), timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = jpeg
        PlexClient.headers(token: token).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.unsupported("The server couldn't update this playlist's artwork.")
        }
        let after = try await playlistPosters(id)
        guard let uploaded = after.first(where: { !before.contains($0) }) else {
            throw PlexError.unsupported("Artwork was uploaded, but the server did not identify the new poster. Refresh the playlist before retrying.")
        }
        try await data("/library/metadata/\(id)/poster", query: [URLQueryItem(name: "url", value: uploaded)], method: "PUT")
    }
    private func playlistPosters(_ id: String) async throws -> [String] {
        let (body, _) = try await data("/library/metadata/\(id)/posters")
        if let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let container = root["MediaContainer"] as? [String: Any] {
            let photos = (container["Photo"] ?? container["Metadata"]) as? [[String: Any]] ?? []
            return photos.compactMap { $0["ratingKey"] as? String }
        }
        return XMLAttributes.elements(named: "Photo", in: body).compactMap { $0["ratingKey"] }
    }
    func playbackDevices() async throws -> [PlexPlaybackDevice] {
        struct Response: Decodable {
            struct Container: Decodable { var Server: [PlexPlaybackDevice]? }
            var MediaContainer: Container
        }
        let (body, _) = try await data("/clients")
        return try JSONDecoder().decode(Response.self, from: body).MediaContainer.Server?.filter {
            !$0.machineIdentifier.isEmpty && $0.machineIdentifier != PlexClient.identifier && $0.protocolCapabilities.split(separator: ",").contains("playback")
        } ?? []
    }
    static func allPlayableLeaves(_ item: PlexMetadata, api: PlexServerAPI) async throws -> [PlexMetadata] {
        if item.isLeaf { return [item] }
        let path = item.kind == .playlist ? "/playlists/\(item.ratingKey)/items" : "/library/metadata/\(item.ratingKey)/allLeaves"
        let leaves = try await collectPages { start, size in try await api.page(path, start: start, size: size) }
            .filter { $0.kind == .track || $0.isPlayableVideo }
        guard leaves.isEmpty, item.kind != .playlist else { return leaves }
        return try await api.leavesFromChildren(item.ratingKey)
    }
}

struct PlexPlaybackDevice: Decodable, Identifiable {
    let name: String
    let machineIdentifier: String
    let product: String?
    let protocolCapabilities: String
    var id: String { machineIdentifier }
    enum CodingKeys: String, CodingKey { case name, machineIdentifier, product, protocolCapabilities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineIdentifier = c.lossyString(.machineIdentifier) ?? ""
        name = c.lossyString(.name) ?? "Plex player"
        product = c.lossyString(.product)
        protocolCapabilities = c.lossyString(.protocolCapabilities) ?? ""
    }
}

enum HandoffRequest {
    static func validateResponse(_ data: Data) throws {
        let xml = XMLAttributes.elements(named: "Response", in: data).first
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let response = (json?["Response"] as? [String: Any]) ?? json
        let code = xml?["code"].flatMap(Int.init) ?? (response?["code"] as? Int) ?? (response?["code"] as? String).flatMap(Int.init)
        if let code, !(200..<300).contains(code) { throw PlexError.unsupported("The other player rejected playback (\(code)). Open Plex on that device and try again.") }
    }
    static func query(item: PlexMetadata, offset: Int, machine: String, serverURL: URL) throws -> [URLQueryItem] {
        guard item.kind == .track || item.isPlayableVideo, !item.ratingKey.isEmpty,
              item.ratingKey.allSatisfy(\.isNumber), let host = serverURL.host,
              let scheme = serverURL.scheme, ["http", "https"].contains(scheme) else {
            throw PlexError.unsupported("This item cannot be sent to a Plex player.")
        }
        let values: [(String, String)] = [
            ("uri", "server://\(machine)/com.plexapp.plugins.library/library/metadata/\(item.ratingKey)"),
            ("type", item.kind == .track ? "audio" : "video"), ("offset", "\(max(0, offset))"),
            ("protocol", scheme), ("address", host), ("port", "\(serverURL.port ?? (scheme == "https" ? 443 : 80))"),
            ("machineIdentifier", machine), ("source", machine), ("shuffle", "0"), ("repeat", "0"),
            ("includeRelated", "0"), ("commandID", "\(Int64(Date().timeIntervalSince1970 * 1000))")]
        return values.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}
