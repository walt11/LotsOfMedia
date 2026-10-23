import CarPlay
import UIKit

/// CarPlay audio app: Home, Library, Playlists and Downloads, playing through
/// the shared AudioPlayer (which already feeds Now Playing).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated {
            DownloadManager.shared.start()
            let c = CarPlayController(interface: interfaceController)
            controller = c
            c.start()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        MainActor.assumeIsolated { controller?.stop() }
        controller = nil
    }
}

/// Groups an A–Z list by first letter (of the sort title, so "The Climb" is under C).
enum CarPlayAlphabet {
    static func letter(for item: PlexMetadata) -> String {
        let name = (item.titleSort ?? item.title).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let first = name.first(where: { !$0.isWhitespace }), first.isLetter, first.isASCII else { return "#" }
        return String(first).uppercased()
    }

    /// Letters in order of first appearance, "#" first; items keep their order within a letter.
    static func groups(_ items: [PlexMetadata]) -> [(letter: String, items: [PlexMetadata])] {
        var order: [String] = []
        var byLetter: [String: [PlexMetadata]] = [:]
        for item in items {
            let l = letter(for: item)
            if byLetter[l] == nil { order.append(l) }
            byLetter[l, default: []].append(item)
        }
        order.sort { a, b in a == "#" ? b != "#" : (b == "#" ? false : a < b) }
        return order.map { ($0, byLetter[$0] ?? []) }
    }
}

/// Shuffle and repeat for Now Playing, made once and handed back on every re-draw: new
/// instances each time made CarPlay flash the shuffle state while seeking.
@MainActor
final class CarPlayModeButtons {
    let shuffle = CPNowPlayingShuffleButton { _ in AudioPlayer.shared.toggleShuffle() }
    let repeatButton = CPNowPlayingRepeatButton { _ in
        let player = AudioPlayer.shared
        let all = RepeatMode.allCases
        player.repeatMode = all[(all.firstIndex(of: player.repeatMode)! + 1) % all.count]
    }
    var all: [CPNowPlayingButton] { [shuffle, repeatButton] }
}

@MainActor
final class CarPlayController: NSObject, CPNowPlayingTemplateObserver {
    private let interface: CPInterfaceController
    private let homeTemplate = CPListTemplate(title: "Home", sections: [])
    private let libraryTemplate = CPListTemplate(title: "Library", sections: [])
    private let playlistsTemplate = CPListTemplate(title: "Playlists", sections: [])
    private let downloadsTemplate = CPListTemplate(title: "Downloads", sections: [])
    private var tabs: CPTabBarTemplate?
    private var playlists: [PlexMetadata] = []
    private var recent: [PlexMetadata] = []
    private var recentlyAdded: [PlexMetadata] = []
    private var online = false
    private var stopped = false
    /// Song rows on screen, by rating key, so the playing one shows CarPlay's playing indicator.
    private var songRows: [String: NSHashTable<CPListItem>] = [:]
    private var proObserver: NSObjectProtocol?
    private let modeButtons = CarPlayModeButtons()

    init(interface: CPInterfaceController) { self.interface = interface }

    private var api: PlexServerAPI? { StandaloneServer.api }
    private var serverID: String? { StandaloneServer.serverID }
    private var maxItems: Int { CPListTemplate.maximumItemCount }
    private var player: AudioPlayer { .shared }

    func start() {
        guard ProStore.isUnlocked else { return showLocked() }
        homeTemplate.tabImage = UIImage(systemName: "house")
        libraryTemplate.tabImage = UIImage(systemName: "music.note.house")
        playlistsTemplate.tabImage = UIImage(systemName: "music.note.list")
        downloadsTemplate.tabImage = UIImage(systemName: "arrow.down.circle")
        let tabs = CPTabBarTemplate(templates: [homeTemplate, libraryTemplate, playlistsTemplate, downloadsTemplate])
        self.tabs = tabs
        interface.setRootTemplate(tabs, animated: false, completion: nil)
        setUpNowPlaying()
        loadDownloads()
        observeDownloads()
        Task { await reload() }
    }

    func stop() {
        stopped = true
        if let proObserver { NotificationCenter.default.removeObserver(proObserver) }
        CPNowPlayingTemplate.shared.remove(self)
    }

    /// CarPlay is part of Pro: a neutral note until it's unlocked, then the full app.
    /// (CarPlay guidelines: never ask a driver to pick up their iPhone.)
    private func showLocked() {
        let note = CPListItem(text: "CarPlay is included with LotsOfMedia Pro", detailText: nil,
                              image: UIImage(systemName: "sparkles"))
        let template = CPListTemplate(title: "LotsOfMedia", sections: [CPListSection(items: [note])])
        interface.setRootTemplate(template, animated: false, completion: nil)
        guard proObserver == nil else { return }
        proObserver = NotificationCenter.default.addObserver(forName: ProStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, ProStore.isUnlocked else { return }
                if let o = self.proObserver { NotificationCenter.default.removeObserver(o) }
                self.proObserver = nil
                self.start()
            }
        }
    }

    private func reload() async {
        for t in [libraryTemplate, playlistsTemplate] { showMessage("Connecting…", in: t) }
        loadHome()
        online = await StandaloneServer.connect(force: true) != nil
        async let played = loadRecentlyPlayed()
        async let added = loadRecentlyAdded()
        await loadLibrary()
        await loadPlaylists()
        recent = await played
        recentlyAdded = await added
        loadHome()
        // Nothing reachable and nothing cached: start where there's music.
        if !online, playlists.isEmpty, !downloadedTracks.isEmpty {
            tabs?.select(downloadsTemplate)
        }
    }

    // MARK: Home

    /// Now Playing, artwork rows (playlists, recently added and recently played albums, mixes),
    /// then recently played songs. Rebuilt when the song changes.
    private func loadHome() {
        var sections: [CPListSection] = []
        if let current = player.current {
            let track = current.track
            let li = CPListItem(text: player.isPlaying ? "Now Playing" : "Resume",
                                detailText: [track.title, track.grandparentTitle].compactMap { $0 }.joined(separator: " · "),
                                image: UIImage(systemName: player.isPlaying ? "waveform" : "play.circle.fill"))
            li.accessoryType = .disclosureIndicator
            li.handler = { [weak self] _, done in
                guard let self else { return done() }
                if !self.player.isPlaying { self.player.resume() }
                self.showNowPlaying()
                done()
            }
            Task { if let img = await self.artwork(track.parentThumb ?? track.thumb, serverID: current.serverID) { li.setImage(img) } }
            sections.append(CPListSection(items: [li]))
        }
        var tiles: [CPListTemplateItem] = []
        if !playlists.isEmpty { tiles.append(playlistTiles()) }
        if !recentlyAdded.isEmpty { tiles.append(albumTiles("Recently Added", albums: recentlyAdded)) }
        let playedAlbums = Self.recentlyPlayedAlbums(picked: ManualPlays.recent(serverID: serverID ?? ""), recentTracks: recent)
        if !playedAlbums.isEmpty { tiles.append(albumTiles("Recently Played", albums: playedAlbums)) }
        tiles.append(mixTiles(online: online))
        sections.append(CPListSection(items: tiles))
        if !recent.isEmpty {
            let list = recent
            let items = list.prefix(8).enumerated().map { i, t in
                trackItem(t) { [weak self] in self?.play(list, startAt: i, shuffle: false) }
            }
            sections.append(CPListSection(items: Array(items), header: "Recently Played", sectionIndexTitle: nil))
        }
        homeTemplate.updateSections(sections)
    }

    /// Recently Played albums, matching the phone: the albums picked to play (here or on the
    /// phone), and only before any were picked, the albums of recently played songs.
    static func recentlyPlayedAlbums(picked: [ManualPlays.Play], recentTracks: [PlexMetadata]) -> [PlexMetadata] {
        guard !picked.isEmpty else { return albums(of: recentTracks) }
        return picked.compactMap { play in
            var json: [String: Any] = ["ratingKey": play.albumKey, "type": "album", "title": play.title]
            if let art = play.art { json["thumb"] = art }
            guard let data = try? JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [json]]]) else { return nil }
            return try? PlexServerAPI.decodeContainer(data).metadata.first
        }
    }

    /// The albums of some songs, once each, in order (for Recently Played tiles).
    static func albums(of tracks: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        return tracks.compactMap { t -> PlexMetadata? in
            guard let key = t.parentRatingKey, seen.insert(key).inserted else { return nil }
            var album = t
            album.ratingKey = key
            album.type = "album"
            album.title = t.parentTitle ?? t.title
            album.parentTitle = t.grandparentTitle
            album.thumb = t.parentThumb ?? t.thumb
            return album
        }
    }

    /// Albums as artwork tiles: tap one to open it, or the row for the full list.
    private func albumTiles(_ title: String, albums: [PlexMetadata]) -> CPListImageRowItem {
        let shown = Array(albums.prefix(CPMaximumNumberOfGridImages))
        let placeholder = Self.symbolTile("square.stack")
        let row = Self.tileRow(title, tiles: shown.map { (placeholder, $0.title, $0.parentTitle) })
        row.handler = { [weak self] _, done in
            self?.pushAlbumList(title: title, albums: albums)
            done()
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            guard let self, shown.indices.contains(index) else { return done() }
            Task { await self.openAlbum(shown[index]); done() }
        }
        Task {
            var images = shown.map { _ in placeholder }
            for (i, a) in shown.enumerated() {
                if let img = await artwork(a.thumb) { images[i] = img; Self.setTileImages(images, in: row) }
            }
        }
        return row
    }

    private func openAlbum(_ album: PlexMetadata) async {
        guard let api else { return }
        let tracks = (try? await api.children(album.ratingKey)) ?? []
        guard !tracks.isEmpty else { return showAlert("This album is empty.") }
        pushTracks(title: album.title, tracks: tracks, numbered: true, album: album)
    }

    private func loadRecentlyAdded() async -> [PlexMetadata] {
        guard let api, let sections = try? await api.sections().filter({ $0.type == "artist" }) else { return [] }
        var albums: [PlexMetadata] = []
        for section in sections {
            albums += (try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 12, query: [
                URLQueryItem(name: "type", value: "9"), URLQueryItem(name: "sort", value: "addedAt:desc"),
            ]).metadata) ?? []
        }
        return Array(albums.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(12))
    }

    /// Most recently played playlists as artwork tiles.
    private func playlistTiles() -> CPListImageRowItem {
        let shown = Array(playlists.prefix(CPMaximumNumberOfGridImages))
        let placeholder = Self.symbolTile("music.note.list")
        let row = Self.tileRow("Playlists", tiles: shown.map { (placeholder, $0.title, $0.leafCount.map { "\($0) songs" }) })
        row.handler = { [weak self] _, done in
            if let self { self.tabs?.select(self.playlistsTemplate) }
            done()
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            guard let self, shown.indices.contains(index) else { return done() }
            Task { await self.openPlaylist(shown[index]); done() }
        }
        Task {
            var images = shown.map { _ in placeholder }
            for (i, p) in shown.enumerated() {
                if let img = await artwork(p.thumb ?? p.composite) { images[i] = img; Self.setTileImages(images, in: row) }
            }
        }
        return row
    }

    /// Mixes as tiles; without a connection only Downloaded Songs works.
    private func mixTiles(online: Bool) -> CPListImageRowItem {
        let mixes = MusicMix.allCases.filter { online || $0.isOffline }
        let row = Self.tileRow("Mixes", tiles: mixes.map { (Self.symbolTile($0.icon), $0.title, nil) })
        row.handler = { [weak self] _, done in
            guard let self else { return done() }
            let items = mixes.map { mix in
                self.row(mix.title, detail: mix.subtitle, icon: mix.icon) { [weak self] in await self?.openMix(mix) }
            }
            self.push(CPListTemplate(title: "Mixes", sections: [CPListSection(items: items)]))
            done()
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            guard let self, mixes.indices.contains(index) else { return done() }
            Task { await self.openMix(mixes[index]); done() }
        }
        return row
    }

    private func openMix(_ mix: MusicMix) async {
        let tracks = (try? await MusicMixLoader.load(mix, api: api, serverID: serverID ?? "", scope: StandaloneServer.scope)) ?? []
        guard !tracks.isEmpty else { return showAlert(mix.isOffline ? "No downloaded songs yet." : "This mix is empty right now.") }
        pushTracks(title: mix.title, tracks: tracks)
    }

    private func loadRecentlyPlayed() async -> [PlexMetadata] {
        guard let api, let sections = try? await api.sections().filter({ $0.type == "artist" }) else { return [] }
        var played: [PlexMetadata] = []
        for section in sections {
            played += ((try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 16, query: [
                URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "lastViewedAt:desc"),
            ]).metadata) ?? []).filter { $0.kind == .track && ($0.lastViewedAt ?? 0) > 0 }
        }
        return Array(played.sorted { ($0.lastViewedAt ?? 0) > ($1.lastViewedAt ?? 0) }.prefix(12))
    }

    // MARK: Library

    private func loadLibrary() async {
        guard let api else { return showMessage("Sign in to LotsOfMedia on your iPhone first.", in: libraryTemplate) }
        guard let all = try? await api.sections() else { return showUnavailable("your libraries", in: libraryTemplate) }
        let sections = all.filter { $0.type == "artist" }
        guard !sections.isEmpty else { return showMessage("No music libraries found.", in: libraryTemplate) }
        let listSections = sections.map { section in
            CPListSection(items: [
                row("Recently Added", icon: "sparkles") { [weak self] in
                    await self?.pushAlbums(title: "Recently Added", path: "/library/sections/\(section.key)/all",
                                           query: [URLQueryItem(name: "type", value: "9"), URLQueryItem(name: "sort", value: "addedAt:desc")])
                },
                row("Artists", icon: "music.mic") { [weak self] in await self?.pushAlphabetical(section: section, type: 8, title: "Artists") },
                row("Albums", icon: "square.stack") { [weak self] in await self?.pushAlphabetical(section: section, type: 9, title: "Albums") },
                row("Songs", icon: "music.note") { [weak self] in await self?.pushAlphabetical(section: section, type: 10, title: "Songs") },
                row("Shuffle Library", icon: "shuffle") { [weak self] in
                    guard let self, let api = self.api else { return }
                    let tracks = (try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 200, query: [
                        URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "random"),
                    ]).metadata) ?? []
                    self.play(tracks, startAt: nil, shuffle: true)
                },
            ], header: sections.count > 1 ? section.title : nil, sectionIndexTitle: nil)
        }
        libraryTemplate.updateSections(listSections)
    }

    /// Artists, albums or songs A–Z. Short lists show at once with a letter index;
    /// long ones start with the letters so every name can be reached despite CarPlay's list cap.
    private func pushAlphabetical(section: PlexDirectory, type: Int, title: String) async {
        guard let api else { return }
        let all = (try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 5000, query: [
            URLQueryItem(name: "type", value: "\(type)"), URLQueryItem(name: "sort", value: "titleSort"),
        ]).metadata) ?? []
        guard !all.isEmpty else { return showAlert("Nothing here yet.") }
        let groups = CarPlayAlphabet.groups(all)
        if all.count < maxItems {
            if type == 10 { pushTracks(title: title, tracks: all) }
            else { push(CPListTemplate(title: title, sections: groups.map { CPListSection(items: $0.items.map(browseItem), header: $0.letter, sectionIndexTitle: $0.letter) })) }
            return
        }
        let rows = groups.map { group in
            row(group.letter, detail: "\(group.items.count)", icon: nil) { [weak self] in
                self?.pushList(type: type, title: "\(title) · \(group.letter)", items: group.items)
            }
        }
        push(CPListTemplate(title: title, sections: [CPListSection(items: Array(rows.prefix(maxItems)))]))
    }

    private func pushList(type: Int, title: String, items: [PlexMetadata]) {
        if type == 10 { pushTracks(title: title, tracks: items) }
        else { push(CPListTemplate(title: title, sections: [CPListSection(items: items.prefix(maxItems).map(browseItem))])) }
    }

    /// An artist or album row that opens its contents.
    private func browseItem(_ m: PlexMetadata) -> CPListItem {
        item(m, detail: m.kind == .album ? [m.parentTitle, m.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") : nil) { [weak self] in
            guard let self, let api = self.api else { return }
            if m.kind == .artist {
                let albums = (try? await api.children(m.ratingKey)) ?? []
                self.pushAlbumList(title: m.title, albums: albums, artistKey: m.ratingKey)
            } else {
                let tracks = (try? await api.children(m.ratingKey)) ?? []
                self.pushTracks(title: m.title, tracks: tracks, numbered: true, album: m)
            }
        }
    }

    // MARK: Playlists & Downloads

    private func loadPlaylists() async {
        guard let api else { return showMessage("Sign in to LotsOfMedia on your iPhone first.", in: playlistsTemplate) }
        guard let all = try? await api.playlists() else { return showUnavailable("playlists", in: playlistsTemplate) }
        playlists = MusicPlaylists.recentlyPlayedFirst(PlaylistPlays.applying(to: all, serverID: serverID ?? ""))
        SiriMedia.updateVocabulary(playlists: playlists)
        guard !playlists.isEmpty else { return showMessage("No music playlists.", in: playlistsTemplate) }
        let items = playlists.prefix(maxItems).map { p in
            item(p, detail: Self.playlistDetail(p)) { [weak self] in await self?.openPlaylist(p) }
        }
        playlistsTemplate.updateSections([CPListSection(items: Array(items))])
    }

    /// "24 songs · 1 hr 32 min"
    static func playlistDetail(_ p: PlexMetadata) -> String? {
        let count = p.leafCount.map { "\($0) song\($0 == 1 ? "" : "s")" }
        let length = p.duration.flatMap { ms -> String? in
            let minutes = ms / 60_000
            guard minutes > 0 else { return nil }
            return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
        }
        let parts = [count, length].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func openPlaylist(_ p: PlexMetadata) async {
        guard let api else { return }
        let tracks = (try? await api.playlistItems(p.ratingKey)) ?? []
        pushTracks(title: p.title, tracks: tracks, playlistKey: p.ratingKey)
    }

    private var downloadedTracks: [DownloadRecord] {
        DownloadManager.shared.records.filter { $0.state == .completed && $0.isAudio }
    }

    /// Downloads refresh as songs finish downloading or are removed.
    private func observeDownloads() {
        guard !stopped else { return }
        withObservationTracking {
            _ = DownloadManager.shared.records.filter { $0.state == .completed && $0.isAudio }.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.loadDownloads()
                self.observeDownloads()
            }
        }
    }

    private func loadDownloads() {
        let tracks = downloadedTracks
        guard !tracks.isEmpty else { return showMessage("No downloaded music.", in: downloadsTemplate) }
        let byArtist = Dictionary(grouping: tracks, by: \.offlineGroupID)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        var items: [CPListItem] = [row("Shuffle All", icon: "shuffle") { [weak self] in
            self?.playDownloads(tracks, shuffle: true)
        }]
        for (_, recs) in byArtist.prefix(maxItems - 1) {
            let artist = recs.first?.offlineGroupTitle ?? "Unknown Artist"
            let li = CPListItem(text: artist, detailText: "\(recs.count) song\(recs.count == 1 ? "" : "s")")
            li.accessoryType = .disclosureIndicator
            li.handler = { [weak self] _, done in
                let sorted = recs.sorted { ($0.metadata.parentTitle ?? "", $0.metadata.index ?? 0) < ($1.metadata.parentTitle ?? "", $1.metadata.index ?? 0) }
                self?.pushDownloadedTracks(title: artist, records: sorted)
                done()
            }
            // Decoded off the main thread; the row shows as soon as the list does.
            let poster = DownloadStore.posterURL(id: recs[0].id)
            Task.detached(priority: .utility) {
                guard let img = UIImage(contentsOfFile: poster.path)?.preparingForDisplay() else { return }
                await MainActor.run { li.setImage(img) }
            }
            items.append(li)
        }
        downloadsTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: Drill-down

    private func pushAlbums(title: String, path: String, query: [URLQueryItem]) async {
        guard let api, let albums = try? await api.page(path, start: 0, size: maxItems, query: query).metadata else { return }
        pushAlbumList(title: title, albums: albums)
    }

    private func pushAlbumList(title: String, albums: [PlexMetadata], artistKey: String? = nil) {
        var items: [CPListItem] = []
        if let artistKey {
            items.append(row("Shuffle \(title)", icon: "shuffle") { [weak self] in
                guard let self, let api = self.api else { return }
                self.play((try? await api.allLeaves(artistKey)) ?? [], startAt: nil, shuffle: true)
            })
        }
        items += albums.prefix(maxItems - items.count).map(browseItem)
        push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    /// `playlistKey`: playing from this list counts as playing that playlist.
    /// `album`: playing from this list counts as picking that album (Recently Played).
    private func pushTracks(title: String, tracks: [PlexMetadata], serverID: String? = nil, playlistKey: String? = nil,
                            numbered: Bool = false, album: PlexMetadata? = nil) {
        let playable = tracks.filter { $0.kind == .track }
        let recordAlbum: () -> Void = { [weak self] in
            guard let album, let sid = serverID ?? self?.serverID else { return }
            ManualPlays.record(albumKey: album.ratingKey, title: album.title, art: album.thumb, serverID: sid)
        }
        let play: (Int, Bool) -> Void = { [weak self] index, shuffle in
            guard let self else { return }
            recordAlbum()
            if let playlistKey { PlaylistPlays.record(playlistKey, serverID: serverID ?? self.serverID ?? "") }
            self.play(playable, startAt: shuffle ? nil : index, shuffle: shuffle, serverID: serverID)
        }
        var items: [CPListItem] = []
        if playable.count > 1 {
            // In order, even with shuffle on (a song picked below keeps shuffle on).
            items.append(row("Play", icon: "play.fill") { [weak self] in
                guard let self else { return }
                recordAlbum()
                if let playlistKey { PlaylistPlays.record(playlistKey, serverID: serverID ?? self.serverID ?? "") }
                self.play(playable, startAt: nil, shuffle: false, serverID: serverID)
            })
            items.append(row("Shuffle", icon: "shuffle") { play(0, true) })
        }
        for (i, t) in playable.prefix(maxItems - items.count).enumerated() {
            items.append(trackItem(t, number: numbered ? (t.index ?? i + 1) : nil) { play(i, false) })
        }
        push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }

    private func pushDownloadedTracks(title: String, records: [DownloadRecord]) {
        var rows = [row("Shuffle", icon: "shuffle") { [weak self] in self?.playDownloads(records, shuffle: true) }]
        for (index, rec) in records.prefix(maxItems - 1).enumerated() {
            let li = trackItem(rec.metadata, localArt: DownloadStore.posterURL(id: rec.id)) { [weak self] in
                self?.playDownloads(records, startAt: index)
            }
            rows.append(li)
        }
        push(CPListTemplate(title: title, sections: [CPListSection(items: rows)]))
    }

    // MARK: Now Playing

    private func setUpNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.add(self)
        np.isUpNextButtonEnabled = true
        np.upNextTitle = "Up Next"
        np.isAlbumArtistButtonEnabled = true
        updateNowPlayingButtons()
        observePlayer()
        observePlayState()
    }

    /// Shuffle, repeat, favorite and Start Radio. The heart follows the current song.
    private func updateNowPlayingButtons() {
        var buttons: [CPNowPlayingButton] = modeButtons.all
        if let track = player.current?.track {
            let fav = MediaPreferences.shared.isFavorite(track, scope: StandaloneServer.scope)
            if let image = UIImage(systemName: fav ? "heart.fill" : "heart") {
                buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                    MediaPreferences.shared.toggle(track, scope: StandaloneServer.scope)
                    self?.updateNowPlayingButtons()
                })
            }
            if NetworkMonitor.shared.isConnected, let image = UIImage(systemName: "dot.radiowaves.left.and.right") {
                buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in
                    Task { await self?.startRadio(from: track) }
                })
            }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    /// What re-draws the Now Playing buttons: only the song. Seeking and play/pause leave it
    /// alone, since every re-draw made CarPlay flash the shuffle button.
    static func buttonsKey(_ player: AudioPlayer) -> UUID? { player.current?.id }

    /// Re-draws the buttons when the song changes.
    private func observePlayer() {
        guard !stopped else { return }
        withObservationTracking {
            _ = Self.buttonsKey(player)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.updateNowPlayingButtons()
                self.updatePlayingIndicators()
                self.loadHome()
                self.observePlayer()
            }
        }
    }

    private func observePlayState() {
        guard !stopped else { return }
        withObservationTracking {
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.updatePlayingIndicators()
                self.loadHome()
                self.observePlayState()
            }
        }
    }

    private func startRadio(from track: PlexMetadata) async {
        guard let api = await StandaloneServer.connect() ?? api else { return }
        guard let tracks = try? await MusicRadio.tracks(seed: track, api: api), tracks.count > 1 else {
            return showAlert("Couldn't start radio for this song.")
        }
        play(tracks, startAt: 0, shuffle: false, serverID: player.current?.serverID)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            let upcoming = player.upcoming
            let base = player.queue.count - upcoming.count
            guard !upcoming.isEmpty else { return showAlert("Nothing else in the queue.") }
            let items = upcoming.prefix(maxItems).enumerated().map { i, entry in
                trackItem(entry.track) { [weak self] in self?.player.skip(to: base + i) }
            }
            push(CPListTemplate(title: "Up Next", sections: [CPListSection(items: Array(items))]))
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            guard let track = player.current?.track, let artistKey = track.grandparentRatingKey else { return }
            Task {
                guard let api = self.api else { return }
                let albums = (try? await api.children(artistKey)) ?? []
                guard !albums.isEmpty else { return }
                self.pushAlbumList(title: track.grandparentTitle ?? "Artist", albums: albums, artistKey: artistKey)
            }
        }
    }

    // MARK: Helpers

    private func play(_ tracks: [PlexMetadata], startAt: Int?, shuffle: Bool, serverID: String? = nil) {
        guard !tracks.isEmpty, let sid = serverID ?? self.serverID else { return }
        player.play(tracks, serverID: sid, startAt: startAt, shuffle: shuffle)
        showNowPlaying()
    }

    private func playDownloads(_ records: [DownloadRecord], startAt: Int? = nil, shuffle: Bool = false) {
        player.play(downloads: records, startAt: startAt, shuffle: shuffle)
        showNowPlaying()
    }

    private func showNowPlaying() {
        if !(interface.topTemplate is CPNowPlayingTemplate) {
            interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func push(_ template: CPTemplate) {
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    private func showAlert(_ text: String) {
        let alert = CPAlertTemplate(titleVariants: [text], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.interface.dismissTemplate(animated: true, completion: nil) },
        ])
        interface.presentTemplate(alert, animated: true, completion: nil)
    }

    /// Why server content isn't showing, with a way to try again.
    private func showUnavailable(_ what: String, in template: CPListTemplate) {
        let text: String
        if !NetworkMonitor.shared.isConnected {
            text = "No connection – your downloads are under Downloads."
        } else if StandaloneServer.liveAPI == nil {
            text = "Couldn't reach \(StandaloneServer.server?.name ?? "your server")."
        } else {
            text = "Couldn't load \(what)."
        }
        template.updateSections([CPListSection(items: [
            CPListItem(text: text, detailText: nil),
            row("Try Again", icon: "arrow.clockwise") { [weak self] in await self?.reload() },
        ])])
    }

    private func row(_ title: String, detail: String? = nil, icon: String?, action: @escaping @MainActor () async -> Void) -> CPListItem {
        let li = CPListItem(text: title, detailText: detail, image: icon.flatMap { UIImage(systemName: $0) })
        li.accessoryType = .disclosureIndicator
        li.handler = { _, done in
            Task { @MainActor in
                await action()
                done()
            }
        }
        return li
    }

    /// A song row: album art, "3. Title" when numbered, artist and length, and the playing
    /// indicator while it's the song playing.
    private func trackItem(_ t: PlexMetadata, number: Int? = nil, localArt: URL? = nil, action: @escaping @MainActor () -> Void) -> CPListItem {
        let li = CPListItem(text: number.map { "\($0). \(t.title)" } ?? t.title,
                            detailText: [t.grandparentTitle ?? t.originalTitle, Fmt.clock(seconds: Double(t.duration ?? 0) / 1000)]
                                .compactMap { $0 }.joined(separator: " · "))
        li.handler = { _, done in
            action()
            done()
        }
        li.playingIndicatorLocation = .trailing
        li.isPlaying = player.current?.track.ratingKey == t.ratingKey
        songRows[t.ratingKey, default: .weakObjects()].add(li)
        if let localArt, let img = UIImage(contentsOfFile: localArt.path) {
            li.setImage(img)
        } else {
            Task { if let img = await artwork(t.parentThumb ?? t.thumb) { li.setImage(img) } }
        }
        return li
    }

    /// Moves the playing indicator to the song now playing.
    private func updatePlayingIndicators() {
        let playing = player.current?.track.ratingKey
        for (key, rows) in songRows {
            for li in rows.allObjects { li.isPlaying = key == playing }
            if rows.allObjects.isEmpty { songRows[key] = nil }
        }
    }

    private func item(_ m: PlexMetadata, detail: String?, action: @escaping @MainActor () async -> Void) -> CPListItem {
        let li = CPListItem(text: m.title, detailText: detail)
        li.accessoryType = .disclosureIndicator
        li.handler = { _, done in
            Task { @MainActor in
                await action()
                done()
            }
        }
        Task { if let img = await artwork(m.thumb ?? m.composite) { li.setImage(img) } }
        return li
    }

    private func artwork(_ path: String?, serverID: String? = nil) async -> UIImage? {
        let source = serverID.flatMap { ServerDirectory.shared.api(for: $0) } ?? api
        guard let url = source?.imageURL(path, width: 160, height: 160) else { return nil }
        return await ImageLoader.shared.image(for: url)
    }

    /// A row of artwork tiles with a name under each (and a subtitle on iOS 26: artist or song
    /// count). iOS 17.4–25 shows names under the images; older versions show images only.
    static func tileRow(_ text: String, tiles: [(image: UIImage, title: String, subtitle: String?)]) -> CPListImageRowItem {
        if #available(iOS 26.0, *) {
            let elements = tiles.map { CPListImageRowItemRowElement(image: $0.image, title: $0.title, subtitle: $0.subtitle) }
            return CPListImageRowItem(text: text, elements: elements, allowsMultipleLines: false)
        } else if #available(iOS 17.4, *) {
            return CPListImageRowItem(text: text, images: tiles.map(\.image), imageTitles: tiles.map(\.title))
        } else {
            return CPListImageRowItem(text: text, images: tiles.map(\.image))
        }
    }

    /// Swaps in loaded artwork, keeping each tile's name.
    static func setTileImages(_ images: [UIImage], in row: CPListImageRowItem) {
        if #available(iOS 26.0, *) {
            for (element, image) in zip(row.elements, images) { element.image = image }
            row.elements = row.elements
        } else {
            row.update(images)
        }
    }

    /// A white symbol on a slate tile, for mixes and placeholders.
    static func symbolTile(_ name: String) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(AppTheme.surface).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 46, weight: .semibold)
            if let symbol = UIImage(systemName: name, withConfiguration: config)?.withTintColor(UIColor(AppTheme.accent), renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }

    private func showMessage(_ text: String, in template: CPListTemplate) {
        template.updateSections([CPListSection(items: [CPListItem(text: text, detailText: nil)])])
    }
}
