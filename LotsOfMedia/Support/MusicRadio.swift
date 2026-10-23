import Foundation

/// "Start Radio": a long queue of music like one song.
enum MusicRadio {
    static let length = 60

    /// The seed first, then similar songs. Uses Plex's sonic analysis when the server has it;
    /// otherwise the same artist, similar artists in the library and the artist's genres.
    static func tracks(seed: PlexMetadata, api: PlexServerAPI) async throws -> [PlexMetadata] {
        let sonic = (try? await api.container("/library/metadata/\(seed.ratingKey)/nearest", query: [
            URLQueryItem(name: "limit", value: "\(length)"),
            URLQueryItem(name: "maxDistance", value: "0.25"),
        ]).metadata) ?? []
        if sonic.filter({ $0.kind == .track }).count >= 10 {
            return assemble(seed: seed, similar: sonic.shuffled())
        }

        // Tracks from some lists don't say which library they're in; use the first music library.
        var section = seed.librarySectionID.map(String.init)
        if section == nil { section = (try? await api.sections())?.first { $0.type == "artist" }?.key }

        var sameArtist: [PlexMetadata] = []
        var similarArtists: [PlexMetadata] = []
        var sameGenre: [PlexMetadata] = []
        if let artistKey = seed.grandparentRatingKey {
            sameArtist = Array(((try? await api.allLeaves(artistKey)) ?? []).shuffled().prefix(length / 4))
            // Similar artists that are in this library.
            let similar = ((try? await api.container("/library/metadata/\(artistKey)/similar").metadata) ?? [])
                .filter { $0.kind == .artist }.shuffled().prefix(6)
            for artist in similar {
                similarArtists += ((try? await api.allLeaves(artist.ratingKey)) ?? []).shuffled().prefix(8)
            }
            // Songs by artists sharing this artist's genres.
            if let section, let artist = (try? await api.metadata(artistKey)) ?? nil {
                for filter in artist.genres.compactMap(\.filter).prefix(2) {
                    let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    sameGenre += (try? await api.page("/library/sections/\(section)/all", start: 0, size: length, query: [
                        URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "random"),
                        URLQueryItem(name: "artist.\(parts[0])", value: parts[1]),
                    ]).metadata) ?? []
                }
            }
        }
        var others = interleave(similarArtists.shuffled(), sameGenre)
        if others.count + sameArtist.count < length / 2, let section {
            // Nothing to go on: fill from the whole library.
            others += (try? await api.page("/library/sections/\(section)/all", start: 0, size: length, query: [
                URLQueryItem(name: "type", value: "10"), URLQueryItem(name: "sort", value: "random"),
            ]).metadata) ?? []
        }
        return assemble(seed: seed, similar: interleave(sameArtist, others))
    }

    /// Seed first, then unique songs (never the seed again), capped at `length`.
    static func assemble(seed: PlexMetadata, similar: [PlexMetadata]) -> [PlexMetadata] {
        var seen: Set<String> = [seed.ratingKey]
        let rest = similar.filter { $0.kind == .track && seen.insert($0.ratingKey).inserted }
        return [seed] + rest.prefix(length - 1)
    }

    /// Two from `others`, then one from `first`, repeating; leftovers follow.
    static func interleave(_ first: [PlexMetadata], _ others: [PlexMetadata]) -> [PlexMetadata] {
        var out: [PlexMetadata] = []
        var a = first.makeIterator(), o = others.makeIterator()
        var aDone = false, oDone = false
        while !(aDone && oDone) {
            for _ in 0..<2 { if let x = o.next() { out.append(x) } else { oDone = true } }
            if let x = a.next() { out.append(x) } else { aDone = true }
        }
        return out
    }
}

extension AppState {
    /// Plays a radio station built from one song.
    func startRadio(from track: PlexMetadata) async {
        guard ProStore.require(.radio) else { return }
        guard let api = browseAPI, let sid = selectedServerID,
              let tracks = try? await MusicRadio.tracks(seed: track, api: api), !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks, serverID: sid)
    }
}

/// When playlists were last played in this app. LotsOfMedia plays a playlist song by song,
/// so the server never updates the playlist's own "last played" date; this fills that in
/// (per profile and server) for Recently Played and the Playlists row.
enum PlaylistPlays {
    private static func key(serverID: String) -> String {
        "playlistPlays." + MediaPreferences.scope(user: UserDefaults.standard.string(forKey: "currentUserUUID"), server: serverID)
    }

    static func record(_ ratingKey: String, serverID: String, at date: Date = Date()) {
        var plays = UserDefaults.standard.dictionary(forKey: key(serverID: serverID)) as? [String: Int] ?? [:]
        plays[ratingKey] = Int(date.timeIntervalSince1970)
        UserDefaults.standard.set(plays, forKey: key(serverID: serverID))
    }

    /// The playlists with `lastViewedAt` set to whichever is newer: the server's or this app's.
    static func applying(to playlists: [PlexMetadata], serverID: String) -> [PlexMetadata] {
        let plays = UserDefaults.standard.dictionary(forKey: key(serverID: serverID)) as? [String: Int] ?? [:]
        return playlists.map { p in
            guard let local = plays[p.ratingKey], local > (p.lastViewedAt ?? 0) else { return p }
            var copy = p
            copy.lastViewedAt = local
            return copy
        }
    }
}

/// Albums and songs the user explicitly chose to play (not auto-played from a playlist).
/// Playlist plays already appear via PlaylistPlays; this keeps the album side of Recently
/// Played free of albums that only showed up because one of their songs was in a playlist.
enum ManualPlays {
    struct Play: Codable {
        let albumKey: String
        let title: String
        let art: String?
        let timestamp: Int
        /// The song picked, when a song (not the whole album) was played.
        var song: String? = nil
    }

    private static func key(serverID: String) -> String {
        "manualPlays." + MediaPreferences.scope(user: UserDefaults.standard.string(forKey: "currentUserUUID"), server: serverID)
    }

    static func record(albumKey: String, title: String, art: String?, song: String? = nil, serverID: String) {
        var plays = recent(serverID: serverID)
        plays.removeAll { $0.albumKey == albumKey }
        plays.insert(Play(albumKey: albumKey, title: title, art: art, timestamp: Int(Date().timeIntervalSince1970), song: song), at: 0)
        plays = Array(plays.prefix(20))
        if let data = try? JSONEncoder().encode(plays) {
            UserDefaults.standard.set(data, forKey: key(serverID: serverID))
        }
    }

    static func recent(serverID: String) -> [Play] {
        guard let data = UserDefaults.standard.data(forKey: key(serverID: serverID)) else { return [] }
        return (try? JSONDecoder().decode([Play].self, from: data)) ?? []
    }
}
