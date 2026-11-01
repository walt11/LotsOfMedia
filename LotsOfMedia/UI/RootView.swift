import SwiftUI
import AuthenticationServices
import CoreSpotlight

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProStore.self) private var pro
    /// "Who's Watching?", once per launch (see `WhoIsWatching`).
    @State private var askWhoIsWatching = false
    @State private var askedWhoIsWatching = false

    var body: some View {
        Group {
            if app.needsOnboarding && !app.browsingDownloadsOnly {
                SignInView()
            } else {
                MainTabView().id("\(app.currentUserID ?? "")-\(app.selectedServerID ?? "")")
            }
        }
        .sheet(item: Binding(get: { app.downloadPreview }, set: { app.downloadPreview = $0 })) { item in
            ProGate(.downloads) {
                DownloadPreviewView(item: item, quality: DownloadQuality.choices(for: item).contains(downloads.defaultQuality) ? downloads.defaultQuality : .original)
            }
        }
        .onOpenURL { url in Task { await open(url) } }
        .fullScreenCover(isPresented: $askWhoIsWatching) { UserPickerView() }
        .onChange(of: app.canSwitchUsers, initial: true) { _, can in
            guard can, !askedWhoIsWatching, pro.isUnlocked, WhoIsWatching.isEnabled, !app.needsOnboarding else { return }
            askedWhoIsWatching = true
            askWhoIsWatching = true
        }
        // Shortcuts and Siri (App Intents) and Spotlight results for downloads.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = SpotlightIndex.downloadID(from: activity) { IntentRouter.shared.pending = .openDownload(id) }
        }
        .task(id: IntentRouter.shared.pending) {
            guard let action = IntentRouter.shared.pending else { return }
            IntentRouter.shared.pending = nil
            await perform(action)
        }
        .alert("Couldn't Complete Action", isPresented: Binding(get: { app.actionError != nil || downloads.actionError != nil }, set: { if !$0 { app.actionError = nil; downloads.actionError = nil } })) {
            Button("OK") { app.actionError = nil; downloads.actionError = nil }
        } message: { Text(app.actionError ?? downloads.actionError ?? "") }
        .alert("Plex Sign-In Expired", isPresented: Binding(get: { app.signInExpired }, set: { app.signInExpired = $0 })) {
            Button("Sign In Again") { app.signInExpired = false; app.signOut() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Plex no longer accepts this device's sign-in, so your servers can't be reached. Your downloads stay on this iPhone.")
        }
    }

    /// Home Screen widget: lotsofmedia://play/<key>?server=<id> resumes that item on that server
    /// (switching to it if it's another of yours; a link for a server you don't have is ignored).
    private func open(_ url: URL) async {
        guard let link = TopShelfSnapshot.parse(url) else { return }
        if let wanted = link.server, wanted != app.selectedServerID {
            guard app.servers.contains(where: { $0.id == wanted }) else { return }
            app.select(serverID: wanted)
            await app.connect()
        }
        guard let api = await connectedAPI(), link.server == nil || api.serverID == link.server,
              let item = try? await api.metadata(link.key) else { return }
        if item.isPlayableVideo { app.play(item) }
    }

    /// The live connection, waiting up to 10 seconds for one that's under way (just launched).
    private func connectedAPI() async -> PlexServerAPI? {
        for _ in 0..<20 where app.api == nil || app.status == .connecting { try? await Task.sleep(for: .milliseconds(500)) }
        return app.api
    }

    private func perform(_ action: IntentRouter.Action) async {
        switch action {
        case .resume:
            if let first = TopShelfSnapshot.load()?.items.first {
                await open(TopShelfSnapshot.link("play", first.ratingKey, server: TopShelfSnapshot.load()?.serverID))
            } else if let api = await connectedAPI(), let item = try? await api.continueWatching().first(where: \.isPlayableVideo) {
                app.play(item)
            }
        case .playShow(let name):
            guard let api = await connectedAPI() else { app.actionError = "Connect to your server to play a show."; return }
            let shows = ((try? await api.search(name)) ?? []).flatMap(\.metadata).filter { $0.kind == .show }
            guard let show = shows.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) ?? shows.first else {
                app.actionError = "Couldn't find a show called “\(name)”."
                return
            }
            let episodes = (try? await api.allLeaves(show.ratingKey)) ?? []
            if let next = episodes.first(where: { $0.progress != nil }) ?? episodes.first(where: { ($0.viewCount ?? 0) == 0 }) ?? episodes.first {
                app.play(next)
            }
        case .downloads:
            app.mediaMode = .watch
            app.selectedTab = .downloads
        case .openDownload(let id):
            guard let rec = downloads.records.first(where: { $0.id == id }) else { return }
            if rec.isAudio { AudioPlayer.shared.play(downloads: [rec]) } else { app.play(rec.metadata, serverID: rec.serverID) }
        }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var live
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var visited: Set<MediaMode> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                OfflineBanner()
                AirPlayBanner()
            }
            .frame(maxWidth: .infinity)
            .background(Cinema.background)

            // Give navigation containers their own bounds below the mode switch.
            // An outer safe-area inset can let native navigation bars extend behind it.
            ZStack {
                ForEach(MediaMode.allCases) { mode in
                    if visited.contains(mode) || app.mediaMode == mode {
                        ModeShell(mode: mode)
                            .environment(\.mediaMode, mode)
                            .opacity(app.mediaMode == mode ? 1 : 0)
                            .allowsHitTesting(app.mediaMode == mode)
                            .accessibilityHidden(app.mediaMode != mode)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Native tab bars extend into the bottom safe area; do not clip this container.
        }
        .overlay { DownloadEventBanner() }
        .environment(\.mediaMode, app.mediaMode)
        .onAppear { visited.insert(app.mediaMode) }
        .onChange(of: app.mediaMode) { old, new in visited.formUnion([old, new]) }
        .task(id: app.api?.baseURL) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-liveSample"), let api = app.api { live.loadSample(serverID: api.serverID); return }
            #endif
            if let api = app.api { await live.refresh(api: api) } else { live.clearSession() }
        }
    }
}

struct MediaModePicker: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Picker("App mode", selection: $app.mediaMode) {
            ForEach(MediaMode.allCases) { mode in Label(mode.title, systemImage: mode.icon).tag(mode) }
        }.pickerStyle(.segmented).accessibilityLabel("Listen or Watch mode")
    }
}

/// iOS 26.1+: the mini player becomes the tab bar's accessory, and the tab bar
/// shrinks while scrolling down, as in Apple Music.
private struct TabBarPlayerModifier: ViewModifier {
    @Environment(AudioPlayer.self) private var audio
    let mode: MediaMode
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: mode == .music && audio.current != nil) { TabBarMiniPlayer() }
                .tabBarMinimizeBehavior(.onScrollDown)
                .environment(\.miniPlayerInTabBar, true)
        } else {
            content
        }
    }
}

/// Retains each mode's navigation stacks and browsing state while the other is active.
private struct ModeShell: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var live
    @Environment(\.horizontalSizeClass) private var sizeClass
    let mode: MediaMode
    @State private var visitedTabs: Set<AppState.Tab> = [.home]
    @State private var columns: NavigationSplitViewVisibility = .all
    private var selection: AppState.Tab { app.tab(for: mode) }
    private var tabs: [AppState.Tab] {
        [.home, .library] + (mode == .watch && live.isAvailable ? [.live] : []) + [.search, .downloads]
    }
    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columns) {
                    List {
                        MediaModePicker().listRowBackground(Color.clear)
                        ForEach(tabs, id: \.self) { tab in
                            Button { app.selectTab(tab, for: mode) } label: {
                                Label(title(tab), systemImage: icon(tab)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .listRowBackground(selection == tab ? Cinema.accent.opacity(0.18) : Color.clear)
                            .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        }
                    }
                    // The picker below the title is the mode switch; the title is the app's name.
                    .pageTitle("LotsOfMedia")
                    .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
                } detail: {
                    ZStack {
                        ForEach(tabs, id: \.self) { tab in
                            if visitedTabs.contains(tab) || selection == tab {
                                stack(tab)
                                    .opacity(selection == tab ? 1 : 0)
                                    .allowsHitTesting(selection == tab)
                                    .accessibilityHidden(selection != tab)
                            }
                        }
                    }
                    // iPad: one mini player under every tab (pages inside the split view don't show their own).
                    .environment(\.miniPlayerInTabBar, true)
                    // While the sidebar (and its picker) is showing, pages don't repeat the switch.
                    .environment(\.modePickerInSidebar, columns == .all)
                    .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerBar() }
                }
            } else {
                TabView(selection: Binding(get: { selection }, set: { app.selectTab($0, for: mode) })) {
                    ForEach(tabs, id: \.self) { tab in
                        stack(tab).tabItem { Label(title(tab), systemImage: icon(tab)) }.tag(tab)
                    }
                }
                .modifier(TabBarPlayerModifier(mode: mode))
            }
        }
        .onChange(of: selection) { old, new in visitedTabs.formUnion([old, new]) }
        .onChange(of: live.isAvailable) { if !live.isAvailable && selection == .live { app.selectTab(.home, for: mode) } }
    }
    private func stack(_ tab: AppState.Tab) -> some View {
        NavigationStack {
            Group {
                switch tab {
                case .home:
                    if mode == .music { MusicHomeView() } else { HomeView() }
                case .library: LibrariesView()
                case .live: ProGate(.liveTV, inline: true) { LiveTVView() }
                case .search: SearchView()
                case .downloads: DownloadsView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .miniPlayerClearance()
            .withRoutes()
        }.miniPlayerInset()
    }
    private func title(_ tab: AppState.Tab) -> String {
        switch tab {
        case .home: return "Home"
        case .library: return "Library"
        case .live: return "Live TV"
        case .search: return "Search"
        case .downloads: return "Downloads"
        }
    }
    private func icon(_ tab: AppState.Tab) -> String {
        switch tab {
        case .home: return "house.fill"
        case .library: return mode == .music ? "music.note.list" : "film.stack"
        case .live: return "antenna.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle.fill"
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var browser = PlexAuthBrowser()
    @State private var working = false
    @State private var linkPin: PlexAccount.Pin?
    @State private var error: String?
    @State private var showManual = false
    @State private var showJellyfin = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Cinema.accent)
                    Text("LotsOfMedia").font(.largeTitle.bold())
                    Text("Your movies, shows and music. Connect Plex or Jellyfin to make yourself at home.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }

                if let pin = linkPin {
                    VStack(spacing: 10) {
                        Text("Go to plex.tv/link and enter").foregroundStyle(.secondary)
                        Text(pin.code)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .kerning(6)
                            .textSelection(.enabled)
                        Link("Open plex.tv/link", destination: URL(string: "https://plex.tv/link")!)
                        ProgressView().padding(.top, 4)
                        Button("Cancel") { cancelPolling() }.padding(.top, 4)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 12) {
                        Button {
                            Task { await signInWithBrowser() }
                        } label: {
                            Label("Sign in with Plex", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .prominentButton()
                        .disabled(working)

                        Button {
                            Task { await signInWithCode() }
                        } label: {
                            Label("Sign in with a code", systemImage: "number")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(working)

                        Button("Use a different Plex account") { Task { await signInWithBrowser(fresh: true) } }
                            .font(.subheadline)
                            .padding(.top, 4)
                            .disabled(working)
                        Button {
                            showJellyfin = true
                        } label: {
                            Label("Sign in to Jellyfin", systemImage: "server.rack")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(working)
                        Button("Connect to a server manually") { showManual = true }
                            .font(.subheadline)
                        if !downloads.records.isEmpty {
                            Button("Keep using downloads offline") { app.browsingDownloadsOnly = true }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 32)
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: 480)
            .padding(.top, 48)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            }
            .background(Cinema.background)
            .sheet(isPresented: $showManual) { ManualServerView() }
            .sheet(isPresented: $showJellyfin) { JellyfinSignInView() }
        }
    }

    private func signInWithBrowser(fresh: Bool = false) async {
        working = true
        error = nil
        defer { working = false }
        do {
            let pin = try await PlexAccount.createPin(strong: true)
            startPolling(pin)
            // Plex shows "you can close this window" after approval; the poll
            // closes the browser for the user as soon as the PIN is claimed.
            await browser.open(PlexAccount.authURL(for: pin), fresh: fresh || app.signInFresh)
            app.signInFresh = false
            if !isPolling { return }  // poll already signed in and closed the browser
            // The user closed the browser – check a few more times in case approval beat the poll.
            for _ in 0..<5 {
                if let token = try? await PlexAccount.checkPin(pin.id).authToken {
                    cancelPolling()
                    await app.signIn(token: token)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            cancelPolling()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signInWithCode() async {
        error = nil
        do {
            let pin = try await PlexAccount.createPin(strong: false)
            linkPin = pin
            startPolling(pin)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startPolling(_ pin: PlexAccount.Pin) {
        pollTask?.cancel()
        pollTask = Task {
            let deadline = Date().addingTimeInterval(TimeInterval(pin.expiresIn ?? 900))
            while !Task.isCancelled, Date() < deadline {
                if let token = try? await PlexAccount.checkPin(pin.id).authToken, !token.isEmpty {
                    linkPin = nil
                    pollTask = nil
                    browser.close()
                    await app.signIn(token: token)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            linkPin = nil
        }
    }

    private var isPolling: Bool { pollTask != nil }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        linkPin = nil
    }
}

struct ManualServerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:32400", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("X-Plex-Token (optional if signed in)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                } header: {
                    Text("Server address")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .pageTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Connect") { Task { await connect() } }.disabled(url.isEmpty)
                    }
                }
            }
        }
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await app.addManualServer(urlString: url, token: token.isEmpty ? nil : token)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ServerPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showManual = false
    @State private var showJellyfin = false

    var body: some View {
        List {
            Section {
                ForEach(app.servers) { server in
                    Button {
                        app.select(serverID: server.id)
                        Task { await app.connect() }
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                            VStack(alignment: .leading) {
                                Text(server.name).foregroundStyle(.primary)
                                Text(server.kindLabel(local: server.id == app.selectedServerID && app.isOnline
                                                      ? app.isLocalConnection : server.lastConnectionIsLocal))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == app.selectedServerID { Image(systemName: "checkmark").foregroundStyle(Cinema.accent) }
                        }
                    }
                    .swipeActions {
                        if server.isManual {
                            Button(role: .destructive) { app.removeServer(server.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            } footer: {
                if app.servers.isEmpty { Text("No servers found for this account.") }
            }
            Section {
                Button { showManual = true } label: { Label("Add Plex Server Manually", systemImage: "plus") }
                Button { showJellyfin = true } label: { Label("Add Jellyfin Server", systemImage: "plus.rectangle.on.rectangle") }
                if app.isSignedIn {
                    Button { Task { await app.refreshServers() } } label: {
                        HStack {
                            Label("Refresh Server List", systemImage: "arrow.clockwise")
                            if app.isRefreshingServers { Spacer(); ProgressView() }
                        }
                    }
                }
            }
        }
        .pageTitle("Servers")
        .sheet(isPresented: $showManual) { ManualServerView() }
        .sheet(isPresented: $showJellyfin) { JellyfinSignInView() }
    }
}

/// Signs in to a Jellyfin server with a username and password, or Quick Connect.
struct JellyfinSignInView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var server: JellyfinAuth.ServerInfo?
    @State private var quickConnectAvailable = false
    @State private var quickConnect: JellyfinAuth.QuickConnect?
    @State private var pollTask: Task<Void, Never>?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8096", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(server != nil)
                    if let server {
                        LabeledContent(server.name, value: "Jellyfin \(server.version)")
                    }
                } header: {
                    Text("Server address")
                }
                if server != nil {
                    Section {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button { Task { await signIn() } } label: {
                            HStack { Text("Sign In"); if working { Spacer(); ProgressView() } }
                        }
                        .disabled(username.isEmpty || working)
                    } header: {
                        Text("Account")
                    }
                    if quickConnectAvailable {
                        Section {
                            if let quickConnect {
                                Text(quickConnect.code)
                                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                                    .kerning(6)
                                    .frame(maxWidth: .infinity)
                                    .textSelection(.enabled)
                                HStack { ProgressView(); Text("Waiting for approval…").foregroundStyle(.secondary) }
                            } else {
                                Button("Use Quick Connect") { Task { await startQuickConnect() } }
                            }
                        } header: {
                            Text("Quick Connect")
                        } footer: {
                            Text("Enter the code in the Jellyfin app or web page where you're signed in (your profile → Quick Connect).")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .pageTitle("Jellyfin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if server == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if working { ProgressView() } else {
                            Button("Next") { Task { await findServer() } }.disabled(address.isEmpty)
                        }
                    }
                }
            }
            .onDisappear { pollTask?.cancel() }
        }
    }

    private func findServer() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let found = try await JellyfinAuth.info(address: address)
            server = found
            quickConnectAvailable = await JellyfinAuth.quickConnectEnabled(found)
        } catch {
            self.error = "Couldn't reach a Jellyfin server there. \(error.localizedDescription)"
        }
    }

    private func signIn() async {
        guard let server else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            await finish(try await JellyfinAuth.signIn(server, username: username, password: password))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startQuickConnect() async {
        guard let server else { return }
        error = nil
        do {
            let qc = try await JellyfinAuth.startQuickConnect(server)
            quickConnect = qc
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    if await JellyfinAuth.checkQuickConnect(server, qc) {
                        do { await finish(try await JellyfinAuth.signIn(server, quickConnect: qc)) } catch { self.error = error.localizedDescription }
                        return
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish(_ signedIn: PlexServer) async {
        pollTask?.cancel()
        await app.addJellyfinServer(signedIn)
        dismiss()
    }
}

/// Wraps ASWebAuthenticationSession so the app can close it programmatically
/// once the Plex PIN has been claimed (there is no redirect back to the app).
@MainActor
final class PlexAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// `fresh`: a private browser session, so plex.tv asks which account to use
    /// rather than signing in with the one Safari remembers.
    func open(_ url: URL, fresh: Bool = false) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "lotsofmedia") { _, _ in
                cont.resume()
            }
            session.presentationContextProvider = self
            // Normally reuse Safari's plex.tv login if there is one.
            session.prefersEphemeralWebBrowserSession = fresh
            self.session = session
            if !session.start() { cont.resume() }
        }
        session = nil
    }

    func close() { session?.cancel() }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}
