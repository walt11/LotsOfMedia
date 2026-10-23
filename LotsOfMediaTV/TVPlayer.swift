import AVKit
import SwiftUI

/// Something to play: one item, or a queue (a season's episodes, an album's songs).
struct TVPlayRequest: Identifiable {
    let id = UUID()
    let queue: [PlexMetadata]
    let start: Int
    let resume: Bool

    init(item: PlexMetadata, resume: Bool) { queue = [item]; start = 0; self.resume = resume }
    init(queue: [PlexMetadata], start: Int, resume: Bool = false) { self.queue = queue; self.start = start; self.resume = resume }
}

/// Full-screen playback. Apple's player (Siri Remote scrubbing, chapters, audio and subtitle
/// menus) for what tvOS plays; the built-in VLC player for the rest, with Pro.
struct TVPlayerView: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let request: TVPlayRequest

    var body: some View {
        if let first = request.queue.indices.contains(request.start) ? request.queue[request.start] : nil, BuiltInPlayer.handles(first),
           TVVideoQuality.current(isRelay: session.isRelayConnection) == .original {
            TVVLCPlayerView(request: request, session: session)
        } else {
            TVPlayerRepresentable(request: request, session: session) { dismiss() }
                .ignoresSafeArea()
        }
    }
}

/// Progress reports shared by both players.
enum TVPlaybackReporting {
    /// Tells the server where playback is; a stop past 90% also marks it watched.
    @MainActor
    static func report(_ item: PlexMetadata?, state: String, timeMs: Int, sessionID: String, session: TVSession) async {
        await report(item, state: state, timeMs: timeMs, sessionID: sessionID, api: session.api)
    }

    /// Reports against a given connection (the one playback started on, even if the session has moved on).
    static func report(_ item: PlexMetadata?, state: String, timeMs: Int, sessionID: String, api: PlexServerAPI?) async {
        guard let item, let api, timeMs > 0 else { return }
        try? await api.timeline(ratingKey: item.ratingKey, key: item.key, state: state, timeMs: timeMs,
                                durationMs: item.duration, sessionID: sessionID)
        if state == "stopped", let d = item.duration, d > 0, Double(timeMs) / Double(d) > 0.9 {
            try? await api.scrobble(item.ratingKey)
        }
    }

    /// Subtitle the server should burn into a converted stream: one Apple's player can't show itself.
    static func burnSubtitleID(for item: PlexMetadata) -> Int? {
        guard let sub = item.primaryPart?.selectedSubtitle else { return nil }
        if !sub.isSidecarText, PlaybackDecider.nativeTextSubtitleCodecs.contains((sub.codec ?? "").lowercased()) { return nil }
        return sub.id
    }
}

private struct TVPlayerRepresentable: UIViewControllerRepresentable {
    let request: TVPlayRequest
    let session: TVSession
    let onFinish: () -> Void

    func makeCoordinator() -> TVPlaybackController {
        TVPlaybackController(request: request, session: session, onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        // Leaving the player stops playback, so a Picture in Picture window would just freeze.
        vc.allowsPictureInPicturePlayback = false
        vc.player = context.coordinator.player
        vc.transportBarCustomMenuItems = [TVSleepTimer.shared.menu()]
        vc.speeds = PlaybackSpeeds.video.map { AVPlaybackSpeed(rate: $0, localizedName: TVSpeedLabel.text($0)) }
        context.coordinator.viewController = vc
        context.coordinator.start()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: TVPlaybackController) {
        coordinator.stop()
    }
}

/// Loads each item (direct play when tvOS can, otherwise the server converts it), resumes,
/// reports progress to Plex, and moves on to the next item in the queue.
@MainActor
final class TVPlaybackController: NSObject {
    let player = AVPlayer()
    weak var viewController: AVPlayerViewController?
    private var actionsShown: String?
    private var queue: [PlexMetadata]
    /// The episode after this one, offered at the credits with a countdown.
    private var upNext: PlexMetadata?
    private var upNextHidden = false
    private var upNextCountdown = TVUpNextCountdown()
    private let session: TVSession
    private let onFinish: () -> Void
    private var index: Int
    private let resumeFirst: Bool
    private var current: PlexMetadata?
    private var sessionID = UUID().uuidString
    private var transcoding = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var lastReport = Date.distantPast
    private var stopped = false
    private var sleepObserver: NSObjectProtocol?
    /// The newest load; an older one finishing late is ignored.
    private var loadID = UUID()
    private var statusObservation: NSKeyValueObservation?
    /// Compatible playback (a server conversion) was already tried for this item.
    private var triedCompatible = false
    /// A conversion that stopped (the server ends one left paused or while the app was away)
    /// was already restarted once for this item.
    private var restartedConversion = false
    /// The current stream opened at least once; a conversion that fails before then is retried as H.264.
    private var streamOpened = false
    private var avoidHEVC = false
    /// Profile and server the language choices are remembered for.
    private var languageScope = ""
    /// The player's audio/subtitle choice once it settled; a later change is the viewer's, and is remembered.
    private var languageBaseline: (audio: String?, subtitle: String?)?
    private var selectionObserver: NSObjectProtocol?

    init(request: TVPlayRequest, session: TVSession, onFinish: @escaping () -> Void) {
        queue = request.queue
        index = request.start
        resumeFirst = request.resume
        self.session = session
        self.onFinish = onFinish
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        TVAudioOutput.applyChannelLimit()
    }

    func start() {
        TVMusicPlayer.shared.pause()
        TVLiveNow.shared.stop()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        sleepObserver = NotificationCenter.default.addObserver(forName: .tvSleepTimerFired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.pause() }
        }
        Task { await load(index, resume: resumeFirst) }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        player.pause()
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        let finishedItem = current, time = currentMs, id = sessionID, wasTranscoding = transcoding
        Task { [session] in
            await Self.report(finishedItem, state: "stopped", timeMs: time, sessionID: id, session: session)
            if wasTranscoding, let api = session.api { await api.stopTranscode(sessionID: id) }
            session.contentVersion += 1
        }
    }

    private var currentMs: Int {
        let s = player.currentTime().seconds
        return s.isFinite ? Int(s * 1000) : 0
    }

    /// `startAtMs` restarts at a given point (after a failure); `compatible` asks the server to convert.
    private func load(_ i: Int, resume: Bool, startAtMs: Int? = nil, compatible: Bool = false) async {
        guard !stopped, let api = session.api, queue.indices.contains(i) else { return onFinish() }
        let id = UUID()
        loadID = id
        if i != index || current == nil { triedCompatible = false; restartedConversion = false; avoidHEVC = false }
        index = i
        var loaded = (try? await api.metadata(queue[i].ratingKey)) ?? queue[i]
        guard !stopped, id == loadID else { return }
        // The remembered languages, set on the server first so a conversion uses them too.
        let scope = TVLanguagePreference.scope(session: session)
        languageScope = scope
        if loaded.isPlayableVideo, let partID = loaded.primaryPart?.id,
           let change = LanguagePreference.change(for: loaded.primaryPart, audio: TVLanguagePreference.audio(scope: scope),
                                                  subtitle: TVLanguagePreference.subtitle(scope: scope)) {
            try? await api.selectStreams(partID: partID, audioStreamID: change.audioStreamID, subtitleStreamID: change.subtitleStreamID)
            let key = loaded.ratingKey
            let fresh = (try? await LibraryCache.$requireFresh.withValue(true) { try await api.metadata(key) }) ?? nil
            if let fresh { loaded = fresh }
            guard !stopped, id == loadID else { return }
        }
        let item = loaded
        current = item
        let previousSession = sessionID, wasTranscoding = transcoding
        sessionID = UUID().uuidString
        // A conversion being replaced (a retry) is ended on the server.
        if wasTranscoding, startAtMs != nil { Task { await api.stopTranscode(sessionID: previousSession) } }
        upNext = nil; upNextHidden = false; upNextCountdown.reset(); actionsShown = nil
        viewController?.contextualActions = []
        Task { [queue, index, session] in
            let next = await TVUpNext.next(after: item, queue: queue, index: index, session: session)
            if current?.ratingKey == item.ratingKey { upNext = next }
        }
        // A subtitle Apple's player can't draw (an external file, PGS…) is burned in by the server.
        let burn = TVPlaybackReporting.burnSubtitleID(for: item)
        let quality: StreamingQuality = item.kind == .track ? .original : TVVideoQuality.current(isRelay: session.isRelayConnection)
        let direct = !compatible && PlaybackDecider.shouldDirectPlay(item, quality: quality) && burn == nil
        let url = direct ? PlaybackDecider.directURL(api: api, item: item)
            : PlaybackDecider.transcodeURL(api: api, item: item, quality: quality, sessionID: sessionID,
                                           isLocal: session.isLocalConnection, music: item.kind == .track, burnSubtitleID: burn,
                                           allowHEVC: !avoidHEVC)
        guard let url else { return onFinish() }
        transcoding = !direct

        let avItem = AVPlayerItem(url: url)
        avItem.externalMetadata = metadata(for: item, artwork: nil)
        player.replaceCurrentItem(with: avItem)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded() }
        }
        // A failed stream recovers instead of leaving a stuck player.
        streamOpened = false
        statusObservation = avItem.observe(\.status) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay: DispatchQueue.main.async { self?.streamOpened = true; self?.trackLanguages(of: item) }
            case .failed: DispatchQueue.main.async { self?.playbackFailed(item.error) }
            default: break
            }
        }
        if let offset = startAtMs ?? (resume ? item.viewOffset : nil), offset > 0 {
            // Jump once the stream is open (as on iPhone): a seek queued before then lands on a
            // conversion that's still starting, and the sound can come in out of step.
            for _ in 0..<100 where avItem.status == .unknown {
                try? await Task.sleep(for: .milliseconds(100))
                guard !stopped, id == loadID else { return }
            }
            // Failed: the status observer recovers. Still opening after 10 s: seek anyway (it's
            // queued until the stream is ready) rather than never starting.
            guard avItem.status != .failed else { return }
            await player.seek(to: CMTime(value: CMTimeValue(offset), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Closed (or replaced by a newer load) while seeking: don't start playing again.
        guard !stopped, id == loadID, player.currentItem === avItem else { return }
        player.play()
        lastReport = .distantPast

        // Chapters in the player's info panel, each with its picture (or the preview frame there).
        if item.isPlayableVideo, !item.chapters.isEmpty {
            Task { [session] in
                let groups = await TVChapterMarkers.groups(for: item, api: api, session: session)
                if player.currentItem === avItem, !groups.isEmpty { avItem.navigationMarkerGroups = groups }
            }
        }

        // Artwork for the info panel and the Now Playing screen, once it loads.
        let artPath = item.kind == .track ? (item.parentThumb ?? item.thumb) : (item.kind == .episode ? item.grandparentThumb ?? item.thumb : item.thumb)
        if let artURL = session.imageURL(artPath, width: 600, height: 900), let image = await ImageLoader.shared.image(for: artURL),
           current?.ratingKey == item.ratingKey {
            avItem.externalMetadata = metadata(for: item, artwork: image)
        }
    }

    /// Applies the remembered languages to the file's own tracks, then remembers what the viewer
    /// picks in the player's audio and subtitle menus.
    private func trackLanguages(of avItem: AVPlayerItem) {
        guard player.currentItem === avItem, current?.isPlayableVideo == true else { return }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        languageBaseline = nil
        let scope = languageScope
        Task {
            if !transcoding { await TVLanguagePreference.apply(scope: scope, to: avItem) }
            guard player.currentItem === avItem else { return }
            languageBaseline = await TVLanguagePreference.selection(in: avItem)
            selectionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification,
                                                                       object: avItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged(avItem) }
            }
        }
    }

    private func selectionChanged(_ avItem: AVPlayerItem) {
        let scope = languageScope
        Task {
            guard let now = await TVLanguagePreference.selection(in: avItem), let before = languageBaseline else { return }
            if now.audio != before.audio { TVLanguagePreference.rememberAudio(now.audio, scope: scope) }
            if now.subtitle != before.subtitle { TVLanguagePreference.rememberSubtitle(now.subtitle, scope: scope) }
            languageBaseline = now
        }
    }

    /// The original file failed: try once more as a server conversion at the same point. If that
    /// fails too, say so and offer to try again.
    private func playbackFailed(_ error: Error?) {
        guard !stopped, current != nil else { return }
        let position = currentMs > 0 ? currentMs : nil
        // A conversion the server ended (paused a long time, or the app was away): start a new one
        // at the same point, quietly, once.
        if transcoding && !restartedConversion {
            restartedConversion = true
            if !streamOpened { avoidHEVC = true }
            Task { await load(index, resume: false, startAtMs: position, compatible: true) }
            return
        }
        if !transcoding && !triedCompatible {
            triedCompatible = true
            Task { await load(index, resume: false, startAtMs: position, compatible: true) }
            return
        }
        let alert = UIAlertController(title: "Couldn't Play", message: error?.localizedDescription ?? "Playback stopped unexpectedly.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            guard let self else { return }
            Task { await self.load(self.index, resume: false, startAtMs: position, compatible: self.transcoding) }
        })
        alert.addAction(UIAlertAction(title: "Close", style: .cancel) { [weak self] _ in self?.onFinish() })
        viewController?.present(alert, animated: true)
    }

    private func tick() {
        updateContextualActions()
        guard let current, Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        let state = player.timeControlStatus == .paused ? "paused" : "playing"
        let time = currentMs, id = sessionID
        Task { [session] in await Self.report(current, state: state, timeMs: time, sessionID: id, session: session) }
    }

    /// The player's own contextual buttons: Up Next (with a countdown) at the credits, otherwise
    /// Skip Intro / Skip Credits while a marker is playing.
    private func updateContextualActions() {
        let ms = currentMs
        if let current, let next = upNext, !upNextHidden, !TVSleepTimer.shared.atEndOfItem,
           let trigger = TVUpNext.trigger(for: current, durationMs: current.duration ?? 0), ms >= trigger {
            let left = upNextCountdown.secondsLeft(atMs: ms)
            if left == 0 { return playNext() }
            let key = "next-\(left)"
            guard key != actionsShown else { return }
            actionsShown = key
            // The play button comes last: tvOS focuses the rightmost action, so a click plays it.
            viewController?.contextualActions = [
                UIAction(title: "Hide", image: UIImage(systemName: "xmark")) { [weak self] _ in
                    self?.upNextHidden = true
                    self?.actionsShown = nil
                    self?.viewController?.contextualActions = []
                },
                UIAction(title: next.kind == .episode ? "Next Episode in \(left)" : "Up Next in \(left)", image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.playNext() },
            ]
            return
        }
        upNextCountdown.reset()
        let marker = current?.markers.first { ["intro", "credits"].contains($0.type) && ms >= $0.startTimeOffset && ms < $0.endTimeOffset - 1000 }
        let label = marker.map { $0.type == "intro" ? "Skip Intro" : "Skip Credits" }
        guard label != actionsShown else { return }
        actionsShown = label
        if let marker, let label {
            let target = CMTime(value: CMTimeValue(marker.endTimeOffset), timescale: 1000)
            viewController?.contextualActions = [UIAction(title: label, image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                self?.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }]
        } else {
            viewController?.contextualActions = []
        }
    }

    /// Finishes this episode (marks it watched) and starts the next one.
    private func playNext() {
        guard let next = upNext else { return }
        upNext = nil
        actionsShown = nil
        viewController?.contextualActions = []
        detachOutgoingItem()
        finishCurrent()
        if !(queue.indices.contains(index + 1) && queue[index + 1].ratingKey == next.ratingKey) {
            queue.insert(next, at: index + 1)
        }
        Task { await load(index + 1, resume: false) }
    }

    /// The old episode stops and can no longer report its end while the next one loads
    /// (an end arriving then would advance a second time and skip an episode).
    private func detachOutgoingItem() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func finishCurrent() {
        let finished = current, id = sessionID, wasTranscoding = transcoding
        Task { [session] in
            await Self.report(finished, state: "stopped", timeMs: finished?.duration ?? 0, sessionID: id, session: session)
            if let finished, let api = session.api { try? await api.scrobble(finished.ratingKey) }
            if wasTranscoding, let api = session.api { await api.stopTranscode(sessionID: id) }
        }
        current = nil
    }

    private func itemEnded() {
        // Already moving on (Up Next was chosen as this ended): nothing more to do.
        guard current != nil else { return }
        // The sleep timer set to the end of this episode: stop here.
        if TVSleepTimer.shared.shouldStopAtItemEnd() {
            finishCurrent()
            session.contentVersion += 1
            return onFinish()
        }
        // Up Next goes on unless it was hidden.
        if upNext != nil, !upNextHidden { return playNext() }
        detachOutgoingItem()
        finishCurrent()
        if index + 1 < queue.count, !upNextHidden {
            Task { await load(index + 1, resume: false) }
        } else {
            session.contentVersion += 1
            onFinish()
        }
    }

    private static func report(_ item: PlexMetadata?, state: String, timeMs: Int, sessionID: String, session: TVSession) async {
        await TVPlaybackReporting.report(item, state: state, timeMs: timeMs, sessionID: sessionID, session: session)
    }

    private func metadata(for item: PlexMetadata, artwork: UIImage?) -> [AVMetadataItem] {
        func entry(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m.copy() as? AVMetadataItem
        }
        let subtitle: String? = switch item.kind {
        case .episode: [item.grandparentTitle, item.subtitleLine].compactMap { $0 }.joined(separator: " · ")
        case .track: [item.grandparentTitle, item.parentTitle].compactMap { $0 }.joined(separator: " · ")
        default: item.tvMetaLine
        }
        return [
            entry(.commonIdentifierTitle, item.title as NSString),
            entry(.iTunesMetadataTrackSubTitle, subtitle.map { $0 as NSString }),
            entry(.commonIdentifierDescription, item.summary.map { $0 as NSString }),
            entry(.commonIdentifierArtwork, artwork?.jpegData(compressionQuality: 0.85).map { $0 as NSData }),
        ].compactMap { $0 }
    }
}
