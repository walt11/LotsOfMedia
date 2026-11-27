import Intents
import UIKit

/// "Hey Siri, play <playlist / artist / album / song> in LotsOfMedia" — handled
/// inside the app, which iOS starts in the background if it isn't running.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        guard let match = await SiriMedia.find(intent.mediaSearch) else {
            return [.unsupported()]
        }
        return INPlayMediaMediaItemResolutionResult.successes(with: [match.mediaItem])
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let started = await SiriMedia.play(intent.mediaItems?.first, shuffle: intent.playShuffled ?? false)
        return INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil)
    }
}

@MainActor
enum SiriMedia {
    enum Kind: String { case playlist, artist, album, track, library }

    struct Match {
        let kind: Kind
        let item: PlexMetadata?
        var mediaItem: INMediaItem {
            let type: INMediaItemType
            switch kind {
            case .playlist: type = .playlist
            case .artist: type = .artist
            case .album: type = .album
            case .track: type = .song
            case .library: type = .music
            }
            return INMediaItem(identifier: "\(kind.rawValue):\(item?.ratingKey ?? "")", title: item?.title ?? "Your Library",
                               type: type, artwork: nil, artist: item?.grandparentTitle ?? item?.parentTitle)
        }
    }

    /// What was asked for: a named playlist, artist, album or song; with no name ("play music"), the whole library.
    static func find(_ search: INMediaSearch?) async -> Match? {
        guard let api = await StandaloneServer.connect() ?? StandaloneServer.api else { return nil }
        let name = search?.mediaName ?? search?.albumName ?? search?.artistName
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return Match(kind: .library, item: nil) }
        let wanted = kind(for: search?.mediaType, search: search)

        var candidates: [PlexMetadata] = []
        if wanted == nil || wanted == .playlist {
            candidates += ((try? await api.playlists()) ?? []).filter { $0.playlistType == "audio" }
        }
        if wanted != .playlist {
            let hubs = (try? await api.search(name)) ?? []
            candidates += hubs.flatMap(\.metadata).filter { [.artist, .album, .track].contains($0.kind) }
        }
        guard let best = best(for: name, artist: search?.artistName, wanted: wanted, in: candidates) else { return nil }
        return Match(kind: matchKind(best), item: best)
    }

    static func play(_ mediaItem: INMediaItem?, shuffle: Bool) async -> Bool {
        guard let identifier = mediaItem?.identifier,
              let colon = identifier.firstIndex(of: ":"),
              let kind = Kind(rawValue: String(identifier[..<colon])) else { return false }
        let key = String(identifier[identifier.index(after: colon)...])
        guard let api = await StandaloneServer.connect() ?? StandaloneServer.api, let sid = StandaloneServer.serverID else { return false }
        var tracks: [PlexMetadata] = []
        var shuffled = shuffle
        switch kind {
        case .playlist:
            tracks = (try? await api.playlistItems(key)) ?? []
            PlaylistPlays.record(key, serverID: sid)
        case .album: tracks = (try? await api.children(key)) ?? []
        case .artist: tracks = (try? await api.allLeaves(key)) ?? []; shuffled = true
        case .track:
            // The song, then more like it.
            if let song = (try? await api.metadata(key)) ?? nil { tracks = (try? await MusicRadio.tracks(seed: song, api: api)) ?? [song] }
        case .library:
            if let section = (try? await api.sections())?.first(where: { $0.type == "artist" }) {
                tracks = (try? await api.page("/library/sections/\(section.key)/all", start: 0, size: 200, query: [
                    URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "random"),
                ]).metadata) ?? []
            }
        }
        guard !tracks.isEmpty else { return false }
        AudioPlayer.shared.play(tracks, serverID: sid, shuffle: shuffled)
        return true
    }

    // MARK: Matching (pure, tested)

    nonisolated static func kind(for type: INMediaItemType?, search: INMediaSearch?) -> Kind? {
        switch type {
        case .playlist?: return .playlist
        case .artist?: return .artist
        case .album?: return .album
        case .song?: return .track
        default:
            // "Play <artist>" often arrives with only the artist name.
            if search?.mediaName == nil, search?.albumName == nil, search?.artistName != nil { return .artist }
            if search?.mediaName == nil, search?.albumName != nil { return .album }
            return nil
        }
    }

    nonisolated static func matchKind(_ item: PlexMetadata) -> Kind {
        switch item.kind {
        case .playlist: return .playlist
        case .artist: return .artist
        case .album: return .album
        default: return .track
        }
    }

    nonisolated static func normalized(_ s: String) -> String {
        // "Don't" matches "dont"; other punctuation separates words ("Road-Trip" = "road trip").
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0 != "'" && $0 != "’" }
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// The name as Siri might hear it either way: spaces and dots dropped, and spoken numbers
    /// as digits, so "HR 2", "H R 2", "H.R. Two" and "hr two" all match a playlist named "HR2".
    nonisolated static func compact(_ s: String) -> String {
        let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                       "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]
        return normalized(s).split(separator: " ").map { numbers[String($0)] ?? String($0) }.joined()
    }

    /// Exact title beats starts-with beats contains; the asked-for kind wins ties,
    /// then playlists, artists, albums, songs. An artist name narrows songs and albums.
    nonisolated static func best(for name: String, artist: String?, wanted: Kind?, in items: [PlexMetadata]) -> PlexMetadata? {
        let q = normalized(name)
        let a = artist.map(normalized)
        func score(_ m: PlexMetadata) -> Int? {
            let t = normalized(m.title)
            var s: Int
            if t == q { s = 300 } else if !q.isEmpty, compact(m.title) == compact(name) { s = 290 } else if t.hasPrefix(q) || q.hasPrefix(t) && !t.isEmpty { s = 200 } else if t.contains(q) { s = 100 } else { return nil }
            let k = matchKind(m)
            if let wanted { if k == wanted { s += 50 } else if wanted != .track || k != .album { s -= 40 } }
            s += [Kind.playlist: 8, .artist: 6, .album: 4, .track: 2][k] ?? 0
            if let a, [.album, .track].contains(k), let by = m.grandparentTitle ?? m.parentTitle {
                s += normalized(by) == a ? 30 : -20
            }
            return s
        }
        return items.compactMap { m in score(m).map { (m, $0) } }.max { $0.1 < $1.1 }?.0
    }

    /// Lets Siri recognize unusual playlist and artist names.
    static func updateVocabulary(playlists: [PlexMetadata]) {
        let names = NSOrderedSet(array: playlists.map(\.title).prefix(100).map { $0 })
        INVocabulary.shared().setVocabularyStrings(names, of: .mediaPlaylistTitle)
    }
}
