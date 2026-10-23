import SwiftUI

/// Suggestions for freeing space, grouped by reason. Pure so it can be tested.
struct CleanupSuggestions {
    enum Kind: String, CaseIterable, Identifiable {
        case watchedVideos, finishedShows, largest, rarelyPlayedMusic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .watchedVideos: return "Watched Movies & Videos"
            case .finishedShows: return "Finished Shows"
            case .largest: return "Largest Downloads"
            case .rarelyPlayedMusic: return "Rarely Played Music"
            }
        }
        var detail: String {
            switch self {
            case .watchedVideos: return "Already watched to the end."
            case .finishedShows: return "Every downloaded episode has been watched."
            case .largest: return "The biggest files on this iPhone."
            case .rarelyPlayedMusic: return "Downloaded over a month ago and not played in three months."
            }
        }
    }

    struct Group: Identifiable {
        let kind: Kind
        let title: String          // group label (e.g. a show's name), or the item title
        let recordIDs: [String]
        let bytes: Int64
        var id: String { kind.rawValue + "|" + recordIDs.joined(separator: ",") }
    }

    static func watched(_ r: DownloadRecord) -> Bool {
        (r.metadata.viewCount ?? 0) > 0 && (r.metadata.viewOffset ?? 0) == 0
    }

    static func make(records: [DownloadRecord], now: Date = Date(), largestCount: Int = 10) -> [Kind: [Group]] {
        let done = records.filter { $0.state == .completed && !$0.hasPendingProgress }
        func size(_ rs: [DownloadRecord]) -> Int64 { rs.reduce(0) { $0 + ($1.totalBytes ?? 0) } }
        var out: [Kind: [Group]] = [:]

        let watchedVideos = done.filter { !$0.isAudio && $0.metadata.kind != .episode && watched($0) }
        out[.watchedVideos] = watchedVideos.map { Group(kind: .watchedVideos, title: $0.metadata.title, recordIDs: [$0.id], bytes: $0.totalBytes ?? 0) }

        let episodes = Dictionary(grouping: done.filter { $0.metadata.kind == .episode }, by: \.offlineGroupID)
        out[.finishedShows] = episodes.values.filter { $0.allSatisfy(watched) }.map {
            Group(kind: .finishedShows, title: "\($0[0].offlineGroupTitle) · \($0.count) episode\($0.count == 1 ? "" : "s")",
                  recordIDs: $0.map(\.id), bytes: size($0))
        }.sorted { $0.bytes > $1.bytes }

        out[.largest] = done.sorted { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }.prefix(largestCount).map {
            Group(kind: .largest, title: $0.metadata.kind == .episode ? "\($0.metadata.grandparentTitle ?? "") · \($0.metadata.subtitleLine ?? $0.metadata.title)" : $0.metadata.title,
                  recordIDs: [$0.id], bytes: $0.totalBytes ?? 0)
        }

        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let quarterAgo = now.timeIntervalSince1970 - 90 * 86_400
        let rare = done.filter { r in
            r.isAudio && (r.completedAt ?? r.createdAt) < monthAgo
                && (r.metadata.lastViewedAt.map { Double($0) < quarterAgo } ?? true)
        }
        out[.rarelyPlayedMusic] = Dictionary(grouping: rare, by: \.offlineGroupID).values.map {
            Group(kind: .rarelyPlayedMusic, title: "\($0[0].offlineGroupTitle) · \($0.count) song\($0.count == 1 ? "" : "s")",
                  recordIDs: $0.map(\.id), bytes: size($0))
        }.sorted { $0.bytes > $1.bytes }
        return out
    }

    /// Space a selection frees, counting each download once even if it appears in several groups.
    static func bytes(of ids: Set<String>, records: [DownloadRecord]) -> Int64 {
        records.filter { ids.contains($0.id) }.reduce(0) { $0 + ($1.totalBytes ?? 0) }
    }
}

struct StorageCleanupView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var confirming = false

    var body: some View {
        let groups = CleanupSuggestions.make(records: downloads.records)
        let freed = CleanupSuggestions.bytes(of: selected, records: downloads.records)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.bytes(downloads.records.filter { $0.state == .completed }.reduce(0) { $0 + ($1.totalBytes ?? 0) }))
                        .font(.title2.bold())
                    Text("used by downloads" + (DownloadStore.availableCapacity().map { " · \(Fmt.bytes($0)) free on this iPhone" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(CleanupSuggestions.Kind.allCases) { kind in
                if let list = groups[kind], !list.isEmpty {
                    Section {
                        ForEach(list) { group in row(group) }
                    } header: {
                        HStack {
                            Text(kind.title)
                            Spacer()
                            let all = Set(list.flatMap(\.recordIDs))
                            Button(all.isSubset(of: selected) ? "Deselect" : "Select All") {
                                if all.isSubset(of: selected) { selected.subtract(all) } else { selected.formUnion(all) }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    } footer: { Text(kind.detail) }
                }
            }
        }
        .overlay {
            if groups.values.allSatisfy(\.isEmpty) {
                ContentUnavailableView("Nothing to Clean Up", systemImage: "checkmark.circle",
                                       description: Text("Suggestions appear here once you have watched or rarely played downloads."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                Button { confirming = true } label: {
                    Text("Review \(selected.count) Download\(selected.count == 1 ? "" : "s") · Free \(Fmt.bytes(freed))")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .prominentButton()
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .confirmationDialog("Delete \(selected.count) download\(selected.count == 1 ? "" : "s")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete and Free \(Fmt.bytes(freed))", role: .destructive) {
                downloads.deleteMany(Array(selected))
                selected = []
            }
        } message: {
            Text("They stay in your Plex library and can be downloaded again. Offline watch progress that hasn't synced is never removed here.")
        }
        .pageTitle("Free Up Space")
    }

    private func row(_ group: CleanupSuggestions.Group) -> some View {
        let on = Set(group.recordIDs).isSubset(of: selected)
        return Button {
            if on { selected.subtract(group.recordIDs) } else { selected.formUnion(group.recordIDs) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(on ? Cinema.accent : .secondary)
                Text(group.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                Text(Fmt.bytes(group.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
