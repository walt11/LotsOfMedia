import AVFoundation
import Foundation

/// Video quality on Apple TV. Automatic plays the original file except over a Plex relay, which
/// is too slow for it; a fixed choice limits every video to that quality.
enum TVVideoQuality {
    static let preferenceKey = "tv.videoQuality"

    /// nil: Automatic.
    static var fixed: StreamingQuality? {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(StreamingQuality.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: preferenceKey) }
    }

    /// Plex relays are capped at a few megabits per second.
    static let relayQuality: StreamingQuality = .q2

    static func current(isRelay: Bool) -> StreamingQuality { fixed ?? (isRelay ? relayQuality : .original) }

    static var label: String { fixed?.label ?? "Automatic" }
}

/// Audio and subtitle languages chosen on Apple TV, remembered per profile and server (as on
/// iPhone), and applied to the next video.
enum TVLanguagePreference {
    @MainActor static func scope(session: TVSession) -> String {
        "\(session.currentHomeUser?.uuid ?? session.user?.uuid ?? "local")|\(session.selectedServerID ?? "none")"
    }
    static func audio(scope: String) -> String? { UserDefaults.standard.string(forKey: "tv.lang.audio." + scope) }
    /// ISO 639-2 code, "off", or nil when there's no preference yet.
    static func subtitle(scope: String) -> String? { UserDefaults.standard.string(forKey: "tv.lang.subtitle." + scope) }
    static func rememberAudio(_ code: String?, scope: String) {
        guard let code, !code.isEmpty else { return }
        UserDefaults.standard.set(code, forKey: "tv.lang.audio." + scope)
    }
    /// `nil` means subtitles were turned off.
    static func rememberSubtitle(_ code: String?, scope: String) {
        UserDefaults.standard.set(code ?? "off", forKey: "tv.lang.subtitle." + scope)
    }

    /// The three-letter code Plex uses ("eng") for a track in Apple's player.
    static func code(for option: AVMediaSelectionOption?) -> String? {
        guard let option else { return nil }
        if let alpha3 = option.locale?.language.languageCode?.identifier(.alpha3) { return alpha3 }
        guard let tag = option.extendedLanguageTag else { return nil }
        return Locale(identifier: tag).language.languageCode?.identifier(.alpha3)
    }

    /// The player's current audio and subtitle choice, as Plex language codes (subtitle nil = off).
    static func selection(in item: AVPlayerItem) async -> (audio: String?, subtitle: String?)? {
        let asset = item.asset
        guard let audible = try? await asset.loadMediaSelectionGroup(for: .audible) else { return nil }
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        let selection = item.currentMediaSelection
        let subtitle = legible.flatMap { selection.selectedMediaOption(in: $0) }
        return (code(for: selection.selectedMediaOption(in: audible)),
                subtitle?.hasMediaCharacteristic(.containsOnlyForcedSubtitles) == true ? nil : code(for: subtitle))
    }

    /// Picks the remembered languages among the file's own tracks (direct play: Apple's player
    /// otherwise starts on the file's default track).
    static func apply(scope: String, to item: AVPlayerItem) async {
        let asset = item.asset
        if let audio = audio(scope: scope), let group = try? await asset.loadMediaSelectionGroup(for: .audible),
           code(for: item.currentMediaSelection.selectedMediaOption(in: group)) != audio,
           let match = group.options.first(where: { code(for: $0) == audio }) {
            item.select(match, in: group)
        }
        guard let subtitle = subtitle(scope: scope), let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        if subtitle == "off" {
            if group.allowsEmptySelection { item.select(nil, in: group) }
        } else if let match = group.options.first(where: { code(for: $0) == subtitle && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) {
            item.select(match, in: group)
        }
    }
}
