import AppIntents
import CoreSpotlight
import Observation
import UniformTypeIdentifiers

/// What a Shortcut, Siri or a Spotlight result asked the app to do. RootView carries it out once
/// it's on screen (the app may have just been launched for it).
@MainActor @Observable
final class IntentRouter {
    static let shared = IntentRouter()
    enum Action: Equatable {
        case resume
        case playShow(String)
        case downloads
        case openDownload(String)
    }
    var pending: Action?
}

// MARK: - App Intents (Shortcuts, Siri, Spotlight actions)

struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Watching"
    static var description = IntentDescription("Plays the first item in Continue Watching.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .resume
        return .result()
    }
}

struct PlayNextEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Next Episode"
    static var description = IntentDescription("Plays the episode you're up to in a show: the one in progress, or the first one you haven't watched.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Show", requestValueDialog: "Which show?")
    var show: String

    static var parameterSummary: some ParameterSummary { Summary("Play the next episode of \(\.$show)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .playShow(show)
        return .result()
    }
}

struct OpenDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Downloads"
    static var description = IntentDescription("Shows what's downloaded to this device.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .downloads
        return .result()
    }
}

struct LotsOfMediaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeWatchingIntent(),
                    phrases: ["Resume watching in \(.applicationName)", "Continue watching in \(.applicationName)"],
                    shortTitle: "Resume Watching", systemImageName: "play.fill")
        AppShortcut(intent: PlayNextEpisodeIntent(),
                    phrases: ["Play the next episode in \(.applicationName)"],
                    shortTitle: "Next Episode", systemImageName: "forward.end.fill")
        AppShortcut(intent: OpenDownloadsIntent(),
                    phrases: ["Show my downloads in \(.applicationName)", "Open \(.applicationName) downloads"],
                    shortTitle: "Downloads", systemImageName: "arrow.down.circle")
    }
}

// MARK: - Spotlight

/// Finished downloads appear in Spotlight search; choosing one plays it, even offline.
enum SpotlightIndex {
    static let prefix = "download:"
    private static let queue = DispatchQueue(label: "net.jwalter.LotsOfMedia.spotlight", qos: .utility)
    /// Only touched on `queue`.
    nonisolated(unsafe) private static var indexed: Set<String>?

    /// Brings the index in line with the completed downloads (adds new ones, removes deleted ones).
    static func sync(_ records: [DownloadRecord]) {
        let completed = records.filter { $0.state == .completed }
        queue.async {
            let ids = Set(completed.map(\.id))
            guard ids != indexed else { return }
            let previous = indexed
            indexed = ids
            let index = CSSearchableIndex.default()
            // First run after launch: rebuild, so the index never keeps something deleted while the app was closed.
            let removed = previous.map { Array($0.subtracting(ids)).map { prefix + $0 } }
            let added = completed.filter { previous?.contains($0.id) != true }
            let items = added.map(searchableItem)
            if let removed {
                if !removed.isEmpty { index.deleteSearchableItems(withIdentifiers: removed) }
                if !items.isEmpty { index.indexSearchableItems(items) }
            } else {
                index.deleteSearchableItems(withDomainIdentifiers: ["downloads"]) { _ in
                    if !items.isEmpty { index.indexSearchableItems(items) }
                }
            }
        }
    }

    private static func searchableItem(_ rec: DownloadRecord) -> CSSearchableItem {
        let m = rec.metadata
        let attributes = CSSearchableItemAttributeSet(contentType: rec.isAudio ? .audio : .movie)
        attributes.title = m.kind == .episode ? "\(m.grandparentTitle ?? m.title) · \(m.title)" : m.title
        attributes.contentDescription = [m.kind == .track ? m.grandparentTitle : m.subtitleLine, "Downloaded"].compactMap { $0 }.joined(separator: " · ")
        attributes.thumbnailURL = DownloadStore.posterURL(id: rec.id)
        if let ms = m.duration { attributes.duration = NSNumber(value: Double(ms) / 1000) }
        return CSSearchableItem(uniqueIdentifier: prefix + rec.id, domainIdentifier: "downloads", attributeSet: attributes)
    }

    /// The download a Spotlight result stands for.
    static func downloadID(from activity: NSUserActivity) -> String? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}
