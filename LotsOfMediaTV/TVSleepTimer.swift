import SwiftUI
import UIKit

extension Notification.Name {
    /// The sleep timer ran out: video players pause.
    static let tvSleepTimerFired = Notification.Name("tvSleepTimerFired")
}

/// Stops playback after a while, or at the end of what's playing: music pauses, live TV stops
/// and videos pause. Set from the players' menus and Now Playing.
@MainActor @Observable
final class TVSleepTimer {
    static let shared = TVSleepTimer()
    static let choices = [15, 30, 45, 60, 90]

    private(set) var endsAt: Date?
    private(set) var atEndOfItem = false
    var isActive: Bool { endsAt != nil || atEndOfItem }
    @ObservationIgnored private var task: Task<Void, Never>?

    func set(minutes: Int) {
        cancel()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        endsAt = end
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func setEndOfItem() {
        cancel()
        atEndOfItem = true
    }

    func cancel() {
        task?.cancel()
        task = nil
        endsAt = nil
        atEndOfItem = false
    }

    private func fire() {
        cancel()
        TVMusicPlayer.shared.pause()
        TVLiveNow.shared.stop()
        NotificationCenter.default.post(name: .tvSleepTimerFired, object: nil)
    }

    /// Players call this when an item finishes; true means stop here instead of going on.
    func shouldStopAtItemEnd() -> Bool {
        guard atEndOfItem else { return false }
        fire()
        return true
    }

    var summary: String {
        if atEndOfItem { return "At the end of this one" }
        guard let endsAt else { return "Off" }
        let minutes = max(1, Int(ceil(endsAt.timeIntervalSinceNow / 60)))
        return "\(minutes) min left"
    }

    /// For Apple's player's transport bar; rebuilt each time it opens so the checkmark is current.
    func menu(endLabel: String? = "End of Episode") -> UIMenu {
        UIMenu(title: "Sleep Timer", image: UIImage(systemName: "moon.zzz"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    guard let self else { return completion([]) }
                    var items: [UIMenuElement] = [UIAction(title: "Off", state: self.isActive ? .off : .on) { _ in self.cancel() }]
                    items += Self.choices.map { m in
                        UIAction(title: "\(m) Minutes") { _ in self.set(minutes: m) }
                    }
                    if let endLabel {
                        items.append(UIAction(title: endLabel, state: self.atEndOfItem ? .on : .off) { _ in self.setEndOfItem() })
                    }
                    if let endsAt = self.endsAt {
                        items.insert(UIAction(title: "Stops at \(Fmt.time(endsAt))", attributes: .disabled) { _ in }, at: 0)
                    }
                    completion(items)
                }
            },
        ])
    }
}

/// Sleep Timer choices as a SwiftUI menu (Now Playing).
struct TVSleepTimerMenu: View {
    var endLabel = "End of Current Song"
    private var timer: TVSleepTimer { .shared }

    var body: some View {
        Menu {
            Button("Off") { timer.cancel() }
            ForEach(TVSleepTimer.choices, id: \.self) { m in
                Button("\(m) Minutes") { timer.set(minutes: m) }
            }
            Button(endLabel) { timer.setEndOfItem() }
        } label: {
            Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuStyle(.button)
    }
}
