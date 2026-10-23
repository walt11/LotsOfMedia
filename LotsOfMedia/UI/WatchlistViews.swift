import SwiftUI

/// Add to / Remove from the plex.tv Watchlist (movies and shows; episodes and seasons add their show).
struct WatchlistAction: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata

    var body: some View {
        if app.isSignedIn, PlexWatchlist.canAdd(item) {
            let saved = WatchlistStore.shared.contains(item)
            let noun = item.kind == .episode || item.kind == .season ? "Show" : ""
            Button {
                Task {
                    do { try await WatchlistStore.shared.toggle(item, token: app.accountToken); Haptics.success() }
                    catch { app.actionError = error.localizedDescription }
                }
            } label: {
                Label(saved ? "Remove \(noun.isEmpty ? "" : noun + " ")from Watchlist" : "Add \(noun.isEmpty ? "" : noun + " ")to Watchlist",
                      systemImage: saved ? "bookmark.slash" : "bookmark")
            }
        }
    }
}

/// The plex.tv Watchlist, shared with every Plex app. Entries on this server open their page;
/// the rest are marked as not available here.
struct WatchlistView: View {
    @Environment(AppState.self) private var app
    /// Discover key → the same title in this server's library (nil: checked, not here).
    @State private var local: [String: PlexMetadata?] = [:]
    @State private var matchedServer: String?

    private var store: WatchlistStore { .shared }

    var body: some View {
        List {
            ForEach(store.items) { entry in
                let key = PlexWatchlist.discoverKey(for: entry) ?? entry.id
                Group {
                    if let match = local[key] ?? nil {
                        NavigationLink(value: match.route) { WatchlistRow(entry: entry, availability: .here) }
                            .contextMenu { ItemContextMenu(item: match) }
                    } else {
                        WatchlistRow(entry: entry, availability: local[key] == nil ? .checking : .elsewhere)
                    }
                }
                .listRowBackground(Color.clear)
                .swipeActions {
                    Button(role: .destructive) {
                        Task {
                            do { try await store.toggle(entry, token: app.accountToken) }
                            catch { app.actionError = error.localizedDescription }
                        }
                    } label: { Label("Remove", systemImage: "bookmark.slash") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.items.isEmpty {
                if store.isLoading {
                    ProgressView()
                } else if let error = store.error {
                    ContentUnavailableView("Couldn't Load Watchlist", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Your Watchlist Is Empty", systemImage: "bookmark",
                                           description: Text("Choose Add to Watchlist from a movie's or show's menu. Your Watchlist is shared with the other Plex apps."))
                }
            }
        }
        .pageTitle("Watchlist")
        .task(id: "\(app.accountToken ?? "")-\(app.selectedServerID ?? "")-\(app.contentVersion)") {
            await store.refresh(token: app.accountToken)
            await matchLocal()
        }
        .refreshable {
            await store.refresh(token: app.accountToken)
            local = [:]
            await matchLocal()
        }
    }

    /// Looks each entry up on the current server, a few at a time.
    private func matchLocal() async {
        guard let api = app.browseAPI else { return }
        if matchedServer != api.serverID { local = [:]; matchedServer = api.serverID }
        let pending = store.items.filter { local[PlexWatchlist.discoverKey(for: $0) ?? $0.id] == nil }
        await withTaskGroup(of: (String, PlexMetadata?).self) { group in
            var started = 0
            for entry in pending {
                let key = PlexWatchlist.discoverKey(for: entry) ?? entry.id
                if started >= 6, let done = await group.next() { local[done.0] = .some(done.1) }
                group.addTask { (key, await PlexWatchlist.localMatch(for: entry, api: api)) }
                started += 1
            }
            for await (k, match) in group { local[k] = .some(match) }
        }
    }
}

private struct WatchlistRow: View {
    enum Availability { case checking, here, elsewhere }
    let entry: PlexMetadata
    let availability: Availability

    var body: some View {
        HStack(spacing: 12) {
            PlexImage(path: entry.thumb, width: 120, height: 180, placeholderIcon: entry.kind == .show ? "tv" : "film")
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                Text([entry.kind == .show ? "Show" : "Movie", entry.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                switch availability {
                case .checking: EmptyView()
                case .here: Label("On this server", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                case .elsewhere: Label("Not on this server", systemImage: "icloud.slash").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(availability == .elsewhere ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
