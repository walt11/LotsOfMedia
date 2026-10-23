import SwiftUI

/// Song lyrics from the Plex server (a lyrics stream on the track: LRC with timings, or plain text).
struct Lyrics: Equatable {
    struct Line: Equatable, Identifiable { let id: Int; let time: Double?; let text: String }
    let lines: [Line]
    var isSynced: Bool { lines.contains { $0.time != nil } }

    /// Reads LRC ("[01:23.45] words", possibly several stamps per line) or plain text.
    static func parse(_ text: String) -> Lyrics? {
        var timed: [(Double, String)] = []
        var plain: [String] = []
        let stamp = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let stamps = line.matches(of: stamp)
            if stamps.isEmpty {
                // Metadata tags such as [ar:Artist] are skipped.
                if line.hasPrefix("[") && line.hasSuffix("]") && line.contains(":") { continue }
                plain.append(line)
                continue
            }
            let words = String(line[(stamps.last!.range.upperBound)...]).trimmingCharacters(in: .whitespaces)
            for m in stamps {
                let minutes = Double(m.output.1) ?? 0, seconds = Double(m.output.2) ?? 0
                let fraction = m.output.3.map { Double("0." + $0) ?? 0 } ?? 0
                timed.append((minutes * 60 + seconds + fraction, words))
            }
        }
        if !timed.isEmpty {
            let sorted = timed.sorted { $0.0 < $1.0 }
            return Lyrics(lines: sorted.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) })
        }
        let trimmed = plain.drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed()
        guard !trimmed.isEmpty else { return nil }
        return Lyrics(lines: trimmed.enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) })
    }

    /// The line being sung at `time` (synced lyrics only).
    func currentLine(at time: Double) -> Int? {
        guard isSynced else { return nil }
        return lines.lastIndex { ($0.time ?? .infinity) <= time + 0.2 }
    }

    enum LoadResult: Equatable { case found(Lyrics), missing, failed }

    /// Fetches a track's lyrics: its full metadata carries the lyrics stream (type 4).
    /// `.missing` means the server has no lyrics for it; `.failed`, that it couldn't be asked.
    @MainActor
    static func load(for track: PlexMetadata, serverID: String) async -> LoadResult {
        guard let api = ServerDirectory.shared.api(for: serverID) else { return .failed }
        let full: PlexMetadata?
        do { full = try await api.metadata(track.ratingKey) } catch { return .failed }
        guard let stream = full?.media.first?.parts.first?.streams.first(where: { $0.streamType == 4 && $0.key != nil }),
              let key = stream.key else { return .missing }
        guard let (data, _) = try? await api.data(key) else { return .failed }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return parse(text).map { .found($0) } ?? .missing
    }
}

/// Lyrics for the song playing: synced lyrics follow along and scroll (until you scroll away to
/// read; Follow Lyrics brings it back); plain lyrics just read.
struct LyricsView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var result: Lyrics.LoadResult?
    @State private var following = true
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                switch result {
                case .found(let lyrics): lyricsList(lyrics)
                case .missing:
                    ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                                           description: Text("Your server doesn't have lyrics for this song."))
                case .failed:
                    ContentUnavailableView {
                        Label("Couldn't Load Lyrics", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Your server couldn't be reached.")
                    } actions: {
                        Button("Try Again") { attempt += 1 }.prominentButton()
                    }
                case nil: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [player.artworkTint ?? Cinema.surface, Cinema.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle(player.current?.track.title ?? "Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Keyed by the queue entry (server and song), so another server's song with the same
        // key reloads; a late answer for a song no longer playing is dropped.
        .task(id: "\(player.current?.id.uuidString ?? "")-\(attempt)") {
            result = nil
            following = true
            guard let entry = player.current else { result = .missing; return }
            let loaded = await Lyrics.load(for: entry.track, serverID: entry.serverID)
            guard !Task.isCancelled, player.current?.id == entry.id else { return }
            result = loaded
        }
    }

    private func lyricsList(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let current = lyrics.currentLine(at: player.currentTime)
                    ForEach(lyrics.lines) { line in
                        let text = Text(line.text.isEmpty ? "♪" : line.text).font(.title2.bold())
                        if let time = line.time {
                            Button { player.seek(to: time); following = true } label: {
                                text.foregroundStyle(line.id == current ? Color.white : Color.white.opacity(0.45))
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(line.text.isEmpty ? "Instrumental" : line.text)
                            .accessibilityHint("Plays from this line")
                            .id(line.id)
                        } else {
                            text.foregroundStyle(.white).id(line.id)
                        }
                    }
                }
                .padding(24)
                // Room so the floating Follow Lyrics button never covers the last lines.
                .padding(.bottom, lyrics.isSynced ? 90 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Opened mid-song (even paused): start at the line being sung.
            .onAppear {
                guard let line = lyrics.currentLine(at: player.currentTime) else { return }
                DispatchQueue.main.async { proxy.scrollTo(line, anchor: .center) }
            }
            // Reading ahead or back: stop following until asked.
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if lyrics.isSynced { following = false } })
            .overlay(alignment: .bottom) {
                if lyrics.isSynced && !following {
                    Button {
                        following = true
                        if let line = lyrics.currentLine(at: player.currentTime) { withAnimation { proxy.scrollTo(line, anchor: .center) } }
                    } label: { Label("Follow Lyrics", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .prominentButton()
                    .padding(.bottom, 24)
                }
            }
            .onChange(of: lyrics.currentLine(at: player.currentTime)) { _, line in
                if following, let line { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) } }
            }
        }
    }
}
