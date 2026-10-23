import SwiftUI
import UIKit

/// Shared pieces of the music pages' look: artwork-colored backdrops, the action row
/// with a round Play button, filter pills and compact quick-access tiles.
extension Cinema {
    /// A bright version of an artwork color for music page backdrops and the mini player.
    static func musicTint(from color: UIColor, brightness: CGFloat = 0.48) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Near-grey artwork stays grey (boosting it would turn it an arbitrary hue, usually brown).
        let saturation = s < 0.15 ? s : min(0.9, max(0.45, s * 1.3))
        return Color(hue: Double(h), saturation: Double(saturation), brightness: Double(brightness))
    }
}

/// Download / ⋯ on the left; shuffle toggle and a large round Play/Pause on the right.
struct MusicActionRow<Leading: View>: View {
    @Binding var shuffleOn: Bool
    let isPlaying: Bool
    let playOrPause: () -> Void
    /// Hidden for empty lists.
    var canPlay = true
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(spacing: 20) {
            leading
            Spacer()
            if canPlay { playControls }
        }
        .frame(minHeight: 56)
        .buttonStyle(.plain)
    }

    @ViewBuilder private var playControls: some View {
            Button { shuffleOn.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "shuffle").font(.title2)
                    Circle().frame(width: 4, height: 4).opacity(shuffleOn ? 1 : 0)
                }
                .foregroundStyle(shuffleOn ? Cinema.accent : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(shuffleOn ? "On" : "Off")
            Button(action: playOrPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 56)
                    .background(Cinema.accent, in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// A grey icon button for the left of the action row (⋯, download).
struct MusicRowIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 44)
            .contentShape(Rectangle())
    }
}

/// Filter pills: the selected one filled with the accent, the rest on a dark surface.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let on = option == selection
                    Button { withAnimation(.easeInOut(duration: 0.15)) { selection = option } } label: {
                        Text(label(option))
                            .font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.black : .white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(on ? Cinema.accent : Cinema.placeholder, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
    }
}

/// One entry in Home's quick-access grid: a recently played playlist or album.
struct QuickAccessItem: Identifiable, Hashable {
    let id: String
    let title: String
    /// The album, when the tile is a song.
    var subtitle: String? = nil
    let art: String?
    let route: Route
    let isPlaylist: Bool
    let playedAt: Int

    /// Recently played playlists and albums the user explicitly chose, newest first.
    static func make(playlists: [PlexMetadata], albumPlays: [ManualPlays.Play], recentTracks: [PlexMetadata] = [], limit: Int = 8) -> [QuickAccessItem] {
        var out: [QuickAccessItem] = playlists.compactMap { p in
            guard let at = p.lastViewedAt else { return nil }
            return QuickAccessItem(id: "p" + p.ratingKey, title: p.title, art: p.composite ?? p.thumb, route: p.route, isPlaylist: true, playedAt: at)
        }
        var seen = Set<String>()
        for play in albumPlays where seen.insert(play.albumKey).inserted {
            out.append(QuickAccessItem(id: "a" + play.albumKey, title: play.song ?? play.title,
                                       subtitle: play.song == nil ? nil : play.title, art: play.art,
                                       route: .item(ratingKey: play.albumKey, title: play.title),
                                       isPlaylist: false, playedAt: play.timestamp))
        }
        // Server history only before any album has been picked here (e.g. first launch after
        // updating); otherwise it would bring back albums a playlist happened to play.
        if albumPlays.isEmpty {
            for t in recentTracks {
                guard let album = t.parentRatingKey, seen.insert(album).inserted else { continue }
                out.append(QuickAccessItem(id: "a" + album, title: t.title, subtitle: t.parentTitle, art: t.parentThumb ?? t.thumb,
                                           route: .item(ratingKey: album, title: t.parentTitle ?? t.title),
                                           isPlaylist: false, playedAt: t.lastViewedAt ?? 0))
            }
        }
        return Array(out.sorted { $0.playedAt > $1.playedAt }.prefix(limit))
    }
}

/// Compact tile for Home's quick-access grid: artwork on the left, the name (and a song's album) beside it.
struct QuickTile: View {
    let entry: QuickAccessItem
    var body: some View {
        HStack(spacing: 8) {
            PlexImage(path: entry.art, width: 120, height: 120, placeholderIcon: entry.isPlaylist ? "music.note.list" : "square.stack")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(entry.subtitle == nil ? 2 : 1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .frame(height: 52)
        .background(Cinema.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([entry.title, entry.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Spotify-style "Browse all" tile: a strong color and a bold name.
struct GenreTile: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(GenreTile.color(for: title), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A stable color per genre name, from a set that holds white text well.
    static func color(for name: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.86, green: 0.15, blue: 0.47), Color(red: 0.12, green: 0.45, blue: 0.85), Color(red: 0.55, green: 0.26, blue: 0.85),
            Color(red: 0.91, green: 0.38, blue: 0.13), Color(red: 0.07, green: 0.55, blue: 0.43), Color(red: 0.73, green: 0.18, blue: 0.18),
            Color(red: 0.35, green: 0.42, blue: 0.86), Color(red: 0.62, green: 0.45, blue: 0.10), Color(red: 0.16, green: 0.50, blue: 0.62),
            Color(red: 0.80, green: 0.25, blue: 0.70),
        ]
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
