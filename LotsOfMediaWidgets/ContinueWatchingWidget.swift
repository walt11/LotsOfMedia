import SwiftUI
import WidgetKit

/// Home Screen widget: what you're in the middle of. Tapping an item resumes it in LotsOfMedia.
struct ContinueWatchingWidget: Widget {
    static let kind = "ContinueWatching"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ContinueWatchingProvider()) { entry in
            ContinueWatchingWidgetView(entry: entry)
                .containerBackground(AppTheme.background, for: .widget)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct ContinueWatchingEntry: TimelineEntry {
    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let progress: Double?
        let image: UIImage?
    }
    let date: Date
    let items: [Item]
    /// Where the items are from, carried in their links.
    var serverID: String?

    func link(_ item: Item) -> URL { TopShelfSnapshot.link("play", item.id, server: serverID) }
}

struct ContinueWatchingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueWatchingEntry {
        ContinueWatchingEntry(date: .now, items: [.init(id: "p", title: "Your Movie", subtitle: "42m left", progress: 0.4, image: nil)])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueWatchingEntry) -> Void) {
        Task { completion(context.isPreview ? placeholder(in: context) : await load(limit: 4)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueWatchingEntry>) -> Void) {
        Task {
            // Lock Screen families show no artwork; don't download it for them.
            let lockScreen = [.accessoryRectangular, .accessoryInline, .accessoryCircular].contains(context.family)
            let entry = await load(limit: lockScreen ? 1 : 4, artwork: !lockScreen)
            // The app refreshes the widget whenever Home loads; this is a fallback.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600))))
        }
    }

    /// Reads what the app saved and fetches small copies of the artwork.
    private func load(limit: Int, artwork: Bool = true) async -> ContinueWatchingEntry {
        let snapshot = TopShelfSnapshot.load()
        let saved = snapshot?.items.prefix(limit) ?? []
        var items: [ContinueWatchingEntry.Item] = []
        for s in saved {
            var image: UIImage?
            if artwork, let url = s.imageURL, let (data, _) = try? await URLSession.shared.data(from: url), let full = UIImage(data: data) {
                image = full.preparingThumbnail(of: CGSize(width: 640, height: 360)) ?? full
            }
            items.append(.init(id: s.ratingKey, title: s.title, subtitle: s.subtitle, progress: s.progress, image: image))
        }
        return ContinueWatchingEntry(date: .now, items: items, serverID: snapshot?.serverID)
    }
}

struct ContinueWatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContinueWatchingEntry

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryInline, .accessoryCircular: lockScreen
        default: homeScreen
        }
    }

    /// Lock Screen and StandBy: the next thing to resume, as text and progress.
    @ViewBuilder private var lockScreen: some View {
        let first = entry.items.first
        switch family {
        case .accessoryInline:
            Label(first.map { $0.title } ?? "Nothing in progress", systemImage: "play.rectangle.fill")
                .widgetURL(first.map(entry.link))
        case .accessoryCircular:
            Gauge(value: first?.progress ?? 0) { Image(systemName: "play.fill") }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetURL(first.map(entry.link))
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label("Continue Watching", systemImage: "play.rectangle.fill").font(.caption2.weight(.semibold)).widgetAccentable()
                Text(first?.title ?? "Nothing in progress").font(.headline).lineLimit(1)
                if let s = first?.subtitle { Text(s).font(.caption).lineLimit(1) }
                if let p = first?.progress { ProgressView(value: p) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(first.map(entry.link))
        }
    }

    @ViewBuilder private var homeScreen: some View {
        if entry.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.on.rectangle").font(.title2).foregroundStyle(AppTheme.accent)
                Text("Nothing in progress").font(.caption.weight(.semibold))
                Text("Open LotsOfMedia to start watching.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        } else {
            switch family {
            case .systemSmall:
                tile(entry.items[0], titleFont: .caption.weight(.bold))
                    .widgetURL(entry.link(entry.items[0]))
            case .systemMedium:
                HStack(spacing: 6) {
                    ForEach(entry.items.prefix(2)) { item in
                        Link(destination: entry.link(item)) { tile(item, titleFont: .caption.weight(.bold)) }
                    }
                }
                .padding(6)
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue Watching").font(.headline).padding(.horizontal, 6)
                    ForEach(entry.items.prefix(4)) { item in
                        Link(destination: entry.link(item)) { row(item) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
            }
        }
    }

    /// Artwork with the title and progress over it.
    private func tile(_ item: ContinueWatchingEntry.Item, titleFont: Font) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork(item)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(titleFont).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                progressBar(item)
            }
            .padding(10)
        }
        .foregroundStyle(.white)
        .clipShape(ContainerRelativeShape())
    }

    private func row(_ item: ContinueWatchingEntry.Item) -> some View {
        HStack(spacing: 10) {
            artwork(item).frame(width: 110, height: 62).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                progressBar(item)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").font(.caption).foregroundStyle(AppTheme.accent)
        }
    }

    @ViewBuilder private func artwork(_ item: ContinueWatchingEntry.Item) -> some View {
        if let image = item.image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(AppTheme.placeholder).overlay(Image(systemName: "film").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder private func progressBar(_ item: ContinueWatchingEntry.Item) -> some View {
        if let p = item.progress {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(AppTheme.accent).frame(width: g.size.width * p)
                }
            }
            .frame(height: 3)
        }
    }
}
