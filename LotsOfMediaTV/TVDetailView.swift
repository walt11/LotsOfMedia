import SwiftUI

/// One page for every kind of item: movies and episodes play; shows list seasons and
/// episodes; seasons list episodes; albums list songs; artists list albums.
struct TVDetailView: View {
    @Environment(TVSession.self) private var session
    let item: PlexMetadata
    @State private var detail: PlexMetadata?
    @State private var children: [PlexMetadata] = []
    @State private var seasonKey: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var playing: TVPlayRequest?
    @State private var showNowPlaying = false
    @State private var related: [PlexMetadata] = []
    @State private var extras: [PlexMetadata] = []
    /// The main button (Resume, Play, Play S1 E2, Shuffle) gets focus when the page opens, also
    /// when it's opened from the Top Shelf (where focus would otherwise stay on the tab bar).
    @FocusState private var primaryFocused: Bool
    @State private var focusedPrimary = false
    private var trailer: PlexMetadata? { extras.first { $0.subtype == "trailer" } }

    private var shown: PlexMetadata { detail ?? item }

    var body: some View {
        TVPageScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                switch shown.kind {
                case .show: showContent
                case .season: episodeList(children)
                case .album, .playlist: trackList
                case .artist, .collection:
                    if !children.isEmpty {
                        TVRow(title: shown.kind == .artist ? "Albums" : "In This Collection") {
                            ForEach(children) { c in
                                NavigationLink(value: c) { TVPosterCard(item: c) }.buttonStyle(.borderless)
                            }
                        }
                        .padding(.horizontal, -80)
                    }
                default: EmptyView()
                }
                if !extras.isEmpty { extrasRow }
                if !shown.roles.isEmpty, [.movie, .show, .episode, .season].contains(shown.kind) { castRow }
                if !related.isEmpty {
                    TVRow(title: shown.kind == .album || shown.kind == .artist ? "You Might Also Like" : "More Like This") {
                        ForEach(related) { r in
                            NavigationLink(value: r) { TVPosterCard(item: r) }.buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, -80)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            TVImage(path: shown.backdrop ?? shown.thumb, width: 1920, height: 1080)
                .overlay(LinearGradient(colors: [TVTheme.background.opacity(0.55), TVTheme.background], startPoint: .top, endPoint: .bottom))
                .overlay(LinearGradient(colors: [TVTheme.background.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                .ignoresSafeArea()
        }
        .task(id: session.contentVersion) { await load() }
        .fullScreenCover(item: $playing) { TVPlayerView(request: $0) }
        .fullScreenCover(isPresented: $showNowPlaying) { TVNowPlayingView() }
    }

    /// Songs go to the music player (which keeps playing while browsing); videos play full screen.
    private func playQueue(_ list: [PlexMetadata], start: Int = 0) {
        if !list.isEmpty, list.allSatisfy({ $0.kind == .track }) {
            TVMusicPlayer.shared.play(list, start: start, session: session)
            showNowPlaying = true
        } else {
            playing = TVPlayRequest(queue: list, start: start)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 60) {
            if [.album, .artist, .season, .playlist, .collection].contains(shown.kind) {
                TVImage(path: shown.posterThumb ?? shown.thumb, width: 600, height: 600, placeholderIcon: "music.note")
                    .frame(width: 360, height: shown.kind == .season || shown.kind == .collection ? 540 : 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            VStack(alignment: .leading, spacing: 18) {
                if shown.kind == .episode, let show = shown.grandparentTitle {
                    Text(show).font(.title3).foregroundStyle(.secondary)
                }
                if shown.kind == .album, let artist = shown.parentTitle {
                    Text(artist).font(.title3).foregroundStyle(.secondary)
                }
                Text(shown.title).font(.system(size: 64, weight: .heavy).width(.compressed)).lineLimit(2)
                HStack(spacing: 14) {
                    let meta = shown.tvMetaLine
                    if !meta.isEmpty { Text(meta).font(.callout).foregroundStyle(.secondary) }
                    TVQualityChips(item: shown).id(MediaVersionChoice.shared.revision)
                }
                if let tagline = shown.tagline, !tagline.isEmpty { Text(tagline).font(.headline).italic() }
                if let summary = shown.summary, !summary.isEmpty {
                    Text(summary).font(.callout).lineLimit(5).frame(maxWidth: 1100, alignment: .leading)
                }
                actions.padding(.top, 10)
            }
        }
        .focusSection()
    }

    /// Marks the item (a whole show or season too) watched or unwatched.
    private var watchedButton: some View {
        Button { Task { await session.setWatched(shown, !shown.isWatched) } } label: {
            Label(shown.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: shown.isWatched ? "eye.slash" : "eye")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 30) {
            if shown.isPlayableVideo {
                if let remaining = Fmt.remaining(ms: shown.duration, offset: shown.viewOffset), (shown.viewOffset ?? 0) > 0 {
                    Button { playing = TVPlayRequest(item: shown, resume: true) } label: {
                        Label("Resume · \(remaining)", systemImage: "play.fill")
                    }
                    .focused($primaryFocused)
                    Button { playing = TVPlayRequest(item: shown, resume: false) } label: {
                        Label("From Beginning", systemImage: "gobackward")
                    }
                } else {
                    Button { playing = TVPlayRequest(item: shown, resume: false) } label: { Label("Play", systemImage: "play.fill") }
                        .focused($primaryFocused)
                }
                if let trailer {
                    Button { playing = TVPlayRequest(item: trailer, resume: false) } label: { Label("Trailer", systemImage: "film") }
                }
                watchedButton
                ratingMenu
                if shown.media.count > 1 { versionMenu }
                if let part = shown.primaryPart, part.audioStreams.count > 1 || !part.subtitleStreams.isEmpty {
                    streamMenu(part)
                }
            } else if shown.kind == .show {
                if let next = nextEpisode {
                    Button { playing = TVPlayRequest(item: next, resume: (next.viewOffset ?? 0) > 0) } label: {
                        Label(next.index.map { "Play S\(next.parentIndex ?? 1) E\($0)" } ?? "Play", systemImage: "play.fill")
                    }
                    .focused($primaryFocused)
                }
                if let trailer {
                    Button { playing = TVPlayRequest(item: trailer, resume: false) } label: { Label("Trailer", systemImage: "film") }
                }
                watchedButton
                ratingMenu
            } else if shown.kind == .season {
                watchedButton
                    .focused($primaryFocused)
            } else if [.album, .playlist].contains(shown.kind), !tracks.isEmpty {
                Button { playQueue(tracks) } label: { Label("Play", systemImage: "play.fill") }
                    .focused($primaryFocused)
                Button { playQueue(tracks.shuffled()) } label: { Label("Shuffle", systemImage: "shuffle") }
            } else if shown.kind == .artist {
                Button {
                    Task {
                        guard let api = session.api, let all = try? await api.allLeaves(shown.ratingKey), !all.isEmpty else { return }
                        playQueue(all.shuffled())
                    }
                } label: { Label("Shuffle", systemImage: "shuffle") }
                .focused($primaryFocused)
            }
        }
        .buttonStyle(TVActionStyle())
    }

    /// Your own 1–5 star rating.
    private var ratingMenu: some View {
        let stars = Int(((shown.userRating ?? 0) / 2).rounded())
        return Menu {
            ForEach((1...5).reversed(), id: \.self) { n in
                Button { Task { await session.rate(shown, stars: n) } } label: {
                    Text(String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n) + (n == stars ? "  ✓" : ""))
                }
            }
            if stars > 0 { Button("Clear Rating") { Task { await session.rate(shown, stars: 0) } } }
        } label: {
            Label(stars > 0 ? String(repeating: "★", count: stars) : "Rate", systemImage: stars > 0 ? "star.fill" : "star")
        }
    }

    /// Which of the title's files plays: 4K or 1080p, an extended cut…
    private var versionMenu: some View {
        let _ = MediaVersionChoice.shared.revision
        let current = shown.primaryMediaIndex
        return Menu {
            ForEach(Array(shown.media.enumerated()), id: \.offset) { i, media in
                Button { MediaVersionChoice.shared.choose(media, of: shown) } label: {
                    if i == current { Label(media.versionLabel(), systemImage: "checkmark") } else { Text(media.versionLabel()) }
                }
            }
        } label: {
            Label(shown.primaryMedia?.resolutionLabel.map { "Version · \($0)" } ?? "Version", systemImage: "square.stack.3d.up")
        }
    }

    /// Audio and subtitle choice, saved on the server (so Plex and the iPhone app use it too).
    private func streamMenu(_ part: PlexPart) -> some View {
        Menu {
            if part.audioStreams.count > 1 {
                Section("Audio") {
                    ForEach(part.audioStreams) { a in
                        Button { choose(part, audio: a.id, subtitle: nil) } label: {
                            if a.id == part.selectedAudio?.id { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                        }
                    }
                }
            }
            if !part.subtitleStreams.isEmpty {
                Section("Subtitles") {
                    Button { choose(part, audio: nil, subtitle: 0) } label: {
                        if part.selectedSubtitle == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                    }
                    ForEach(part.subtitleStreams) { s in
                        Button { choose(part, audio: nil, subtitle: s.id) } label: {
                            if s.id == part.selectedSubtitle?.id { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                        }
                    }
                }
            }
        } label: {
            Label("Audio & Subtitles", systemImage: "captions.bubble")
        }
        .menuStyle(.button)
    }

    private func choose(_ part: PlexPart, audio: Int?, subtitle: Int?) {
        Task {
            guard let api = session.api else { return }
            try? await api.selectStreams(partID: part.id, audioStreamID: audio, subtitleStreamID: subtitle)
            if let fresh = try? await api.metadata(item.ratingKey) { detail = fresh }
        }
    }

    // MARK: Shows

    private var nextEpisode: PlexMetadata? {
        episodes.first { ($0.viewOffset ?? 0) > 0 } ?? episodes.first { !$0.isWatched } ?? episodes.first
    }

    @ViewBuilder private var showContent: some View {
        if !children.isEmpty {
            HStack(spacing: 24) {
                ForEach(children) { season in
                    Button { seasonKey = season.ratingKey } label: {
                        Text(season.title).fontWeight(season.ratingKey == currentSeason?.ratingKey ? .bold : .regular)
                    }
                    .buttonStyle(TVActionStyle(selected: season.ratingKey == currentSeason?.ratingKey))
                }
            }
            .focusSection()
            episodeList(episodes.filter { $0.parentRatingKey == currentSeason?.ratingKey })
        }
    }

    private var currentSeason: PlexMetadata? {
        children.first { $0.ratingKey == seasonKey }
            ?? children.first { s in episodes.contains { $0.parentRatingKey == s.ratingKey && !$0.isWatched } }
            ?? children.first
    }

    private func episodeList(_ list: [PlexMetadata]) -> some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, ep in
                Button { playing = TVPlayRequest(queue: list, start: i, resume: (ep.viewOffset ?? 0) > 0) } label: {
                    HStack(spacing: 30) {
                        TVImage(path: ep.thumb, width: 640, height: 360)
                            .frame(width: 320, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottom) { TVProgressBar(item: ep) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(ep.index.map { "\($0). " } ?? "")\(ep.title)").font(.headline)
                            Text(ep.tvMetaLine).font(.caption).foregroundStyle(.secondary)
                            if let s = ep.summary { Text(s).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if ep.isWatched { Image(systemName: "checkmark.circle.fill").foregroundStyle(TVTheme.accent) }
                    }
                    .padding(16)
                }
                .buttonStyle(.card)
                // Press and hold an episode to mark it.
                .contextMenu {
                    Button { Task { await session.setWatched(ep, !ep.isWatched) } } label: {
                        Label(ep.isWatched ? "Mark Unwatched" : "Mark Watched", systemImage: ep.isWatched ? "eye.slash" : "eye")
                    }
                    if (ep.viewOffset ?? 0) > 0 {
                        Button { playing = TVPlayRequest(queue: list, start: i, resume: false) } label: {
                            Label("Play From Beginning", systemImage: "gobackward")
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    // MARK: Music

    private var tracks: [PlexMetadata] { children.filter { $0.kind == .track || $0.isPlayableVideo } }

    private var trackList: some View {
        LazyVStack(spacing: 8) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                Button { playQueue(tracks, start: i) } label: {
                    HStack(spacing: 24) {
                        Text(t.index.map(String.init) ?? "\(i + 1)").foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title)
                            if shown.kind == .playlist, let artist = t.grandparentTitle { Text(artist).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(Fmt.duration(ms: t.duration) ?? "").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .contextMenu {
                    if t.kind == .track {
                        Button { TVMusicPlayer.shared.queueNext([t], session: session) } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    // MARK: Cast

    private var castRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast").font(.headline).foregroundStyle(.white.opacity(0.9))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 34) {
                    ForEach(Array(shown.roles.prefix(20).enumerated()), id: \.offset) { _, person in
                        if person.filter != nil {
                            NavigationLink(value: TVPerson(tag: person)) { TVCastCard(person: person) }
                                .buttonStyle(TVCastStyle())
                        } else {
                            TVCastCard(person: person).focusable()
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // MARK: Extras

    private var extrasRow: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trailers & Extras").font(.headline).foregroundStyle(.white.opacity(0.9))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(extras) { extra in
                        Button { playing = TVPlayRequest(item: extra, resume: false) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                TVImage(path: extra.thumb, width: 640, height: 360, placeholderIcon: "film")
                                    .frame(width: 400, height: 225)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .bottomTrailing) {
                                        if let d = Fmt.duration(ms: extra.duration) {
                                            Text(d).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                                                .background(.black.opacity(0.6), in: Capsule()).padding(10)
                                        }
                                    }
                                Text(extra.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(Self.extraKind(extra)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 400)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    static func extraKind(_ m: PlexMetadata) -> String { PlexMetadata.extraKind(m.subtype) }

    // MARK: Loading

    /// Once per page: after the details arrive (a show's after its episodes, for Play S1 E2).
    /// Set again a moment later, because a page pushed from the Top Shelf appears while the
    /// tab bar still holds focus.
    private func focusPrimaryOnce() {
        guard !focusedPrimary else { return }
        focusedPrimary = true
        primaryFocused = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            primaryFocused = true
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        if let fresh = try? await api.metadata(item.ratingKey) { detail = fresh }
        defer { focusPrimaryOnce() }
        if item.kind != .show { focusPrimaryOnce() }
        if extras.isEmpty, [.movie, .show, .season].contains(item.kind) {
            extras = await api.extras(item.ratingKey)
        }
        if related.isEmpty, [.movie, .show, .album, .artist].contains(item.kind) {
            related = await api.related(item.ratingKey).first { !$0.metadata.isEmpty }?.metadata ?? []
        }
        switch item.kind {
        case .show:
            async let seasons = try? api.children(item.ratingKey)
            async let all = try? api.allLeaves(item.ratingKey)
            children = (await seasons ?? []).filter { $0.kind == .season }
            episodes = await all ?? []
        case .season, .album, .artist:
            children = (try? await api.children(item.ratingKey)) ?? []
        case .collection:
            children = (try? await api.container("/library/collections/\(item.ratingKey)/children").metadata) ?? []
        case .playlist:
            children = (try? await api.playlistItems(item.ratingKey)) ?? []
        default:
            break
        }
    }
}

/// A cast member: round photo, name and role. Selecting one opens their page.
private struct TVCastCard: View {
    @Environment(\.isFocused) private var focused
    let person: PlexTag

    var body: some View {
        VStack(spacing: 10) {
            TVImage(path: person.thumb, width: 300, height: 300, placeholderIcon: "person.fill")
                .frame(width: 150, height: 150)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 4))
            Text(person.tag).font(.caption.weight(.semibold)).lineLimit(1)
            Text(person.role ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 180)
        .scaleEffect(focused ? 1.1 : 1)
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// Cast cards as buttons, without the system's card lift (the photo ring shows focus).
private struct TVCastStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Someone from a cast list, for their page.
struct TVPerson: Hashable {
    let tag: PlexTag
}

/// A person's page: their photo and everything they're in across your movie and TV libraries.
struct TVPersonView: View {
    @Environment(TVSession.self) private var session
    let person: TVPerson
    @State private var items: [PlexMetadata] = []
    @State private var loading = true
    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 260), spacing: 48)]

    var body: some View {
        TVPageScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(spacing: 40) {
                    TVImage(path: person.tag.thumb, width: 400, height: 400, placeholderIcon: "person.fill")
                        .frame(width: 200, height: 200).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 10) {
                        Text(person.tag.tag).font(.system(size: 64, weight: .heavy).width(.compressed))
                        Text(loading ? "Looking through your libraries…" : "\(items.count) title\(items.count == 1 ? "" : "s") in your libraries")
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                    ForEach(items) { item in
                        NavigationLink(value: item) { TVPosterCard(item: item) }.buttonStyle(.borderless)
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let api = session.api, let filter = person.tag.filter else { return }
        items = await api.titles(withFilter: filter, in: session.browsableSections)
    }
}
