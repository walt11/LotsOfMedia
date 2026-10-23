import Intents
import SwiftUI

struct DownloadsView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var audio
    @ScaledMetric(relativeTo: .body) private var posterWidth = Cinema.gridPosterWidth
    @State private var showingQueue = false
    @State private var pendingRemoval: Removal?
    @State private var confirmCancelAll = false

    /// A group the user asked to remove, awaiting confirmation.
    struct Removal: Identifiable {
        let id = UUID()
        let title: String
        let recordIDs: [String]
        var collectionID: String?
        var showKey: String?
    }

    private var modeRecords: [DownloadRecord] { downloads.records.filter { mediaMode.includes($0.metadata) } }
    private static let unfinished: Set<DownloadRecord.State> = [.queued, .preparing, .downloading, .assembling, .paused, .failed]
    private var active: [DownloadRecord] { modeRecords.filter { Self.unfinished.contains($0.state) } }
    private var completed: [DownloadRecord] { modeRecords.filter { $0.state == .completed } }
    private var readyCollections: [DownloadCollection] { downloads.collections.filter { $0.isAudio == (mediaMode == .music) && downloads.records(in: $0).contains { $0.state == .completed } } }
    private var movies: [DownloadRecord] { completed.filter { $0.metadata.kind != .episode && $0.metadata.kind != .track } }
    private var showGroups: [(String, [DownloadRecord])] { group(completed.filter { $0.metadata.kind == .episode }) }
    private var musicGroups: [(String, [DownloadRecord])] { group(completed.filter { $0.metadata.kind == .track }) }

    private func group(_ recs: [DownloadRecord]) -> [(String, [DownloadRecord])] {
        Dictionary(grouping: recs, by: \.offlineGroupID)
            .sorted { ($0.value.first?.offlineGroupTitle ?? "").localizedCaseInsensitiveCompare($1.value.first?.offlineGroupTitle ?? "") == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    /// In-progress downloads: group downloads (playlist, season…) collapse to one row.
    private var activeEntries: [(id: String, title: String?, records: [DownloadRecord])] {
        var out: [(String, String?, [DownloadRecord])] = []
        var seen = Set<String>()
        for rec in active {
            if let batch = rec.batchID {
                guard seen.insert(batch).inserted else { continue }
                let members = modeRecords.filter { $0.batchID == batch }
                out.append((batch, rec.batchTitle, members))
            } else {
                out.append((rec.id, nil, [rec]))
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if modeRecords.isEmpty {
                    // Nothing at all: just the explanation, not an empty Ready/In Progress switch.
                    VStack(spacing: 16) {
                        EmptyStateView(title: "No Downloads", systemImage: "arrow.down.circle",
                                       message: mediaMode == .music ? "Download songs, albums, artists or music playlists to listen offline." : "Download movies, episodes, shows or video playlists to watch offline.")
                        Button { app.selectedTab = .library } label: { Text("Browse Library").padding(.horizontal, 8) }
                            .prominentButton()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                OfflineReadinessCard(records: modeRecords, music: mediaMode == .music, userID: downloads.activeUserID)
                if !completed.isEmpty {
                    StorageSummaryCard(movies: bytes(movies), tv: bytes(showGroups.flatMap(\.1)),
                                       music: bytes(musicGroups.flatMap(\.1)))
                        .padding(.horizontal)
                }
                PillPicker(options: [false, true], selection: $showingQueue) {
                    $0 ? "In Progress (\(active.count))" : "Ready Offline (\(completed.count))"
                }
                if showingQueue {
                    if active.isEmpty { EmptyStateView(title: "Queue Clear", systemImage: "checkmark.circle", message: "New downloads will appear here.") }
                    else { activeSection }
                } else {
                    if completed.isEmpty && !modeRecords.isEmpty {
                        EmptyStateView(title: "Nothing Ready Yet", systemImage: "arrow.down.circle", message: "Open In Progress to see your downloads.")
                    }
                    if mediaMode == .music {
                        musicList
                    } else {
                    if !readyCollections.isEmpty { playlistsSection }
                    if !movies.isEmpty {
                        posterSection("Movies & Videos") {
                            ForEach(movies) { rec in
                                MovieDownloadTile(record: rec) { pendingRemoval = Removal(title: rec.metadata.title, recordIDs: [rec.id]) }
                            }
                        }
                    }
                    if !showGroups.isEmpty {
                        posterSection("TV Shows") {
                            ForEach(showGroups, id: \.0) { title, recs in
                                groupTile(title: recs.first?.offlineGroupTitle ?? title, recs: recs, unit: "ep", showKey: recs.first?.metadata.grandparentRatingKey)
                            }
                        }
                    }
                    }
                }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 90)
        }
        .background(Cinema.background)
        .pageTitle("Downloads")
        .onAppear { if completed.isEmpty && !active.isEmpty { showingQueue = true } }
        .toolbar {
            if !active.isEmpty || !completed.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !active.isEmpty {
                            Button { active.forEach { downloads.pause($0.id) } } label: { Label("Pause All", systemImage: "pause") }
                            Button { active.filter { $0.state == .paused }.forEach { downloads.resume($0.id) } } label: { Label("Resume All", systemImage: "play") }
                            Button(role: .destructive) { confirmCancelAll = true } label: { Label("Cancel All", systemImage: "xmark") }
                            Divider()
                        }
                        NavigationLink(value: Route.storageCleanup) { Label("Free Up Space", systemImage: "trash.circle") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .removalConfirmation($pendingRemoval)
        .confirmationDialog("Cancel \(active.count) download\(active.count == 1 ? "" : "s")?", isPresented: $confirmCancelAll,
                            titleVisibility: .visible) {
            Button("Cancel All Downloads", role: .destructive) { downloads.deleteMany(active.map(\.id)) }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Finished downloads are kept.")
        }
    }

    private func bytes(_ recs: [DownloadRecord]) -> Int64 { recs.reduce(0) { $0 + ($1.totalBytes ?? 0) } }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.bold()).foregroundStyle(.white).padding(.horizontal)
    }

    // MARK: Downloading

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("In Progress")
            ForEach(activeEntries, id: \.id) { entry in
                Group {
                    if let title = entry.title, entry.records.count > 1 {
                        let remaining = entry.records.filter { $0.state != .completed }.map(\.id)
                        HStack(spacing: 8) {
                            NavigationLink(value: Route.downloadBatch(id: entry.id, title: title)) {
                                BatchDownloadRow(title: title, records: entry.records)
                            }
                            .buttonStyle(.plain)
                            CancelDownloadButton(title: title, recordIDs: remaining)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                downloads.deleteMany(entry.records.filter { $0.state != .completed }.map(\.id))
                            } label: { Label("Cancel Remaining", systemImage: "xmark") }
                        }
                    } else if let rec = entry.records.first {
                        DownloadRow(record: rec)
                            .contextMenu {
                                Button(role: .destructive) { downloads.delete(rec.id) } label: { Label("Cancel Download", systemImage: "xmark") }
                            }
                    }
                }
                .padding(12)
                .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                .padding(.horizontal)
            }
        }
    }

    // MARK: Music (a list, like the playlist and library pages)

    private var musicList: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(readyCollections) { c in
                let recs = downloads.records(in: c)
                let ready = recs.filter { $0.state == .completed }
                NavigationLink(value: Route.offlinePlaylist(id: c.id)) {
                    DownloadLibraryRow(title: c.title,
                                       detail: "Playlist · " + countAndSize(ready) + (ready.count < c.itemIDs.count ? " · \(c.itemIDs.count - ready.count) to go" : "")) {
                        OfflineCover(records: recs, shadow: false).frame(width: 56, height: 56)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        pendingRemoval = Removal(title: c.title, recordIDs: c.itemIDs, collectionID: c.id)
                    } label: { Label("Remove Download", systemImage: "trash") }
                }
            }
            ForEach(musicGroups, id: \.0) { id, recs in
                let title = recs.first?.offlineGroupTitle ?? "Music"
                NavigationLink(value: Route.offlineGroup(id: id, title: title)) {
                    DownloadLibraryRow(title: title, detail: "Artist · " + countAndSize(recs)) {
                        PlexImage(path: recs.first?.metadata.grandparentThumb, width: 120, height: 120,
                                  localFile: recs.first.map { DownloadStore.posterURL(id: $0.id) }, placeholderIcon: "music.mic")
                            .frame(width: 56, height: 56).clipShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        pendingRemoval = Removal(title: title, recordIDs: recs.map(\.id))
                    } label: { Label("Remove Download", systemImage: "trash") }
                }
            }
        }
        .padding(.horizontal)
    }

    private func countAndSize(_ recs: [DownloadRecord]) -> String {
        "\(recs.count) song\(recs.count == 1 ? "" : "s") · \(Fmt.bytes(bytes(recs)))"
    }

    // MARK: Playlists

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Playlists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(readyCollections) { c in
                        let recs = downloads.records(in: c)
                        let summary = GroupDownloadSummary(records: recs, expected: c.itemIDs.count)
                        NavigationLink(value: Route.offlinePlaylist(id: c.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                PlexImage(path: c.thumb, width: 300, height: 300,
                                          localFile: recs.first.map { DownloadStore.posterURL(id: $0.id) },
                                          placeholderIcon: c.isAudio ? "music.note.list" : "list.and.film")
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        if !summary.isComplete {
                                            GroupDownloadIcon(summary: summary, size: 20).padding(6).glassCircle()
                                                .padding(6)
                                        }
                                    }
                                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(summary.isComplete
                                     ? "\(summary.total) \(c.isAudio ? "song" : "item")\(summary.total == 1 ? "" : "s") · \(Fmt.bytes(summary.bytes))"
                                     : "\(recs.filter { $0.state == .completed }.count) of \(c.itemIDs.count) ready offline")
                                    .font(.caption).foregroundStyle(Cinema.muted).lineLimit(1)
                            }
                            .frame(width: 140)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingRemoval = Removal(title: c.title, recordIDs: c.itemIDs, collectionID: c.id)
                            } label: { Label("Remove Playlist", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Poster wall

    private func posterSection<Content: View>(_ title: String, square: Bool = false,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12, alignment: .top)],
                      alignment: .leading, spacing: 16, content: content)
                .padding(.horizontal)
        }
    }

    private func groupTile(title: String, recs: [DownloadRecord], unit: String, showKey: String?) -> some View {
        let isMusic = unit == "song"
        let first = recs.first
        let poster = isMusic ? (first?.metadata.grandparentThumb ?? first?.metadata.posterThumb) : first?.metadata.posterThumb
        return NavigationLink(value: Route.offlineGroup(id: first?.offlineGroupID ?? "", title: title)) {
            PosterTile(path: poster, localFile: first.map { DownloadStore.posterURL(id: $0.id) },
                       square: isMusic, placeholder: isMusic ? "music.note" : "tv",
                       badge: "\(recs.count) \(unit)\(recs.count == 1 ? "" : "s")",
                       title: title, caption: Fmt.bytes(bytes(recs)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                pendingRemoval = Removal(title: title, recordIDs: recs.map(\.id), showKey: showKey)
            } label: { Label("Remove All", systemImage: "trash") }
        }
    }
}

/// Storage used by downloads, split by type, against the limit or free space.
struct StorageSummaryCard: View {
    @Environment(DownloadManager.self) private var downloads
    let movies: Int64
    let tv: Int64
    let music: Int64

    static var movieColor: Color { Cinema.accent }
    static let tvColor = Cinema.converting
    /// Music and video are never shown together (each mode has its own card), so both use the accent.
    static var musicColor: Color { Cinema.accent }

    var body: some View {
        let used = movies + tv + music
        let cap: Int64? = downloads.storageCapGB > 0 ? Int64(downloads.storageCapGB) * 1_073_741_824 : nil
        let free = DownloadStore.availableCapacity()
        let total = max(used, cap ?? (used + (free ?? 0)), 1)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.bytes(used)).font(.title.bold()).foregroundStyle(.white)
                Text("downloaded").font(.subheadline).foregroundStyle(Cinema.muted)
                Spacer()
                if let cap {
                    Text("of \(Fmt.bytes(cap)) shared limit").font(.caption).foregroundStyle(Cinema.muted)
                } else if let free {
                    Text("\(Fmt.bytes(free)) free").font(.caption).foregroundStyle(Cinema.muted)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.color)
                            .frame(width: max(3, geo.size.width * CGFloat(seg.bytes) / CGFloat(total)))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 5) {
                        Circle().fill(seg.color).frame(width: 7, height: 7)
                        Text("\(seg.label) \(Fmt.bytes(seg.bytes))").font(.caption).foregroundStyle(Cinema.muted)
                    }
                }
            }
        }
        .padding(16)
        .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var segments: [(label: String, bytes: Int64, color: Color)] {
        [("Movies", movies, Self.movieColor), ("TV", tv, Self.tvColor), ("Music", music, Self.musicColor)]
            .filter { $0.1 > 0 }
    }
}

/// A poster on the downloads wall, with a quality or count badge.
struct PosterTile: View {
    let path: String?
    let localFile: URL?
    var square = false
    var placeholder = "film"
    let badge: String?
    let title: String
    var caption: String?
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PlexImage(path: path, width: 240, height: square ? 240 : 360, localFile: localFile, placeholderIcon: placeholder)
                .aspectRatio(square ? 1 : 2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) { if let progress { ProgressOverlay(progress: progress) } }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            if let caption { Text(caption).font(.caption2).foregroundStyle(Cinema.muted).lineLimit(1) }
        }
    }
}

/// A downloaded movie or video: tap to play, hold for more.
struct MovieDownloadTile: View {
    @Environment(AppState.self) private var app
    let record: DownloadRecord
    let onRemove: () -> Void

    private var badge: String? {
        if let h = record.quality.targetHeight { return "\(h)p" }
        if record.isConverted { return "MP4" }
        return record.metadata.primaryMedia?.resolutionLabel
    }

    var body: some View {
        Button { app.play(record.metadata, serverID: record.serverID) } label: {
            PosterTile(path: record.metadata.posterThumb, localFile: DownloadStore.posterURL(id: record.id),
                       badge: badge, title: record.metadata.title,
                       caption: [Fmt.duration(ms: record.metadata.duration), record.totalBytes.map(Fmt.bytes)]
                           .compactMap { $0 }.joined(separator: " · "),
                       progress: record.metadata.progress)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { app.play(record.metadata, serverID: record.serverID) } label: { Label("Play", systemImage: "play") }
            NavigationLink(value: record.metadata.route) { Label("Details", systemImage: "info.circle") }
            Button(role: .destructive, action: onRemove) { Label("Remove Download", systemImage: "trash") }
        } preview: {
            PlexImage(path: record.metadata.posterThumb, width: 400, height: 600, localFile: DownloadStore.posterURL(id: record.id))
                .frame(width: 240, height: 360)
        }
    }
}

extension View {
    /// Shared "Remove N downloads?" confirmation for group removal.
    func removalConfirmation(_ removal: Binding<DownloadsView.Removal?>) -> some View {
        modifier(RemovalConfirmation(removal: removal))
    }
}

private struct RemovalConfirmation: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Binding var removal: DownloadsView.Removal?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            removal.map { "Remove \($0.title)?" } ?? "",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible,
            presenting: removal
        ) { r in
            Button("Remove \(r.recordIDs.count) Download\(r.recordIDs.count == 1 ? "" : "s")", role: .destructive) {
                let serverID = downloads.records.first { r.recordIDs.contains($0.id) }?.serverID
                if let c = r.collectionID {
                    downloads.removeCollection(c)
                } else {
                    downloads.deleteMany(r.recordIDs)
                }
                if let show = r.showKey, let sid = serverID,
                   let rule = SmartDownloads.shared.rule(serverID: sid, showRatingKey: show) {
                    SmartDownloads.shared.remove(rule.id)
                }
            }
        } message: { r in
            if r.collectionID != nil {
                Text("Items that are also in another downloaded playlist are kept.")
            } else if r.showKey != nil {
                Text("Smart Download for this show is turned off too.")
            }
        }
    }
}

/// One row for a group download in progress ("Road Trip Mix · 5 of 24").
struct BatchDownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let title: String
    let records: [DownloadRecord]

    var body: some View {
        let summary = GroupDownloadSummary(records: records, expected: nil)
        HStack(spacing: 12) {
            PlexImage(path: records.first?.metadata.posterThumb, width: 120, height: 120,
                      localFile: records.first.map { DownloadStore.posterURL(id: $0.id) },
                      placeholderIcon: records.allSatisfy(\.isAudio) ? "music.note.list" : "square.stack")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: summary.progress(downloads))
                Text(summary.statusText + (summary.failed > 0 && summary.active > 0 ? " · \(summary.failed) failed" : ""))
                    .font(.caption).foregroundStyle(summary.failed > 0 ? .red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Every item of a group download, for pausing/retrying individual ones.
struct DownloadBatchView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(DownloadManager.self) private var downloads
    let batchID: String
    let title: String

    var body: some View {
        let recs = downloads.records.filter { $0.batchID == batchID && mediaMode.includes($0.metadata) }
        List {
            ForEach(recs) { rec in
                if rec.state == .completed {
                    CompletedDownloadRow(record: rec, siblings: recs.filter { $0.state == .completed })
                } else {
                    DownloadRow(record: rec)
                }
            }
        }
        .pageTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { recs.forEach { downloads.pause($0.id) } } label: { Label("Pause All", systemImage: "pause") }
                    Button { recs.forEach { downloads.resume($0.id) } } label: { Label("Resume All", systemImage: "play") }
                    Button(role: .destructive) {
                        downloads.deleteMany(recs.filter { $0.state != .completed }.map(\.id))
                    } label: { Label("Cancel Remaining", systemImage: "xmark") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

struct PlaylistDownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    let collection: DownloadCollection
    let records: [DownloadRecord]

    var body: some View {
        let summary = GroupDownloadSummary(records: records, expected: collection.itemIDs.count)
        HStack(spacing: 12) {
            PlexImage(path: collection.thumb, width: 120, height: 120,
                      localFile: records.first.map { DownloadStore.posterURL(id: $0.id) },
                      placeholderIcon: collection.isAudio ? "music.note.list" : "list.and.film")
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.title).font(.headline).lineLimit(1)
                Text(summary.isComplete
                     ? "\(summary.total) \(collection.isAudio ? "song" : "item")\(summary.total == 1 ? "" : "s") · \(Fmt.bytes(summary.bytes))"
                     : summary.statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !summary.isComplete { GroupDownloadIcon(summary: summary, size: 20) }
        }
    }
}

/// A downloaded playlist, playable offline in its original order.
/// A downloaded playlist, laid out like the playlist page: cover, title, details, action row, songs.
struct OfflinePlaylistView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let collectionID: String
    @State private var pendingRemoval: DownloadsView.Removal?

    var body: some View {
        if let c = downloads.collections.first(where: { $0.id == collectionID }) {
            let recs = downloads.records(in: c)
            OfflineCollectionPage(title: c.title, subtitle: "Downloaded playlist", records: recs, menu: {
                Section("Keep Updated") { PlaylistUpdateToggles(collection: c) }
                Button(role: .destructive) {
                    pendingRemoval = .init(title: c.title, recordIDs: c.itemIDs, collectionID: c.id)
                } label: { Label("Remove Download", systemImage: "trash") }
            }, footer: c.lastSynced.map { "New songs checked \($0.formatted(.relative(presentation: .named)))." })
            .removalConfirmation($pendingRemoval)
        } else {
            EmptyStateView(title: "Playlist Removed", systemImage: "music.note.list")
                .onAppear { dismiss() }
        }
    }
}

/// Shared layout for downloaded playlists, albums and artists.
struct OfflineCollectionPage<Menu: View>: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var audio
    let title: String
    let subtitle: String
    let records: [DownloadRecord]
    @ViewBuilder let menu: Menu
    var footer: String? = nil
    @State private var shuffleOn = false
    @State private var backdrop: Color = Cinema.surface
    @State private var headerVisible = true

    private var ready: [DownloadRecord] { records.filter { $0.state == .completed } }
    private var isPlayingHere: Bool {
        guard audio.isPlaying, let key = audio.current?.track.ratingKey else { return false }
        return ready.contains { $0.metadata.ratingKey == key }
    }

    var body: some View {
        List {
            OfflineCover(records: records)
                .frame(maxWidth: 250)
                .frame(maxWidth: .infinity)
                .padding(.top, 4).padding(.bottom, 8)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                    .onAppear { headerVisible = true }.onDisappear { headerVisible = false }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Cinema.accent)
                    Text(details).font(.subheadline).foregroundStyle(.secondary)
                }
                MusicActionRow(shuffleOn: $shuffleOn, isPlaying: isPlayingHere, playOrPause: playOrPause, canPlay: !ready.isEmpty) {
                    SwiftUI.Menu { menu } label: { MusicRowIcon(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

            ForEach(records) { rec in
                Group {
                    if rec.state == .completed { OfflineTrackRow(record: rec, siblings: ready) }
                    else { DownloadRow(record: rec) }
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 6))
            }
            if let footer {
                Text(footer).font(.caption).foregroundStyle(Cinema.muted)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [backdrop, Cinema.background], startPoint: .top, endPoint: .bottom).frame(height: 520)
                Cinema.background
            }
            .ignoresSafeArea()
        }
        .navigationTitle(headerVisible ? "" : title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: records.first?.id) { loadBackdrop() }
    }

    private var details: String {
        let songs = ready.count
        let minutes = ready.reduce(0) { $0 + ($1.metadata.duration ?? 0) } / 60_000
        let bytes = ready.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        var parts = [subtitle, "\(songs) \(ready.allSatisfy(\.isAudio) ? "song" : "item")\(songs == 1 ? "" : "s")"]
        if minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min") }
        if bytes > 0 { parts.append(Fmt.bytes(bytes)) }
        if ready.count < records.count { parts.append("\(records.count - ready.count) downloading") }
        return parts.joined(separator: " · ")
    }

    private func playOrPause() {
        if isPlayingHere { audio.pause(); return }
        guard let first = ready.first else { return }
        if ready.allSatisfy(\.isAudio) { audio.play(downloads: ready, shuffle: shuffleOn) }
        else { app.playAll(ready.map(\.metadata), serverID: first.serverID, shuffle: shuffleOn) }
    }

    private func loadBackdrop() {
        guard let rec = records.first, let img = UIImage(contentsOfFile: DownloadStore.posterURL(id: rec.id).path),
              let color = img.averageColor else { return }
        backdrop = Cinema.musicTint(from: color)
    }
}

/// Cover from saved artwork: one picture, or four different album covers in a grid.
struct OfflineCover: View {
    let records: [DownloadRecord]
    var shadow = true

    var body: some View {
        let ids = distinctArt
        Group {
            if ids.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { tile(ids[0]); tile(ids[1]) }
                    GridRow { tile(ids[2]); tile(ids[3]) }
                }
            } else if let first = ids.first {
                tile(first)
            } else {
                Rectangle().fill(Cinema.placeholder).overlay(Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: shadow ? 6 : 4))
        .shadow(color: .black.opacity(shadow ? 0.5 : 0), radius: 18, y: 10)
    }

    /// One record per album, so the grid shows four different covers.
    private var distinctArt: [String] {
        var seen = Set<String>()
        return records.filter { seen.insert($0.metadata.parentRatingKey ?? $0.id).inserted }.prefix(4).map(\.id)
    }

    private func tile(_ id: String) -> some View {
        PlexImage(path: nil, localFile: DownloadStore.posterURL(id: id), placeholderIcon: "music.note")
            .aspectRatio(1, contentMode: .fill)
    }
}

/// A row in the Downloads list: artwork, name, "Playlist · 3 songs · 24 MB", chevron.
struct DownloadLibraryRow<Art: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let art: Art

    var body: some View {
        HStack(spacing: 12) {
            art
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Cinema.accent)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A downloaded song or video row in the playlist style.
struct OfflineTrackRow: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var audio
    let record: DownloadRecord
    var siblings: [DownloadRecord] = []
    /// Shown when results come from more than one server, so identical titles can be told apart.
    var serverName: String? = nil

    var body: some View {
        let m = record.metadata
        let current = audio.current?.track.ratingKey == m.ratingKey && audio.current?.serverID == record.serverID
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(spacing: 12) {
                    PlexImage(path: m.posterThumb, width: 120, height: 120, localFile: DownloadStore.posterURL(id: record.id),
                              placeholderIcon: record.isAudio ? "music.note" : "film")
                        .frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.kind == .episode ? (m.subtitleLine ?? m.title) : m.title)
                            .foregroundStyle(current ? Cinema.accent : .primary).lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(Cinema.accent)
                            Text([m.originalTitle ?? m.grandparentTitle ?? m.parentTitle ?? Fmt.duration(ms: m.duration), serverName]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                if record.isAudio {
                    Button { app.addToQueue(m, next: true, serverID: record.serverID) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                }
                Button(role: .destructive) { downloads.delete(record.id) } label: { Label("Remove Download", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .tint(.secondary)
            .accessibilityLabel("More for \(m.title)")
        }
        .swipeActions {
            Button(role: .destructive) { downloads.delete(record.id) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func play() {
        if record.isAudio {
            let list = siblings.isEmpty ? [record] : siblings
            audio.play(downloads: list, startAt: list.firstIndex(of: record) ?? 0)
        } else {
            app.play(record.metadata, serverID: record.serverID)
        }
    }
}

struct CompletedDownloadRow: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(AudioPlayer.self) private var audio
    let record: DownloadRecord
    var siblings: [DownloadRecord] = []

    var body: some View {
        Button {
            if record.metadata.kind == .track {
                let list = siblings.isEmpty ? [record] : siblings
                audio.play(downloads: list, startAt: list.firstIndex(of: record) ?? 0)
            } else {
                app.play(record.metadata, serverID: record.serverID)
            }
        } label: {
            HStack(spacing: 12) {
                let isEpisode = record.metadata.kind == .episode
                PlexImage(path: isEpisode ? record.metadata.thumb : record.metadata.posterThumb, width: 240, height: 240,
                          localFile: isEpisode ? DownloadStore.artURL(id: record.id) : DownloadStore.posterURL(id: record.id),
                          placeholderIcon: record.isAudio ? "music.note" : "film")
                    .frame(width: isEpisode ? 96 : 48, height: isEpisode ? 54 : (record.isAudio ? 48 : 72))
                    .overlay(alignment: .bottom) { if let p = record.metadata.progress { ProgressOverlay(progress: p) } }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEpisode ? (record.metadata.subtitleLine ?? record.metadata.title) : record.metadata.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([Fmt.duration(ms: record.metadata.duration), record.totalBytes.map(Fmt.bytes),
                          record.isConverted ? (record.sourceContainer.map { "Converted from \($0.uppercased())" } ?? "Converted") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if record.progress(for: downloads.activeUserID)?.pending == true {
                        Label("Progress will sync when online", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Cinema.accent)
            }
        }
        .buttonStyle(.plain)
    }
}

struct DownloadRow: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(NetworkMonitor.self) private var network
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            PlexImage(path: record.metadata.posterThumb, width: 120, height: 180,
                      localFile: DownloadStore.posterURL(id: record.id), placeholderIcon: record.isAudio ? "music.note" : "film")
                .frame(width: 40, height: record.isAudio ? 40 : 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if record.state == .downloading || record.state == .assembling || record.state == .paused {
                    ProgressView(value: downloads.progress(of: record)).tint(record.state == .paused ? .secondary : Cinema.accent)
                } else if record.state == .preparing {
                    ProgressView(value: record.preparationProgress ?? 0).tint(Cinema.converting)
                }
                Text(statusText).font(.caption).foregroundStyle(record.state == .failed ? .red : .secondary)
                if record.waitingForSpace || (record.lastError?.localizedCaseInsensitiveContains("storage") == true) {
                    NavigationLink("Manage Storage") { SettingsView() }.font(.caption)
                }
                if record.state == .downloading || record.state == .queued {
                    if network.isConnected && !downloads.allowCellular && !network.usesWiFi {
                        Button("Allow Cellular") { downloads.allowCellular = true }.font(.caption)
                    } else if network.isConnected && !downloads.transfersAllowed {
                        Button("Allow on Battery") { downloads.chargingOnly = false }.font(.caption)
                    }
                }
            }
            Spacer(minLength: 4)
            controls
            if record.state != .completed && record.state != .assembling {
                CancelDownloadButton(title: record.metadata.title, recordIDs: [record.id])
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        record.metadata.kind == .episode
            ? "\(record.metadata.grandparentTitle ?? "") · \(record.metadata.subtitleLine ?? record.metadata.title)"
            : record.metadata.title
    }

    private var statusText: String {
        let bytes = downloads.liveBytes[record.id] ?? record.downloadedSegmentBytes
        let sizes = record.totalBytes.map { "\(Fmt.bytes(bytes)) of \(Fmt.bytes($0))" } ?? ""
        switch record.state {
        case .queued:
            if let error = record.lastError { return "Waiting · " + error }
            if !network.isConnected { return "Waiting for network" }
            if !downloads.allowCellular && !network.usesWiFi { return "Waiting for Wi-Fi" }
            if !downloads.transfersAllowed { return "Waiting for charger" }
            return "Waiting to start"
        case .preparing:
            let pct = Int((record.preparationProgress ?? 0) * 100)
            let why = record.conversionReason.map { " · \($0)" } ?? ""
            return "Converting · \(pct)%" + why + (record.lastError.map { " · \($0)" } ?? "")
        case .downloading:
            if !network.isConnected { return "\(sizes) · Waiting for network" }
            if !downloads.allowCellular && !network.usesWiFi { return "\(sizes) · Waiting for Wi-Fi" }
            if !downloads.transfersAllowed { return "\(sizes) · Waiting for charger" }
            return record.lastError.map { "\(sizes) · \($0)" } ?? "Downloading · \(sizes)"
        case .assembling: return "Finishing…"
        case .paused: return record.lastError ?? "Paused · \(sizes)"
        case .failed: return record.lastError ?? "Failed"
        case .completed: return record.totalBytes.map(Fmt.bytes) ?? "Downloaded"
        }
    }

    @ViewBuilder private var controls: some View {
        switch record.state {
        case .paused, .failed:
            Button { downloads.resume(record.id) } label: {
                Image(systemName: record.state == .failed ? "arrow.clockwise.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(record.state == .failed ? "Retry download" : "Resume download")
            .foregroundStyle(Cinema.accent)
        case .queued, .preparing, .downloading:
            Button { downloads.pause(record.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// ✕ button that cancels one or more unfinished downloads after confirming.
struct CancelDownloadButton: View {
    @Environment(DownloadManager.self) private var downloads
    let title: String
    let recordIDs: [String]
    @State private var confirming = false

    var body: some View {
        Button { confirming = true } label: {
            Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.35))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel download")
        .confirmationDialog(recordIDs.count == 1 ? "Cancel downloading \(title)?" : "Cancel \(recordIDs.count) downloads in \(title)?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(recordIDs.count == 1 ? "Cancel Download" : "Cancel Remaining Downloads", role: .destructive) {
                downloads.deleteMany(recordIDs)
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("Anything already downloaded for \(recordIDs.count == 1 ? "it" : "them") will be deleted.")
        }
    }
}

/// A downloaded show or artist, browsable without a connection.
struct OfflineGroupView: View {
    @Environment(DownloadManager.self) private var downloads
    let groupID: String
    let groupTitle: String
    @State private var pendingRemoval: DownloadsView.Removal?

    private var records: [DownloadRecord] {
        downloads.records
            .filter { $0.state == .completed && $0.offlineGroupID == groupID }
            .sorted { ($0.metadata.parentIndex ?? 0, $0.metadata.index ?? 0) < ($1.metadata.parentIndex ?? 0, $1.metadata.index ?? 0) }
    }

    var body: some View {
        let all = records
        if !all.isEmpty, all.allSatisfy(\.isAudio) {
            OfflineCollectionPage(title: groupTitle, subtitle: "Downloaded", records: all, menu: {
                Button(role: .destructive) {
                    pendingRemoval = .init(title: groupTitle, recordIDs: all.map(\.id))
                } label: { Label("Remove Download", systemImage: "trash") }
            })
            .removalConfirmation($pendingRemoval)
        } else {
            showList(all)
        }
    }

    @ViewBuilder private func showList(_ all: [DownloadRecord]) -> some View {
        let grouped = Dictionary(grouping: all) { r -> String in
            r.metadata.kind == .track ? (r.metadata.parentTitle ?? "Songs") : (r.metadata.parentIndex.map { "Season \($0)" } ?? r.metadata.parentTitle ?? "Episodes")
        }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        List {
            ForEach(grouped, id: \.key) { title, recs in
                Section {
                    ForEach(recs) { rec in
                        CompletedDownloadRow(record: rec, siblings: recs)
                            .swipeActions {
                                Button(role: .destructive) { downloads.delete(rec.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    HStack {
                        Text(title)
                        Spacer()
                        Button(role: .destructive) {
                            pendingRemoval = .init(title: "\(groupTitle) · \(title)", recordIDs: recs.map(\.id))
                        } label: {
                            Label("Remove", systemImage: "trash").labelStyle(.titleAndIcon).font(.caption)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .pageTitle(groupTitle)
        .toolbar {
            if !all.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        let show = all.first?.metadata.kind == .episode ? all.first?.metadata.grandparentRatingKey : nil
                        pendingRemoval = .init(title: groupTitle, recordIDs: all.map(\.id), showKey: show)
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Remove all downloads for \(groupTitle)")
                }
            }
        }
        .removalConfirmation($pendingRemoval)
    }
}

/// Position slider and times. Its own view so the once-a-second position update
/// redraws only this, not the whole Now Playing screen.
private struct NowPlayingScrubber: View {
    let player: AudioPlayer
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrub ?? player.currentTime }, set: { scrub = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrub { player.seek(to: s); scrub = nil }
            }
            HStack {
                Text(Fmt.clock(seconds: scrub ?? player.currentTime))
                Spacer()
                Text("-" + Fmt.clock(seconds: max(0, player.duration - (scrub ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

/// "Play Road Trip in LotsOfMedia": asks for Siri access once, then shows its state.
struct SiriSettingRow: View {
    @State private var status = INPreferences.siriAuthorizationStatus()

    var body: some View {
        switch status {
        case .authorized:
            LabeledContent("Siri") { Text("Say “Play … in LotsOfMedia”").foregroundStyle(.secondary) }
        case .notDetermined:
            Button {
                guard ProStore.require(.siri) else { return }
                INPreferences.requestSiriAuthorization { s in Task { @MainActor in status = s } }
            } label: {
                HStack { Label("Use Siri to Play Music", systemImage: "mic"); Spacer(); ProBadge() }
            }
        default:
            LabeledContent("Siri", value: "Off in iPhone Settings")
        }
    }
}

/// Settings → App Icon: every design, shown as the home screen draws it (dark versions
/// while the system is in dark mode).
struct AppIconPickerView: View {
    private var store: AppIconStore { .shared }
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 18)]
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemDark = Self.isSystemDark

    /// The app is always dark, so this asks the screen, which follows the system setting.
    private static var isSystemDark: Bool {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        return scene?.screen.traitCollection.userInterfaceStyle == .dark
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(AppIconStyle.allCases) { style in
                        let on = store.iconStyle == style
                        Button { store.iconStyle = style } label: {
                            VStack(spacing: 8) {
                                Image(style.previewName(dark: systemDark))
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .strokeBorder(on ? Cinema.accent : .white.opacity(0.1), lineWidth: on ? 3 : 1)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if on {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.black, Cinema.accent)
                                                .offset(x: 6, y: -6)
                                        }
                                    }
                                Text(style.name)
                                    .font(.caption.weight(on ? .semibold : .regular))
                                    .foregroundStyle(on ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.name) icon")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding()
        }
        .background(Cinema.background)
        .pageTitle("App Icon")
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemDark = Self.isSystemDark }   // changed in Control Center
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @State private var confirmSignOut = false
    @State private var confirmSwitchAccount = false
    @State private var confirmDeleteAll = false
    @State private var usedBytes: Int64 = 0
    @State private var showUsers = false
    @State private var askWhoIsWatching = WhoIsWatching.isEnabled

    var body: some View {
        @Bindable var app = app
        @Bindable var downloads = downloads
        Form {
            ProSettingsSection()
            Section("Account") {
                if let jellyfin = app.jellyfinUser {
                    LabeledContent("Jellyfin", value: jellyfin)
                }
                if let user = app.user {
                    LabeledContent(app.jellyfinUser == nil ? "Signed in as" : "Plex account", value: user.title ?? user.username ?? user.email ?? "Plex user")
                    if app.canSwitchUsers {
                        Button { showUsers = true } label: { Label("Switch Home User", systemImage: "person.2.fill") }
                        Toggle(isOn: $askWhoIsWatching) {
                            Label("Ask Who's Watching", systemImage: "person.crop.circle.badge.questionmark")
                        }
                        .onChange(of: askWhoIsWatching) { _, on in WhoIsWatching.isEnabled = on }
                    }
                } else if app.isSignedIn {
                    LabeledContent("Signed in", value: "Plex account")
                } else if app.jellyfinUser == nil {
                    Text("Not signed in (manual server)").foregroundStyle(.secondary)
                }
                Button { confirmSwitchAccount = true } label: {
                    Label(app.isSignedIn ? "Sign In with Another Plex Account" : "Sign In with Plex", systemImage: "person.crop.circle.badge.plus")
                }
                if app.isSignedIn {
                    Button("Sign Out of Plex", role: .destructive) { confirmSignOut = true }
                }
            }
            Section("Server") {
                NavigationLink { ServerPickerView() } label: {
                    LabeledContent("Server", value: app.selectedServer?.name ?? "None")
                }
                LabeledContent("Connection") {
                    switch app.status {
                    case .connected:
                        Text(app.isLocalConnection ? "Local" : "Remote").foregroundStyle(.green)
                    case .connecting:
                        ProgressView()
                    case .failed:
                        Text("Unavailable").foregroundStyle(.red)
                    case .idle:
                        Text("—")
                    }
                }
                if let base = app.api?.baseURL.host {
                    LabeledContent("Address", value: base).font(.caption)
                }
                Button("Reconnect") { Task { await app.connect() } }
            }
            Section {
                NavigationLink { AppIconPickerView() } label: {
                    LabeledContent("App Icon", value: AppIconStore.shared.iconStyle.name)
                }
            } header: {
                Text("Appearance")
            }
            Section {
                NavigationLink("Music & Watch Preferences") { PlaybackPreferencesView() }
                SiriSettingRow()
            } header: {
                Text("Playback")
            }
            Section {
                Picker("Download Quality", selection: $downloads.defaultQuality) {
                    ForEach(DownloadQuality.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Download Only on Wi-Fi", isOn: Binding(get: { !downloads.allowCellular },
                                                                 set: { downloads.allowCellular = !$0 }))
                if downloads.allowCellular {
                    Picker("Quality on Cellular", selection: $downloads.cellularQuality) {
                        Text("Same as Wi-Fi").tag(DownloadQuality?.none)
                        ForEach(DownloadQuality.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Picker("Remove Watched Videos", selection: $downloads.removeWatchedAfterDays) {
                    Text("Never").tag(0)
                    Text("After 1 Day").tag(1)
                    ForEach([3, 7, 14, 30], id: \.self) { Text("After \($0) Days").tag($0) }
                }
                Toggle("Download Only While Charging", isOn: $downloads.chargingOnly)
                Picker("Storage Limit", selection: $downloads.storageCapGB) {
                    Text("No Limit").tag(0)
                    ForEach([5, 10, 25, 50, 100, 250, 500], id: \.self) { Text("\($0) GB").tag($0) }
                }
                if downloads.storageCapGB > 0 {
                    Toggle("Remove Watched to Make Room", isOn: $downloads.freeSpaceWithWatched)
                }
                NavigationLink {
                    SmartDownloadsSettingsView()
                } label: {
                    LabeledContent("Smart Downloads", value: SmartDownloads.shared.rules.isEmpty ? "Off" : "\(SmartDownloads.shared.rules.count) show\(SmartDownloads.shared.rules.count == 1 ? "" : "s")")
                }
                Toggle("Progress on Lock Screen & Dynamic Island", isOn: Binding(
                    get: { DownloadActivityController.shared.isEnabled },
                    set: { DownloadActivityController.shared.isEnabled = $0 }))
                LabeledContent("Storage Used", value: Fmt.bytes(usedBytes))
                Button("Delete All Downloads", role: .destructive) { confirmDeleteAll = true }
                    .disabled(downloads.records.isEmpty)
            } header: {
                Text("Downloads")
            }
            SettingsTransferSection()
            Section {
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
            }
            Section {
            } footer: {
                VStack(spacing: 6) {
                    Text("LotsOfMedia \(PlexClient.version) · Client ID \(PlexClient.identifier.prefix(8))")
                    Text("© 2026 John Walter. All rights reserved.")
                    Text("Plex is a trademark of Plex, Inc. This app is not affiliated with or endorsed by Plex.")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            }
        }
        .titleWithDownloadStatus("Settings")
        .sheet(isPresented: $showUsers) { ProGate(.homeUsers) { UserPickerView() } }
        .task { await app.loadHomeUsers() }
        .task { usedBytes = await Task.detached { DownloadStore.usedBytes() }.value }
        .confirmationDialog("Sign out? Downloads stay on this device.", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.signOut() }
        }
        .confirmationDialog("Sign in with another Plex account?", isPresented: $confirmSwitchAccount, titleVisibility: .visible) {
            Button("Continue") { app.switchAccount() }
        } message: {
            Text("You'll be signed out of \(app.user?.title ?? app.user?.username ?? "this account"), then Plex asks which account to use. Downloads stay on this device.")
        }
        .confirmationDialog("Delete all downloaded media?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                downloads.deleteAll()
                usedBytes = 0
            }
        }
    }
}

// MARK: - Now Playing

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var showDevices = false
    @State private var showQueue = false
    @State private var showInfo = false
    @State private var addingToPlaylist = false
    @State private var showLyrics = false
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: artwork beside the song and its controls.
                VStack(spacing: 0) {
                    topBar
                    HStack(alignment: .center, spacing: 48) {
                        artwork.frame(maxWidth: 560)
                        VStack(spacing: 24) { controls }
                            .frame(maxWidth: 520)
                    }
                    .padding(.horizontal, 40)
                    .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 22) {
                    topBar
                    Spacer(minLength: 0)
                    artwork
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(.bottom)
        .background {
            LinearGradient(colors: [player.artworkTint ?? Cinema.surface, Cinema.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: player.artworkTint)
        }
        .padding(.bottom)
        .sheet(isPresented: $showQueue) { AudioQueueView() }
        .sheet(isPresented: $showLyrics) { LyricsView() }
        .sheet(isPresented: $showInfo) { PlaybackInfoView(source: .music) }
        .sheet(isPresented: $addingToPlaylist) { if let track = player.current?.track { AddToPlaylistView(item: track) } }
        .sheet(isPresented: $showDevices) { if let entry = player.current { HandoffView(item: entry.track, serverID: entry.serverID, player: player.playbackPlayer) } }
        .presentationDragIndicator(.hidden)
        .presentationBackground(Cinema.background)
        .modifier(LargePageOnIPad())
    }

    private var artwork: some View {
        Group {
            if let art = player.artwork {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Cinema.placeholder)
                    .overlay(Image(systemName: "music.note").font(.system(size: 64)))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .padding(.horizontal, 24)
        .overlay(alignment: .bottom) {
            if let device = AirPlayStatus.shared.deviceName {
                AirPlayPill(deviceName: device).offset(y: 16)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.track.title ?? "").font(.title2.bold()).lineLimit(1)
                Text(player.current?.track.grandparentTitle ?? player.current?.track.originalTitle ?? "")
                    .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track = player.current?.track {
                let fav = MediaPreferences.shared.isFavorite(track, scope: app.preferenceScope)
                Button { MediaPreferences.shared.toggle(track, scope: app.preferenceScope) } label: {
                    Image(systemName: fav ? "heart.fill" : "heart").font(.title2)
                        .foregroundStyle(fav ? Cinema.accent : .white.opacity(0.8))
                }
                .accessibilityLabel(fav ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        .padding(.horizontal, 24)
    
        NowPlayingScrubber(player: player)
            .padding(.horizontal, 24)
    
        // Shuffle · previous · play · next · repeat
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.shuffled ? Cinema.accent : .white.opacity(0.4))
            }
            .accessibilityLabel(player.shuffled ? "Disable shuffle" : "Shuffle remaining songs")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
                .accessibilityLabel("Previous")
            Spacer()
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
                .disabled(!player.hasNext)
                .accessibilityLabel("Next")
            Spacer()
            Button {
                let all = RepeatMode.allCases
                player.repeatMode = all[((all.firstIndex(of: player.repeatMode) ?? 0) + 1) % all.count]
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.4) : Cinema.accent)
            }
            .accessibilityLabel(player.repeatMode.label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
    
        if let error = player.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    
        HStack {
            Button { showDevices = true } label: { Image(systemName: "airplay.audio").font(.title3) }
                .accessibilityLabel("Play on another device")
            Spacer()
            Button { showLyrics = true } label: { Image(systemName: "quote.bubble").font(.title3) }
                .accessibilityLabel("Lyrics")
            Spacer()
            // Speed and chapters, for audiobooks and podcasts.
            Menu {
                if !player.chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(Array(player.chapters.enumerated()), id: \.offset) { _, chapter in
                            Button { player.seek(to: Double(chapter.startTimeOffset) / 1000) } label: {
                                if chapter == player.currentChapter { Label(chapter.title, systemImage: "checkmark") } else { Text(chapter.title) }
                            }
                        }
                    }
                }
                Picker("Speed", selection: Binding(get: { player.speed }, set: { player.speed = $0 })) {
                    ForEach(AudioPlayer.speeds, id: \.self) { s in Text(s == 1 ? "Normal Speed" : "\(s.formatted())×").tag(s) }
                }
            } label: {
                Text(player.speed == 1 ? "1×" : "\(player.speed.formatted())×").font(.callout.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 32)
            }
            .accessibilityLabel("Playback speed\(player.chapters.isEmpty ? "" : " and chapters")")
            Spacer()
            Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.title3) }
                .accessibilityLabel("Up Next, \(player.upcoming.count) songs")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 24)
    }

    /// Close · "Playing from <album>" · more.
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Text("PLAYING FROM").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.7))
                Text(player.current?.track.parentTitle ?? "Your Library").font(.footnote.weight(.bold)).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { addingToPlaylist = true } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                    .disabled(!app.isOnline || player.current == nil)
                if let track = player.current?.track, app.isOnline {
                    Button { Task { await app.startRadio(from: track) } } label: { Label("Start Radio", systemImage: "dot.radiowaves.left.and.right") }
                }
                SleepTimerMenu(player: player.playbackPlayer, endLabel: "End of Current Song")
                Button { showInfo = true } label: { Label("Playback Info", systemImage: "info.circle") }
            } label: { Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
            .accessibilityLabel("More")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

// MARK: - Smart downloads settings

struct SmartDownloadsSettingsView: View {
    @Environment(AppState.self) private var app
    private var smart: SmartDownloads { .shared }

    var body: some View {
        List {
            if smart.rules.isEmpty {
                EmptyStateView(title: "No Smart Downloads", systemImage: "wand.and.stars",
                               message: "Open a TV show and tap Smart Download to keep its next episodes downloaded automatically.")
                    .listRowBackground(Color.clear)
            }
            ForEach(smart.rules) { rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        PlexImage(path: rule.showThumb, width: 120, height: 180, placeholderIcon: "tv")
                            .frame(width: 40, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(rule.showTitle).font(.headline)
                    }
                    Picker("Keep downloaded", selection: Binding(get: { rule.keepCount }, set: { n in
                        var r = rule; r.keepCount = n; smart.set(r)
                    })) {
                        ForEach(SmartDownloads.keepChoices, id: \.self) { Text("Next \($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Delete after watching", isOn: Binding(get: { rule.deleteWatched }, set: { v in
                        var r = rule; r.deleteWatched = v; smart.set(r)
                    }))
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button(role: .destructive) { smart.remove(rule.id) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .pageTitle("Smart Downloads")
        .refreshable { await smart.refresh() }
    }
}


struct AudioQueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now Playing") { Text(current.track.title).font(.headline) }
                }
                Section("Up Next") {
                    if player.upcoming.isEmpty { Text("Your queue is empty.").foregroundStyle(.secondary) }
                    ForEach(player.upcoming) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.track.title)
                            Text(entry.track.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }.onDelete(perform: player.removeUpcoming).onMove(perform: player.moveUpcoming)
                }
            }
            .pageTitle("Playback Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}

struct VideoQueueView: View {
    @ObservedObject var playback: VideoPlaybackController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Now Playing") { Text(playback.request.item.title).font(.headline) }
                Section("Up Next") {
                    if playback.upNext.isEmpty { Text("Your queue is empty.").foregroundStyle(.secondary) }
                    ForEach(playback.upNext) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.item.grandparentTitle ?? entry.item.title)
                            Text(entry.item.subtitleLine ?? entry.item.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }.onDelete(perform: playback.removeUpcoming).onMove(perform: playback.moveUpcoming)
                }
            }
            .pageTitle("Playback Queue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}


/// Per-playlist options for keeping a downloaded playlist in step with the server.
struct PlaylistUpdateToggles: View {
    @Environment(DownloadManager.self) private var downloads
    let collection: DownloadCollection

    var body: some View {
        Toggle(collection.isAudio ? "Download New Songs" : "Download New Items", isOn: Binding(
            get: { collection.downloadsNewItems },
            set: { downloads.setPlaylistUpdates(collection.id, autoDownloadNew: $0) }))
        Toggle("Remove Items Taken Off the Playlist", isOn: Binding(
            get: { collection.removeMissing == true },
            set: { downloads.setPlaylistUpdates(collection.id, removeMissing: $0) }))
    }
}


/// On iPad, Now Playing opens as a large page instead of a small form sheet (iOS 18+).
private struct LargePageOnIPad: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.presentationSizing(.page) } else { content }
    }
}


// MARK: - Offline readiness

/// "Before a trip": what plays offline now, what's still converting or downloading, what
/// failed, and whether watch progress made offline has synced back to the server.
struct OfflineReadinessCard: View {
    @Environment(DownloadManager.self) private var downloads
    let records: [DownloadRecord]
    let music: Bool
    let userID: String?

    struct Counts: Equatable {
        var ready = 0, converting = 0, downloading = 0, paused = 0, failed = 0, unsynced = 0
        var allReady: Bool { converting == 0 && downloading == 0 && paused == 0 && failed == 0 }
    }

    static func counts(_ records: [DownloadRecord], userID: String?) -> Counts {
        var c = Counts()
        for r in records {
            switch r.state {
            case .completed: c.ready += 1
            case .preparing: c.converting += 1
            case .queued, .downloading, .assembling: c.downloading += 1
            case .paused: c.paused += 1
            case .failed: c.failed += 1
            }
            if r.progress(for: userID)?.pending == true { c.unsynced += 1 }
        }
        return c
    }

    var body: some View {
        let c = Self.counts(records, userID: userID)
        VStack(alignment: .leading, spacing: 10) {
            // Title and Resume side by side when they fit; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack {
                    title(c)
                    Spacer(minLength: 8)
                    resumeButton(c, fixed: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    title(c)
                    resumeButton(c, fixed: false)
                }
            }
            // Side by side when they fit; stacked on narrow screens and at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { stats(c, fixed: true) }
                VStack(alignment: .leading, spacing: 6) { stats(c, fixed: false) }
            }
            if c.unsynced > 0 {
                Label("\(c.unsynced) with watch progress that syncs when you're online", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !music, c.ready > 0 {
                Label("Watch progress is synced", systemImage: "checkmark.icloud").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Cinema.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func title(_ c: Counts) -> some View {
        Label(c.allReady ? "Ready for Offline" : (c.paused > 0 && c.downloading == 0 && c.converting == 0 ? "Paused" : "Getting Ready"),
              systemImage: c.allReady ? "checkmark.circle.fill" : (c.paused > 0 && c.downloading == 0 ? "pause.circle" : "clock.arrow.circlepath"))
            .font(.headline)
            .foregroundStyle(c.allReady ? Cinema.accent : .primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Only what this card shows (Listen or Watch), not every paused download.
    /// `fixed`: one line beside the title; stacked, the label may wrap so the card never widens.
    @ViewBuilder private func resumeButton(_ c: Counts, fixed: Bool) -> some View {
        if c.paused > 0 {
            Button {
                records.filter { $0.state == .paused }.forEach { downloads.resume($0.id) }
            } label: {
                Label("Resume \(c.paused) \(music ? (c.paused == 1 ? "song" : "songs") : (c.paused == 1 ? "download" : "downloads"))", systemImage: "play.fill")
                    .fixedSize(horizontal: fixed, vertical: !fixed)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// `fixed`: one row, each stat at its natural width; stacked, labels may wrap.
    @ViewBuilder private func stats(_ c: Counts, fixed: Bool) -> some View {
        stat(c.ready, music ? "songs ready" : "ready to watch", icon: "play.circle", fixed: fixed)
        if c.converting > 0 { stat(c.converting, "converting", icon: "gearshape.2", tint: Cinema.converting, fixed: fixed) }
        if c.downloading > 0 { stat(c.downloading, "downloading", icon: "arrow.down.circle", fixed: fixed) }
        if c.paused > 0 { stat(c.paused, "paused", icon: "pause.circle", fixed: fixed) }
        if c.failed > 0 { stat(c.failed, "failed", icon: "exclamationmark.triangle", tint: .red, fixed: fixed) }
    }

    private func stat(_ n: Int, _ label: String, icon: String, tint: Color = .secondary, fixed: Bool) -> some View {
        Label { Text("\(n.formatted()) \(label)").font(.subheadline) } icon: { Image(systemName: icon).foregroundStyle(tint) }
            .fixedSize(horizontal: fixed, vertical: !fixed)
            .accessibilityElement(children: .combine)
    }
}
