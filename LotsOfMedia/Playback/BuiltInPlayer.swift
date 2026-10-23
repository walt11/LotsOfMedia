import MediaPlayer
import MobileVLCKit
import SwiftUI
import UIKit

/// LotsOfMedia's built-in player (VLC, LGPL-2.1) for files iOS can't play — MKV/AVI,
/// DTS/TrueHD, VC-1, image subtitles — played straight from the original, with no
/// server conversion. Apple's player stays the default for everything it can play
/// (it keeps AirPlay, picture-in-picture and HDR).
enum BuiltInPlayer {
    static let preferenceKey = "playback.builtInPlayer"

    /// Settings → Playback: on by default.
    static var isEnabled: Bool {
        // A Pro feature; without Pro, the server converts these files as before.
        get { ProStore.isUnlocked && (UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// Files the built-in player can take: any single-file video.
    static func canPlay(media: PlexMedia, kind: PlexMetadata.Kind) -> Bool {
        isEnabled && kind != .track && media.parts.count == 1
    }

    /// Whether this request plays here rather than in Apple's player.
    @MainActor
    static func handles(_ r: VideoPlayRequest, quality: StreamingQuality) -> Bool {
        guard r.item.isPlayableVideo, let media = r.item.primaryMedia, canPlay(media: media, kind: r.item.kind) else { return false }
        if r.localURL != nil {
            // Converted downloads are MP4s made for iPhone.
            let converted = r.downloadID.flatMap { id in DownloadManager.shared.records.first { $0.id == id } }?.isConverted ?? false
            return !converted && !PlaybackDecider.canPlayNatively(media: media, kind: r.item.kind)
        }
        // AirPlay and smaller-quality streams go through the server and Apple's player.
        guard !AirPlayStatus.shared.isActive, quality == .original else { return false }
        return !PlaybackDecider.shouldDirectPlay(r.item, quality: .original)
    }
}

/// Lets lock-screen and headphone controls reach a player that isn't an AVPlayer.
@MainActor
protocol ExternalPlaybackControls: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteToggle()
    func remoteSeek(toSeconds: Double)
    func remoteSkip(seconds: Double)
}

/// The Up Next queue of whichever video player is showing.
@MainActor
protocol VideoQueueing: AnyObject {
    func enqueue(_ requests: [VideoPlayRequest])
    func playNext(_ next: VideoPlayRequest)
}

// MARK: - Playback

@MainActor
final class BuiltInPlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate, ExternalPlaybackControls, VideoQueueing {
    struct Track: Identifiable, Hashable { let id: Int32; let name: String }

    let mediaPlayer = VLCMediaPlayer()
    @Published private(set) var request: VideoPlayRequest
    @Published private(set) var upNext: [VideoPlayRequest]
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var timeMs = 0
    @Published private(set) var durationMs = 0
    @Published var errorMessage: String?
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var currentAudio: Int32 = -1
    @Published private(set) var currentSubtitle: Int32 = -1
    @Published private(set) var skipLabel: String?
    @Published var speed: Float = 1 { didSet { mediaPlayer.rate = speed } }
    /// Thumbnails for the scrubber, when the server made them.
    @Published private(set) var previews: ScrubPreviews?
    /// Sound later (positive) or earlier (negative) than the picture, to fix lip sync.
    @Published var audioDelayMs = 0 { didSet { mediaPlayer.currentAudioPlaybackDelay = audioDelayMs * 1000 } }

    /// Called when the last item ends (the screen closes).
    var onFinished: (() -> Void)?

    private let userID: String?
    private var api: PlexServerAPI?
    private var sessionID = UUID().uuidString
    private var markers: [PlexMarker] = []
    private var skipTarget: Int?
    private var lastReport = Date.distantPast
    private var lastState = ""
    private var tracksApplied = false
    private var stopped = false
    private var backgroundObserver: NSObjectProtocol?

    init(request: VideoPlayRequest, upNext: [VideoPlayRequest] = []) {
        self.request = request
        self.upNext = upNext
        self.userID = DownloadManager.shared.activeUserID
        self.api = ServerDirectory.shared.api(for: request.serverID)
        super.init()
    }

    func start(drawable: UIView) {
        AudioPlayer.shared.pause()
        PlaybackFocus.claimExternal(self)
        mediaPlayer.delegate = self
        mediaPlayer.drawable = drawable
        // No picture-in-picture here, so pause rather than drawing video in the background.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaPlayer.pause() }
        }
        load(request)
    }

    private func load(_ r: VideoPlayRequest) {
        request = r
        api = ServerDirectory.shared.api(for: r.serverID)
        sessionID = UUID().uuidString
        markers = r.item.markers
        durationMs = r.item.duration ?? 0
        timeMs = r.startMs
        tracksApplied = false
        audioTracks = []
        subtitleTracks = []
        skipLabel = nil
        lastState = ""
        errorMessage = nil
        isBuffering = true
        previews = nil

        guard let url = r.localURL ?? api.flatMap({ PlaybackDecider.directURL(api: $0, item: r.item) }) else {
            errorMessage = "Server unavailable."
            return
        }
        guard url.isFileURL || MediaPreferences.shared.streamAllowed(.watch) else {
            errorMessage = "Watch streaming over cellular is disabled in Playback Preferences."
            return
        }
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        if VolumeLeveling.isOn { VolumeLeveling.vlcOptions.forEach { media.addOption($0) } }
        // DVD-era formats are usually interlaced; without this, motion shows comb lines.
        if let codec = r.item.primaryMedia?.videoCodec?.lowercased(), ["mpeg2video", "mpeg1video", "vc1", "mpeg2"].contains(codec) {
            media.addOption(":deinterlace=1")
            media.addOption(":deinterlace-mode=yadif")
        }
        if r.startMs > 0 { media.addOption(":start-time=\(Double(r.startMs) / 1000)") }
        // Open on the chosen audio track rather than switching once playing: switching right
        // after a resume restarts the audio decoder mid-seek, which can leave it out of sync.
        if let n = VLCTrackChoice.audioIndex(in: r.item) { media.addOption(":audio-track=\(n)") }
        mediaPlayer.media = media
        mediaPlayer.play()
        mediaPlayer.rate = speed
        mediaPlayer.currentAudioPlaybackDelay = audioDelayMs * 1000
        for sub in sidecarSubtitles(r) { mediaPlayer.addPlaybackSlave(sub, type: .subtitle, enforce: false) }
        updateNowPlaying()

        // Fresh metadata brings intro/credit markers.
        if r.localURL == nil || NetworkMonitor.shared.isConnected, let api {
            Task { [ratingKey = r.item.ratingKey] in
                guard let fresh = try? await api.metadata(ratingKey), request.item.ratingKey == ratingKey else { return }
                markers = fresh.markers
                let loaded = await ScrubPreviews.load(api: api, item: fresh)
                if request.item.ratingKey == ratingKey { previews = loaded }
            }
        }
    }

    /// Subtitle files outside the video: the server's sidecar files, or ones saved with a download.
    private func sidecarSubtitles(_ r: VideoPlayRequest) -> [URL] {
        if r.localURL != nil, let id = r.downloadID, let rec = DownloadManager.shared.records.first(where: { $0.id == id }) {
            return rec.subtitleFiles.map { DownloadStore.directory(for: rec.id).appendingPathComponent($0.fileName) }
        }
        guard let api else { return [] }
        return (r.item.primaryPart?.subtitleStreams ?? []).compactMap { s in
            s.key.map { api.url($0, query: PlexClient.queryItems(token: api.token)) }
        }
    }

    // MARK: Controls

    func togglePlay() { mediaPlayer.isPlaying ? mediaPlayer.pause() : mediaPlayer.play() }
    func skip(seconds: Int) {
        if seconds >= 0 { mediaPlayer.jumpForward(Int32(seconds)) } else { mediaPlayer.jumpBackward(Int32(-seconds)) }
    }
    func seek(toMs ms: Int) {
        mediaPlayer.time = VLCTime(int: Int32(clamping: max(0, ms)))
        timeMs = ms
    }
    func selectAudio(_ id: Int32) { mediaPlayer.currentAudioTrackIndex = id; currentAudio = id }
    func selectSubtitle(_ id: Int32) { mediaPlayer.currentVideoSubTitleIndex = id; currentSubtitle = id }

    func performSkip() {
        guard let skipTarget else { return }
        seek(toMs: skipTarget)
        skipLabel = nil
    }

    // MARK: Queue

    func enqueue(_ requests: [VideoPlayRequest]) {
        var known = Set((upNext + [request]).map { "\($0.serverID):\($0.item.ratingKey)" })
        upNext += requests.filter { known.insert("\($0.serverID):\($0.item.ratingKey)").inserted }
    }

    func playNext(_ next: VideoPlayRequest) {
        upNext.removeAll { $0.serverID == next.serverID && $0.item.ratingKey == next.item.ratingKey }
        upNext.insert(next, at: 0)
    }

    // MARK: VLC events (delivered on the main thread)

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { timeChanged() }
    }

    private func stateChanged() {
        guard !stopped else { return }
        switch mediaPlayer.state {
        case .playing:
            isPlaying = true
            isBuffering = false
            refreshTracks()
            report(force: true)
        case .paused:
            isPlaying = false
            report(force: true)
        case .buffering:
            if !mediaPlayer.isPlaying { isBuffering = true }
        case .esAdded:
            refreshTracks()
        case .ended:
            Task { await finishItem() }
        case .error:
            isBuffering = false
            errorMessage = request.localURL != nil ? "This download couldn't be played." : "This video couldn't be played. Check your connection, or turn off the built-in player in Playback Preferences to let your server convert it."
        default:
            break
        }
        updateNowPlaying()
    }

    private func timeChanged() {
        guard !stopped else { return }
        timeMs = Int(mediaPlayer.time.intValue)
        if let length = mediaPlayer.media?.length.intValue, length > 0 { durationMs = Int(length) }
        isBuffering = false
        updateSkip()
        report(force: false)
    }

    private func refreshTracks() {
        func tracks(_ names: [Any]?, _ ids: [Any]?) -> [Track] {
            let n = (names as? [String]) ?? []
            let i = (ids as? [NSNumber])?.map(\.int32Value) ?? []
            return zip(i, n).filter { $0.0 >= 0 }.map { Track(id: $0.0, name: $0.1) }
        }
        audioTracks = tracks(mediaPlayer.audioTrackNames, mediaPlayer.audioTrackIndexes)
        subtitleTracks = tracks(mediaPlayer.videoSubTitlesNames, mediaPlayer.videoSubTitlesIndexes)
        currentAudio = mediaPlayer.currentAudioTrackIndex
        currentSubtitle = mediaPlayer.currentVideoSubTitleIndex
        applyPlexTrackChoices()
    }

    /// Starts on the audio and subtitle tracks chosen in Plex (matched by position in the file).
    private func applyPlexTrackChoices() {
        guard !tracksApplied, !audioTracks.isEmpty, let part = request.item.primaryPart else { return }
        tracksApplied = true
        let audio = part.audioStreams
        // Usually already open on it (see load); only switch when VLC picked another.
        if let chosen = part.selectedAudio, let n = audio.firstIndex(where: { $0.id == chosen.id }), audioTracks.indices.contains(n),
           audioTracks[n].id != mediaPlayer.currentAudioTrackIndex {
            selectAudio(audioTracks[n].id)
        }
        let embedded = part.subtitleStreams.filter { $0.key == nil }
        if let chosen = part.selectedSubtitle {
            if let n = embedded.firstIndex(where: { $0.id == chosen.id }), subtitleTracks.indices.contains(n) {
                selectSubtitle(subtitleTracks[n].id)
            } else if chosen.key != nil, let last = subtitleTracks.last {
                selectSubtitle(last.id)   // a sidecar file, added after the embedded tracks
            }
        }
    }

    private func updateSkip() {
        if let m = markers.first(where: { ["intro", "credits"].contains($0.type) && timeMs >= $0.startTimeOffset && timeMs < $0.endTimeOffset - 1000 }) {
            skipLabel = m.type == "intro" ? "Skip Intro" : "Skip Credits"
            skipTarget = m.endTimeOffset
        } else {
            skipLabel = nil
            skipTarget = nil
        }
    }

    private func finishItem() async {
        let final = report(force: true, state: "stopped")
        if let final { await PlaybackReportDeadline.wait(for: final) }
        guard !stopped else { return }
        if !upNext.isEmpty {
            load(upNext.removeFirst())
        } else {
            onFinished?()
        }
    }

    // MARK: Plex progress

    @discardableResult
    private func report(force: Bool, state explicit: String? = nil) -> Task<Void, Never>? {
        let state = explicit ?? (isPlaying ? "playing" : "paused")
        guard force || state != lastState || Date().timeIntervalSince(lastReport) > 10 else { return nil }
        lastState = state
        lastReport = Date()
        let pos = timeMs, dur = durationMs > 0 ? durationMs : nil
        if let id = request.downloadID {
            DownloadManager.shared.recordOfflineProgress(id, positionMs: pos, durationMs: dur, userID: userID)
        }
        guard let api else { return nil }
        let item = request.item, sid = sessionID
        return Task.detached {
            try? await api.timeline(ratingKey: item.ratingKey, key: item.key, state: state, timeMs: pos, durationMs: dur, sessionID: sid)
        }
    }

    func stop() async {
        guard !stopped else { return }
        let final = report(force: true, state: "stopped")
        stopped = true
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        PlaybackFocus.releaseExternal(self)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let final { await PlaybackReportDeadline.wait(for: final) }
    }

    // MARK: Lock screen

    private func updateNowPlaying() {
        guard !stopped else { return }
        let item = request.item
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.grandparentTitle ?? item.year.map(String.init) ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(timeMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
    }

    func remotePlay() { mediaPlayer.play() }
    func remotePause() { mediaPlayer.pause() }
    func remoteToggle() { togglePlay() }
    func remoteSeek(toSeconds s: Double) { seek(toMs: Int(s * 1000)) }
    func remoteSkip(seconds: Double) { skip(seconds: Int(seconds)) }
}

// MARK: - Screen

/// Full-screen host: VLC draws into `videoView`; our SwiftUI controls sit on top.
final class BuiltInPlayerViewController: UIViewController {
    let playback: BuiltInPlaybackController
    var onClose: (() -> Void)?
    private let videoView = UIView()
    private var started = false

    init(playback: BuiltInPlaybackController) {
        self.playback = playback
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        let controls = UIHostingController(rootView: BuiltInPlayerControls(playback: playback, close: { [weak self] in self?.close() },
                                                                           setZoom: { [weak self] in self?.setZoom($0, fill: $1) })
            .preferredColorScheme(.dark))   // light-mode slider tracks vanish on black
        controls.view.backgroundColor = .clear
        addChild(controls)
        controls.view.frame = view.bounds
        controls.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls.view)
        controls.didMove(toParent: self)
        playback.onFinished = { [weak self] in self?.close() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        playback.start(drawable: videoView)
        becomeFirstResponder()
    }

    private var fills = false
    private var zoom: CGFloat = 1
    /// Fit the whole picture or fill the screen (cropping the edges), then zoom by `zoom`
    /// (0.5–2, from the menu or pinching).
    private func setZoom(_ zoom: CGFloat, fill: Bool) {
        self.zoom = zoom
        fills = fill
        applyFill()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyFill()
    }

    private func applyFill() {
        let video = playback.mediaPlayer.videoSize
        let bounds = view.bounds.size
        var scale = zoom
        if fills, video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 {
            let fit = min(bounds.width / video.width, bounds.height / video.height)
            let fill = max(bounds.width / video.width, bounds.height / video.height)
            scale *= fill / fit
        }
        let transform = scale == 1 ? .identity : CGAffineTransform(scaleX: scale, y: scale)
        guard videoView.transform != transform else { return }
        UIView.animate(withDuration: 0.15) { self.videoView.transform = transform }
    }

    private func close() {
        guard presentingViewController != nil else { return }
        dismiss(animated: true) { [onClose] in onClose?() }
    }

    // Keyboard (Mac, iPad keyboards): Space plays and pauses, the arrows skip 10 seconds, Escape closes.
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Play/Pause", action: #selector(keyTogglePlay), input: " "),
            UIKeyCommand(title: "Back 10 Seconds", action: #selector(keySkipBack), input: UIKeyCommand.inputLeftArrow),
            UIKeyCommand(title: "Forward 10 Seconds", action: #selector(keySkipForward), input: UIKeyCommand.inputRightArrow),
            UIKeyCommand(title: "Close", action: #selector(keyClose), input: UIKeyCommand.inputEscape),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func keyTogglePlay() { playback.togglePlay() }
    @objc private func keySkipBack() { playback.skip(seconds: -10) }
    @objc private func keySkipForward() { playback.skip(seconds: 10) }
    @objc private func keyClose() { close() }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

/// Play/pause, ±10 s, scrubber, audio and subtitle tracks, speed, audio sync, zoom and Skip Intro.
struct BuiltInPlayerControls: View {
    @ObservedObject var playback: BuiltInPlaybackController
    let close: () -> Void
    let setZoom: (_ zoom: CGFloat, _ fill: Bool) -> Void
    @State private var visible = true
    @State private var scrubMs: Double?
    @State private var fill = false
    @State private var zoom: CGFloat = 1
    /// Zoom when the pinch began.
    @State private var pinchStart: CGFloat?
    static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { visible ? hide() : show() }
                .gesture(MagnifyGesture()
                    .onChanged { g in
                        let start = pinchStart ?? zoom
                        pinchStart = start
                        zoom = min(max(start * g.magnification, 0.5), 2)
                        setZoom(zoom, fill)
                    }
                    .onEnded { _ in
                        pinchStart = nil
                        // Snap close to 100% back to it.
                        if abs(zoom - 1) < 0.06 { zoom = 1; setZoom(zoom, fill) }
                    })
            if playback.isBuffering && playback.errorMessage == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            if visible { chrome.transition(.opacity) }
            if let label = playback.skipLabel, playback.errorMessage == nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(label) { playback.performSkip() }
                            .font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, visible ? 110 : 40)
                .padding(.horizontal, 24)
            }
            if let error = playback.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("Close", action: close).prominentButton()
                }
                .foregroundStyle(.white)
                .padding(32)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onAppear { scheduleHide() }
        .onChange(of: playback.isPlaying) { _, playing in if playing { scheduleHide() } else { show(autoHide: false) } }
    }

    private var chrome: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                topBar
                Spacer()
                centerButtons
                Spacer()
                scrubber
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            Button(action: close) { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                .accessibilityLabel("Close")
            Text(playback.request.item.displayTitle).font(.headline).lineLimit(1)
            Spacer()
            if playback.audioTracks.count > 1 {
                Menu {
                    ForEach(playback.audioTracks) { t in
                        Button { playback.selectAudio(t.id) } label: { checkLabel(t.name, on: t.id == playback.currentAudio) }
                    }
                } label: { Image(systemName: "speaker.wave.2").font(.title3) }
                .accessibilityLabel("Audio")
            }
            if !playback.subtitleTracks.isEmpty {
                Menu {
                    Button { playback.selectSubtitle(-1) } label: { checkLabel("Off", on: playback.currentSubtitle < 0) }
                    ForEach(playback.subtitleTracks) { t in
                        Button { playback.selectSubtitle(t.id) } label: { checkLabel(t.name, on: t.id == playback.currentSubtitle) }
                    }
                } label: { Image(systemName: "captions.bubble").font(.title3) }
                .accessibilityLabel("Subtitles")
            }
            Menu {
                Menu {
                    ForEach(VideoPlaybackController.speeds, id: \.self) { s in
                        Button { playback.speed = s } label: { checkLabel(SpeedLabel.text(s), on: s == playback.speed) }
                    }
                } label: { Label("Speed · \(SpeedLabel.text(playback.speed))", systemImage: "gauge.with.dots.needle.67percent") }
                Menu {
                    Button { playback.audioDelayMs -= 50 } label: { Label("Sound Earlier (−50 ms)", systemImage: "minus") }
                    Button { playback.audioDelayMs += 50 } label: { Label("Sound Later (+50 ms)", systemImage: "plus") }
                    if playback.audioDelayMs != 0 { Button("Reset") { playback.audioDelayMs = 0 } }
                } label: { Label("Audio Sync · \(AudioSyncLabel.text(playback.audioDelayMs))", systemImage: "waveform.badge.plus") }
                Menu {
                    ForEach(Self.zoomSteps, id: \.self) { z in
                        Button { zoom = z; setZoom(z, fill) } label: { checkLabel("\(Int(z * 100))%", on: abs(z - zoom) < 0.01) }
                    }
                } label: { Label("Zoom · \(Int((zoom * 100).rounded()))%", systemImage: "plus.magnifyingglass") }
            } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
            .accessibilityLabel("Playback Options")
            Button { fill.toggle(); setZoom(zoom, fill) } label: {
                Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.title3)
            }
            .accessibilityLabel(fill ? "Fit to Screen" : "Fill Screen")
        }
        .simultaneousGesture(TapGesture().onEnded { scheduleHide() })
    }

    private var centerButtons: some View {
        HStack(spacing: 56) {
            Button { playback.skip(seconds: -10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.system(size: 34)) }
                .accessibilityLabel("Back 10 seconds")
            Button { playback.togglePlay(); scheduleHide() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 50))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(seconds: 10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.system(size: 34)) }
                .accessibilityLabel("Forward 10 seconds")
        }
        .opacity(playback.errorMessage == nil ? 1 : 0)
    }

    private var scrubber: some View {
        let duration = Double(max(playback.durationMs, 1))
        let shown = scrubMs ?? Double(playback.timeMs)
        return VStack(spacing: 4) {
            // A drawn bar: the system slider's track is nearly invisible over black video.
            GeometryReader { geo in
                let fraction = min(max(shown / duration, 0), 1)
                ZStack(alignment: .leading) {
                    if let scrubMs, let previews = playback.previews {
                        ScrubPreviewThumbnail(previews: previews, ms: Int(scrubMs))
                            .offset(x: min(max(geo.size.width * fraction - 90, 0), max(geo.size.width - 180, 0)), y: -80)
                            .allowsHitTesting(false)
                    }
                    Capsule().fill(.white.opacity(0.3)).frame(height: scrubMs == nil ? 4 : 8)
                    Capsule().fill(Cinema.accent).frame(width: geo.size.width * fraction, height: scrubMs == nil ? 4 : 8)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .offset(x: geo.size.width * fraction - 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        hideTask?.cancel()
                        scrubMs = min(max(g.location.x / geo.size.width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let s = scrubMs { playback.seek(toMs: Int(s)) }
                        scrubMs = nil
                        scheduleHide()
                    })
            }
            .frame(height: 28)
            .animation(.easeOut(duration: 0.15), value: scrubMs == nil)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Fmt.clock(seconds: shown / 1000))
            .accessibilityAdjustableAction { direction in
                playback.skip(seconds: direction == .increment ? 10 : -10)
            }
            HStack {
                Text(Fmt.clock(seconds: shown / 1000))
                Spacer()
                Text("-" + Fmt.clock(seconds: max(0, duration - shown) / 1000))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .opacity(playback.errorMessage == nil ? 1 : 0)
    }

    @ViewBuilder
    private func checkLabel(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    private func show(autoHide: Bool = true) {
        visible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func hide() {
        hideTask?.cancel()
        visible = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, playback.isPlaying else { return }
            visible = false
        }
    }
}

/// The frame at the scrub position, above the scrubber.
struct ScrubPreviewThumbnail: View {
    let previews: ScrubPreviews
    let ms: Int
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) } else { Color.black }
            }
            .frame(width: 180, height: 101)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.6), lineWidth: 1))
            Text(Fmt.clock(seconds: Double(ms) / 1000)).font(.caption.monospacedDigit().weight(.semibold))
        }
        .shadow(radius: 6)
        // Every 2 seconds of scrub position at most, so dragging doesn't decode every frame.
        .task(id: ms / 2000) {
            if let found = await previews.image(atMs: ms) { image = found }
        }
    }
}
