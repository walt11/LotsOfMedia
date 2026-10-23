import Foundation
import Observation

/// The plex.tv Watchlist: one list per Plex account, shared by every Plex app. Items are movies
/// and shows identified by their Plex guid ("plex://movie/5d776…"), whether or not a server has them.
enum PlexWatchlist {
    static let baseURL = URL(string: "https://discover.provider.plex.tv")!

    /// The Watchlist's own key for an item: the last part of its Plex guid. Episodes and seasons
    /// use their show's. Nil for items without a Plex guid (older agents).
    static func discoverKey(for item: PlexMetadata) -> String? {
        let guid: String?
        switch item.kind {
        case .movie, .show: guid = item.guid
        case .season: guid = item.parentGuid
        case .episode: guid = item.grandparentGuid
        default: guid = nil
        }
        guard let guid, guid.hasPrefix("plex://"), let key = guid.split(separator: "/").last, !key.isEmpty else { return nil }
        return String(key)
    }

    /// The movie or show a Watchlist entry stands for (episodes and seasons: their show).
    static func canAdd(_ item: PlexMetadata) -> Bool { discoverKey(for: item) != nil }

    private static func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", token: String) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = method
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8)) }
        return data
    }

    /// The whole Watchlist, most recently added first.
    static func items(token: String) async throws -> [PlexMetadata] {
        var all: [PlexMetadata] = []
        let size = 100
        while true {
            try Task.checkCancellation()
            let data = try await request("library/sections/watchlist/all", query: [
                URLQueryItem(name: "sort", value: "watchlistedAt:desc"),
                URLQueryItem(name: "X-Plex-Container-Start", value: "\(all.count)"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)"),
            ], token: token)
            let page = try PlexServerAPI.decodeContainer(data)
            all += page.metadata
            if page.metadata.count < size || all.count >= (page.totalSize ?? Int.max) { return all }
        }
    }

    static func add(_ key: String, token: String) async throws {
        _ = try await request("actions/addToWatchlist", query: [URLQueryItem(name: "ratingKey", value: key)], method: "PUT", token: token)
    }

    static func remove(_ key: String, token: String) async throws {
        _ = try await request("actions/removeFromWatchlist", query: [URLQueryItem(name: "ratingKey", value: key)], method: "PUT", token: token)
    }

    /// The same movie or show in a server's library, if it has it.
    static func localMatch(for entry: PlexMetadata, api: PlexServerAPI) async -> PlexMetadata? {
        guard let guid = entry.guid else { return nil }
        let found = try? await api.container("/library/all", query: [URLQueryItem(name: "guid", value: guid)]).metadata
        return found?.first { $0.kind == .movie || $0.kind == .show }
    }
}

/// The signed-in profile's Watchlist, shared by the pages that show or change it.
@MainActor @Observable
final class WatchlistStore {
    static let shared = WatchlistStore()

    private(set) var items: [PlexMetadata] = []
    /// Discover keys on the Watchlist, for the Add/Remove menu items.
    private(set) var keys: Set<String> = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// The account the list belongs to; a profile switch starts again.
    private var token: String?

    func contains(_ item: PlexMetadata) -> Bool { PlexWatchlist.discoverKey(for: item).map(keys.contains) ?? false }

    func refresh(token: String?) async {
        guard let token else { items = []; keys = []; self.token = nil; return }
        if token != self.token { items = []; keys = [] }
        self.token = token
        isLoading = true
        defer { if token == self.token { isLoading = false } }
        do {
            let list = try await PlexWatchlist.items(token: token)
            guard token == self.token else { return }
            items = list
            keys = Set(list.compactMap { PlexWatchlist.discoverKey(for: $0) })
            error = nil
        } catch {
            guard token == self.token, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    /// Adds or removes the item's movie or show. Shown at once; put back if plex.tv refuses.
    func toggle(_ item: PlexMetadata, token: String?) async throws {
        guard let token, let key = PlexWatchlist.discoverKey(for: item) else { throw PlexError.notSignedIn }
        let adding = !keys.contains(key)
        if adding { keys.insert(key) } else { keys.remove(key); items.removeAll { PlexWatchlist.discoverKey(for: $0) == key } }
        do {
            if adding { try await PlexWatchlist.add(key, token: token) } else { try await PlexWatchlist.remove(key, token: token) }
        } catch {
            if adding { keys.remove(key) } else { keys.insert(key) }
            throw error
        }
        if adding { await refresh(token: token) }
    }
}
