import AVFoundation
import AVKit
import Observation
import SwiftUI

/// Whether audio/video is currently going to an AirPlay device, and which one.
@MainActor
@Observable
final class AirPlayStatus {
    static let shared = AirPlayStatus()

    private(set) var deviceName: String?
    var isActive: Bool { deviceName != nil }

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        update()
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AirPlayStatus.shared.update() }
        }
    }

    func update() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let airplay = outputs.first { $0.portType == .airPlay }
        deviceName = airplay.map { $0.portName.isEmpty ? "AirPlay" : $0.portName }
    }

    /// For a video player: AVPlayer reports external playback separately from the audio route.
    static func name(forExternal player: AVPlayer) -> String? {
        guard player.isExternalPlaybackActive else { return nil }
        return shared.deviceName ?? "AirPlay"
    }
}

/// "Playing on Living Room TV" pill. Tapping it opens the system route picker.
struct AirPlayPill: View {
    let deviceName: String
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplayvideo").font(.subheadline.weight(.bold))
            Text(compact ? deviceName : "Playing on \(deviceName)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(.black)
        .background(Cinema.accent, in: Capsule())
        .overlay {
            // Invisible system picker over the pill, so a tap changes or stops AirPlay.
            RoutePicker().opacity(0.02)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AirPlay: playing on \(deviceName). Double-tap to change.")
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// App-wide banner while music is AirPlaying (video players show their own).
struct AirPlayBanner: View {
    @Environment(AudioPlayer.self) private var audio
    private var status: AirPlayStatus { .shared }

    var body: some View {
        if let name = status.deviceName, audio.current != nil {
            AirPlayPill(deviceName: name)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
