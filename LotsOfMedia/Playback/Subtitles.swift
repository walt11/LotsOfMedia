import Foundation
import SwiftUI

/// One timed line of subtitle text.
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Parses SRT and WebVTT (Plex converts ASS/SSA/SMI sidecars to SRT for us).
enum SubtitleParser {
    static func parse(_ data: Data) -> [SubtitleCue] {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        // Blank lines (some files put spaces or tabs on them) separate cues.
        let blocks = text.replacingOccurrences(of: "\n[ \t]+\n", with: "\n\n", options: .regularExpression)
        for block in blocks.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]), let end = seconds(parts[1]) else { continue }
            let body = lines[(timeIndex + 1)...].joined(separator: "\n")
            let clean = stripMarkup(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345", "01:02.345" (VTT) or with trailing cue settings.
    static func seconds(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let pieces = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count) else { return nil }
        var total = 0.0
        for p in pieces { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }

    static func stripMarkup(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)   // <i>, <font …>
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)  // {\an8}
        out = out.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
        return out
    }

    /// Binary search for the cue showing at `time`.
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lo = 0, hi = cues.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let i = found else { return nil }
        // Overlapping cues (two speakers at once): every one still on screen, earliest on top.
        let showing = stride(from: i, through: max(0, i - 3), by: -1).reversed()
            .filter { cues[$0].start <= time && time < cues[$0].end }
        guard let first = showing.first else { return nil }
        guard showing.count > 1 else { return cues[first] }
        let last = cues[showing[showing.count - 1]]
        return SubtitleCue(start: last.start, end: showing.map { cues[$0].end }.min() ?? last.end,
                           text: showing.map { cues[$0].text }.joined(separator: "\n"))
    }
}

enum SubtitleSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
    var points: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 19
        case .large: return 24
        case .extraLarge: return 30
        }
    }
    static var current: SubtitleSize {
        get { SubtitleSize(rawValue: UserDefaults.standard.string(forKey: "subtitleSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "subtitleSize") }
    }
}

/// A subtitle choice in the player.
struct SubtitleOption: Identifiable, Hashable {
    enum Source: Hashable {
        case off
        /// Downloaded .srt next to an offline file.
        case localFile(URL)
        /// Sidecar text on the server – fetched and drawn by the app (no transcode).
        case sidecar(streamID: Int)
        /// Embedded text track AVPlayer can show itself (MP4 mov_text).
        case native(index: Int)
        /// Image or embedded subtitle the server must burn into the video.
        case burn(streamID: Int)
    }
    let id: String
    let label: String
    let detail: String?
    let source: Source

    static let off = SubtitleOption(id: "off", label: "Off", detail: nil, source: .off)
}

// MARK: - Views

/// Drawn in the player's content overlay (above video, below controls).
struct SubtitleOverlayView: View {
    @ObservedObject var playback: VideoPlaybackController

    var body: some View {
        GeometryReader { geo in
            // Sit near the bottom of the *picture*, not the screen (letterboxing in portrait).
            let r = playback.videoRect.width > 0 ? playback.videoRect : CGRect(origin: .zero, size: geo.size)
            VStack {
                Spacer()
                if let text = playback.subtitleText {
                    Text(text)
                        .font(.system(size: playback.subtitleSize.points, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 16)
                        .padding(.bottom, max(8, r.height * 0.06))
                }
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
        }
        // videoBounds is in full-view coordinates; don't let safe areas shift them.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// In-player subtitle settings: track, timing, size, online search.
struct SubtitleSheet: View {
    @ObservedObject var playback: VideoPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var searching = false
    @State private var results: [PlexStream] = []
    @State private var searchError: String?
    @State private var language = Locale.current.language.languageCode?.identifier ?? "en"
    @State private var adding: PlexStream?

    private let languages: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"), ("pl", "Polish"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Subtitles") {
                    ForEach(playback.subtitleOptions) { option in
                        Button {
                            Task { await playback.selectSubtitle(option) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let d = option.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if playback.selectedSubtitleID == option.id {
                                    Image(systemName: "checkmark").foregroundStyle(Cinema.accent)
                                }
                            }
                        }
                    }
                    if playback.isSwitchingSubtitles {
                        HStack { ProgressView(); Text("Switching…").foregroundStyle(.secondary) }
                    }
                }

                if playback.subtitlesAreAppRendered {
                    Section {
                        Stepper(value: $playback.subtitleOffset, in: -30...30, step: 0.25) {
                            LabeledContent("Timing", value: String(format: "%+.2fs", playback.subtitleOffset))
                        }
                        Picker("Size", selection: $playback.subtitleSize) {
                            ForEach(SubtitleSize.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }

                if playback.canSearchSubtitles {
                    Section {
                        Picker("Language", selection: $language) {
                            ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        Button {
                            Task { await search() }
                        } label: {
                            HStack {
                                Label("Search Online", systemImage: "magnifyingglass")
                                if searching { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(searching)
                        if let searchError { Text(searchError).font(.caption).foregroundStyle(.secondary) }
                        ForEach(results, id: \.self) { r in
                            Button {
                                Task { await add(r) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.displayTitle ?? r.title ?? r.language ?? "Subtitle").foregroundStyle(.primary).lineLimit(2)
                                        Text([r.providerTitle, r.codec?.uppercased(), r.hearingImpaired == true ? "SDH" : nil]
                                                .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if adding == r { ProgressView() } else { Image(systemName: "plus.circle") }
                                }
                            }
                            .disabled(adding != nil)
                        }
                    } header: {
                        Text("Find More Subtitles")
                    }
                }
            }
            .pageTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() async {
        searching = true
        searchError = nil
        defer { searching = false }
        do {
            results = try await playback.searchSubtitles(language: language)
            if results.isEmpty { searchError = "No subtitles found for this language." }
        } catch {
            searchError = error.localizedDescription
        }
    }

    private func add(_ r: PlexStream) async {
        adding = r
        defer { adding = nil }
        do {
            try await playback.addSubtitle(r)
            results = []
        } catch {
            searchError = "Couldn't add that subtitle: \(error.localizedDescription)"
        }
    }
}

/// Skip Intro / Skip Credits / Next Episode button, plus the subtitles button.
struct PlayerOverlayButtons: View {
    @ObservedObject var playback: VideoPlaybackController
    var showSubtitles: () -> Void
    var showQueue: () -> Void
    @State private var showDevices = false
    @State private var showInfo = false

    private func chapterLabel(_ c: PlexChapter) -> String { "\(Fmt.clock(seconds: Double(c.startTimeOffset) / 1000))  \(c.title)" }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            // Always shown while AirPlaying, not just with the controls.
            if let device = playback.airPlayDevice { AirPlayPill(deviceName: device) }
            if playback.chromeVisible || playback.isPaused {
                Menu {
                    Picker(selection: $playback.speed) {
                        ForEach(VideoPlaybackController.speeds, id: \.self) { Text(SpeedLabel.text($0)).tag($0) }
                    } label: { Label("Playback Speed · \(SpeedLabel.text(playback.speed))", systemImage: "gauge.with.dots.needle.67percent") }
                    .pickerStyle(.menu)
                    if !playback.chapters.isEmpty {
                        Menu {
                            ForEach(Array(playback.chapters.enumerated()), id: \.offset) { _, chapter in
                                Button { playback.jump(to: chapter) } label: {
                                    if chapter == playback.currentChapter { Label(chapterLabel(chapter), systemImage: "checkmark") }
                                    else { Text(chapterLabel(chapter)) }
                                }
                            }
                        } label: { Label("Chapters", systemImage: "list.number") }
                    }
                    SleepTimerMenu(player: playback.player, endLabel: "End of Current Video")
                    Button("Play on Another Device") { showDevices = true }
                    Button { showInfo = true } label: { Label("Playback Info", systemImage: "info.circle") }
                } label: { Image(systemName: "ellipsis.circle.fill").font(.title2) }.tint(.white)
                Button(action: showQueue) { Label("Up Next (\(playback.upNext.count))", systemImage: "list.bullet") }
                    .buttonStyle(.bordered).tint(.white).background(.ultraThinMaterial, in: Capsule())
            }
            if (playback.chromeVisible || playback.isPaused) && !playback.subtitleOptions.isEmpty {
                Button(action: showSubtitles) {
                    Label("Subtitles", systemImage: playback.selectedSubtitleID == "off" ? "captions.bubble" : "captions.bubble.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Subtitles")
                .transition(.opacity)
            }
            if let prompt = playback.skipPrompt {
                SkipButton(prompt: prompt, playback: playback)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showInfo) { PlaybackInfoView(source: .video(playback)) }
        .sheet(isPresented: $showDevices) { HandoffView(item: playback.request.item, serverID: playback.request.serverID, player: playback.player) }
        .animation(.easeInOut(duration: 0.25), value: playback.skipPrompt)
        .animation(.easeInOut(duration: 0.2), value: playback.chromeVisible || playback.isPaused)
        .padding(4)
    }
}

private struct SkipButton: View {
    let prompt: VideoPlaybackController.SkipPrompt
    @ObservedObject var playback: VideoPlaybackController

    var body: some View {
        HStack(spacing: 8) {
            if case .nextEpisode = prompt {
                Button { playback.dismissSkipPrompt() } label: {
                    Text("Watch Credits").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
            }
            Button { Task { await playback.performSkip() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title)
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.white, in: Capsule())
                .foregroundStyle(.black)
            }
        }
        .shadow(radius: 6)
    }

    private var title: String {
        switch prompt {
        case .intro: return "Skip Intro"
        case .credits: return "Skip Credits"
        case .nextEpisode(let s): return s > 0 ? "Next Episode in \(s)" : "Next Episode"
        }
    }

    private var icon: String {
        switch prompt {
        case .nextEpisode: return "forward.end.fill"
        default: return "forward.fill"
        }
    }
}


enum SpeedLabel {
    static func text(_ rate: Float) -> String {
        rate == 1 ? "Normal" : (rate.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f×", rate) : String(format: "%g×", rate))
    }
}
