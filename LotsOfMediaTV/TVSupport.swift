import SwiftUI
import UIKit

// MARK: - Look

/// The TV app uses the iPhone app's Blue theme: near-black ground, cyan accent.
enum TVTheme {
    /// White on Apple TV, like its buttons (iPhone and iPad use green).
    static var accent: Color { .white }
    static var background: Color { AppTheme.background }
    static var surface: Color { AppTheme.surface }
    static var placeholder: Color { AppTheme.placeholder }
    static var muted: Color { AppTheme.muted }
}

/// Used by ProStore when it presents the unlock screen; the TV app is always dark and blue.
struct ThemeTint: ViewModifier {
    func body(content: Content) -> some View { content.tint(TVTheme.accent) }
}

// MARK: - Stand-ins for iPhone-only features the shared playback code mentions

/// The VLC-based player for files tvOS can't play (MKV, DTS, TrueHD, image subtitles).
/// A Pro feature, on by default with Pro; without it the server converts those files.
enum BuiltInPlayer {
    static let preferenceKey = "builtInPlayerEnabled"
    static var isEnabled: Bool {
        get { ProStore.isUnlocked && (UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }
    static func canPlay(media: PlexMedia, kind: PlexMetadata.Kind) -> Bool {
        isEnabled && kind != .track && media.parts.count == 1
    }
    /// Plays here rather than in Apple's player: only what tvOS can't play as-is.
    static func handles(_ item: PlexMetadata) -> Bool {
        guard item.isPlayableVideo, let media = item.primaryMedia, canPlay(media: media, kind: item.kind) else { return false }
        if !PlaybackDecider.canPlayNatively(media: media, kind: item.kind) { return true }
        // Image subtitles (PGS, VobSub) would otherwise need the server to burn them in.
        if let sub = media.parts.first?.selectedSubtitle, !sub.isSidecarText,
           !PlaybackDecider.nativeTextSubtitleCodecs.contains((sub.codec ?? "").lowercased()) { return true }
        return false
    }
}

/// Downloads don't exist on Apple TV; only the "original" case is ever referenced.
enum DownloadQuality {
    case original
    var targetHeight: Int? { nil }
}

// MARK: - Artwork

/// Plex artwork, loaded through the shared ImageLoader cache.
struct TVImage: View {
    @Environment(TVSession.self) private var session
    let path: String?
    var width = 400
    var height = 600
    var placeholderIcon = "film"

    /// Kept with its URL: when the view moves to other artwork, the old picture isn't shown.
    @State private var loaded: (url: URL, image: UIImage)?

    private var url: URL? { session.imageURL(path, width: width, height: height) }

    var body: some View {
        let url = self.url
        let shown = loaded.flatMap { $0.url == url ? $0.image : nil } ?? url.flatMap { ImageLoader.shared.cached($0) }
        Rectangle()
            .fill(TVTheme.placeholder)
            .overlay {
                if let shown {
                    Image(uiImage: shown).resizable().aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else if !placeholderIcon.isEmpty {
                    Image(systemName: placeholderIcon).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                if let image = await ImageLoader.shared.image(for: url) {
                    // Artwork fades in instead of popping in.
                    withAnimation(.easeOut(duration: 0.3)) { loaded = (url, image) }
                }
            }
    }
}

// MARK: - Text

extension PlexMetadata {
    /// "2010 · 1h 47m · PG-13" for movies; "S1 · E2 · 24m" for episodes.
    var tvMetaLine: String {
        var parts: [String] = []
        if kind == .episode {
            if let s = parentIndex { parts.append("Season \(s)") }
            if let e = index { parts.append("Episode \(e)") }
        } else if let year { parts.append(String(year)) }
        if let d = Fmt.duration(ms: duration) { parts.append(d) }
        if let r = contentRating { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    /// Title for a card: episodes show their show's name.
    var tvCardTitle: String { kind == .episode ? (grandparentTitle ?? title) : title }

    /// Second line for a card.
    var tvCardSubtitle: String? {
        switch kind {
        case .episode: return subtitleLine ?? title
        case .album: return parentTitle ?? year.map(String.init)
        case .season: return parentTitle
        default: return year.map(String.init)
        }
    }

    /// Wide artwork for Continue Watching (episode stills, movie backdrops).
    var tvWideArt: String? { kind == .episode ? (thumb ?? art ?? grandparentArt) : (art ?? thumb) }
}
