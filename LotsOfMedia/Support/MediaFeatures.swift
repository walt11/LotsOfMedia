import Foundation
import Observation
import SwiftUI
import AVFoundation

@MainActor @Observable
final class MediaPreferences {
    static let shared = MediaPreferences()
    private let defaults: UserDefaults
    private var revision = 0
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    struct Favorite: Codable, Identifiable {
        var item: PlexMetadata
        var id: String { item.ratingKey }
    }
    nonisolated static func scope(user: String?, server: String?) -> String {
        // Length-prefixed components avoid collisions between profile/server IDs.
        [user ?? "local", server ?? "none"].map { "\($0.utf8.count):\($0)" }.joined()
    }
    func favorites(scope: String, mode: MediaMode) -> [PlexMetadata] {
        _ = revision
        return read([Favorite].self, key: "favorites." + scope, fallback: []).map(\.item).filter { mode.includes($0) }
    }
    func isFavorite(_ item: PlexMetadata, scope: String) -> Bool {
        _ = revision
        return read([Favorite].self, key: "favorites." + scope, fallback: []).contains { $0.id == item.ratingKey }
    }
    func toggle(_ item: PlexMetadata, scope: String) {
        var list = read([Favorite].self, key: "favorites." + scope, fallback: [])
        if list.contains(where: { $0.id == item.ratingKey }) { list.removeAll { $0.id == item.ratingKey } }
        else { list.insert(Favorite(item: item.trimmedForStorage()), at: 0) }
        save(list, key: "favorites." + scope)
        Haptics.tap()
    }
    // MARK: Watch Later (per profile and server, separate from Favorites)

    func watchLater(scope: String) -> [PlexMetadata] {
        _ = revision
        return read([Favorite].self, key: "watchLater." + scope, fallback: []).map(\.item)
    }
    func isInWatchLater(_ item: PlexMetadata, scope: String) -> Bool {
        watchLater(scope: scope).contains { $0.ratingKey == item.ratingKey }
    }
    func toggleWatchLater(_ item: PlexMetadata, scope: String) {
        var list = read([Favorite].self, key: "watchLater." + scope, fallback: [])
        if list.contains(where: { $0.id == item.ratingKey }) { list.removeAll { $0.id == item.ratingKey } }
        else { list.append(Favorite(item: item.trimmedForStorage())) }
        save(list, key: "watchLater." + scope)
        Haptics.tap()
    }
    func setWatchLater(_ items: [PlexMetadata], scope: String) {
        save(items.map { Favorite(item: $0.trimmedForStorage()) }, key: "watchLater." + scope)
    }
    /// Remove items from Watch Later once they've been watched (on by default).
    var watchLaterRemovesWatched: Bool {
        get { _ = revision; return defaults.object(forKey: "watchLater.autoRemove") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "watchLater.autoRemove"); revision += 1 }
    }
    /// Refreshes saved items with current server metadata; drops watched ones when asked.
    nonisolated static func refreshWatchLater(_ saved: [PlexMetadata], fresh: [String: PlexMetadata], removeWatched: Bool) -> [PlexMetadata] {
        saved.compactMap { item in
            let current = fresh[item.ratingKey] ?? item
            return removeWatched && current.isWatched ? nil : current
        }
    }

    /// Adds or removes several favorites with one save.
    func setFavorite(_ items: [PlexMetadata], on: Bool, scope: String) {
        var list = read([Favorite].self, key: "favorites." + scope, fallback: [])
        let keys = Set(items.map(\.ratingKey))
        list.removeAll { keys.contains($0.id) }
        if on { list.insert(contentsOf: items.map { Favorite(item: $0.trimmedForStorage()) }, at: 0) }
        save(list, key: "favorites." + scope)
    }

    // MARK: Remembered languages (per profile)

    /// ISO 639-2 code ("eng"), or nil when there's no preference yet.
    func preferredAudioLanguage(scope: String) -> String? {
        _ = revision; return defaults.string(forKey: "lang.audio." + scope)
    }
    /// ISO 639-2 code, "off", or nil when there's no preference yet.
    func preferredSubtitleLanguage(scope: String) -> String? {
        _ = revision; return defaults.string(forKey: "lang.subtitle." + scope)
    }
    func rememberAudio(languageCode code: String?, scope: String) {
        guard let code, !code.isEmpty else { return }
        defaults.set(code, forKey: "lang.audio." + scope); revision += 1
    }
    /// `nil` means subtitles were turned off.
    func rememberSubtitle(languageCode code: String?, scope: String) {
        if let code { guard !code.isEmpty else { return }; defaults.set(code, forKey: "lang.subtitle." + scope) }
        else { defaults.set("off", forKey: "lang.subtitle." + scope) }
        revision += 1
    }
    func clearLanguagePreferences(scope: String) {
        defaults.removeObject(forKey: "lang.audio." + scope)
        defaults.removeObject(forKey: "lang.subtitle." + scope)
        revision += 1
    }

    struct HomeLayout: Codable, Equatable {
        var order: [String]
        var hidden: Set<String> = []
        func normalized(defaults: [String]) -> HomeLayout {
            var seen = Set<String>()
            var result = order.filter { defaults.contains($0) && seen.insert($0).inserted }
            // Sections added in an update go right after the section they follow by default.
            for (i, id) in defaults.enumerated() where !seen.contains(id) {
                let anchor = defaults[..<i].last { result.contains($0) }
                // Nothing to follow: append, so the user's chosen first section stays first.
                let at = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? result.count
                result.insert(id, at: at)
                seen.insert(id)
            }
            return HomeLayout(order: result, hidden: hidden.intersection(defaults))
        }
    }
    static func homeSections(_ mode: MediaMode) -> [String] {
        mode == .music ? ["shortcuts", "recent", "playlists", "mixes", "albums", "favorites", "recommendations"] : ["resume", "watchLater", "recent", "next", "favorites", "recommendations", "featured"]
    }
    /// A calm Home to start with; the rest can be turned on in Customize Home.
    static func hiddenByDefault(_ mode: MediaMode) -> Set<String> {
        mode == .music ? ["shortcuts", "favorites", "recommendations"] : ["featured"]
    }
    static func sectionTitle(_ id: String, mode: MediaMode) -> String {
        switch id {
        case "shortcuts": return "Library Shortcuts"
        case "recent": return mode == .music ? "Recently Played" : "Recently Added"
        case "resume": return "Continue Watching"
        case "albums": return "New Albums"
        case "next": return "Next Episodes"
        case "favorites": return "Favorites"
        case "watchLater": return "Watch Later"
        case "mixes": return "Mixes"
        case "playlists": return "Playlists"
        case "featured": return "Featured Artwork"
        default: return "Recommendations"
        }
    }
    func layout(scope: String, mode: MediaMode) -> HomeLayout {
        _ = revision
        let defaults = Self.homeSections(mode)
        let fallback = HomeLayout(order: defaults, hidden: Self.hiddenByDefault(mode))
        return read(HomeLayout.self, key: "home.\(scope).\(mode.rawValue)", fallback: fallback).normalized(defaults: defaults)
    }
    func setLayout(_ layout: HomeLayout, scope: String, mode: MediaMode) { save(layout, key: "home.\(scope).\(mode.rawValue)") }
    var musicBitrate: Int {
        get { _ = revision; return defaults.integer(forKey: "playback.music.bitrate") }
        set { defaults.set(newValue, forKey: "playback.music.bitrate"); revision += 1 }
    }
    /// Seconds of fade-in/out between songs (0 = off; songs still change without a gap).
    var musicFadeSeconds: Int {
        get { _ = revision; return defaults.integer(forKey: "playback.music.fade") }
        set { defaults.set(newValue, forKey: "playback.music.fade"); revision += 1 }
    }
    /// Seconds songs overlap as one fades into the next (0 = off; replaces fades when on).
    var musicCrossfadeSeconds: Int {
        get { _ = revision; return defaults.integer(forKey: "playback.music.crossfade") }
        set { defaults.set(newValue, forKey: "playback.music.crossfade"); revision += 1 }
    }
    /// Sound Check: songs play at a consistent volume using the server's loudness analysis.
    var musicSoundCheck: Bool {
        get { _ = revision; return defaults.bool(forKey: "playback.music.soundCheck") }
        set { defaults.set(newValue, forKey: "playback.music.soundCheck"); revision += 1 }
    }
    var videoQuality: StreamingQuality {
        get { _ = revision; return StreamingQuality(rawValue: defaults.string(forKey: "streamingQuality") ?? "") ?? .original }
        set { defaults.set(newValue.rawValue, forKey: "streamingQuality"); revision += 1 }
    }
    func allowsCellular(_ mode: MediaMode) -> Bool {
        _ = revision; return defaults.object(forKey: "playback.\(mode.rawValue).cellular") as? Bool ?? true
    }
    func setCellular(_ allowed: Bool, mode: MediaMode) { defaults.set(allowed, forKey: "playback.\(mode.rawValue).cellular"); revision += 1 }
    func streamAllowed(_ mode: MediaMode) -> Bool { NetworkMonitor.shared.usesWiFi || allowsCellular(mode) }
    /// Decoded lists by key: "is this a favorite?" runs per row, so it mustn't decode JSON each time.
    @ObservationIgnored private var decoded: [String: Any] = [:]

    private func read<T: Decodable>(_ type: T.Type, key: String, fallback: T) -> T {
        if let cached = decoded[key] as? T { return cached }
        guard let data = defaults.data(forKey: key) else { return fallback }
        let value = (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
        decoded[key] = value
        return value
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
            decoded[key] = value
            revision += 1
        }
    }
}

extension AppState {
    var preferenceScope: String { MediaPreferences.scope(user: currentUserID, server: selectedServerID) }
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    var label: String { self == .off ? "Repeat Off" : self == .all ? "Repeat Queue" : "Repeat Song" }
    func nextIndex(current: Int, count: Int, naturalEnd: Bool) -> Int? {
        guard count > 0, (0..<count).contains(current) else { return nil }
        if self == .one && naturalEnd { return current }
        if current + 1 < count { return current + 1 }
        return self == .all ? 0 : nil
    }
}

@MainActor @Observable
final class PlaybackSleepTimer {
    static let shared = PlaybackSleepTimer()
    private(set) var deadline: Date?
    private(set) var atEnd = false
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?
    func isSet(for player: AVPlayer) -> Bool { self.player === player && (deadline != nil || atEnd) }
    func set(minutes: Int, player: AVPlayer) {
        cancel(); self.player = player
        deadline = Date().addingTimeInterval(Double(minutes) * 60)
        task = Task { [weak self, weak player] in
            do { try await Task.sleep(for: .seconds(Double(minutes) * 60)) } catch { return }
            guard let self, let player, self.player === player else { return }
            player.pause(); self.cancel()
        }
    }
    func endsWithItem(for player: AVPlayer) -> Bool { self.player === player && atEnd }
    func finishItem(player: AVPlayer) { cancel(); self.player = player; atEnd = true }
    func consumeEnd(for player: AVPlayer) -> Bool {
        guard self.player === player, atEnd else { return false }
        player.pause(); cancel(); return true
    }
    func cancel() { task?.cancel(); task = nil; deadline = nil; atEnd = false; player = nil }
}

struct LibrarySongFilter {
    static func matches(_ item: PlexMetadata, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let haystack = [item.title, item.grandparentTitle ?? "", item.parentTitle ?? ""].joined(separator: " ")
        return tokens.allSatisfy { haystack.localizedStandardContains($0) }
    }
}

struct DownloadPlan {
    let count: Int
    let knownBytes: Int64
    let unknownCount: Int
    let estimated: Bool
    init(items: [PlexMetadata], quality: DownloadQuality) {
        var seen = Set<String>()
        let items = items.filter { seen.insert($0.ratingKey).inserted }
        count = items.count
        var sum: Int64 = 0, unknown = 0
        var estimated = false
        for item in items {
            let effective = quality.isReduction(of: item.primaryMedia) ? quality : .original
            if item.kind != .track, let target = effective.transcodeTarget, let duration = item.duration, duration > 0 {
                sum += Int64(Double(target.bitrate) * Double(duration) / 8); estimated = true
            } else if let bytes = item.primaryPart?.size, bytes >= 0 {
                sum += bytes
                if let media = item.primaryMedia, PlaybackDecider.conversionReason(media: media, kind: item.kind, quality: effective) != nil { estimated = true }
            } else { unknown += 1 }
        }
        knownBytes = sum; unknownCount = unknown; self.estimated = estimated
    }
    var sizeLabel: String {
        if count == 0 { return "No items" }
        if unknownCount == count { return "Size unavailable for \(count) items" }
        return (estimated ? "About " : "") + Fmt.bytes(knownBytes) + (unknownCount > 0 ? " + \(unknownCount) unknown" : "")
    }
}


// MARK: - Music mixes

/// Rule-based song collections built from the library and this device.
enum MusicMix: String, CaseIterable, Identifiable, Hashable {
    case favoritesNotRecent, recentlyAdded, downloaded, mostPlayed, rediscover
    var id: String { rawValue }

    var title: String {
        switch self {
        case .favoritesNotRecent: return "Favorites to Revisit"
        case .recentlyAdded: return "Recently Added"
        case .downloaded: return "Downloaded Songs"
        case .mostPlayed: return "Most Played"
        case .rediscover: return "Rediscover"
        }
    }
    var subtitle: String {
        switch self {
        case .favoritesNotRecent: return "Favorites you haven't played in a month"
        case .recentlyAdded: return "The newest songs in your library"
        case .downloaded: return "Only songs saved on this iPhone"
        case .mostPlayed: return "Your most-played songs"
        case .rediscover: return "Played often, but not for three months"
        }
    }
    var icon: String {
        switch self {
        case .favoritesNotRecent: return "heart.circle"
        case .recentlyAdded: return "sparkles"
        case .downloaded: return "arrow.down.circle"
        case .mostPlayed: return "flame"
        case .rediscover: return "clock.arrow.circlepath"
        }
    }
    /// Works with no connection.
    var isOffline: Bool { self == .downloaded }

    static let limit = 100
    static let day: TimeInterval = 86_400

    static func notPlayedSince(_ tracks: [PlexMetadata], days: Double, now: Date) -> [PlexMetadata] {
        let cutoff = now.timeIntervalSince1970 - days * day
        return tracks.filter { t in (t.lastViewedAt.map { Double($0) < cutoff }) ?? true }
    }
    static func mostPlayed(_ tracks: [PlexMetadata]) -> [PlexMetadata] {
        tracks.filter { ($0.viewCount ?? 0) > 0 }.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
    }
    static func rediscover(_ tracks: [PlexMetadata], now: Date) -> [PlexMetadata] {
        notPlayedSince(mostPlayed(tracks), days: 90, now: now)
    }
    static func unique(_ tracks: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        return tracks.filter { $0.kind == .track && seen.insert($0.ratingKey).inserted }
    }
}

@MainActor
enum MusicMixLoader {
    static func load(_ mix: MusicMix, app: AppState, now: Date = Date()) async throws -> [PlexMetadata] {
        try await load(mix, api: app.browseAPI, serverID: app.selectedServerID ?? "", scope: app.preferenceScope, now: now)
    }

    /// Without the phone UI (CarPlay): the server, its API and the profile's preference scope passed in.
    static func load(_ mix: MusicMix, api: PlexServerAPI?, serverID sid: String, scope: String, now: Date = Date()) async throws -> [PlexMetadata] {
        if mix == .downloaded {
            return DownloadManager.shared.records
                .filter { $0.serverID == sid && $0.isAudio && $0.state == .completed }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .map(\.metadata)
        }
        guard let api else { throw PlexError.noServer }
        if mix == .favoritesNotRecent {
            var tracks: [PlexMetadata] = []
            for fav in MediaPreferences.shared.favorites(scope: scope, mode: .music) {
                if fav.kind == .track { tracks.append(fav) }
                else if [.album, .artist].contains(fav.kind) { tracks += (try? await api.allLeaves(fav.ratingKey)) ?? [] }
                if tracks.count > 1000 { break }
            }
            // Saved favorites carry old play counts; use the server's current ones.
            let fresh = try await freshen(MusicMix.unique(tracks), api: api)
            return Array(MusicMix.notPlayedSince(fresh, days: 30, now: now).shuffled().prefix(MusicMix.limit))
        }
        let sections = try await api.sections().filter { $0.type == "artist" }
        var songs: [PlexMetadata] = []
        for section in sections {
            let sort: String
            switch mix {
            case .recentlyAdded: sort = "addedAt:desc"
            default: sort = "viewCount:desc"
            }
            songs += try await api.page("/library/sections/\(section.key)/all", start: 0, size: mix == .recentlyAdded ? MusicMix.limit : 500,
                                        query: [URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: sort)]).metadata
        }
        songs = MusicMix.unique(songs)
        switch mix {
        case .recentlyAdded: return Array(songs.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(MusicMix.limit))
        case .mostPlayed: return Array(MusicMix.mostPlayed(songs).prefix(MusicMix.limit))
        case .rediscover: return Array(MusicMix.rediscover(songs, now: now).prefix(MusicMix.limit))
        default: return []
        }
    }

    private static func freshen(_ tracks: [PlexMetadata], api: PlexServerAPI) async throws -> [PlexMetadata] {
        var fresh: [String: PlexMetadata] = [:]
        for start in stride(from: 0, to: tracks.count, by: 50) {
            let keys = tracks[start..<min(start + 50, tracks.count)].map(\.ratingKey).joined(separator: ",")
            for item in (try? await api.container("/library/metadata/\(keys)").metadata) ?? [] { fresh[item.ratingKey] = item }
        }
        return tracks.map { fresh[$0.ratingKey] ?? $0 }
    }
}
