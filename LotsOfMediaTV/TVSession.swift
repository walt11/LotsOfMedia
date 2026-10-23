import SwiftUI

/// Apple TV app state: the Plex account, the chosen server and its connection.
/// Built on the same Plex layer as the iPhone app (PlexAccount, ServerDirectory, ConnectionResolver).
@MainActor @Observable
final class TVSession {
    enum Status: Equatable { case idle, connecting, connected, failed(String) }

    private(set) var token: String? = Keychain.string(for: "accountToken")
    private(set) var user: PlexUser? {
        // The profile in use, for what's kept per profile (Live TV's recent channels), as on iPhone.
        didSet { UserDefaults.standard.set(user?.uuid, forKey: "currentUserUUID") }
    }
    private(set) var servers: [PlexServer] = ServerDirectory.shared.servers
    private(set) var api: PlexServerAPI?
    private(set) var status: Status = .idle
    private(set) var sections: [PlexDirectory] = []
    private(set) var homeUsers: [PlexHomeUser] = []
    private(set) var currentHomeUser: PlexHomeUser?
    /// The Plex Home profiles have been looked up (so whether to ask "Who's Watching?" is known).
    private(set) var homeUsersLoaded = false
    /// Bumped after playback or watch-state changes so pages reload.
    var contentVersion = 0
    var selectedServerID: String? = UserDefaults.standard.string(forKey: "selectedServerID") {
        didSet { UserDefaults.standard.set(selectedServerID, forKey: "selectedServerID") }
    }

    /// Signed in to Plex, or to at least one Jellyfin server.
    var isSignedIn: Bool { token != nil || servers.contains(where: \.isJellyfin) }
    @ObservationIgnored private var lastContentRefresh = Date()

    /// Back in the app after a while: reload server-driven pages (Continue Watching, progress,
    /// watched marks) so changes made on other devices show up. At most once a minute.
    func refreshContentIfStale() {
        guard status == .connected, Date().timeIntervalSince(lastContentRefresh) > 60 else { return }
        lastContentRefresh = Date()
        contentVersion += 1
    }
    var selectedServer: PlexServer? {
        servers.first { $0.id == selectedServerID } ?? servers.first { $0.owned } ?? servers.first
    }
    var isLocalConnection: Bool {
        guard let api, let server = selectedServer else { return false }
        return server.connections.first { $0.uri == api.baseURL.absoluteString }?.local ?? false
    }
    /// Connected through a Plex relay (slow): Automatic quality converts instead of playing the original.
    var isRelayConnection: Bool {
        guard let api, let server = selectedServer else { return false }
        return server.connections.first { $0.uri == api.baseURL.absoluteString }?.relay ?? false
    }
    /// Changes whenever the account, profile or server does: work started before then is stale
    /// and drops its result instead of restoring an old connection.
    @ObservationIgnored private var generation = UUID()

    init() {
        // Back online after a drop (router restart, Wi-Fi blip): reconnect instead of staying failed.
        NetworkMonitor.shared.onChange { [weak self] connected in
            guard let self, connected, self.isSignedIn, case .failed = self.status else { return }
            Task { await self.connect() }
        }
    }

    /// The account that signed in (Home user switches are made with it).
    private var primaryToken: String? { Keychain.string(for: "primaryAccountToken") ?? token }

    /// Sections the TV shows: movies, shows and music.
    var browsableSections: [PlexDirectory] { sections.filter { ["movie", "show", "artist"].contains($0.type ?? "") } }
    var photoSections: [PlexDirectory] { sections.filter { $0.type == "photo" } }

    func bootstrap() async {
        guard let token else {
            if isSignedIn { await connect() }   // Jellyfin only
            return
        }
        let gen = generation
        if let session = try? await PlexAccount.prepareSession(token: token), gen == generation {
            user = session.user
            ServerDirectory.shared.setDiscovered(session.servers)
            servers = ServerDirectory.shared.servers
        }
        await connect()
        await loadHomeUsers()
    }

    func signIn(token newToken: String) async throws {
        let gen = generation
        let session = try await PlexAccount.prepareSession(token: newToken)
        guard gen == generation else { throw CancellationError() }
        beginIdentityChange()
        Keychain.set(newToken, for: "accountToken")
        Keychain.set(newToken, for: "primaryAccountToken")
        token = newToken
        user = session.user
        currentHomeUser = nil
        ServerDirectory.shared.replaceSessionServers(session.servers)
        servers = ServerDirectory.shared.servers
        if selectedServer == nil || !servers.contains(where: { $0.id == selectedServerID }) {
            selectedServerID = (servers.first { $0.owned } ?? servers.first)?.id
        }
        await connect()
        await loadHomeUsers()
    }

    func signOut() {
        generation = UUID()
        Keychain.set(nil as Data?, for: "accountToken")
        Keychain.set(nil as Data?, for: "primaryAccountToken")
        ServerDirectory.shared.removeAll()
        token = nil; user = nil; api = nil; servers = []; sections = []; homeUsers = []; currentHomeUser = nil; homeUsersLoaded = false
        selectedServerID = nil
        status = .idle
        TVMusicPlayer.shared.stop()
        TVLiveNow.shared.stop()
        LiveTVStore.shared.clearSession()
        TopShelfSnapshot.clear()
        TVSpotlight.shared.reset()
    }

    /// A Jellyfin server just signed in to: saved, selected and connected.
    func addJellyfin(_ server: PlexServer) async {
        beginIdentityChange()
        ServerDirectory.shared.upsert(server)
        if let uri = server.connections.first?.uri { ServerDirectory.shared.setEndpoint(uri, for: server.id) }
        servers = ServerDirectory.shared.servers
        selectedServerID = server.id
        await connect()
    }

    /// Looks up the Plex account's servers again (a server added or shared since).
    func refreshServers() async throws {
        guard let token else { throw PlexError.notSignedIn }
        let gen = generation
        let discovered = try await PlexAccount.servers(token: token)
        guard gen == generation else { return }
        ServerDirectory.shared.setDiscovered(discovered)
        servers = ServerDirectory.shared.servers
    }

    /// A Plex server by its address (one that isn't on the account, or not reachable through
    /// plex.tv). `serverToken` defaults to the signed-in account's.
    func addPlexServer(address: String, serverToken: String?) async throws {
        var uri = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !uri.contains("://") { uri = "http://" + uri }
        while uri.hasSuffix("/") { uri.removeLast() }
        if URLComponents(string: uri)?.port == nil { uri += ":32400" }
        let tok = (serverToken?.isEmpty ?? true) ? token : serverToken
        let identity = try await ConnectionResolver.identify(uri: uri, token: tok)
        let id = identity.machineIdentifier ?? uri
        var server = ServerDirectory.shared.server(id: id)
            ?? PlexServer(name: identity.friendlyName ?? URL(string: uri)?.host ?? "Plex Server", clientIdentifier: id,
                          accessToken: tok, owned: true, connections: [], isManual: true)
        server.connections = [PlexConnection(uri: uri, local: AppStateLocality.looksLocal(uri), relay: false)]
            + server.connections.filter { $0.uri != uri }
        server.accessToken = tok ?? server.accessToken
        ServerDirectory.shared.upsert(server)
        ServerDirectory.shared.setEndpoint(uri, for: id)
        servers = ServerDirectory.shared.servers
        beginIdentityChange()
        selectedServerID = id
        await connect()
    }

    /// Removes a Jellyfin server (signing out of it) or a Plex server added by address.
    func removeServer(_ server: PlexServer) async {
        if server.isJellyfin { await JellyfinAuth.signOut(server) }
        ServerDirectory.shared.remove(id: server.id)
        servers = ServerDirectory.shared.servers
        if selectedServerID == server.id {
            beginIdentityChange()
            selectedServerID = (servers.first { $0.owned } ?? servers.first)?.id
            await connect()
        }
    }

    func select(_ server: PlexServer) async {
        guard server.id != selectedServer?.id || status != .connected else { return }
        beginIdentityChange()
        selectedServerID = server.id
        await connect()
    }

    /// Before switching account, profile or server: playback from the old one stops (reporting its
    /// progress to the old connection), and in-flight connections are made stale.
    private func beginIdentityChange() {
        generation = UUID()
        TVMusicPlayer.shared.stop()
        TVLiveNow.shared.stop()
        LiveTVStore.shared.clearSession()
        TopShelfSnapshot.clear()
        TVSpotlight.shared.reset()
        api = nil
        sections = []
        status = .idle
    }

    /// Tries a few times before giving up: on first launch tvOS asks for local network access
    /// while the first attempt is under way, so that attempt can fail on its own.
    func connect() async {
        let gen = generation
        for attempt in 0..<3 {
            await connectOnce(gen)
            if gen != generation || status == .connected || Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 5))
        }
    }

    /// Every await is followed by a generation check: a sign-out or switch while resolving
    /// wins, and this attempt's result (or error) is dropped.
    private func connectOnce(_ gen: UUID) async {
        guard gen == generation, let server = selectedServer else { if gen == generation { status = .idle }; return }
        status = .connecting
        do {
            let uri = try await ConnectionResolver.resolve(server)
            guard gen == generation else { return }
            guard let url = URL(string: uri) else { throw PlexError.noReachableConnection }
            let api = PlexServerAPI(baseURL: url, token: server.accessToken, serverID: server.id)
            let loaded = (try? await api.sections()) ?? []
            guard gen == generation else { return }
            self.api = api
            sections = loaded
            status = .connected
            contentVersion += 1
        } catch {
            guard gen == generation else { return }
            api = ServerDirectory.shared.api(for: server.id)
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Plex Home

    private func loadHomeUsers() async {
        guard let primaryToken else { homeUsersLoaded = true; return }
        let gen = generation
        let users = (try? await PlexAccount.homeUsers(token: primaryToken)) ?? []
        guard gen == generation else { return }
        homeUsers = users
        homeUsersLoaded = true
    }

    /// Plex Home profiles belong to the Plex account: not offered while a Jellyfin server is in use.
    var canSwitchUsers: Bool { homeUsers.count > 1 && selectedServer?.isJellyfin != true }
    /// Signed in to the selected server as this Jellyfin user (nil for a Plex server).
    var jellyfinUser: String? { selectedServer?.isJellyfin == true ? selectedServer?.jellyfinUserName ?? "Jellyfin user" : nil }

    func switchUser(_ homeUser: PlexHomeUser, pin: String?) async throws {
        guard let primaryToken else { return }
        let gen = generation
        let userToken = try await PlexAccount.switchUser(homeUser, pin: pin, token: primaryToken)
        let session = try await PlexAccount.prepareSession(token: userToken)
        guard gen == generation else { throw CancellationError() }
        // The profile already in use (its PIN just checked at "Who's Watching?"): keep its
        // connection, music queue and Top Shelf instead of starting over.
        if session.user.uuid != nil, session.user.uuid == user?.uuid {
            Keychain.set(userToken, for: "accountToken")
            token = userToken
            currentHomeUser = homeUser
            return
        }
        beginIdentityChange()
        Keychain.set(userToken, for: "accountToken")
        token = userToken
        user = session.user
        currentHomeUser = homeUser
        ServerDirectory.shared.replaceSessionServers(session.servers)
        servers = ServerDirectory.shared.servers
        await connect()
    }

    // MARK: Helpers

    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        if let path, path.hasPrefix("http") { return URL(string: path) }
        // The last known address while offline, so cached artwork still shows.
        let api = self.api ?? selectedServer.flatMap { ServerDirectory.shared.api(for: $0.id) }
        return api?.imageURL(path, width: width, height: height)
    }

    /// Your 1–5 star rating (0 clears it), saved on the server.
    func rate(_ item: PlexMetadata, stars: Int) async {
        guard let api else { return }
        try? await api.rate(item.ratingKey, rating: stars == 0 ? nil : Double(stars * 2))
        contentVersion += 1
    }

    func setWatched(_ item: PlexMetadata, _ watched: Bool) async {
        guard let api else { return }
        if watched { try? await api.scrobble(item.ratingKey) } else { try? await api.unscrobble(item.ratingKey) }
        contentVersion += 1
    }
}
