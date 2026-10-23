import AVKit
import CoreMedia
import SwiftUI

// MARK: - Match the TV to the video

/// Asks tvOS to switch the TV to the video's frame rate and dynamic range (when the viewer has
/// Match Content on in Apple TV settings). Apple's player does this itself for what it plays;
/// the built-in player describes the file from Plex's details instead.
enum TVDisplayMatch {
    @MainActor static func apply(for item: PlexMetadata, in view: UIView?) {
        guard let window = view?.window ?? Self.keyWindow else { return }
        window.avDisplayManager.preferredDisplayCriteria = criteria(for: item)
    }

    @MainActor static func reset(in view: UIView?) {
        (view?.window ?? Self.keyWindow)?.avDisplayManager.preferredDisplayCriteria = nil
    }

    @MainActor private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    static func criteria(for item: PlexMetadata) -> AVDisplayCriteria? {
        guard let media = item.primaryMedia,
              let video = media.parts.first?.streams.first(where: { $0.streamType == 1 }),
              let rate = video.frameRate, rate > 0 else { return nil }
        var extensions: [CFString: Any] = [:]
        var codec = kCMVideoCodecType_HEVC
        if video.doviPresent == true {
            codec = kCMVideoCodecType_DolbyVisionHEVC
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        } else if video.colorTrc == "smpte2084" {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        } else if video.colorTrc == "arib-std-b67" {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        } else {
            codec = kCMVideoCodecType_H264
            extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec,
                                       width: Int32(media.width ?? 1920), height: Int32(media.height ?? 1080),
                                       extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard let format else { return nil }
        return AVDisplayCriteria(refreshRate: Float(rate), formatDescription: format)
    }
}

// MARK: - Up Next

/// The next episode after the one playing, and when to offer it: at the final credits, or 30
/// seconds before the end when the episode has no credits marker.
enum TVUpNext {
    /// How long the countdown runs before the next episode starts by itself.
    static let countdown = 10

    @MainActor
    static func next(after item: PlexMetadata, queue: [PlexMetadata], index: Int, session: TVSession) async -> PlexMetadata? {
        if queue.indices.contains(index + 1) { return queue[index + 1] }
        guard item.kind == .episode, let api = session.api else { return nil }
        return try? await api.episodes(after: item, limit: 1).first
    }

    /// Milliseconds into the episode where Up Next appears.
    static func trigger(for item: PlexMetadata, durationMs: Int) -> Int? {
        guard durationMs > 60_000 else { return nil }
        // The final credits, not the first: credits that roll over the last scene, or before a
        // scene after the credits, get their own earlier marker.
        let credits = item.markers.filter { $0.isCredits && $0.startTimeOffset > durationMs / 2 }
        if let end = credits.first(where: { $0.final == true }) ?? credits.max(by: { $0.startTimeOffset < $1.startTimeOffset }) {
            return end.startTimeOffset
        }
        return durationMs - 30_000
    }

    static func label(_ next: PlexMetadata) -> String {
        if next.kind == .episode, let e = next.index {
            return "S\(next.parentIndex ?? 1) E\(e) · \(next.title)"
        }
        return next.title
    }
}

/// Seconds left on the Up Next countdown, counted in playback from where Up Next appeared (so
/// pausing pauses it). Resuming or jumping into the credits starts the full countdown, and a
/// skip while it runs doesn't use it up.
struct TVUpNextCountdown {
    private var anchorMs: Int?
    private var lastMs = 0

    mutating func reset() { anchorMs = nil }

    mutating func secondsLeft(atMs ms: Int) -> Int {
        let jump = ms - lastMs
        lastMs = ms
        if let anchor = anchorMs {
            // Playing moves ~1 s between updates; anything else is a seek.
            if jump < 0 || jump > 2500 { anchorMs = anchor + jump }
        } else {
            anchorMs = ms
        }
        return max(0, TVUpNext.countdown - (ms - (anchorMs ?? ms)) / 1000)
    }
}

/// Up Next card for the built-in player: the next episode's picture and title, a countdown,
/// Play Now and Hide.
struct TVUpNextCard: View {
    let next: PlexMetadata
    let secondsLeft: Int
    let playNow: () -> Void
    let hide: () -> Void
    var playFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 28) {
            TVImage(path: next.thumb ?? next.grandparentThumb, width: 480, height: 270, placeholderIcon: "play.rectangle")
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text("UP NEXT IN \(secondsLeft)").font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                Text(next.grandparentTitle ?? next.title).font(.headline).lineLimit(1)
                Text(TVUpNext.label(next)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 20) {
                    Button(action: playNow) { Label("Play Now", systemImage: "play.fill") }
                        .focused(playFocused)
                    Button("Hide", action: hide)
                }
                .buttonStyle(TVActionStyle(compact: true))
            }
            .frame(width: 520, alignment: .leading)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .focusSection()
    }
}
