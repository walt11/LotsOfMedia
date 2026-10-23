import Foundation

/// Thread-safe persistent registry of known servers, their tokens, and the
/// last connection URI that worked. Used by both the UI layer and the
/// background download engine (which may run before any UI exists).
final class ServerDirectory: @unchecked Sendable {
    static let shared = ServerDirectory()

    private let lock = NSLock()
    private let persists: Bool
    private var _servers: [PlexServer]
    private var _endpoints: [String: String]

    private init() {
        persists = true
        if let data = Keychain.data(for: "servers"),
           let servers = try? JSONDecoder().decode([PlexServer].self, from: data) {
            _servers = servers
        } else {
            _servers = []
        }
        _endpoints = UserDefaults.standard.dictionary(forKey: "serverEndpoints") as? [String: String] ?? [:]
    }

    /// Isolated registry for tests and previews; never reads or writes credentials.
    init(inMemoryServers: [PlexServer]) {
        persists = false
        _servers = inMemoryServers
        _endpoints = [:]
    }

    /// A different account must never inherit manually supplied credentials. Jellyfin servers
    /// have their own sign-in, separate from Plex accounts, and stay.
    func replaceSessionServers(_ discovered: [PlexServer]) {
        lock.withLock {
            let jellyfin = _servers.filter(\.isJellyfin)
            _servers = discovered + jellyfin
            _endpoints = _endpoints.filter { key, _ in jellyfin.contains { $0.id == key } }
            persist()
        }
    }

    var servers: [PlexServer] { lock.withLock { _servers } }

    func server(id: String) -> PlexServer? { lock.withLock { _servers.first { $0.id == id } } }

    /// Replace account-discovered servers while keeping manually added ones.
    func setDiscovered(_ discovered: [PlexServer]) {
        lock.withLock {
            let manual = _servers.filter { $0.isManual && !discovered.map(\.id).contains($0.id) }
            _servers = discovered + manual
            persist()
        }
    }

    func upsert(_ server: PlexServer) {
        lock.withLock {
            if let i = _servers.firstIndex(where: { $0.id == server.id }) { _servers[i] = server } else { _servers.append(server) }
            persist()
        }
    }

    func remove(id: String) {
        lock.withLock {
            _servers.removeAll { $0.id == id }
            _endpoints[id] = nil
            persist()
        }
    }

    func removeAll() {
        lock.withLock {
            _servers = []
            _endpoints = [:]
            persist()
        }
    }

    func setEndpoint(_ uri: String, for serverID: String) {
        lock.withLock {
            _endpoints[serverID] = uri
            if persists { UserDefaults.standard.set(_endpoints, forKey: "serverEndpoints") }
        }
    }

    func endpointURI(for serverID: String) -> String? { lock.withLock { _endpoints[serverID] } }

    /// Reject results captured before credentials changed or the server was removed.
    func authorizes(_ api: PlexServerAPI) -> Bool {
        lock.withLock {
            guard let server = _servers.first(where: { $0.id == api.serverID }) else { return false }
            return server.accessToken == api.token
        }
    }

    /// Best-known base URL and token for a server, without any network activity.
    func api(for serverID: String) -> PlexServerAPI? {
        lock.withLock {
            guard let server = _servers.first(where: { $0.id == serverID }) else { return nil }
            let uri = _endpoints[serverID] ?? server.connections.sorted { $0.rank < $1.rank }.first?.uri
            guard let uri, let url = URL(string: uri) else { return nil }
            return PlexServerAPI(baseURL: url, token: server.accessToken, serverID: serverID)
        }
    }

    private func persist() {
        guard persists else { return }
        Keychain.set(try? JSONEncoder().encode(_servers), for: "servers")
        UserDefaults.standard.set(_endpoints, forKey: "serverEndpoints")
    }
}
