import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LotsOfMediaWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
        ContinueWatchingWidget()
    }
}

/// The app's colors (AppTheme).
private extension DownloadActivityAttributes.ContentState {
    var accent: Color { AppTheme.accent }
    var phaseColor: Color { phase == .converting ? AppTheme.converting : accent }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(AppTheme.background.opacity(0.92))
                .activitySystemActionForegroundColor(context.state.accent)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(state: state).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ProgressFigure(state: state, font: .title3)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        PhaseLabel(state: state)
                        Text(state.title).font(.headline).lineLimit(1)
                        if let sub = state.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressBar(state: state)
                        HStack {
                            Text(statusLine(state)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if state.remainingItems > 1 {
                                Text("\(state.remainingItems) items left").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(state: state)
            } compactTrailing: {
                HStack(spacing: 4) {
                    if state.estimateEnd == nil {
                        Text(state.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(state.phaseColor)
                            .lineLimit(1).fixedSize()
                    }
                    Ring(state: state).frame(width: 16, height: 16)
                }
            } minimal: {
                Ring(state: state).frame(width: 18, height: 18)
            }
            .keylineTint(state.phaseColor)
        }
    }
}

private func statusLine(_ s: DownloadActivityAttributes.ContentState) -> String {
    let bytes = s.bytesTotal > 0
        ? "\(ByteCountFormatter.string(fromByteCount: s.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: s.bytesTotal, countStyle: .file))"
        : ""
    switch s.phase {
    case .downloading:
        return s.convertingCount > 0 ? "\(bytes) · \(s.convertingCount) converting" : bytes
    case .converting:
        if s.convertingCount > 1 { return "Your server is converting \(s.convertingCount) items for iPhone" }
        return s.conversionReason.map { "\($0) – converting to MP4" } ?? "Your server is preparing a playable copy"
    case .waiting: return "Waiting for connection · " + bytes
    case .paused: return "Paused · " + bytes
    case .finishing: return "Finishing…"
    case .done:
        let verb = s.isAudio == true ? "listen" : "watch"
        return s.completedItems == 1 ? "Ready to \(verb) offline" : "\(s.completedItems) downloads ready to \(verb) offline"
    case .failed: return "Download needs attention"
    }
}

private struct PhaseIcon: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(state.accent)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
        case .converting: Image(systemName: "gearshape.2.fill").foregroundStyle(AppTheme.converting)
        default: Image(systemName: "arrow.down.circle.fill").foregroundStyle(state.accent)
        }
    }
}

/// Uses the date-based estimate when available so the bar animates without updates.
private struct ProgressBar: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        Group {
            if state.phase == .downloading || state.phase == .converting, let start = state.estimateStart, let end = state.estimateEnd, end > start {
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: min(max(state.progress, 0), 1))
            }
        }
        .tint(state.phaseColor)
    }
}

private struct Ring: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        if state.phase == .done {
            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(state.accent)
        } else if state.phase == .downloading || state.phase == .converting, let start = state.estimateStart, let end = state.estimateEnd, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular)
                .tint(state.phaseColor)
        } else {
            ProgressView(value: min(max(state.progress, 0), 1))
                .progressViewStyle(.circular)
                .tint(state.phaseColor)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 14) {
            PhaseIcon(state: state).font(.system(size: 34))
            VStack(alignment: .leading, spacing: 5) {
                PhaseLabel(state: state)
                HStack {
                    Text(state.title).font(.headline).lineLimit(1)
                    Spacer()
                    if state.phase != .done {
                        ProgressFigure(state: state, font: .subheadline)
                    }
                }
                if let sub = state.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if state.phase != .done { ProgressBar(state: state) }
                HStack {
                    Text(statusLine(state))
                    Spacer()
                    if state.remainingItems > 1 { Text("\(state.remainingItems) left") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Small all-caps label so converting vs. downloading reads at a glance.
private struct PhaseLabel: View {
    let state: DownloadActivityAttributes.ContentState
    var body: some View {
        let text: String? = switch state.phase {
        case .converting: "CONVERTING"
        case .downloading: "DOWNLOADING"
        case .waiting: "WAITING"
        case .paused: "PAUSED"
        case .finishing: "FINISHING"
        case .done, .failed: nil
        }
        if let text {
            Text(text).font(.caption2.weight(.bold)).kerning(0.6).foregroundStyle(state.phaseColor)
        }
    }
}

/// Percentage, or a live "time left" countdown when we have an estimate. The
/// countdown keeps ticking while the app is suspended, so it never contradicts
/// the animated bar the way a frozen percentage would.
private struct ProgressFigure: View {
    let state: DownloadActivityAttributes.ContentState
    let font: Font
    var body: some View {
        Group {
            if (state.phase == .downloading || state.phase == .converting), let end = state.estimateEnd, end > .now {
                Text(timerInterval: Date.now...end, countsDown: true)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            } else {
                Text(state.progress, format: .percent.precision(.fractionLength(0)))
            }
        }
        .font(font.monospacedDigit().weight(.semibold))
        .foregroundStyle(state.phaseColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
