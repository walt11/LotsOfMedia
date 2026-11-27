import AVFoundation
import MediaPlayer
import Observation
import UIKit
import SwiftUI

/// Background-capable music player with a queue, lock-screen controls and
/// Plex progress reporting. Plays downloaded tracks from disk when available.
@MainActor
@Observable
final class AudioPlayer {
    static let shared = AudioPlayer()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let track: PlexMetadata
        let serverID: String
        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    }

    /// What's saved between launches: queue, position, shuffle (repeat has its own key).
    struct SavedSession: Codable {
        struct Item: Codable { var track: PlexMetadata; var serverID: String }
        var items: [Item]
        var index: Int
        var position: Double
        var shuffled: Bool
        /// Queue positions in their pre-shuffle order, so un-shuffling still works after a relaunch.
        var originalOrder: [Int]
        /// Matches the position checkpoint written for this queue (absent in older saves).
        var snapshotID: UUID? = nil
    }

    private(set) var queue: [Entry] = []
    private(set) var index: Int = 0
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var artwork: UIImage? { didSet { updateArtworkTint() } }
    /// The current artwork's color, for the mini player and Now Playing backdrops.
    private(set) var artworkTint: Color?
    var errorMessage: String?

    var current: Entry? { queue.indices.contains(index) ? queue[index] : nil }
    var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "music.repeat") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "music.repeat"); resetCrossfade(); prepareNext(); updateModeCommands() }
    }
    private(set) var shuffled = false { didSet { updateModeCommands() } }
    /// Playback speed (audiobooks, podcasts). Kept between launches.
    var speed: Float = UserDefaults.standard.object(forKey: "music.speed") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "music.speed")
            player.defaultRate = speed
            if player.rate != 0 { player.rate = speed }
            updateNowPlaying()
        }
    }
    static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Chapters of the current track (audiobook files), loaded for long tracks.
    private(set) var chapters: [PlexChapter] = []
    /// Tracks this long are treated like audiobook parts: they resume where they were left.
    static let resumableSeconds: Double = 20 * 60
    private var originalOrder: [UUID] = []
    var playbackPlayer: AVPlayer { player }
    var hasNext: Bool { repeatMode.nextIndex(current: index, count: queue.count, naturalEnd: false) != nil }
    /// On: the song playing stays, and the rest of the list — songs before it too, so it works
    /// from the last song — follows in a random order. Off: the list's own order comes back,
    /// continuing from the song playing.
    func toggleShuffle() {
        guard let current = queue.indices.contains(index) ? queue[index] : nil else { shuffled.toggle(); return }
        if shuffled {
            queue = Self.unshuffled(queue, originalOrder: originalOrder)
        } else {
            originalOrder = queue.map(\.id)
            queue = Self.shuffled(queue, first: index)
        }
        index = queue.firstIndex { $0.id == current.id } ?? 0
        shuffled.toggle()
        queueChanged()
    }

    /// Back to the original order (songs added while shuffled keep their place at the end).
    nonisolated static func unshuffled(_ queue: [Entry], originalOrder: [UUID]) -> [Entry] {
        let order = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($1, $0) })
        return queue.enumerated().sorted { a, b in
            (order[a.element.id] ?? Int.max, a.offset) < (order[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }

    /// A queue player so the next song is buffered and starts without a gap.
    @ObservationIgnored private let player = AVQueuePlayer()
    /// The AVPlayerItem for `current` (the queue player may already be on the next one).
    @ObservationIgnored private var loadedItem: AVPlayerItem?
    /// The next song, already queued behind the current one.
    @ObservationIgnored private var prepared: (entryID: UUID, item: AVPlayerItem, transcode: Bool, sessionID: String)?
    @ObservationIgnored private var preparedObservation: NSKeyValueObservation?
    /// Where to start once a restored session is resumed.
    @ObservationIgnored private var pendingStart: Double?
    @ObservationIgnored private var lastSave = Date.distantPast
    nonisolated static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("listening-session.json")
    }
    /// Just the place in the queue (rewritten every few seconds while playing); the queue file
    /// itself is only rewritten when the queue changes.
    nonisolated static var checkpointURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("listening-position.json")
    }
    struct Checkpoint: Codable { var index: Int; var position: Double; var count: Int; var snapshotID: UUID? = nil }

    /// A checkpoint belongs to a queue file when their snapshot IDs match (older files: same length).
    nonisolated static func checkpoint(_ c: Checkpoint, matches saved: SavedSession) -> Bool {
        if let a = c.snapshotID, let b = saved.snapshotID { return a == b }
        return c.snapshotID == nil && saved.snapshotID == nil && c.count == saved.items.count
    }
    /// Encoding and writing happen here, in order, off the main thread.
    private static let writer = DispatchQueue(label: "net.jwalter.LotsOfMedia.listeningSession", qos: .utility)
    /// What the queue file holds now, to skip rewriting an unchanged queue.
    @ObservationIgnored private var savedQueueIDs: [UUID] = []
    @ObservationIgnored private var savedShuffled = false
    @ObservationIgnored private var savedOrder: [UUID] = []
    @ObservationIgnored private var savedSnapshotID = UUID()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var usingTranscode = false
    /// Sound Check: each song's gain (dB) from the server's loudness analysis, by server and rating key.
    @ObservationIgnored private var gains: [String: Double] = [:]
    private static func gainKey(_ entry: Entry) -> String { entry.serverID + "|" + entry.track.ratingKey }
    @ObservationIgnored private var gainRequested: Set<String> = []
    /// The server conversion behind the current song, ended on the server once it's replaced.
    @ObservationIgnored private var activeTranscode: (sessionID: String, serverID: String)?
    @ObservationIgnored private var triedFallback = false
    /// The song's conversion was restarted once (the server ends one left paused a long time).
    @ObservationIgnored private var restartedConversion = false
    /// Crossfade: the next song playing early on a helper player while the volumes cross.
    @ObservationIgnored private var crossfade: (player: AVPlayer, entryID: UUID, ramp: Task<Void, Never>)?
    @ObservationIgnored private var crossfadeBoundary: Any?
    /// A freshly loaded song waiting for its Sound Check gain and fade-in before it starts, so
    /// it never plays a moment at full volume. Pausing or skipping cancels it.
    @ObservationIgnored private var startGate: Task<Void, Never>?
    /// Smooths a Sound Check change that arrives while a song is already playing.
    @ObservationIgnored private var volumeRamp: Task<Void, Never>?
    /// The queued next song failed (an idle conversion the server ended): try again near the end.
    @ObservationIgnored private var preparedFailed = false
    /// The Sound Check level last set from a known gain. A song whose gain isn't known yet plays
    /// at this, never at whatever a crossfade left the player at (the end of one is silence).
    @ObservationIgnored private var levelVolume: Float = 1
    /// A song that should be playing but hasn't moved (a stream the server stopped feeding):
    /// started when the player starts waiting, cancelled once it plays or pauses.
    @ObservationIgnored private var stallWatch: Task<Void, Never>?
    /// The current song was already reloaded once after stalling.
    @ObservationIgnored private var restartedStalled = false
    /// How long a song may wait without moving before it's reloaded.
    nonisolated static let stallSeconds: Double = 12

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = speed
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in self?.tick(t) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let ended = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let ended, ended === self.loadedItem, PlaybackFocus.owns(self.player) else { return }
                self.itemEnded()
            }
        }
        // A stream that breaks mid-song (network drop, the server ending a conversion) doesn't
        // always fail the item: the queue player just moves on without us. Treat it as a failure.
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let failed = note.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, let failed, failed === self.loadedItem, PlaybackFocus.owns(self.player) else { return }
                self.handleItemFailure(failed)
            }
        }
        rateObservation = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let playing = Self.countsAsPlaying(p.timeControlStatus)
            Task { @MainActor in
                guard let self else { return }
                if self.player.timeControlStatus == .playing {
                    PlaybackFocus.claim(self.player)
                    if self.errorMessage == Self.stalledMessage { self.errorMessage = nil }
                }
                // Paused from anywhere (sleep timer, another app, a remote): the overlap stops too.
                if self.player.timeControlStatus == .paused, self.crossfade != nil { self.cancelCrossfade() }
                if self.isPlaying != playing { self.isPlaying = playing; self.report() }
                // Now Playing's rate follows the player itself (buffering reads as stopped), so it
                // must refresh on every change — including buffering → playing, where isPlaying
                // stays true — or the lock-screen and CarPlay progress would stay frozen.
                self.updateNowPlaying()
                self.watchForStall()
            }
        }
        setupRemoteCommands()
    }

    /// The color is measured off the main thread (it reads every pixel of full-size artwork).
    private func updateArtworkTint() {
        guard let image = artwork else { artworkTint = nil; return }
        Task.detached(priority: .utility) { [weak self] in
            let color = image.averageColor
            await MainActor.run {
                guard let self, self.artwork === image else { return }
                self.artworkTint = color.map { Cinema.musicTint(from: $0, brightness: 0.36) }
            }
        }
    }

    var diagnosticsInput: DiagnosticsBuilder.Input? {
        guard let entry = current else { return nil }
        let local = DownloadManager.shared.localFileURL(serverID: entry.serverID, ratingKey: entry.track.ratingKey) != nil && !usingTranscode
        let bitrate = MediaPreferences.shared.musicBitrate
        return DiagnosticsBuilder.Input(item: entry.track, serverID: entry.serverID,
                                        mode: local ? "Downloaded" : usingTranscode ? "Converting" : "Direct Play",
                                        isDownloaded: local, isConverting: usingTranscode,
                                        transcodeSessionID: usingTranscode ? sessionID : nil,
                                        qualitySetting: bitrate == 0 ? "Original" : "\(bitrate) kbps",
                                        playerItem: loadedItem, error: errorMessage,
                                        player: crossfade != nil ? "Apple's player (crossfading)" : "Apple's player")
    }

    // MARK: Session restore

    /// Brings back the last queue, paused at the saved position. Nothing plays until the user presses play.
    func restoreSession() {
        guard queue.isEmpty, let data = try? Data(contentsOf: Self.sessionURL),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              !saved.items.isEmpty else { return }
        let entries = saved.items.map { Entry(track: $0.track, serverID: $0.serverID) }
        queue = entries
        index = min(max(0, saved.index), entries.count - 1)
        shuffled = saved.shuffled
        // Songs added while shuffled have no saved position. Keep the known order;
        // unshuffling puts the new songs after it in queue order.
        var seen = Set<Int>()
        originalOrder = saved.originalOrder.compactMap { position in
            guard entries.indices.contains(position), seen.insert(position).inserted else { return nil }
            return entries[position].id
        }
        currentTime = saved.position
        // The checkpoint is newer than the queue file when only the position moved.
        if let data = try? Data(contentsOf: Self.checkpointURL),
           let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data), Self.checkpoint(checkpoint, matches: saved) {
            index = min(max(0, checkpoint.index), entries.count - 1)
            currentTime = checkpoint.position
        }
        // A queue saved by an older version has no snapshot ID: leave it marked unsaved so the
        // next save rewrites it with one (else its new checkpoints would never match it).
        savedQueueIDs = saved.snapshotID == nil ? [] : entries.map(\.id)
        savedShuffled = shuffled; savedOrder = originalOrder
        savedSnapshotID = saved.snapshotID ?? UUID()
        duration = Double(entries[index].track.duration ?? 0) / 1000
        pendingStart = currentTime
        isPlaying = false
        loadArtwork()
    }

    /// Saves the place in the queue, and the queue itself only when it changed. Encoding and
    /// writing run on a background queue; `wait` blocks until they're done (when backgrounding).
    func saveSession(wait: Bool = false) {
        lastSave = Date()
        let work: () -> Void
        if queue.isEmpty {
            savedQueueIDs = []; savedOrder = []
            work = {
                try? FileManager.default.removeItem(at: Self.sessionURL)
                try? FileManager.default.removeItem(at: Self.checkpointURL)
            }
        } else {
            let entries = queue, idx = index, position = currentTime, shuffle = shuffled, order = originalOrder
            let ids = entries.map(\.id)
            let queueChanged = ids != savedQueueIDs || shuffle != savedShuffled || order != savedOrder
            if queueChanged { savedQueueIDs = ids; savedShuffled = shuffle; savedOrder = order; savedSnapshotID = UUID() }
            let snapshot = savedSnapshotID
            work = {
                if queueChanged {
                    let positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
                    let saved = SavedSession(items: entries.map { .init(track: $0.track.trimmedForStorage(), serverID: $0.serverID) },
                                             index: idx, position: position, shuffled: shuffle,
                                             originalOrder: order.compactMap { positions[$0] }, snapshotID: snapshot)
                    if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.sessionURL, options: .atomic) }
                }
                let checkpoint = Checkpoint(index: idx, position: position, count: entries.count, snapshotID: snapshot)
                if let data = try? JSONEncoder().encode(checkpoint) { try? data.write(to: Self.checkpointURL, options: .atomic) }
            }
        }
        // The closure only holds copies made above; it runs alone on the serial writer.
        nonisolated(unsafe) let job = work
        if wait { Self.writer.sync { job() } } else { Self.writer.async { job() } }
    }

    /// Queue edits change which song comes next: re-queue it and save.
    private func queueChanged() {
        resetCrossfade()
        prepareNext()
        saveSession()
    }

    // MARK: Controls

    /// `startAt` is the song tapped. With `shuffle` and no `startAt`, every song is shuffled,
    /// including which one plays first; with both, the tapped song plays first and the rest shuffle.
    func play(_ tracks: [PlexMetadata], serverID: String, startAt: Int? = nil, shuffle: Bool = false) {
        play(entries: tracks.filter { $0.kind == .track }.map { Entry(track: $0, serverID: serverID) }, startAt: startAt, shuffle: shuffle)
    }

    func play(downloads: [DownloadRecord], startAt: Int? = nil, shuffle: Bool = false) {
        play(entries: downloads.filter(\.isAudio).map { Entry(track: $0.metadata, serverID: $0.serverID) }, startAt: startAt, shuffle: shuffle)
    }

    /// `startAt` is a song picked from a list: with shuffle on, it stays on (that song first, the
    /// rest shuffled). Play buttons pass no `startAt` and play in order; Shuffle passes `shuffle`.
    func play(entries: [Entry], startAt: Int? = nil, shuffle requested: Bool = false) {
        guard !entries.isEmpty else { return }
        let shuffle = requested || (startAt != nil && shuffled)
        Haptics.tap()
        let list = shuffle ? Self.shuffled(entries, first: startAt) : entries
        let start = shuffle ? 0 : min(max(0, startAt ?? 0), entries.count - 1)
        stop()
        queue = list
        originalOrder = entries.map(\.id)
        shuffled = shuffle
        skip(to: start)
    }

    /// A uniformly random order; `first` (an index into `items`) stays at the front when given.
    nonisolated static func shuffled<T>(_ items: [T], first: Int?) -> [T] {
        guard let first, items.indices.contains(first) else { return items.shuffled() }
        var rest = items
        let pinned = rest.remove(at: first)
        return [pinned] + rest.shuffled()
    }

    func enqueue(_ tracks: [PlexMetadata], serverID: String) {
        let entries = tracks.filter { $0.kind == .track }.map { Entry(track: $0, serverID: serverID) }
        if queue.isEmpty { play(tracks, serverID: serverID) } else { queue += entries; queueChanged() }
    }

    var upcoming: [Entry] { Array(queue.dropFirst(index + 1)) }

    func playNext(_ track: PlexMetadata, serverID: String) {
        guard track.kind == .track else { return }
        if queue.isEmpty { play([track], serverID: serverID) }
        else { queue.insert(Entry(track: track, serverID: serverID), at: index + 1); queueChanged() }
    }

    func removeUpcoming(at offsets: IndexSet) {
        var next = upcoming
        guard offsets.allSatisfy({ next.indices.contains($0) }) else { return }
        next.remove(atOffsets: offsets)
        queue = Array(queue.prefix(index + 1)) + next
        queueChanged()
    }

    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        var next = upcoming
        guard offsets.allSatisfy({ next.indices.contains($0) }), (0...next.count).contains(destination) else { return }
        next.move(fromOffsets: offsets, toOffset: destination)
        queue = Array(queue.prefix(index + 1)) + next
        queueChanged()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        cancelCrossfade()
        startGate?.cancel(); startGate = nil
        player.pause()
        report(state: "paused")
        saveSession()
    }

    func resume() {
        PlaybackFocus.claim(player)
        guard loadedItem != nil else {
            // Restored session (or a finished queue): load the song, at the saved spot if any.
            if !queue.isEmpty { let start = pendingStart ?? 0; pendingStart = nil; skip(to: index, startAt: start) }
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        if let item = loadedItem, needsGate(for: current) { return startWhenReady(item) }
        player.play()
    }

    func next() { if let next = repeatMode.nextIndex(current: index, count: queue.count, naturalEnd: false) { skip(to: next) } }

    func previous() {
        if currentTime > 3 || index == 0 { seek(to: 0) } else { skip(to: index - 1) }
    }

    func seek(to seconds: Double) {
        if loadedItem == nil, !queue.isEmpty { pendingStart = seconds; currentTime = seconds; return }
        cancelCrossfade()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self, let item = self.loadedItem, item.status == .readyToPlay else { return }
                self.scheduleCrossfade(for: item)
            }
        }
        currentTime = seconds
        updateNowPlaying()
    }

    func stop() {
        if PlaybackSleepTimer.shared.isSet(for: player) { PlaybackSleepTimer.shared.cancel() }
        report(state: "stopped")
        cancelCrossfade()
        player.pause()
        clearPlayerItems()
        endTranscode(activeTranscode)
        activeTranscode = nil
        queue = []
        index = 0
        isPlaying = false
        pendingStart = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        saveSession()
    }

    // MARK: Crossfade

    /// Sets a time just before the current song ends to start the overlap.
    private func scheduleCrossfade(for item: AVPlayerItem) {
        if let crossfadeBoundary { player.removeTimeObserver(crossfadeBoundary); self.crossfadeBoundary = nil }
        let seconds = Double(MediaPreferences.shared.musicCrossfadeSeconds)
        guard item === loadedItem, let at = Self.crossfadeStart(length: item.duration.seconds, fadeSeconds: seconds,
                                                                  playhead: player.currentTime().seconds) else { return }
        let start = CMTime(seconds: at, preferredTimescale: 600)
        crossfadeBoundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: start)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.startCrossfade(seconds: seconds) }
        }
    }

    /// When the overlap starts, or nil: crossfade off, a song too short for one, or a playhead
    /// already past that point (after a seek near the end), where a boundary would never fire
    /// and the next song would start early on top of this one.
    nonisolated static func crossfadeStart(length: Double, fadeSeconds: Double, playhead: Double) -> Double? {
        guard fadeSeconds > 0, length.isFinite, length > fadeSeconds * 3 else { return nil }
        let start = length - fadeSeconds
        return playhead < start ? start : nil
    }

    /// Starts the next song on a helper player and crosses the volumes over `seconds`. Only for
    /// a next song that is a file (direct or downloaded): conversions can't be joined mid-song.
    private func startCrossfade(seconds: Double) {
        guard crossfade == nil, isPlaying, repeatMode != .one, !PlaybackSleepTimer.shared.endsWithItem(for: player),
              let p = prepared, !p.transcode, let entry = queue.first(where: { $0.id == p.entryID }),
              let src = source(for: entry, forceTranscode: false), !src.transcode else { return }
        let helper = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: src.url)))
        helper.volume = 0
        helper.automaticallyWaitsToMinimizeStalling = true
        helper.play()
        let outgoing = player.volume
        let incoming: Float = MediaPreferences.shared.musicSoundCheck
            ? ((gains[Self.gainKey(entry)] ?? Self.gain(of: entry.track)).map { Float(min(1, pow(10, $0 / 20))) } ?? 1) : 1
        let ramp = Task { @MainActor [weak self] in
            // The old song keeps its volume until the new one is actually playing. If it isn't
            // within half the fade (slow network) or it fails, the overlap is dropped and the
            // usual gapless change happens instead of a fade into silence.
            var waited = 0
            while helper.timeControlStatus != .playing {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 1
                guard !Task.isCancelled, let self, self.crossfade?.player === helper else { return }
                if helper.currentItem?.status == .failed || Double(waited) * 0.05 > seconds / 2 { return self.cancelCrossfade() }
            }
            let steps = max(1, Int((seconds - Double(waited) * 0.05) * 20))
            var step = 0
            while step < steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, self.crossfade?.player === helper,
                      self.player.timeControlStatus != .paused else { return }
                if helper.currentItem?.status == .failed { return self.cancelCrossfade() }
                // Hold the mix while the new song rebuffers.
                guard helper.timeControlStatus == .playing else { continue }
                step += 1
                let f = Float(step) / Float(steps)
                // Equal-power curves keep the loudness steady through the middle.
                self.player.volume = outgoing * cos(f * .pi / 2)
                helper.volume = incoming * sin(f * .pi / 2)
            }
        }
        crossfade = (helper, p.entryID, ramp)
    }

    /// The old song ended and the main player moved to the next one: line it up with the helper
    /// (which has been playing it), then let the helper go.
    private func handOffCrossfade(to entryID: UUID) {
        guard let fade = crossfade else { return }
        guard fade.entryID == entryID else { return cancelCrossfade() }
        fade.ramp.cancel()
        let target = player.volume
        player.volume = 0
        let at = fade.player.currentTime()
        player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.crossfade?.player === fade.player else { return }
                self.player.volume = target
                fade.player.pause()
                self.crossfade = nil
            }
        }
    }

    /// The song or what follows it changed: drop any overlap and set the start point again.
    private func resetCrossfade() {
        cancelCrossfade()
        if let item = loadedItem, item.status == .readyToPlay { scheduleCrossfade(for: item) }
    }

    /// Skipping, pausing or stopping during an overlap: the helper stops and volume returns.
    private func cancelCrossfade() {
        if let crossfadeBoundary { player.removeTimeObserver(crossfadeBoundary); self.crossfadeBoundary = nil }
        guard let fade = crossfade else { return }
        fade.ramp.cancel()
        fade.player.pause()
        crossfade = nil
        applySoundCheck()
    }

    // MARK: Sound Check

    /// Sets the volume for the current song from its loudness gain (Sound Check on), else full.
    /// AVPlayer can only turn down, so loud songs are lowered and quiet ones play at full volume.
    private func applySoundCheck(smoothly: Bool = false) {
        volumeRamp?.cancel(); volumeRamp = nil
        guard MediaPreferences.shared.musicSoundCheck, let entry = current else { levelVolume = 1; player.volume = 1; return }
        guard let target = soundCheckVolume(for: entry) else {
            // Unknown yet: the last song's level (songs are usually turned down, so jumping to
            // full would blast) until the gain arrives. Its level, not the player's volume: after
            // a crossfade that is zero, and every song after would stay silent.
            player.volume = levelVolume
            fetchGain(for: entry)
            return
        }
        levelVolume = target
        guard smoothly, player.timeControlStatus == .playing, abs(player.volume - target) > 0.01 else { player.volume = target; return }
        let from = player.volume
        volumeRamp = Task { @MainActor [weak self] in
            for step in 1...8 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                self.player.volume = from + (target - from) * Float(step) / 8
            }
        }
    }

    private func soundCheckVolume(for entry: Entry) -> Float? {
        (gains[Self.gainKey(entry)] ?? Self.gain(of: entry.track)).map { Float(min(1, pow(10, $0 / 20))) }
    }

    /// Whether a song should wait for its gain before starting.
    private func needsGate(for entry: Entry?) -> Bool {
        guard let entry, MediaPreferences.shared.musicSoundCheck else { return false }
        return soundCheckVolume(for: entry) == nil
    }

    /// Starts a freshly loaded song once its gain is known and its fade-in is attached (each
    /// waited on for at most a moment), so the first second isn't louder than the rest.
    private func startWhenReady(_ item: AVPlayerItem, fades: Task<Void, Never>? = nil) {
        startGate?.cancel()
        let entryID = current?.id
        let attached = Done(fades == nil)
        if let fades { Task { @MainActor in await fades.value; attached.value = true } }
        startGate = Task { @MainActor [weak self] in
            // The fade-in needs the file's header from the server, which a slow or stalled
            // connection can hold up indefinitely: past the deadline the song starts anyway.
            let deadline = Date().addingTimeInterval(1.5)
            while let self, !Task.isCancelled, !attached.value || self.needsGate(for: self.current), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, !Task.isCancelled, self.loadedItem === item, self.current?.id == entryID else { return }
            self.startGate = nil
            self.applySoundCheck()
            self.player.play()
        }
    }

    @MainActor private final class Done {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// Looks up a song's gain (the song's full details carry it), ahead of time for the next song.
    private func fetchGain(for entry: Entry) {
        let key = Self.gainKey(entry), ratingKey = entry.track.ratingKey, entryID = entry.id
        if let g = Self.gain(of: entry.track) { gains[key] = g; return }
        guard MediaPreferences.shared.musicSoundCheck, !gainRequested.contains(key),
              let api = ServerDirectory.shared.api(for: entry.serverID) else { return }
        gainRequested.insert(key)
        Task {
            guard let full = try? await api.metadata(ratingKey) else {
                gainRequested.remove(key)   // try again later (offline, server busy)
                return
            }
            guard let g = Self.gain(of: full) else { return }
            gains[key] = g
            if current?.id == entryID, startGate == nil { applySoundCheck(smoothly: true) }
        }
    }

    nonisolated static func gain(of track: PlexMetadata) -> Double? {
        track.media.first?.parts.first?.streams.first { $0.streamType == 2 }?.gain
    }

    /// Tells the server a conversion is no longer needed, so it stops working on it.
    private func endTranscode(_ t: (sessionID: String, serverID: String)?) {
        guard let t, let api = ServerDirectory.shared.api(for: t.serverID) else { return }
        Task { await api.stopTranscode(sessionID: t.sessionID) }
    }

    /// The queued next song's conversion, when it's dropped before playing.
    private func endPreparedTranscode() {
        guard let p = prepared, p.transcode, let entry = queue.first(where: { $0.id == p.entryID }) else { return }
        endTranscode((p.sessionID, entry.serverID))
    }

    private func clearPlayerItems() {
        endPreparedTranscode()
        player.removeAllItems()
        loadedItem = nil
        prepared = nil
        preparedObservation = nil
    }

    func skip(to newIndex: Int, startAt: Double = 0) {
        guard queue.indices.contains(newIndex) else { return }
        cancelCrossfade()
        startGate?.cancel(); startGate = nil
        stallWatch?.cancel(); stallWatch = nil
        restartedStalled = false
        if PlaybackSleepTimer.shared.endsWithItem(for: player) { PlaybackSleepTimer.shared.cancel() }
        PlaybackFocus.claim(player)
        if loadedItem != nil { report(state: "stopped") }
        statusObservation = nil
        player.pause()
        clearPlayerItems()
        isPlaying = false
        errorMessage = nil
        index = newIndex
        duration = Double(queue[newIndex].track.duration ?? 0) / 1000
        // A long track (an audiobook part) picks up where it was left, like a video.
        var startAt = startAt
        if startAt == 0, duration >= Self.resumableSeconds, let offset = queue[newIndex].track.viewOffset,
           Double(offset) / 1000 < duration - 30 {
            startAt = Double(offset) / 1000
        }
        currentTime = startAt
        pendingStart = nil
        chapters = []
        if duration >= Self.resumableSeconds { loadChapters(for: queue[newIndex]) }
        artwork = nil
        triedFallback = false
        restartedConversion = false
        load(useTranscode: false, startAt: startAt)
        loadArtwork()
        saveSession()
    }

    /// The current song finished. If the next one was queued it is already
    /// playing (gapless); otherwise load it the normal way.
    private func itemEnded() {
        report(state: "stopped")
        let next = repeatMode.nextIndex(current: index, count: queue.count, naturalEnd: true)
        let advanced = prepared.flatMap { p in next.flatMap { queue.indices.contains($0) && queue[$0].id == p.entryID ? p : nil } }
        if PlaybackSleepTimer.shared.consumeEnd(for: player) {
            if let advanced, let next { adopt(advanced, at: next) }
            player.pause()
            isPlaying = false
            saveSession()
            return
        }
        if let advanced, let next {
            adopt(advanced, at: next)
        } else if let next {
            skip(to: next)
        } else {
            isPlaying = false
            clearPlayerItems()
            index = queue.count - 1
            currentTime = 0
            pendingStart = 0
            saveSession()
        }
    }

    /// Makes the already-queued item the current song.
    private func adopt(_ p: (entryID: UUID, item: AVPlayerItem, transcode: Bool, sessionID: String), at newIndex: Int) {
        loadedItem = p.item
        prepared = nil
        preparedObservation = nil
        preparedFailed = false
        index = newIndex
        usingTranscode = p.transcode
        sessionID = p.sessionID
        let previous = activeTranscode
        activeTranscode = p.transcode ? (p.sessionID, queue[newIndex].serverID) : nil
        if previous?.sessionID != activeTranscode?.sessionID { endTranscode(previous) }
        applySoundCheck()
        handOffCrossfade(to: queue[newIndex].id)
        scheduleCrossfade(for: p.item)
        triedFallback = false
        restartedConversion = false
        restartedStalled = false
        errorMessage = nil
        currentTime = 0
        duration = Double(queue[newIndex].track.duration ?? 0) / 1000
        artwork = nil
        observeStatus(p.item)
        // The player may already be waiting on this song (it moved on before we heard).
        stallWatch?.cancel(); stallWatch = nil
        watchForStall()
        if p.item.status == .failed { handleItemFailure(p.item) }
        loadArtwork()
        updateNowPlaying()
        prepareNext()
        saveSession()
    }

    // MARK: Loading

    /// How a queue entry will be played: a downloaded file, the original file, or a conversion.
    private struct Source { var url: URL; var transcode: Bool; var sessionID: String }

    private func source(for entry: Entry, forceTranscode: Bool) -> Source? {
        let track = entry.track
        if !forceTranscode, let local = DownloadManager.shared.localFileURL(serverID: entry.serverID, ratingKey: track.ratingKey) {
            return Source(url: local, transcode: false, sessionID: sessionID)
        }
        guard let api = ServerDirectory.shared.api(for: entry.serverID), MediaPreferences.shared.streamAllowed(.music) else { return nil }
        let native = track.primaryMedia.map { PlaybackDecider.canPlayNatively(media: $0, kind: .track) } ?? false
        if native && !forceTranscode && MediaPreferences.shared.musicBitrate == 0, let url = PlaybackDecider.directURL(api: api, item: track) {
            return Source(url: url, transcode: false, sessionID: sessionID)
        }
        let sid = UUID().uuidString
        return Source(url: PlaybackDecider.transcodeURL(api: api, item: track, quality: .original, sessionID: sid, isLocal: true,
                                                        music: true, musicBitrate: MediaPreferences.shared.musicBitrate),
                      transcode: true, sessionID: sid)
    }

    private func makeItem(_ source: Source, forwardBuffer: Double = 20) -> (item: AVPlayerItem, fades: Task<Void, Never>?) {
        let item = AVPlayerItem(asset: AVURLAsset(url: source.url, options: [AVURLAssetAllowsCellularAccessKey: MediaPreferences.shared.allowsCellular(.music)]))
        item.preferredForwardBufferDuration = forwardBuffer
        let fades = SongFades.apply(seconds: MediaPreferences.shared.musicFadeSeconds, to: item)
        return (item, fades)
    }

    private func load(useTranscode: Bool, startAt: Double = 0) {
        guard let entry = current else { return }
        guard let src = source(for: entry, forceTranscode: useTranscode) else {
            errorMessage = DownloadManager.shared.localFileURL(serverID: entry.serverID, ratingKey: entry.track.ratingKey) == nil
                && !MediaPreferences.shared.streamAllowed(.music) && NetworkMonitor.shared.isConnected
                ? "Music streaming over cellular is disabled in Playback Preferences." : "This track isn't available offline."
            updateNowPlaying()
            return
        }
        usingTranscode = src.transcode
        sessionID = src.sessionID
        let previous = activeTranscode
        activeTranscode = src.transcode ? (src.sessionID, entry.serverID) : nil
        if previous?.sessionID != activeTranscode?.sessionID { endTranscode(previous) }
        applySoundCheck()
        try? AVAudioSession.sharedInstance().setActive(true)
        let (item, fades) = makeItem(src)
        observeStatus(item, startAt: startAt)
        clearPlayerItems()
        loadedItem = item
        preparedFailed = false
        player.insert(item, after: nil)
        // Play straight away when nothing needs waiting for; otherwise once the gain and
        // fade-in are in place (AVPlayer is still buffering then anyway).
        if fades == nil && !needsGate(for: entry) { player.play() } else { startWhenReady(item, fades: fades) }
        updateNowPlaying()
        prepareNext()
        stallWatch?.cancel(); stallWatch = nil
        watchForStall()
    }

    /// While the player waits on the current song, checks back after `stallSeconds`: if it
    /// still hasn't moved, the stream is stuck (most often at the very start of a song, when
    /// the queued request or conversion went stale), and the song is reloaded from that spot.
    private func watchForStall() {
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, player.reasonForWaitingToPlay != .noItemToPlay,
              let item = loadedItem, player.currentItem === item else {
            stallWatch?.cancel(); stallWatch = nil
            return
        }
        guard stallWatch == nil else { return }
        let from = player.currentTime().seconds
        stallWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallSeconds))
            guard !Task.isCancelled, let self else { return }
            self.stallWatch = nil
            guard self.loadedItem === item, self.player.currentItem === item,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  Self.isStuck(from: from, now: self.player.currentTime().seconds) else { return }
            self.recoverFromStall()
        }
    }

    nonisolated static let stalledMessage = "This song stopped loading. Check the connection to your server, or skip to another song."

    /// The playhead hasn't moved meaningfully while waiting.
    nonisolated static func isStuck(from: Double, now: Double) -> Bool {
        guard from.isFinite, now.isFinite else { return true }
        return now < from + 0.5
    }

    private func recoverFromStall() {
        cancelCrossfade()
        if !restartedStalled {
            restartedStalled = true
            // A fresh request (and a new conversion when converting), like a failed song gets.
            load(useTranscode: usingTranscode, startAt: currentTime)
            return
        }
        // Stuck again: say so rather than sit silent. Skipping still works, and the player
        // carries on by itself if the stream comes back.
        errorMessage = Self.stalledMessage
        updateNowPlaying()
    }

    /// `startAt`: resume point (restored session, transcode fallback), applied once the item is ready.
    private func observeStatus(_ item: AVPlayerItem, startAt: Double = 0) {
        var pendingSeek = startAt > 1 ? startAt : nil
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self, self.loadedItem === item else { return }
                if status == .readyToPlay, let seconds = pendingSeek {
                    pendingSeek = nil
                    await item.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                    self.currentTime = seconds
                    self.updateNowPlaying()
                }
                if status == .readyToPlay { self.scheduleCrossfade(for: item) }
                if status == .failed, PlaybackFocus.owns(self.player) { self.handleItemFailure(item) }
            }
        }
    }

    private func handleItemFailure(_ item: AVPlayerItem) {
        // Resuming a song paused for a long while: the server ended its conversion. Start a new
        // one where it was, once, instead of skipping to the next song with an error.
        if usingTranscode && !restartedConversion {
            restartedConversion = true
            load(useTranscode: true, startAt: currentTime)
            return
        }
        if !usingTranscode && !triedFallback {
            triedFallback = true
            load(useTranscode: true, startAt: currentTime)
        } else {
            errorMessage = item.error?.localizedDescription ?? "Couldn't play this track."
            if hasNext { skip(to: index + 1) }
        }
    }

    /// Buffers the song that plays next and queues it behind the current one,
    /// so the change is gapless. Re-run whenever the queue or repeat mode changes.
    private func prepareNext() {
        if let p = prepared { endPreparedTranscode(); player.remove(p.item); prepared = nil; preparedObservation = nil }
        guard let current = loadedItem, player.items().contains(where: { $0 === current }),
              !PlaybackSleepTimer.shared.endsWithItem(for: player),
              let next = repeatMode.nextIndex(current: index, count: queue.count, naturalEnd: true),
              next != index, let src = source(for: queue[next], forceTranscode: false) else { return }
        // A minute buffered ahead, so the change is instant even on a patchy connection.
        let item = makeItem(src, forwardBuffer: 60).item
        let entryID = queue[next].id
        prefetchAhead(from: next)
        prepared = (entryID, item, src.transcode, src.sessionID)
        player.insert(item, after: current)
        // A queued song that fails is dropped, so the end of the current one falls back to a normal load.
        preparedObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, let p = self.prepared, p.item === item else { return }
                self.player.remove(item)
                self.prepared = nil
                self.preparedFailed = true
            }
        }
    }

    /// Gains (Sound Check) and artwork for the next few songs, so a change or a skip
    /// starts at the right volume with its picture already there.
    private func prefetchAhead(from start: Int) {
        let upcoming = (0..<3).map { start + $0 }.filter { queue.indices.contains($0) }
        for i in upcoming { fetchGain(for: queue[i]) }
        if index > 0, queue.indices.contains(index - 1) { fetchGain(for: queue[index - 1]) }
        guard let i = upcoming.first, let api = ServerDirectory.shared.api(for: queue[i].serverID),
              DownloadManager.shared.record(serverID: queue[i].serverID, ratingKey: queue[i].track.ratingKey) == nil,
              let url = api.imageURL(queue[i].track.posterThumb, width: 600, height: 600) else { return }
        Task { _ = await ImageLoader.shared.image(for: url) }
    }

    private func loadArtwork() {
        guard let entry = current else { return }
        let rec = DownloadManager.shared.record(serverID: entry.serverID, ratingKey: entry.track.ratingKey)
        if let rec, let img = UIImage(contentsOfFile: DownloadStore.posterURL(id: rec.id).path) {
            artwork = img
            updateNowPlaying()
            return
        }
        guard let api = ServerDirectory.shared.api(for: entry.serverID),
              let url = api.imageURL(entry.track.posterThumb, width: 600, height: 600) else { return }
        let expected = entry.id
        Task {
            let image = await ImageLoader.shared.image(for: url)
            guard current?.id == expected else { return }
            artwork = image
            updateNowPlaying()
        }
    }

    // MARK: Reporting

    private func tick(_ t: CMTime) {
        // Right after a gapless change the queue player is already on the next song;
        // only trust timing from the song this player considers current.
        guard loadedItem != nil, player.currentItem === loadedItem else { return }
        let s = t.seconds
        if s.isFinite { currentTime = s }
        if let d = loadedItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        // The queued song failed earlier (often a conversion that sat idle too long): queue it
        // again shortly before the end so the change is still seamless.
        if preparedFailed, prepared == nil, isPlaying, duration - currentTime < 45 { preparedFailed = false; prepareNext() }
        if isPlaying, Date().timeIntervalSince(lastReport) > 10 { report() }
        if isPlaying, Date().timeIntervalSince(lastSave) > 15 { saveSession() }
    }

    private func report(state explicit: String? = nil) {
        guard let entry = current else { return }
        lastReport = Date()
        let state = explicit ?? (isPlaying ? "playing" : "paused")
        let pos = Int(currentTime * 1000)
        let dur = entry.track.duration ?? Int(duration * 1000)
        let sid = sessionID
        guard let api = ServerDirectory.shared.api(for: entry.serverID) else { return }
        let track = entry.track
        Task.detached {
            try? await api.timeline(ratingKey: track.ratingKey, key: track.key, state: state, timeMs: pos, durationMs: dur, sessionID: sid)
        }
    }

    // MARK: Now Playing / remote commands

    private func updateNowPlaying() {
        guard let entry = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.track.title,
            MPMediaItemPropertyArtist: entry.track.grandparentTitle ?? entry.track.originalTitle ?? "",
            MPMediaItemPropertyAlbumTitle: entry.track.parentTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: Self.nowPlayingRate(player.timeControlStatus, speed: speed),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Buffering after a seek still counts as playing, so play/pause doesn't flicker…
    nonisolated static func countsAsPlaying(_ status: AVPlayer.TimeControlStatus) -> Bool { status != .paused }
    /// …but the scrubber only moves once sound is actually coming out.
    nonisolated static func nowPlayingRate(_ status: AVPlayer.TimeControlStatus, speed: Float = 1) -> Double { status == .playing ? Double(speed) : 0 }

    /// Chapter marks for a long track, from the server (they aren't in list responses).
    private func loadChapters(for entry: Entry) {
        let expected = entry.id
        if !entry.track.chapters.isEmpty { chapters = entry.track.chapters; return }
        guard let api = ServerDirectory.shared.api(for: entry.serverID) else { return }
        Task {
            guard let fresh = try? await api.metadata(entry.track.ratingKey), current?.id == expected else { return }
            chapters = fresh.chapters
        }
    }

    /// The chapter playing now.
    var currentChapter: PlexChapter? { chapters.last { Double($0.startTimeOffset) / 1000 <= currentTime } }

    /// Lets CarPlay and Control Center show the current shuffle and repeat state.
    private func updateModeCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.changeShuffleModeCommand.currentShuffleType = shuffled ? .items : .off
        c.changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : repeatMode == .all ? .all : .off
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        // While the built-in video player has focus, these control it instead of music.
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in
            if let v = PlaybackFocus.external { v.remotePlay() } else { self?.resume() } }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in
            if let v = PlaybackFocus.external { v.remotePause() } else { self?.pause() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in
            if let v = PlaybackFocus.external { v.remoteToggle() } else { self?.toggle() } }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in
            if let v = PlaybackFocus.external { v.remoteSkip(seconds: 10) } else { self?.next() } }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in
            if let v = PlaybackFocus.external { v.remoteSkip(seconds: -10) } else { self?.previous() } }; return .success }
        // Shuffle / repeat from CarPlay's Now Playing buttons and other system controls.
        c.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self else { return }
                if (e.shuffleType != .off) != self.shuffled { self.toggleShuffle() }
            }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.repeatMode = e.repeatType == .one ? .one : e.repeatType == .all ? .all : .off }
            return .success
        }
        updateModeCommands()
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                if let v = PlaybackFocus.external { v.remoteSeek(toSeconds: e.positionTime) } else { self?.seek(to: e.positionTime) }
            }
            return .success
        }
    }
}


@MainActor
enum PlaybackFocus {
    private static weak var current: AVPlayer?
    /// The built-in (VLC) player while it has focus; lock-screen controls go to it.
    private(set) static weak var external: (any ExternalPlaybackControls)?

    static func claim(_ player: AVPlayer) {
        if let external { external.remotePause(); self.external = nil }
        if current !== player { current?.pause(); current = player }
    }
    static func owns(_ player: AVPlayer) -> Bool { current === player }

    static func claimExternal(_ controls: any ExternalPlaybackControls) {
        current?.pause()
        current = nil
        external = controls
    }
    static func releaseExternal(_ controls: any ExternalPlaybackControls) {
        if external === controls { external = nil }
    }
}


/// Crossfade lengths offered in Playback Preferences.
enum Crossfade {
    static let choices = [0, 4, 8, 12]
}

/// Short volume fades at the start and end of each song (Settings → Playback).
/// These are fades, not an overlapping crossfade: AVQueuePlayer plays one item at a time.
enum SongFades {
    static let choices = [0, 2, 4, 6]

    /// The returned task finishes once the fades are attached (or skipped), so a song can wait
    /// for its fade-in instead of starting loud and dropping when the mix arrives.
    @MainActor @discardableResult
    static func apply(seconds: Int, to item: AVPlayerItem) -> Task<Void, Never>? {
        // Crossfade does its own volume work.
        guard seconds > 0, MediaPreferences.shared.musicCrossfadeSeconds == 0 else { return nil }
        let asset = item.asset
        // Built and attached on the main actor, so the mix never crosses threads.
        return Task { @MainActor in
            // Streams converted to HLS expose no audio tracks; they simply play without fades.
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
                  let duration = try? await asset.load(.duration), duration.seconds.isFinite,
                  duration.seconds > Double(seconds) * 3 else { return }
            let fade = CMTime(seconds: Double(seconds), preferredTimescale: 600)
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fade))
            params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: duration - fade, duration: fade))
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }
}
