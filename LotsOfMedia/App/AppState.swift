import Foundation
import Observation
import SwiftUI
import WidgetKit

@MainActor
@Observable
final class AppState {
    enum ConnectionStatus: Equatable {
        case idle, connecting, connected, failed(String)
    }

    private(set) var accountToken: String? = Keychain.string(for: "accountToken")
    private(set) var user: PlexUser?
    /// Plex Home members (empty when the account isn't part of a Home).
    private(set) var homeUsers: [PlexHomeUser] = []
    private(set) var isSwitchingUser = false
    private(set) var servers: [PlexServer] = ServerDirectory.shared.servers
    /// Saved on every change: CarPlay and background work read it without the phone UI.
    private(set) var selectedServerID: String? = UserDefaults.standard.string(forKey: "selectedServerID") {
        didSet {
            UserDefaults.standard.set(selectedServerID, forKey: "selectedServerID")
            MediaVersionChoice.serverID = selectedServerID ?? ""
        }
    }
    private(set) var api: PlexServerAPI?
    private(set) var status: ConnectionStatus = .idle {
        // When the server can't be reached, library screens read straight from the cache.
        didSet { if case .failed = status { LibraryCache.isOffline = true } else if status == .connected { LibraryCache.isOffline = false } }
    }
    private(set) var isLocalConnection = true
    private(set) var isRefreshingServers = false
    /// Bumped when watch state likely changed (after playback, mark watched…), so screens reload.
    private(set) var contentVersion = 0
    var downloadPreview: PlexMetadata?
    var actionError: String?
    /// plex.tv no longer accepts the account's token (signed out elsewhere, password changed):
    /// asks the user to sign in again.
    var signInExpired = false
    @ObservationIgnored private var checkingSignIn = false
    @ObservationIgnored private var sessionGeneration = UUID()
    /// Downloads paused during a session change, resumed once the new session connects.
    @ObservationIgnored private var suspendedDownloads: [String] = []

    private func resumeSuspendedDownloads() {
        let ids = suspendedDownloads
        suspendedDownloads = []
        ids.forEach { DownloadManager.shared.resume($0) }
    }
    var mediaMode: MediaMode = MediaMode(rawValue: UserDefaults.standard.string(forKey: "mediaMode") ?? "") ?? .watch {
        didSet { UserDefaults.standard.set(mediaMode.rawValue, forKey: "mediaMode") }
    }
    private var musicTab: Tab = .home
    private var watchTab: Tab = .home
    var selectedTab: Tab {
        get { tab(for: mediaMode) }
        set { selectTab(newValue, for: mediaMode) }
    }
    func tab(for mode: MediaMode) -> Tab { mode == .music ? musicTab : watchTab }
    func selectTab(_ tab: Tab, for mode: MediaMode) {
        if mode == .music { musicTab = tab == .live ? .home : tab }
        else { watchTab = tab }
    }

    enum Tab: Hashable { case home, library, live, search, downloads }

    var streamingQuality: StreamingQuality {
        get { MediaPreferences.shared.videoQuality }
        set { MediaPreferences.shared.videoQuality = newValue }
    }

    var selectedServer: PlexServer? { servers.first { $0.id == selectedServerID } }
    var isSignedIn: Bool { accountToken != nil }
    var needsOnboarding: Bool { accountToken == nil && servers.isEmpty }
    /// Signed out but chose to keep using downloads offline (instead of signing in).
    var browsingDownloadsOnly = false
    /// The next Plex sign-in asks for an account instead of reusing the browser's saved one.
    var signInFresh = false
    var isOnline: Bool { status == .connected }
    /// API for browsing: the live connection, or the last known address while
    /// offline (requests are then answered from the library cache).
    var browseAPI: PlexServerAPI? { api ?? selectedServerID.flatMap { ServerDirectory.shared.api(for: $0) } }
    var currentUserID: String? { user?.uuid ?? UserDefaults.standard.string(forKey: "currentUserUUID") }
    var currentHomeUser: PlexHomeUser? { homeUsers.first { $0.uuid == currentUserID } }
    /// Plex Home profiles belong to the Plex account: not offered while a Jellyfin server is in use.
    var canSwitchUsers: Bool { homeUsers.count > 1 && selectedServer?.isJellyfin != true }
    /// Signed in to the selected server as this Jellyfin user (nil for a Plex server).
    var jellyfinUser: String? { selectedServer?.isJellyfin == true ? selectedServer?.jellyfinUserName ?? "Jellyfin user" : nil }
    /// Who's browsing, as shown on the profile button and playlists: the Jellyfin user, else the Plex profile.
    var profileName: String? { jellyfinUser ?? currentHomeUser?.title ?? user?.title }
    var profileThumb: String? { jellyfinUser != nil ? nil : currentHomeUser?.thumb ?? user?.thumb }
    /// Token of the account that originally signed in; used to list/switch Home users.
    private var primaryToken: String? { Keychain.string(for: "primaryAccountToken") ?? accountToken }
    @ObservationIgnored private var lastContentRefresh = Date()

    init() {
        DownloadManager.shared.activeUserID = UserDefaults.standard.string(forKey: "currentUserUUID")
        NetworkMonitor.shared.onChange { [weak self] connected in
            guard let self else { return }
            if connected { Task { await self.connect() } } else { self.status = .failed("No network connection") }
        }
        NotificationCenter.default.addObserver(forName: PlexServerAPI.unauthorized, object: nil, queue: .main) { [weak self] note in
            let token = note.object as? String
            MainActor.assumeIsolated { self?.serverRejected(token: token) }
        }
    }

    /// A server refused this session's token. A share that was removed only affects that server;
    /// plex.tv refusing the account token too means the sign-in itself expired.
    private func serverRejected(token: String?) {
        guard let token, token == api?.token, let account = accountToken, !checkingSignIn, !signInExpired else { return }
        checkingSignIn = true
        let generation = sessionGeneration
        Task {
            defer { checkingSignIn = false }
            do { _ = try await PlexAccount.user(token: account) } catch PlexError.http(401, _) {
                guard generation == sessionGeneration else { return }
                signInExpired = true
            } catch {}
        }
    }

    // MARK: Session

    func bootstrap() async {
        let generation = sessionGeneration
        if let token = accountToken {
            // Installs from before Home support: the signed-in token is the primary one.
            if Keychain.string(for: "primaryAccountToken") == nil { Keychain.set(token, for: "primaryAccountToken") }
            if user == nil {
                let lookUp = Task {
                    guard let u = try? await PlexAccount.user(token: token), generation == sessionGeneration else { return }
                    setUser(u)
                }
                // The profile is remembered from last time, so the server needn't wait on plex.tv.
                if currentUserID == nil { await lookUp.value }
            }
            guard generation == sessionGeneration else { return }
            Task { await loadHomeUsers() }
            if servers.isEmpty { await refreshServers() } else { Task { await refreshServers() } }
        }
        if selectedServerID == nil { selectedServerID = servers.first(where: \.owned)?.id ?? servers.first?.id }
        await connect()
    }

    func signIn(token: String) async {
        let generation = sessionGeneration
        do {
            let prepared = try await PlexAccount.prepareSession(token: token)
            guard generation == sessionGeneration else { return }
            commitSession(token: prepared.token, user: prepared.user, servers: prepared.servers)
            Keychain.set(token, for: "primaryAccountToken")
            homeUsers = []
            await loadHomeUsers()
            await connect()
            resumeSuspendedDownloads()
        } catch { actionError = error.localizedDescription }
    }

    /// Commit credentials and identity together, without an await between them.
    private func commitSession(token: String, user: PlexUser, servers discovered: [PlexServer]) {
        sessionGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        suspendedDownloads = DownloadManager.shared.suspendActive()
        AudioPlayer.shared.stop()
        // The Home Screen widget showed the previous profile's Continue Watching.
        TopShelfSnapshot.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
        api = nil
        status = .idle
        ServerDirectory.shared.replaceSessionServers(discovered)
        servers = ServerDirectory.shared.servers
        Keychain.set(token, for: "accountToken")
        accountToken = token
        setUser(user)
        if selectedServer == nil { select(serverID: servers.first(where: \.owned)?.id ?? servers.first?.id) }
        contentVersion += 1
    }

    /// Signs out and goes to sign-in for a different Plex account. Downloads stay on the device.
    func switchAccount() {
        signOut()
        signInFresh = true
    }

    #if DEBUG
    /// Tests: a session in a given connection state without contacting Plex.
    func setForTesting(servers: [PlexServer], selected: String?, status: ConnectionStatus) {
        self.servers = servers
        selectedServerID = selected
        self.status = status
    }
    #endif

    func signOut() {
        browsingDownloadsOnly = false
        TopShelfSnapshot.clear()   // the Home Screen widget's Continue Watching
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
        sessionGeneration = UUID()
        connectTask?.cancel()
        connectTask = nil
        DownloadManager.shared.pauseAll()
        AudioPlayer.shared.stop()
        Keychain.set(nil as Data?, for: "accountToken")
        Keychain.set(nil as Data?, for: "primaryAccountToken")
        LibraryCache.clear()
        Task { await WatchlistStore.shared.refresh(token: nil) }
        accountToken = nil
        user = nil
        homeUsers = []
        UserDefaults.standard.removeObject(forKey: "currentUserUUID")
        DownloadManager.shared.activeUserID = nil
        ServerDirectory.shared.removeAll()
        servers = []
        select(serverID: nil)
        api = nil
        status = .idle
    }

    func refreshServers() async {
        guard let token = accountToken else { return }
        let generation = sessionGeneration
        isRefreshingServers = true
        defer { isRefreshingServers = false }
        do {
            let discovered = try await PlexAccount.servers(token: token)
            guard generation == sessionGeneration, token == accountToken else { return }
            ServerDirectory.shared.setDiscovered(discovered)
            servers = ServerDirectory.shared.servers
        } catch {
            guard generation == sessionGeneration else { return }
            servers = ServerDirectory.shared.servers  // only this session’s cached list
        }
    }

    func addManualServer(urlString: String, token: String?) async throws {
        let generation = sessionGeneration
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let tok = (token?.isEmpty ?? true) ? accountToken : token
        let identity = try await ConnectionResolver.identify(uri: trimmed, token: tok)
        guard generation == sessionGeneration else { throw CancellationError() }
        let id = identity.machineIdentifier ?? trimmed
        var server = PlexServer(name: identity.friendlyName ?? URL(string: trimmed)?.host ?? "Plex Server", clientIdentifier: id,
                                accessToken: tok, owned: true, connections: [PlexConnection(uri: trimmed, local: true, relay: false)],
                                isManual: true)
        if let existing = ServerDirectory.shared.server(id: id) {
            server.name = existing.name
            server.connections = [PlexConnection(uri: trimmed, local: true, relay: false)] + existing.connections.filter { $0.uri != trimmed }
            server.accessToken = tok ?? existing.accessToken
        }
        ServerDirectory.shared.upsert(server)
        ServerDirectory.shared.setEndpoint(trimmed, for: id)
        servers = ServerDirectory.shared.servers
        select(serverID: id)
        await connect()
    }

    /// A Jellyfin server just signed in to: saved, selected and connected.
    func addJellyfinServer(_ server: PlexServer) async {
        ServerDirectory.shared.upsert(server)
        DownloadManager.shared.refreshProgressOwnership()
        if let uri = server.connections.first?.uri { ServerDirectory.shared.setEndpoint(uri, for: server.id) }
        servers = ServerDirectory.shared.servers
        select(serverID: server.id)
        await connect()
    }

    func removeServer(_ id: String) {
        if let server = ServerDirectory.shared.server(id: id), server.isJellyfin { Task { await JellyfinAuth.signOut(server) } }
        ServerDirectory.shared.remove(id: id)
        servers = ServerDirectory.shared.servers
        if selectedServerID == id {
            select(serverID: servers.first?.id)
            Task { await connect() }
        }
    }

    func select(serverID: String?) {
        selectedServerID = serverID
        api = nil
        status = .idle
    }

    @ObservationIgnored private var connectTask: Task<Void, Never>?

    /// Network changes, foregrounding and launch can all ask to connect at once;
    /// they share one in-flight attempt instead of racing each other.
    func connect() async {
        if let running = connectTask {
            await running.value
            // Done if that attempt was for the server that's selected now.
            if selectedServer == nil || (api?.serverID == selectedServerID && status == .connected) { return }
        }
        let generation = sessionGeneration
        let task = Task { await performConnect() }
        connectTask = task
        await task.value
        if generation == sessionGeneration { connectTask = nil }
    }

    private func performConnect() async {
        let generation = sessionGeneration
        guard let server = selectedServer else { status = .idle; return }
        guard NetworkMonitor.shared.isConnected else {
            status = .failed("No network connection")
            return
        }
        status = .connecting
        do {
            let uri = try await ConnectionResolver.resolve(server)
            guard generation == sessionGeneration, !Task.isCancelled, server.id == selectedServerID, let url = URL(string: uri) else { return }
            api = PlexServerAPI(baseURL: url, token: server.accessToken, serverID: server.id)
            isLocalConnection = server.connections.first { $0.uri == uri }?.local ?? Self.looksLocal(url)
            status = .connected
            let accountToken = self.accountToken
            Task { await WatchlistStore.shared.refresh(token: accountToken) }
            Task {
                await DownloadManager.shared.syncOfflineProgress()
                await DownloadManager.shared.refreshWatchState(serverID: server.id)
                await SmartDownloads.shared.refresh()
                await DownloadManager.shared.syncPlaylistDownloads()
            }
            DownloadManager.shared.pump()
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled, server.id == selectedServerID else { return }
            // Keep a best-effort API so cached endpoints can still be tried.
            api = ServerDirectory.shared.api(for: server.id)
            status = .failed(error.localizedDescription)
        }
    }

    /// Private, link-local, CGNAT (Tailscale) and loopback addresses, `.local` names, and
    /// `*.plex.direct` names, which spell out the server's IP ("192-168-1-5.<hash>.plex.direct").
    nonisolated static func looksLocal(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasSuffix(".plex.direct"), let label = host.split(separator: ".").first {
            let parts = label.split(separator: "-", omittingEmptySubsequences: false)
            let isV4 = parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
            host = parts.joined(separator: isV4 ? "." : ":")
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        // IPv6: loopback, unique local (fc00::/7) and link-local (fe80::/10).
        guard host.contains(":") else { return false }
        return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb")
    }

    // MARK: Plex Home users

    private func setUser(_ u: PlexUser) {
        user = u
        if let uuid = u.uuid ?? u.id.map({ "plex-id:\($0)" }) {
            UserDefaults.standard.set(uuid, forKey: "currentUserUUID")
            DownloadManager.shared.activeUserID = uuid
        }
    }

    func loadHomeUsers() async {
        let generation = sessionGeneration
        guard let token = primaryToken else { return }
        if let users = try? await PlexAccount.homeUsers(token: token) {
            guard generation == sessionGeneration else { return }
            homeUsers = users
        } else if let current = accountToken, current != token, let users = try? await PlexAccount.homeUsers(token: current) {
            guard generation == sessionGeneration else { return }
            homeUsers = users
        }
    }

    /// Switches the active Plex Home user. Server tokens, watch state, On Deck
    /// and history all follow the new user.
    func switchUser(to target: PlexHomeUser, pin: String?) async throws {
        guard let token = accountToken ?? primaryToken else { throw PlexError.notSignedIn }
        guard !isSwitchingUser else { throw PlexError.unsupported("A user switch is already in progress.") }
        let generation = sessionGeneration
        isSwitchingUser = true
        defer { isSwitchingUser = false }
        var newToken: String
        do {
            newToken = try await PlexAccount.switchUser(target, pin: pin, token: token)
        } catch {
            // A managed user may not be allowed to switch; retry as the Home admin.
            guard let primary = primaryToken, primary != token else { throw error }
            newToken = try await PlexAccount.switchUser(target, pin: pin, token: primary)
        }
        // Discovery must succeed before replacing the active identity. A failed
        // request leaves the original session intact, never a hybrid of two users.
        let fallback = PlexUser(id: target.id, uuid: target.uuid, username: target.username, title: target.title, email: nil, thumb: target.thumb)
        let prepared = try await PlexAccount.prepareSession(token: newToken, fallbackUser: fallback)
        guard generation == sessionGeneration else { throw CancellationError() }
        commitSession(token: prepared.token, user: prepared.user, servers: prepared.servers)
        await connect()
        resumeSuspendedDownloads()
        contentVersion += 1
    }

    /// Reload server-driven screens (On Deck, progress, watched flags) so changes
    /// made on other devices show up, at most once a minute.
    func refreshContentIfStale() {
        guard Date().timeIntervalSince(lastContentRefresh) > 60 else { return }
        lastContentRefresh = Date()
        contentVersion += 1
        if let id = selectedServerID {
            Task {
                await DownloadManager.shared.refreshWatchState(serverID: id)
                await SmartDownloads.shared.refresh()
            }
        }
    }

    @ObservationIgnored weak var activeVideoPlayback: (any VideoQueueing)?

    /// `serverID`: where the item is from (a download from another server); else the selected server.
    func addToQueue(_ item: PlexMetadata, next: Bool, serverID: String? = nil) {
        let sid = serverID ?? selectedServerID ?? ""
        if item.kind == .track {
            if next { AudioPlayer.shared.playNext(item, serverID: sid) }
            else { AudioPlayer.shared.enqueue([item], serverID: sid) }
        } else if item.isPlayableVideo {
            guard let playback = activeVideoPlayback else { play(item); return }
            let request = playRequest(item, serverID: sid, fromStart: false)
            if next { playback.playNext(request) } else { playback.enqueue([request]) }
        }
    }

    // MARK: Playback

    func play(_ item: PlexMetadata, serverID: String? = nil, fromStart: Bool = false, queue: [PlexMetadata] = []) {
        Haptics.tap()
        let sid = serverID ?? selectedServerID ?? ""
        let request = playRequest(item, serverID: sid, fromStart: fromStart)
        let upNext = queue.filter(\.isPlayableVideo).map { playRequest($0, serverID: sid, fromStart: false) }
        let playback = VideoPresenter.present(request, upNext: upNext, app: self)
        activeVideoPlayback = playback
        // Episodes roll into the rest of the season, like the Plex apps.
        if queue.isEmpty, item.kind == .episode, let playback {
            Task { playback.enqueue(await laterEpisodes(after: item, serverID: sid).map { playRequest($0, serverID: sid, fromStart: true) }) }
        }
    }

    /// Play a list in order (playlists). `shuffle` randomizes the order.
    func playAll(_ items: [PlexMetadata], serverID: String? = nil, shuffle: Bool = false) {
        var list = items.filter(\.isPlayableVideo)
        if shuffle { list.shuffle() }
        guard let first = list.first else { return }
        play(first, serverID: serverID, fromStart: shuffle, queue: Array(list.dropFirst()))
    }

    private func playRequest(_ item: PlexMetadata, serverID sid: String, fromStart: Bool) -> VideoPlayRequest {
        let record = DownloadManager.shared.record(serverID: sid, ratingKey: item.ratingKey)
        let selected = item.forPlayback(serverID: sid)
        let local = record.flatMap { record -> URL? in
            if let saved = record.mediaID, let chosen = selected.playbackMediaID, saved != chosen { return nil }
            return DownloadManager.shared.localFileURL(for: record)
        }
        let offset = fromStart ? 0 : record?.resumeOffset(for: currentUserID, serverOffset: item.viewOffset) ?? item.viewOffset ?? 0
        return VideoPlayRequest(item: selected, serverID: sid, startMs: offset, localURL: local,
                                downloadID: local == nil ? nil : record?.id)
    }

    private func laterEpisodes(after episode: PlexMetadata, serverID: String) async -> [PlexMetadata] {
        let isLater: (PlexMetadata) -> Bool = {
            ($0.parentIndex ?? 0, $0.index ?? 0) > (episode.parentIndex ?? 0, episode.index ?? 0)
        }
        if isOnline, let api, let later = try? await api.episodes(after: episode, limit: 10) {
            return later
        }
        return DownloadManager.shared.records
            .filter { $0.state == .completed && $0.serverID == serverID && $0.metadata.grandparentRatingKey == episode.grandparentRatingKey }
            .map(\.metadata).filter(isLater)
            .sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
    }

    func libraryChanged() { contentVersion += 1 }

    func playbackEnded() {
        lastContentRefresh = Date()
        contentVersion += 1
        // An episode may have just been finished: delete it / queue the next one.
        if !SmartDownloads.shared.rules.isEmpty {
            Task { await SmartDownloads.shared.refresh() }
        }
    }

    func markWatched(_ item: PlexMetadata, watched: Bool) async {
        guard let api else { actionError = "Connect to a server to change watch status."; return }
        do {
            if watched { try await api.scrobble(item.ratingKey) } else { try await api.unscrobble(item.ratingKey) }
            Haptics.success()
            contentVersion += 1
        } catch { actionError = error.localizedDescription }
    }

    /// From `browseAPI`, so artwork saved in the image cache still shows when the app starts offline.
    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        browseAPI?.imageURL(path, width: width, height: height)
    }
}


/// Shared content boundary used by every browsing surface.
enum MediaMode: String, CaseIterable, Identifiable {
    case music, watch
    var id: String { rawValue }
    var title: String { self == .music ? "Listen" : "Watch" }
    var icon: String { self == .music ? "music.note" : "play.rectangle" }
    var playlistType: String { self == .music ? "audio" : "video" }
    func includes(_ item: PlexMetadata) -> Bool {
        if item.kind == .playlist { return item.playlistType == playlistType }
        switch self {
        case .music: return [.artist, .album, .track].contains(item.kind)
        case .watch: return [.movie, .show, .season, .episode, .clip, .collection].contains(item.kind)
        }
    }
    func includes(section: PlexDirectory) -> Bool {
        self == .music ? section.type == "artist" : ["movie", "show"].contains(section.type)
    }
    func filter(_ hubs: [PlexHub]) -> [PlexHub] {
        hubs.compactMap { hub in
            var result = hub
            result.metadata = hub.metadata.filter { includes($0) }
            return result.metadata.isEmpty ? nil : result
        }
    }
}

private struct MediaModeKey: EnvironmentKey { static let defaultValue: MediaMode = .watch }
extension EnvironmentValues {
    var mediaMode: MediaMode {
        get { self[MediaModeKey.self] }
        set { self[MediaModeKey.self] = newValue }
    }
}
