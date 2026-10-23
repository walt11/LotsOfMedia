#if os(iOS)
import UIKit
#endif

/// Light touch feedback for actions: play, favorite, mark watched, download, record, purchase.
/// Callable from anywhere; does nothing on Apple TV.
enum Haptics {
    static func tap() {
        #if os(iOS)
        Task { @MainActor in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        #endif
    }

    static func success() {
        #if os(iOS)
        Task { @MainActor in UINotificationFeedbackGenerator().notificationOccurred(.success) }
        #endif
    }
}
