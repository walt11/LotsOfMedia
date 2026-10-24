import SwiftUI
import WidgetKit

// MARK: - Home

/// The connected server's name, styled identically wherever it appears.
struct ServerLabel: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Label(app.selectedServer?.name ?? "No server", systemImage: "server.rack")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct HomeView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @State private var continueWatching: [PlexMetadata] = []
    @State private var nextEpisodes: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []
    /// Picks for a holiday coming up (Halloween, Christmas…), from the library.
    @State private var holiday: Holiday?
    @State private var holidayItems: [PlexMetadata] = []
    @State private var loading = false
    @State private var error: String?

    /// Up to six items with good artwork: what you're in the middle of, then what's new.
    private var heroItems: [PlexMetadata] {
        // Hub ids vary by server version: "home.movies.recent", "movie.recentlyadded"…
        let recentHubs = hubs.filter {
            let id = ($0.hubIdentifier ?? "").lowercased()
            return id.contains("recent") || $0.title.lowercased().hasPrefix("recently added")
        }
        // Interleave rows (a movie, a show, a movie…) so the carousel isn't all one type.
        var recent: [PlexMetadata] = []
        for i in 0..<6 { for hub in recentHubs where i < hub.metadata.count { recent.append(hub.metadata[i]) } }
        var seen = Set<String>()
        return (continueWatching.prefix(2) + recent)
            .filter { [.movie, .show, .episode, .season].contains($0.kind) && ($0.backdrop != nil) }
            .filter { seen.insert($0.kind == .episode ? ($0.grandparentRatingKey ?? $0.ratingKey) : $0.ratingKey).inserted }
            .prefix(6).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DownloadStatusPill()
                if hubs.isEmpty && continueWatching.isEmpty, ConnectionNotice.problem(app) != nil {
                    ConnectionNotice()
                } else if (app.status == .connecting || loading) && hubs.isEmpty && continueWatching.isEmpty {
                    // The page's shape while it loads, instead of a spinner that jumps to content.
                    SkeletonHome()
                }
                ForEach(homeLayout.order.filter { !homeLayout.hidden.contains($0) }, id: \.self) { id in homeSection(id) }
                if app.isOnline, !loading, error == nil, hubs.allSatisfy({ $0.metadata.isEmpty }), continueWatching.isEmpty,
                   ConnectionNotice.problem(app) == nil {
                    EmptyStateView(title: "Nothing on Deck", systemImage: "sparkles.tv",
                                   message: "Browse your libraries in the Library tab.")
                }
                if let error, hubs.isEmpty, app.isOnline {
                    EmptyStateView(title: "Couldn't Load", systemImage: "exclamationmark.triangle", message: error)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .homeTitle(.watch)
        .refreshable { await load() }
        .task(id: "\(app.api?.baseURL.absoluteString ?? "")-\(app.contentVersion)") { await load() }
    }

    private var homeLayout: MediaPreferences.HomeLayout { MediaPreferences.shared.layout(scope: app.preferenceScope, mode: .watch) }
    @ViewBuilder private func homeSection(_ id: String) -> some View {
        switch id {
        case "resume":
                if !continueWatching.filter({ $0.progress != nil }).isEmpty {
                    ContinueWatchingRow(items: continueWatching.filter { $0.progress != nil }) { removed in
                        continueWatching.removeAll { $0.id == removed.id }
                    }
                }
        case "recent":
                ForEach(hubs.filter { hubRank($0) == 0 }) { hub in
                    // New episodes and seasons show as their show, once each.
                    if !hub.metadata.isEmpty { HubRow(title: hub.title, items: ShowGrouping.showLevel(hub.metadata)) }
                }
        case "holiday":
                if let holiday, holidayItems.count >= 3 {
                    HubRow(title: holiday.rowTitle, items: holidayItems)
                }
        case "next":
                if !nextEpisodes.isEmpty {
                    HubRow(title: "Next Episodes", items: nextEpisodes, wide: true)
                }
        case "recommendations":
                ForEach(hubs.filter { hubRank($0) != 0 }.sorted { hubRank($0) < hubRank($1) }) { hub in
                    if !hub.metadata.isEmpty, !isContinueHub(hub) {
                        HubRow(title: hub.title, items: hub.metadata,
                               wide: hub.type == "clip" || hub.style == "hero",
                               moreRoute: (hub.more ?? false) ? hub.key.map { Route.hub(key: $0, title: hub.title) } : nil)
                    }
                }
        case "featured":
                if !heroItems.isEmpty { HeroCarousel(items: heroItems) }
        case "favorites": FavoritesHomeSection()
        case "watchLater": WatchLaterHomeSection()
        default: EmptyView()
        }
    }

    private func hubRank(_ hub: PlexHub) -> Int {
        let name = ((hub.hubIdentifier ?? "") + hub.title).lowercased()
        if name.contains("recent") { return 0 }
        if name.contains("ondeck") || name.contains("next") { return 1 }
        return 2
    }

    private func isContinueHub(_ hub: PlexHub) -> Bool {
        let id = (hub.hubIdentifier ?? "").lowercased()
        let title = hub.title.lowercased()
        return id.contains("continue") || id.contains("ondeck") || id.contains("inprogress")
            || title == "continue watching" || title == "on deck"
    }

    private func load() async {
        guard let api = app.browseAPI else { return }
        loading = true
        defer { loading = false }
        async let cw = try? api.continueWatching()
        async let h = api.homeHubs()
        async let deck = try? api.container("/library/onDeck").metadata
        let watching = await cw ?? []
        let upcoming = await deck ?? []
        guard !Task.isCancelled else { return }
        continueWatching = watching.filter { mediaMode.includes($0) }
        if mediaMode == .watch { HomeWidgetData.save(continueWatching, app: app) }
        var seen = Set<String>()
        nextEpisodes = (upcoming + watching).filter { $0.kind == .episode && $0.progress == nil && seen.insert($0.ratingKey).inserted }
        do {
            let loadedHubs = try await h
            try Task.checkCancellation()
            hubs = mediaMode.filter(loadedHubs)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        // After the rest, so Home doesn't wait on the searches.
        let comingHoliday = mediaMode == .watch ? Holiday.current() : nil
        let picks = comingHoliday == nil ? [] : await api.holidayPicks(comingHoliday!)
        guard !Task.isCancelled else { return }
        holiday = comingHoliday
        holidayItems = picks
    }
}

/// Full-bleed swipeable artwork at the top of Home.
struct HeroCarousel: View {
    @Environment(AppState.self) private var app
    let items: [PlexMetadata]
    @State private var page = 0

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HeroPage(item: item).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 500)
            HStack(spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    Capsule().fill(i == page ? Color.white : Color.white.opacity(0.3))
                        .frame(width: i == page ? 16 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: page)
            .accessibilityHidden(true)
        }
        .onChange(of: items.map(\.id)) { _, _ in page = 0 }
        // Moves on every 8 seconds; swiping restarts the wait.
        .task(id: page) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % items.count }
        }
    }
}

private struct HeroPage: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata

    private var heading: String { item.kind == .episode ? (item.grandparentTitle ?? item.title) : (item.kind == .season ? (item.parentTitle ?? item.title) : item.title) }

    private var meta: String {
        var parts: [String] = []
        if item.kind == .episode, let s = item.parentIndex, let e = item.index { parts.append("S\(s) E\(e) · \(item.title)") }
        else if let y = item.year { parts.append(String(y)) }
        if let g = item.genres.first?.tag { parts.append(g) }
        if let left = Fmt.remaining(ms: item.duration, offset: item.viewOffset) { parts.append(left) }
        else if let d = Fmt.duration(ms: item.duration), item.kind != .show { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PlexImage(path: item.backdrop, width: 1280, height: 1000, placeholderIcon: "film")
                .frame(height: 500)
                .frame(maxWidth: .infinity)
                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Cinema.background, location: 0.97)],
                                        startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 8) {
                QualityChips(item: item, includeRating: false)
                Text(heading)
                    .font(Cinema.title(46)).textCase(.uppercase)
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                if !meta.isEmpty {
                    Text(meta).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if item.isPlayableVideo {
                        Button { app.play(item) } label: {
                            Label(item.progress != nil ? "Resume" : "Play", systemImage: "play.fill")
                        }
                        .buttonStyle(CinemaPlayButtonStyle())
                    } else {
                        NavigationLink(value: item.route) { Label("View", systemImage: "play.rectangle.fill") }
                            .buttonStyle(CinemaPlayButtonStyle())
                    }
                    NavigationLink(value: item.route) { Image(systemName: "info").glassCircle() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details")
                    if item.isLeaf || item.kind == .show || item.kind == .season {
                        DownloadButton(item: item, compact: true).glassCircle()
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 560, alignment: .leading)   // iPad: buttons stay a sensible width
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Libraries

struct LibrariesView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @State private var sections: [PlexDirectory] = []
    @State private var previews: [String: LibraryPreview] = [:]
    @State private var loaded = false
    @State private var error: String?

    struct LibraryPreview { var count: Int?; var art: String? }

    /// Grows with text size, so the cards drop to one column before their names truncate.
    @ScaledMetric(relativeTo: .title3) private var cardMinWidth = 160.0
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: min(cardMinWidth, 340)), spacing: 12)] }

    var body: some View {
        // Listen with one music library: show it right here instead of a single card to tap.
        if mediaMode == .music, loaded, sections.count == 1, let music = sections.first {
            LibrarySectionView(section: music, title: "Library", header: AnyView(MusicLibraryChips()))
        } else {
            cardsPage
        }
    }

    private var cardsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ServerLabel().padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 12) {
                    if sections.isEmpty && !loaded && error == nil && ConnectionNotice.problem(app) == nil {
                        ForEach(0..<4, id: \.self) { _ in LibraryCardPlaceholder() }
                    }
                    ForEach(sections) { section in
                        NavigationLink(value: Route.section(section)) {
                            LibraryCard(section: section, preview: previews[section.key])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                if sections.isEmpty, ConnectionNotice.problem(app) != nil {
                    ConnectionNotice()
                } else if let error, sections.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Load Libraries", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }

                if loaded && sections.isEmpty && error == nil && ConnectionNotice.problem(app) == nil {
                    EmptyStateView(title: "No \(mediaMode.title) Libraries", systemImage: mediaMode.icon,
                                   message: "Choose a server with \(mediaMode == .music ? "music" : "movies or shows") in Settings.")
                }
                if mediaMode == .music && !sections.isEmpty { MixesHomeSection() }
                if !sections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("More").font(.title3.bold()).padding(.horizontal)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            NavigationLink(value: Route.favorites) {
                                ShortcutTile(title: "Favorites", systemImage: "heart.fill", color: Cinema.accent)
                            }
                            if mediaMode == .watch {
                                NavigationLink(value: Route.watchLater) {
                                    ShortcutTile(title: "Watch Later", systemImage: "clock.badge.checkmark", color: Cinema.accent)
                                }
                                if app.isSignedIn {
                                    NavigationLink(value: Route.watchlist) {
                                        ShortcutTile(title: "Watchlist", systemImage: "bookmark.fill", color: Cinema.accent)
                                    }
                                }
                            }
                            NavigationLink(value: Route.playlists) {
                                ShortcutTile(title: "Playlists", systemImage: "music.note.list", color: Cinema.accent)
                            }
                            NavigationLink(value: Route.history) {
                                ShortcutTile(title: "History", systemImage: "clock.arrow.circlepath", color: Cinema.accent)
                            }
                            Button { app.selectedTab = .downloads } label: {
                                ShortcutTile(title: "Downloads", systemImage: "arrow.down.circle.fill", color: Cinema.accent)
                            }
                            NavigationLink(value: Route.storageCleanup) {
                                ShortcutTile(title: "Free Up Space", systemImage: "trash.circle", color: Cinema.accent)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .titleWithDownloadStatus("Library")
        .refreshable { await load() }
        .task(id: app.api?.baseURL) { await load() }
    }

    private func load() async {
        guard let api = app.browseAPI else { return }
        do {
            sections = try await api.sections().filter { mediaMode.includes(section: $0) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
        // Count + newest item's artwork for every library, in parallel.
        await withTaskGroup(of: (String, LibraryPreview).self) { group in
            for section in sections {
                group.addTask {
                    let page = try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 1,
                                                   query: [URLQueryItem(name: "sort", value: "addedAt:desc")])
                    let newest = page?.metadata.first
                    return (section.key, LibraryPreview(count: page?.totalSize,
                                                        art: newest?.art ?? newest?.thumb ?? section.art))
                }
            }
            for await (key, preview) in group { previews[key] = preview }
        }
    }
}

private extension PlexDirectory {
    var accent: Color {
        Cinema.accent
    }

    func countLabel(_ n: Int) -> String {
        let noun: String
        switch type {
        case "movie": noun = n == 1 ? "movie" : "movies"
        case "show": noun = n == 1 ? "show" : "shows"
        case "artist": noun = n == 1 ? "artist" : "artists"
        default: noun = n == 1 ? "item" : "items"
        }
        return "\(n.formatted()) \(noun)"
    }
}

struct LibraryCard: View {
    let section: PlexDirectory
    let preview: LibrariesView.LibraryPreview?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop from the library's newest item, darkening toward the title.
            PlexImage(path: preview?.art, width: 640, height: 400, placeholderIcon: section.systemImage,
                      background: Cinema.placeholder)
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom)
                )

            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: section.systemImage)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(section.accent.gradient, in: RoundedRectangle(cornerRadius: 9))
                Spacer(minLength: 0)
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(preview?.count.map(section.countLabel) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .redacted(reason: preview == nil ? .placeholder : [])
            }
            .padding(12)
        }
        .aspectRatio(16 / 11, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryCardPlaceholder: View {
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(pulse ? Cinema.placeholder : Cinema.surface)
            .aspectRatio(16 / 11, contentMode: .fit)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

private struct ShortcutTile: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.black)
                .frame(width: 44, height: 44)
                .background(color.gradient, in: Circle())
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Cinema.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Library section grid

struct LibrarySectionView: View {
    @Environment(\.mediaMode) private var mediaMode
    @ScaledMetric(relativeTo: .body) private var posterWidth = Cinema.gridPosterWidth
    @Environment(AppState.self) private var app
    let section: PlexDirectory
    @Environment(AudioPlayer.self) private var audio

    enum Mode: String, CaseIterable, Identifiable {
        case all = "All", recommended = "Recommended", collections = "Collections", albums = "Albums", songs = "Songs", folders = "Folders"
        var id: String { rawValue }
    }

    /// Shown as the page title instead of the library's name (the Listen Library tab).
    var title: String?
    /// Content above the Artists/Albums/Songs picker.
    var header: AnyView?

    init(section: PlexDirectory, initialMode: Mode = .all, title: String? = nil, header: AnyView? = nil) {
        self.section = section
        self.title = title
        self.header = header
        _mode = State(initialValue: initialMode)
    }

    struct Sort: Hashable { let key: String; let label: String }
    static let sorts = [
        Sort(key: "titleSort", label: "Title"),
        Sort(key: "addedAt:desc", label: "Date Added"),
        Sort(key: "originallyAvailableAt:desc", label: "Release Date"),
        Sort(key: "lastViewedAt:desc", label: "Last Watched"),
        Sort(key: "rating:desc", label: "Rating"),
    ]

    @State private var mode: Mode = .all
    @State private var items: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []
    @State private var total: Int?
    @State private var nextOffset = 0
    @State private var paging = PageRequestState()
    private var loadingPage: Bool { paging.isLoading }
    /// The list the page holds; when only the content changed (back from playing), it's
    /// refreshed in place so the scroll position stays.
    @State private var loadedKey = ""
    private var listKey: String {
        "\(mode)-\(sort.key)-\(unwatchedOnly)-\(genre?.key ?? "")-\(decade?.key ?? "")-\(only4K)"
    }
    @State private var sort = LibrarySectionView.sorts[0]
    @State private var unwatchedOnly = false
    /// Filters, as on Apple TV: genre, decade and 4K (the All list only).
    @State private var genre: PlexDirectory?
    @State private var decade: PlexDirectory?
    @State private var only4K = false
    @State private var genres: [PlexDirectory] = []
    @State private var decades: [PlexDirectory] = []
    private var isFiltered: Bool { unwatchedOnly || genre != nil || decade != nil || only4K }
    /// # A B C … for jumping through a list in title order.
    struct Letter: Hashable { let title: String; let size: Int }
    @State private var letters: [Letter] = []
    private var showsLetters: Bool { mode == .all && sort.key == "titleSort" && section.type != "photo" && letters.count > 1 }
    @State private var error: String?

    @State private var selection = BulkSelection()
    private var selectable: Bool { mode != .recommended && section.type != "photo" }
    private var selectedItems: [PlexMetadata] {
        let byID = Dictionary(items.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
        return selection.ids.compactMap { byID[$0] }
    }

    @State private var songQuery = ""
    @FocusState private var songQueryFocused: Bool
    /// Read once per render (a big library has tens of thousands of songs to filter).
    private var visibleSongs: [PlexMetadata] {
        songQuery.isEmpty ? items : items.filter { LibrarySongFilter.matches($0, query: songQuery) }
    }
    /// Shuffling a whole library queues a random selection: a 50,000-song queue would be saved
    /// to disk on every change and slow the player down.
    static let shuffleLimit = 1000
    private let pageSize = 60
    /// The most items refreshed in place when coming back to the list.
    static let refreshWindow = 300
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: posterWidth), spacing: 12)] }

    private var modes: [Mode] {
        switch section.type {
        case "artist": return [.all, .albums, .songs, .recommended]
        case "photo": return [.all]
        default: return [.all, .recommended, .collections]
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let header { header.padding(.bottom, 12) }
            if modes.count > 1 {
                PillPicker(options: modes, selection: $mode) {
                    section.type == "artist" && $0 == .all ? "Artists" : $0 == .recommended ? "For You" : $0.rawValue
                }
            }
            if mode == .recommended {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(hubs) { hub in
                        if !hub.metadata.isEmpty {
                            HubRow(title: hub.title, items: hub.metadata,
                                   moreRoute: (hub.more ?? false) ? hub.key.map { Route.hub(key: $0, title: hub.title) } : nil)
                        }
                    }
                }
                .padding(.vertical)
            } else {
                if mode == .songs {
                    HStack {
                        TextField("Search title, artist or album", text: $songQuery)
                            .textFieldStyle(.roundedBorder)
                            .focused($songQueryFocused)
                            .submitLabel(.done)
                            .onSubmit { songQueryFocused = false }
                            .autocorrectionDisabled()
                        Button { audio.play(Array(items.shuffled().prefix(Self.shuffleLimit)), serverID: app.selectedServerID ?? "", shuffle: true) } label: { Image(systemName: "shuffle") }.disabled(items.isEmpty || loadingPage).accessibilityLabel("Shuffle all songs")
                    }.padding()
                    if loadingPage, let total, total > items.count {
                        Label(songQuery.isEmpty ? "Loading songs… \(items.count.formatted()) of \(total.formatted())"
                                                : "Searching the \(items.count.formatted()) of \(total.formatted()) songs loaded so far",
                              systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    let songs = visibleSongs
                    if !songQuery.isEmpty && songs.isEmpty && !loadingPage { Text("No matching songs").foregroundStyle(.secondary) }
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { item in
                            SelectableRow(id: item.ratingKey, selection: $selection) {
                                TrackRow(item: item, number: nil) {
                                    if let ak = item.parentRatingKey {
                                        ManualPlays.record(albumKey: ak, title: item.parentTitle ?? item.title, art: item.parentThumb ?? item.thumb, song: item.title, serverID: app.selectedServerID ?? "")
                                    }
                                    audio.play(songs, serverID: app.selectedServerID ?? "", startAt: songs.firstIndex(of: item) ?? 0)
                                }
                            }
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                            Divider()
                        }
                    }.padding(.horizontal)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            Group {
                                if selection.isActive {
                                    let on = selection.contains(item.ratingKey)
                                    Button { selection.toggle(item.ratingKey) } label: {
                                        PosterCard(item: item, width: posterWidth)
                                            .overlay(alignment: .topLeading) {
                                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundStyle(on ? Cinema.accent : .white)
                                                    .background(Circle().fill(.black.opacity(0.4)))
                                                    .padding(6)
                                            }
                                            .opacity(on ? 1 : 0.75)
                                    }
                                    .accessibilityAddTraits(on ? .isSelected : [])
                                } else {
                                    NavigationLink(value: item.route) { PosterCard(item: item, width: posterWidth) }
                                        .contextMenu { ItemContextMenu(item: item) }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                            .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                    .padding()
                    .padding(.trailing, showsLetters ? 18 : 0)
                }
                if loadingPage { ProgressView().padding() }
                if let error {
                    Text(error).foregroundStyle(.secondary).padding()
                    Button("Retry") { Task { await reload() } }.padding(.bottom)
                }
                if !loadingPage, items.isEmpty, error == nil, total == 0 {
                    EmptyStateView(title: isFiltered ? "Nothing Matches" : "Nothing Here", systemImage: "tray")
                }
            }
        }
        .overlay(alignment: .trailing) { if showsLetters { letterStrip(proxy) } }
        }
        // Scrolling puts the keyboard away so the tab bar is reachable again.
        .scrollDismissesKeyboard(.immediately)
        .titleWithDownloadStatus(title ?? section.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isActive { BulkActionBar(items: selectedItems) { selection.end() } }
        }
        .onChange(of: mode) { selection.end(); songQueryFocused = false }
        .toolbar {
            if selectable {
                BulkSelectButton(selection: $selection, allIDs: (mode == .songs ? visibleSongs : items).map(\.ratingKey))
            }
            if mode == .all || mode == .albums || mode == .songs {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(Self.sorts, id: \.self) { sort in
                                Text(section.type == "artist" && sort.key.hasPrefix("lastViewedAt") ? "Last Played" : sort.label).tag(sort)
                            }
                        }
                        if section.type == "movie" || section.type == "show" {
                            Toggle("Unwatched Only", isOn: $unwatchedOnly)
                        }
                        if mode == .all {
                            if !genres.isEmpty { filterPicker("Genre", systemImage: "theatermasks", options: genres, selection: $genre) }
                            if !decades.isEmpty { filterPicker("Decade", systemImage: "calendar", options: decades, selection: $decade) }
                            if section.type == "movie" { Toggle(isOn: $only4K) { Label("4K Only", systemImage: "4k.tv") } }
                        }
                        if isFiltered {
                            Button { unwatchedOnly = false; genre = nil; decade = nil; only4K = false } label: {
                                Label("Clear Filters", systemImage: "xmark")
                            }
                        }
                    } label: { Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Sort and Filter")
                }
            }
        }
        .refreshable { await reload() }
        .task(id: "\(listKey)-\(app.contentVersion)") {
            if listKey == loadedKey, !items.isEmpty || mode == .recommended { await refreshInPlace() } else { loadedKey = listKey; await reload() }
        }
        .task(id: "\(section.key)-\(app.isOnline)") { await loadFilters() }
    }

    private func filterPicker(_ title: String, systemImage: String, options: [PlexDirectory], selection: Binding<PlexDirectory?>) -> some View {
        Picker(selection: selection) {
            Text("Any").tag(PlexDirectory?.none)
            ForEach(options, id: \.key) { Text($0.title).tag(Optional($0)) }
        } label: { Label(selection.wrappedValue.map { "\(title): \($0.title)" } ?? title, systemImage: systemImage) }
        .pickerStyle(.menu)
    }

    /// Down the right edge: pick a letter to jump there (loading pages up to it).
    private func letterStrip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 1) {
                ForEach(letters, id: \.self) { letter in
                    Button { Task { await jump(to: letter, proxy: proxy) } } label: {
                        Text(letter.title).font(.caption2.weight(.semibold)).frame(width: 22, height: 17).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Cinema.accent)
                    .accessibilityLabel("Jump to \(letter.title)")
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 24)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 2)
    }

    /// Genres and decades for the filter menu.
    private func loadFilters() async {
        guard let api = app.browseAPI, section.type != "photo" else { genres = []; decades = []; return }
        async let g = try? api.container("/library/sections/\(section.key)/genre")
        async let d = try? api.container("/library/sections/\(section.key)/decade")
        let (loadedGenres, loadedDecades) = await (g?.directories ?? [], d?.directories ?? [])
        guard !Task.isCancelled else { return }
        genres = loadedGenres
        decades = section.type == "artist" ? [] : loadedDecades
    }

    private var filterQuery: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if unwatchedOnly { q.append(URLQueryItem(name: "unwatched", value: "1")) }
        guard mode == .all else { return q }
        if let genre { q.append(URLQueryItem(name: "genre", value: genre.key)) }
        if let decade { q.append(URLQueryItem(name: "decade", value: decade.key)) }
        if only4K { q.append(URLQueryItem(name: "resolution", value: "4k")) }
        return q
    }

    private func loadLetters() async {
        letters = []
        guard showsLettersCandidate, let api = app.browseAPI,
              let (body, _) = try? await api.data("/library/sections/\(section.key)/firstCharacter", query: filterQuery),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let dirs = container["Directory"] as? [[String: Any]], !Task.isCancelled else { return }
        letters = dirs.compactMap { d in
            guard let title = d["title"] as? String else { return nil }
            let size = (d["size"] as? Int) ?? Int(d["size"] as? String ?? "") ?? 0
            return size > 0 ? Letter(title: title, size: size) : nil
        }
    }
    private var showsLettersCandidate: Bool { mode == .all && sort.key == "titleSort" && section.type != "photo" }

    /// Loads pages up to the letter's first title, then scrolls there.
    private func jump(to letter: Letter, proxy: ScrollViewProxy) async {
        let offset = letters.prefix { $0 != letter }.reduce(0) { $0 + $1.size }
        while nextOffset <= offset, total.map({ nextOffset < $0 }) ?? true {
            let before = nextOffset
            await loadMore()
            if nextOffset == before { break }
        }
        // The list can hold slightly fewer items than the server listed (duplicates are dropped).
        guard !items.isEmpty else { return }
        let id = items[min(offset, items.count - 1)].id
        withAnimation { proxy.scrollTo(id, anchor: .top) }
    }

    /// Fresher watched marks and progress for what's already listed, in one request. The full
    /// song list (no watch state) isn't reloaded at all.
    private func refreshInPlace() async {
        switch mode {
        case .songs: return
        case .recommended:
            let result = (try? await app.browseAPI?.sectionHubs(section.key)) ?? []
            if !result.isEmpty, !Task.isCancelled { hubs = mediaMode.filter(result) }
        default:
            guard let api = app.browseAPI, let generation = paging.begin() else { return }
            defer { paging.finish(generation) }
            let (path, query) = listRequest()
            // Deep in a long list, only the top is refetched (what just played is usually there);
            // items further down keep their marks until the list is reloaded.
            let count = min(max(nextOffset, pageSize), Self.refreshWindow)
            guard let page = try? await api.page(path, start: 0, size: count, query: query),
                  generation == paging.generation, !Task.isCancelled else { return }
            var seen = Set<String>()
            let fresh = page.metadata.filter { mediaMode.includes($0) && seen.insert($0.id).inserted }
            if nextOffset <= count {
                items = fresh
                nextOffset = page.metadata.count
                total = page.totalSize ?? (page.metadata.count < count ? nextOffset : nil)
            } else {
                let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                items = items.map { byID[$0.id] ?? $0 }
            }
        }
    }

    /// Where the list comes from for the current mode, sort and filter.
    private func listRequest() -> (path: String, query: [URLQueryItem]) {
        var path = "/library/sections/\(section.key)/all"
        var query = [URLQueryItem(name: "sort", value: sort.key), URLQueryItem(name: "includeCollections", value: "1")]
        switch mode {
        case .collections:
            path = "/library/sections/\(section.key)/collections"
            query = []
        case .albums:
            query.append(URLQueryItem(name: "type", value: "9"))
        case .songs:
            query.append(URLQueryItem(name: "type", value: "10"))
        case .folders:
            path = "/library/sections/\(section.key)/folder"
        default: break
        }
        if mode != .collections && mode != .folders { query += filterQuery }
        return (path, query)
    }

    private func reload() async {
        paging.reset()
        let generation = paging.generation
        items = []
        total = nil
        nextOffset = 0
        error = nil
        if mode == .songs {
            guard let api = app.browseAPI, let ticket = paging.begin() else { return }
            defer { paging.finish(ticket) }
            // Songs appear page by page as they load (search and Shuffle use what's loaded so far,
            // and the list says when more are still coming).
            let size = 300
            do {
                while true {
                    let page = try await api.page("/library/sections/\(section.key)/all", start: nextOffset, size: size, query: [
                        URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: sort.key),
                    ])
                    guard generation == paging.generation, !Task.isCancelled else { return }
                    nextOffset += page.metadata.count
                    items += page.metadata.filter { $0.kind == .track }
                    if total == nil { total = page.totalSize }
                    if page.metadata.count < size || (total.map { nextOffset >= $0 } ?? false) { break }
                }
                total = nextOffset
            } catch { if generation == paging.generation && !Task.isCancelled { self.error = error.localizedDescription } }
        } else if mode == .recommended {
            let result = (try? await app.browseAPI?.sectionHubs(section.key)) ?? []
            guard generation == paging.generation, !Task.isCancelled else { return }
            hubs = mediaMode.filter(result)
        } else {
            await loadMore()
            if showsLettersCandidate { await loadLetters() } else { letters = [] }
        }
    }

    private func loadMore() async {
        guard let api = app.browseAPI, !loadingPage else { return }
        if let total, nextOffset >= total { return }
        guard let generation = paging.begin() else { return }
        defer { paging.finish(generation) }
        let (path, query) = listRequest()
        do {
            let page = try await api.page(path, start: nextOffset, size: pageSize, query: query)
            guard generation == paging.generation, !Task.isCancelled else { return }
            error = nil
            nextOffset += page.metadata.count
            var existing = Set(items.map(\.id))
            items += page.metadata.filter { mediaMode.includes($0) && existing.insert($0.id).inserted }
            total = page.metadata.isEmpty ? nextOffset : page.totalSize ?? (page.metadata.count < pageSize ? nextOffset : nil)
        } catch {
            guard generation == paging.generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Hub "see all"

struct HubGridView: View {
    @Environment(\.mediaMode) private var mediaMode
    @ScaledMetric(relativeTo: .body) private var posterWidth = Cinema.gridPosterWidth
    @Environment(AppState.self) private var app
    let key: String
    let title: String
    @State private var items: [PlexMetadata] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item.route) { PosterCard(item: item, width: posterWidth) }
                        .buttonStyle(.plain)
                        .contextMenu { ItemContextMenu(item: item) }
                }
            }
            .padding()
            if loading { ProgressView() }
        }
        .titleWithDownloadStatus(title)
        .task {
            items = ((try? await app.api?.page(key, start: 0, size: 200).metadata) ?? []).filter { mediaMode.includes($0) }
            loading = false
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @State private var playlists: [PlexMetadata] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false

    private var groups: [(type: String, title: String)] { [(mediaMode.playlistType, mediaMode == .music ? "Music" : "Video")] }

    var body: some View {
        List {
            ForEach(groups, id: \.type) { group in
                let items = playlists.filter { ($0.playlistType ?? "video") == group.type }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { p in
                            NavigationLink(value: p.route) { PlaylistRow(playlist: p) }
                        }
                    }
                }
            }
        }
        .overlay {
            if loading && playlists.isEmpty {
                ProgressView()
            } else if let error, playlists.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Playlists", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if playlists.isEmpty {
                EmptyStateView(title: "No Playlists", systemImage: "music.note.list",
                               message: "Tap + to name a playlist and choose \(mediaMode == .music ? "songs" : "videos").")
            }
        }
        .titleWithDownloadStatus("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create playlist")
            }
        }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { CreatePlaylistView() }
        .refreshable { await load() }
        .task(id: app.contentVersion) { await load() }
    }

    private func load() async {
        guard let api = app.browseAPI else { loading = false; error = "Not connected to a server."; return }
        loading = true
        defer { loading = false }
        do {
            playlists = try await api.playlists().filter { mediaMode.includes($0) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaylistRow: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let playlist: PlexMetadata
    var body: some View {
        HStack(spacing: 12) {
            PlexImage(path: playlist.thumb ?? playlist.composite, width: 160, height: 160,
                      placeholderIcon: playlist.playlistType == "audio" ? "music.note.list" : "list.and.film")
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(playlist.title).lineLimit(1)
                    if playlist.smart == true {
                        Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text([playlist.leafCount.map { "\($0) item\($0 == 1 ? "" : "s")" }, Fmt.duration(ms: playlist.duration)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let c = downloads.collection(serverID: app.selectedServerID ?? "", ratingKey: playlist.ratingKey) {
                let summary = GroupDownloadSummary(records: downloads.records(in: c),
                                                   expected: max(c.itemIDs.count, playlist.leafCount ?? 0))
                GroupDownloadIcon(summary: summary, size: 20)
                    .accessibilityLabel(summary.statusText)
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    let ratingKey: String
    let title: String
    @State private var items: [PlexMetadata] = []
    @State private var removingEntry = false
    @State private var editing = false
    @State private var editedTitle: String?
    @State private var isSmart = false
    @State private var loading = true
    @State private var error: String?
    @State private var photoIndex: ItemDetailView.PhotoSelection?
    @State private var selection = BulkSelection()
    /// Entries removed but not yet deleted on the server (Undo is still possible).
    @State private var pendingRemoval: [PlexMetadata] = []
    @State private var removalTask: Task<Void, Never>?
    /// The playlist itself (cover, duration), for the header.
    @State private var meta: PlexMetadata?
    @State private var backdrop: Color = Cinema.surface
    /// The big title is on screen; the bar shows the name once it scrolls away.
    @State private var headerTitleVisible = true
    @State private var shuffleOn = false

    /// Everything shown: the playlist minus entries awaiting removal.
    private var shown: [PlexMetadata] {
        let hidden = Set(pendingRemoval.compactMap(\.playlistItemID))
        return items.filter { $0.playlistItemID.map { !hidden.contains($0) } ?? true }
    }
    private var tracks: [PlexMetadata] { shown.filter { $0.kind == .track } }
    private var videos: [PlexMetadata] { shown.filter(\.isPlayableVideo) }
    private var photos: [PlexMetadata] { shown.filter { $0.kind == .photo } }
    /// Duplicate songs are separate playlist entries, so rows are keyed by entry ID.
    private func rowID(_ item: PlexMetadata, _ idx: Int) -> String { item.playlistItemID ?? "\(idx)-\(item.ratingKey)" }
    private var selectedItems: [PlexMetadata] {
        let rows = Dictionary(shown.enumerated().map { (rowID($1, $0), $1) }, uniquingKeysWith: { a, _ in a })
        return selection.ids.compactMap { rows[$0] }
    }

    var body: some View {
        List {
            if !selection.isActive { header }
            ForEach(Array(shown.enumerated()), id: \.offset) { idx, item in
                SelectableRow(id: rowID(item, idx), selection: $selection) {
                switch item.kind {
                case .track:
                    TrackRow(item: item, number: nil, removeFromPlaylist: canRemove(item) ? { remove([item]) } : nil, removalInProgress: loading || !app.isOnline,
                             playlistStyle: true) {
                        audio.play(tracks, serverID: app.selectedServerID ?? "", startAt: shown.prefix(idx).filter { $0.kind == .track }.count)
                        PlaylistPlays.record(ratingKey, serverID: app.selectedServerID ?? "")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 6))
                case .photo:
                    Button { photoIndex = .init(id: photos.firstIndex(of: item) ?? 0) } label: {
                        HStack(spacing: 12) {
                            PlexImage(path: item.thumb, width: 200, height: 200, placeholderIcon: "photo")
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(item.title).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { removalAction(item) }
                default:
                    NavigationLink(value: Route.item(ratingKey: item.ratingKey, title: item.title)) {
                        EpisodeRowContent(item: item)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12))
                    .contextMenu {
                        if item.isPlayableVideo {
                            Button { app.play(item, queue: Array(shown.dropFirst(idx + 1).filter(\.isPlayableVideo))) } label: {
                                Label("Play from Here", systemImage: "play.fill")
                            }
                        }
                        ItemContextMenu(item: item)
                        removalAction(item)
                    }
                }
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            // Color from the cover, fading into the page.
            VStack(spacing: 0) {
                LinearGradient(colors: [backdrop, Cinema.background], startPoint: .top, endPoint: .bottom).frame(height: 520)
                Cinema.background
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: backdrop)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isActive {
                BulkActionBar(items: selectedItems, removeLabel: "Remove",
                              remove: isSmart || !app.isOnline ? nil : { remove($0.filter(canRemove)) }) { selection.end() }
            } else if !pendingRemoval.isEmpty {
                UndoToast(message: pendingRemoval.count == 1 ? "Removed \(pendingRemoval[0].title)" : "Removed \(pendingRemoval.count) items") {
                    undoRemoval()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: pendingRemoval.count)
        .onDisappear { commitRemoval() }
        .overlay {
            if loading && items.isEmpty {
                ProgressView()
            } else if let error, items.isEmpty {
                ContentUnavailableView("Couldn't Load Playlist", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if shown.isEmpty {
                EmptyStateView(title: "Empty Playlist", systemImage: "music.note.list", message: "Use Add to Playlist from a song’s menu or a video’s detail page.")
            }
        }
        .navigationTitle(headerTitleVisible && !selection.isActive ? "" : name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { DownloadStatusPill() }
        .toolbar {
            if selection.isActive {
                BulkSelectButton(selection: $selection, allIDs: shown.enumerated().map { rowID($1, $0) })
            }
        }
        .confirmationDialog("Remove the downloaded copy of \(name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { if let c = collection { downloads.removeCollection(c.id) } }
        } message: {
            Text("Songs and videos that are also in another downloaded playlist are kept.")
        }
        .refreshable { await load() }
        .task(id: app.contentVersion) { await load() }
        .sheet(isPresented: $editing) { PlaylistEditorView(id: ratingKey, title: editedTitle ?? title, items: items) { app.libraryChanged() } }
        .sheet(item: $photoIndex) { sel in PhotoViewer(photos: photos, start: sel.id) }
    }

    private var name: String { editedTitle ?? title }
    private var playable: Bool { !tracks.isEmpty || !videos.isEmpty }

    // MARK: Header (cover, title, owner, details, actions)

    @ViewBuilder private var header: some View {
        PlexImage(path: meta?.composite ?? meta?.thumb ?? items.first?.posterThumb, width: 600, height: 600,
                  placeholderIcon: "music.note.list")
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 250)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .headerRow()
        VStack(alignment: .leading, spacing: 10) {
            Text(name)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(2)
                .onAppear { headerTitleVisible = true }
                .onDisappear { headerTitleVisible = false }
            if let owner = app.profileName {
                HStack(spacing: 8) {
                    PlexImage(path: app.profileThumb, width: 60, height: 60, placeholderIcon: "person.fill")
                        .frame(width: 24, height: 24).clipShape(Circle())
                    Text(owner).font(.subheadline.weight(.semibold))
                }
            }
            if let details { Text(details).font(.subheadline).foregroundStyle(.secondary) }
            actionRow
        }
        .headerRow()
    }

    /// "23 songs · 1h 11m" (smart playlists say so).
    private var details: String? {
        let count = tracks.isEmpty ? videos.count : tracks.count
        guard count > 0 || isSmart else { return nil }
        var parts: [String] = []
        if isSmart { parts.append("Smart playlist") }
        if count > 0 { parts.append("\(count) \(tracks.isEmpty ? "video" : "song")\(count == 1 ? "" : "s")") }
        let ms = meta?.duration ?? shown.reduce(0) { $0 + ($1.duration ?? 0) }
        if ms > 0 {
            let minutes = ms / 60_000
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }

    private var isPlayingHere: Bool {
        guard audio.isPlaying, let current = audio.current?.track.ratingKey else { return false }
        return tracks.contains { $0.ratingKey == current }
    }

    private var actionRow: some View {
        MusicActionRow(shuffleOn: $shuffleOn, isPlaying: isPlayingHere, playOrPause: playOrPause, canPlay: playable) {
            if playable && summary == nil && !ProStore.shared.isUnlocked {
                Button { ProStore.presentPaywall(.downloads, after: .zero) } label: {
                    Image(systemName: "arrow.down.circle").font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Download")
            } else if playable {
                Menu { downloadMenuContent } label: {
                    Group {
                        if let summary { GroupDownloadIcon(summary: summary, size: 26) }
                        else { Image(systemName: "arrow.down.circle").font(.system(size: 26)) }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(summary?.statusText ?? "Download")
            }
            Menu {
                if !shown.isEmpty {
                    Button { selection.isActive = true } label: { Label("Select", systemImage: "checkmark.circle") }
                }
                Button { commitRemoval(); editing = true } label: { Label("Edit Playlist", systemImage: "pencil") }
                    .disabled(loading || removingEntry || !app.isOnline || isSmart)
            } label: { MusicRowIcon(systemName: "ellipsis") }
            .accessibilityLabel("Playlist actions")
        }
        .padding(.top, 2)
    }

    private func playOrPause() {
        if isPlayingHere { audio.pause(); return }
        if let current = audio.current?.track.ratingKey, !audio.isPlaying, !shuffleOn, tracks.contains(where: { $0.ratingKey == current }) {
            audio.resume(); return
        }
        play(shuffle: shuffleOn)
    }

    private func loadBackdrop() async {
        guard let url = app.imageURL(meta?.composite ?? meta?.thumb ?? items.first?.posterThumb, width: 120, height: 120),
              let color = await ImageLoader.shared.averageColor(for: url) else { return }
        backdrop = Cinema.musicTint(from: color)
    }

    private func canRemove(_ item: PlexMetadata) -> Bool {
        !isSmart && item.playlistItemID != nil
    }

    @ViewBuilder private func removalAction(_ item: PlexMetadata) -> some View {
        if canRemove(item) {
            Button(role: .destructive) { remove([item]) } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }.disabled(removingEntry || loading || !app.isOnline)
        }
    }

    /// Hides the entries now; they're deleted on the server after a few seconds
    /// unless Undo is tapped. A new removal commits the previous one first.
    private func remove(_ entries: [PlexMetadata]) {
        let entries = entries.filter(canRemove)
        guard !entries.isEmpty, app.isOnline else { return }
        commitRemoval()
        pendingRemoval = entries
        removalTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            commitRemoval()
        }
    }

    private func undoRemoval() {
        removalTask?.cancel()
        removalTask = nil
        pendingRemoval = []
    }

    private func commitRemoval() {
        removalTask?.cancel()
        removalTask = nil
        let entries = pendingRemoval
        guard !entries.isEmpty, let api = app.api else { pendingRemoval = []; return }
        pendingRemoval = []
        let ids = entries.compactMap(\.playlistItemID)
        items.removeAll { $0.playlistItemID.map(ids.contains) ?? false }
        removingEntry = true
        Task {
            var failed: [PlexMetadata] = []
            for entry in entries {
                guard let id = entry.playlistItemID else { continue }
                do { try await api.removePlaylistEntry(ratingKey, entryID: id) } catch { failed.append(entry) }
            }
            removingEntry = false
            app.libraryChanged()
            if !failed.isEmpty {
                app.actionError = "Couldn't remove \(failed.count == 1 ? failed[0].title : "\(failed.count) items") from the playlist. Pull to refresh to see its current contents."
            }
        }
    }

    @Environment(DownloadManager.self) private var downloads

    private var downloadable: [PlexMetadata] { items.filter { $0.isPlayableVideo || $0.kind == .track } }

    @State private var confirmRemove = false

    private var collection: DownloadCollection? {
        downloads.collection(serverID: app.selectedServerID ?? "", ratingKey: ratingKey)
    }

    /// Status of *this playlist's* download, not of whichever songs happen to be
    /// downloaded from elsewhere.
    private var summary: GroupDownloadSummary? {
        guard let collection else { return nil }
        let present = downloads.records(in: collection)
        // Items added to the playlist on the server since it was downloaded count as missing.
        let expected = items.isEmpty ? collection.itemIDs.count
            : Set(downloadable.map(\.ratingKey)).union(present.map(\.metadata.ratingKey)).count
        return GroupDownloadSummary(records: present, expected: expected)
    }

    private func startDownload(_ q: DownloadQuality) {
        downloads.downloadPlaylist(ratingKey: ratingKey, title: editedTitle ?? title,
                                   thumb: items.first?.posterThumb, items: downloadable,
                                   serverID: app.selectedServerID ?? "", quality: q)
    }

    @ViewBuilder private var downloadMenuContent: some View {
        if let summary {
            Section(summary.statusText) {
                if summary.missing > 0 {
                    Button { startDownload(downloads.defaultQuality) } label: {
                        Label("Download \(summary.missing) New Item\(summary.missing == 1 ? "" : "s")", systemImage: "arrow.down.circle")
                    }
                }
                if summary.failed > 0 {
                    Button { summary.records.filter { $0.state == .failed }.forEach { downloads.retry($0.id) } } label: {
                        Label("Retry Failed", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label(summary.active > 0 ? "Cancel & Remove Download" : "Remove Download", systemImage: "trash")
                }
            }
            if let collection {
                Section("Keep Updated") { PlaylistUpdateToggles(collection: collection) }
            }
        } else {
            Section("Download \(downloadable.count) item\(downloadable.count == 1 ? "" : "s")") {
                ForEach(videos.isEmpty ? [DownloadQuality.original] : DownloadQuality.allCases) { q in
                    Button(q.label + (q == downloads.defaultQuality ? " (Default)" : "")) { startDownload(q) }
                }
            }
        }
    }

    private func play(shuffle: Bool) {
        PlaylistPlays.record(ratingKey, serverID: app.selectedServerID ?? "")
        if !tracks.isEmpty && tracks.count >= videos.count {
            audio.play(tracks, serverID: app.selectedServerID ?? "", shuffle: shuffle)
        } else {
            app.playAll(videos, shuffle: shuffle)
        }
    }

    private func load() async {
        guard let api = app.browseAPI else { loading = false; error = "Not connected to a server."; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.playlistItems(ratingKey)
            try Task.checkCancellation()
            items = result
            if let metadata = try? await api.playlistMetadata(ratingKey) {
                meta = metadata
                editedTitle = metadata.title
                isSmart = metadata.smart == true
            }
            error = nil
            await loadBackdrop()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension View {
    /// A playlist header row: no separator or row background, page margins.
    func headerRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var hubs: [PlexHub] = []
    @State private var suggestions: [PlexHub] = []
    @State private var searching = false
    @State private var error: String?
    @State private var filter = SearchCategory.all
    @State private var recents: [String] = []
    @State private var retry = 0
    /// Music genres for "Browse all".
    @State private var genres: [GenreEntry] = []
    /// Only what's downloaded (also what offline search shows).
    @State private var onDeviceOnly = false
    @State private var showAllOffline = false
    @Environment(DownloadManager.self) private var downloads
    private var offlineMatches: [DownloadRecord] {
        OfflineSearch.matches(downloads.records, query: trimmed, mode: mediaMode, category: filter)
    }
    private var historyKey: String { "search.history.\(mediaMode.rawValue).\(app.currentUserID ?? "").\(app.selectedServerID ?? "")" }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visible: [PlexHub] {
        (trimmed.isEmpty ? suggestions : hubs).compactMap { hub in
            var copy = hub
            copy.metadata = hub.metadata.filter { mediaMode.includes($0) && filter.includes($0.kind) }
            return copy.metadata.isEmpty ? nil : copy
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    if mediaMode == .watch {
                        PillPicker(options: [SearchCategory.all, .movies, .tv], selection: $filter) { $0.rawValue }
                    }
                    Spacer(minLength: 0)
                    Toggle(isOn: $onDeviceOnly) { Label("On This Device", systemImage: "arrow.down.circle") }
                        .toggleStyle(.button).buttonStyle(.bordered).controlSize(.small)
                        .padding(.trailing)
                }
                // Downloads that match, first (and alone when offline or filtered to this device).
                // Computed once per update; every match is reachable.
                let matches = offlineMatches
                if !matches.isEmpty {
                    let songs = matches.filter(\.isAudio)
                    let mixedServers = Set(matches.map(\.serverID)).count > 1
                    let showAll = onDeviceOnly || !app.isOnline || showAllOffline
                    HStack(alignment: .firstTextBaseline) {
                        Text("On This Device").font(.title3.bold())
                        Text("\(matches.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        if !(onDeviceOnly || !app.isOnline), matches.count > 6 {
                            Button(showAllOffline ? "Show Less" : "Show All \(matches.count)") { withAnimation { showAllOffline.toggle() } }
                                .font(.subheadline)
                        }
                    }
                    .padding(.horizontal)
                    ForEach(showAll ? matches : Array(matches.prefix(6))) { record in
                        OfflineTrackRow(record: record, siblings: record.isAudio ? songs : [],
                                        serverName: mixedServers ? ServerDirectory.shared.server(id: record.serverID)?.name : nil)
                            .padding(.horizontal)
                    }
                }
                if trimmed.isEmpty && !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent Searches").font(.headline)
                            Spacer()
                            Button("Clear") { recents = []; UserDefaults.standard.removeObject(forKey: historyKey) }
                        }
                        ForEach(recents, id: \.self) { recent in
                            Button { query = recent } label: { Label(recent, systemImage: "clock.arrow.circlepath") }
                        }
                    }.padding(.horizontal)
                }
                if onDeviceOnly || !app.isOnline {
                    if trimmed.count >= 2 && offlineMatches.isEmpty {
                        EmptyStateView(title: "No Downloads Match", systemImage: "arrow.down.circle",
                                       message: app.isOnline ? "Nothing downloaded matches “\(trimmed)”." : "Nothing downloaded matches “\(trimmed)”. Connect to search your whole library.")
                    } else if trimmed.count < 2 {
                        EmptyStateView(title: app.isOnline ? "Search Your Downloads" : "You're Offline", systemImage: "arrow.down.circle",
                                       message: app.isOnline ? "Type at least two characters." : "Search what's downloaded on this device. Connect to search your whole library.")
                    }
                } else if let error {
                    EmptyStateView(title: "Search Unavailable", systemImage: "wifi.exclamationmark", message: error)
                    Button("Retry") { retry += 1 }.frame(maxWidth: .infinity)
                } else {
                    ForEach(visible) { hub in
                        HubRow(title: hub.title, items: hub.metadata, wide: hub.type == "episode")
                    }
                    if trimmed.isEmpty && mediaMode == .music && !genres.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Browse all").font(.title3.bold())
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                ForEach(genres) { genre in
                                    NavigationLink { GenreView(genre: genre) } label: { GenreTile(title: genre.title) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    if visible.isEmpty && !searching && !(trimmed.isEmpty && !genres.isEmpty) {
                        EmptyStateView(title: trimmed.count >= 2 ? "No Results" : "Discover Your Library", systemImage: "magnifyingglass",
                                       message: trimmed.count >= 2 ? "Nothing matched “\(trimmed)” in \(filter.rawValue)." : "Search with at least two characters, or explore recently added titles.")
                    }
                }
            }.padding(.vertical)
        }
        .overlay { if searching { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
        .titleWithDownloadStatus("Search")
        .searchable(text: $query, prompt: mediaMode == .music ? "Artists, albums, songs…" : "Movies, shows, episodes…")
        .onSubmit(of: .search) { remember() }
        .task {
            recents = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        }
        .onChange(of: query) { showAllOffline = false }
        .task(id: "\(query)-\(retry)-\(onDeviceOnly)-\(app.api?.baseURL.absoluteString ?? "")") {
            hubs = []; error = nil; searching = false
            // Offline (or filtered to this device), results come from downloads alone.
            guard let api = app.api, app.isOnline, !onDeviceOnly else { return }
            guard trimmed.isEmpty || trimmed.count >= 2 else { return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(350))
                let result: [PlexHub]
                if trimmed.isEmpty && mediaMode == .music {
                    let libraries = try await api.sections().filter { mediaMode.includes(section: $0) }
                    var musicHubs: [PlexHub] = []
                    var found: [GenreEntry] = []
                    for library in libraries {
                        try Task.checkCancellation()
                        musicHubs += try await api.sectionHubs(library.key)
                        let dirs = (try? await api.container("/library/sections/\(library.key)/genre").directories) ?? []
                        found += dirs.map { GenreEntry(sectionKey: library.key, key: $0.key, title: $0.title) }
                    }
                    var seenGenres = Set<String>()
                    genres = found.filter { seenGenres.insert($0.title.lowercased()).inserted }
                    var seen = Set<String>()
                    result = musicHubs.filter { seen.insert($0.id).inserted }
                } else {
                    result = try await (trimmed.isEmpty ? api.homeHubs() : api.search(trimmed))
                }
                try Task.checkCancellation()
                if trimmed.isEmpty {
                    // Plex suggests rows for empty tags ("More from [no label]"); skip those.
                    let scoped = mediaMode.filter(result).filter { !$0.title.contains("[no ") && !$0.title.contains("[unknown") }
                    let recent = scoped.filter { ($0.hubIdentifier ?? $0.title).lowercased().contains("recent") }
                    suggestions = Array((recent.isEmpty ? scoped : recent).prefix(4))
                }
                else { hubs = result }
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; searching = false
            }
        }
        .onDisappear { remember() }
    }

    private func remember() {
        guard trimmed.count >= 2 else { return }
        recents = SearchHistory.adding(trimmed, to: recents)
        UserDefaults.standard.set(recents, forKey: historyKey)
    }
}

struct GenreEntry: Identifiable, Hashable {
    let sectionKey: String
    let key: String
    let title: String
    var id: String { sectionKey + "/" + key }
}

/// A genre's artists (or albums, when artists don't carry genres).
struct GenreView: View {
    @Environment(AppState.self) private var app
    let genre: GenreEntry
    @State private var items: [PlexMetadata] = []
    @State private var loading = true
    @ScaledMetric(relativeTo: .body) private var posterWidth = Cinema.gridPosterWidth

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item.route) { PosterCard(item: item, width: posterWidth) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(alignment: .top) {
            LinearGradient(colors: [GenreTile.color(for: genre.title).opacity(0.7), Cinema.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .ignoresSafeArea()
        }
        .overlay {
            if loading && items.isEmpty { ProgressView() }
            else if items.isEmpty { EmptyStateView(title: "Nothing Here", systemImage: "music.note", message: "No artists or albums are tagged \(genre.title).") }
        }
        .pageTitle(genre.title)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let api = app.browseAPI else { return }
        for type in ["8", "9"] {
            let found = (try? await api.page("/library/sections/\(genre.sectionKey)/all", start: 0, size: 500, query: [
                URLQueryItem(name: "type", value: type), URLQueryItem(name: "genre", value: genre.key),
                URLQueryItem(name: "sort", value: "titleSort"),
            ]).metadata) ?? []
            if !found.isEmpty { items = found; return }
        }
    }
}

/// Search over what's downloaded: titles, shows, artists and albums, ignoring case and accents.
enum OfflineSearch {
    static func matches(_ records: [DownloadRecord], query: String, mode: MediaMode, category: SearchCategory = .all) -> [DownloadRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return records.filter { r in
            guard r.state == .completed, r.isAudio == (mode == .music), category.includes(r.metadata.kind) else { return false }
            let m = r.metadata
            return [m.title, m.grandparentTitle, m.parentTitle, m.originalTitle].compactMap { $0 }.contains { $0.range(of: q, options: opts) != nil }
        }
    }
}

enum SearchCategory: String, CaseIterable {
    case all = "All", movies = "Movies", tv = "TV", music = "Music"
    func includes(_ kind: PlexMetadata.Kind) -> Bool {
        switch self {
        case .all: return true
        case .movies: return kind == .movie || kind == .clip
        case .tv: return [.show, .season, .episode].contains(kind)
        case .music: return [.artist, .album, .track].contains(kind)
        }
    }
}

enum SearchHistory {
    static func adding(_ query: String, to history: [String]) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return history }
        return Array(([text] + history.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(8))
    }
}

struct ContinueWatchingRow: View {
    @Environment(AppState.self) private var app
    let items: [PlexMetadata]
    /// Takes a card off the row at once, while the server is told.
    var onRemove: (PlexMetadata) -> Void = { _ in }
    @ScaledMetric private var cardWidth = 210.0
    /// "Go to Show" from a card's menu.
    @State private var showPage: ShowPage?
    struct ShowPage: Identifiable, Hashable { let id: String; let title: String }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            NavigationLink(value: item.route) {
                                PlexImage(path: item.backdrop ?? item.thumb, width: 600, height: 340)
                                    .frame(width: cardWidth, height: cardWidth * 0.56).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .zoomSource(item)
                            }
                            Text(item.grandparentTitle ?? item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            // Every card has a second line (episode, or year and length) so the Resume buttons line up.
                            Text(cardSubtitle(item)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            ProgressView(value: item.progress ?? 0)
                            Button { app.play(item) } label: {
                                Label("Resume" + (Fmt.remaining(ms: item.duration, offset: item.viewOffset).map { " · \($0)" } ?? ""), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }.font(.caption.weight(.semibold)).prominentButton()
                        }.frame(width: cardWidth).contextMenu { continueMenu(item) }
                    }
                }.padding(.horizontal)
            }
        }
        .navigationDestination(item: $showPage) { page in
            // Dressed like the pages `RouteDestinations` opens.
            ItemDetailView(ratingKey: page.id, fallbackTitle: page.title)
                .toolbar(.visible, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .miniPlayerClearance()
                .environment(\.isPushedPage, true)
        }
    }

    /// As on Apple TV: Go to Show and Remove from Continue Watching, then the usual actions.
    @ViewBuilder private func continueMenu(_ item: PlexMetadata) -> some View {
        if item.kind == .episode, let show = item.grandparentRatingKey {
            Button { showPage = ShowPage(id: show, title: item.grandparentTitle ?? "Show") } label: { Label("Go to Show", systemImage: "tv") }
        }
        if app.isOnline {
            Button {
                onRemove(item)
                Task {
                    do { try await app.api?.removeFromContinueWatching(item.ratingKey) } catch { app.actionError = error.localizedDescription }
                    app.libraryChanged()
                }
            } label: { Label("Remove from Continue Watching", systemImage: "minus.circle") }
        }
        Divider()
        ItemContextMenu(item: item)
    }

    private func cardSubtitle(_ item: PlexMetadata) -> String {
        if item.kind == .episode { return item.subtitleLine ?? item.title }
        let line = [item.year.map(String.init), Fmt.duration(ms: item.duration)].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? " " : line
    }
}

// MARK: - Create playlists

struct CreatePlaylistView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var initialSection: PlexDirectory? = nil
    var seedItems: [PlexMetadata] = []
    @State private var title = ""
    @State private var sections: [PlexDirectory] = []
    @State private var sectionID = ""
    private var category: String { mediaMode.playlistType }
    @State private var query = ""
    @State private var candidates: [PlexMetadata] = []
    @State private var selected: [PlexMetadata] = []
    @State private var paging = PageRequestState()
    @State private var offset = 0
    @State private var hasMore = true
    @State private var loadingLibraries = true
    @State private var saving = false
    @State private var error: String?
    @State private var created: PlexMetadata?
    private var availableSections: [PlexDirectory] {
        sections.filter { category == "audio" ? $0.type == "artist" : ["movie", "show"].contains($0.type) }
    }
    private var currentSection: PlexDirectory? { sections.first { $0.key == sectionID } }

    var body: some View { ProGate(.playlists) { content } }

    private var content: some View {
        NavigationStack {
            Group {
                if let created {
                    ContentUnavailableView {
                        Label("Playlist Created", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("“\(created.title)” is saved to \(app.selectedServer?.name ?? "your Plex server") with \(selected.count) items.")
                    } actions: { Button("Done") { dismiss() }.prominentButton() }
                } else {
                    List {
                        Section("Playlist") {
                            TextField("Playlist name", text: $title)
                            LabeledContent("Media", value: mediaMode == .music ? "Music" : "Videos")
                            if !availableSections.isEmpty {
                                Picker("Library", selection: $sectionID) {
                                    ForEach(availableSections) { Text($0.title).tag($0.key) }
                                }
                            }
                        }
                        if !selected.isEmpty {
                            Section("Selected · \(selected.count)") {
                                ForEach(selected) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.title)
                                            Text(item.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button { selected.removeAll { $0.ratingKey == item.ratingKey } } label: {
                                            Image(systemName: "minus.circle")
                                        }.accessibilityLabel("Remove \(item.title)")
                                    }
                                }
                            }
                        }
                        Section(category == "audio" ? "Choose Songs" : "Choose Videos") {
                            TextField("Filter by title", text: $query).autocorrectionDisabled()
                            if loadingLibraries || paging.isLoading { ProgressView() }
                            if !loadingLibraries && availableSections.isEmpty {
                                Text("No compatible libraries are available on this server.").foregroundStyle(.secondary)
                            }
                            ForEach(candidates) { item in
                                Button { toggle(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected.contains { $0.ratingKey == item.ratingKey } ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).foregroundStyle(.primary)
                                            Text([item.grandparentTitle, item.parentTitle].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityLabel("\(selected.contains { $0.ratingKey == item.ratingKey } ? "Deselect" : "Select") \(item.title)")
                            }
                            if hasMore && !paging.isLoading && currentSection != nil {
                                Button("Load More") { Task { await loadMore() } }
                            }
                            if candidates.isEmpty && !paging.isLoading && !loadingLibraries && error == nil && currentSection != nil {
                                Text("No matching items.").foregroundStyle(.secondary)
                            }
                        }
                        if let error {
                            Section {
                                Text(error).foregroundStyle(.red)
                                Button("Retry Loading") {
                                    Task { if sections.isEmpty { await loadLibraries() } else { await loadMore() } }
                                }
                            }
                        }
                        if !app.isOnline { Text("Connect to your server to create a playlist.").foregroundStyle(.secondary) }
                    }
                    .disabled(saving)
                    .overlay { if saving { ProgressView("Creating playlist…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                }
            }
            .pageTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(created == nil ? "Cancel" : "Close") { dismiss() }.disabled(saving) }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await save() } }
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || saving || !app.isOnline)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                selected = seedItems.filter { mediaMode.includes($0) }
                await loadLibraries()
            }
            .task(id: "\(sectionID)|\(query)") {
                paging.reset(); offset = 0; candidates = []; hasMore = true; error = nil
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                await loadMore()
            }
        }
    }

    private func toggle(_ item: PlexMetadata) {
        if selected.contains(where: { $0.ratingKey == item.ratingKey }) { selected.removeAll { $0.ratingKey == item.ratingKey } }
        else { selected.append(item) }
    }

    private func loadLibraries() async {
        loadingLibraries = true
        defer { loadingLibraries = false }
        guard let api = app.api, app.isOnline else { error = "Connect to your server to choose media."; return }
        do {
            sections = try await api.sections()
            try Task.checkCancellation()
            sectionID = availableSections.first(where: { $0.key == initialSection?.key })?.key ?? availableSections.first?.key ?? ""
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func loadMore() async {
        guard hasMore, let api = app.api, let section = currentSection, let generation = paging.begin() else { return }
        defer { paging.finish(generation) }
        let type = section.type == "artist" ? "10" : section.type == "show" ? "4" : "1"
        var filters = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "sort", value: "titleSort")]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty { filters.append(URLQueryItem(name: "title", value: term)) }
        do {
            let page = try await api.page("/library/sections/\(section.key)/all", start: offset, size: 60, query: filters)
            guard generation == paging.generation, !Task.isCancelled else { return }
            var seen = Set(candidates.map(\.ratingKey))
            candidates += page.metadata.filter { seen.insert($0.ratingKey).inserted }
            offset += page.metadata.count
            hasMore = !page.metadata.isEmpty && (page.totalSize.map { offset < $0 } ?? (page.metadata.count == 60))
            error = nil
        } catch { if generation == paging.generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func save() async {
        guard let api = app.api, app.isOnline else { error = "Connect to your server to create this playlist."; return }
        saving = true
        defer { saving = false }
        do { created = try await api.createPlaylist(title: title, items: selected); error = nil }
        catch { self.error = "Couldn't create the playlist: \(error.localizedDescription)" }
    }
}

struct AddToPlaylistView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let items: [PlexMetadata]
    init(item: PlexMetadata) { items = [item] }
    init(items: [PlexMetadata]) { self.items = items }
    @State private var playlists: [PlexMetadata] = []
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var creating = false
    var body: some View { ProGate(.playlists) { content } }

    private var content: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label("New Playlist", systemImage: "plus") }
                Section(items.count > 1 ? "Add \(items.count) Items to Playlist" : "Add to Playlist") {
                    ForEach(playlists) { playlist in
                        Button(playlist.title) { Task { await add(playlist) } }
                    }
                    if loading { ProgressView() }
                    else if playlists.isEmpty && error == nil { Text("No editable playlists yet. Create one above.").foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving || !app.isOnline)
            .overlay { if saving { ProgressView("Adding…") } }
            .pageTitle("Add to Playlist")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(saving) } }
            .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) { CreatePlaylistView(seedItems: items) }
            .task { await load() }
            .refreshable { await load() }
            .interactiveDismissDisabled(saving)
        }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        guard let api = app.api, app.isOnline else { error = "Connect to your server to edit playlists."; return }
        do {
            let type = items.first?.kind == .track ? "audio" : "video"
            playlists = try await api.playlists().filter { $0.playlistType == type && $0.smart != true }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func add(_ playlist: PlexMetadata) async {
        guard let api = app.api else { return }
        saving = true
        defer { saving = false }
        do { try await api.addToPlaylist(playlist.ratingKey, items: items); app.libraryChanged(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Music Home

struct MusicHomeView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    @State private var recent: [PlexMetadata] = []
    @State private var albums: [PlexMetadata] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var recommendations: [PlexHub] = []
    @State private var sections: [PlexDirectory] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                DownloadStatusPill()
                ForEach(homeLayout.order.filter { !homeLayout.hidden.contains($0) }, id: \.self) { id in homeSection(id) }
                if recent.isEmpty && playlists.isEmpty, ConnectionNotice.problem(app) != nil {
                    ConnectionNotice()
                } else if loading && recent.isEmpty && playlists.isEmpty { SkeletonHome(square: true) }
                if ConnectionNotice.problem(app) != nil && recent.isEmpty && playlists.isEmpty {
                    EmptyView()
                } else if let error {
                    EmptyStateView(title: "Couldn't Load Music", systemImage: "wifi.exclamationmark", message: error)
                    Button("Retry") { Task { await load() } }.frame(maxWidth: .infinity)
                } else if !loading && sections.isEmpty {
                    EmptyStateView(title: "Your Music", systemImage: "music.note",
                                   message: app.isOnline ? "Add a music library to your Plex server to browse it here." : "Connect to your server, or open Offline Music to listen to downloads.")
                }
            }.padding(.top, 4).padding(.bottom)
        }
        .homeTitle(.music)
        // Back from playing a playlist: move it up without waiting for a reload.
        .onAppear { playlists = MusicPlaylists.recentlyPlayedFirst(PlaylistPlays.applying(to: playlists, serverID: app.selectedServerID ?? "")) }
        .task(id: "\(app.api?.baseURL.absoluteString ?? "")-\(app.contentVersion)") { await load() }
        .refreshable { await load() }
    }

    private var homeLayout: MediaPreferences.HomeLayout { MediaPreferences.shared.layout(scope: app.preferenceScope, mode: .music) }
    @ViewBuilder private func homeSection(_ id: String) -> some View {
        switch id {
        case "shortcuts":
                // One quiet, scrollable row instead of two rows of filled buttons.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let section = sections.first {
                            NavigationLink { LibrarySectionView(section: section) } label: { QuickChip(title: "Artists", icon: "music.mic") }
                            NavigationLink { LibrarySectionView(section: section, initialMode: .albums) } label: { QuickChip(title: "Albums", icon: "square.stack") }
                            NavigationLink { LibrarySectionView(section: section, initialMode: .songs) } label: { QuickChip(title: "Songs", icon: "music.note") }
                        }
                        NavigationLink(value: Route.playlists) { QuickChip(title: "Playlists", icon: "music.note.list") }
                        Button { app.selectedTab = .downloads } label: { QuickChip(title: "Downloaded", icon: "arrow.down.circle") }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
        case "recent":
                // Quick access: what you played last, two to a row.
                let quick = QuickAccessItem.make(playlists: playlists, albumPlays: ManualPlays.recent(serverID: app.selectedServerID ?? ""), recentTracks: recent)
                if !quick.isEmpty {
                    Text("Recently Played").font(.title3.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(quick) { entry in
                            NavigationLink(value: entry.route) { QuickTile(entry: entry) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
        case "playlists":
                if !playlists.isEmpty { HubRow(title: "Playlists", items: playlists, moreRoute: .playlists) }
        case "mixes": MixesHomeSection()
        case "albums":
                if !albums.isEmpty { HubRow(title: "New Albums", items: albums) }
        case "recommendations":
                ForEach(recommendations) { hub in
                    HubRow(title: hub.title, items: hub.metadata,
                           moreRoute: (hub.more ?? false) ? hub.key.map { Route.hub(key: $0, title: hub.title) } : nil)
                }
        case "favorites": FavoritesHomeSection()
        default: EmptyView()
        }
    }

    private func load() async {
        guard let api = app.browseAPI else { return }
        loading = true
        defer { loading = false }
        do {
            let libraries = try await api.sections().filter { MediaMode.music.includes(section: $0) }
            var played: [PlexMetadata] = []
            var added: [PlexMetadata] = []
            var hubs: [PlexHub] = []
            for section in libraries {
                try Task.checkCancellation()
                async let recentPage = api.page("/library/sections/\(section.key)/all", start: 0, size: 16,
                                               query: [URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "lastViewedAt:desc")])
                async let albumPage = api.page("/library/sections/\(section.key)/all", start: 0, size: 16,
                                              query: [URLQueryItem(name: "type", value: "9"), URLQueryItem(name: "sort", value: "addedAt:desc")])
                async let sectionHubs = api.sectionHubs(section.key)
                played += try await recentPage.metadata.filter { $0.kind == .track && ($0.lastViewedAt ?? 0) > 0 }
                added += try await albumPage.metadata.filter { $0.kind == .album }
                hubs += (try? await sectionHubs) ?? []
            }
            try Task.checkCancellation()
            sections = libraries
            recent = Array(played.sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }.prefix(16))
            playlists = MusicPlaylists.recentlyPlayedFirst(PlaylistPlays.applying(to: (try? await api.playlists()) ?? [], serverID: app.selectedServerID ?? ""))
            SiriMedia.updateVocabulary(playlists: playlists)
            albums = Array(added.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(24))
            var seen = Set<String>()
            recommendations = MediaMode.music.filter(hubs).filter { seen.insert($0.id).inserted && !($0.hubIdentifier ?? $0.title).lowercased().contains("recent") && !$0.title.contains("[no ") }
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}


/// Small glass chip for the Listen Home shortcuts.
struct QuickChip: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(Cinema.accent)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Cinema.glass, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
}


enum MusicPlaylists {
    /// Music playlists, most recently played first; never-played ones follow, newest first.
    static func recentlyPlayedFirst(_ all: [PlexMetadata]) -> [PlexMetadata] {
        all.filter { $0.kind == .playlist && $0.playlistType == "audio" }
            .sorted { a, b in
                switch (a.lastViewedAt, b.lastViewedAt) {
                case let (x?, y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return (a.addedAt ?? 0) > (b.addedAt ?? 0)
                }
            }
    }
}


/// Shortcuts at the top of the Listen Library: everything that used to sit beside the Music card.
struct MusicLibraryChips: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NavigationLink(value: Route.mixes) { QuickChip(title: "Mixes", icon: "wand.and.stars") }
                NavigationLink(value: Route.playlists) { QuickChip(title: "Playlists", icon: "music.note.list") }
                NavigationLink(value: Route.favorites) { QuickChip(title: "Favorites", icon: "heart") }
                NavigationLink(value: Route.history) { QuickChip(title: "History", icon: "clock.arrow.circlepath") }
                NavigationLink(value: Route.storageCleanup) { QuickChip(title: "Free Up Space", icon: "trash.circle") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }
}


// MARK: - Loading placeholders

/// Faint outlines of a Home page while it loads: a banner and a few rows of posters.
struct SkeletonHome: View {
    var square = false
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if !square {
                RoundedRectangle(cornerRadius: 14).frame(height: 260).padding(.horizontal)
            }
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 150, height: 16).padding(.horizontal)
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 6).frame(width: 120, height: square ? 120 : 180)
                                RoundedRectangle(cornerRadius: 3).frame(width: 90, height: 10)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(dim ? 0.05 : 0.11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
        .accessibilityLabel("Loading")
    }
}

/// Home's Recently Added TV: new episodes and seasons show as their show, once each,
/// with the season's unwatched count on the poster.
enum ShowGrouping {
    static func showLevel(_ items: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        var out: [PlexMetadata] = []
        for item in items {
            var shown = item
            switch item.kind {
            case .season:
                guard let show = item.parentRatingKey else { break }
                shown.ratingKey = show
                shown.key = "/library/metadata/\(show)/children"
                shown.type = "show"
                shown.title = item.parentTitle ?? item.title
                shown.thumb = item.parentThumb ?? item.thumb
                shown.year = nil
            case .episode:
                guard let show = item.grandparentRatingKey else { break }
                shown.ratingKey = show
                shown.key = "/library/metadata/\(show)/children"
                shown.type = "show"
                shown.title = item.grandparentTitle ?? item.title
                shown.thumb = item.grandparentThumb ?? item.thumb
                shown.art = item.grandparentArt ?? item.art
                shown.year = nil
                shown.viewOffset = nil
                shown.leafCount = nil
                shown.viewedLeafCount = nil
            default:
                break
            }
            if seen.insert(shown.ratingKey).inserted { out.append(shown) }
        }
        return out
    }
}


/// Continue Watching for the Home Screen widget, saved where the widget can read it.
enum HomeWidgetData {
    @MainActor
    static func save(_ items: [PlexMetadata], app: AppState) {
        TopShelfSnapshot(items: items.filter { $0.progress != nil }.prefix(6).map { item in
            TopShelfSnapshot.Item(
                ratingKey: item.ratingKey,
                title: item.kind == .episode ? (item.grandparentTitle ?? item.title) : item.title,
                subtitle: [item.kind == .episode ? item.subtitleLine : nil,
                           Fmt.remaining(ms: item.duration, offset: item.viewOffset)].compactMap { $0 }.joined(separator: " · "),
                imageURL: app.imageURL(item.kind == .episode ? item.thumb : (item.art ?? item.thumb), width: 640, height: 360),
                progress: item.progress)
        }, serverID: app.browseAPI?.serverID).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueWatching")
    }
}
