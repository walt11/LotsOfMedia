import SwiftUI

@main
struct LotsOfMediaTVApp: App {
    @State private var session = TVSession()

    init() {
        // Same Pro purchase as on iPhone and iPad (Universal Purchase).
        #if DEBUG
        // Development and screenshots: `-proUnlocked` behaves as if Pro were bought.
        if ProcessInfo.processInfo.arguments.contains("-proUnlocked") { ProStore.unlockedForTesting = true }
        #endif
        MainActor.assumeIsolated {
            ProStore.shared.start()
            TVTabBarFocusWatcher.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-designReview") { TVDesignReviewView() } else { TVRootView() }
                #else
                TVRootView()
                #endif
            }
                .environment(session)
                .environment(ProStore.shared)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-designReview") { return }
                    #endif
                    await session.bootstrap()
                }
        }
    }
}

struct TVRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(TVSession.self) private var session
    @State private var tab: Tab = .home
    @State private var homePath = NavigationPath()
    @State private var playRequest: TVPlayRequest?
    /// A Top Shelf item's page, shown over the app so Back always returns to where you were
    /// (pushed onto Home's stack before it had appeared, Back left the app instead of popping it).
    @State private var openedItem: PlexMetadata?
    @State private var askWhoIsWatching = false
    /// Once per launch.
    @State private var askedWhoIsWatching = false
    /// A Top Shelf link waiting on "Who's Watching?": opened once someone's picked.
    @State private var pendingLink: URL?
    /// The profile "Who's Watching?" starts on (the PIN for a Top Shelf item's protected profile).
    @State private var suggestedProfile: PlexHomeUser?
    private var live: LiveTVStore { .shared }
    private var music: TVMusicPlayer { .shared }

    enum Tab: Hashable { case home, library, live, nowPlaying, search, settings }

    var body: some View {
        if !session.isSignedIn {
            TVSignInView()
        } else {
            TabView(selection: $tab) {
                NavigationStack(path: $homePath) { TVHomeView().tvDestinations() }
                    .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)
                if live.isAvailable {
                    NavigationStack { TVLiveTVView().tvDestinations() }
                        .tabItem { Label("Live TV", systemImage: "antenna.radiowaves.left.and.right") }.tag(Tab.live)
                }
                NavigationStack { TVLibraryView().tvDestinations() }
                    .tabItem { Label("Library", systemImage: "film.stack") }.tag(Tab.library)
                if music.isActive {
                    TVNowPlayingView()
                        .tabItem { Label("Now Playing", systemImage: "waveform") }.tag(Tab.nowPlaying)
                }
                NavigationStack { TVSearchView().tvDestinations() }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
                NavigationStack { TVSettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
            }
            .id("\(session.selectedServerID ?? "")-\(session.user?.uuid ?? "")")
            .opacity(hidesDashboardForProfileSelection ? 0 : 1)
            .disabled(hidesDashboardForProfileSelection)
            .overlay {
                if hidesDashboardForProfileSelection {
                    ProgressView("Loading profiles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(TVTheme.background.ignoresSafeArea())
            .task(id: session.status == .connected) {
                guard session.status == .connected, let api = session.api else { return }
                #if DEBUG
                // Development shortcuts first, so they don't wait on the Live TV check. The sample guide
                // loads after startup settles (connecting resets the Live TV store).
                try? await Task.sleep(for: .milliseconds(500))
                if ProcessInfo.processInfo.arguments.contains("-tvLiveSample"), let id = session.selectedServer?.id ?? session.selectedServerID { live.loadSample(serverID: id) }
                await openFromLaunchArguments()
                #endif
                // Last session's music queue comes back paused (same server only).
                music.restore(session: session)
                await live.refresh(api: api)
            }
            .onOpenURL { url in
                // A Top Shelf item answers "Who's Watching?" itself: the app opens as its profile.
                if TopShelfSnapshot.parse(url) != nil { askedWhoIsWatching = true }
                Task { await open(url) }
            }
            .onChange(of: askWhoIsWatching) { _, asking in
                guard !asking else { return }
                suggestedProfile = nil
                guard let url = pendingLink else { return }
                pendingLink = nil
                Task { await open(url, profileChosen: true) }
            }
            // Another profile: pages and players opened as the previous one would use its access.
            .onChange(of: session.user?.uuid) { old, _ in
                guard old != nil else { return }
                homePath = NavigationPath()
                playRequest = nil
                openedItem = nil
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { session.refreshContentIfStale() } }
            // Live TV keeps playing in its corner window only while you're on the Live TV tab.
            .onChange(of: tab) { _, new in if new != .live { TVLiveNow.shared.stop() } }
            .fullScreenCover(item: Binding(get: { TVQuickPlay.shared.request }, set: { TVQuickPlay.shared.request = $0 })) {
                TVPlayerView(request: $0)
            }
            // The open tab went away (music stopped, the server has no DVR any more): back to Home.
            .onChange(of: music.isActive) { _, active in if !active, tab == .nowPlaying { tab = .home } }
            .onChange(of: live.isAvailable) { _, available in if !available, tab == .live { tab = .home } }
            .fullScreenCover(item: $playRequest) { TVPlayerView(request: $0) }
            .fullScreenCover(item: $openedItem) { item in
                NavigationStack { TVDetailView(item: item).tvDestinations() }
                    .background(TVTheme.background.ignoresSafeArea())
            }
            // Plex Home with Pro: who's watching, once when the app opens.
            .fullScreenCover(isPresented: $askWhoIsWatching) { TVProfilePicker(suggested: suggestedProfile) }
            .onChange(of: asksWhoIsWatching, initial: true) { _, shouldAsk in
                guard shouldAsk, !askedWhoIsWatching else { return }
                askedWhoIsWatching = true
                askWhoIsWatching = true
            }
        }
    }

    /// Top Shelf links: lotsofmedia://item/<key> opens it, lotsofmedia://play/<key> plays it. A link
    /// names its server: the app switches to it if it's another of yours, and ignores the link if not.
    /// A link also names the profile whose Continue Watching it's from, and stands in for
    /// "Who's Watching?": the app opens as that profile (asking only for its PIN, if it has one).
    /// Once someone else has been picked instead (`profileChosen`), the link opens the item's page
    /// as them (if they can see it) rather than resuming another person's progress.
    private func open(_ url: URL, profileChosen: Bool = false) async {
        guard let link = TopShelfSnapshot.parse(url) else { return }
        if let wanted = link.server, wanted != session.selectedServer?.id {
            guard let server = session.servers.first(where: { $0.id == wanted }) else { return }
            await session.select(server)
        }
        for _ in 0..<20 where session.status != .connected { try? await Task.sleep(for: .milliseconds(500)) }
        // Which profiles there are (and so whether the link's is one of them) is known once they're loaded.
        for _ in 0..<10 where !session.homeUsersLoaded { try? await Task.sleep(for: .milliseconds(500)) }
        if !profileChosen, let wanted = link.user {
            switch await switchToProfile(wanted) {
            case .switched: break
            case .needsPIN(let profile):
                suggestedProfile = profile
                pendingLink = url
                askWhoIsWatching = true
                return
            case .unavailable:
                // Not a profile this account can switch to: whoever's watching says who they are.
                if wanted != session.user?.uuid, asksWhoIsWatching {
                    pendingLink = url
                    askWhoIsWatching = true
                    return
                }
            }
        }
        for _ in 0..<20 where session.status != .connected { try? await Task.sleep(for: .milliseconds(500)) }
        let otherProfile = link.user != nil && link.user != session.user?.uuid
        guard let api = session.api, link.server == nil || api.serverID == link.server,
              let item = try? await api.metadata(link.key) else { return }
        tab = .home
        openedItem = nil
        if link.action == "play" && !otherProfile {
            playRequest = TVPlayRequest(item: item, resume: true)
        } else {
            openedItem = item
        }
    }

    /// Keep the presenting view neutral until profiles arrive and while the picker opens.
    /// The tab view stays mounted so startup tasks and Top Shelf links still run.
    private var hidesDashboardForProfileSelection: Bool {
        if askWhoIsWatching { return true }
        guard !askedWhoIsWatching, TVProfilePicker.isEnabled, ProStore.shared.isUnlocked,
              session.token != nil, session.selectedServer?.isJellyfin != true else { return false }
        return !session.homeUsersLoaded || session.canSwitchUsers
    }

    private var asksWhoIsWatching: Bool { session.canSwitchUsers && TVProfilePicker.isEnabled && ProStore.shared.isUnlocked }

    private enum ProfileSwitch { case switched, needsPIN(PlexHomeUser), unavailable }

    /// Becomes the Plex Home profile with this id (already being it counts), answering
    /// "Who's Watching?". A PIN-protected profile still needs its PIN wherever "Who's Watching?"
    /// would have asked for it. Switching profiles is Pro.
    private func switchToProfile(_ uuid: String) async -> ProfileSwitch {
        let profile = session.homeUsers.first { $0.uuid == uuid }
        if let profile, profile.isProtected, asksWhoIsWatching, profile.uuid != session.currentHomeUser?.uuid { return .needsPIN(profile) }
        if uuid == session.user?.uuid { askWhoIsWatching = false; return .switched }
        guard ProStore.shared.isUnlocked, let profile else { return .unavailable }
        if profile.isProtected { return .needsPIN(profile) }
        askWhoIsWatching = false
        do { try await session.switchUser(profile, pin: nil) } catch { return .unavailable }
        return .switched
    }

    #if DEBUG
    /// Development and screenshots: `-tvOpen <ratingKey>` opens an item, `-tvPlay <ratingKey>` plays it,
    /// `-tvTab library|live|search|settings|nowPlaying` picks a tab, `-tvMusic <albumKey>` plays an album.
    private func openFromLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard let api = session.api else { return }
        // Let a tab that just became available (the sample Live TV tab) appear before selecting it.
        try? await Task.sleep(for: .milliseconds(300))
        if let key = value("-tvMusic"), let tracks = try? await api.children(key) { music.play(tracks, session: session) }
        switch value("-tvTab") {
        case "library": tab = .library
        case "live": tab = .live
        case "search": tab = .search
        case "settings": tab = .settings
        case "nowPlaying": tab = .nowPlaying
        default: break
        }
        if let key = value("-tvOpen"), let item = try? await api.metadata(key) { homePath.append(item) }
        // `-tvPlayAt <seconds>` starts `-tvPlay` at that point (e.g. near the end, to see Up Next).
        if let key = value("-tvPlay"), var item = try? await api.metadata(key) {
            if let at = value("-tvPlayAt").flatMap(Int.init) { item.viewOffset = at * 1000 }
            playRequest = TVPlayRequest(item: item, resume: true)
        }
    }
    #endif
}

extension View {
    /// Every browsing tab opens items the same way.
    func tvDestinations() -> some View {
        navigationDestination(for: PlexMetadata.self) { TVDetailView(item: $0) }
            .navigationDestination(for: TVPerson.self) { TVPersonView(person: $0) }
            .navigationDestination(for: TVPhotoAlbum.self) { TVPhotoAlbumView(album: $0) }
    }
}

/// Shown while connecting or when the server can't be reached.
struct TVConnectionStatus: View {
    @Environment(TVSession.self) private var session

    var body: some View {
        switch session.status {
        case .connecting, .idle:
            ProgressView("Connecting to \(session.selectedServer?.name ?? "your server")…")
        case .failed(let message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.secondary)
                Text("Can't reach \(session.selectedServer?.name ?? "your server")").font(.title2.bold())
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await session.connect() } }.buttonStyle(TVActionStyle())
            }
            .frame(maxWidth: 900)
        case .connected:
            EmptyView()
        }
    }
}
