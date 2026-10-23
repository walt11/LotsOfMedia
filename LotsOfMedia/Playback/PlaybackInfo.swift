import AVFoundation
import SwiftUI

/// Everything useful for "why is this buffering / converting?", as labelled rows.
struct PlaybackDiagnostics {
    struct Section: Identifiable { var title: String; var rows: [(String, String)]; var id: String { title } }
    var sections: [Section] = []

    mutating func add(_ title: String, _ rows: [(String, String?)]) {
        let present = rows.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
        if !present.isEmpty { sections.append(Section(title: title, rows: present)) }
    }
}

/// Plain-text report for sharing. Never contains account tokens.
enum PlaybackReport {
    static func text(_ d: PlaybackDiagnostics, date: Date = Date()) -> String {
        var out = ["LotsOfMedia playback report", date.formatted(date: .abbreviated, time: .standard), ""]
        for s in d.sections {
            out.append("[\(s.title)]")
            out += s.rows.map { "\($0.0): \($0.1)" }
            out.append("")
        }
        return redact(out.joined(separator: "\n"))
    }

    /// Strips Plex tokens from any URL or header-like text ("X-Plex-Token=…", "token: …").
    static func redact(_ text: String) -> String {
        var s = text
        let patterns = [
            #"(?i)(x-plex-token=)[^&\s"]+"#,
            #"(?i)(x-plex-token["']?\s*[:=]\s*["']?)[^&\s"',]+"#,
            #"(?i)([?&]token=)[^&\s"]+"#,
            #"(?i)(authToken["']?\s*[:=]\s*["']?)[^&\s"',]+"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "$1REDACTED", options: .regularExpression)
        }
        return s
    }
}

@MainActor
enum DiagnosticsBuilder {
    struct Input {
        var item: PlexMetadata
        var serverID: String
        var mode: String
        var isDownloaded: Bool
        var isConverting: Bool
        var transcodeSessionID: String?
        var qualitySetting: String
        var playerItem: AVPlayerItem?
        var error: String?
        /// Which player is playing it ("Apple's player", "Built-in player").
        var player: String? = nil
    }

    /// What could make this play better, in plain words.
    struct AdviceFacts {
        var isDownloaded = false
        var isConverting = false
        var incompatibilities: [String] = []
        var qualityIsOriginal = true
        var builtInPlayerOff = false
        var imageSubtitle = false
        var relay = false
        var cellular = false
        var stalls = 0
        var serverSpeed: Double?
    }

    nonisolated static func advice(_ f: AdviceFacts) -> [String] {
        guard !f.isDownloaded else { return [] }
        var out: [String] = []
        if f.isConverting, !f.incompatibilities.isEmpty, f.builtInPlayerOff {
            out.append("Turn on the Built-in Player (Playback Preferences) to play this file directly instead of converting it.")
        }
        if f.isConverting, f.incompatibilities.isEmpty, !f.qualityIsOriginal {
            out.append("Set Streaming Quality to Original to play the file as-is.")
        }
        if f.imageSubtitle, f.isConverting {
            out.append("Image subtitles are drawn into the picture by the server; turn them off or pick a text subtitle to avoid converting.")
        }
        if let speed = f.serverSpeed, speed < 1 {
            out.append("Your server converts slower than real time. Turn on hardware-accelerated conversion in Plex's settings, or play the original.")
        }
        if f.relay {
            out.append("This plays through Plex Relay, which limits speed. Turning on Remote Access on your server gives a direct connection.")
        }
        if f.stalls > 0, f.cellular, f.qualityIsOriginal {
            out.append("On cellular, a lower Streaming Quality can stop the pauses.")
        } else if f.stalls > 2, !f.isConverting {
            out.append("It paused to load. A lower Streaming Quality makes a smaller stream that loads faster.")
        }
        return out
    }

    static func build(_ input: Input) async -> PlaybackDiagnostics {
        var d = PlaybackDiagnostics()
        let item = input.item
        let media = item.primaryMedia
        let part = item.primaryPart

        // Why it plays the way it does.
        var why: String?
        if input.isDownloaded { why = "Playing the copy saved on this iPhone." }
        else if input.isConverting, let media {
            let problems = PlaybackDecider.incompatibilities(media: media, kind: item.kind)
            why = problems.isEmpty ? "Converting to match the \(input.qualitySetting) quality setting or the selected subtitle."
                : "iPhone can't play " + ListFormatter.localizedString(byJoining: problems) + "."
        } else if !input.isConverting { why = "The original file plays as-is." }
        d.add("Playback", [("Mode", input.mode), ("Player", input.player), ("Why", why), ("Quality setting", input.qualitySetting),
                           ("Title", item.kind == .episode ? [item.grandparentTitle, item.subtitleLine].compactMap { $0 }.joined(separator: " · ") : item.title)])

        d.add("Source File", [
            ("Container", (media?.container ?? part?.container)?.uppercased()),
            ("Video", [media?.videoCodec?.uppercased(), media?.resolutionLabel].compactMap { $0 }.joined(separator: " · ")),
            ("Audio", part?.selectedAudio?.displayTitle ?? media?.audioCodec?.uppercased()),
            ("Subtitles", part?.selectedSubtitle?.displayTitle ?? "Off"),
            ("Bitrate", media?.bitrate.map { "\($0) kbps" }),
            ("Size", part?.size.map(Fmt.bytes)),
        ])

        if let p = input.playerItem {
            let log = p.accessLog()?.events.last
            let size = p.presentationSize
            d.add("Stream", [
                ("Picture", size.width > 0 ? "\(Int(size.width))×\(Int(size.height))" : nil),
                ("Indicated bitrate", log.flatMap { $0.indicatedBitrate > 0 ? "\(Int($0.indicatedBitrate / 1000)) kbps" : nil }),
                ("Measured throughput", log.flatMap { $0.observedBitrate > 0 ? "\(Int($0.observedBitrate / 1000)) kbps" : nil }),
                ("Stalls", log.map { "\($0.numberOfStalls)" }),
                ("Dropped frames", log.map { "\($0.numberOfDroppedVideoFrames)" }),
                ("Buffered ahead", bufferedAhead(p)),
            ])
        }

        // Connection, without credentials.
        let server = ServerDirectory.shared.server(id: input.serverID)
        let uri = ServerDirectory.shared.endpointURI(for: input.serverID)
        let connection = server?.connections.first { $0.uri == uri }
        let kind = input.isDownloaded ? "Not needed (downloaded)"
            : connection.map { $0.relay ? "Plex Relay (limited speed)" : $0.local ? "Local network" : "Remote (direct)" } ?? "Unknown"
        d.add("Connection", [("Server", server?.name), ("Route", kind),
                             ("Address", input.isDownloaded ? nil : uri.flatMap { URL(string: $0)?.host }),
                             ("Network", NetworkMonitor.shared.isConnected ? (NetworkMonitor.shared.usesWiFi ? "Wi-Fi" : "Cellular") : "Offline")])

        if input.isConverting, let sid = input.transcodeSessionID, let api = ServerDirectory.shared.api(for: input.serverID),
           let session = await transcodeSession(api: api, id: sid) {
            d.add("Server Conversion", [
                ("Video", decision(session["videoDecision"], from: session["sourceVideoCodec"], to: session["videoCodec"])),
                ("Audio", decision(session["audioDecision"], from: session["sourceAudioCodec"], to: session["audioCodec"])),
                ("Speed", (session["speed"] as? Double).map { String(format: "%.1f× realtime", $0) }),
                ("Hardware", (session["transcodeHwFullPipeline"] as? Bool).map { $0 ? "Full hardware" : ((session["transcodeHwRequested"] as? Bool) == true ? "Partial" : "Software") }),
                ("Throttled", (session["throttled"] as? Bool).map { $0 ? "Yes (ahead of playback)" : "No" }),
            ])
        }

        // Suggestions that could make it play better.
        var facts = AdviceFacts()
        facts.isDownloaded = input.isDownloaded
        facts.isConverting = input.isConverting
        facts.incompatibilities = media.map { PlaybackDecider.incompatibilities(media: $0, kind: item.kind) } ?? []
        facts.qualityIsOriginal = input.qualitySetting == "Original" || input.qualitySetting.hasPrefix("Original")
        facts.builtInPlayerOff = item.kind != .track && !BuiltInPlayer.isEnabled
        if let sub = part?.selectedSubtitle, let codec = sub.codec?.lowercased() {
            // Image subtitles (PGS, VobSub…) are neither a text format nor one Apple's player draws.
            facts.imageSubtitle = !PlexStream.textSubtitleCodecs.contains(codec) && !PlaybackDecider.nativeTextSubtitleCodecs.contains(codec)
        }
        facts.relay = connection?.relay == true
        facts.cellular = NetworkMonitor.shared.isConnected && !NetworkMonitor.shared.usesWiFi
        facts.stalls = input.playerItem?.accessLog()?.events.last?.numberOfStalls ?? 0
        if input.isConverting, let sid = input.transcodeSessionID, let api = ServerDirectory.shared.api(for: input.serverID) {
            facts.serverSpeed = await transcodeSession(api: api, id: sid)?["speed"] as? Double
        }
        let tips = advice(facts)
        if !tips.isEmpty { d.add("Improve Playback", tips.enumerated().map { ("Tip \($0.offset + 1)", Optional($0.element)) }) }

        var errors: [(String, String?)] = [("Message", input.error)]
        if let event = input.playerItem?.errorLog()?.events.last {
            errors.append(("Last stream error", "\(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "")"))
        }
        if let e = input.playerItem?.error as NSError? { errors.append(("Player error", "\(e.domain) \(e.code): \(e.localizedDescription)")) }
        d.add("Errors", errors)
        return d
    }

    private static func bufferedAhead(_ item: AVPlayerItem) -> String? {
        let now = item.currentTime().seconds
        guard let range = item.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.start.seconds <= now && now <= $0.end.seconds }) else { return nil }
        return String(format: "%.0f s", range.end.seconds - now)
    }

    private static func decision(_ decision: Any?, from: Any?, to: Any?) -> String? {
        guard let decision = decision as? String else { return nil }
        let codecs = [(from as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }, (to as? String).flatMap { $0 == "*" || $0.isEmpty ? nil : $0.uppercased() }]
            .compactMap { $0 }.joined(separator: " → ")
        let word = decision == "copy" ? "Copied" : decision == "transcode" ? "Converted" : decision.capitalized
        return codecs.isEmpty ? word : "\(word) (\(codecs))"
    }

    private static func transcodeSession(api: PlexServerAPI, id: String) async -> [String: Any]? {
        guard let (body, _) = try? await api.data("/transcode/sessions", timeout: 8),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessions = (root["MediaContainer"] as? [String: Any])?["TranscodeSession"] as? [[String: Any]] else { return nil }
        return sessions.first { ($0["key"] as? String).map { $0.hasSuffix(id) } ?? false }
    }
}

struct PlaybackInfoView: View {
    enum Source {
        case video(VideoPlaybackController)
        case music
    }
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics = PlaybackDiagnostics()

    var body: some View {
        NavigationStack {
            List {
                ForEach(diagnostics.sections) { section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            LabeledContent(row.0) {
                                Text(row.1).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .pageTitle("Playback Info")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: PlaybackReport.text(diagnostics)) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share report (no account details)")
                }
            }
            .task {
                // Refresh while open: stalls and throughput change as it plays.
                while !Task.isCancelled {
                    diagnostics = await build()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func build() async -> PlaybackDiagnostics {
        switch source {
        case .video(let p): return await DiagnosticsBuilder.build(p.diagnosticsInput)
        case .music:
            guard let input = AudioPlayer.shared.diagnosticsInput else { return PlaybackDiagnostics() }
            return await DiagnosticsBuilder.build(input)
        }
    }
}
