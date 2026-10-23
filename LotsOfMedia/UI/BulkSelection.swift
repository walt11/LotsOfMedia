import SwiftUI

/// Multi-select for lists of songs and videos: rows become checkable and a bar
/// of actions applies to everything selected.
struct BulkSelection: Equatable {
    var isActive = false
    private(set) var ids: [String] = []

    func contains(_ id: String) -> Bool { ids.contains(id) }
    mutating func toggle(_ id: String) { if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) } }
    mutating func set(_ all: [String]) { ids = all }
    mutating func end() { isActive = false; ids = [] }
    var count: Int { ids.count }
}

/// Wraps a row so that, while selecting, tapping toggles it instead of opening/playing it.
struct SelectableRow<Content: View>: View {
    let id: String
    @Binding var selection: BulkSelection
    @ViewBuilder let content: () -> Content

    var body: some View {
        row.listRowBackground(Color.clear)   // plain-list rows otherwise paint system black
    }

    @ViewBuilder private var row: some View {
        if selection.isActive {
            let on = selection.contains(id)
            Button { selection.toggle(id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(on ? Cinema.accent : .secondary)
                    content().allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        } else {
            content()
        }
    }
}

/// Select / Done toolbar button, plus Select All while selecting.
struct BulkSelectButton: ToolbarContent {
    @Binding var selection: BulkSelection
    let allIDs: [String]
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selection.isActive {
                Menu {
                    Button(selection.count == allIDs.count ? "Deselect All" : "Select All") {
                        selection.set(selection.count == allIDs.count ? [] : allIDs)
                    }
                    Button("Done") { selection.end() }
                } label: { Text("Done").fontWeight(.semibold) } primaryAction: { selection.end() }
            } else if !allIDs.isEmpty {
                Button("Select") { selection.isActive = true }
            }
        }
    }
}

/// Actions for the selected items. `remove` is the context's own removal
/// (e.g. from a playlist); without it, Remove deletes downloads.
struct BulkActionBar: View {
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    let items: [PlexMetadata]
    var removeLabel = "Remove"
    var remove: (([PlexMetadata]) -> Void)? = nil
    let finish: () -> Void
    @State private var addingToPlaylist = false

    private var scope: String { app.preferenceScope }
    private var playable: [PlexMetadata] { items.filter { $0.kind == .track || $0.isPlayableVideo } }
    private var downloaded: [DownloadRecord] {
        items.compactMap { downloads.record(serverID: app.selectedServerID ?? "", ratingKey: $0.ratingKey) }
    }

    var body: some View {
        let prefs = MediaPreferences.shared
        let allFavorite = !items.isEmpty && items.allSatisfy { prefs.isFavorite($0, scope: scope) }
        let videos = items.filter { $0.isPlayableVideo || $0.kind == .show || $0.kind == .season }
        VStack(spacing: 6) {
            Text(items.isEmpty ? "Select items" : "\(items.count) selected")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                action("Playlist", "text.badge.plus", disabled: playable.isEmpty || !app.isOnline || !sameKind) { addingToPlaylist = true }
                action(allFavorite ? "Unfavorite" : "Favorite", allFavorite ? "heart.slash" : "heart", disabled: items.isEmpty) {
                    prefs.setFavorite(items, on: !allFavorite, scope: scope); finish()
                }
                if !videos.isEmpty {
                    action("Later", "clock.badge.checkmark", disabled: false) {
                        for v in videos where !prefs.isInWatchLater(v, scope: scope) { prefs.toggleWatchLater(v, scope: scope) }
                        finish()
                    }
                }
                action("Download", "arrow.down.circle", disabled: items.isEmpty || !app.isOnline) {
                    let sid = app.selectedServerID ?? ""
                    let leaves = items.filter(\.isLeaf)
                    downloads.enqueue(leaves, serverID: sid, batchTitle: leaves.count > 1 ? "\(leaves.count) selected items" : nil)
                    for container in items where !container.isLeaf {
                        Task { await DownloadActions.download(container, serverID: sid, api: app.api, manager: downloads, quality: nil) }
                    }
                    finish()
                }
                if let remove {
                    action(removeLabel, "minus.circle", disabled: items.isEmpty, role: .destructive) { remove(items); finish() }
                } else if !downloaded.isEmpty {
                    action("Remove", "trash", disabled: false, role: .destructive) { downloads.deleteMany(downloaded.map(\.id)); finish() }
                }
            }
        }
        .padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $addingToPlaylist, onDismiss: finish) { AddToPlaylistView(items: playable) }
    }

    /// Plex playlists hold either songs or videos, not both.
    private var sameKind: Bool { playable.allSatisfy { $0.kind == .track } || playable.allSatisfy(\.isPlayableVideo) }

    private func action(_ title: String, _ icon: String, disabled: Bool, role: ButtonRole? = nil, _ run: @escaping () -> Void) -> some View {
        Button(role: role, action: run) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Cinema.accent)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// "Removed — Undo" message shown briefly after removing playlist entries.
struct UndoToast: View {
    let message: String
    let undo: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(message).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: undo).font(.subheadline.weight(.bold)).foregroundStyle(Cinema.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8, y: 4)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
