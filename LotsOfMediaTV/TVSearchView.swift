import SwiftUI

/// Search with the on-screen keyboard or dictation; results grouped like Plex does.
struct TVSearchView: View {
    @Environment(TVSession.self) private var session
    @State private var query = ""
    @State private var response: (query: String, hubs: [PlexHub], failed: Bool)?
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static let supportedKinds: Set<PlexMetadata.Kind> = [.movie, .show, .episode, .season, .album, .artist, .track, .collection]

    var body: some View {
        let result = response.flatMap { $0.query == trimmed ? $0 : nil }
        TVPageScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                if trimmed.count < 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Find your next favorite").font(TVTheme.title(44))
                        Text("Search movies, shows, artists and albums in your library.")
                            .font(.callout).foregroundStyle(TVTheme.secondary)
                    }.padding(.horizontal, 80)
                }
                if trimmed.count >= 2 && result == nil {
                    ProgressView("Searching your library…").padding(.horizontal, 80)
                }
                ForEach(result?.hubs ?? []) { hub in
                    TVRow(title: hub.title) {
                        ForEach(hub.metadata) { item in
                            NavigationLink(value: item.kind == .track ? albumStandIn(for: item) : item) { TVPosterCard(item: item) }.playsOnPlayPause(item)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if result?.failed == true {
                    Text("Search is unavailable. Try again in a moment.").foregroundStyle(.secondary).padding(.horizontal, 80)
                } else if result?.hubs.isEmpty == true {
                    Text("No results for “\(trimmed)”").foregroundStyle(.secondary).padding(.horizontal, 80)
                }
            }
            .padding(.vertical, 30)
        }
        .searchable(text: $query, prompt: "Movies, shows, music")
        .task(id: trimmed) {
            response = nil
            let q = trimmed
            guard q.count >= 2 else { return }
            guard let api = session.api else {
                response = (q, [], true)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let results = try await api.search(q)
                try Task.checkCancellation()
                let hubs = results.compactMap { hub -> PlexHub? in
                    var filtered = hub
                    filtered.metadata = hub.metadata.filter { Self.supportedKinds.contains($0.kind) }
                    return filtered.metadata.isEmpty ? nil : filtered
                }
                response = (q, hubs, false)
            } catch {
                guard !Task.isCancelled else { return }
                response = (q, [], true)
            }
        }
    }

    /// Songs open their album, like on iPhone.
    private func albumStandIn(for track: PlexMetadata) -> PlexMetadata {
        guard let album = track.parentRatingKey else { return track }
        var m = track
        m.ratingKey = album
        m.type = "album"
        m.title = track.parentTitle ?? track.title
        m.thumb = track.parentThumb ?? track.thumb
        m.parentTitle = track.grandparentTitle
        return m
    }
}
