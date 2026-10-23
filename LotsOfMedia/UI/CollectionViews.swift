import SwiftUI

// MARK: - Watch Later

struct WatchLaterAction: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    var body: some View {
        let saved = MediaPreferences.shared.isInWatchLater(item, scope: app.preferenceScope)
        Button { MediaPreferences.shared.toggleWatchLater(item, scope: app.preferenceScope) } label: {
            Label(saved ? "Remove from Watch Later" : "Add to Watch Later", systemImage: saved ? "clock.badge.xmark" : "clock.badge.checkmark")
        }
    }
}

/// Keeps Watch Later's metadata current and drops watched items when that's turned on.
@MainActor
enum WatchLaterRefresher {
    static func refresh(app: AppState) async {
        let prefs = MediaPreferences.shared
        let scope = app.preferenceScope
        let saved = prefs.watchLater(scope: scope)
        guard !saved.isEmpty, let api = app.browseAPI else { return }
        var fresh: [String: PlexMetadata] = [:]
        for start in stride(from: 0, to: saved.count, by: 50) {
            let keys = saved[start..<min(start + 50, saved.count)].map(\.ratingKey).joined(separator: ",")
            for item in (try? await api.container("/library/metadata/\(keys)").metadata) ?? [] { fresh[item.ratingKey] = item }
        }
        // Only trust removals from a live answer; cached data can be out of date.
        let removeWatched = prefs.watchLaterRemovesWatched && app.isOnline
        guard scope == app.preferenceScope else { return }
        let updated = MediaPreferences.refreshWatchLater(prefs.watchLater(scope: scope), fresh: fresh, removeWatched: removeWatched)
        if updated.map(\.ratingKey) != saved.map(\.ratingKey) || !fresh.isEmpty { prefs.setWatchLater(updated, scope: scope) }
    }
}

struct WatchLaterView: View {
    @Environment(AppState.self) private var app
    private var prefs: MediaPreferences { .shared }

    var body: some View {
        let items = prefs.watchLater(scope: app.preferenceScope)
        List {
            ForEach(items) { item in
                NavigationLink(value: item.route) { WatchLaterRow(item: item) }
                    .contextMenu { ItemContextMenu(item: item) }
                    .listRowBackground(Color.clear)
            }
            .onDelete { offsets in
                var list = items; list.remove(atOffsets: offsets)
                prefs.setWatchLater(list, scope: app.preferenceScope)
            }
            .onMove { from, to in
                var list = items; list.move(fromOffsets: from, toOffset: to)
                prefs.setWatchLater(list, scope: app.preferenceScope)
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("Nothing to Watch Later", systemImage: "clock.badge.checkmark",
                                       description: Text("Choose Add to Watch Later from a movie's or show's menu."))
            }
        }
        .pageTitle("Watch Later")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Remove Watched Items", isOn: Binding(get: { prefs.watchLaterRemovesWatched },
                                                                set: { prefs.watchLaterRemovesWatched = $0 }))
                    if !items.isEmpty { EditButton() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: app.contentVersion) { await WatchLaterRefresher.refresh(app: app) }
        .refreshable { await WatchLaterRefresher.refresh(app: app) }
    }
}

private struct WatchLaterRow: View {
    let item: PlexMetadata
    var body: some View {
        HStack(spacing: 12) {
            PlexImage(path: item.posterThumb, width: 120, height: 180, placeholderIcon: "film")
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let sub = item.kind == .episode ? item.subtitleLine : item.year.map(String.init) {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let left = Fmt.remaining(ms: item.duration, offset: item.viewOffset) {
                    Text(left).font(.caption).foregroundStyle(Cinema.accent)
                }
            }
        }
        .offlineAvailability(item)
    }
}

struct WatchLaterHomeSection: View {
    @Environment(AppState.self) private var app
    var body: some View {
        let items = MediaPreferences.shared.watchLater(scope: app.preferenceScope)
        if !items.isEmpty {
            HubRow(title: "Watch Later", items: Array(items.prefix(12)), moreRoute: .watchLater)
                .task(id: app.contentVersion) { await WatchLaterRefresher.refresh(app: app) }
        }
    }
}

// MARK: - Mixes

struct MixesHomeSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: Route.mixes) {
                HStack(spacing: 4) {
                    Text("Mixes").font(.title3.bold())
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(MusicMix.allCases) { mix in
                        NavigationLink(value: Route.mix(mix)) { MixCard(mix: mix) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct MixCard: View {
    let mix: MusicMix
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: mix.icon)
                .font(.title2)
                .foregroundStyle(Cinema.accent)
            Spacer(minLength: 0)
            Text(mix.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(mix.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(width: 160, height: 120, alignment: .topLeading)
        .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MixesView: View {
    var body: some View {
        List(MusicMix.allCases) { mix in
            NavigationLink(value: Route.mix(mix)) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mix.title).font(.subheadline.weight(.semibold))
                        Text(mix.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: mix.icon).foregroundStyle(Cinema.accent) }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .pageTitle("Mixes")
    }
}

struct MixView: View {
    @Environment(AppState.self) private var app
    @Environment(AudioPlayer.self) private var audio
    let mix: MusicMix
    @State private var tracks: [PlexMetadata] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selection = BulkSelection()

    var body: some View {
        List {
            if !tracks.isEmpty && !selection.isActive {
                HStack(spacing: 12) {
                    Button { play(shuffle: false) } label: {
                        HStack(spacing: 6) { Image(systemName: "play.fill"); Text("Play") }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }.prominentButton()
                    Button { play(shuffle: true) } label: {
                        HStack(spacing: 6) { Image(systemName: "shuffle"); Text("Shuffle") }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    }.buttonStyle(.bordered)
                }
                .font(.subheadline.weight(.semibold))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { i, track in
                SelectableRow(id: track.ratingKey, selection: $selection) {
                    TrackRow(item: track, number: nil) {
                        if let ak = track.parentRatingKey {
                            ManualPlays.record(albumKey: ak, title: track.parentTitle ?? track.title, art: track.parentThumb ?? track.thumb, song: track.title, serverID: app.selectedServerID ?? "")
                        }
                        audio.play(tracks, serverID: app.selectedServerID ?? "", startAt: i)
                    }
                }
            }
        }
        .listStyle(.plain)
        .toolbar { BulkSelectButton(selection: $selection, allIDs: tracks.map(\.ratingKey)) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.isActive {
                BulkActionBar(items: selection.ids.compactMap { id in tracks.first { $0.ratingKey == id } }) { selection.end() }
            }
        }
        .overlay {
            if loading && tracks.isEmpty { ProgressView() }
            else if let error, tracks.isEmpty {
                ContentUnavailableView("Couldn't Build Mix", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if tracks.isEmpty {
                ContentUnavailableView("No Songs Yet", systemImage: mix.icon, description: Text(mix.subtitle))
            }
        }
        .pageTitle(mix.title)
        .task(id: app.contentVersion) { await load() }
        .refreshable { await load() }
    }

    private func play(shuffle: Bool) {
        audio.play(tracks, serverID: app.selectedServerID ?? "", shuffle: shuffle)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            tracks = try await MusicMixLoader.load(mix, app: app)
            error = nil
        } catch {
            self.error = mix.isOffline ? error.localizedDescription : "Connect to your server to build this mix, or open Downloaded Songs."
        }
    }
}
