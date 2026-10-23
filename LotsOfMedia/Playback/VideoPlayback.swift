import AVKit
import SwiftUI
import Combine

struct VideoPlayRequest: Identifiable {
    let id = UUID()
    let item: PlexMetadata
    let serverID: String
    let startMs: Int
    /// Set when playing a completed download.
    let localURL: URL?
    let downloadID: String?
}

/// Owns an AVPlayer for one video and keeps Plex informed of progress.
/// Also drives Skip Intro/Credits and app-rendered subtitles.
@MainActor
final class VideoPlaybackController: ObservableObject, VideoQueueing {
    enum SkipPrompt: Equatable {
        case intro(endMs: Int)
        case credits(endMs: Int)
        case nextEpisode(seconds: Int)
    }

    let player = AVPlayer()
    @Published private(set) var request: VideoPlayRequest
    /// Items that play automatically after the current one (playlist / next episodes).
    @Published private(set) var upNext: [VideoPlayRequest] = []
    @Published var errorMessage: String?
    @Published var modeDescription = ""
    /// The AirPlay device this video is playing on, if any.
    @Published private(set) var airPlayDevice: String?

    // Skip markers
    @Published private(set) var skipPrompt: SkipPrompt?
    @Published private(set) var chromeVisible = false
    @Published private(set) var isPaused = false
    /// Where the picture is drawn inside the player (for subtitle placement).
    @Published var videoRect: CGRect = .zero

    // Subtitles
    @Published private(set) var subtitleOptions: [SubtitleOption] = []
    @Published private(set) var selectedSubtitleID = SubtitleOption.off.id
    @Published private(set) var subtitleText: String?
    @Published private(set) var isSwitchingSubtitles = false
    @Published var subtitleOffset: Double = 0
    @Published var subtitleSize: SubtitleSize = .current { didSet { SubtitleSize.current = subtitleSize } }
    var subtitlesAreAppRendered: Bool { !cues.isEmpty }
    var canSearchSubtitles: Bool { api != nil && request.localURL == nil && NetworkMonitor.shared.isConnected }

    private let userID: String?
    private var transition = PlaybackTransitionGate()
    private var metadata: PlexMetadata
    private var sessionID = UUID().uuidString
    private var quality: StreamingQuality = .original
    private var isLocalConnection = true
    private var itemCancellables = Set<AnyCancellable>()
    private var api: PlexServerAPI?
    private var isTranscoding = false
    private var burnSubtitleID: Int?
    private var triedTranscodeFallback = false
    /// A conversion the server ended (left paused, or the app was away) was restarted once.
    private var restartedConversion = false
    /// The current stream opened at least once (a failure later is the server ending it, not a format problem).
    private var streamOpened = false
    /// A conversion failed before it ever opened: ask the server for H.264 instead of copying HEVC.
    private var avoidHEVC = false
    private var timeObserver: Any?
    private var subtitleObserver: Any?
    private var cues: [SubtitleCue] = []
    private var nativeLegible: [AVMediaSelectionOption] = []
    private var cancellables = Set<AnyCancellable>()
    private var lastReported = Date.distantPast
    private var lastState = ""
    private var stopped = false
    private var dismissedMarkerStart: Int?
    private var countdownMarkerStart: Int?
    private var countdown = 10
    /// Playback time counted toward the countdown, and where it was last measured. Only normal
    /// playback counts: the time observer also fires on seeks, which mustn't use it up.
    private var countdownPlayedMs = 0
    private var countdownLastPos: Int?
    private var chromeHideTask: Task<Void, Never>?

    /// Hands the rest of the queue to the built-in player when the next item needs it.
    var handOff: ((_ next: VideoPlayRequest, _ rest: [VideoPlayRequest]) -> Void)?

    init(request: VideoPlayRequest, upNext: [VideoPlayRequest] = []) {
        self.userID = DownloadManager.shared.activeUserID
        self.request = request
        self.upNext = upNext
        self.metadata = request.item
        self.api = ServerDirectory.shared.api(for: request.serverID)
    }

    func enqueue(_ requests: [VideoPlayRequest]) {
        var known = Set((upNext + [request]).map { "\($0.serverID):\($0.item.ratingKey)" })
        upNext += requests.filter { known.insert("\($0.serverID):\($0.item.ratingKey)").inserted }
    }

    func playNext(_ next: VideoPlayRequest) {
        upNext.removeAll { $0.serverID == next.serverID && $0.item.ratingKey == next.item.ratingKey }
        upNext.insert(next, at: 0)
    }

    func removeUpcoming(at offsets: IndexSet) {
        guard offsets.allSatisfy({ upNext.indices.contains($0) }) else { return }
        upNext.remove(atOffsets: offsets)
    }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ upNext.indices.contains($0) }), (0...upNext.count).contains(destination) else { return }
        upNext.move(fromOffsets: offsets, toOffset: destination)
    }

    func start(quality: StreamingQuality, isLocalConnection: Bool) {
        PlaybackFocus.claim(player)
        AudioPlayer.shared.pause()
        self.quality = quality
        self.isLocalConnection = isLocalConnection
        begin(request)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
        player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    AirPlayStatus.shared.update()
                    self.airPlayDevice = AirPlayStatus.name(forExternal: self.player)
                }
            }
            .store(in: &cancellables)
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                Task { @MainActor in
                    if let self, self.player.timeControlStatus == .playing { PlaybackFocus.claim(self.player) }
                    self?.isPaused = status == .paused
                    self?.report(force: true)
                }
            }
            .store(in: &cancellables)
        noteInteraction()   // system controls are visible when playback starts
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                let id = self.request.id
                Task { @MainActor in
                    if PlaybackSleepTimer.shared.consumeEnd(for: self.player) { self.report(force: true, state: "stopped"); return }
                    await self.advance(from: id)
                }
            }
            .store(in: &cancellables)
    }

    /// Finish the current item and roll on to the next queued one.
    private func advance(from id: UUID) async {
        guard !stopped, id == request.id, transition.begin(id) else { return }
        defer { transition.end(id) }
        skipPrompt = nil
        if PlaybackSleepTimer.shared.endsWithItem(for: player) { PlaybackSleepTimer.shared.cancel() }
        let final = report(force: true, state: "stopped")
        if let final { await PlaybackReportDeadline.wait(for: final) }
        guard !stopped, id == request.id else { return }
        stopCurrentTranscode()
        guard !stopped, !upNext.isEmpty else { return }
        let next = upNext.removeFirst()
        if let handOff, BuiltInPlayer.handles(next, quality: quality) {
            let rest = upNext
            upNext = []
            handOff(next, rest)
            return
        }
        sessionID = UUID().uuidString
        api = ServerDirectory.shared.api(for: next.serverID)
        begin(next)
    }

    private func begin(_ r: VideoPlayRequest) {
        request = r
        metadata = r.item
        isTranscoding = false
        burnSubtitleID = nil
        triedTranscodeFallback = false
        restartedConversion = false
        avoidHEVC = false
        lastState = ""
        errorMessage = nil
        skipPrompt = nil
        dismissedMarkerStart = nil
        countdownMarkerStart = nil
        clearCues()
        nativeLegible = []
        subtitleOptions = []
        selectedSubtitleID = SubtitleOption.off.id
        itemCancellables.removeAll()

        chapters = r.item.chapters
        if let local = request.localURL {
            modeDescription = "Downloaded"
            load(url: local, start: request.startMs)
        } else if let api {
            // Switch to the remembered audio/subtitle languages first, so the stream uses them.
            let prefs = MediaPreferences.shared
            if let change = LanguagePreference.change(for: r.item.primaryPart, audio: prefs.preferredAudioLanguage(scope: preferenceScope),
                                                      subtitle: prefs.preferredSubtitleLanguage(scope: preferenceScope)),
               let partID = r.item.primaryPart?.id {
                modeDescription = "Applying language preferences"
                Task {
                    try? await api.selectStreams(partID: partID, audioStreamID: change.audioStreamID, subtitleStreamID: change.subtitleStreamID)
                    let fresh = (try? await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(r.item.ratingKey) }) ?? nil
                    guard !stopped, request.id == r.id else { return }
                    if let fresh { metadata = fresh }
                    startStreaming(fresh ?? r.item, api: api)
                }
            } else {
                startStreaming(r.item, api: api)
            }
        } else {
            errorMessage = "Server unavailable."
        }

        // Fresh metadata brings intro/credit markers and the full subtitle list.
        Task { [ratingKey = r.item.ratingKey] in
            if let api, request.localURL == nil || NetworkMonitor.shared.isConnected,
               let fresh = try? await api.metadata(ratingKey), request.item.ratingKey == ratingKey {
                metadata = fresh
                chapters = fresh.chapters
            }
            guard request.item.ratingKey == ratingKey else { return }
            rebuildSubtitleOptions()
            await applyInitialSubtitle()
        }
    }

    /// Direct play when iOS can, otherwise the server's conversion.
    private func startStreaming(_ item: PlexMetadata, api: PlexServerAPI) {
        if PlaybackDecider.shouldDirectPlay(item, quality: quality), let url = PlaybackDecider.directURL(api: api, item: item) {
            modeDescription = "Direct Play"
            load(url: url, start: request.startMs)
        } else {
            // Sidecar text is drawn by the app; anything else selected is burned in.
            let burn = item.primaryPart?.selectedSubtitle.flatMap { $0.isSidecarText ? nil : $0.id }
            startTranscode(api: api, start: request.startMs, burn: burn)
        }
    }

    private var preferenceScope: String { MediaPreferences.scope(user: userID, server: request.serverID) }

    var diagnosticsInput: DiagnosticsBuilder.Input {
        DiagnosticsBuilder.Input(item: metadata, serverID: request.serverID, mode: modeDescription,
                                 isDownloaded: request.localURL != nil, isConverting: isTranscoding,
                                 transcodeSessionID: isTranscoding ? sessionID : nil,
                                 qualitySetting: quality.label, playerItem: player.currentItem, error: errorMessage,
                                 player: "Apple's player")
    }

    // MARK: Chapters & speed

    @Published private(set) var chapters: [PlexChapter] = []
    @Published var speed: Float = 1 {
        didSet {
            player.defaultRate = speed
            if player.rate != 0 { player.rate = speed }
        }
    }
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    func jump(to chapter: PlexChapter) {
        player.seek(to: CMTime(value: CMTimeValue(chapter.startTimeOffset), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        noteInteraction()
    }

    var currentChapter: PlexChapter? {
        let pos = positionMs
        return chapters.last { $0.startTimeOffset <= pos }
    }

    private func startTranscode(api: PlexServerAPI, start: Int, burn: Int?) {
        isTranscoding = true
        burnSubtitleID = burn
        modeDescription = quality == .original ? "Transcoding (Original quality)" : "Transcoding · \(quality.label)"
        let url = PlaybackDecider.transcodeURL(api: api, item: metadata, quality: quality, sessionID: sessionID,
                                               isLocal: isLocalConnection, burnSubtitleID: burn, allowHEVC: !avoidHEVC)
        load(url: url, start: start)
    }

    /// Restart the server stream at the current position (e.g. to burn in a different subtitle).
    private func restartTranscode(burn: Int?) {
        guard let api else { return }
        let position = positionMs
        stopCurrentTranscode()
        sessionID = UUID().uuidString
        startTranscode(api: api, start: position, burn: burn)
    }

    private func stopCurrentTranscode() {
        guard isTranscoding, let api else { return }
        let sid = sessionID
        Task.detached { await api.stopTranscode(sessionID: sid) }
    }

    private func load(url: URL, start: Int) {
        itemCancellables.removeAll()
        streamOpened = false
        guard url.isFileURL || MediaPreferences.shared.streamAllowed(.watch) else { errorMessage = "Watch streaming over cellular is disabled in Playback Preferences."; return }
        let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: MediaPreferences.shared.allowsCellular(.watch)])
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = makeMetadata()
        item.preferredForwardBufferDuration = 30
        player.replaceCurrentItem(with: item)
        player.allowsExternalPlayback = true

        item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                Task { @MainActor in
                    guard !self.stopped, self.player.currentItem === item else { return }
                    switch status {
                    case .readyToPlay:
                        self.streamOpened = true
                        if start > 0, item.currentTime().seconds < 1 {
                            await self.player.seek(to: CMTime(value: CMTimeValue(start), timescale: 1000),
                                                   toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
                        }
                        guard !self.stopped, self.player.currentItem === item else { return }
                        if PlaybackFocus.owns(self.player) { self.player.playImmediately(atRate: self.speed) }
                        await self.loadNativeLegible(item)
                    case .failed:
                        self.handleFailure(item.error)
                    default: break
                    }
                }
            }
            .store(in: &itemCancellables)
    }

    private func handleFailure(_ error: Error?) {
        // A conversion that stopped (the server ends one left paused or while the app was away):
        // start a new one at the same point, quietly, once.
        if isTranscoding, !restartedConversion, let api {
            restartedConversion = true
            if !streamOpened { avoidHEVC = true }
            let resume = Int((player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) * 1000)
            startTranscode(api: api, start: max(resume, 0), burn: burnSubtitleID)
            return
        }
        // Direct play failed (unexpected codec/profile): retry via the transcoder.
        if !isTranscoding, request.localURL == nil, !triedTranscodeFallback, let api {
            triedTranscodeFallback = true
            let resume = Int((player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0) * 1000)
            startTranscode(api: api, start: max(resume, request.startMs), burn: nil)
            return
        }
        if request.localURL != nil {
            errorMessage = "This download is in a format iPhone can't play. Replace it with a converted copy from your server?"
        } else {
            errorMessage = error?.localizedDescription ?? "Playback failed."
        }
    }

    private func makeMetadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        let title = request.item.kind == .episode ? request.item.title : request.item.displayTitle
        let subtitle = request.item.kind == .episode ? [request.item.grandparentTitle, request.item.subtitleLine].compactMap { $0 }.joined(separator: " · ") : request.item.year.map(String.init)
        return [item(.commonIdentifierTitle, title), item(.iTunesMetadataTrackSubTitle, subtitle),
                item(.commonIdentifierDescription, request.item.summary)].compactMap { $0 }
    }

    private var positionMs: Int {
        let s = player.currentTime().seconds
        return s.isFinite ? Int(s * 1000) : 0
    }

    private var durationMs: Int? {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { return Int(d * 1000) }
        return request.item.duration
    }

    private func periodic() {
        if Date().timeIntervalSince(lastReported) >= 10 { report(force: true) }
        updateSkipPrompt()
    }

    // MARK: Skip intro / credits

    private func updateSkipPrompt() {
        guard !transition.isActive else { skipPrompt = nil; return }
        let pos = positionMs
        let markers = metadata.markers
        if let intro = markers.first(where: { $0.isIntro && pos >= $0.startTimeOffset && pos < $0.endTimeOffset - 1000 }),
           dismissedMarkerStart != intro.startTimeOffset {
            skipPrompt = .intro(endMs: intro.endTimeOffset)
            return
        }
        let credits = markers.filter(\.isCredits)
        if let current = credits.first(where: { pos >= $0.startTimeOffset && pos < $0.endTimeOffset }),
           dismissedMarkerStart != current.startTimeOffset {
            let isFinal = current.final == true || current == credits.max(by: { $0.startTimeOffset < $1.startTimeOffset })
            if isFinal, !upNext.isEmpty, !PlaybackSleepTimer.shared.endsWithItem(for: player) {
                // Countdown to the next episode, ticking only while playing.
                if countdownMarkerStart != current.startTimeOffset {
                    countdownMarkerStart = current.startTimeOffset
                    countdownPlayedMs = 0
                } else if player.timeControlStatus == .playing, let last = countdownLastPos, (1...2500).contains(pos - last) {
                    countdownPlayedMs += pos - last
                }
                countdownLastPos = pos
                countdown = 10 - countdownPlayedMs / 1000
                if countdown <= 0 {
                    skipPrompt = nil
                    let id = request.id
                    Task { await advance(from: id) }
                } else {
                    skipPrompt = .nextEpisode(seconds: countdown)
                }
            } else {
                skipPrompt = .credits(endMs: current.endTimeOffset)
            }
            return
        }
        skipPrompt = nil
    }

    func performSkip() async {
        switch skipPrompt {
        case .intro(let end), .credits(let end):
            skipPrompt = nil
            await player.seek(to: CMTime(value: CMTimeValue(end), timescale: 1000))
        case .nextEpisode:
            skipPrompt = nil
            await advance(from: request.id)
        case nil:
            break
        }
    }

    func dismissSkipPrompt() {
        let pos = positionMs
        dismissedMarkerStart = metadata.markers.first { pos >= $0.startTimeOffset && pos < $0.endTimeOffset }?.startTimeOffset
        skipPrompt = nil
    }

    /// Called on taps so our buttons appear alongside the system controls.
    func noteInteraction() {
        chromeVisible = true
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chromeVisible = false }
        }
    }

    // MARK: Subtitles

    private func loadNativeLegible(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        // Only real text tracks; skip auto-generated/forced-only system options.
        nativeLegible = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        rebuildSubtitleOptions()
    }

    private func rebuildSubtitleOptions() {
        var options = [SubtitleOption.off]
        if request.localURL != nil, let rec = request.downloadID.flatMap({ id in DownloadManager.shared.records.first { $0.id == id } }) {
            for f in rec.subtitleFiles {
                options.append(SubtitleOption(id: "file-\(f.streamID)", label: f.label, detail: "Downloaded",
                                              source: .localFile(DownloadStore.directory(for: rec.id).appendingPathComponent(f.fileName))))
            }
        } else {
            for s in metadata.primaryPart?.subtitleStreams ?? [] {
                if s.isSidecarText {
                    options.append(SubtitleOption(id: "sidecar-\(s.id)", label: s.label, detail: nil, source: .sidecar(streamID: s.id)))
                } else if isTranscoding || !PlaybackDecider.nativeTextSubtitleCodecs.contains((s.codec ?? "").lowercased()) {
                    options.append(SubtitleOption(id: "burn-\(s.id)", label: s.label,
                                                  detail: "Added to the video by your server", source: .burn(streamID: s.id)))
                }
            }
        }
        for (i, o) in nativeLegible.enumerated() where !isTranscoding {
            options.append(SubtitleOption(id: "native-\(i)", label: o.displayName, detail: "Embedded", source: .native(index: i)))
        }
        subtitleOptions = options.count > 1 ? options : []
        if burnSubtitleID != nil, let id = burnSubtitleID { selectedSubtitleID = "burn-\(id)" }
    }

    /// Match the subtitle the server (or download) says is selected.
    private func applyInitialSubtitle() async {
        if request.localURL != nil {
            let rec = request.downloadID.flatMap { id in DownloadManager.shared.records.first { $0.id == id } }
            if let f = rec?.subtitleFiles.first(where: \.selected),
               let option = subtitleOptions.first(where: { $0.id == "file-\(f.streamID)" }) {
                await selectSubtitle(option, persist: false)
            }
            return
        }
        guard let sel = metadata.primaryPart?.selectedSubtitle else { return }
        if let option = subtitleOptions.first(where: { $0.id == "sidecar-\(sel.id)" }) {
            await selectSubtitle(option, persist: false)
        }
    }

    func selectSubtitle(_ option: SubtitleOption, persist: Bool = true) async {
        isSwitchingSubtitles = true
        defer { isSwitchingSubtitles = false }
        let part = metadata.primaryPart
        switch option.source {
        case .off:
            clearCues()
            selectNative(nil)
            if burnSubtitleID != nil { restartTranscode(burn: nil) }
            if persist, let part { try? await api?.selectStreams(partID: part.id, audioStreamID: nil, subtitleStreamID: 0) }
        case .localFile(let url):
            guard let data = try? Data(contentsOf: url) else { return }
            setCues(SubtitleParser.parse(data))
            selectNative(nil)
        case .sidecar(let id):
            guard let api, let data = try? await api.subtitleFile(streamID: id) else {
                errorMessageForSubtitles("Couldn't load that subtitle from your server.")
                return
            }
            setCues(SubtitleParser.parse(data))
            selectNative(nil)
            if burnSubtitleID != nil { restartTranscode(burn: nil) }
            if persist, let part { try? await api.selectStreams(partID: part.id, audioStreamID: nil, subtitleStreamID: id) }
        case .native(let i):
            clearCues()
            selectNative(nativeLegible.indices.contains(i) ? nativeLegible[i] : nil)
        case .burn(let id):
            clearCues()
            selectNative(nil)
            if persist, let part { try? await api?.selectStreams(partID: part.id, audioStreamID: nil, subtitleStreamID: id) }
            if !isTranscoding || burnSubtitleID != id { restartTranscode(burn: id) }
        }
        selectedSubtitleID = option.id
        if persist { rememberSubtitleChoice(option) }
    }

    private func rememberSubtitleChoice(_ option: SubtitleOption) {
        let prefs = MediaPreferences.shared
        let streams = metadata.primaryPart?.subtitleStreams ?? []
        switch option.source {
        case .off: prefs.rememberSubtitle(languageCode: nil, scope: preferenceScope)
        case .sidecar(let id), .burn(let id):
            if let s = streams.first(where: { $0.id == id }) { prefs.rememberSubtitle(languageCode: s.languageCode, scope: preferenceScope) }
        case .native(let i):
            // Embedded tracks report BCP 47 tags ("en"); Plex uses ISO 639-2 ("eng").
            if nativeLegible.indices.contains(i), let tag = nativeLegible[i].extendedLanguageTag,
               let code = Locale.Language(identifier: tag).languageCode?.identifier(.alpha3) {
                prefs.rememberSubtitle(languageCode: code, scope: preferenceScope)
            }
        case .localFile: break
        }
    }

    private func errorMessageForSubtitles(_ message: String) {
        subtitleText = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if cues.isEmpty { subtitleText = nil }
        }
    }

    private func selectNative(_ option: AVMediaSelectionOption?) {
        guard let item = player.currentItem else { return }
        Task {
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
                item.select(option, in: group)
            }
        }
    }

    private func setCues(_ new: [SubtitleCue]) {
        cues = new
        subtitleText = nil
        if subtitleObserver == nil, !new.isEmpty {
            subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
                Task { @MainActor in self?.updateSubtitle(t.seconds) }
            }
        }
    }

    private func clearCues() {
        cues = []
        subtitleText = nil
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        subtitleObserver = nil
    }

    private func updateSubtitle(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let text = SubtitleParser.cue(at: seconds - subtitleOffset, in: cues)?.text
        if text != subtitleText { subtitleText = text }
    }

    func searchSubtitles(language: String) async throws -> [PlexStream] {
        guard let api else { return [] }
        return try await api.searchSubtitles(ratingKey: metadata.ratingKey, language: language)
    }

    /// Download a search result to the server, then switch to it.
    func addSubtitle(_ result: PlexStream) async throws {
        guard let api else { return }
        let before = Set((metadata.primaryPart?.subtitleStreams ?? []).map(\.id))
        try await api.addSubtitle(ratingKey: metadata.ratingKey, result: result)
        // The server fetches it in the background; wait for it to appear.
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1.5))
            guard let fresh = try? await api.metadata(metadata.ratingKey) else { continue }
            if let added = fresh.primaryPart?.subtitleStreams.first(where: { !before.contains($0.id) }) {
                metadata = fresh
                rebuildSubtitleOptions()
                if let option = subtitleOptions.first(where: { $0.id == "sidecar-\(added.id)" || $0.id == "burn-\(added.id)" }) {
                    await selectSubtitle(option)
                }
                return
            }
        }
        throw PlexError.unsupported("The server didn't finish downloading the subtitle. Try again in a moment.")
    }

    // MARK: Reporting

    @discardableResult
    private func report(force: Bool, state explicit: String? = nil) -> Task<Void, Never>? {
        guard !stopped, player.currentItem != nil else { return nil }
        let state = explicit ?? (player.timeControlStatus == .playing ? "playing" : (player.timeControlStatus == .paused ? "paused" : "buffering"))
        guard force || state != lastState else { return nil }
        lastState = state
        lastReported = Date()
        let pos = positionMs, dur = durationMs
        if let id = request.downloadID {
            DownloadManager.shared.recordOfflineProgress(id, positionMs: pos, durationMs: dur, userID: userID)
        }
        guard let api else { return nil }
        let item = request.item
        let sid = sessionID
        return Task.detached {
            try? await api.timeline(ratingKey: item.ratingKey, key: item.key, state: state, timeMs: pos, durationMs: dur, sessionID: sid)
        }
    }

    /// Stops playback and waits (briefly) for the server to record the final
    /// position, so On Deck / progress bars are current when screens reload.
    func stop() async {
        guard !stopped else { return }
        if PlaybackSleepTimer.shared.isSet(for: player) { PlaybackSleepTimer.shared.cancel() }
        let final = report(force: true, state: "stopped")
        stopped = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        clearCues()
        chromeHideTask?.cancel()
        cancellables.removeAll()
        itemCancellables.removeAll()
        stopCurrentTranscode()
        player.replaceCurrentItem(with: nil)
        if let final { await PlaybackReportDeadline.wait(for: final) }
    }
}

/// Player screen: AVKit's player embedded as a child, with subtitle text drawn
/// in its content overlay and our buttons (Subtitles, Skip Intro/Credits) in a
/// sibling view on top. Buttons placed inside AVPlayerViewController's own view
/// don't reliably receive taps; AVKit's gesture handling takes them.
final class PlexPlayerViewController: UIViewController, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    var playback: VideoPlaybackController?
    var onClose: (() -> Void)?
    private let playerVC = AVPlayerViewController()
    private var errorObserver: AnyCancellable?
    private var boundsObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let playback else { return }
        playerVC.player = playback.player
        playerVC.delegate = self
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.updatesNowPlayingInfoCenter = true
        addChild(playerVC)
        playerVC.view.frame = view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        errorObserver = playback.$errorMessage.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] message in
            self?.showError(message)
        }

        // Subtitle text: in the content overlay (above video, below the system controls).
        let subs = UIHostingController(rootView: SubtitleOverlayView(playback: playback))
        subs.view.backgroundColor = .clear
        subs.view.isUserInteractionEnabled = false
        if let overlay = playerVC.contentOverlayView {
            // Owned by the player controller, since its view lives inside the player's views.
            playerVC.addChild(subs)
            subs.view.frame = overlay.bounds
            subs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(subs.view)
            subs.didMove(toParent: playerVC)
        }

        // Buttons: a fixed area above the timeline. (A hosting view sized to its
        // content kept its first, empty size, so buttons drew outside it untappable.)
        let buttons = UIHostingController(rootView: PlayerOverlayButtons(playback: playback, showSubtitles: { [weak self] in
            self?.presentSubtitles()
        }, showQueue: { [weak self] in
            guard let self, let playback = self.playback else { return }
            self.present(UIHostingController(rootView: VideoQueueView(playback: playback)), animated: true)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing))
        buttons.view.backgroundColor = .clear
        addChild(buttons)
        buttons.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons.view)
        NSLayoutConstraint.activate([
            buttons.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            buttons.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
            buttons.view.widthAnchor.constraint(equalToConstant: 320),
            buttons.view.heightAnchor.constraint(equalToConstant: 220),
        ])
        buttons.didMove(toParent: self)

        boundsObservation = playerVC.observe(\.videoBounds, options: [.initial, .new]) { [weak playback] vc, _ in
            let rect = vc.videoBounds
            Task { @MainActor in playback?.videoRect = rect }
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(userTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        playerVC.view.addGestureRecognizer(tap)
    }

    @objc private func userTapped() { playback?.noteInteraction() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func presentSubtitles() {
        guard let playback, presentedViewController == nil else { return }
        let sheet = UIHostingController(rootView: SubtitleSheet(playback: playback).preferredColorScheme(.dark).tint(Cinema.accent))
        sheet.overrideUserInterfaceStyle = .dark
        sheet.view.backgroundColor = UIColor(Cinema.background)   // opaque: the default glass made white text unreadable
        if let s = sheet.sheetPresentationController {
            s.detents = [.medium(), .large()]
            s.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onClose?()
            onClose = nil
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Can't Play", message: message, preferredStyle: .alert)
        if let downloadID = playback?.request.downloadID {
            alert.addAction(UIAlertAction(title: "Download Playable Version", style: .default) { [weak self] _ in
                DownloadManager.shared.redownloadPlayable(downloadID)
                self?.dismiss(animated: true)
            })
        }
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }

    // Keep the player presented while in Picture in Picture so closing PiP restores it.
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

@MainActor
enum VideoPresenter {
    /// Apple's player when it can play the file; the built-in player otherwise.
    @discardableResult
    static func present(_ request: VideoPlayRequest, upNext: [VideoPlayRequest] = [], app: AppState) -> (any VideoQueueing)? {
        guard let top = topViewController() else { return nil }
        if BuiltInPlayer.handles(request, quality: app.streamingQuality) {
            return presentBuiltIn(request, upNext: upNext, app: app, from: top)
        }
        let playback = VideoPlaybackController(request: request, upNext: upNext)
        let vc = PlexPlayerViewController()
        vc.playback = playback
        vc.modalPresentationStyle = .fullScreen
        vc.onClose = { [weak app] in
            Task { @MainActor in
                await playback.stop()
                if app?.activeVideoPlayback === playback { app?.activeVideoPlayback = nil }
                app?.playbackEnded()
            }
        }
        playback.handOff = { [weak vc, weak app] next, rest in
            guard let vc, let app else { return }
            vc.dismiss(animated: true) {
                Task { @MainActor in
                    await playback.stop()
                    guard let top = topViewController() else { return }
                    app.activeVideoPlayback = presentBuiltIn(next, upNext: rest, app: app, from: top)
                }
            }
        }
        let quality = app.streamingQuality
        let isLocal = app.isLocalConnection
        top.present(vc, animated: true) {
            playback.start(quality: quality, isLocalConnection: isLocal)
        }
        return playback
    }

    private static func presentBuiltIn(_ request: VideoPlayRequest, upNext: [VideoPlayRequest], app: AppState,
                                       from top: UIViewController) -> BuiltInPlaybackController {
        let playback = BuiltInPlaybackController(request: request, upNext: upNext)
        let vc = BuiltInPlayerViewController(playback: playback)
        vc.modalPresentationStyle = .fullScreen
        vc.onClose = { [weak app] in
            Task { @MainActor in
                await playback.stop()
                if app?.activeVideoPlayback === playback { app?.activeVideoPlayback = nil }
                app?.playbackEnded()
            }
        }
        top.present(vc, animated: true)
        return playback
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// One queue transition may own an item, even while its final report is awaiting I/O.
struct PlaybackTransitionGate {
    private var owner: UUID?
    var isActive: Bool { owner != nil }
    mutating func begin(_ id: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = id
        return true
    }
    mutating func end(_ id: UUID) { if owner == id { owner = nil } }
}

/// Unstructured observers deliberately let the caller return at the deadline,
/// even if a reporting operation does not cooperate with cancellation.
@MainActor
final class PlaybackReportDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    private var completion: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func wait(for report: Task<Void, Never>, timeout: Duration = .seconds(4)) async {
        let waiter = PlaybackReportDeadline()
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            waiter.completion = Task { await report.value; waiter.finish() }
            waiter.timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                report.cancel()
                waiter.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        completion?.cancel()
        timer?.cancel()
        completion = nil
        timer = nil
        continuation.resume()
    }
}
