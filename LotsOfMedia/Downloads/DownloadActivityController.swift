import ActivityKit
import Foundation
import UIKit

/// Drives the downloads Live Activity (Lock Screen + Dynamic Island).
///
/// The app can only push updates while it's running (foreground, or woken by
/// the background download session). To keep the bar moving while suspended,
/// each update carries an estimated time range derived from the recent
/// transfer rate; the widget animates across it without further updates.
@MainActor
final class DownloadActivityController {
    static let shared = DownloadActivityController()

    var isEnabled: Bool = UserDefaults.standard.object(forKey: "downloads.liveActivity") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "downloads.liveActivity")
            if !isEnabled { endAll() } else { refresh(force: true) }
        }
    }

    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?
    private var lastPush = Date.distantPast
    /// Records that were part of this activity, so finished items still count toward overall progress.
    private var sessionIDs: Set<String> = []
    private var samples: [(at: Date, bytes: Int64)] = []
    private var conversionSamples: [(at: Date, progress: Double)] = []

    private init() {
        // Adopt an activity left over from a previous launch rather than stacking a new one.
        let live = Activity<DownloadActivityAttributes>.activities.filter { $0.activityState == .active }
        activity = live.first
        for extra in live.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func refresh(force: Bool = false) {
        guard isEnabled else { return }
        let manager = DownloadManager.shared
        let activeStates: Set<DownloadRecord.State> = [.queued, .preparing, .downloading, .assembling, .paused]
        let active = manager.records.filter { activeStates.contains($0.state) }
        let anyRunning = active.contains { $0.state != .paused }

        guard !active.isEmpty else {
            finish(manager)
            return
        }
        sessionIDs.formUnion(active.map(\.id))
        let session = manager.records.filter { sessionIDs.contains($0.id) }

        var bytesTotal: Int64 = 0, bytesDone: Int64 = 0
        for rec in session {
            guard let total = rec.totalBytes else { continue }
            bytesTotal += total
            bytesDone += rec.state == .completed ? total : (manager.liveBytes[rec.id] ?? rec.downloadedSegmentBytes)
        }
        let knownSizes = session.allSatisfy { $0.totalBytes != nil || $0.state == .completed }
        var progress = bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0
        if !knownSizes {
            // Some items are still being prepared: weight by item count instead.
            let done = Double(session.filter { $0.state == .completed }.count)
            progress = min(progress, (done + progress) / Double(max(session.count, 1)))
        }

        let converting = active.filter { $0.state == .preparing }
        let conversionProgress: Double? = converting.isEmpty ? nil
            : converting.map { min(max($0.preparationProgress ?? 0, 0), 1) }.reduce(0, +) / Double(converting.count)

        let phase: DownloadActivityAttributes.ContentState.Phase
        if active.contains(where: { $0.state == .downloading }) {
            phase = NetworkMonitor.shared.isConnected ? .downloading : .waiting
        } else if active.contains(where: { $0.state == .assembling }) {
            phase = .finishing
        } else if !converting.isEmpty {
            phase = .converting
        } else if active.contains(where: { $0.state == .queued }) {
            phase = .downloading
        } else {
            phase = .paused
        }
        let current = phase == .converting
            ? converting[0]
            : (active.first { $0.state == .downloading } ?? active.first { $0.state != .paused } ?? active[0])

        let now = Date()
        // While only converting, the headline progress is the server's conversion progress.
        if phase == .converting, let conversionProgress { progress = conversionProgress }

        // Transfer rate over the last ~20 s for the time-based estimate.
        samples.append((now, bytesDone))
        samples.removeAll { now.timeIntervalSince($0.at) > 20 }
        var estimateStart: Date?, estimateEnd: Date?
        if let conversionProgress {
            conversionSamples.append((now, conversionProgress))
            conversionSamples.removeAll { now.timeIntervalSince($0.at) > 30 }
        } else {
            conversionSamples.removeAll()
        }
        if phase == .converting, let cp = conversionProgress, let first = conversionSamples.first,
           now.timeIntervalSince(first.at) > 5, cp > first.progress, cp < 0.999 {
            // Same trick as downloads: let the widget animate toward an estimated finish.
            let rate = (cp - first.progress) / now.timeIntervalSince(first.at)
            let remaining = (1 - cp) / rate
            estimateStart = now.addingTimeInterval(-cp / rate)
            estimateEnd = now.addingTimeInterval(remaining)
        }
        if phase == .downloading, knownSizes, let first = samples.first, now.timeIntervalSince(first.at) > 3,
           bytesDone > first.bytes, progress < 0.999 {
            let rate = Double(bytesDone - first.bytes) / now.timeIntervalSince(first.at)
            let remaining = Double(bytesTotal - bytesDone) / rate
            let whole = remaining / (1 - progress)
            estimateStart = now.addingTimeInterval(-progress * whole)
            estimateEnd = now.addingTimeInterval(remaining)
        }

        let state = DownloadActivityAttributes.ContentState(
            phase: phase,
            title: Self.title(current.metadata),
            subtitle: Self.subtitle(current.metadata),
            progress: min(max(progress, 0), 1),
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            remainingItems: active.count,
            completedItems: session.filter { $0.state == .completed }.count,
            estimateStart: estimateStart,
            estimateEnd: estimateEnd,
            convertingCount: converting.count,
            conversionProgress: conversionProgress,
            conversionReason: phase == .converting ? current.conversionReason : nil
        )

        let structural = lastState.map {
            $0.phase != state.phase || $0.title != state.title || $0.remainingItems != state.remainingItems
                || $0.convertingCount != state.convertingCount
        } ?? true
        let moved = abs((lastState?.progress ?? -1) - state.progress) > 0.002
        guard force || structural || (moved && now.timeIntervalSince(lastPush) >= 2) else { return }

        if activity == nil {
            // Activities can only be started from the foreground.
            guard anyRunning, UIApplication.shared.applicationState == .active,
                  ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // Clear any "complete" cards from earlier batches so the live one is on top.
            for old in Activity<DownloadActivityAttributes>.activities {
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(15 * 60))
            activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: content, pushType: nil)
        } else if let activity {
            let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(15 * 60))
            Task { await activity.update(content) }
        }
        lastState = state
        lastPush = now
    }

    private func finish(_ manager: DownloadManager) {
        let session = manager.records.filter { sessionIDs.contains($0.id) }
        let completed = session.filter { $0.state == .completed }
        let failed = session.contains { $0.state == .failed }
        // Nothing finished (everything was canceled or removed): clear the Lock Screen
        // straight away instead of leaving a "Downloads stopped" card.
        guard let activity, !completed.isEmpty || failed else {
            endAll()
            samples.removeAll()
            return
        }
        let total = completed.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let state = DownloadActivityAttributes.ContentState(
            phase: completed.isEmpty && failed ? .failed : .done,
            title: completed.count == 1 ? Self.title(completed[0].metadata) : (completed.isEmpty ? "Downloads stopped" : "Downloads complete"),
            subtitle: completed.count == 1 ? Self.subtitle(completed[0].metadata) : nil,
            progress: 1, bytesDone: total, bytesTotal: total,
            remainingItems: 0, completedItems: completed.count,
            estimateStart: nil, estimateEnd: nil,
            isAudio: !completed.isEmpty && completed.allSatisfy(\.isAudio))
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(10 * 60))) }
        self.activity = nil
        lastState = nil
        sessionIDs.removeAll()
        samples.removeAll()
    }

    private func endAll() {
        for a in Activity<DownloadActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        lastState = nil
        sessionIDs.removeAll()
    }

    private static func title(_ m: PlexMetadata) -> String {
        m.kind == .episode ? (m.grandparentTitle ?? m.title) : m.title
    }

    private static func subtitle(_ m: PlexMetadata) -> String? {
        switch m.kind {
        case .episode: return m.subtitleLine
        case .track: return [m.grandparentTitle, m.parentTitle].compactMap { $0 }.joined(separator: " · ")
        default: return m.year.map(String.init)
        }
    }
}
