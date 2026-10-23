import SwiftUI
import AVKit
import PhotosUI

struct FavoriteAction: View {
    @Environment(AppState.self) private var app
    let item: PlexMetadata
    var body: some View {
        let saved = MediaPreferences.shared.isFavorite(item, scope: app.preferenceScope)
        Button { MediaPreferences.shared.toggle(item, scope: app.preferenceScope) } label: {
            Label(saved ? "Remove from Favorites" : "Add to Favorites", systemImage: saved ? "heart.fill" : "heart")
        }
    }
}

struct FavoritesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.mediaMode) private var mode
    var body: some View {
        let items = MediaPreferences.shared.favorites(scope: app.preferenceScope, mode: mode)
        List {
            ForEach(items) { item in
                if item.kind == .track {
                    TrackRow(item: item, number: nil) { AudioPlayer.shared.play([item], serverID: app.selectedServerID ?? "") }
                } else {
                    NavigationLink(item.title, value: item.route).contextMenu { ItemContextMenu(item: item) }
                }
            }
        }.overlay { if items.isEmpty { ContentUnavailableView("No Favorites Yet", systemImage: "heart", description: Text("Add favorites from an item's menu.")) } }
            .pageTitle("Favorites")
    }
}

struct FavoritesHomeSection: View {
    @Environment(AppState.self) private var app
    @Environment(\.mediaMode) private var mode
    var body: some View {
        let items = MediaPreferences.shared.favorites(scope: app.preferenceScope, mode: mode)
        // Same header style as every other Home row; hidden until there's something in it.
        if !items.isEmpty { HubRow(title: "Favorites", items: Array(items.prefix(12)), moreRoute: .favorites) }
    }
}

struct HomeCustomizeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.mediaMode) private var mode
    @Environment(\.dismiss) private var dismiss
    private var layout: MediaPreferences.HomeLayout { MediaPreferences.shared.layout(scope: app.preferenceScope, mode: mode) }
    var body: some View {
        NavigationStack {
            List {
                Section("Drag to reorder; toggle to show or hide") {
                    ForEach(layout.order, id: \.self) { id in
                        Toggle(MediaPreferences.sectionTitle(id, mode: mode), isOn: Binding(get: { !layout.hidden.contains(id) }, set: { visible in
                            var value = layout
                            if visible { value.hidden.remove(id) } else { value.hidden.insert(id) }
                            MediaPreferences.shared.setLayout(value, scope: app.preferenceScope, mode: mode)
                        }))
                    }.onMove { offsets, target in
                        var value = layout; value.order.move(fromOffsets: offsets, toOffset: target)
                        MediaPreferences.shared.setLayout(value, scope: app.preferenceScope, mode: mode)
                    }
                }
                Button("Restore Default Layout") { MediaPreferences.shared.setLayout(.init(order: MediaPreferences.homeSections(mode)), scope: app.preferenceScope, mode: mode) }
            }.environment(\.editMode, .constant(.active))
                .pageTitle("Customize \(mode.title)")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct PlaybackPreferencesView: View {
    private var prefs: MediaPreferences { .shared }
    @AppStorage(BuiltInPlayer.preferenceKey) private var builtInPlayer = true
    @AppStorage(VolumeLeveling.preferenceKey) private var evenOutVolume = true
    var body: some View {
        Form {
            Section("Music") {
                Picker("Streaming Quality", selection: Binding(get: { prefs.musicBitrate }, set: { prefs.musicBitrate = $0 })) {
                    Text("Original").tag(0)
                    ForEach([320, 192, 128], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Toggle("Stream over Cellular", isOn: Binding(get: { prefs.allowsCellular(.music) }, set: { prefs.setCellular($0, mode: .music) }))
                Picker("Crossfade", selection: Binding(get: { prefs.musicCrossfadeSeconds }, set: { prefs.musicCrossfadeSeconds = $0 })) {
                    ForEach(Crossfade.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
                if prefs.musicCrossfadeSeconds == 0 {
                    Picker("Fade Between Songs", selection: Binding(get: { prefs.musicFadeSeconds }, set: { prefs.musicFadeSeconds = $0 })) {
                        ForEach(SongFades.choices, id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                    }
                }
                Toggle("Sound Check", isOn: Binding(get: { prefs.musicSoundCheck }, set: { prefs.musicSoundCheck = $0 }))
            }
            Section("Watch & Live TV") {
                Picker("Streaming Quality", selection: Binding(get: { prefs.videoQuality }, set: { prefs.videoQuality = $0 })) {
                    ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Stream over Cellular", isOn: Binding(get: { prefs.allowsCellular(.watch) }, set: { prefs.setCellular($0, mode: .watch) }))
            }
            Section {
                Toggle(isOn: Binding(get: { builtInPlayer && ProStore.shared.isUnlocked },
                                     set: { if ProStore.require(.builtInPlayer) { builtInPlayer = $0 } })) {
                    HStack { Text("Built-in Player for Other Formats"); ProBadge() }
                }
                if builtInPlayer && ProStore.shared.isUnlocked {
                    Toggle("Even Out Volume", isOn: $evenOutVolume)
                }
            }
        }.pageTitle("Playback Preferences")
    }
}

struct SleepTimerMenu: View {
    let player: AVPlayer
    var endLabel: String? = "End of Current Item"
    var body: some View {
        Menu {
            if PlaybackSleepTimer.shared.isSet(for: player) {
                if let deadline = PlaybackSleepTimer.shared.deadline { Text("Stops at \(deadline.formatted(date: .omitted, time: .shortened))") }
                else { Text("Stops at end of current item") }
                Button("Cancel Timer") { PlaybackSleepTimer.shared.cancel() }
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutes") { PlaybackSleepTimer.shared.set(minutes: minutes, player: player) }
            }
            if let endLabel { Button(endLabel) { PlaybackSleepTimer.shared.finishItem(player: player) } }
        } label: { Label("Sleep Timer", systemImage: PlaybackSleepTimer.shared.isSet(for: player) ? "moon.zzz.fill" : "moon.zzz") }
    }
}

struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = UIColor(Cinema.accent); return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct HandoffView: View {
    let item: PlexMetadata
    let serverID: String
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var players: [PlexPlayerTarget] = []
    @State private var loading = true
    @State private var sendingTo: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(players) { target in
                        Button { Task { await send(to: target) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: target)).font(.title3).frame(width: 28)
                                    .foregroundStyle(Cinema.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name).foregroundStyle(.primary)
                                    if let product = target.product { Text(product).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if sendingTo == target.id { ProgressView() }
                            }
                        }
                        .disabled(sendingTo != nil)
                    }
                    if loading {
                        HStack(spacing: 10) { ProgressView(); Text("Looking for Plex players…").foregroundStyle(.secondary) }
                    } else if players.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Plex players found").font(.subheadline.weight(.semibold))
                            Text("Open Plex or Plexamp on the TV, computer or phone you want to use, make sure it's on the same Wi-Fi, then pull down to look again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Continue on a Plex player")
                }
                Section("AirPlay") {
                    HStack { Text("Choose an audio or video output"); Spacer(); AirPlayPicker().frame(width: 44, height: 44) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Play on Another Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                        .accessibilityLabel("Look again")
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func icon(for target: PlexPlayerTarget) -> String {
        let product = (target.product ?? target.name).lowercased()
        if product.contains("plexamp") { return "hifispeaker" }
        if product.contains("tv") || product.contains("roku") || product.contains("shield") || product.contains("fire") { return "tv" }
        if product.contains("web") || product.contains("htpc") || product.contains("desktop") || product.contains("mac") { return "desktopcomputer" }
        return "play.rectangle"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let api = ServerDirectory.shared.api(for: serverID) else { error = "Server unavailable."; return }
        players = await PlayerDiscovery.discover(api: api, accountToken: Keychain.string(for: "accountToken"))
        error = nil
    }

    private func send(to target: PlexPlayerTarget) async {
        guard let api = ServerDirectory.shared.api(for: serverID) else { error = "Server unavailable."; return }
        sendingTo = target.id
        defer { sendingTo = nil }
        do {
            let sourceItem = player.currentItem
            let seconds = player.currentTime().seconds
            try await api.handoff(item, offset: seconds.isFinite ? Int(seconds * 1000) : 0, to: target)
            if player.currentItem === sourceItem { player.pause() }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlaylistEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State var title: String
    @State var items: [PlexMetadata]
    var onSaved: () -> Void
    @State private var original: [PlexMetadata] = []
    @State private var photo: PhotosPickerItem?
    @State private var artwork: Data?
    @State private var loadingArtwork = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("Playlist") {
                    TextField("Name", text: $title)
                    PhotosPicker(selection: $photo, matching: .images) { Label(artwork == nil ? "Choose Artwork" : "Artwork Selected", systemImage: "photo") }
                    if loadingArtwork { ProgressView("Loading artwork…") }
                    if let artwork, let image = UIImage(data: artwork) { Image(uiImage: image).resizable().scaledToFit().frame(height: 100) }
                }
                Section("Tracks / Videos") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item.title) }
                        .onDelete { items.remove(atOffsets: $0) }
                        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("Saving to Plex…") }
            }.environment(\.editMode, .constant(.active))
                .disabled(saving)
                .pageTitle("Edit Playlist")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || loadingArtwork || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .interactiveDismissDisabled(saving)
                .onAppear { original = items }
                .task(id: photo) {
                    guard let photo else { return }
                    loadingArtwork = true
                    defer { loadingArtwork = false }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw PlexError.unsupported("Couldn't read this image.") }
                        try Task.checkCancellation()
                        let scale = min(1, 1200 / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        artwork = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.85)
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
    private func save() async {
        guard let api = app.api else { error = "Connect to your server to edit playlists."; return }
        guard original.allSatisfy({ $0.playlistItemID != nil }) else { error = "This server did not provide playlist entry IDs. Refresh and try again."; return }
        saving = true; defer { saving = false }
        do {
            let current = try await api.playlistItems(id)
            guard current.map(\.playlistItemID) == original.map(\.playlistItemID) else {
                error = "This playlist changed on another device. Close the editor and refresh before editing again."; return
            }
            try await api.renamePlaylist(id, title: title)
            let kept = Set(items.compactMap(\.playlistItemID))
            for entry in original where !kept.contains(entry.playlistItemID!) { try await api.removePlaylistEntry(id, entryID: entry.playlistItemID!) }
            // Refresh the baseline after each mutation so retry never repeats successful deletes.
            original = original.filter { kept.contains($0.playlistItemID!) }
            var previous: String?
            for item in items {
                try await api.movePlaylistEntry(id, entryID: item.playlistItemID!, after: previous)
                previous = item.playlistItemID
            }
            if let artwork { try await api.uploadPlaylistArtwork(id, jpeg: artwork) }
            onSaved(); dismiss()
        } catch {
            if let refreshed = try? await api.playlistItems(id) { original = refreshed }
            self.error = "Some changes may have saved. \(error.localizedDescription)"
            onSaved()
        }
    }
}

/// Open-source software in LotsOfMedia and its licenses.
struct AcknowledgementsView: View {
    private var lgpl: String {
        Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VLCKit 3.7.3").font(.headline)
                    Text("The built-in video player uses VLCKit by VideoLAN and the VLC authors, licensed under the GNU Lesser General Public License, version 2.1.")
                    Text("VLCKit is included unmodified as a separate dynamic framework (MobileVLCKit.framework), which can be replaced with your own build. Its complete source code is available at:")
                    Link("code.videolan.org/videolan/VLCKit", destination: URL(string: "https://code.videolan.org/videolan/VLCKit")!)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }
            Section("GNU Lesser General Public License 2.1") {
                Text(lgpl).font(.caption2.monospaced()).textSelection(.enabled)
            }
        }
        .pageTitle("Acknowledgements")
    }
}
