import MediaPlayer
import SwiftUI
import TVVLCKit

/// Playback position, kept apart from the controller so only the progress bar redraws as it
/// changes (a redraw of the controls closes any menu or dialog that's open).
final class TVPlaybackClock: ObservableObject {
    @Published var timeMs = 0
    @Published var durationMs = 0
}

/// Plays files tvOS can't (MKV, DTS, TrueHD, image subtitles) straight from the server with VLC,
/// so nothing has to be converted. Reports progress, follows a queue and offers Skip Intro.
@MainActor
final class TVVLCPlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    struct Track: Identifiable, Hashable { let id: Int32; let name: String }

    let mediaPlayer = VLCMediaPlayer()
    let clock = TVPlaybackClock()
    private(set) var timeMs = 0 { didSet { if timeMs / 1000 != clock.timeMs / 1000 { clock.timeMs = timeMs } } }
    private(set) var durationMs = 0 { didSet { if durationMs != clock.durationMs { clock.durationMs = durationMs } } }
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var skipLabel: String?
    @Published private(set) var current: PlexMetadata?
    @Published private(set) var errorMessage: String?
    @Published var speed: Float = 1 { didSet { mediaPlayer.rate = speed } }
    /// Sound later (positive) or earlier (negative) than the picture, to fix lip sync.
    @Published var audioDelayMs = 0 { didSet { mediaPlayer.currentAudioPlaybackDelay = audioDelayMs * 1000 } }
    /// Picture size relative to fitting the screen (0.5–2).
    @Published var zoom: CGFloat = 1 { didSet { drawable?.transform = zoom == 1 ? .identity : CGAffineTransform(scaleX: zoom, y: zoom) } }
    /// Seconds left on the Up Next countdown while it's showing.
    @Published private(set) var upNextLeft: Int?
    private(set) var upNext: PlexMetadata?
    private var upNextHidden = false
    private var upNextCountdown = TVUpNextCountdown()
    private weak var drawable: UIView?
    private var sleepObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    /// Finished loading after the app was left: starts on the way back.
    private var startOnReturn = false

    private var queue: [PlexMetadata]
    private var index: Int
    private let resumeFirst: Bool
    private let session: TVSession
    private let playbackAPI: PlexServerAPI?
    var onFinish: () -> Void = {}
    private var markers: [PlexMarker] = []
    private var skipTarget: Int?
    private var sessionID = UUID().uuidString
    private var lastReport = Date.distantPast
    /// What the server was last told, and what VLC last said: it repeats a state many times a second.
    private var lastState = ""
    private var lastPlayerState: VLCMediaPlayerState?
    /// The newest load; an older one finishing late is ignored.
    private var loadID = UUID()
    /// Profile and server the language choices are remembered for.
    private var languageScope = ""
    private var tracksApplied = false
    private var stopped = false
    private var ending = false

    init(request: TVPlayRequest, session: TVSession) {
        queue = request.queue
        index = request.start
        resumeFirst = request.resume
        self.session = session
        playbackAPI = session.api
        super.init()
        mediaPlayer.delegate = self
    }

    func start(drawable: UIView) {
        TVMusicPlayer.shared.yieldToVideo()
        TVLiveNow.shared.stop()
        mediaPlayer.drawable = drawable
        self.drawable = drawable
        sleepObserver = NotificationCenter.default.addObserver(forName: .tvSleepTimerFired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaPlayer.pause() }
        }
        // The stream can drop while the app is at the Home Screen: pick it up again where it stopped.
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if self.startOnReturn { self.startOnReturn = false; self.mediaPlayer.play(); return }
                if self.errorMessage != nil || self.mediaPlayer.state == .error || self.mediaPlayer.state == .stopped { self.retry() }
            }
        }
        // The app may play audio in the background for music; a video stops when it's left.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.mediaPlayer.isPlaying || self.isBuffering else { return }
                self.mediaPlayer.pause()
                self.report(force: true)
            }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        TVAudioOutput.applyChannelLimit()
        Task { await load(index, resume: resumeFirst) }
    }

    /// `startMs` starts at a given point instead (a retry where it stopped).
    private func load(_ i: Int, resume: Bool, startMs: Int? = nil) async {
        guard !stopped, let api = playbackAPI, queue.indices.contains(i) else { return onFinish() }
        index = i
        let id = UUID()
        loadID = id
        var loaded = ((try? await api.metadata(queue[i].ratingKey)) ?? queue[i]).usingPlaybackVersion(of: queue[i])
        guard !stopped, id == loadID else { return }
        // The remembered languages, set on the server first so the file opens on them.
        let scope = TVLanguagePreference.scope(session: session)
        languageScope = scope
        if let partID = loaded.primaryPart?.id,
           let change = LanguagePreference.change(for: loaded.primaryPart, audio: TVLanguagePreference.audio(scope: scope),
                                                  subtitle: TVLanguagePreference.subtitle(scope: scope)) {
            try? await api.selectStreams(partID: partID, audioStreamID: change.audioStreamID, subtitleStreamID: change.subtitleStreamID)
            let key = loaded.ratingKey
            let fresh = (try? await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(key) }) ?? nil
            if let fresh { loaded = fresh.usingPlaybackVersion(of: queue[i]) }
            guard !stopped, id == loadID else { return }
        }
        let item = loaded
        current = item
        markers = item.markers
        durationMs = item.duration ?? 0
        timeMs = startMs ?? (resume ? (item.viewOffset ?? 0) : 0)
        sessionID = UUID().uuidString
        audioTracks = []; subtitleTracks = []; tracksApplied = false
        skipLabel = nil; errorMessage = nil; isBuffering = true; ending = false; lastReport = .distantPast
        lastState = ""; lastPlayerState = nil
        upNext = nil; upNextHidden = false; upNextLeft = nil; upNextCountdown.reset()
        // The TV switches to this file's frame rate and HDR format (with Match Content on).
        TVDisplayMatch.apply(for: item, in: drawable)
        Task { [queue, index] in
            let next = await TVUpNext.next(after: item, queue: queue, index: index, api: api)
            if !stopped, loadID == id { upNext = next }
        }

        guard let url = PlaybackDecider.directURL(api: api, item: item) else {
            errorMessage = "This item has no playable file."
            return
        }
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        if VolumeLeveling.isOn { VolumeLeveling.vlcOptions.forEach { media.addOption($0) } }
        if let codec = item.primaryMedia?.videoCodec?.lowercased(), ["mpeg2video", "mpeg1video", "vc1", "mpeg2"].contains(codec) {
            media.addOption(":deinterlace=1")
            media.addOption(":deinterlace-mode=yadif")
        }
        if timeMs > 0 { media.addOption(":start-time=\(Double(timeMs) / 1000)") }
        // Open on the chosen audio track rather than switching once playing: switching right
        // after a resume restarts the audio decoder mid-seek, which can leave it out of sync.
        if let n = VLCTrackChoice.audioIndex(in: item) { media.addOption(":audio-track=\(n)") }
        if TVAudioOutput.passthrough { media.addOption(":spdif") }
        mediaPlayer.media = media
        if UIApplication.shared.applicationState == .background { startOnReturn = true } else { mediaPlayer.play() }
        mediaPlayer.rate = speed
        mediaPlayer.currentAudioPlaybackDelay = audioDelayMs * 1000
        mediaPlayer.audio?.passthrough = TVAudioOutput.passthrough
        if TVAudioOutput.stereoOnly { mediaPlayer.audioChannel = 1 }   // VLCAudioChannelStereo
        for s in item.primaryPart?.subtitleStreams ?? [] {
            if let key = s.key { mediaPlayer.addPlaybackSlave(api.url(key, query: PlexClient.queryItems(token: api.token)), type: .subtitle, enforce: false) }
        }
        updateNowPlaying()
    }

    // MARK: Controls

    func togglePlay() { mediaPlayer.isPlaying ? mediaPlayer.pause() : mediaPlayer.play() }
    func skip(seconds: Int) {
        if seconds >= 0 { mediaPlayer.jumpForward(Int32(seconds)) } else { mediaPlayer.jumpBackward(Int32(-seconds)) }
    }
    func seek(toMs ms: Int) { mediaPlayer.time = VLCTime(int: Int32(max(0, ms))) }
    func selectAudio(_ id: Int32) { mediaPlayer.currentAudioTrackIndex = id; currentAudio = id }
    func selectSubtitle(_ id: Int32) { mediaPlayer.currentVideoSubTitleIndex = id; currentSubtitle = id }

    /// The viewer picked this in the menu: it's also remembered for what plays next.
    func chooseAudio(_ id: Int32) {
        selectAudio(id)
        guard let part = current?.primaryPart, let n = audioTracks.firstIndex(where: { $0.id == id }),
              let code = VLCTrackChoice.audioLanguage(atPosition: n, in: part) else { return }
        TVLanguagePreference.rememberAudio(code, scope: languageScope)
    }

    func chooseSubtitle(_ id: Int32) {
        selectSubtitle(id)
        if id < 0 { return TVLanguagePreference.rememberSubtitle(nil, scope: languageScope) }
        guard let part = current?.primaryPart, let n = subtitleTracks.filter({ $0.id >= 0 }).firstIndex(where: { $0.id == id }),
              let code = VLCTrackChoice.subtitleLanguage(atPosition: n, in: part) else { return }
        TVLanguagePreference.rememberSubtitle(code, scope: languageScope)
    }

    func performSkip() { if let skipTarget { seek(toMs: skipTarget) } }
    /// After an error: reload this item where it stopped.
    func retry() {
        guard !stopped, queue.indices.contains(index) else { return }
        let resumeAt = timeMs
        // Started at the point by the opening itself; a seek while VLC is still opening the
        // file can leave the sound out of step with the picture.
        Task { await load(index, resume: false, startMs: resumeAt > 0 ? resumeAt : nil) }
    }
    func hideUpNext() { upNextHidden = true; upNextLeft = nil }

    /// Marks this episode watched and starts the next one.
    func playNext() {
        guard let next = upNext, !stopped else { return }
        upNext = nil; upNextLeft = nil
        ending = true
        let finished = current, id = sessionID, api = playbackAPI
        let position = timeMs
        Task { await TVPlaybackReporting.reportFinished(finished, sessionID: id, api: api, fallbackMs: position) }
        if !(queue.indices.contains(index + 1) && queue[index + 1].ratingKey == next.ratingKey) {
            queue.insert(next, at: index + 1)
        }
        Task { await load(index + 1, resume: false) }
    }
    /// VLC may pick its own tracks after loading; read them before showing a choice.
    func syncCurrentTracks() {
        currentAudio = mediaPlayer.currentAudioTrackIndex
        currentSubtitle = mediaPlayer.currentVideoSubTitleIndex
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // Already reported as finished, if it played to its end.
        let item = ending ? nil : current, time = timeMs, id = sessionID, api = playbackAPI
        mediaPlayer.stop()
        TVKeepAwake.hold(false, by: self)
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        TVDisplayMatch.reset(in: drawable)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        Task { [session] in
            await TVPlaybackReporting.report(item, state: "stopped", timeMs: time, sessionID: id, api: api)
            session.contentVersion += 1
        }
    }

    // MARK: VLC events (delivered on the main thread)

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { timeChanged() }
    }

    private func stateChanged() {
        let state = mediaPlayer.state
        guard state != lastPlayerState else { return }
        lastPlayerState = state
        switch state {
        case .buffering, .opening: setBuffering(true)
        case .playing: setBuffering(false); if !isPlaying { isPlaying = true }
        case .paused: if isPlaying { isPlaying = false }; setBuffering(false)
        case .ended, .stopped:
            isPlaying = false
            if !stopped, state == .ended || (durationMs > 0 && timeMs > durationMs - 3000) { itemEnded() }
        case .error:
            isBuffering = false
            errorMessage = "This file couldn't be played."
        default: break
        }
        // VLC draws its own picture, so tvOS doesn't know a video is playing: keep the TV awake.
        TVKeepAwake.hold(!stopped && (state == .playing || state == .buffering || state == .opening), by: self)
        if !stopped { report(force: false) }
        updateNowPlaying()
    }

    private func timeChanged() {
        timeMs = Int(mediaPlayer.time.intValue)
        if let length = mediaPlayer.media?.length.intValue, length > 0, Int(length) != durationMs { durationMs = Int(length) }
        setBuffering(false)
        if !tracksApplied { refreshTracks() }
        updateSkip()
        updateUpNext()
        report(force: false)
    }

    /// Counts down to the next episode from the credits (pausing pauses the countdown).
    private func updateUpNext() {
        guard let current, upNext != nil, !upNextHidden, !TVSleepTimer.shared.atEndOfItem,
              let trigger = TVUpNext.trigger(for: current, durationMs: durationMs), timeMs >= trigger else {
            if upNextLeft != nil { upNextLeft = nil }
            upNextCountdown.reset()
            return
        }
        let left = upNextCountdown.secondsLeft(atMs: timeMs)
        if left == 0 { return playNext() }
        if upNextLeft != left { upNextLeft = left }
    }

    /// Only publishes real changes; VLC reports the same state many times a second.
    private func setBuffering(_ value: Bool) { if isBuffering != value { isBuffering = value } }

    private func refreshTracks() {
        func tracks(_ names: [Any]?, _ ids: [Any]?) -> [Track] {
            zip(names ?? [], ids ?? []).compactMap { n, i in
                guard let name = n as? String, let id = (i as? NSNumber)?.int32Value else { return nil }
                return Track(id: id, name: name)
            }
        }
        // VLC lists "Disable" (index -1) first: never offered for audio, shown as "Off" for subtitles.
        audioTracks = tracks(mediaPlayer.audioTrackNames, mediaPlayer.audioTrackIndexes).filter { $0.id >= 0 }
        subtitleTracks = tracks(mediaPlayer.videoSubTitlesNames, mediaPlayer.videoSubTitlesIndexes)
            .map { $0.id < 0 ? Track(id: $0.id, name: "Off") : $0 }
        currentAudio = mediaPlayer.currentAudioTrackIndex
        currentSubtitle = mediaPlayer.currentVideoSubTitleIndex
        guard !audioTracks.isEmpty, let part = current?.primaryPart else { return }
        tracksApplied = true
        // Start with the audio and subtitles chosen in Plex (or on the detail page).
        let audio = part.audioStreams
        // Usually already open on it (see load); only switch when VLC picked another.
        if let chosen = part.selectedAudio, let n = audio.firstIndex(where: { $0.id == chosen.id }), audioTracks.indices.contains(n),
           audioTracks[n].id != mediaPlayer.currentAudioTrackIndex {
            selectAudio(audioTracks[n].id)
        }
        // Embedded subtitles come first in VLC's list; external files are added after them.
        let realSubs = subtitleTracks.filter { $0.id >= 0 }
        let embedded = part.subtitleStreams.filter { $0.key == nil }
        if let chosen = part.selectedSubtitle {
            if let n = embedded.firstIndex(where: { $0.id == chosen.id }), realSubs.indices.contains(n) {
                selectSubtitle(realSubs[n].id)
            } else if chosen.key != nil, let last = realSubs.last {
                selectSubtitle(last.id)
            }
        } else {
            selectSubtitle(-1)
        }
    }

    private func updateSkip() {
        let m = markers.first { ["intro", "credits"].contains($0.type) && timeMs >= $0.startTimeOffset && timeMs < $0.endTimeOffset - 1000 }
        let label = m.map { $0.type == "intro" ? "Skip Intro" : "Skip Credits" }
        if label != skipLabel { skipLabel = label }
        skipTarget = m?.endTimeOffset
    }

    private func report(force: Bool) {
        let state = mediaPlayer.isPlaying ? "playing" : "paused"
        guard let current, force || state != lastState || Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastState = state
        lastReport = Date()
        let time = timeMs, id = sessionID, api = playbackAPI
        Task { await TVPlaybackReporting.report(current, state: state, timeMs: time, sessionID: id, api: api) }
    }

    private func itemEnded() {
        guard !ending else { return }
        if TVSleepTimer.shared.shouldStopAtItemEnd() {
            ending = true
            let finished = current, id = sessionID, api = playbackAPI, position = timeMs
            Task { [session] in
                await TVPlaybackReporting.reportFinished(finished, sessionID: id, api: api, fallbackMs: position)
                session.contentVersion += 1
            }
            return onFinish()
        }
        if upNext != nil, !upNextHidden { return playNext() }
        ending = true
        let finished = current, id = sessionID, api = playbackAPI, position = timeMs
        Task { await TVPlaybackReporting.reportFinished(finished, sessionID: id, api: api, fallbackMs: position) }
        if index + 1 < queue.count, !upNextHidden {
            Task { await load(index + 1, resume: false) }
        } else {
            session.contentVersion += 1
            onFinish()
        }
    }

    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.grandparentTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(timeMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}

// MARK: - View

/// Full-screen VLC playback with remote controls:
/// click left/right to skip 10 seconds, play/pause to pause, up/down or select for the controls.
struct TVVLCPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: TVVLCPlaybackController
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var choosing: TrackKind?
    @FocusState private var focus: Focus?
    @FocusState private var upNextFocused: Bool

    enum TrackKind: Identifiable { case audio, subtitles, sleep, options, speed, sync, zoom; var id: Self { self } }

    enum Focus: Hashable { case surface, back, play, forward, audio, subtitles, skip }

    init(request: TVPlayRequest, session: TVSession) {
        _playback = StateObject(wrappedValue: TVVLCPlaybackController(request: request, session: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCSurface(playback: playback).ignoresSafeArea()

            // Catches the remote while the controls are hidden.
            Color.clear
                .contentShape(Rectangle())
                .focusable(!controlsVisible)
                .focused($focus, equals: .surface)
                .onMoveCommand { dir in
                    switch dir {
                    case .left: playback.skip(seconds: -10)
                    case .right: playback.skip(seconds: 10)
                    default: showControls()
                    }
                }
                .onTapGesture { showControls() }

            if playback.isBuffering && playback.errorMessage == nil { ProgressView().scaleEffect(1.5) }
            if let error = playback.errorMessage {
                VStack(spacing: 20) {
                    Text(error).font(.title3)
                    HStack(spacing: 24) {
                        Button { playback.retry() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        Button("Close") { dismiss() }
                    }
                    .buttonStyle(TVActionStyle())
                }
                .padding(50).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }

            VStack {
                Spacer()
                if controlsVisible { controls.transition(.opacity) }
            }
            if let left = playback.upNextLeft, let next = playback.upNext {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        TVUpNextCard(next: next, secondsLeft: left, playNow: { playback.playNext() },
                                     hide: { playback.hideUpNext(); hideControls() }, playFocused: $upNextFocused)
                            .padding(.trailing, 80)
                            .padding(.bottom, controlsVisible ? 300 : 80)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let label = playback.skipLabel {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(label) { playback.performSkip(); noteActivity() }
                            .focused($focus, equals: .skip)
                            .padding(.trailing, 80)
                            .padding(.bottom, controlsVisible ? 300 : 80)
                    }
                }
            }
        }
        // Track choices as a dialog on the whole screen: it stays open while video plays and controls redraw.
        .confirmationDialog(dialogTitle,
                            isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil; noteActivity() } })) {
            if choosing == .sleep {
                Button(TVSleepTimer.shared.isActive ? "Off" : "✓ Off") { TVSleepTimer.shared.cancel() }
                ForEach(TVSleepTimer.choices, id: \.self) { m in
                    Button("\(m) Minutes") { TVSleepTimer.shared.set(minutes: m) }
                }
                Button(TVSleepTimer.shared.atEndOfItem ? "✓ End of Episode" : "End of Episode") { TVSleepTimer.shared.setEndOfItem() }
            } else if choosing == .options {
                Button("Speed · \(TVSpeedLabel.text(playback.speed))") { open(.speed) }
                Button("Audio Sync · \(AudioSyncLabel.text(playback.audioDelayMs))") { open(.sync) }
                Button("Zoom · \(Int((playback.zoom * 100).rounded()))%") { open(.zoom) }
            } else if choosing == .speed {
                ForEach(PlaybackSpeeds.video, id: \.self) { s in
                    Button(s == playback.speed ? "✓ \(TVSpeedLabel.text(s))" : TVSpeedLabel.text(s)) { playback.speed = s }
                }
            } else if choosing == .sync {
                Button("Sound Earlier (−50 ms)") { playback.audioDelayMs -= 50; open(.sync) }
                Button("Sound Later (+50 ms)") { playback.audioDelayMs += 50; open(.sync) }
                if playback.audioDelayMs != 0 { Button("Reset") { playback.audioDelayMs = 0 } }
            } else if choosing == .zoom {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [CGFloat], id: \.self) { z in
                    let label = "\(Int(z * 100))%"
                    Button(abs(z - playback.zoom) < 0.01 ? "✓ \(label)" : label) { playback.zoom = z }
                }
            } else if choosing == .audio {
                ForEach(playback.audioTracks) { t in
                    Button(t.id == playback.currentAudio ? "✓ \(t.name)" : t.name) { playback.chooseAudio(t.id) }
                }
            } else {
                ForEach(playback.subtitleTracks) { t in
                    Button(t.id == playback.currentSubtitle ? "✓ \(t.name)" : t.name) { playback.chooseSubtitle(t.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onPlayPauseCommand { playback.togglePlay(); showControls() }
        .onExitCommand {
            if controlsVisible && playback.isPlaying { hideControls() } else { playback.stop(); dismiss() }
        }
        .onAppear {
            playback.onFinish = { dismiss() }
            showControls()
            #if DEBUG
            // Development: `-tvShowAudio` opens the Audio choice a few seconds in.
            if ProcessInfo.processInfo.arguments.contains("-tvShowAudio") {
                Task { try? await Task.sleep(for: .seconds(6)); hideTask?.cancel(); playback.syncCurrentTracks(); choosing = .audio }
            }
            #endif
        }
        .onDisappear { playback.stop() }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: playback.upNextLeft == nil)
        // Up Next takes focus when it appears, so a click plays the next episode.
        .onChange(of: playback.upNextLeft == nil) { _, gone in if !gone { upNextFocused = true } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let item = playback.current {
                Text(item.kind == .episode ? (item.grandparentTitle ?? item.title) : item.title).font(.title2.bold())
                if item.kind == .episode, let line = item.subtitleLine { Text(line).foregroundStyle(.secondary) }
            }
            TVPlaybackProgress(clock: playback.clock)
            HStack(spacing: 30) {
                Button { playback.skip(seconds: -10); noteActivity() } label: { Image(systemName: "gobackward.10") }
                    .focused($focus, equals: .back)
                Button { playback.togglePlay(); noteActivity() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .focused($focus, equals: .play)
                Button { playback.skip(seconds: 10); noteActivity() } label: { Image(systemName: "goforward.10") }
                    .focused($focus, equals: .forward)
                Spacer()
                if playback.audioTracks.count > 1 {
                    Button { hideTask?.cancel(); playback.syncCurrentTracks(); choosing = .audio } label: { Label("Audio", systemImage: "speaker.wave.2") }
                        .focused($focus, equals: .audio)
                }
                if !playback.subtitleTracks.isEmpty {
                    Button { hideTask?.cancel(); playback.syncCurrentTracks(); choosing = .subtitles } label: { Label("Subtitles", systemImage: "captions.bubble") }
                        .focused($focus, equals: .subtitles)
                }
                Button { hideTask?.cancel(); choosing = .options } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Playback Options")
                Button { hideTask?.cancel(); choosing = .sleep } label: {
                    Image(systemName: TVSleepTimer.shared.isActive ? "moon.zzz.fill" : "moon.zzz")
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .focusSection()
    }

    private var dialogTitle: String {
        switch choosing {
        case .audio: "Audio"
        case .sleep: "Sleep Timer"
        case .options: "Playback Options"
        case .speed: "Speed"
        case .sync: "Audio Sync · \(AudioSyncLabel.text(playback.audioDelayMs))"
        case .zoom: "Zoom"
        default: "Subtitles"
        }
    }

    /// Opens another choice once the current dialog has closed.
    private func open(_ kind: TrackKind) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            hideTask?.cancel()
            choosing = kind
        }
    }

    private func showControls() {
        controlsVisible = true
        if focus == nil || focus == .surface { focus = .play }
        noteActivity()
    }

    private func hideControls() {
        controlsVisible = false
        if playback.upNextLeft != nil { upNextFocused = true } else { focus = playback.skipLabel != nil ? .skip : .surface }
    }

    private func noteActivity() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            // Never hide while a track choice is open.
            if !Task.isCancelled, playback.isPlaying, choosing == nil { hideControls() }
        }
    }
}

/// Progress bar and times; the only part that redraws as playback moves.
private struct TVPlaybackProgress: View {
    @ObservedObject var clock: TVPlaybackClock

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: Double(clock.timeMs), total: Double(max(clock.durationMs, 1))).tint(TVTheme.accent)
            HStack {
                Text(Fmt.clock(seconds: Double(clock.timeMs) / 1000))
                Spacer()
                Text("-" + Fmt.clock(seconds: Double(max(0, clock.durationMs - clock.timeMs)) / 1000))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The view VLC draws video into.
private struct VLCSurface: UIViewRepresentable {
    let playback: TVVLCPlaybackController
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        DispatchQueue.main.async { playback.start(drawable: view) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
