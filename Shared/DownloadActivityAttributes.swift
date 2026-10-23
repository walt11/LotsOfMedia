import ActivityKit
import Foundation

/// Live Activity (Lock Screen + Dynamic Island) for offline downloads.
/// Compiled into both the app and the widget extension.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading, converting, waiting, paused, finishing, done, failed
        }

        var phase: Phase
        /// Item currently transferring (or the last one to finish).
        var title: String
        var subtitle: String?
        /// Overall progress across all active downloads, 0...1.
        var progress: Double
        var bytesDone: Int64
        var bytesTotal: Int64
        var remainingItems: Int
        var completedItems: Int
        /// When set, the UI animates progress between these dates on its own,
        /// so the bar keeps moving while the app is suspended and can't push updates.
        var estimateStart: Date?
        var estimateEnd: Date?
        /// Items the server is still converting (shown alongside downloads).
        var convertingCount: Int = 0
        /// Average server conversion progress, 0...1, while converting.
        var conversionProgress: Double?
        /// Why the current item is being converted ("iPhone can't play MKV files").
        var conversionReason: String?
        /// Everything in this run is music ("ready to listen" rather than "watch").
        var isAudio: Bool?
    }
}
