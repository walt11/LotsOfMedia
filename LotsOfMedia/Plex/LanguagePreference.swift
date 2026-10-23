import Foundation

/// Which audio/subtitle streams to switch to so a video matches the remembered languages.
enum LanguagePreference {
    struct Change: Equatable { var audioStreamID: Int?; var subtitleStreamID: Int? }

    /// nil when the current selection already matches (or nothing matching exists).
    /// `subtitleStreamID == 0` means turn subtitles off.
    static func change(for part: PlexPart?, audio: String?, subtitle: String?) -> Change? {
        guard let part else { return nil }
        var change = Change()
        if let audio, part.selectedAudio?.languageCode != audio,
           let match = part.audioStreams.first(where: { $0.languageCode == audio }) {
            change.audioStreamID = match.id
        }
        if subtitle == "off" {
            if part.selectedSubtitle != nil { change.subtitleStreamID = 0 }
        } else if let subtitle, part.selectedSubtitle?.languageCode != subtitle {
            let candidates = part.subtitleStreams.filter { $0.languageCode == subtitle }
            // Prefer full subtitles over forced (foreign-parts-only) tracks.
            if let match = candidates.first(where: { $0.forced != true }) ?? candidates.first { change.subtitleStreamID = match.id }
        }
        return change == Change() ? nil : change
    }
}
