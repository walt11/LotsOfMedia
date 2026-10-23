import XCTest
import SwiftUI
@testable import LotsOfMedia

final class MusicStyleTests: XCTestCase {
    private func item(_ json: String) throws -> PlexMetadata { try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8)) }

    func testQuickAccessMixesPlaylistsAndAlbumsNewestFirst() throws {
        let playlist = try item(#"{"ratingKey":"p1","type":"playlist","title":"Road Trip","lastViewedAt":300}"#)
        let never = try item(#"{"ratingKey":"p2","type":"playlist","title":"Never Played"}"#)
        let t1 = try item(#"{"ratingKey":"t1","type":"track","title":"A","parentRatingKey":"al1","parentTitle":"Album One","lastViewedAt":400}"#)
        let t2 = try item(#"{"ratingKey":"t2","type":"track","title":"B","parentRatingKey":"al1","parentTitle":"Album One","lastViewedAt":350}"#)
        let t3 = try item(#"{"ratingKey":"t3","type":"track","title":"C","parentRatingKey":"al2","parentTitle":"Album Two","lastViewedAt":100}"#)
        // With no ManualPlays, recentTracks fills in as fallback.
        let quick = QuickAccessItem.make(playlists: [playlist, never], albumPlays: [], recentTracks: [t1, t2, t3])
        // One tile per album, unplayed playlists left out, newest first.
        XCTAssertEqual(quick.map(\.title), ["A", "Road Trip", "C"])
        XCTAssertEqual(quick.map(\.subtitle), ["Album One", nil, "Album Two"])
        XCTAssertEqual(QuickAccessItem.make(playlists: [playlist], albumPlays: [], recentTracks: [t1, t3], limit: 1).count, 1)
    }

    func testGenreColorsAreStable() {
        XCTAssertEqual(GenreTile.color(for: "Jazz"), GenreTile.color(for: "Jazz"))
    }

    func testGreyArtworkStaysGrey() {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Cinema.musicTint(from: UIColor(white: 0.5, alpha: 1))).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertLessThan(s, 0.15)
        UIColor(Cinema.musicTint(from: UIColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        XCTAssertGreaterThan(s, 0.45)
    }

    func testPlaylistsPlayedInTheAppCountAsRecentlyPlayed() throws {
        let server = "test-\(UUID())"
        let a = try item(#"{"ratingKey":"a","type":"playlist","title":"A","playlistType":"audio","lastViewedAt":500}"#)
        let b = try item(#"{"ratingKey":"b","type":"playlist","title":"B","playlistType":"audio"}"#)
        XCTAssertEqual(MusicPlaylists.recentlyPlayedFirst(PlaylistPlays.applying(to: [a, b], serverID: server)).map(\.ratingKey), ["a", "b"])
        // Played here just now: the server never saw it, but it moves to the front.
        PlaylistPlays.record("b", serverID: server)
        let sorted = MusicPlaylists.recentlyPlayedFirst(PlaylistPlays.applying(to: [a, b], serverID: server))
        XCTAssertEqual(sorted.map(\.ratingKey), ["b", "a"])
        XCTAssertEqual(QuickAccessItem.make(playlists: sorted, albumPlays: []).first?.title, "B")
        // An older local play never hides a newer server one.
        PlaylistPlays.record("a", serverID: server, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(PlaylistPlays.applying(to: [a], serverID: server).first?.lastViewedAt, 500)
    }
}

/// Recently Played: albums you picked, with server history only before any were picked.
final class RecentlyPlayedPicksTests: XCTestCase {
    private func track(_ key: String, album: String, title: String, at: Int) throws -> PlexMetadata {
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [[
            "ratingKey": key, "type": "track", "title": key, "parentRatingKey": album, "parentTitle": title, "lastViewedAt": at]]]])
        return try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
    }

    func testPickedAlbumsReplaceServerHistory() throws {
        let fromPlaylist = try track("t1", album: "pl-album", title: "Played by a Playlist", at: 900)
        let picked = [ManualPlays.Play(albumKey: "mine", title: "Picked Album", art: nil, timestamp: 500)]
        let quick = QuickAccessItem.make(playlists: [], albumPlays: picked, recentTracks: [fromPlaylist])
        XCTAssertEqual(quick.map(\.title), ["Picked Album"], "An album a playlist happened to play doesn't fill in")
    }

    func testServerHistoryOnlyBeforeAnyPicks() throws {
        let t = try track("t1", album: "a1", title: "History Album", at: 900)
        XCTAssertEqual(QuickAccessItem.make(playlists: [], albumPlays: [], recentTracks: [t]).map(\.title), ["t1"])
    }

    func testPickedSongShowsTheSongWithItsAlbum() {
        let picked = [ManualPlays.Play(albumKey: "a1", title: "The Album", art: nil, timestamp: 500, song: "The Song"),
                      ManualPlays.Play(albumKey: "a2", title: "Whole Album", art: nil, timestamp: 400)]
        let quick = QuickAccessItem.make(playlists: [], albumPlays: picked)
        XCTAssertEqual(quick.map(\.title), ["The Song", "Whole Album"])
        XCTAssertEqual(quick.map(\.subtitle), ["The Album", nil])
        XCTAssertEqual(quick.first?.route, .item(ratingKey: "a1", title: "The Album"))
    }

    @MainActor func testCarPlayMatchesThePhone() throws {
        let t = try track("t1", album: "pl-album", title: "Played by a Playlist", at: 900)
        let picked = [ManualPlays.Play(albumKey: "mine", title: "Picked Album", art: "/art.jpg", timestamp: 500)]
        let albums = CarPlayController.recentlyPlayedAlbums(picked: picked, recentTracks: [t])
        XCTAssertEqual(albums.map(\.ratingKey), ["mine"])
        XCTAssertEqual(albums.first?.title, "Picked Album")
        XCTAssertEqual(albums.first?.thumb, "/art.jpg")
        XCTAssertEqual(albums.first?.kind, .album)
        XCTAssertEqual(CarPlayController.recentlyPlayedAlbums(picked: [], recentTracks: [t]).map(\.ratingKey), ["pl-album"])
    }

    func testRecordingKeepsTheNewestFirstAndNoDuplicates() {
        let server = "picks-test-\(UUID().uuidString)"
        ManualPlays.record(albumKey: "a", title: "A", art: nil, serverID: server)
        ManualPlays.record(albumKey: "b", title: "B", art: nil, serverID: server)
        ManualPlays.record(albumKey: "a", title: "A", art: nil, serverID: server)
        XCTAssertEqual(ManualPlays.recent(serverID: server).map(\.albumKey), ["a", "b"])
    }
}
