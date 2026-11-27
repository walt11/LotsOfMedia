import SwiftUI

// MARK: - Navigation

enum Route: Hashable {
    case item(ratingKey: String, title: String)
    case section(PlexDirectory)
    case hub(key: String, title: String)
    case playlists
    case playlist(ratingKey: String, title: String)
    case offlineGroup(id: String, title: String)
    case offlinePlaylist(id: String)
    case downloadBatch(id: String, title: String)
    case history
    case favorites
    case watchLater
    case watchlist
    case mixes
    case mix(MusicMix)
    case storageCleanup
    case person(PlexTag)
}

struct RouteDestinations: ViewModifier {
    /// Shared by artwork (the zoom source) and the detail page it opens (the zoom destination).
    @Namespace private var zoom

    func body(content: Content) -> some View {
        content.environment(\.zoomNamespace, zoom).navigationDestination(for: Route.self) { route in
            Group {
            switch route {
            case .item(let key, let title): ItemDetailView(ratingKey: key, fallbackTitle: title).modifier(ZoomDestination(id: key, namespace: zoom))
            case .section(let dir): LibrarySectionView(section: dir)
            case .hub(let key, let title): HubGridView(key: key, title: title)
            case .playlists: PlaylistsView()
            case .playlist(let key, let title): PlaylistDetailView(ratingKey: key, title: title)
            case .offlineGroup(let id, let title): OfflineGroupView(groupID: id, groupTitle: title)
            case .offlinePlaylist(let id): OfflinePlaylistView(collectionID: id)
            case .downloadBatch(let id, let title): DownloadBatchView(batchID: id, title: title)
            case .favorites: FavoritesView()
            case .watchLater: WatchLaterView()
            case .watchlist: WatchlistView()
            case .mixes: MixesView()
            case .mix(let mix): MixView(mix: mix)
            case .storageCleanup: StorageCleanupView()
            case .history: WatchHistoryView()
            case .person(let person): PersonView(person: person)
            }
            }
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .miniPlayerClearance()
            .environment(\.isPushedPage, true)
            .environment(\.zoomNamespace, zoom)
        }
    }
}

// MARK: - Zoom transitions (iOS 18+)

private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// Artwork a detail page zooms out of (and back into). iOS 17 keeps the standard slide.
private struct ZoomSource: ViewModifier {
    @Environment(\.zoomNamespace) private var namespace
    let item: PlexMetadata
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, case .item(let key, _) = item.route {
            content.matchedTransitionSource(id: key, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: 8)) }
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.navigationTransition(.zoom(sourceID: id, in: namespace)) } else { content }
    }
}

extension View {
    /// Mark artwork as where its item's detail page zooms from.
    func zoomSource(_ item: PlexMetadata) -> some View { modifier(ZoomSource(item: item)) }
}

private struct PushedPageKey: EnvironmentKey { static let defaultValue = false }
private struct MiniPlayerInTabBarKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set on screens pushed onto a navigation stack; they get a small centered title.
    var isPushedPage: Bool {
        get { self[PushedPageKey.self] }
        set { self[PushedPageKey.self] = newValue }
    }
    /// The mini player lives in the system tab bar (iOS 26.1+), so pages don't reserve room for it.
    var miniPlayerInTabBar: Bool {
        get { self[MiniPlayerInTabBarKey.self] }
        set { self[MiniPlayerInTabBarKey.self] = newValue }
    }
}

private struct PageTitleModifier: ViewModifier {
    @Environment(\.isPushedPage) private var pushed
    let title: String
    func body(content: Content) -> some View {
        if pushed {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } else {
            content.navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar { PageTitleToolbar(title: title) }
        }
    }
}

extension View {
    func withRoutes() -> some View { modifier(RouteDestinations()) }

    /// A single navigation row holds the left-aligned title and page actions.
    /// Clear the native centered title so it cannot compete for toolbar space.
    /// Every screen's title and ground: the same title row, type and background
    /// on every page, so tabs and pushed screens line up and match.
    func pageTitle(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(Cinema.background)
            .toolbar(.visible, for: .navigationBar)
            .modifier(PageTitleModifier(title: title))
    }

    /// Pill directly under the navigation bar, for screens whose title lives
    /// in the bar (detail pages).
    func downloadStatusInset() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { DownloadStatusPill().padding(.top, 4) }
    }

    /// Sets the screen title. While downloads are active the order becomes:
    /// navigation buttons → download status → large title → content.
    func titleWithDownloadStatus(_ title: String) -> some View {
        modifier(DownloadStatusHeader(title: title))
    }
}

private struct PageTitleToolbar: ToolbarContent {
    let title: String
    private var label: some View {
        Text(title)
            .font(.title.bold())
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { label }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { label }
        }
    }
}

extension PlexMetadata {
    var route: Route {
        if kind == .playlist { return .playlist(ratingKey: ratingKey, title: title) }
        // A song opens its album (a page for one song has little on it).
        if kind == .track, let album = parentRatingKey { return .item(ratingKey: album, title: parentTitle ?? title) }
        return .item(ratingKey: ratingKey, title: title)
    }
}

// MARK: - Cards

/// Watch progress along the bottom of artwork: a light track inset from the edges, so even
/// a few percent reads as a progress bar on dark posters rather than a stray mark.
struct ProgressOverlay: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Cinema.accent).frame(width: max(4, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

struct WatchBadge: View {
    let item: PlexMetadata
    var body: some View {
        if let unwatched = item.unwatchedCount, unwatched > 0, item.kind == .show || item.kind == .season {
            Text("\(unwatched)")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Cinema.accent, in: Capsule())
                .foregroundStyle(.black)
                .padding(6)
        }
    }
}

struct DownloadedBadge: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: PlexMetadata
    var body: some View {
        if let sid = app.selectedServerID {
            if item.kind == .playlist, let c = downloads.collection(serverID: sid, ratingKey: item.ratingKey),
               !c.itemIDs.isEmpty, c.itemIDs.allSatisfy({ downloads.state(id: $0) == .completed }) {
                // Finished: decided from states alone, so the card doesn't redraw on every download save.
                badge
            } else if item.kind == .playlist, let c = downloads.collection(serverID: sid, ratingKey: item.ratingKey) {
                // Downloaded playlists: same badge as other downloads once complete, progress while downloading.
                let summary = GroupDownloadSummary(records: downloads.records(in: c), expected: c.itemIDs.count)
                if summary.isComplete {
                    badge
                } else {
                    GroupDownloadIcon(summary: summary, size: 18)
                        .padding(3)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(5)
                }
            } else if downloads.state(serverID: sid, ratingKey: item.ratingKey) == .completed {
                badge
            }
        }
    }

    private var badge: some View {
        Image(systemName: "arrow.down.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, Cinema.accent)
            .font(.body)
            .padding(5)
            .accessibilityLabel("Downloaded")
    }
}

struct PosterCard: View {
    let item: PlexMetadata
    var width: CGFloat = 120

    private var isSquare: Bool { [.artist, .album, .track, .photo, .photoAlbum, .playlist].contains(item.kind) }
    private var aspect: CGFloat { isSquare ? 1 : 1.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlexImage(path: item.kind == .episode ? item.thumb : item.posterThumb ?? item.thumb,
                      width: Int(width * 2.5), height: Int(width * aspect * 2.5),
                      placeholderIcon: placeholder)
                .frame(width: width, height: width * aspect)
                .overlay(alignment: .topTrailing) { WatchBadge(item: item) }
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .overlay(alignment: .bottom) {
                    if let p = item.progress { ProgressOverlay(progress: p) }
                }
                .clipShape(RoundedRectangle(cornerRadius: item.kind == .artist ? width / 2 : AppTheme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: item.kind == .artist ? width / 2 : AppTheme.cardRadius)
                    .strokeBorder(AppTheme.border, lineWidth: 0.5))
                .zoomSource(item)
            Text(item.kind == .episode ? item.title : item.displayTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            if let sub = item.kind == .episode ? item.subtitleLine.map({ _ in item.grandparentTitle ?? "" }) : item.subtitleLine {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .offlineAvailability(item)
    }

    private var placeholder: String {
        switch item.kind {
        case .artist, .album, .track: return "music.note"
        case .photo, .photoAlbum: return "photo"
        case .show, .season, .episode: return "tv"
        case .playlist: return "music.note.list"
        default: return "film"
        }
    }
}

/// Landscape card used for Continue Watching / episodes.
struct WideCard: View {
    let item: PlexMetadata
    var width: CGFloat = 250

    /// "S2 E4 · 18m left", "1h 12m left", or the year.
    private var caption: String {
        let left = Fmt.remaining(ms: item.duration, offset: item.viewOffset)
        if item.kind == .episode {
            let code = [item.parentIndex.map { "S\($0)" }, item.index.map { "E\($0)" }].compactMap { $0 }.joined(separator: " ")
            return [code.isEmpty ? nil : code, left ?? item.title].compactMap { $0 }.joined(separator: " · ")
        }
        return left ?? item.year.map(String.init) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlexImage(path: item.kind == .episode ? item.thumb : (item.art ?? item.thumb),
                      width: Int(width * 2), height: Int(width * 9 / 16 * 2), placeholderIcon: "play.rectangle")
                .frame(width: width, height: width * 9 / 16)
                .zoomSource(item)
                .overlay(alignment: .topLeading) { DownloadedBadge(item: item) }
                .overlay(alignment: .center) {
                    if item.progress != nil {
                        Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let p = item.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(Cinema.accent).frame(width: max(4, geo.size.width * p))
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 2)
            }
            Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(Cinema.muted).lineLimit(1)
        }
        .frame(width: width)
        .offlineAvailability(item)
    }
}

struct HubRow: View {
    let title: String
    let items: [PlexMetadata]
    var wide = false
    var moreRoute: Route?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let moreRoute {
                    NavigationLink(value: moreRoute) {
                        HStack(spacing: 4) {
                            Text(title).font(.title3.bold())
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title).font(.title3.bold())
                }
                Spacer()
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item.route) {
                            if wide { WideCard(item: item) } else { PosterCard(item: item) }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { ItemContextMenu(item: item) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct ItemContextMenu: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: PlexMetadata
    var includeDownload = true

    var body: some View {
        FavoriteAction(item: item)
        if item.isPlayableVideo || item.kind == .show || item.kind == .season {
            WatchLaterAction(item: item)
            WatchlistAction(item: item)
        }
        if item.isPlayableVideo {
            Button { app.play(item) } label: { Label(item.progress != nil ? "Resume" : "Play", systemImage: "play.fill") }
            if item.progress != nil {
                Button { app.play(item, fromStart: true) } label: { Label("Play from Beginning", systemImage: "gobackward") }
            }
        }
        if item.isPlayableVideo || item.kind == .track {
            Button { app.addToQueue(item, next: true) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { app.addToQueue(item, next: false) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        }
        if item.kind == .track, app.isOnline {
            Button { Task { await app.startRadio(from: item) } } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
        }
        if item.isLeaf || [.show, .season, .album, .artist].contains(item.kind) {
            Button {
                Task { await app.markWatched(item, watched: !item.isWatched) }
            } label: {
                let music = [.track, .album, .artist].contains(item.kind)
                Label(item.isWatched ? (music ? "Mark as Unplayed" : "Mark as Unwatched") : (music ? "Mark as Played" : "Mark as Watched"),
                      systemImage: item.isWatched ? "eye.slash" : "eye")
            }
        }
        if includeDownload, item.isLeaf, let sid = app.selectedServerID, let rec = downloads.record(serverID: sid, ratingKey: item.ratingKey) {
            Button(role: .destructive) { downloads.delete(rec.id) } label: {
                Label(rec.state == .completed ? "Remove Download" : "Cancel Download", systemImage: rec.state == .completed ? "trash" : "xmark")
            }
        } else if includeDownload, let sid = app.selectedServerID, item.kind != .photo, item.kind != .photoAlbum, item.kind != .playlist {
            Button {
                if item.isLeaf { Task { await DownloadActions.download(item, serverID: sid, api: app.api, manager: downloads, quality: nil) } }
                else { app.downloadPreview = item }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

// MARK: - Download actions

@MainActor
enum DownloadActions {
    /// Downloads a leaf item, or every playable leaf under a show/season/album/artist.
    static func download(_ item: PlexMetadata, serverID: String, api: PlexServerAPI?, manager: DownloadManager,
                         quality: DownloadQuality?, unwatchedOnly: Bool = false) async {
        if item.isLeaf {
            manager.enqueue([item], serverID: serverID, quality: quality)
            return
        }
        guard let api else { manager.actionError = "Connect to a server to download this group."; return }
        do {
            var leaves = try await api.allLeaves(item.ratingKey)
            if unwatchedOnly { leaves = leaves.filter { ($0.viewCount ?? 0) == 0 } }
            let title = item.kind == .season ? "\(item.parentTitle ?? "") \(item.title)".trimmingCharacters(in: .whitespaces) : item.title
            manager.enqueue(leaves, serverID: serverID, quality: quality, batchTitle: title)
        } catch { manager.actionError = error.localizedDescription }
    }
}

struct DownloadButton: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: PlexMetadata
    var compact = false
    /// Styled to sit in a row of bordered action buttons (detail pages).
    var bordered = false
    @State private var previewQuality: DownloadQuality?

    var body: some View {
        Group {
        if !item.isLeaf, let sid = app.selectedServerID,
           !downloads.records(under: item, serverID: sid).isEmpty {
            // Season / show / album / artist with downloads: whole-group status + removal.
            GroupDownloadButton(item: item, serverID: sid, bordered: bordered, iconSize: iconSize)
        } else if bordered {
            content.buttonStyle(.bordered).accessibilityLabel("Download")
        } else {
            content
        }
        }
        .sheet(item: $previewQuality) { quality in
            DownloadPreviewView(item: item, quality: quality)
        }
    }

    private var iconSize: CGFloat { bordered ? 22 : (compact ? 22 : 26) }

    @ViewBuilder private var content: some View {
        if let sid = app.selectedServerID {
            // `state` is cheap to observe; only rows that actually have a download
            // read the full record (and re-render as its progress changes).
            if item.isLeaf, downloads.state(serverID: sid, ratingKey: item.ratingKey) != nil,
               let rec = downloads.record(serverID: sid, ratingKey: item.ratingKey) {
                Menu {
                    switch rec.state {
                    case .completed:
                        Button(role: .destructive) { downloads.delete(rec.id) } label: { Label("Remove Download", systemImage: "trash") }
                    case .paused, .failed:
                        Button { downloads.resume(rec.id) } label: { Label("Resume Download", systemImage: "arrow.clockwise") }
                        Button(role: .destructive) { downloads.delete(rec.id) } label: { Label("Cancel Download", systemImage: "xmark") }
                    default:
                        Button { downloads.pause(rec.id) } label: { Label("Pause Download", systemImage: "pause") }
                        Button(role: .destructive) { downloads.delete(rec.id) } label: { Label("Cancel Download", systemImage: "xmark") }
                    }
                } label: {
                    DownloadStateIcon(record: rec, size: iconSize)
                }
            } else {
                // Quality (and Unwatched Only for shows) are chosen in Download Options.
                Button { previewQuality = effectiveDefault } label: { downloadIcon }
            }
        }
    }

    private var downloadIcon: some View {
        Image(systemName: "arrow.down.circle")
            .font(bordered ? .title2 : .system(size: iconSize))
    }

    /// The settings default, or Original when that default isn't offered for this item.
    private var effectiveDefault: DownloadQuality {
        DownloadQuality.choices(for: item).contains(downloads.defaultQuality) ? downloads.defaultQuality : .original
    }
}

struct DownloadStateIcon: View {
    @Environment(DownloadManager.self) private var downloads
    let record: DownloadRecord
    var size: CGFloat = 26

    var body: some View {
        switch record.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(Cinema.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: size)).foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle").font(.system(size: size)).foregroundStyle(.secondary)
        case .queued, .preparing, .assembling:
            ProgressRing(progress: record.state == .preparing ? (record.preparationProgress ?? 0) : downloads.progress(of: record), indeterminate: record.state != .preparing)
                .frame(width: size, height: size)
        case .downloading:
            ProgressRing(progress: downloads.progress(of: record), indeterminate: false)
                .frame(width: size, height: size)
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    var indeterminate = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: indeterminate ? 0.25 : max(0.02, progress))
                .stroke(Cinema.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(indeterminate && spin ? 270 : -90))
                .animation(indeterminate ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spin)
            Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(Cinema.accent)
        }
        .onAppear { spin = true }
    }
}

// MARK: - Status

struct OfflineBanner: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize

    private var failed: Bool { if case .failed = app.status { return true } else { return false } }

    var body: some View {
        if failed || app.status == .connecting {
            let count = downloads.records.filter { $0.state == .completed && mediaMode.includes($0.metadata) }.count
            let title = app.status == .connecting ? "Connecting…" : "Offline · \(count) download\(count == 1 ? "" : "s") ready"
            let detail = "Showing your saved library. Downloads play without a connection."
            Group {
                if typeSize.isAccessibilitySize {
                    // Stacked, so large text wraps by word instead of squeezing beside the buttons.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(title, systemImage: "wifi.slash").font(.subheadline.bold())
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack { retry; downloadsButton(labelled: true) }
                            VStack(alignment: .leading) { retry; downloadsButton(labelled: true) }
                        }
                    }
                } else if verticalSize == .compact {
                    // Landscape: one short line, to leave room for the page.
                    HStack(spacing: 10) {
                        Label(title, systemImage: "wifi.slash").font(.subheadline.bold()).lineLimit(1)
                        Spacer()
                        retry
                        downloadsButton(labelled: false)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.subheadline.bold()).lineLimit(1)
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        retry
                        downloadsButton(labelled: false)
                    }
                }
            }
            .padding(verticalSize == .compact ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    private var retry: some View {
        Button("Retry") { Task { await app.connect() } }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(app.status == .connecting)
    }

    private func downloadsButton(labelled: Bool) -> some View {
        Button { app.selectedTab = .downloads } label: {
            if labelled { Label("Downloads", systemImage: "arrow.down.circle.fill") } else { Image(systemName: "arrow.down.circle.fill") }
        }
        .prominentButton()
        .fixedSize()
        .accessibilityLabel("Go to Downloads")
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Cinema.accent)
                    .frame(width: 80, height: 80)
                    .background(Cinema.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            }
        } description: {
            if let message { Text(message).font(.subheadline).frame(maxWidth: 380) }
        }
    }
}

// MARK: - Mini player

private struct MiniPlayerInsetModifier: ViewModifier {
    @Environment(\.miniPlayerInTabBar) private var inTabBar
    func body(content: Content) -> some View {
        if inTabBar { content } else { content.safeAreaInset(edge: .bottom) { MiniPlayerBar() } }
    }
}

private struct MiniPlayerClearance: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(\.miniPlayerInTabBar) private var inTabBar
    @Environment(AudioPlayer.self) private var player
    var body: some View {
        if !inTabBar, mediaMode == .music, player.current != nil { Color.clear.frame(height: 72) }
    }
}

/// The mini player as the tab bar's accessory (iOS 26.1+): the system draws the
/// capsule, and it shrinks into the tab bar when you scroll down.
@available(iOS 26.0, *)
struct TabBarMiniPlayer: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var showFull = false

    var body: some View {
        if let entry = player.current {
            HStack(spacing: 10) {
                Group {
                    if let art = player.artwork { Image(uiImage: art).resizable().scaledToFill() }
                    else { Rectangle().fill(Cinema.placeholder).overlay(Image(systemName: "music.note").font(.caption)) }
                }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        if let device = AirPlayStatus.shared.deviceName {
                            Label(device, systemImage: "airplayaudio").font(.caption2.weight(.semibold))
                                .foregroundStyle(Cinema.accent).lineLimit(1)
                        } else {
                            Text(entry.track.grandparentTitle ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MiniPlayerAccessibility.label(entry.track))
                .accessibilityHint("Opens Now Playing")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showFull = true }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                // Next stays even when the tab bar shrinks the player to one line.
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .disabled(!player.hasNext)
                    .accessibilityLabel("Next")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tinted with the artwork's color, with a thin progress line along the bottom.
            .background((player.artworkTint ?? .clear).opacity(0.9))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: player.duration > 0 ? geo.size.width * min(player.currentTime / player.duration, 1) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 3)
            }
            .animation(.easeInOut(duration: 0.4), value: player.artworkTint)
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .miniPlayerSwipes(player) { showFull = true }
            .sheet(isPresented: $showFull) { NowPlayingView() }
        }
    }
}

struct MiniPlayerBar: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showFull = false

    var body: some View {
        if mediaMode == .music, let entry = player.current {
            HStack(spacing: 12) {
                Group {
                    if let art = player.artwork {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Cinema.placeholder).overlay(Image(systemName: "music.note"))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
                // At accessibility text sizes the title gets two lines instead of truncating early.
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.track.title).font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    if let device = AirPlayStatus.shared.deviceName {
                        Label(device, systemImage: "airplayaudio")
                            .font(.caption.weight(.semibold)).foregroundStyle(Cinema.accent).lineLimit(1)
                    } else {
                        Text(entry.track.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(MiniPlayerAccessibility.label(entry.track))
                .accessibilityHint("Opens Now Playing")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showFull = true }
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                    .disabled(!player.hasNext)
                    .accessibilityLabel("Next")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial)
                RoundedRectangle(cornerRadius: 14).fill((player.artworkTint ?? .clear).opacity(0.9))
            }
            .overlay {
                if AirPlayStatus.shared.isActive {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Cinema.accent, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: fraction.isFinite ? geo.size.width * min(max(fraction, 0), 1) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .miniPlayerSwipes(player) { showFull = true }
            .sheet(isPresented: $showFull) { NowPlayingView() }
        }
    }
}

/// What VoiceOver reads for the mini player: the song, its artist, and where it's playing.
enum MiniPlayerAccessibility {
    @MainActor static func label(_ track: PlexMetadata) -> String {
        var parts = ["Now Playing", track.title]
        if let artist = track.grandparentTitle ?? track.originalTitle { parts.append("by \(artist)") }
        if let device = AirPlayStatus.shared.deviceName { parts.append("on \(device)") }
        return parts.joined(separator: ", ")
    }
}

extension View {
    func miniPlayerInset() -> some View { modifier(MiniPlayerInsetModifier()) }

    /// Reserves the mini player's height inside a page. The inset added outside a
    /// NavigationStack doesn't reach its lists on iOS 26, so their last rows ended
    /// up behind the bar.
    func miniPlayerClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerClearance() }
    }
}

// MARK: - In-app download status

/// Share one navigation row for page titles and controls, with no second title header.
/// Download status gets a separate row without duplicating the page title.
struct DownloadStatusHeader: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .pageTitle(title)
            .toolbar(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                DownloadStatusPill()
            }
    }
}

/// Compact live status of active downloads; tap to open the Downloads tab.
struct DownloadStatusPill: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads

    private var active: [DownloadRecord] {
        downloads.records.filter { mediaMode.includes($0.metadata) && [.queued, .preparing, .downloading, .assembling].contains($0.state) }
    }

    var body: some View {
        let active = active
        // Hidden on the Downloads tab, where the list itself shows progress.
        if !active.isEmpty && app.tab(for: mediaMode) != .downloads {
            let converting = active.filter { $0.state == .preparing }
            let transferring = active.filter { $0.state == .downloading || $0.state == .assembling }
            let isConverting = transferring.isEmpty && !converting.isEmpty
            let current = transferring.first ?? converting.first ?? active[0]
            let color: Color = isConverting ? Cinema.converting : Cinema.accent
            let batch = singleBatch(active)
            let progress: Double = batch.map { GroupDownloadSummary(records: $0.members, expected: nil).progress(downloads) }
                ?? (isConverting
                    ? converting.map { $0.preparationProgress ?? 0 }.reduce(0, +) / Double(converting.count)
                    : overallProgress(transferring))

            Button { app.selectedTab = .downloads } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: isConverting ? "gearshape.2.fill" : "arrow.down.circle.fill")
                            .font(.title3)
                            .foregroundStyle(color)
                            .symbolEffect(.pulse, isActive: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isConverting ? "Converting for iPhone" : (current.state == .assembling ? "Finishing" : "Downloading"))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color)
                            Text(headline(current, active: active)).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                            Text(batchDetail(active) ?? detail(active: active.count, converting: converting.count, isConverting: isConverting))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: min(max(progress, 0), 1)).tint(color)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("Downloads in progress, \(Int(progress * 100)) percent. Opens Downloads.")
        }
    }

    private func overallProgress(_ recs: [DownloadRecord]) -> Double {
        let total = recs.compactMap(\.totalBytes).reduce(0, +)
        guard total > 0 else { return 0 }
        let done = recs.reduce(Int64(0)) { $0 + (downloads.liveBytes[$1.id] ?? $1.downloadedSegmentBytes) }
        return Double(done) / Double(total)
    }

    /// When everything in progress belongs to one group download, name the group.
    private func singleBatch(_ active: [DownloadRecord]) -> (title: String, members: [DownloadRecord])? {
        guard let batch = active.first?.batchID, active.allSatisfy({ $0.batchID == batch }),
              let title = active.first?.batchTitle else { return nil }
        return (title, downloads.records.filter { $0.batchID == batch && mediaMode.includes($0.metadata) })
    }

    private func headline(_ current: DownloadRecord, active: [DownloadRecord]) -> String {
        if let b = singleBatch(active) { return b.title }
        return title(current.metadata)
    }

    private func batchDetail(_ active: [DownloadRecord]) -> String? {
        guard let b = singleBatch(active) else { return nil }
        let done = b.members.filter { $0.state == .completed }.count
        return "\(done) of \(b.members.count)"
    }

    private func title(_ m: PlexMetadata) -> String {
        m.kind == .episode ? "\(m.grandparentTitle ?? "") · \(m.subtitleLine ?? m.title)" : m.title
    }

    private func detail(active: Int, converting: Int, isConverting: Bool) -> String {
        if active == 1 { return isConverting ? "on server" : "1 item" }
        if !isConverting && converting > 0 { return "\(active) items · \(converting) converting" }
        return "\(active) items"
    }
}

/// Brief banner when a download finishes or fails, shown on any tab.
struct DownloadEventBanner: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var shown: DownloadManager.Event?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let event = shown, event.isAudio == (mediaMode == .music) {
                Button {
                    app.selectedTab = .downloads
                    shown = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: event.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(event.succeeded ? Cinema.accent : Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.succeeded ? (event.isAudio ? "Ready to listen offline" : "Ready to watch offline")
                                                 : "Download needs attention")
                                .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Text(event.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let m = event.message { Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.spring(duration: 0.35), value: shown)
        .onChange(of: downloads.lastEvent) { _, event in
            guard let event, event.isAudio == (mediaMode == .music) else { return }
            shown = event
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(event.succeeded ? 3 : 6))
                if !Task.isCancelled { shown = nil }
            }
        }
    }
}

// MARK: - Group download status (season, show, album, artist, playlist)

struct GroupDownloadSummary {
    let records: [DownloadRecord]
    /// Items the group should contain (nil = unknown, use what's downloaded).
    let expected: Int?

    var completed: Int { records.filter { $0.state == .completed }.count }
    var failed: Int { records.filter { $0.state == .failed }.count }
    var active: Int { records.filter { [.queued, .preparing, .downloading, .assembling].contains($0.state) }.count }
    var total: Int { max(expected ?? 0, records.count) }
    var missing: Int { max(0, total - records.count) }
    var isComplete: Bool { total > 0 && completed == total }
    var bytes: Int64 { records.filter { $0.state == .completed }.reduce(0) { $0 + ($1.totalBytes ?? 0) } }

    @MainActor func progress(_ manager: DownloadManager) -> Double {
        guard total > 0 else { return 0 }
        return records.reduce(0.0) { $0 + manager.progress(of: $1) } / Double(total)
    }

    var statusText: String {
        if isComplete { return "Downloaded" }
        if active > 0 { return "Downloading \(completed) of \(total)" }
        if failed > 0 { return "\(failed) failed · \(completed) of \(total) downloaded" }
        return "\(completed) of \(total) downloaded"
    }
}

/// Icon reflecting a whole group: check when complete, ring while downloading.
struct GroupDownloadIcon: View {
    @Environment(DownloadManager.self) private var downloads
    let summary: GroupDownloadSummary
    var size: CGFloat = 26

    var body: some View {
        if summary.isComplete {
            Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(Cinema.accent)
        } else if summary.active > 0 {
            ProgressRing(progress: summary.progress(downloads)).frame(width: size, height: size)
        } else if summary.failed > 0 {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: size)).foregroundStyle(.red)
        } else {
            // Partially downloaded.
            Image(systemName: "arrow.down.circle.dotted").font(.system(size: size)).foregroundStyle(Cinema.accent)
        }
    }
}

struct GroupDownloadButton: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: PlexMetadata
    let serverID: String
    var bordered = false
    var iconSize: CGFloat = 26
    @State private var confirmRemove = false

    private var summary: GroupDownloadSummary {
        GroupDownloadSummary(records: downloads.records(under: item, serverID: serverID), expected: item.leafCount)
    }

    private var noun: String {
        switch item.kind {
        case .season: return "Season"
        case .show: return "Show"
        case .album: return "Album"
        default: return "Artist"
        }
    }

    var body: some View {
        let summary = summary
        Menu {
            Section(summary.statusText) {
                if summary.missing > 0 {
                    Button {
                        app.downloadPreview = item
                    } label: { Label("Download Remaining \(summary.missing)", systemImage: "arrow.down.circle") }
                }
                if summary.failed > 0 {
                    Button {
                        summary.records.filter { $0.state == .failed }.forEach { downloads.retry($0.id) }
                    } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                }
                if summary.active > 0 {
                    Button {
                        summary.records.filter { $0.state != .completed }.forEach { downloads.pause($0.id) }
                    } label: { Label("Pause", systemImage: "pause") }
                }
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label(summary.active > 0 ? "Cancel & Remove Downloads" : "Remove \(noun) Downloads", systemImage: "trash")
                }
            }
        } label: {
            GroupDownloadIcon(summary: summary, size: bordered ? 22 : iconSize)
        }
        .modifier(BorderedIf(bordered))
        .accessibilityLabel("\(noun) downloads: \(summary.statusText)")
        .confirmationDialog("Remove \(summary.records.count) downloaded item\(summary.records.count == 1 ? "" : "s") from \(item.title)?",
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) {
                downloads.deleteMany(summary.records.map(\.id))
                // Removing a whole show also stops Smart Download refilling it.
                if item.kind == .show, let rule = SmartDownloads.shared.rule(serverID: serverID, showRatingKey: item.ratingKey) {
                    SmartDownloads.shared.remove(rule.id)
                }
            }
        } message: {
            if item.kind == .season, let show = item.parentRatingKey,
               SmartDownloads.shared.rule(serverID: serverID, showRatingKey: show) != nil {
                Text("Smart Download is on for this show and will download upcoming episodes again.")
            }
        }
    }
}

struct BorderedIf: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.bordered) } else { content }
    }
}

// MARK: - Offline availability

extension DownloadManager {
    /// Whether this item (or, for a show/season/album/artist/playlist, part of it) can play offline.
    func isAvailableOffline(_ item: PlexMetadata, serverID: String) -> Bool {
        if item.isLeaf { return record(serverID: serverID, ratingKey: item.ratingKey)?.state == .completed }
        if item.kind == .playlist, let c = collection(serverID: serverID, ratingKey: item.ratingKey) {
            return records(in: c).contains { $0.state == .completed }
        }
        return records(under: item, serverID: serverID).contains { $0.state == .completed }
    }
}

/// While offline, items that aren't downloaded are dimmed and marked, so it's
/// clear at a glance what can actually be played.
private struct OfflineAvailability: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let item: PlexMetadata

    func body(content: Content) -> some View {
        let unavailable = !app.isOnline && app.status != .connecting && app.status != .idle
            && !downloads.isAvailableOffline(item, serverID: app.selectedServerID ?? "")
        content
            .opacity(unavailable ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if unavailable {
                    Image(systemName: "icloud.slash")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.7), in: Circle())
                        .padding(4)
                        .accessibilityLabel("Not downloaded")
                }
            }
    }
}

extension View {
    func offlineAvailability(_ item: PlexMetadata) -> some View { modifier(OfflineAvailability(item: item)) }
}


// MARK: - Home title (switches Listen / Watch)

extension View {
    /// Home's large title doubles as the Listen/Watch switch; the avatar sits beside it.
    func homeTitle(_ mode: MediaMode) -> some View {
        scrollContentBackground(.hidden)
            .background(Cinema.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { HomeTitleToolbar(mode: mode) }
    }
}

private struct HomeTitleToolbar: ToolbarContent {
    let mode: MediaMode
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { ModeTitleMenu(mode: mode) }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { UserSwitcherButton() }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { ModeTitleMenu(mode: mode) }
            ToolbarItem(placement: .topBarTrailing) { UserSwitcherButton() }
        }
    }
}

extension EnvironmentValues {
    /// iPad with the sidebar open: the sidebar's Listen/Watch picker is the only switch, so
    /// Home's title is just "Home".
    @Entry var modePickerInSidebar = false
}

struct ModeTitleMenu: View {
    @Environment(AppState.self) private var app
    @Environment(\.modePickerInSidebar) private var pickerInSidebar
    let mode: MediaMode
    var body: some View {
        if pickerInSidebar {
            Text("Home").font(.largeTitle.bold()).foregroundStyle(.white).fixedSize()
                .accessibilityAddTraits(.isHeader)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(MediaMode.allCases) { m in
                Button { app.mediaMode = m } label: {
                    if m == mode { Label(m.title, systemImage: "checkmark") } else { Label(m.title, systemImage: m.icon) }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mode.title).font(.largeTitle.bold()).foregroundStyle(.white)
                Image(systemName: "chevron.down").font(.headline.weight(.bold)).foregroundStyle(Cinema.accent)
            }
            .fixedSize()
        }
        .accessibilityLabel("\(mode.title). Double-tap to switch between Listen and Watch.")
        .accessibilityAddTraits(.isHeader)
    }
}


extension View {
    /// Mini player gestures: swipe left or right to change song, up to open Now Playing.
    func miniPlayerSwipes(_ player: AudioPlayer, open: @escaping () -> Void) -> some View {
        gesture(DragGesture(minimumDistance: 24).onEnded { drag in
            let dx = drag.translation.width, dy = drag.translation.height
            if abs(dx) > abs(dy), abs(dx) > 50 {
                if dx < 0 { if player.hasNext { player.next(); Haptics.tap() } } else { player.previous(); Haptics.tap() }
            } else if dy < -40 {
                open()
            }
        })
        .accessibilityAction(named: "Next Song") { player.next() }
        .accessibilityAction(named: "Previous Song") { player.previous() }
    }
}

// MARK: - Connection notice

/// What to do when the app has no server connection: try again, pick another server, or
/// play what's downloaded. Shown instead of loading placeholders once connecting has failed.
struct ConnectionNotice: View {
    @Environment(AppState.self) private var app
    @Environment(\.mediaMode) private var mode
    @Environment(DownloadManager.self) private var downloads

    enum Problem: Equatable { case noServer, offline, unreachable(String) }

    /// Nil while connected or still connecting.
    static func problem(_ app: AppState) -> Problem? {
        // Before the server list arrives there's nothing to choose yet (that's still loading).
        guard app.selectedServer != nil else { return app.servers.isEmpty ? nil : .noServer }
        guard case .failed(let message) = app.status else { return nil }
        return NetworkMonitor.shared.isConnected ? .unreachable(message) : .offline
    }

    var body: some View {
        if let problem = Self.problem(app) {
            ContentUnavailableView {
                Label(title(problem), systemImage: icon(problem))
            } description: {
                Text(message(problem))
            } actions: {
                VStack(spacing: 12) {
                    if problem != .noServer {
                        Button { Task { await app.connect() } } label: { Label("Retry", systemImage: "arrow.clockwise").frame(minWidth: 200) }
                            .prominentButton()
                    }
                    NavigationLink { SettingsView() } label: { Label("Choose Server", systemImage: "server.rack").frame(minWidth: 200) }
                        .buttonStyle(.bordered)
                    if hasDownloads {
                        Button { app.selectTab(.downloads, for: mode) } label: { Label("Browse Downloads", systemImage: "arrow.down.circle").frame(minWidth: 200) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var hasDownloads: Bool {
        downloads.records.contains { $0.state == .completed && ($0.isAudio == (mode == .music)) }
    }

    private func title(_ p: Problem) -> String {
        switch p {
        case .noServer: "No Server Chosen"
        case .offline: "You're Offline"
        case .unreachable: "Can't Reach \(app.selectedServer?.name ?? "Your Server")"
        }
    }

    private func icon(_ p: Problem) -> String {
        switch p {
        case .noServer: "server.rack"
        case .offline: "wifi.slash"
        case .unreachable: "exclamationmark.icloud"
        }
    }

    private func message(_ p: Problem) -> String {
        switch p {
        case .noServer: "Pick one of your Plex servers to start browsing."
        case .offline: "Connect to Wi-Fi or cellular to browse. Downloads play without a connection."
        case .unreachable(let detail): "It may be off or away from this network. \(detail)"
        }
    }
}

#if DEBUG
/// Synthetic media for repeatable visual review; no account, library or credentials are changed.
enum DesignReviewSamples {
    static let items: [PlexMetadata] = (0..<8).compactMap { index in
        let titles = ["Northern Light", "The Long Way Home", "After Hours", "Open Water", "A Quiet Place", "City Stories", "Coast to Coast", "The Last Journey"]
        let item: [String: Any] = ["ratingKey": "design-\(index)", "title": titles[index], "type": "movie", "year": 2024 + index % 2,
            "duration": 6_840_000, "viewOffset": index < 2 ? 1_800_000 : 0,
            "thumb": "http://127.0.0.1:18766/cover\(index).png", "art": "http://127.0.0.1:18766/wide\(index).png",
            "summary": "Extraordinary stories. Unexpected discoveries. Find something worth your evening."]
        guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
        return try? JSONDecoder().decode(PlexMetadata.self, from: data)
    }
    static var albums: [PlexMetadata] {
        items.enumerated().map { index, original in
            var item = original
            item.type = "album"
            item.parentTitle = ["The Midnight", "Coastal Radio", "Juniper", "Slow Motion"][index % 4]
            return item
        }
    }
}
#endif

#if DEBUG
struct DesignReviewView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var music: Bool { ProcessInfo.processInfo.arguments.contains("-designMusic") }
    private var library: Bool { ProcessInfo.processInfo.arguments.contains("-designLibrary") }
    private var empty: Bool { ProcessInfo.processInfo.arguments.contains("-designEmpty") }
    private var width: CGFloat { sizeClass == .regular ? 156 : Cinema.gridPosterWidth }
    private var items: [PlexMetadata] { music ? DesignReviewSamples.albums : DesignReviewSamples.items }

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if empty {
                            EmptyStateView(title: "Your library starts here", systemImage: "square.stack", message: "Connect your server to bring your movies, shows and music together.")
                                .frame(minHeight: 400)
                        } else if library {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 12)], alignment: .leading, spacing: 24) {
                                ForEach(items) { PosterCard(item: $0, width: width) }
                            }.padding(.horizontal)
                        } else {
                            HubRow(title: music ? "Made for your evening" : "Continue Watching", items: Array(items.prefix(2)), wide: !music)
                            HubRow(title: music ? "Recently played" : "Recently added", items: items)
                            HubRow(title: music ? "Rediscover your favorites" : "Worth another watch", items: Array(items.reversed()))
                        }
                    }.padding(.vertical, 16)
                }
                .pageTitle(library ? "Library" : music ? "Listen" : "Watch")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(Cinema.accent) } }
                .withRoutes()
            }.tabItem { Label("Home", systemImage: "house") }
            Text("Library").tabItem { Label("Library", systemImage: "square.stack") }
            Text("Search").tabItem { Label("Search", systemImage: "magnifyingglass") }
            Text("Downloads").tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        }
        .environment(\.mediaMode, music ? .music : .watch)
    }
}
#endif
