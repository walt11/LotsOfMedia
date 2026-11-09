import SwiftUI

/// Library: pick Movies, TV Shows, Music or Playlists, then browse everything in a grid —
/// sorted and filtered (unwatched, genre, decade, 4K), as collections, or by first letter.
struct TVLibraryView: View {
    @Environment(TVSession.self) private var session
    @State private var sectionKey: String?
    @State private var view: ViewMode = .all
    @State private var sort = Self.sorts[0]
    @State private var unwatchedOnly = false
    @State private var genre: PlexDirectory?
    @State private var decade: PlexDirectory?
    @State private var only4K = false
    @State private var genres: [PlexDirectory] = []
    @State private var decades: [PlexDirectory] = []
    @State private var letters: [Letter] = []
    /// The list the grid holds (see `listKey`).
    @State private var loadedKey = ""
    @State private var items: [PlexMetadata] = []
    @State private var total: Int?
    /// A page requested for a list that's since changed is dropped, and doesn't hold up the new list.
    @State private var paging = PageRequestState()
    private var loading: Bool { paging.isLoading }
    @FocusState private var focusedItem: String?

    static let playlistsKey = "playlists"
    private var sections: [PlexDirectory] { session.browsableSections + session.photoSections }
    private var isPhotos: Bool { section?.type == "photo" }
    private var isPlaylists: Bool { sectionKey == Self.playlistsKey }
    private var section: PlexDirectory? { isPlaylists ? nil : (sections.first { $0.key == sectionKey } ?? sections.first) }
    private let pageSize = 100
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 260), spacing: 48)]

    enum ViewMode: String, CaseIterable { case all = "All", collections = "Collections" }

    struct Sort: Hashable { let key: String; let label: String }
    static let sorts = [
        Sort(key: "titleSort", label: "Title"),
        Sort(key: "addedAt:desc", label: "Date Added"),
        Sort(key: "originallyAvailableAt:desc", label: "Release Date"),
        Sort(key: "audienceRating:desc", label: "Rating"),
        Sort(key: "lastViewedAt:desc", label: "Last Watched"),
    ]

    struct Letter: Hashable { let title: String; let size: Int }

    /// The letter strip appears when the grid is in title order.
    private var showsLetters: Bool { !isPlaylists && !isPhotos && view == .all && sort.key == "titleSort" && letters.count > 1 }

    var body: some View {
        Group {
            if session.status != .connected {
                TVConnectionStatus()
            } else if sections.isEmpty {
                Text("This server has no movie, TV or music libraries.").foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: 20) {
                        TVPageScrollView {
                            VStack(alignment: .leading, spacing: 30) {
                                sectionRow
                                if !isPlaylists && !isPhotos { controlRow }
                                if isPhotos { TVPhotoGrid(items: items) { Task { await loadMore() } } } else { grid }
                                if loading { ProgressView().frame(maxWidth: .infinity) }
                            }
                            .padding(.leading, 80)
                            .padding(.trailing, showsLetters ? 0 : 80)
                            .padding(.vertical, 40)
                        }
                        if showsLetters { letterStrip(proxy) }
                    }
                }
            }
        }
        .task(id: session.status == .connected) { if session.sections.isEmpty { await session.refreshSections() } }
        .task(id: "\(sectionKey ?? "")-\(session.contentVersion)") { await loadFilters() }
        .task(id: "\(listKey)-\(session.contentVersion)") {
            // Same list, just fresher (back from watching something): update it in place so the
            // grid keeps its place and focus instead of starting over at the top.
            if listKey == loadedKey, !items.isEmpty { await refreshInPlace() } else { loadedKey = listKey; await reload() }
        }
    }

    // MARK: Rows

    private var sectionRow: some View {
        HStack(spacing: 24) {
            ForEach(sections, id: \.key) { s in
                Button { select(s.key) } label: { Label(s.title, systemImage: icon(s)) }
                    .buttonStyle(TVActionStyle(selected: s.key == section?.key))
            }
            Button { select(Self.playlistsKey) } label: { Label("Playlists", systemImage: "music.note.list") }
                .buttonStyle(TVActionStyle(selected: isPlaylists))
        }
        .focusSection()
    }

    private var controlRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if section?.type != "artist" {
                    ForEach(ViewMode.allCases, id: \.self) { m in
                        Button(m.rawValue) { view = m }.buttonStyle(TVActionStyle(selected: view == m, compact: true))
                    }
                    divider
                }
                if view == .all {
                    Menu {
                        ForEach(Self.sorts, id: \.self) { s in
                            Button { sort = s } label: { if s == sort { Label(s.label, systemImage: "checkmark") } else { Text(s.label) } }
                        }
                    } label: { Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down") }
                    .menuStyle(.button)
                    .buttonStyle(TVActionStyle(compact: true))
                    if section?.type != "artist" {
                        Button { unwatchedOnly.toggle() } label: { Label("Unwatched", systemImage: "eye.slash") }
                            .buttonStyle(TVActionStyle(selected: unwatchedOnly, compact: true))
                    }
                    if !genres.isEmpty { filterMenu("Genre", systemImage: "theatermasks", options: genres, selection: $genre) }
                    if !decades.isEmpty { filterMenu("Decade", systemImage: "calendar", options: decades, selection: $decade) }
                    if section?.type == "movie" {
                        Button { only4K.toggle() } label: { Label("4K", systemImage: "4k.tv") }
                            .buttonStyle(TVActionStyle(selected: only4K, compact: true))
                    }
                    if unwatchedOnly || genre != nil || decade != nil || only4K {
                        Button { unwatchedOnly = false; genre = nil; decade = nil; only4K = false } label: { Label("Clear", systemImage: "xmark") }
                            .buttonStyle(TVActionStyle(compact: true))
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func filterMenu(_ title: String, systemImage: String, options: [PlexDirectory], selection: Binding<PlexDirectory?>) -> some View {
        Menu {
            Button { selection.wrappedValue = nil } label: { if selection.wrappedValue == nil { Label("Any", systemImage: "checkmark") } else { Text("Any") } }
            ForEach(options, id: \.key) { o in
                Button { selection.wrappedValue = o } label: {
                    if o.key == selection.wrappedValue?.key { Label(o.title, systemImage: "checkmark") } else { Text(o.title) }
                }
            }
        } label: { Label(selection.wrappedValue?.title ?? title, systemImage: systemImage) }
        .menuStyle(.button)
        .buttonStyle(TVActionStyle(selected: selection.wrappedValue != nil, compact: true))
    }

    private var divider: some View {
        Capsule().fill(.white.opacity(0.15)).frame(width: 2, height: 30).padding(.horizontal, 6)
    }

    private var grid: some View {
        Group {
            if items.isEmpty && !loading {
                Text(isPlaylists ? "No playlists yet." : (view == .collections ? "No collections in this library." : "Nothing matches these filters."))
                    .foregroundStyle(.secondary).padding(.top, 40)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                ForEach(items) { item in
                    NavigationLink(value: item) { TVPosterCard(item: item) }.playsOnPlayPause(item)
                        .buttonStyle(.borderless)
                        .focused($focusedItem, equals: item.id)
                        .id(item.id)
                        .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .focusSection()
        }
    }

    /// # A B C … down the right edge: select a letter to jump there.
    private func letterStrip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(letters, id: \.self) { letter in
                    Button(letter.title) { Task { await jump(to: letter, proxy: proxy) } }
                        .buttonStyle(TVLetterStyle())
                }
            }
            .padding(.vertical, 30)
        }
        .frame(width: 70)
        .padding(.trailing, 30)
        .focusSection()
    }

    // MARK: Loading

    private func select(_ key: String) {
        guard key != sectionKey else { return }
        sectionKey = key
        view = .all; unwatchedOnly = false; genre = nil; decade = nil; only4K = false
        sort = Self.sorts[0]
    }

    private func icon(_ s: PlexDirectory) -> String {
        switch s.type {
        case "movie": "film"
        case "show": "tv"
        case "artist": "music.note"
        case "photo": "photo.on.rectangle"
        default: "folder"
        }
    }

    /// Genres and decades for the filter menus.
    private func loadFilters() async {
        genres = []; decades = []
        guard let api = session.api, let section, section.type != "photo" else { return }
        async let g = try? api.container("/library/sections/\(section.key)/genre")
        async let d = try? api.container("/library/sections/\(section.key)/decade")
        genres = await g?.directories ?? []
        decades = section.type == "artist" ? [] : (await d?.directories ?? [])
    }

    private var filterQuery: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if unwatchedOnly { q.append(URLQueryItem(name: section?.type == "show" ? "unwatchedLeaves" : "unwatched", value: "1")) }
        if let genre { q.append(URLQueryItem(name: "genre", value: genre.key)) }
        if let decade { q.append(URLQueryItem(name: "decade", value: decade.key)) }
        if only4K { q.append(URLQueryItem(name: "resolution", value: "4k")) }
        return q
    }

    /// What's being listed; a change starts the grid over.
    private var listKey: String {
        "\(sectionKey ?? "")-\(view)-\(sort.key)-\(unwatchedOnly)-\(genre?.key ?? "")-\(decade?.key ?? "")-\(only4K)"
    }

    /// Reloads what's already shown (watched marks, progress) in one request, keeping its length.
    private func refreshInPlace() async {
        guard let api = session.api else { return }
        let key = listKey
        if isPlaylists {
            let fresh = ((try? await api.playlists()) ?? []).filter { $0.playlistType != "photo" }
            guard key == listKey, !fresh.isEmpty else { return }
            items = fresh; total = fresh.count
            return
        }
        guard let section, !loading else { return }
        let mode = view
        let path = mode == .collections ? "/library/sections/\(section.key)/collections" : "/library/sections/\(section.key)/all"
        var query = [URLQueryItem(name: "sort", value: section.type == "photo" ? "originallyAvailableAt:desc" : mode == .collections ? "titleSort" : sort.key)]
        if mode == .all { query += filterQuery }
        let count = max(items.count, pageSize)
        guard let page = try? await api.page(path, start: 0, size: count, query: query), key == listKey else { return }
        items = page.metadata
        total = page.totalSize ?? (page.metadata.count < count ? items.count : nil)
    }

    private func reload() async {
        items = []; total = nil; letters = []
        paging.reset()
        if isPlaylists {
            guard let api = session.api, let request = paging.begin() else { return }
            defer { paging.finish(request) }
            let lists = ((try? await api.playlists()) ?? []).filter { $0.playlistType != "photo" }
            guard request == paging.generation else { return }
            items = lists
            total = lists.count
            return
        }
        await loadMore()
        if view == .all && sort.key == "titleSort" && !isPhotos { await loadLetters() }
    }

    private func loadLetters() async {
        guard let api = session.api, let section else { return }
        guard let (body, _) = try? await api.data("/library/sections/\(section.key)/firstCharacter", query: filterQuery),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any],
              let dirs = container["Directory"] as? [[String: Any]] else { return }
        letters = dirs.compactMap { d in
            guard let title = d["title"] as? String else { return nil }
            let size = (d["size"] as? Int) ?? Int(d["size"] as? String ?? "") ?? 0
            return size > 0 ? Letter(title: title, size: size) : nil
        }
    }

    /// `size`: how many to fetch, when more than a page is needed at once.
    private func loadMore(size: Int? = nil) async {
        guard !isPlaylists, let api = session.api, let section, total.map({ items.count < $0 }) ?? true,
              let request = paging.begin() else { return }
        defer { paging.finish(request) }
        let key = section.key, mode = view
        let path = mode == .collections ? "/library/sections/\(key)/collections" : "/library/sections/\(key)/all"
        // Photos: newest first, albums and photos together.
        var query = [URLQueryItem(name: "sort", value: section.type == "photo" ? "originallyAvailableAt:desc" : mode == .collections ? "titleSort" : sort.key)]
        if mode == .all { query += filterQuery }
        let count = size ?? pageSize
        guard let page = try? await api.page(path, start: items.count, size: count, query: query),
              request == paging.generation else { return }
        items += page.metadata
        total = page.totalSize ?? (page.metadata.count < count ? items.count : nil)
    }

    /// Loads pages up to the letter's first item, then moves focus (and the grid) there.
    private func jump(to letter: Letter, proxy: ScrollViewProxy) async {
        let offset = letters.prefix { $0 != letter }.reduce(0) { $0 + $1.size }
        while items.count <= offset, total.map({ items.count < $0 }) ?? true {
            let before = items.count
            // Everything up to the letter in one request (or a few, in a very large library).
            await loadMore(size: min(max(offset + pageSize - before, pageSize), 2000))
            if items.count == before { break }
        }
        guard items.indices.contains(offset) else { return }
        let id = items[offset].id
        proxy.scrollTo(id, anchor: .top)
        focusedItem = id
    }
}

/// Letters in the jump strip: small, turning white under focus.
private struct TVLetterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .font(.caption2.weight(.bold))
                .frame(width: 54, height: 34)
                .foregroundStyle(focused ? Color.black : Color.white.opacity(0.7))
                .background(focused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(focused ? 1.2 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}
