import SwiftUI

/// A cast member's photo and name, opening their page when the server can list their titles.
struct PersonLink<Label: View>: View {
    let person: PlexTag
    @ViewBuilder let label: () -> Label

    var body: some View {
        if person.filter != nil {
            NavigationLink(value: Route.person(person)) { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            label()
        }
    }
}

/// A person's page, as on Apple TV: their photo and everything they're in across your
/// movie and TV libraries.
struct PersonView: View {
    @ScaledMetric(relativeTo: .body) private var posterWidth = Cinema.gridPosterWidth
    @Environment(AppState.self) private var app
    let person: PlexTag
    @State private var items: [PlexMetadata] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    PlexImage(path: person.thumb, width: 300, height: 300, placeholderIcon: "person.fill")
                        .frame(width: 110, height: 110)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.tag).font(.largeTitle.bold()).lineLimit(2).minimumScaleFactor(0.6)
                        Text(loading ? "Looking through your libraries…" : "\(items.count) title\(items.count == 1 ? "" : "s") in your libraries")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 12)], spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item.route) { PosterCard(item: item, width: posterWidth) }
                            .buttonStyle(.plain)
                            .contextMenu { ItemContextMenu(item: item) }
                    }
                }
                .padding(.horizontal)
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.vertical)
        }
        .titleWithDownloadStatus(person.tag)
        .task(id: app.contentVersion) { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let api = app.browseAPI, let filter = person.filter,
              let sections = try? await api.sections() else { return }
        let found = await api.titles(withFilter: filter, in: sections)
        if !Task.isCancelled { items = found }
    }
}
