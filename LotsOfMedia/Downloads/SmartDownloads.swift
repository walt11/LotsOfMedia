import Foundation
import Observation

/// "Keep the next N unwatched episodes downloaded" for a show.
struct SmartDownloadRule: Codable, Identifiable, Hashable {
    var serverID: String
    var showRatingKey: String
    var showTitle: String
    var showThumb: String?
    var keepCount: Int
    /// Remove episodes once they're fully watched.
    var deleteWatched: Bool

    var id: String { serverID + "_" + showRatingKey }
}

/// Keeps smart-download shows topped up: queues upcoming unwatched episodes
/// and removes watched ones. Runs on connect, after playback, when the app
/// returns to the foreground, and from background refresh.
@MainActor
@Observable
final class SmartDownloads {
    static let shared = SmartDownloads()
    static let keepChoices = [1, 3, 5, 10]

    private(set) var rules: [SmartDownloadRule] = []
    private(set) var isRefreshing = false

    private static var fileURL: URL { DownloadStore.root.appendingPathComponent("smart-downloads.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([SmartDownloadRule].self, from: data) {
            rules = saved
        }
    }

    func rule(serverID: String, showRatingKey: String) -> SmartDownloadRule? {
        rules.first { $0.serverID == serverID && $0.showRatingKey == showRatingKey }
    }

    func set(_ rule: SmartDownloadRule) {
        guard ProStore.require(.downloads) else { return }
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule } else { rules.append(rule) }
        persist()
        Task { await refresh(only: rule.id) }
    }

    func remove(_ id: String) {
        rules.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func refresh(only ruleID: String? = nil) async {
        guard ProStore.isUnlocked, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let manager = DownloadManager.shared
        let userID = manager.activeUserID
        // Push offline progress first so "watched" is accurate and nothing unsynced is deleted.
        await manager.syncOfflineProgress()

        for rule in rules where ruleID == nil || rule.id == ruleID {
            guard userID == manager.activeUserID else { return }
            var leaves: [PlexMetadata]?
            if NetworkMonitor.shared.isConnected, let api = ServerDirectory.shared.api(for: rule.serverID) {
                leaves = try? await api.allLeaves(rule.showRatingKey)
                guard userID == manager.activeUserID, ServerDirectory.shared.authorizes(api) else { return }
            }

            if rule.deleteWatched {
                let watchedOnServer = Set((leaves ?? []).filter { ($0.viewCount ?? 0) > 0 && ($0.viewOffset ?? 0) == 0 }.map(\.ratingKey))
                let showRecords = manager.records.filter {
                    $0.serverID == rule.serverID && $0.metadata.grandparentRatingKey == rule.showRatingKey
                        && $0.state == .completed && !$0.hasPendingProgress
                }
                for rec in showRecords {
                    let watchedLocally = (rec.metadata.viewCount ?? 0) > 0 && (rec.metadata.viewOffset ?? 0) == 0
                    if watchedOnServer.contains(rec.metadata.ratingKey) || watchedLocally { manager.delete(rec.id) }
                }
            }

            // Queue the next N unwatched episodes (in-progress ones count as unwatched).
            guard let leaves else { continue }
            let upcoming = leaves.filter { ($0.viewCount ?? 0) == 0 }.prefix(rule.keepCount)
            manager.enqueue(Array(upcoming), serverID: rule.serverID, batchTitle: rule.showTitle)
        }
    }
}
