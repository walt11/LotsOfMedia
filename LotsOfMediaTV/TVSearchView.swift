import SwiftUI

/// Search with the on-screen keyboard or dictation; results grouped like Plex does.
struct TVSearchView: View {
    @Environment(TVSession.self) private var session
    @State private var query = ""
    @State private var hubs: [PlexHub] = []
    @State private var searching = false

    var body: some View {
        TVPageScrollView {
            LazyVStack(alignment: .leading, spacing: 50) {
                ForEach(hubs) { hub in
                    TVRow(title: hub.title) {
                        ForEach(hub.metadata) { item in
                            NavigationLink(value: item.kind == .track ? albumStandIn(for: item) : item) { TVPosterCard(item: item) }.playsOnPlayPause(item)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if !query.isEmpty && hubs.isEmpty && !searching {
                    Text("No results for “\(query)”").foregroundStyle(.secondary).padding(.horizontal, 80)
                }
            }
            .padding(.vertical, 30)
        }
        .searchable(text: $query, prompt: "Movies, shows, music")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2, let api = session.api else { hubs = []; return }
            try? await Task.sleep(for: .milliseconds(350))   // wait for typing to pause
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            let results = (try? await api.search(q)) ?? []
            guard !Task.isCancelled else { return }
            hubs = results.filter { hub in hub.metadata.contains { [.movie, .show, .episode, .season, .album, .artist, .track, .collection].contains($0.kind) } }
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
