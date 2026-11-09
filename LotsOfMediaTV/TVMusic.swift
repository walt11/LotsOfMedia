import AVFoundation
import MediaPlayer
import SwiftUI

/// Music keeps playing while you browse: one shared queue, the remote's play/pause button,
/// and the Now Playing screen. Progress goes to the server like on iPhone.
@MainActor @Observable
final class TVMusicPlayer {
    static let shared = TVMusicPlayer()

    private(set) var queue: [PlexMetadata] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var timeMs = 0
    private(set) var durationMs = 0
    var current: PlexMetadata? { queue.indices.contains(index) ? queue[index] : nil }
    var isActive: Bool { current != nil }
    var hasNext: Bool { index + 1 < queue.count || (repeatMode == .all && queue.count > 1) }

    enum RepeatMode: String, Codable, CaseIterable { case off, all, one }
    /// Remembered between launches.
    private(set) var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "tv.music.repeat") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "tv.music.repeat") }
    }

    /// The queue, saved so it comes back (paused) on the next launch with the same server.
    struct SavedQueue: Codable { var items: [PlexMetadata]; var index: Int; var positionMs: Int; var serverID: String; var snapshotID: UUID? = nil }
    @ObservationIgnored private var pendingStartMs: Int?
    @ObservationIgnored private var lastSave = Date.distantPast
    nonisolated static var savedQueueURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tv-music-queue.json")
    }
    /// The place in the queue, rewritten while playing; the queue file only when the queue changes.
    nonisolated static var checkpointURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tv-music-position.json")
    }
    struct Checkpoint: Codable { var index: Int; var positionMs: Int; var snapshotID: UUID }
    /// Encoding and writing happen here, off the main thread, in order.
    private static let writer = DispatchQueue(label: "net.jwalter.LotsOfMedia.tvMusicQueue", qos: .utility)
    @ObservationIgnored private var savedKeys: [String] = []
    @ObservationIgnored private var snapshotID = UUID()

    /// A queue player: the next song is lined up behind the current one so it starts without a gap.
    @ObservationIgnored private let player = AVQueuePlayer()
    /// The next song, buffering behind the current one.
    @ObservationIgnored private var prepared: (item: AVPlayerItem, index: Int, ratingKey: String, transcode: Bool, sessionID: String)?
    @ObservationIgnored private var preparedObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var session: TVSession?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var transcoding = false
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// The song's conversion was already restarted once (the server ends one left paused).
    @ObservationIgnored private var restartedConversion = false

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        registerCommands()
    }

    /// The remote's Play/Pause and the system's Now Playing controls for the music. While the app has
    /// these, tvOS sends the remote's Play/Pause here rather than to a video on screen, so they're
    /// only registered while music is what's playing.
    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(toMs: Int(e.positionTime * 1000)) }
            return .success
        }
    }

    private func unregisterCommands() {
        guard commandsRegistered else { return }
        commandsRegistered = false
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand,
                        center.previousTrackCommand, center.changePlaybackPositionCommand] {
            command.removeTarget(nil)
        }
    }

    /// Set while a video plays: the music's Now Playing entry and remote commands are out of the way.
    @ObservationIgnored private var yielded = false
    @ObservationIgnored private var commandsRegistered = false

    /// A video is starting: the music pauses and gives up Now Playing. Otherwise tvOS reads the
    /// remote's Play/Pause against the paused song (it sends "play" to the app, which is already
    /// playing the video) and the video never gets the button.
    func yieldToVideo() {
        if isPlaying { pause() }
        yielded = true
        unregisterCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Music is playing again: it takes Now Playing and the remote's commands back.
    private func reclaim() {
        guard yielded else { return }
        yielded = false
        registerCommands()
    }

    func play(_ tracks: [PlexMetadata], start: Int = 0, session: TVSession) {
        let playable = tracks.filter { $0.kind == .track }
        guard !playable.isEmpty else { return }
        // Live TV first: stopping it clears the remote's commands, which the music then takes.
        TVLiveNow.shared.stop()
        reclaim()
        self.session = session
        queue = playable
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        load(min(max(0, start), playable.count - 1))
    }

    func toggle() { isPlaying ? pause() : resume() }
    func pause() { player.pause(); isPlaying = false; report("paused"); updateNowPlaying(); saveQueue() }
    func resume() {
        guard current != nil else { return }
        reclaim()
        // A restored queue loads its song on the first press of play.
        if player.currentItem == nil { load(index, startAtMs: pendingStartMs); pendingStartMs = nil; return }
        player.play(); isPlaying = true; updateNowPlaying()
    }
    func next() {
        guard hasNext else { return }
        finishCurrent(scrobble: false)
        load(index + 1 < queue.count ? index + 1 : 0)
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
        prepareNext()
    }

    /// Shuffles what's coming up (the current song keeps playing).
    func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        queue = Array(queue.prefix(index + 1)) + queue.suffix(from: index + 1).shuffled()
        queueEdited()
    }

    // MARK: Queue editing

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        queue.remove(at: i)
        if i < index { index -= 1 }
        queueEdited()
    }

    /// Moves a song to play right after the current one.
    func playNext(at i: Int) {
        guard queue.indices.contains(i), i != index, i != index + 1 else { return }
        let song = queue.remove(at: i)
        if i < index { index -= 1 }
        queue.insert(song, at: index + 1)
        queueEdited()
    }

    func move(at i: Int, by delta: Int) {
        let j = i + delta
        guard queue.indices.contains(i), queue.indices.contains(j), i != index, j != index else { return }
        queue.swapAt(i, j)
        queueEdited()
    }

    /// Adds songs right after the current one (or starts them when nothing is playing).
    func queueNext(_ tracks: [PlexMetadata], session: TVSession) {
        let songs = tracks.filter { $0.kind == .track }
        guard !songs.isEmpty else { return }
        if queue.isEmpty { return play(songs, session: session) }
        queue.insert(contentsOf: songs, at: index + 1)
        queueEdited()
    }
    func previous() {
        if timeMs > 3000 || index == 0 { seek(toMs: 0) } else { finishCurrent(scrobble: false); load(index - 1) }
    }
    func jump(to i: Int) { guard queue.indices.contains(i) else { return }; finishCurrent(scrobble: false); load(i) }
    func seek(toMs ms: Int) { player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000)); timeMs = ms; updateNowPlaying() }

    private func queueEdited() {
        saveQueue()
        prepareNext()
    }

    func stop() {
        finishCurrent(scrobble: false)
        dropPrepared()
        player.removeAllItems()
        queue = []; index = 0; isPlaying = false; pendingStartMs = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        savedKeys = []
        Self.writer.async {
            try? FileManager.default.removeItem(at: Self.savedQueueURL)
            try? FileManager.default.removeItem(at: Self.checkpointURL)
        }
    }

    /// Writes the queue and place (small on TV; done on changes and every 15 seconds while playing).
    func saveQueue() {
        lastSave = Date()
        guard let serverID = session?.api?.serverID, !queue.isEmpty else { return }
        let items = queue, idx = index, position = timeMs
        let keys = items.map(\.ratingKey)
        let queueChanged = keys != savedKeys
        if queueChanged { savedKeys = keys; snapshotID = UUID() }
        let snapshot = snapshotID
        Self.writer.async {
            if queueChanged {
                let saved = SavedQueue(items: items.map { $0.trimmedForStorage() }, index: idx, positionMs: position,
                                       serverID: serverID, snapshotID: snapshot)
                if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.savedQueueURL, options: .atomic) }
            }
            if let data = try? JSONEncoder().encode(Checkpoint(index: idx, positionMs: position, snapshotID: snapshot)) {
                try? data.write(to: Self.checkpointURL, options: .atomic)
            }
        }
    }

    /// Brings back the last queue, paused, when connected to the server it came from.
    /// Where a saved queue resumes: the checkpoint when it belongs to this queue (it's newer),
    /// else the queue file's own place. A queue saved by an older version (no snapshot ID) is
    /// rewritten on the next save, so later checkpoints match it.
    nonisolated static func restorePlan(saved: SavedQueue, checkpoint: Checkpoint?) -> (index: Int, positionMs: Int, rewriteQueue: Bool) {
        let last = max(0, saved.items.count - 1)
        if let c = checkpoint, let id = saved.snapshotID, c.snapshotID == id {
            return (min(max(0, c.index), last), c.positionMs, false)
        }
        return (min(max(0, saved.index), last), saved.positionMs, saved.snapshotID == nil)
    }

    func restore(session: TVSession) {
        guard queue.isEmpty, let serverID = session.api?.serverID,
              let data = try? Data(contentsOf: Self.savedQueueURL),
              let saved = try? JSONDecoder().decode(SavedQueue.self, from: data),
              saved.serverID == serverID, !saved.items.isEmpty else { return }
        self.session = session
        queue = saved.items
        let checkpoint = (try? Data(contentsOf: Self.checkpointURL)).flatMap { try? JSONDecoder().decode(Checkpoint.self, from: $0) }
        let plan = Self.restorePlan(saved: saved, checkpoint: checkpoint)
        index = plan.index
        timeMs = plan.positionMs
        savedKeys = plan.rewriteQueue ? [] : saved.items.map(\.ratingKey)
        snapshotID = saved.snapshotID ?? UUID()
        durationMs = queue[index].duration ?? 0
        pendingStartMs = timeMs
        isPlaying = false
        updateNowPlaying()
    }

    private func load(_ i: Int, startAtMs: Int? = nil, restart: Bool = false) {
        guard let api = session?.api, queue.indices.contains(i) else { return }
        if !restart { restartedConversion = false }
        index = i
        let item = queue[i]
        let sid = UUID().uuidString
        guard let src = source(item, api: api, sessionID: sid) else { return }
        sessionID = sid
        transcoding = src.transcode
        timeMs = 0
        durationMs = item.duration ?? 0
        let avItem = AVPlayerItem(url: src.url)
        dropPrepared()
        player.removeAllItems()
        player.insert(avItem, after: nil)
        attach(avItem)
        if let startAtMs, startAtMs > 0 {
            player.seek(to: CMTime(value: CMTimeValue(startAtMs), timescale: 1000))
            timeMs = startAtMs
        }
        player.play()
        isPlaying = true
        lastReport = .distantPast
        saveQueue()
        loadArtwork(item)
        prepareNext()
    }

    private func source(_ item: PlexMetadata, api: PlexServerAPI, sessionID: String) -> (url: URL, transcode: Bool)? {
        let direct = PlaybackDecider.shouldDirectPlay(item, quality: .original)
        let url = direct ? PlaybackDecider.directURL(api: api, item: item)
            : PlaybackDecider.transcodeURL(api: api, item: item, quality: .original, sessionID: sessionID,
                                           isLocal: session?.isLocalConnection ?? false, music: true)
        return url.map { ($0, !direct) }
    }

    /// Watches the playing song for failure and its end.
    private func attach(_ avItem: AVPlayerItem) {
        statusObservation = avItem.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.songFailed(item) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
    }

    private func loadArtwork(_ item: PlexMetadata) {
        artwork = nil
        updateNowPlaying()
        Task {
            guard let path = item.parentThumb ?? item.thumb, let url = session?.imageURL(path, width: 600, height: 600),
                  let image = await ImageLoader.shared.image(for: url), current?.ratingKey == item.ratingKey else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    // MARK: Gapless

    /// The song after the current one at its natural end (repeat one reloads the same song).
    private var naturalNext: Int? {
        if repeatMode == .one { return nil }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all && queue.count > 1 ? 0 : nil
    }

    /// Lines up the next song behind the current one (a minute buffered), so it starts without a
    /// gap. Re-run when the queue or repeat changes; an unchanged next song is kept.
    private func prepareNext() {
        let n = naturalNext
        if let p = prepared, let n, queue[n].ratingKey == p.ratingKey { prepared?.index = n; return }
        dropPrepared()
        guard let n, let current = player.currentItem, !TVSleepTimer.shared.atEndOfItem, let api = session?.api else { return }
        let item = queue[n], sid = UUID().uuidString
        guard let src = source(item, api: api, sessionID: sid) else { return }
        let avItem = AVPlayerItem(url: src.url)
        avItem.preferredForwardBufferDuration = 60
        player.insert(avItem, after: current)
        prepared = (avItem, n, item.ratingKey, src.transcode, sid)
        // A queued song that fails is dropped; the end of this one then loads it the usual way.
        preparedObservation = avItem.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, self.prepared?.item === item else { return }
                self.player.remove(item)
                self.prepared = nil
            }
        }
    }

    private func dropPrepared() {
        guard let p = prepared else { return }
        player.remove(p.item)
        if p.transcode, let api = session?.api { Task { await api.stopTranscode(sessionID: p.sessionID) } }
        prepared = nil
        preparedObservation = nil
    }

    /// The queue player moved on to the lined-up song by itself: make it the current one.
    private func adopt(_ p: (item: AVPlayerItem, index: Int, ratingKey: String, transcode: Bool, sessionID: String), play: Bool) {
        prepared = nil
        preparedObservation = nil
        index = p.index
        sessionID = p.sessionID
        transcoding = p.transcode
        restartedConversion = false
        timeMs = 0
        durationMs = queue[index].duration ?? 0
        attach(p.item)
        if p.item.status == .failed { songFailed(p.item) }
        if play { isPlaying = true } else { player.pause(); isPlaying = false }
        lastReport = .distantPast
        saveQueue()
        loadArtwork(queue[index])
        prepareNext()
    }

    private func tick() {
        let s = player.currentTime().seconds
        if s.isFinite { timeMs = Int(s * 1000) }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { durationMs = Int(d * 1000) }
        if isPlaying, Date().timeIntervalSince(lastReport) >= 10 { report("playing") }
        if isPlaying, Date().timeIntervalSince(lastSave) >= 15 { saveQueue() }
    }

    /// A song that won't play: a conversion the server ended is started again at the same point
    /// (once); otherwise it moves on to the next song.
    private func songFailed(_ item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        if transcoding && !restartedConversion {
            restartedConversion = true
            return load(index, startAtMs: timeMs, restart: true)
        }
        if index + 1 < queue.count { load(index + 1) } else { isPlaying = false; updateNowPlaying() }
    }

    private func trackEnded() {
        finishCurrent(scrobble: true)
        // Already playing the lined-up song (gapless)?
        let lined = prepared.flatMap { p in player.currentItem === p.item && queue.indices.contains(p.index) && queue[p.index].ratingKey == p.ratingKey ? p : nil }
        if TVSleepTimer.shared.shouldStopAtItemEnd() {
            if let lined { adopt(lined, play: false) } else { player.pause(); isPlaying = false }
            updateNowPlaying()
            return
        }
        if let lined { return adopt(lined, play: true) }
        if repeatMode == .one { return load(index) }
        if index + 1 < queue.count { load(index + 1) }
        else if repeatMode == .all { load(0) }
        else { isPlaying = false; updateNowPlaying(); saveQueue() }
    }

    /// Reports go to the connection in use right now, captured before any await, so a profile or
    /// server change can't send this account's progress to another.
    private func finishCurrent(scrobble: Bool) {
        guard let item = current, let api = session?.api else { return }
        let time = timeMs, id = sessionID, wasTranscoding = transcoding
        Task {
            if scrobble { await TVPlaybackReporting.reportFinished(item, sessionID: id, api: api, fallbackMs: time) }
            else { await TVPlaybackReporting.report(item, state: "stopped", timeMs: time, sessionID: id, api: api) }
            if wasTranscoding { await api.stopTranscode(sessionID: id) }
        }
    }

    private func report(_ state: String) {
        guard let item = current, let api = session?.api else { return }
        lastReport = Date()
        let time = timeMs, id = sessionID
        Task { await TVPlaybackReporting.report(item, state: state, timeMs: time, sessionID: id, api: api) }
    }

    private func updateNowPlaying() {
        // A video has Now Playing.
        if yielded { return }
        guard let item = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.grandparentTitle ?? "",
            MPMediaItemPropertyAlbumTitle: item.parentTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(timeMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Now Playing: artwork, the song, controls and what's next.
struct TVNowPlayingView: View {
    @Environment(TVSession.self) private var session
    private var music: TVMusicPlayer { .shared }

    var body: some View {
        if let track = music.current {
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 26) {
                    TVImage(path: track.parentThumb ?? track.thumb, width: 800, height: 800, placeholderIcon: "music.note")
                        .frame(width: 620, height: 620)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .shadow(radius: 30)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(track.title).font(.title2.bold()).lineLimit(1)
                        Text([track.grandparentTitle, track.parentTitle].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    VStack(spacing: 8) {
                        ProgressView(value: Double(music.timeMs), total: Double(max(music.durationMs, 1))).tint(TVTheme.accent)
                        HStack {
                            Text(Fmt.clock(seconds: Double(music.timeMs) / 1000))
                            Spacer()
                            Text("-" + Fmt.clock(seconds: Double(max(0, music.durationMs - music.timeMs)) / 1000))
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 40) {
                        Button { music.previous() } label: { Image(systemName: "backward.fill") }
                        Button { music.toggle() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }
                        Button { music.next() } label: { Image(systemName: "forward.fill") }.disabled(!music.hasNext)
                        Button { music.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                        Button { music.cycleRepeat() } label: {
                            Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                                .opacity(music.repeatMode == .off ? 0.45 : 1)
                        }
                        .accessibilityLabel(music.repeatMode == .off ? "Repeat off" : music.repeatMode == .all ? "Repeat all" : "Repeat one")
                        TVSleepTimerMenu()
                    }
                    .font(.title2)
                    .buttonStyle(TVActionStyle())
                    .focusSection()
                }
                .frame(width: 620)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Up Next").font(.headline).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(music.queue.enumerated()), id: \.offset) { i, t in
                                Button { music.jump(to: i) } label: {
                                    HStack(spacing: 20) {
                                        Image(systemName: i == music.index ? "speaker.wave.2.fill" : "music.note")
                                            .foregroundStyle(i == music.index ? .primary : .secondary).frame(width: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(t.title).lineLimit(1)
                                            if let artist = t.grandparentTitle { Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                        Spacer()
                                        Text(Fmt.duration(ms: t.duration) ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                // Hold a song to change the order.
                                .contextMenu {
                                    if i != music.index {
                                        Button { music.playNext(at: i) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                        Button { music.move(at: i, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                                        Button { music.move(at: i, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                                        Button(role: .destructive) { music.remove(at: i) } label: { Label("Remove from Queue", systemImage: "minus.circle") }
                                    }
                                }
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                TVImage(path: track.parentThumb ?? track.thumb, width: 400, height: 400)
                    .blur(radius: 80)
                    .overlay(TVTheme.background.opacity(0.75))
                    .ignoresSafeArea()
            }
        } else {
            VStack(spacing: 20) {
                Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary)
                Text("Nothing playing").font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}
