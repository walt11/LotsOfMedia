import SwiftUI

struct ItemDetailView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var audio
    @Environment(\.horizontalSizeClass) private var sizeClass
    let ratingKey: String
    let fallbackTitle: String

    @State private var item: PlexMetadata?
    @State private var children: [PlexMetadata] = []
    @State private var related: [PlexHub] = []
    /// Trailers, featurettes, deleted scenes… (movies, shows and seasons).
    @State private var extras: [PlexMetadata] = []
    private var trailer: PlexMetadata? { extras.first { $0.subtype == "trailer" } }
    @State private var error: String?
    @State private var photoIndex: PhotoSelection?
    @State private var summaryExpanded = false
    @State private var addingToPlaylist = false
    @State private var tint: Color = Cinema.background
    /// Artist pages: most-played songs.
    @State private var popular: [PlexMetadata] = []
    @State private var shuffleOn = false
    @State private var tab: DetailTab?
    @State private var selection = BulkSelection()
    @ScaledMetric(relativeTo: .body) private var albumWidth = Cinema.gridPosterWidth

    struct PhotoSelection: Identifiable { let id: Int }

    enum DetailTab: String, Identifiable, CaseIterable {
        case episodes = "Episodes", seasons = "Seasons", extras = "Extras", cast = "Cast", related = "Related", details = "Details"
        var id: String { rawValue }
    }

    /// Tabs that have something to show for this item.
    private func tabs(for item: PlexMetadata) -> [DetailTab] {
        var t: [DetailTab] = []
        switch item.kind {
        case .episode: t.append(.episodes)
        case .season: t.append(.episodes)
        case .show: if !children.isEmpty { t.append(.seasons) }
        default: break
        }
        if !extras.isEmpty { t.append(.extras) }
        if !item.roles.isEmpty { t.append(.cast) }
        if related.contains(where: { !$0.metadata.isEmpty }) { t.append(.related) }
        if item.isPlayableVideo || item.kind == .show || item.kind == .season { t.append(.details) }
        return t
    }

    private var usesTabs: Bool {
        guard let item else { return false }
        return [.movie, .episode, .show, .season, .clip].contains(item.kind)
    }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 18) {
                    if isMusicPage(item) {
                        musicHeader(item)
                        DownloadStatusPill()
                        musicActions(item)
                    } else {
                        header(item)
                        DownloadStatusPill()
                    }
                    if sizeClass == .regular && usesTabs && !isMusicPage(item) {
                        // iPad: actions, track choices and summary beside the tabs, not one long column.
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 18) {
                                actions(item)
                                if item.isPlayableVideo { StreamPickers(item: item) { await load() } }
                                summaryText(item, lines: 8)
                            }
                            .frame(width: 440)
                            VStack(alignment: .leading, spacing: 18) { tabSection(item) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        if !isMusicPage(item) { actions(item) }
                        if item.isPlayableVideo { StreamPickers(item: item) { await load() } }
                        summaryText(item, lines: 3)
                        if usesTabs { tabSection(item) }
                    }
                    if !usesTabs {
                        if item.kind == .artist && !popular.isEmpty { popularSection }
                        childrenSection(item)
                        if !item.roles.isEmpty { castRow(item) }
                        ForEach(related) { hub in
                            if !hub.metadata.isEmpty { HubRow(title: hub.title, items: hub.metadata) }
                        }
                        // Music pages keep the description at the end, as "About".
                        if isMusicPage(item), let summary = item.summary, !summary.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("About").font(.title3.bold())
                                Text(summary).font(.callout).foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(summaryExpanded ? nil : 4)
                                    .onTapGesture { withAnimation { summaryExpanded.toggle() } }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                .padding(.bottom, 24)
            } else if let error {
                EmptyStateView(title: "Unavailable", systemImage: "exclamationmark.triangle", message: error)
                    .padding(.top, 80)
            } else {
                ProgressView().padding(.top, 120).frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(edges: .top)
        .background {
            // The page takes on the artwork's color, fading into the app's dark ground.
            if let item, isMusicPage(item) {
                // Solid behind the header (so an artist photo fades into it without a seam), then fading.
                VStack(spacing: 0) {
                    tint.frame(height: item.kind == .artist ? 380 : 260)
                    LinearGradient(colors: [tint, Cinema.background], startPoint: .top, endPoint: .bottom).frame(height: 420)
                    Cinema.background
                }
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: tint)
            } else {
                LinearGradient(colors: [tint, tint.opacity(0.55), Cinema.background], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: tint)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        // The big title in the header replaces the inline one; the title still labels the back button.
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            // Select lives in the album's ⋯ menu; the bar only shows it while selecting.
            if item?.kind == .album, selection.isActive {
                BulkSelectButton(selection: $selection, allIDs: children.map(\.ratingKey))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isActive {
                BulkActionBar(items: selection.ids.compactMap { id in children.first { $0.ratingKey == id } }) { selection.end() }
            }
        }
        .task(id: item?.ratingKey) { await loadTint() }
        .navigationTitle(item?.kind == .episode ? (item?.grandparentTitle ?? fallbackTitle) : (item?.title ?? fallbackTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.contentVersion) { await load() }
        .refreshable { await load() }
        .sheet(item: $photoIndex) { sel in PhotoViewer(photos: children.filter { $0.kind == .photo }, start: sel.id) }
        .sheet(isPresented: $addingToPlaylist) { if let item { AddToPlaylistView(item: item) } }
    }

    // MARK: Loading

    private func loadTint() async {
        guard let item else { return }
        let path = item.posterThumb ?? item.thumb ?? item.backdrop
        guard let url = app.imageURL(path, width: 120, height: 180),
              let color = await ImageLoader.shared.averageColor(for: url) else { return }
        tint = isMusicPage(item) ? Cinema.musicTint(from: color, brightness: 0.42) : Cinema.tint(from: color)
    }

    private func load() async {
        let sid = app.selectedServerID ?? ""
        // Offline, this is answered from the library cache when the page was seen before.
        guard let api = app.browseAPI else {
            loadOffline(serverID: sid)
            return
        }
        do {
            guard let fresh = try await api.metadata(ratingKey) else { throw PlexError.http(404, nil) }
            try Task.checkCancellation()
            guard sid == app.selectedServerID, api.token == app.browseAPI?.token else { return }
            item = fresh
            downloads.updateMetadata(fresh, serverID: sid)
            // The rest of the page loads in parallel.
            let key = ratingKey
            async let kids = Self.children(of: fresh, api: api)
            async let mostPlayed: [PlexMetadata] = fresh.kind == .artist ? Self.popularSongs(artist: fresh, api: api) : []
            async let relatedHubs: [PlexHub] = fresh.kind == .movie || fresh.kind == .show ? api.related(key) : []
            async let extraVideos: [PlexMetadata] = [.movie, .show, .season].contains(fresh.kind) ? api.extras(key) : []
            let (loadedKids, loadedPopular, loadedRelated, loadedExtras) = await (kids, mostPlayed, relatedHubs, extraVideos)
            try Task.checkCancellation()
            children = loadedKids.filter { mediaMode.includes($0) }
            if fresh.kind == .artist { popular = loadedPopular }
            if fresh.kind == .movie || fresh.kind == .show { related = Array(mediaMode.filter(loadedRelated).prefix(2)) }
            extras = loadedExtras
            error = nil
        } catch {
            loadOffline(serverID: sid)
            if item == nil { self.error = error.localizedDescription }
        }
    }

    private static func children(of item: PlexMetadata, api: PlexServerAPI) async -> [PlexMetadata] {
        switch item.kind {
        case .show, .season, .artist, .album, .photoAlbum, .collection:
            let path = item.kind == .collection ? "/library/collections/\(item.ratingKey)/children" : "/library/metadata/\(item.ratingKey)/children"
            return (try? await api.container(path).metadata) ?? []
        default:
            return []
        }
    }

    /// The artist's five most played songs, asked of the server rather than sorting every song.
    /// Falls back to the full list on servers that don't filter by artist.
    private static func popularSongs(artist: PlexMetadata, api: PlexServerAPI) async -> [PlexMetadata] {
        if let section = artist.librarySectionID,
           let top = try? await api.page("/library/sections/\(section)/all", start: 0, size: 5, query: [
               URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "artist.id", value: artist.ratingKey),
               URLQueryItem(name: "sort", value: "viewCount:desc"),
           ]).metadata, !top.isEmpty,
           top.allSatisfy({ $0.grandparentRatingKey == nil || $0.grandparentRatingKey == artist.ratingKey }) {
            return top
        }
        // Most-played first; ties keep album order.
        let songs = (try? await api.allLeaves(artist.ratingKey)) ?? []
        return Array(songs.enumerated().sorted { a, b in
            (a.element.viewCount ?? 0, -a.offset) > (b.element.viewCount ?? 0, -b.offset)
        }.map(\.element).prefix(5))
    }

    private func loadOffline(serverID: String) {
        if let rec = downloads.record(serverID: serverID, ratingKey: ratingKey) {
            item = rec.metadata
            return
        }
        // Containers: assemble from downloaded children.
        let kids = downloads.records.filter {
            $0.metadata.parentRatingKey == ratingKey || $0.metadata.grandparentRatingKey == ratingKey
        }.map(\.metadata)
        if !kids.isEmpty {
            children = kids.sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
        } else if item == nil {
            error = "You're offline and this item isn't downloaded."
        }
    }

    // MARK: Music pages (albums and artists)

    private func isMusicPage(_ item: PlexMetadata) -> Bool { item.kind == .album || item.kind == .artist }

    /// Albums: centered cover, title, artist, "Album · year". Artists: full-width photo with the name on it.
    @ViewBuilder private func musicHeader(_ item: PlexMetadata) -> some View {
        let rec = downloads.record(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey)
        if item.kind == .artist {
            ZStack(alignment: .bottomLeading) {
                PlexImage(path: item.backdrop ?? item.thumb, width: 1280, height: 900, placeholderIcon: "music.mic", background: .clear)
                    .frame(height: 380)
                    .frame(maxWidth: .infinity)
                    .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: tint, location: 1)],
                                            startPoint: .top, endPoint: .bottom))
                Text(item.title)
                    .font(.system(size: 44, weight: .heavy))
                    .lineLimit(2).minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 10)
                    .padding(.horizontal)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PlexImage(path: item.posterThumb, width: 600, height: 600, localFile: rec.map { DownloadStore.posterURL(id: $0.id) },
                          placeholderIcon: "square.stack")
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 112)
                    .padding(.bottom, 6)
                Text(item.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(3)
                if let artist = item.parentTitle {
                    let link = HStack(spacing: 8) {
                        PlexImage(path: item.parentThumb, width: 60, height: 60, placeholderIcon: "music.mic")
                            .frame(width: 24, height: 24).clipShape(Circle())
                        Text(artist).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    if let key = item.parentRatingKey {
                        NavigationLink(value: Route.item(ratingKey: key, title: artist)) { link }.buttonStyle(.plain)
                    } else { link }
                }
                Text(albumLine(item)).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }

    /// "Album · 2019 · 12 songs, 45 min"
    private func albumLine(_ item: PlexMetadata) -> String {
        var parts = ["Album"]
        if let y = item.year { parts.append(String(y)) }
        let songs = children.filter { $0.kind == .track }
        if !songs.isEmpty {
            let minutes = songs.reduce(0) { $0 + ($1.duration ?? 0) } / 60_000
            parts.append("\(songs.count) song\(songs.count == 1 ? "" : "s"), " + (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"))
        }
        return parts.joined(separator: " · ")
    }

    private func isPlayingHere(_ item: PlexMetadata) -> Bool {
        guard let track = audio.current?.track else { return false }
        return item.kind == .album ? track.parentRatingKey == item.ratingKey : track.grandparentRatingKey == item.ratingKey
    }

    private func musicActions(_ item: PlexMetadata) -> some View {
        MusicActionRow(shuffleOn: $shuffleOn, isPlaying: audio.isPlaying && isPlayingHere(item), playOrPause: {
            if audio.isPlaying && isPlayingHere(item) { audio.pause() }
            else if !audio.isPlaying && isPlayingHere(item) && !shuffleOn { audio.resume() }
            else { Task { await playMusic(item, shuffle: shuffleOn) } }
        }) {
            DownloadButton(item: item, compact: true)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
            Menu {
                if item.kind == .album, children.contains(where: { $0.kind == .track }) {
                    Button { selection.isActive = true } label: { Label("Select Songs", systemImage: "checkmark.circle") }
                }
                ItemContextMenu(item: item, includeDownload: false)
            } label: { MusicRowIcon(systemName: "ellipsis") }
                .accessibilityLabel("More actions")
        }
        .padding(.horizontal)
    }

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Popular").font(.title3.bold()).padding(.horizontal).padding(.bottom, 4)
            ForEach(Array(popular.enumerated()), id: \.element.id) { idx, track in
                HStack(spacing: 10) {
                    Text("\(idx + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                    TrackRow(item: track, number: nil, playlistStyle: true) {
                        if let ak = track.parentRatingKey {
                            ManualPlays.record(albumKey: ak, title: track.parentTitle ?? track.title, art: track.parentThumb ?? track.thumb, song: track.title, serverID: app.selectedServerID ?? "")
                        }
                        audio.play(popular, serverID: app.selectedServerID ?? "", startAt: idx)
                    }
                }
                .padding(.leading)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Header

    /// Episodes / Seasons / Cast / Related / Details tabs for video pages.
    @ViewBuilder private func tabSection(_ item: PlexMetadata) -> some View {
        let available = tabs(for: item)
        if !available.isEmpty {
            let current = tab.flatMap { available.contains($0) ? $0 : nil } ?? available[0]
            CinemaTabs(tabs: available, selection: Binding(get: { current }, set: { tab = $0 }),
                       label: \.rawValue, underline: .white)
            Group {
                switch current {
                case .episodes, .seasons: childrenSection(item)
                case .extras: extrasGrid
                case .cast: castGrid(item)
                case .related:
                    ForEach(related) { hub in
                        if !hub.metadata.isEmpty { HubRow(title: hub.title, items: hub.metadata) }
                    }
                case .details: DetailsPanel(item: item)
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private func summaryText(_ item: PlexMetadata, lines: Int) -> some View {
        if let summary = item.summary, !summary.isEmpty, !isMusicPage(item) {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(summaryExpanded ? nil : lines)
                .onTapGesture { withAnimation { summaryExpanded.toggle() } }
                .padding(.horizontal)
        }
    }

    @ViewBuilder private func header(_ item: PlexMetadata) -> some View {
        let rec = downloads.record(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey)
        let squareArt = [.album, .artist, .track, .playlist].contains(item.kind)
        ZStack(alignment: .bottomLeading) {
            PlexImage(path: item.kind == .episode ? (item.thumb ?? item.backdrop) : (item.backdrop ?? item.thumb), width: 1280, height: 900,
                      localFile: rec.map { DownloadStore.artURL(id: $0.id) }, placeholderIcon: "photo", background: .clear)
                .frame(height: 420)
                .frame(maxWidth: .infinity)
                .overlay(LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: tint, location: 1)],
                                        startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 14) {
                if squareArt || sizeClass == .regular {
                    PlexImage(path: item.posterThumb, width: 300, height: 300, localFile: rec.map { DownloadStore.posterURL(id: $0.id) })
                        .frame(width: sizeClass == .regular ? 200 : 110, height: sizeClass == .regular ? (squareArt ? 200 : 280) : 110)
                        .clipShape(RoundedRectangle(cornerRadius: item.kind == .artist ? 55 : 10))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .episode, let show = item.grandparentTitle {
                        showLink(show, ratingKey: item.grandparentRatingKey)
                    } else if item.kind == .season, let show = item.parentTitle {
                        showLink(show, ratingKey: item.parentRatingKey)
                    }
                    Text(item.title)
                        .font(.largeTitle.bold())
                        .textCase(squareArt ? nil : .uppercase)
                        .lineLimit(3).minimumScaleFactor(0.6)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 8)
                    if let sub = metaLine(item) {
                        Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                    QualityChips(item: item).id(MediaVersionChoice.shared.revision)
                    let scores = item.externalScores
                    if !scores.isEmpty { ExternalScoresRow(scores: scores) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder private func showLink(_ title: String, ratingKey: String?) -> some View {
        if let ratingKey {
            NavigationLink(value: Route.item(ratingKey: ratingKey, title: title)) {
                HStack(spacing: 3) {
                    Text(title)
                    Image(systemName: "chevron.right").font(.caption2.bold())
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        } else {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private func metaLine(_ item: PlexMetadata) -> String? {
        var parts: [String] = []
        if item.kind == .episode {
            if let s = item.parentIndex, let e = item.index { parts.append("S\(s) · E\(e)") }
            if let d = item.originallyAvailableAt { parts.append(d) }
        } else if item.kind == .season {
            if let n = item.leafCount { parts.append("\(n) episodes") }
        } else if let y = item.year { parts.append(String(y)) }
        if let g = item.genres.first?.tag, item.kind != .episode { parts.append(g) }
        if let d = Fmt.duration(ms: item.duration) { parts.append(d) }
        if item.kind == .show, let c = item.childCount { parts.append("\(c) season\(c == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ item: PlexMetadata) -> some View {
        HStack(spacing: 10) {
            if item.isPlayableVideo {
                Button {
                    app.play(item)
                } label: {
                    Label(item.progress.map { _ in "Resume" + (Fmt.remaining(ms: item.duration, offset: item.viewOffset).map { " · \($0)" } ?? "") } ?? "Play",
                          systemImage: "play.fill")
                }
                .buttonStyle(CinemaPlayButtonStyle())
                if item.progress != nil {
                    Button { app.play(item, fromStart: true) } label: { Image(systemName: "gobackward").glassCircle() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play from Beginning")
                        .help("Play from Beginning")
                }
            } else if item.kind == .show || item.kind == .season {
                Button { Task { await playNextEpisode(item) } } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(CinemaPlayButtonStyle())
            } else if item.kind == .album || item.kind == .artist {
                Button { Task { await playMusic(item, shuffle: false) } } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(CinemaPlayButtonStyle())
                Button { Task { await playMusic(item, shuffle: true) } } label: { Image(systemName: "shuffle").glassCircle() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle")
            } else if item.kind == .track {
                Button { audio.play([item], serverID: app.selectedServerID ?? "") } label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(CinemaPlayButtonStyle())
            }

            if let trailer {
                Button { app.play(trailer, fromStart: true) } label: { Image(systemName: "film").glassCircle() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play Trailer")
                    .help("Play Trailer")
            }
            if item.kind != .photo, item.kind != .photoAlbum, item.kind != .collection, item.kind != .playlist {
                // Same size and baseline as the More button; VoiceOver reads "Download".
                DownloadButton(item: item, compact: true).glassCircle()
            }
            Menu {
                if item.kind == .track || item.isPlayableVideo {
                    Button("Add to Playlist…") { addingToPlaylist = true }
                }
                ItemContextMenu(item: item, includeDownload: false)
            } label: { Image(systemName: "ellipsis").glassCircle() }
            .accessibilityLabel("More actions")

        }
        .padding(.horizontal)

        if item.kind == .show || item.kind == .season {
            SmartDownloadControl(item: item).padding(.horizontal)
        }

        if item.isPlayableVideo, item.media.count > 1 {
            VersionPicker(item: item).padding(.horizontal)
        }

        if [.movie, .show, .season, .episode, .artist, .album, .track].contains(item.kind) {
            UserRatingControl(item: item).padding(.horizontal)
        }

        if MediaVersionChoice.shared.revision >= 0, item.isPlayableVideo, let media = item.primaryMedia,
           downloads.state(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey) == nil,
           let note = PlaybackDecider.conversionReason(media: media, kind: item.kind, quality: .original)
               .map({ app.browseAPI?.isJellyfin == true
                   ? "\($0). It streams converted by your server; downloads need the built-in player."
                   : "\($0). Downloads are converted to MP4 by your server automatically." })
               ?? PlaybackDecider.builtInPlayerNote(media: media, kind: item.kind) {
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                .padding(.horizontal)
        }

        if let rec = downloads.record(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey), rec.state != .completed {
            DownloadRow(record: rec).padding(.horizontal)
        }
    }

    private func playNextEpisode(_ item: PlexMetadata) async {
        var leaves: [PlexMetadata] = []
        if let api = app.api, app.isOnline { leaves = (try? await api.allLeaves(item.ratingKey)) ?? [] }
        if leaves.isEmpty { leaves = children.filter { $0.kind == .episode } }
        let next = leaves.first { $0.viewOffset != nil } ?? leaves.first { ($0.viewCount ?? 0) == 0 } ?? leaves.first
        if let next { app.play(next) }
    }

    private func playMusic(_ item: PlexMetadata, shuffle: Bool) async {
        var tracks: [PlexMetadata] = item.kind == .album ? children : []
        if tracks.isEmpty, let api = app.api { tracks = (try? await api.allLeaves(item.ratingKey)) ?? [] }
        if item.kind == .album {
            ManualPlays.record(albumKey: item.ratingKey, title: item.title, art: item.thumb, serverID: app.selectedServerID ?? "")
        }
        audio.play(tracks, serverID: app.selectedServerID ?? "", shuffle: shuffle)
    }

    // MARK: Children

    @ViewBuilder private func childrenSection(_ item: PlexMetadata) -> some View {
        switch item.kind {
        case .episode:
            SeasonBrowser(episode: item)
        case .show:
            if !children.isEmpty {
                HubRow(title: "Seasons", items: children)
            }
        case .season:
            VStack(alignment: .leading, spacing: 0) {
                Text("Episodes").font(.title3.bold()).padding(.horizontal).padding(.bottom, 8)
                ForEach(children) { ep in
                    NavigationLink(value: ep.route) { EpisodeRowContent(item: ep) }
                        .buttonStyle(.plain)
                        .contextMenu { ItemContextMenu(item: ep) }
                    Divider().padding(.leading)
                }
            }
        case .artist:
            if !children.isEmpty {
                VStack(alignment: .leading) {
                    Text("Albums").font(.title3.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: albumWidth), spacing: 12)], spacing: 16) {
                        ForEach(children) { album in
                            NavigationLink(value: album.route) { PosterCard(item: album, width: albumWidth) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        case .album:
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.element.id) { idx, track in
                    SelectableRow(id: track.ratingKey, selection: $selection) {
                        TrackRow(item: track, number: nil, playlistStyle: true, showsArtwork: false) {
                            ManualPlays.record(albumKey: item.ratingKey, title: item.title, art: item.thumb, serverID: app.selectedServerID ?? "")
                            audio.play(children, serverID: app.selectedServerID ?? "", startAt: idx)
                        }
                    }
                    .padding(.leading)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                }
            }
        case .photoAlbum, .collection:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: item.kind == .photoAlbum ? 100 : 108), spacing: 8)], spacing: 12) {
                ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                    if child.kind == .photo {
                        Button {
                            photoIndex = PhotoSelection(id: children.filter { $0.kind == .photo }.firstIndex(of: child) ?? 0)
                        } label: {
                            PlexImage(path: child.thumb, width: 300, height: 300, placeholderIcon: "photo")
                                .frame(minWidth: 100, minHeight: 100).aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    } else {
                        NavigationLink(value: child.route) { PosterCard(item: child, width: 108) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
        default:
            EmptyView()
        }
    }

    private var extrasGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 18) {
            ForEach(extras) { extra in
                Button { app.play(extra, fromStart: true) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        PlexImage(path: extra.thumb, width: 480, height: 270, placeholderIcon: "film")
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottomTrailing) {
                                if let d = Fmt.duration(ms: extra.duration) {
                                    Text(d).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.black.opacity(0.6), in: Capsule()).padding(6)
                                }
                            }
                        Text(extra.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(PlexMetadata.extraKind(extra.subtype)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func castGrid(_ item: PlexMetadata) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 16) {
            ForEach(item.roles.prefix(30), id: \.self) { role in
                PersonLink(person: role) {
                    VStack(spacing: 4) {
                        PlexImage(path: role.thumb, width: 180, height: 180, placeholderIcon: "person.fill")
                            .frame(width: 78, height: 78)
                            .clipShape(Circle())
                        Text(role.tag).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(role.role ?? "").font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func castRow(_ item: PlexMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cast").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(item.roles.prefix(20), id: \.self) { role in
                        PersonLink(person: role) {
                            VStack(spacing: 4) {
                                PlexImage(path: role.thumb, width: 160, height: 160, placeholderIcon: "person.fill")
                                    .frame(width: 72, height: 72)
                                    .clipShape(Circle())
                                Text(role.tag).font(.caption2.weight(.medium)).lineLimit(1)
                                Text(role.role ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 84)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Rows

struct EpisodeRowContent: View {
    let item: PlexMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlexImage(path: item.thumb, width: 320, height: 180, placeholderIcon: "tv")
                .frame(width: 140, height: 79)
                .overlay(alignment: .bottom) { if let p = item.progress { ProgressOverlay(progress: p) } }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.index.map { "\($0). " } ?? "").foregroundStyle(.secondary) + Text(item.title)
                    Spacer(minLength: 4)
                    if item.isWatched { Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                Text([Fmt.duration(ms: item.duration), item.originallyAvailableAt].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let s = item.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            DownloadButton(item: item, compact: true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .offlineAvailability(item)
    }
}

struct TrackRow: View {
    @Environment(AudioPlayer.self) private var audio
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var addingToPlaylist = false
    let item: PlexMetadata
    let number: Int?
    var removeFromPlaylist: (() -> Void)? = nil
    var removalInProgress = false
    /// Playlist pages: larger artwork, artist line with a downloaded badge, and a ⋯ button.
    var playlistStyle = false
    /// Album pages leave the artwork out: every song shares the cover above.
    var showsArtwork = true
    let play: () -> Void

    var body: some View {
        Group {
            if playlistStyle { playlistRow } else { standardRow }
        }
        .padding(.vertical, playlistStyle ? 0 : 4)
        .offlineAvailability(item)
        // Actions: press and hold (full menu) or swipe (in lists).
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let removeFromPlaylist {
                Button(role: .destructive, action: removeFromPlaylist) { Label("Remove", systemImage: "minus.circle") }
            }
            Button { addingToPlaylist = true } label: { Label("Playlist", systemImage: "text.badge.plus") }.tint(Cinema.converting)
        }
        .swipeActions(edge: .leading) {
            Button { app.addToQueue(item, next: true) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .tint(Cinema.accent)
        }
        .contextMenu { menuItems }
        .sheet(isPresented: $addingToPlaylist) { AddToPlaylistView(item: item) }
    }

    private var isCurrent: Bool { audio.current?.track.ratingKey == item.ratingKey }

    @ViewBuilder private var menuItems: some View {
        Button("Add to Playlist…") { addingToPlaylist = true }
        ItemContextMenu(item: item)
        removalAction
    }

    private var playlistRow: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    if showsArtwork {
                        PlexImage(path: item.posterThumb, width: 120, height: 120, placeholderIcon: "music.note")
                            .frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(isCurrent ? Cinema.accent : .primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let rec = downloads.record(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey) {
                                DownloadStateIcon(record: rec, size: 13).allowsHitTesting(false)
                            }
                            Text(item.originalTitle ?? item.grandparentTitle ?? "")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .tint(.secondary)   // menus otherwise take the accent color
            .accessibilityLabel("More for \(item.title)")
        }
    }

    private var standardRow: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    if let number {
                        Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                    } else {
                        PlexImage(path: item.posterThumb, width: 100, height: 100, placeholderIcon: "music.note")
                            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrent ? Cinema.accent : .primary)
                            .lineLimit(1)
                        if number == nil || item.originalTitle != nil {
                            Text(item.originalTitle ?? item.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let rec = downloads.record(serverID: app.selectedServerID ?? "", ratingKey: item.ratingKey) {
                        // Status only; downloading and removing live in the ⋯ menu.
                        DownloadStateIcon(record: rec, size: 16).allowsHitTesting(false)
                    }
                    Text(Fmt.clock(seconds: Double(item.duration ?? 0) / 1000)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    @ViewBuilder private var removalAction: some View {
        if let removeFromPlaylist {
            Button(role: .destructive, action: removeFromPlaylist) {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }.disabled(removalInProgress)
        }
    }

}

// MARK: - Audio / subtitle selection

struct StreamPickers: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    let reload: () async -> Void

    var body: some View {
        if let part = item.primaryPart, app.isOnline, part.audioStreams.count > 1 || !part.subtitleStreams.isEmpty {
            HStack(spacing: 12) {
                if part.audioStreams.count > 1 {
                    Menu {
                        ForEach(part.audioStreams) { s in
                            Button {
                                MediaPreferences.shared.rememberAudio(languageCode: s.languageCode, scope: app.preferenceScope)
                                Task { try? await app.api?.selectStreams(partID: part.id, audioStreamID: s.id, subtitleStreamID: nil); await reload() }
                            } label: {
                                if s.id == part.selectedAudio?.id { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                            }
                        }
                    } label: {
                        Label(part.selectedAudio?.label ?? "Audio", systemImage: "speaker.wave.2").lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                if !part.subtitleStreams.isEmpty {
                    Menu {
                        Button {
                            MediaPreferences.shared.rememberSubtitle(languageCode: nil, scope: app.preferenceScope)
                            Task { try? await app.api?.selectStreams(partID: part.id, audioStreamID: nil, subtitleStreamID: 0); await reload() }
                        } label: {
                            if part.selectedSubtitle == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                        }
                        ForEach(part.subtitleStreams) { s in
                            Button {
                                MediaPreferences.shared.rememberSubtitle(languageCode: s.languageCode, scope: app.preferenceScope)
                                Task { try? await app.api?.selectStreams(partID: part.id, audioStreamID: nil, subtitleStreamID: s.id); await reload() }
                            } label: {
                                if s.id == part.selectedSubtitle?.id { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                            }
                        }
                    } label: {
                        Label(part.selectedSubtitle?.label ?? "Subtitles Off", systemImage: "captions.bubble").lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal)
        }
    }
}

// MARK: - Photos

struct PhotoViewer: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let photos: [PlexMetadata]
    @State var start: Int
    /// Slideshow, as on Apple TV: the next photo every few seconds, looping, until stopped.
    @State private var slideshow = false
    static let slideSeconds = 6

    var body: some View {
        NavigationStack {
            TabView(selection: $start) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { idx, photo in
                    PlexImage(path: photo.primaryPart?.key ?? photo.thumb, width: 2048, height: 2048, placeholderIcon: "photo", contentMode: .fit, background: .black)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .overlay(alignment: .bottom) {
                if photos.count > 1 {
                    Text("\(start + 1) of \(photos.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
            .pageTitle(photos.indices.contains(start) ? photos[start].title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if photos.count > 1 {
                        Button { slideshow.toggle() } label: {
                            Label(slideshow ? "Stop Slideshow" : "Slideshow", systemImage: slideshow ? "pause.fill" : "play.fill")
                        }
                        .keyboardShortcut(.space, modifiers: [])
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Arrow keys (Mac, iPad keyboards) move between photos.
            .background {
                Group {
                    Button("Previous Photo") { move(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Next Photo") { move(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                }
                .opacity(0).accessibilityHidden(true)
            }
            .task(id: slideshow) {
                while slideshow, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.slideSeconds))
                    guard slideshow, !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.8)) { start = (start + 1) % max(photos.count, 1) }
                }
            }
            .onChange(of: slideshow) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func move(_ delta: Int) {
        let next = start + delta
        guard photos.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { start = next }
    }
}

/// Under an episode: season picker plus that season's episodes, so you can
/// move around the show without backing out.
struct SeasonBrowser: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let episode: PlexMetadata

    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeason: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Episodes").font(.title3.bold())
                Spacer()
                if let show = episode.grandparentRatingKey {
                    NavigationLink(value: Route.item(ratingKey: show, title: episode.grandparentTitle ?? "Show")) {
                        Text("All Seasons").font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            if seasons.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons) { season in
                                let selected = season.ratingKey == selectedSeason
                                Button {
                                    selectedSeason = season.ratingKey
                                } label: {
                                    Text(season.title)
                                        .font(.subheadline.weight(selected ? .semibold : .regular))
                                        .padding(.horizontal, 14).padding(.vertical, 7)
                                        .background(selected ? Cinema.accent : Cinema.placeholder, in: Capsule())
                                        .foregroundStyle(selected ? Color.black : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .id(season.ratingKey)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .onAppear { if let s = selectedSeason { proxy.scrollTo(s, anchor: .center) } }
                }
            }

            if loading && episodes.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            LazyVStack(spacing: 0) {
                ForEach(episodes) { ep in
                    Group {
                    if ep.ratingKey == episode.ratingKey {
                        // The episode you're on: highlighted, not a link to itself –
                        // but its download button must still work.
                        EpisodeRowContent(item: ep)
                            .background(Cinema.accent.opacity(0.12))
                            .overlay(alignment: .leading) { Rectangle().fill(Cinema.accent).frame(width: 4) }
                            .overlay(alignment: .bottomTrailing) {
                                Text("Now Viewing").font(.caption2.bold()).foregroundStyle(Cinema.accent)
                                    .padding(.trailing).padding(.bottom, 6)
                                    .allowsHitTesting(false)
                            }
                    } else {
                        NavigationLink(value: ep.route) { EpisodeRowContent(item: ep) }
                            .buttonStyle(.plain)
                    }
                    }
                    .contextMenu { ItemContextMenu(item: ep) }
                    Divider().padding(.leading)
                }
            }
        }
        .task(id: "\(episode.ratingKey)-\(app.contentVersion)") { await loadSeasons() }
        .task(id: selectedSeason) { await loadEpisodes() }
    }

    private func loadSeasons() async {
        if selectedSeason == nil { selectedSeason = episode.parentRatingKey }
        guard let show = episode.grandparentRatingKey else { return }
        if let api = app.api, app.isOnline, let list = try? await api.children(show), !list.isEmpty {
            seasons = list.filter { $0.kind == .season }
        } else {
            // Offline: seasons that have downloaded episodes.
            var seen = Set<String>()
            seasons = offlineEpisodes.compactMap { ep -> PlexMetadata? in
                guard let key = ep.parentRatingKey, seen.insert(key).inserted else { return nil }
                var season = ep
                season.ratingKey = key
                season.type = "season"
                season.title = ep.parentIndex.map { "Season \($0)" } ?? (ep.parentTitle ?? "Season")
                season.index = ep.parentIndex
                return season
            }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        }
    }

    private func loadEpisodes() async {
        guard let season = selectedSeason else { return }
        loading = true
        defer { loading = false }
        if let api = app.api, app.isOnline, let list = try? await api.children(season), !list.isEmpty {
            episodes = list
        } else {
            episodes = offlineEpisodes.filter { $0.parentRatingKey == season }
        }
    }

    private var offlineEpisodes: [PlexMetadata] {
        downloads.records
            .filter { $0.state == .completed && $0.metadata.grandparentRatingKey == episode.grandparentRatingKey }
            .map(\.metadata)
            .sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
    }
}

/// Per-show "keep the next N episodes downloaded" control.
struct SmartDownloadControl: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    private var smart: SmartDownloads { .shared }

    private var showKey: String? { item.kind == .show ? item.ratingKey : item.parentRatingKey }
    private var showTitle: String { item.kind == .show ? item.title : (item.parentTitle ?? item.title) }
    private var rule: SmartDownloadRule? {
        guard let sid = app.selectedServerID, let showKey else { return nil }
        return smart.rule(serverID: sid, showRatingKey: showKey)
    }

    var body: some View {
        if let showKey, let sid = app.selectedServerID {
            Menu {
                Section("Keep downloaded") {
                    Button { if let r = rule { smart.remove(r.id) } } label: {
                        if rule == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                    }
                    ForEach(SmartDownloads.keepChoices, id: \.self) { n in
                        Button {
                            smart.set(SmartDownloadRule(serverID: sid, showRatingKey: showKey, showTitle: showTitle,
                                                        showThumb: item.kind == .show ? item.thumb : item.parentThumb,
                                                        keepCount: n, deleteWatched: rule?.deleteWatched ?? true,
                                                        includeSpecials: rule?.includeSpecials))
                        } label: {
                            let text = "Next \(n) unwatched episode\(n == 1 ? "" : "s")"
                            if rule?.keepCount == n { Label(text, systemImage: "checkmark") } else { Text(text) }
                        }
                    }
                }
                if var r = rule {
                    Section {
                        Button {
                            r.deleteWatched.toggle()
                            smart.set(r)
                        } label: {
                            if r.deleteWatched { Label("Delete After Watching", systemImage: "checkmark") } else { Text("Delete After Watching") }
                        }
                        Button {
                            r.includeSpecials = !r.includesSpecials
                            smart.set(r)
                        } label: {
                            if r.includesSpecials { Label("Include Specials", systemImage: "checkmark") } else { Text("Include Specials") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(rule == nil ? Color.secondary : Cinema.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Smart Download").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(rule.map { "Keeping next \($0.keepCount) unwatched\($0.includesSpecials ? " incl. specials" : "")\($0.deleteWatched ? " · deletes watched" : "")" }
                                ?? "Automatically keep upcoming episodes downloaded")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Cinema.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}

/// IMDb, Rotten Tomatoes and TMDB scores as small badges.
struct ExternalScoresRow: View {
    let scores: [ExternalScore]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(scores, id: \.self) { score in
                HStack(spacing: 4) {
                    badge(score)
                    Text(score.text).font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(score.site.rawValue) \(score.text)")
            }
        }
    }

    @ViewBuilder private func badge(_ score: ExternalScore) -> some View {
        switch score.site {
        case .imdb:
            Text("IMDb").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3))
        case .tomatoes:
            Image(systemName: score.positive ? "circle.fill" : "burst.fill").font(.caption2)
                .foregroundStyle(score.positive ? .red : .green)
        case .tomatoesAudience:
            Image(systemName: score.positive ? "popcorn.fill" : "popcorn").font(.caption2).foregroundStyle(.red)
        case .tmdb:
            Text("TMDB").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color(red: 0.0, green: 0.82, blue: 0.69), in: RoundedRectangle(cornerRadius: 3))
        case .tvdb:
            Text("TVDB").font(.system(size: 9, weight: .heavy)).padding(.horizontal, 3).padding(.vertical, 1)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
        case .community:
            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
        }
    }
}

/// Your own 1–5 star rating, saved on the server (Plex stores 0–10, two per star).
struct UserRatingControl: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    @State private var stars: Int?
    @State private var saving = false

    private var current: Int { stars ?? Int(((item.userRating ?? 0) / 2).rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            Text("Your Rating").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { n in
                    Button { Task { await rate(n == current ? 0 : n) } } label: {
                        Image(systemName: n <= current ? "star.fill" : "star")
                            .font(.body)
                            .foregroundStyle(n <= current ? Color.yellow : .white.opacity(0.5))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(n) star\(n == 1 ? "" : "s")")
                    .accessibilityAddTraits(n == current ? .isSelected : [])
                }
            }
            .disabled(saving || !app.isOnline)
            if saving { ProgressView().controlSize(.small) }
            Spacer()
        }
        .onChange(of: item.ratingKey) { stars = nil }
    }

    /// `n`: 1–5 stars, or 0 to clear.
    private func rate(_ n: Int) async {
        guard let api = app.api else { return }
        let before = stars
        stars = n
        saving = true
        defer { saving = false }
        do {
            try await api.rate(item.ratingKey, rating: n == 0 ? nil : Double(n * 2))
            Haptics.tap()
            app.libraryChanged()
        } catch {
            stars = before
            app.actionError = error.localizedDescription
        }
    }
}

/// Chooses which of a title's versions (4K, 1080p, an extended cut…) plays and downloads.
struct VersionPicker: View {
    let item: PlexMetadata
    private var choice: MediaVersionChoice { MediaVersionChoice.shared }

    var body: some View {
        let _ = choice.revision
        let current = item.primaryMediaIndex
        Menu {
            ForEach(Array(item.media.enumerated()), id: \.offset) { i, media in
                Button { choice.choose(media, of: item); Haptics.tap() } label: {
                    if i == current { Label(media.versionLabel(), systemImage: "checkmark") } else { Text(media.versionLabel()) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(current + 1) of \(item.media.count)").font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(item.primaryMedia?.versionLabel() ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        }
        .accessibilityLabel("Version: \(item.primaryMedia?.versionLabel() ?? "")")
    }
}

/// File and stream details (the "Details" tab).
struct DetailsPanel: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    private var jellyfin: Bool { app.browseAPI?.isJellyfin == true }

    private var rows: [(String, String)] {
        var out: [(String, String)] = []
        _ = MediaVersionChoice.shared.revision   // redraw for another version
        if !item.directors.isEmpty { out.append(("Director", item.directors.prefix(2).map(\.tag).joined(separator: ", "))) }
        if !item.genres.isEmpty { out.append(("Genres", item.genres.prefix(4).map(\.tag).joined(separator: ", "))) }
        if let s = item.studio { out.append(("Studio", s)) }
        if let date = item.originallyAvailableAt { out.append(("Released", date)) }
        if let media = item.primaryMedia, let part = media.parts.first {
            let video = part.streams.first { $0.streamType == 1 }
            var v = [media.videoCodec?.uppercased(), media.resolutionLabel].compactMap { $0 }
            if video?.doviPresent == true { v.append("Dolby Vision") } else if video?.colorTrc == "smpte2084" { v.append("HDR10") }
            if let br = media.bitrate { v.append(String(format: "%.1f Mbps", Double(br) / 1000)) }
            if !v.isEmpty { out.append(("Video", v.joined(separator: " · "))) }
            if let audio = part.selectedAudio ?? part.audioStreams.first {
                out.append(("Audio", audio.label))
            } else if let a = media.audioCodec {
                out.append(("Audio", a.uppercased()))
            }
            let subs = part.subtitleStreams.map { $0.language ?? $0.label }
            if !subs.isEmpty { out.append(("Subtitles", Array(NSOrderedSet(array: subs)).compactMap { $0 as? String }.prefix(6).joined(separator: ", "))) }
            var file = [(part.container ?? media.container)?.uppercased()].compactMap { $0 }
            if let size = part.size { file.append(Fmt.bytes(size)) }
            if !file.isEmpty { out.append(("File", file.joined(separator: " · "))) }
            let reason = PlaybackDecider.conversionReason(media: media, kind: item.kind, quality: .original)
            let builtIn = PlaybackDecider.builtInPlayerNote(media: media, kind: item.kind) != nil
            out.append(("Offline", reason.map { jellyfin ? "Needs the built-in player (\($0.replacingOccurrences(of: "iPhone can't play ", with: "")))"
                                              : "Converts to MP4 (\($0.replacingOccurrences(of: "iPhone can't play ", with: "")))" }
                        ?? (builtIn ? "Downloads as the original file; plays in the built-in player" : "Downloads as the original file")))
        }
        if item.kind == .show || item.kind == .season, let n = item.leafCount {
            out.append(("Episodes", "\(n) (\(item.viewedLeafCount ?? 0) watched)"))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 84, alignment: .leading)
                    Text(row.1).font(.subheadline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                if i < rows.count - 1 { Divider().overlay(.white.opacity(0.1)) }
            }
        }
        .padding(.horizontal)
    }
}


struct DownloadPreviewView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let item: PlexMetadata
    @State var quality: DownloadQuality
    @State private var unwatchedOnly = false
    @State private var allLeaves: [PlexMetadata]?
    private var leaves: [PlexMetadata]? { allLeaves?.filter { !unwatchedOnly || ($0.viewCount ?? 0) == 0 } }
    @State private var metadata: PlexMetadata?
    @State private var loading = false
    @State private var error: String?
    @State private var working = false
    private var source: PlexMetadata { metadata ?? item }

    var body: some View {
        NavigationStack {
            Form {
                Section(item.title) {
                    Picker("Quality", selection: $quality) {
                        ForEach(isJellyfin ? [DownloadQuality.original] : DownloadQuality.choices(for: source)) { Text($0.label).tag($0) }
                    }
                    if [.show, .season].contains(item.kind) {
                        Toggle("Unwatched Only", isOn: $unwatchedOnly)
                    }
                    if let leaves {
                        LabeledContent("Items", value: "\(leaves.count)")
                        LabeledContent("Total storage", value: DownloadPlan(items: leaves, quality: quality).sizeLabel)
                    } else { LabeledContent("File size", value: DownloadEstimate.sizeLabel(item: source, quality: quality)) }
                    if let available = DownloadStore.availableCapacity() { LabeledContent("Available on device", value: Fmt.bytes(available)) }
                    if !isMusic { LabeledContent("Subtitles", value: subtitleSummary) }
                    if isJellyfin {
                        Text("Jellyfin downloads keep the original file. Smaller converted downloads are available with Plex.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !isMusic { Text(quality.detail).font(.caption).foregroundStyle(.secondary) }
                    if !item.isLeaf {
                        Text(isMusic ? "Downloads every song." : unwatchedOnly ? "Downloads unwatched items in this group." : "Downloads all playable items in this group.")
                            .font(.caption)
                    }
                }
                if loading { ProgressView("Checking media details…") }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if !app.isOnline { Text("Connect to your server to start a new download.").foregroundStyle(.secondary) }
                Section {
                    Button {
                        Task {
                            working = true
                            if let leaves {
                                downloads.enqueue(leaves, serverID: app.selectedServerID ?? "", quality: quality, batchTitle: item.title)
                            } else { await DownloadActions.download(source, serverID: app.selectedServerID ?? "", api: app.api,
                                                           manager: downloads, quality: quality, unwatchedOnly: unwatchedOnly) }
                            working = false; dismiss()
                        }
                    } label: { Label("Download", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                    .disabled(!app.isOnline || loading || working || (!item.isLeaf && (leaves == nil || leaves?.isEmpty == true)))
                }
            }
            .pageTitle("Download Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                if isJellyfin { quality = .original }
                guard let api = app.api, app.isOnline else { return }
                loading = true
                defer { loading = false }
                do {
                    if item.isLeaf { metadata = try await api.metadata(item.ratingKey) }
                    else {
                        allLeaves = try await PlexServerAPI.allPlayableLeaves(item, api: api)
                    }
                    if !DownloadQuality.choices(for: source).contains(quality) { quality = .original }
                } catch { self.error = "Couldn't refresh media details. Available cached details are shown." }
            }
        }
    }

    private var isJellyfin: Bool { app.selectedServerID.map { ServerDirectory.shared.server(id: $0)?.isJellyfin == true } ?? false }
    private var isMusic: Bool { [.track, .album, .artist].contains(item.kind) }

    private var subtitleSummary: String {
        guard item.isLeaf else { return "Varies by episode" }
        guard let part = source.primaryPart else { return "Unknown" }
        let streams = part.subtitleStreams
        if streams.isEmpty { return "None listed by server" }
        let text = streams.filter { $0.isSidecarText }.count
        return "\(streams.count) listed · \(text) external text"
    }
}

enum DownloadEstimate {
    static func sizeLabel(item: PlexMetadata, quality: DownloadQuality) -> String {
        guard item.isLeaf else { return "Calculated for each item" }
        if let target = quality.transcodeTarget, let duration = item.duration, duration > 0 {
            let bytes = Int64(Double(target.bitrate) * Double(duration) / 8)
            return "About " + Fmt.bytes(bytes) + " (estimate)"
        }
        if let size = item.primaryPart?.size {
            let conversion = item.primaryMedia.map { PlaybackDecider.conversionReason(media: $0, kind: item.kind, quality: quality) != nil } ?? false
            return Fmt.bytes(size) + (conversion ? " source; converted size varies" : "")
        }
        return "Unknown until download starts"
    }
}
