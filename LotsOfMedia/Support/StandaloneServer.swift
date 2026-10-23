import Foundation

/// The music server for places that run without the phone UI (CarPlay, Siri):
/// the saved server choice, a connection checked from where the phone is now,
/// and the profile's preference scope.
@MainActor
enum StandaloneServer {
    /// The server chosen on the phone; if none was ever saved, the same default the phone picks.
    nonisolated static func serverID(selected: String?, servers: [PlexServer]) -> String? {
        if let selected, servers.contains(where: { $0.id == selected }) { return selected }
        return servers.first(where: \.owned)?.id ?? servers.first?.id
    }

    static var serverID: String? {
        serverID(selected: UserDefaults.standard.string(forKey: "selectedServerID"), servers: ServerDirectory.shared.servers)
    }
    static var server: PlexServer? { serverID.flatMap { ServerDirectory.shared.server(id: $0) } }
    static var scope: String {
        MediaPreferences.scope(user: UserDefaults.standard.string(forKey: "currentUserUUID"), server: serverID)
    }

    /// Last connection that answered (in the car that's usually cellular, not the
    /// home-network address saved last time).
    private(set) static var liveAPI: PlexServerAPI?
    private static var checkedAt: Date?

    /// Best API right now: the checked connection, else the last known address
    /// (requests are then answered from the library cache).
    static var api: PlexServerAPI? {
        if let liveAPI, let server, matches(liveAPI, server) { return liveAPI }
        return serverID.flatMap { ServerDirectory.shared.api(for: $0) }
    }

    /// A connection belongs to one server and one set of credentials: after a profile or
    /// account change the same server has a new token, and the old connection is not reused.
    private static func matches(_ api: PlexServerAPI, _ server: PlexServer) -> Bool {
        api.serverID == server.id && api.token == server.accessToken
    }

    /// Finds a working address (re-checked at most every few minutes unless forced).
    @discardableResult
    static func connect(force: Bool = false) async -> PlexServerAPI? {
        guard let server else { return nil }
        if !force, let liveAPI, matches(liveAPI, server), let checkedAt, Date().timeIntervalSince(checkedAt) < 300 {
            return liveAPI
        }
        guard NetworkMonitor.shared.isConnected else {
            LibraryCache.isOffline = true
            return nil
        }
        let resolved = try? await ConnectionResolver.resolve(server)
        // The profile, account or server may have changed while resolving: drop a stale result.
        guard let current = self.server, current.id == server.id, current.accessToken == server.accessToken else {
            return api
        }
        if let uri = resolved, let url = URL(string: uri) {
            liveAPI = PlexServerAPI(baseURL: url, token: server.accessToken, serverID: server.id)
            checkedAt = Date()
            LibraryCache.isOffline = false
            return liveAPI
        }
        liveAPI = nil
        // Unreachable: answer browsing from the library cache instead of waiting on timeouts.
        LibraryCache.isOffline = true
        return nil
    }
}
