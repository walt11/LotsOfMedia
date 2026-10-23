import Foundation
import Observation
import UIKit
import BackgroundTasks

/// Offline download engine.
///
/// Robustness strategy:
/// * Every download runs on a *background* URLSession, so transfers continue
///   while the app is suspended or terminated, and the system relaunches the
///   app to deliver results.
/// * Files are fetched as independent byte-range segments (HTTP Range). Each
///   finished segment is moved to disk immediately, so a network drop, app
///   kill or reboot can only lose the part of a segment that was in flight.
///   Servers without range support fall back to a single stream that is
///   resumed with URLSession resume data.
/// * State is persisted to disk after every transition and reconciled with the
///   session's live tasks on launch.
/// * Network errors are retried indefinitely with backoff; retries fire
///   immediately when connectivity returns. Host-level errors re-resolve the
///   server address (e.g. moving from home Wi-Fi to cellular switches from the
///   LAN address to the remote one) and only affected segments restart.
/// * Assembly into the final file is crash-safe and verified against the
///   expected size.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let sessionIdentifier = "net.jwalter.LotsOfMedia.downloads"
    static let refreshTaskIdentifier = "net.jwalter.LotsOfMedia.downloads.refresh"
    static let chargingTaskIdentifier = "net.jwalter.LotsOfMedia.downloads.charging"
    nonisolated static let probePrefix = "probe|"

    private(set) var records: [DownloadRecord] = [] { didSet { recordsChanged() } }
    /// Download state by record ID. Kept separate from `records` so badges and
    /// buttons only re-render when a state actually changes, not on every
    /// segment completion.
    private(set) var states: [String: DownloadRecord.State] = [:]

    /// A download finishing or failing, for in-app banners.
    struct Event: Identifiable, Equatable, Sendable {
        let id = UUID()
        let recordID: String
        let title: String
        let succeeded: Bool
        let message: String?
        /// "Ready to listen offline" vs "Ready to watch offline".
        var isAudio: Bool = false
    }

    /// Downloaded playlists.
    private(set) var collections: [DownloadCollection] = []

    /// Most items converting or transferring at once; the rest wait their turn.
    static let maxSimultaneousDownloads = 3
    var actionError: String?
    private(set) var lastEvent: Event?
    /// Bytes on disk or in flight per record, refreshed twice a second.
    private(set) var liveBytes: [String: Int64] = [:]

    var allowCellular: Bool = UserDefaults.standard.object(forKey: "downloads.allowCellular") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(allowCellular, forKey: "downloads.allowCellular")
            restartAllTasks()
        }
    }

    /// Only transfer while the device is charging.
    var chargingOnly: Bool = UserDefaults.standard.bool(forKey: "downloads.chargingOnly") {
        didSet {
            UserDefaults.standard.set(chargingOnly, forKey: "downloads.chargingOnly")
            powerPolicyChanged()
        }
    }

    /// Storage limit for downloads in GB; 0 = no limit.
    var storageCapGB: Int = UserDefaults.standard.integer(forKey: "downloads.storageCapGB") {
        didSet {
            UserDefaults.standard.set(storageCapGB, forKey: "downloads.storageCapGB")
            resumeWaitingForSpace()
        }
    }

    /// When the limit is reached, remove fully watched downloads (oldest first) to make room.
    var freeSpaceWithWatched: Bool = UserDefaults.standard.object(forKey: "downloads.freeWatched") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(freeSpaceWithWatched, forKey: "downloads.freeWatched")
            resumeWaitingForSpace()
        }
    }

    /// Plugged in (or a simulator / unknown state, which counts as powered).
    private(set) var isOnPower = true
    /// False while "only while charging" is on and the device is on battery.
    var transfersAllowed: Bool { !chargingOnly || isOnPower }

    var defaultQuality: DownloadQuality = DownloadQuality(rawValue: UserDefaults.standard.string(forKey: "downloads.quality") ?? "") ?? .original {
        didSet { UserDefaults.standard.set(defaultQuality.rawValue, forKey: "downloads.quality") }
    }

    /// Quality for downloads started on cellular (nil: the same as on Wi-Fi). Smaller copies save data.
    var cellularQuality: DownloadQuality? = UserDefaults.standard.string(forKey: "downloads.cellularQuality").flatMap(DownloadQuality.init(rawValue:)) {
        didSet { UserDefaults.standard.set(cellularQuality?.rawValue, forKey: "downloads.cellularQuality") }
    }

    /// Days after which watched videos are removed automatically; 0 = keep them.
    var removeWatchedAfterDays: Int = UserDefaults.standard.integer(forKey: "downloads.removeWatchedAfterDays") {
        didSet {
            UserDefaults.standard.set(removeWatchedAfterDays, forKey: "downloads.removeWatchedAfterDays")
            removeExpiredWatched()
        }
    }

    /// The quality a new download gets when none was picked for it.
    private var qualityForNewDownloads: DownloadQuality {
        if let cellularQuality, NetworkMonitor.shared.isExpensive, !NetworkMonitor.shared.usesWiFi { return cellularQuality }
        return defaultQuality
    }

    /// Removes videos watched more than `removeWatchedAfterDays` ago (by the active profile).
    /// Songs, playlist items and progress not yet synced are kept.
    func removeExpiredWatched(now: Date = Date()) {
        guard removeWatchedAfterDays > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(removeWatchedAfterDays) * 86_400)
        let inPlaylists = Set(collections.flatMap(\.itemIDs))
        let expired = records.filter { r in
            guard r.state == .completed, !r.isAudio, !r.hasPendingProgress, isFullyWatched(r), !inPlaylists.contains(r.id) else { return false }
            let watchedAt = r.metadata.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? r.completedAt ?? now
            return watchedAt < cutoff
        }
        deleteMany(expired.map(\.id))
    }

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    /// Current Plex Home user; offline progress is attributed to them.
    var activeUserID: String? = UserDefaults.standard.string(forKey: "currentUserUUID") {
        didSet {
            guard oldValue != activeUserID else { return }
            let user = activeUserID
            updateRecords { all in for i in all.indices { Self.projectProgress(&all[i], userID: user, clearUnknown: true) } }
            saveNow()
        }
    }

    @ObservationIgnored private var syncingProgress = false
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private var tasks: [String: [Int: URLSessionDownloadTask]] = [:]
    @ObservationIgnored private var retryAt: [String: Date] = [:]
    @ObservationIgnored private var preparing: Set<String> = []
    @ObservationIgnored private var assembling: Set<String> = []
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var reconciled = false
    @ObservationIgnored private var started = false
    /// False when the saved index existed but couldn't be read; saving then would erase it.
    @ObservationIgnored private var indexReadable = true
    /// Failed assembly attempts by record, so a persistent failure backs off instead of looping.
    @ObservationIgnored private var assemblyFailures: [String: Int] = [:]
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    /// Record positions by "server|parent" and "server|grandparent", so season/album and
    /// show/artist tiles find their downloads without scanning every record.
    @ObservationIgnored private var indexByParent: [String: [Int]] = [:]
    @ObservationIgnored private var indexByGrandparent: [String: [Int]] = [:]
    @ObservationIgnored private var hasActiveWork = false
    /// Observable flag for UI that only cares whether anything is in progress.
    private(set) var hasActiveDownloads = false
    @ObservationIgnored private var bulkUpdate = false
    /// Last observed byte count per live task, for stall detection.
    @ObservationIgnored private var activity: [Int: (bytes: Int64, at: Date)] = [:]
    @ObservationIgnored private var lastWatchdog = Date.distantPast
    /// A task that received data and then nothing for this long is restarted.
    @ObservationIgnored let stallTimeout: TimeInterval = 20

    /// Upper bound on tasks handed to the background session at once while
    /// we're in the foreground (where we can top the queue up continuously).
    @ObservationIgnored let maxOutstandingTasks = 64
    /// Before suspension we queue (nearly) everything: iOS only wakes the app
    /// when *all* tasks finish, and tasks created while in the background are
    /// treated as discretionary and can be delayed for a long time.
    @ObservationIgnored let backgroundOutstandingTasks = 1024
    @ObservationIgnored private var queueEverything = false
    /// Scheduled background checks for server conversions, by record ID.
    @ObservationIgnored private var probeTasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var conversionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var taskWindow: Int { queueEverything ? backgroundOutstandingTasks : maxOutstandingTasks }
    @ObservationIgnored let maxFailures = 12

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let saved = DownloadStore.load()
        // Migrated and projected before it's published: one index rebuild instead of one per record.
        var loaded = saved.records
        for i in loaded.indices {
            loaded[i].migrateProgress()
            Self.projectProgress(&loaded[i], userID: activeUserID, clearUnknown: false)
        }
        records = loaded
        indexReadable = saved.readable
        loadCollections()
        adoptFinishedSegmentsOnDisk()
        // Only with a trustworthy index, so an unreadable one never costs anyone their downloads.
        if indexReadable {
            let ids = Set(records.map(\.id))
            Task.detached(priority: .background) { DownloadStore.removeOrphans(keeping: ids) }
        }

        delegate.onComplete = { [weak self] tag, taskID, result in
            Task { @MainActor in self?.handleCompletion(tag: tag, taskID: taskID, result: result) }
        }
        delegate.onProbeFinished = { [weak self] id in
            Task { @MainActor in self?.probeFinished(id) }
        }
        delegate.onEventsFinished = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pump()
                self.saveNow()
                // Woken in the background: push fresh numbers to the Live Activity.
                self.publishProgress()
                DownloadActivityController.shared.refresh(force: true)
                let handler = self.backgroundCompletionHandler
                self.backgroundCompletionHandler = nil
                handler?()
            }
        }

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        config.allowsCellularAccess = true            // narrowed per request
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegate.queue)

        session.getAllTasks { [weak self] live in
            // Stale conversion checks from a previous run; we poll directly now.
            live.filter { $0.taskDescription?.hasPrefix(Self.probePrefix) == true }.forEach { $0.cancel() }
            let snapshot = live.compactMap { t -> (URLSessionTask, SegmentTaskTag)? in
                guard let tag = SegmentTaskTag(t.taskDescription) else { return nil }
                return (t, tag)
            }
            Task { @MainActor in self?.reconcile(snapshot) }
        }

        NetworkMonitor.shared.onChange { [weak self] connected in self?.networkChanged(connected: connected) }

        UIDevice.current.isBatteryMonitoringEnabled = true
        updatePowerState()
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePowerState() }
        }

        updateTimer()
    }

    private func recordsChanged() {
        var index = [String: Int](minimumCapacity: records.count)
        var newStates = [String: DownloadRecord.State](minimumCapacity: records.count)
        var byParent: [String: [Int]] = [:], byGrandparent: [String: [Int]] = [:]
        var active = false
        for (i, r) in records.enumerated() {
            index[r.id] = i
            newStates[r.id] = r.state
            if let p = r.metadata.parentRatingKey { byParent[r.serverID + "|" + p, default: []].append(i) }
            if let g = r.metadata.grandparentRatingKey { byGrandparent[r.serverID + "|" + g, default: []].append(i) }
            if r.state == .queued || r.state == .preparing || r.state == .downloading || r.state == .assembling { active = true }
        }
        indexByID = index
        indexByParent = byParent
        indexByGrandparent = byGrandparent
        if newStates != states {
            // Announce transitions into a final state (not the initial load).
            for (id, state) in newStates where (state == .completed || state == .failed) && states[id] != nil && states[id] != state {
                guard let i = index[id] else { continue }
                if let event = finishedEvent(for: records[i]) { lastEvent = event }
            }
            states = newStates
            SpotlightIndex.sync(records)
        }
        if active != hasActiveDownloads { hasActiveDownloads = active }
        if active != hasActiveWork {
            hasActiveWork = active
            updateTimer()
        }
    }

    /// The event to announce when `rec` finishes, or nil while others in its batch are still going.
    private func finishedEvent(for rec: DownloadRecord) -> Event? {
        Self.finishedEvent(for: rec, batchMembers: rec.batchID.map { b in records.filter { $0.batchID == b } } ?? [rec])
    }

    nonisolated static func finishedEvent(for rec: DownloadRecord, batchMembers members: [DownloadRecord]) -> Event? {
        let unfinished: Set<DownloadRecord.State> = [.queued, .preparing, .downloading, .assembling]
        guard rec.batchID != nil else {
            let m = rec.metadata
            let title = m.kind == .episode ? "\(m.grandparentTitle ?? m.title) · \(m.subtitleLine ?? m.title)" : m.title
            return Event(recordID: rec.id, title: title, succeeded: rec.state == .completed,
                         message: rec.state == .failed ? rec.lastError : nil, isAudio: rec.isAudio)
        }
        guard !members.contains(where: { unfinished.contains($0.state) }) else { return nil }
        let done = members.filter { $0.state == .completed }
        let failed = members.count - done.count
        let audio = members.allSatisfy(\.isAudio)
        let noun = audio ? "song" : (members.allSatisfy { $0.metadata.kind == .episode } ? "episode" : "item")
        let summary = "\(done.count) \(noun)\(done.count == 1 ? "" : "s")"
        return Event(recordID: rec.id, title: "\(rec.batchTitle ?? "Downloads") · \(summary)",
                     succeeded: failed == 0,
                     message: failed > 0 ? "\(failed) couldn't download. Open Downloads to retry." : nil,
                     isAudio: audio)
    }

    /// The progress/watchdog timer only runs while there's work to do.
    private func updateTimer() {
        guard started else { return }
        if hasActiveWork, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !hasActiveWork, let t = timer {
            t.invalidate()
            timer = nil
            Task { @MainActor in self.tick() }  // final progress + Live Activity "done" state
        }
    }

    func state(id: String) -> DownloadRecord.State? { states[id] }

    func state(serverID: String, ratingKey: String) -> DownloadRecord.State? {
        states[DownloadRecord.makeID(serverID: serverID, ratingKey: ratingKey)]
    }

    /// Re-attach to tasks the background session kept running while we were gone.
    private func reconcile(_ live: [(URLSessionTask, SegmentTaskTag)]) {
        for (task, tag) in live {
            guard let download = task as? URLSessionDownloadTask,
                  task.state == .running || task.state == .suspended,
                  let i = index(of: tag.recordID),
                  records[i].state == .downloading,
                  let seg = records[i].segments.first(where: { $0.index == tag.index }),
                  !seg.done, seg.start == tag.start, seg.end == tag.end
            else {
                task.cancel()
                continue
            }
            tasks[tag.recordID, default: [:]][tag.index] = download
            if task.state == .suspended { task.resume() }
        }
        // Anything interrupted mid-assembly continues where it left off.
        for r in records where r.state == .assembling { startAssembly(r.id) }
        reconciled = true
        pump()
    }

    /// Segment files are only moved into place after validation, so a file of
    /// exactly the right size is complete even if we died before persisting that.
    private func adoptFinishedSegmentsOnDisk() {
        for i in records.indices where records[i].state == .downloading {
            for j in records[i].segments.indices where !records[i].segments[j].done {
                let seg = records[i].segments[j]
                if DownloadStore.fileSize(DownloadStore.segmentURL(id: records[i].id, index: seg.index)) == seg.length {
                    records[i].segments[j].done = true
                }
            }
        }
    }

    private func tick() {
        publishProgress()
        DownloadActivityController.shared.refresh()
        if Date().timeIntervalSince(lastWatchdog) > 5 { watchdog() }
        if retryAt.values.contains(where: { $0 <= Date() }) { pump() }
    }

    /// The system download daemon sometimes holds an interrupted transfer for
    /// its own (long, opaque) retry schedule instead of reporting an error.
    /// While we're in the foreground and online, restart any segment that
    /// started receiving data and then stalled – only that segment restarts.
    private func watchdog() {
        lastWatchdog = Date()
        guard NetworkMonitor.shared.isConnected, UIApplication.shared.applicationState == .active else {
            activity.removeAll()
            return
        }
        let snapshot = delegate.progressSnapshot()
        let now = Date()
        // Tasks that moved recently are using connection slots; idle zero-byte
        // tasks beyond that may simply be queued behind them.
        let progressing = activity.values.filter { now.timeIntervalSince($0.at) < 10 && $0.bytes > 0 }.count
        let slotsBusy = progressing >= session.configuration.httpMaximumConnectionsPerHost
        var live = Set<Int>()
        var restarted = false
        for (id, segTasks) in tasks {
            for (index, task) in segTasks {
                let tid = task.taskIdentifier
                live.insert(tid)
                let bytes = snapshot[id]?[index] ?? 0
                if let last = activity[tid], last.bytes == bytes {
                    let limit = bytes > 0 ? stallTimeout : (slotsBusy ? .infinity : stallTimeout * 1.5)
                    if now.timeIntervalSince(last.at) > limit {
                        tasks[id]?[index] = nil
                        activity[tid] = nil
                        delegate.clearProgress(recordID: id, index: index)
                        task.cancel()
                        if let i = self.index(of: id) { records[i].lastError = "Connection stalled · restarting segment" }
                        restarted = true
                    }
                } else {
                    activity[tid] = (bytes, now)
                }
            }
        }
        activity = activity.filter { live.contains($0.key) }
        if restarted { pump() }
    }

    // MARK: - Public API

    func record(serverID: String, ratingKey: String) -> DownloadRecord? {
        index(of: DownloadRecord.makeID(serverID: serverID, ratingKey: ratingKey)).map { records[$0] }
    }

    func localFileURL(for record: DownloadRecord) -> URL? {
        guard record.state == .completed, let name = record.fileName else { return nil }
        let url = DownloadStore.directory(for: record.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localFileURL(serverID: String, ratingKey: String) -> URL? {
        record(serverID: serverID, ratingKey: ratingKey).flatMap(localFileURL(for:))
    }

    func progress(of record: DownloadRecord) -> Double {
        guard let total = record.totalBytes, total > 0 else { return record.state == .completed ? 1 : 0 }
        if record.state == .completed { return 1 }
        let bytes = liveBytes[record.id] ?? record.downloadedSegmentBytes
        return min(1, Double(bytes) / Double(total))
    }

    /// `batchTitle`: name for a group download (playlist, season…), announced once when all finish.
    func enqueue(_ items: [PlexMetadata], serverID: String, quality: DownloadQuality? = nil, batchTitle: String? = nil, forceConversion: Bool = false) {
        guard ProStore.require(.downloads) else { return }
        let leaves = items.filter { $0.isLeaf && $0.kind != .photo }
        let batchID = batchTitle != nil && leaves.count > 1 ? UUID().uuidString : nil
        var newRecords: [DownloadRecord] = []
        var seen = Set<String>()
        for item in leaves {
            if let existing = record(serverID: serverID, ratingKey: item.ratingKey) {
                if existing.state == .failed { retry(existing.id) }
                continue
            }
            var rec = DownloadRecord(serverID: serverID, metadata: item, quality: quality ?? qualityForNewDownloads)
            guard seen.insert(rec.id).inserted else { continue }
            rec.forceConversion = forceConversion
            rec.batchID = batchID
            rec.batchTitle = batchID == nil ? nil : batchTitle
            newRecords.append(rec)
        }
        guard !newRecords.isEmpty else { return }
        // One append: adding a 500-song playlist publishes `records` once, not 500 times.
        records.append(contentsOf: newRecords)
        newRecords.forEach(saveArtwork)
        saveNow(); pump(); Haptics.success()
    }

    // MARK: Playlists & groups

    /// Downloads belonging to a season, show, album or artist.
    func records(under item: PlexMetadata, serverID: String) -> [DownloadRecord] {
        let key = item.ratingKey
        switch item.kind {
        case .season, .album:
            _ = records  // observe changes
            return (indexByParent[serverID + "|" + key] ?? []).compactMap { records.indices.contains($0) ? records[$0] : nil }
        case .show, .artist:
            _ = records
            return (indexByGrandparent[serverID + "|" + key] ?? []).compactMap { records.indices.contains($0) ? records[$0] : nil }
        default:
            return []
        }
    }

    func collection(serverID: String, ratingKey: String) -> DownloadCollection? {
        collections.first { $0.serverID == serverID && $0.ratingKey == ratingKey }
    }

    /// Download a whole playlist and remember it as one unit.
    func downloadPlaylist(ratingKey: String, title: String, thumb: String?, items: [PlexMetadata],
                          serverID: String, quality: DownloadQuality? = nil) {
        guard ProStore.require(.downloads) else { return }
        let leaves = items.filter { $0.isPlayableVideo || $0.kind == .track }
        let ids = leaves.map { DownloadRecord.makeID(serverID: serverID, ratingKey: $0.ratingKey) }
        let audio = !leaves.isEmpty && leaves.allSatisfy { $0.kind == .track }
        let c = DownloadCollection(id: DownloadRecord.makeID(serverID: serverID, ratingKey: ratingKey),
                                   serverID: serverID, ratingKey: ratingKey, title: title, thumb: thumb,
                                   playlistType: audio ? "audio" : "video", itemIDs: ids)
        var updated = c
        if let i = collections.firstIndex(where: { $0.id == c.id }) {
            // Re-downloading keeps the playlist's update preferences.
            updated.autoDownloadNew = collections[i].autoDownloadNew
            updated.removeMissing = collections[i].removeMissing
            collections[i] = updated
        } else { collections.append(updated) }
        saveCollections()
        enqueue(leaves, serverID: serverID, quality: quality, batchTitle: title)
    }

    func setPlaylistUpdates(_ id: String, autoDownloadNew: Bool? = nil, removeMissing: Bool? = nil) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        if let autoDownloadNew { collections[i].autoDownloadNew = autoDownloadNew }
        if let removeMissing { collections[i].removeMissing = removeMissing }
        saveCollections()
        Task { await syncPlaylistDownloads(only: id) }
    }

    /// Brings downloaded playlists in line with the server: downloads new items
    /// and/or removes ones taken off the playlist, per each playlist's settings.
    func syncPlaylistDownloads(only id: String? = nil) async {
        guard ProStore.isUnlocked, NetworkMonitor.shared.isConnected, !LibraryCache.isOffline else { return }
        for c in collections where c.keepsUpdated && (id == nil || c.id == id) {
            guard let api = ServerDirectory.shared.api(for: c.serverID),
                  let items = try? await LibraryCache.$requireFresh.withValue(true, operation: { try await api.playlistItems(c.ratingKey) }),
                  ServerDirectory.shared.authorizes(api),
                  let i = collections.firstIndex(where: { $0.id == c.id }) else { continue }
            let leaves = items.filter { $0.isPlayableVideo || $0.kind == .track }
            let usedElsewhere = Set(collections.filter { $0.id != c.id }.flatMap(\.itemIDs))
            let plan = PlaylistSyncPlan.make(collection: collections[i], serverKeys: leaves.map(\.ratingKey), usedElsewhere: usedElsewhere)
            collections[i].itemIDs = plan.order
            collections[i].lastSynced = Date()
            saveCollections()
            if !plan.toRemove.isEmpty { deleteMany(plan.toRemove) }
            let add = Set(plan.toDownload)
            if !add.isEmpty {
                enqueue(leaves.filter { add.contains($0.ratingKey) }, serverID: c.serverID, batchTitle: c.title)
            }
        }
    }

    func records(in collection: DownloadCollection) -> [DownloadRecord] {
        collection.itemIDs.compactMap { id in index(of: id).map { records[$0] } }
    }

    /// Remove a downloaded playlist. Items that another downloaded playlist
    /// also contains are kept.
    func removeCollection(_ id: String) {
        guard let c = collections.first(where: { $0.id == id }) else { return }
        collections.removeAll { $0.id == id }
        let stillUsed = Set(collections.flatMap(\.itemIDs))
        deleteMany(c.itemIDs.filter { !stillUsed.contains($0) })
        saveCollections()
    }

    /// Delete several downloads with a single save.
    func deleteMany(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        bulkUpdate = true
        ids.forEach(delete)
        bulkUpdate = false
        saveNow()
        resumeWaitingForSpace()
    }

    private static var collectionsURL: URL { DownloadStore.root.appendingPathComponent("collections.json") }

    private func loadCollections() {
        guard let data = try? Data(contentsOf: Self.collectionsURL),
              let saved = try? JSONDecoder().decode([DownloadCollection].self, from: data) else { return }
        collections = saved
    }

    private func saveCollections() {
        if let data = try? JSONEncoder().encode(collections) { try? data.write(to: Self.collectionsURL, options: .atomic) }
    }

    func pause(_ id: String) {
        guard let i = index(of: id), [.queued, .preparing, .downloading].contains(records[i].state) else { return }
        records[i].state = .paused
        cancelTasks(for: id, keepResumeData: true)
        saveNow()
    }

    func resume(_ id: String) {
        guard let i = index(of: id), records[i].state == .paused || records[i].state == .failed else { return }
        records[i].lastError = nil
        if !records[i].segments.isEmpty {
            records[i].state = .downloading
        } else if case .queue? = records[i].source {
            records[i].state = .preparing
        } else {
            records[i].source = nil
            records[i].state = .queued
        }
        records[i].prepareAttempts = 0
        assemblyFailures[id] = nil
        for j in records[i].segments.indices { records[i].segments[j].attempts = 0 }
        clearRetries(for: id)
        saveNow()
        pump()
    }

    func retry(_ id: String) { resume(id) }

    /// Call as the app leaves the foreground (while still allowed to create
    /// non-discretionary tasks) so the system can finish every remaining
    /// segment without needing to wake us.
    func prepareForBackground() {
        queueEverything = true
        pump()
        saveNow()
        scheduleChargingTask()
        DownloadStore.flush()
        if records.contains(where: { $0.state == .preparing }) {
            // Keep polling conversions for the background time iOS grants…
            if conversionBackgroundTask == .invalid {
                conversionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "conversion-poll") { [weak self] in
                    self?.endConversionBackgroundTask()
                }
            }
            // …and leave scheduled checks with the system for after that.
            scheduleConversionProbes()
        }
    }

    private func endConversionBackgroundTask() {
        if conversionBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(conversionBackgroundTask)
            conversionBackgroundTask = .invalid
        }
    }

    /// A conversion runs on the server, but our polling stops once we're
    /// suspended. A tiny ranged request against the converted file, set to
    /// start later, makes the system wake us to check again – and when the
    /// conversion is done, the real download starts without opening the app.
    private func scheduleConversionProbes(delay: TimeInterval = 45) {
        for rec in records where rec.state == .preparing && probeTasks[rec.id] == nil {
            guard case .queue(let q, let item)? = rec.source, let api = ServerDirectory.shared.api(for: rec.serverID) else { continue }
            var req = URLRequest(url: api.url(ServerConversion.mediaPath(queueID: q, itemID: item), includeToken: true))
            PlexClient.headers(token: api.token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let task = session.downloadTask(with: req)
            task.taskDescription = Self.probePrefix + rec.id
            task.earliestBeginDate = Date().addingTimeInterval(delay)
            task.countOfBytesClientExpectsToSend = 1024
            task.countOfBytesClientExpectsToReceive = 4096
            probeTasks[rec.id] = task
            task.resume()
        }
    }

    private func cancelProbe(_ id: String) {
        probeTasks.removeValue(forKey: id)?.cancel()
    }

    private func probeFinished(_ id: String) {
        probeTasks[id] = nil
        guard let i = index(of: id), records[i].state == .preparing else { return }
        retryAt[prepKey(id)] = nil
        if !preparing.contains(id) {
            preparing.insert(id)
            // iOS may suspend us right after delivering this event; ask for time to finish the check.
            let bg = UIApplication.shared.beginBackgroundTask(withName: "conversion-probe")
            Task {
                defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
                await pollConversion(id)
                // Still converting and we're about to be suspended again: check back later.
                if UIApplication.shared.applicationState != .active, records.first(where: { $0.id == id })?.state == .preparing {
                    scheduleConversionProbes(delay: 60)
                }
            }
        }
    }

    func didBecomeActive() {
        queueEverything = false
        removeExpiredWatched()
        pump()
    }

    func pauseAll() { records.map(\.id).forEach(pause) }

    /// Pauses running transfers and returns their IDs so they can be resumed later
    /// (used while credentials change, so nothing keeps using the old token).
    @discardableResult
    func suspendActive() -> [String] {
        let ids = records.filter { [.queued, .preparing, .downloading].contains($0.state) }.map(\.id)
        ids.forEach(pause)
        return ids
    }
    func resumeAll() { records.filter { $0.state == .paused }.map(\.id).forEach(resume) }

    func delete(_ id: String) {
        guard let i = index(of: id) else { return }
        let rec = records[i]
        cancelTasks(for: id, keepResumeData: false)
        cancelProbe(id)
        records.remove(at: i)
        liveBytes[id] = nil
        delegate.clearProgress(recordID: id)
        clearRetries(for: id)
        DownloadStore.removeFiles(for: id)
        if case .queue(let q, let item)? = rec.source, let api = ServerDirectory.shared.api(for: rec.serverID) {
            Task { await ServerConversion.remove(api: api, queueID: q, itemID: item) }
        }
        if !bulkUpdate {
            saveNow()
            if rec.state == .completed || rec.totalBytes != nil { resumeWaitingForSpace() }
        }
    }

    /// Replace a download that turned out to be unplayable with a converted copy.
    func redownloadPlayable(_ id: String) {
        guard let rec = records.first(where: { $0.id == id }), ProStore.require(.downloads) else { return }
        delete(id)
        enqueue([rec.metadata], serverID: rec.serverID, quality: .original, forceConversion: true)
    }

    func deleteAll(serverID: String? = nil) {
        bulkUpdate = true
        records.filter { serverID == nil || $0.serverID == serverID }.map(\.id).forEach(delete)
        bulkUpdate = false
        collections.removeAll { serverID == nil || $0.serverID == serverID }
        saveCollections()
        saveNow()
        resumeWaitingForSpace()
    }

    // MARK: Offline progress

    private func projectProgress(at i: Int, clearUnknown: Bool) {
        Self.projectProgress(&records[i], userID: activeUserID, clearUnknown: clearUnknown)
    }

    private static func projectProgress(_ record: inout DownloadRecord, userID: String?, clearUnknown: Bool) {
        if let progress = record.progress(for: userID) {
            record.metadata.viewOffset = progress.offset
            record.metadata.viewCount = progress.watched ? 1 : 0
        } else if clearUnknown {
            record.metadata.viewOffset = nil
            record.metadata.viewCount = nil
        }
    }

    /// Many changes at once: `records` is published (and its indexes rebuilt) once, not per change.
    /// Every `records[i]` write runs `recordsChanged`, which is O(n), so loops over all records
    /// must go through here.
    private func updateRecords(_ body: (inout [DownloadRecord]) -> Void) {
        var copy = records
        body(&copy)
        records = copy
    }

    func recordOfflineProgress(_ id: String, positionMs: Int, durationMs: Int?, userID: String?) {
        guard let i = index(of: id) else { return }
        records[i].updateProgress(userID: userID, positionMs: positionMs, durationMs: durationMs)
        if userID == activeUserID { projectProgress(at: i, clearUnknown: false) }
        scheduleSave()
    }

    /// Acknowledges only the version sent, never a newer playback update.
    func syncOfflineProgress() async {
        guard !syncingProgress else { return }
        syncingProgress = true
        defer { syncingProgress = false }
        let userID = activeUserID
        for rec in records {
            guard userID == activeUserID else { break }
            guard let progress = rec.progress(for: userID), progress.pending,
                  let api = ServerDirectory.shared.api(for: rec.serverID) else { continue }
            do {
                if progress.watched {
                    try await api.scrobble(rec.metadata.ratingKey)
                } else {
                    try await api.setProgress(ratingKey: rec.metadata.ratingKey, timeMs: progress.offset)
                }
                if let i = index(of: rec.id) {
                    records[i].acknowledgeProgress(userID: userID, revision: progress.revision)
                }
            } catch { continue }
        }
        saveNow()
    }

    /// Pull watch state for downloaded items from the server so offline
    /// browsing reflects progress made on other devices (or by another user).
    func refreshWatchState(serverID: String) async {
        guard let api = ServerDirectory.shared.api(for: serverID) else { return }
        let userID = activeUserID
        let keys = records.filter { $0.serverID == serverID && $0.progress(for: userID)?.pending != true }.map(\.metadata.ratingKey)
        var fresh: [String: PlexMetadata] = [:]
        for start in stride(from: 0, to: keys.count, by: 40) {
            let batch = keys[start..<min(start + 40, keys.count)].joined(separator: ",")
            guard let items = try? await api.container("/library/metadata/\(batch)").metadata else { return }
            for item in items { fresh[item.ratingKey] = item }
        }
        guard activeUserID == userID, ServerDirectory.shared.authorizes(api) else { return }
        var updated = records
        var changed = false
        for i in updated.indices where updated[i].serverID == serverID && updated[i].progress(for: userID)?.pending != true {
            guard let item = fresh[updated[i].metadata.ratingKey] else { continue }
            if updated[i].metadata.viewOffset != item.viewOffset || updated[i].metadata.viewCount != item.viewCount || updated[i].progress(for: userID) == nil {
                updated[i].metadata.viewOffset = item.viewOffset
                updated[i].metadata.viewCount = item.viewCount
                updated[i].metadata.lastViewedAt = item.lastViewedAt
                if updated[i].userProgress == nil { updated[i].userProgress = [:] }
                updated[i].userProgress?[DownloadRecord.progressKey(userID)] = OfflineProgress(
                    offset: item.viewOffset ?? 0, watched: (item.viewCount ?? 0) > 0, pending: false)
                changed = true
            }
        }
        // Published once (and only when something changed), not once per field.
        if changed { records = updated; saveNow() }
        removeExpiredWatched()
    }

    func updateMetadata(_ metadata: PlexMetadata, serverID: String) {
        guard let i = records.firstIndex(where: { $0.serverID == serverID && $0.metadata.ratingKey == metadata.ratingKey }),
              records[i].progress(for: activeUserID)?.pending != true else { return }
        records[i].metadata.viewOffset = metadata.viewOffset
        records[i].metadata.viewCount = metadata.viewCount
        if records[i].userProgress == nil { records[i].userProgress = [:] }
        records[i].userProgress?[DownloadRecord.progressKey(activeUserID)] = OfflineProgress(
            offset: metadata.viewOffset ?? 0, watched: (metadata.viewCount ?? 0) > 0, pending: false)
        scheduleSave()
    }

    // MARK: - Scheduling

    /// Starts whatever work is possible right now. Idempotent.
    func pump() {
        guard reconciled else { return }
        var outstanding = tasks.values.reduce(0) { $0 + $1.count }
        let now = Date()
        // Items converting, transferring or being prepared count toward the limit.
        var inProgress = records.filter { [.preparing, .downloading, .assembling].contains($0.state) }.count
            + records.filter { $0.state == .queued && preparing.contains($0.id) }.count

        for i in records.indices {
            let rec = records[i]
            switch rec.state {
            case .queued:
                if !preparing.contains(rec.id), inProgress < Self.maxSimultaneousDownloads,
                   (retryAt[prepKey(rec.id)] ?? .distantPast) <= now {
                    inProgress += 1
                    preparing.insert(rec.id)
                    Task { await prepare(rec.id) }
                }
            case .preparing:
                if !preparing.contains(rec.id), (retryAt[prepKey(rec.id)] ?? .distantPast) <= now {
                    preparing.insert(rec.id)
                    Task { await pollConversion(rec.id) }
                }
            case .downloading:
                if rec.segments.allSatisfy(\.done) {
                    if (retryAt[asmKey(rec.id)] ?? .distantPast) <= now { startAssembly(rec.id) }
                    continue
                }
                guard transfersAllowed, outstanding < taskWindow, let api = ServerDirectory.shared.api(for: rec.serverID) else { continue }
                for seg in rec.segments where !seg.done {
                    guard outstanding < taskWindow else { break }
                    if tasks[rec.id]?[seg.index] != nil { continue }
                    if let t = retryAt[segKey(rec.id, seg.index)], t > now { continue }
                    startTask(recordIndex: i, segment: seg, api: api)
                    outstanding += 1
                }
            case .assembling:
                startAssembly(rec.id)
            case .paused, .completed, .failed:
                break
            }
        }
    }

    private func sourceURL(_ rec: DownloadRecord, api: PlexServerAPI) -> URL? {
        switch rec.source {
        case .file(let partKey)?:
            return api.url(partKey, query: [URLQueryItem(name: "download", value: "1")], includeToken: true)
        case .queue(let q, let item)?:
            return api.url(ServerConversion.mediaPath(queueID: q, itemID: item), includeToken: true)
        case nil:
            return nil
        }
    }

    private func startTask(recordIndex i: Int, segment seg: DownloadSegment, api: PlexServerAPI) {
        let rec = records[i]
        guard let total = rec.totalBytes, let url = sourceURL(rec, api: api),
              let j = rec.segments.firstIndex(where: { $0.index == seg.index }) else { return }
        let ranged = rec.segments.count > 1
        let tag = SegmentTaskTag(recordID: rec.id, index: seg.index, start: seg.start, end: seg.end, total: total, ranged: ranged)
        let base = api.baseURL.absoluteString

        var task: URLSessionDownloadTask
        let resumeURL = DownloadStore.resumeDataURL(id: rec.id, index: seg.index)
        if !ranged, seg.lastBaseURL == base, let data = try? Data(contentsOf: resumeURL) {
            // Single-stream mode: continue exactly where the last attempt stopped.
            task = session.downloadTask(withResumeData: data)
        } else {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            PlexClient.headers(token: api.token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            if ranged { req.setValue("bytes=\(seg.start)-\(seg.end)", forHTTPHeaderField: "Range") }
            req.allowsCellularAccess = allowCellular
            req.allowsExpensiveNetworkAccess = allowCellular
            task = session.downloadTask(with: req)
        }
        // Resume data is single-use; a failed attempt writes fresh data.
        try? FileManager.default.removeItem(at: resumeURL)

        task.taskDescription = tag.encoded
        task.countOfBytesClientExpectsToReceive = seg.length
        task.countOfBytesClientExpectsToSend = 1024
        records[i].segments[j].lastBaseURL = base
        tasks[rec.id, default: [:]][seg.index] = task
        task.resume()
    }

    private func cancelTasks(for id: String, keepResumeData: Bool) {
        guard let segTasks = tasks.removeValue(forKey: id) else { return }
        for (index, task) in segTasks {
            if keepResumeData, SegmentTaskTag(task.taskDescription)?.ranged == false {
                task.cancel { data in
                    if let data {
                    DownloadStore.ensureDirectory(for: id)
                    try? data.write(to: DownloadStore.resumeDataURL(id: id, index: index), options: .atomic)
                }
                }
            } else {
                task.cancel()
            }
        }
        delegate.clearProgress(recordID: id)
    }

    /// Cancel and recreate in-flight tasks (e.g. after a cellular-policy or address change).
    private func restartAllTasks(serverID: String? = nil, unlessBase base: String? = nil) {
        for (id, segTasks) in tasks {
            guard let i = index(of: id), serverID == nil || records[i].serverID == serverID else { continue }
            for (index, task) in segTasks {
                if let base, records[i].segments.first(where: { $0.index == index })?.lastBaseURL == base { continue }
                tasks[id]?[index] = nil
                if SegmentTaskTag(task.taskDescription)?.ranged == false {
                    task.cancel { data in
                        if let data {
                    DownloadStore.ensureDirectory(for: id)
                    try? data.write(to: DownloadStore.resumeDataURL(id: id, index: index), options: .atomic)
                }
                    }
                } else {
                    task.cancel()
                }
                delegate.clearProgress(recordID: id, index: index)
            }
        }
        pump()
    }

    // MARK: - Completion handling

    private func handleCompletion(tag: SegmentTaskTag, taskID: Int, result: SegmentResult) {
        let isCurrent = tasks[tag.recordID]?[tag.index]?.taskIdentifier == taskID
        if isCurrent { tasks[tag.recordID]?[tag.index] = nil }
        delegate.clearProgress(recordID: tag.recordID, index: tag.index)

        guard let i = index(of: tag.recordID),
              let j = records[i].segments.firstIndex(where: { $0.index == tag.index && $0.start == tag.start && $0.end == tag.end })
        else {
            // Record was deleted or re-planned; discard stray output.
            switch result {
            case .success: try? FileManager.default.removeItem(at: DownloadStore.segmentURL(id: tag.recordID, index: tag.index))
            case .wholeFile: try? FileManager.default.removeItem(at: DownloadStore.directory(for: tag.recordID).appendingPathComponent("whole-download"))
            default: break
            }
            return
        }
        // A superseded task (we already started a replacement) only matters if it succeeded.
        if !isCurrent { guard case .success = result else { return } }

        let key = segKey(tag.recordID, tag.index)
        switch result {
        case .success:
            records[i].segments[j].done = true
            records[i].segments[j].attempts = 0
            records[i].lastError = nil
            retryAt[key] = nil
            if let other = tasks[tag.recordID]?[tag.index], other.taskIdentifier != taskID {
                other.cancel()
                tasks[tag.recordID]?[tag.index] = nil
            }
            if records[i].state == .downloading && records[i].segments.allSatisfy(\.done) {
                startAssembly(tag.recordID)
            } else {
                scheduleSave()
            }

        case .wholeFile:
            // Server ignored Range and sent everything: adopt it as a single finished segment.
            cancelTasks(for: tag.recordID, keepResumeData: false)
            DownloadStore.removeSegmentFiles(for: tag.recordID)
            let dir = DownloadStore.ensureDirectory(for: tag.recordID)
            do {
                try FileManager.default.moveItem(at: dir.appendingPathComponent("whole-download"), to: DownloadStore.segmentURL(id: tag.recordID, index: 0))
            } catch {
                records[i].state = .failed
                records[i].lastError = "Couldn't adopt the downloaded file: " + error.localizedDescription
                saveNow()
                break
            }
            var seg = DownloadSegment(index: 0, start: 0, end: tag.total - 1)
            seg.done = true
            records[i].segments = [seg]
            startAssembly(tag.recordID)

        case .rangeIgnored:
            cancelTasks(for: tag.recordID, keepResumeData: false)
            DownloadStore.removeSegmentFiles(for: tag.recordID)
            records[i].segments = SegmentPlanner.plan(totalBytes: tag.total, supportsRanges: false)
            saveNow()

        case .http(let status, let retryAfter):
            handleHTTPFailure(recordIndex: i, segmentIndex: j, status: status, retryAfter: retryAfter)

        case .invalid(let message):
            records[i].segments[j].attempts += 1
            fail(recordIndex: i, segmentIndex: j, message: message)

        case .error(let error, _):
            switch SegmentPlanner.classify(error) {
            case .cancelledByUs:
                break
            case .network, .cancelledBySystem:
                // Never gives up: wait for connectivity, retry with gentle backoff.
                records[i].segments[j].attempts += 1
                records[i].lastError = "Connection interrupted · resuming automatically"
                retryAt[key] = Date().addingTimeInterval(SegmentPlanner.backoff(attempts: min(records[i].segments[j].attempts, 4)))
            case .unreachableHost:
                records[i].segments[j].attempts += 1
                records[i].lastError = "Can't reach server · retrying"
                retryAt[key] = Date().addingTimeInterval(SegmentPlanner.backoff(attempts: min(records[i].segments[j].attempts, 4)))
                resolveEndpoint(serverID: records[i].serverID)
            case .storage:
                records[i].lastError = "Not enough storage space. Free up space and resume."
                records[i].state = .paused
                cancelTasks(for: tag.recordID, keepResumeData: true)
                saveNow()
            case .other:
                records[i].segments[j].attempts += 1
                fail(recordIndex: i, segmentIndex: j, message: error.localizedDescription)
            }
            scheduleSave()
        }
        pump()
    }

    private func handleHTTPFailure(recordIndex i: Int, segmentIndex j: Int, status: Int, retryAfter: TimeInterval?) {
        let rec = records[i]
        let key = segKey(rec.id, rec.segments[j].index)
        switch status {
        case 503:
            // Converted media not ready yet, or server busy.
            retryAt[key] = Date().addingTimeInterval(max(5, retryAfter ?? 15))
        case 401, 403:
            records[i].state = .failed
            records[i].lastError = "The server refused access (HTTP \(status)). Sign in again, then retry."
            cancelTasks(for: rec.id, keepResumeData: true)
            saveNow()
        case 404, 410, 416:
            // The file changed or the converted copy expired: prepare again from scratch.
            resetForPreparation(i, note: status == 416 ? "File changed on server; restarting." : nil)
        default:
            records[i].segments[j].attempts += 1
            fail(recordIndex: i, segmentIndex: j, message: "Server error (HTTP \(status))")
        }
    }

    private func fail(recordIndex i: Int, segmentIndex j: Int, message: String) {
        let attempts = records[i].segments[j].attempts
        if attempts >= maxFailures {
            records[i].state = .failed
            records[i].lastError = message
            cancelTasks(for: records[i].id, keepResumeData: true)
            saveNow()
        } else {
            retryAt[segKey(records[i].id, records[i].segments[j].index)] = Date().addingTimeInterval(SegmentPlanner.backoff(attempts: attempts))
        }
    }

    private func resetForPreparation(_ i: Int, note: String?) {
        let id = records[i].id
        // Drop the old server-side conversion so it doesn't linger in the server's queue.
        if case .queue(let q, let item)? = records[i].source, let api = ServerDirectory.shared.api(for: records[i].serverID) {
            Task { await ServerConversion.remove(api: api, queueID: q, itemID: item) }
        }
        cancelProbe(id)
        cancelTasks(for: id, keepResumeData: false)
        DownloadStore.removeSegmentFiles(for: id)
        try? FileManager.default.removeItem(at: Assembler.sidecarURL(id: id))
        records[i].segments = []
        records[i].source = nil
        records[i].totalBytes = nil
        records[i].assembledSegments = 0
        records[i].lastError = note
        records[i].prepareAttempts += 1
        if records[i].prepareAttempts > 5 {
            records[i].state = .failed
            records[i].lastError = "The server kept changing the file. Try again later."
        } else {
            records[i].state = .queued
        }
        saveNow()
    }

    // MARK: - Preparation

    private func prepare(_ id: String) async {
        defer { preparing.remove(id); pump() }
        guard let i0 = index(of: id), records[i0].state == .queued else { return }
        let rec = records[i0]
        guard let api = ServerDirectory.shared.api(for: rec.serverID) else {
            postponePreparation(id, message: "Server unavailable")
            return
        }
        do {
            let fresh = try await api.metadata(rec.metadata.ratingKey) ?? rec.metadata
            guard ServerDirectory.shared.authorizes(api), let i = index(of: id), records[i].state == .queued else { return }
            var merged = fresh
            if records[i].progress(for: activeUserID)?.pending == true { merged.viewOffset = records[i].metadata.viewOffset; merged.viewCount = records[i].metadata.viewCount }
            records[i].metadata = merged

            guard let media = fresh.primaryMedia, let part = media.parts.first, let partKey = part.key else {
                throw PlexError.unsupported("This item has no downloadable media.")
            }
            saveSubtitles(id: id, part: part, api: api)

            // Never store something the device can't play: convert whenever the
            // source isn't natively playable, or a smaller size was requested.
            let native = PlaybackDecider.canPlayOnDevice(media: media, kind: fresh.kind)
            // A "smaller" quality that isn't actually smaller than the source falls back to Original.
            if rec.quality != .original, !rec.quality.isReduction(of: media), let i = index(of: id) {
                records[i].quality = .original
            }
            let quality = index(of: id).map { records[$0].quality } ?? rec.quality
            let wantsConversion = rec.requiresConversion(media: media, kind: fresh.kind, quality: quality)

            if wantsConversion {
                do {
                    let sidecarSelected = part.selectedSubtitle?.isSidecarText ?? false
                    let ids = try await ServerConversion.enqueue(api: api, ratingKey: fresh.ratingKey, mediaIndex: fresh.primaryMediaIndex, quality: quality,
                                                                 burnSubtitles: !sidecarSelected, forceTranscode: rec.forceConversion == true)
                    guard ServerDirectory.shared.authorizes(api), let i = index(of: id), records[i].state == .queued else { return }
                    records[i].source = .queue(queueID: ids.queueID, itemID: ids.itemID)
                    records[i].isConverted = true
                    records[i].conversionReason = PlaybackDecider.conversionReason(media: media, kind: fresh.kind, quality: quality)
                    records[i].sourceContainer = media.container
                    records[i].fileExtension = "mp4"
                    records[i].state = .preparing
                    records[i].preparationProgress = 0
                    records[i].lastError = nil
                    saveNow()
                    return
                } catch PlexError.http(let code, _) where [400, 404, 405, 501].contains(code) {
                    guard ServerDirectory.shared.authorizes(api) else { return }
                    // Server predates the download queue (PMS 1.41.9).
                    guard native && rec.forceConversion != true else {
                        if let i = index(of: id) {
                            records[i].state = .failed
                            records[i].lastError = api.isJellyfin
                                ? "This file's format (\((media.container ?? "unknown").uppercased())) can't play on iPhone, and downloads from Jellyfin aren't converted. Turn on the built-in player in Playback Preferences to download the original."
                                : "This file's format (\((media.container ?? "unknown").uppercased())) can't play on iPhone, and your server is too old to convert it. Update Plex Media Server to 1.41.9 or later."
                            saveNow()
                        }
                        return
                    }
                    // Playable as-is: a smaller copy isn't possible, so take the original.
                    if let i = index(of: id) { records[i].lastError = "Server can't convert; downloading the original file." }
                }
            }

            let url = api.url(partKey, query: [URLQueryItem(name: "download", value: "1")], includeToken: true)
            let probe = try await MediaProbe.probe(url, token: api.token)
            guard ServerDirectory.shared.authorizes(api), let i = index(of: id), records[i].state == .queued else { return }
            records[i].source = .file(partKey: partKey)
            records[i].isConverted = false
            records[i].fileExtension = Self.fileExtension(part: part, media: media)
            try beginDownloading(i, totalBytes: probe.totalBytes, acceptsRanges: probe.acceptsRanges)
        } catch {
            guard ServerDirectory.shared.authorizes(api) else { return }
            handlePreparationError(id, error)
        }
    }

    private func pollConversion(_ id: String) async {
        defer { preparing.remove(id); pump() }
        while let i = index(of: id), records[i].state == .preparing {
            guard case .queue(let q, let item)? = records[i].source, let api = ServerDirectory.shared.api(for: records[i].serverID) else {
                postponePreparation(id, message: "Server unavailable")
                return
            }
            do {
                guard let status = try await ServerConversion.status(api: api, queueID: q, itemID: item) else {
                    throw PlexError.http(404, nil)
                }
                guard ServerDirectory.shared.authorizes(api), let i = index(of: id), records[i].state == .preparing else { return }
                switch status.status {
                case "available":
                    let url = api.url(ServerConversion.mediaPath(queueID: q, itemID: item), includeToken: true)
                    let probe = try await MediaProbe.probe(url, token: api.token)
                    guard ServerDirectory.shared.authorizes(api), let i = index(of: id), records[i].state == .preparing else { return }
                    records[i].preparationProgress = 1
                    try beginDownloading(i, totalBytes: probe.totalBytes, acceptsRanges: probe.acceptsRanges)
                    return
                case "error":
                    records[i].prepareAttempts += 1
                    if records[i].prepareAttempts > 3 {
                        records[i].state = .failed
                        records[i].lastError = status.error ?? "The server couldn't convert this item."
                        saveNow()
                        return
                    }
                    try await ServerConversion.restart(api: api, queueID: q, itemID: item)
                case "expired":
                    try await ServerConversion.restart(api: api, queueID: q, itemID: item)
                default:
                    if let p = status.transcodeSession?.progress {
                        records[i].preparationProgress = min(1, max(0, p > 1 ? p / 100 : p))
                    }
                }
            } catch MediaProbe.ProbeError.notReady(let after) {
                try? await Task.sleep(for: .seconds(max(3, after ?? 5)))
                continue
            } catch PlexError.http(404, _) {
                guard ServerDirectory.shared.authorizes(api) else { return }
                if let i = index(of: id) { resetForPreparation(i, note: nil) }
                return
            } catch {
                guard ServerDirectory.shared.authorizes(api) else { return }
                handlePreparationError(id, error)
                return
            }
            // The server keeps converting while we're suspended; keep polling while
            // iOS still gives us background time, then rely on scheduled probes.
            if UIApplication.shared.applicationState == .background && UIApplication.shared.backgroundTimeRemaining < 8 {
                retryAt[prepKey(id)] = Date().addingTimeInterval(30)
                return
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func beginDownloading(_ index0: Int, totalBytes: Int64, acceptsRanges: Bool) throws {
        let id = records[index0].id
        cancelProbe(id)
        defer {
            if !records.contains(where: { $0.state == .preparing }) { endConversionBackgroundTask() }
        }
        guard makeRoom(for: id, bytes: totalBytes), let i = index(of: id) else { return }
        if let free = DownloadStore.availableCapacity() {
            let needed = totalBytes + 200 * 1024 * 1024 - records[i].downloadedSegmentBytes
            if free < needed {
                records[i].state = .paused
                records[i].lastError = "Not enough storage: needs \(Fmt.bytes(totalBytes)), \(Fmt.bytes(free)) free."
                saveNow()
                return
            }
        }
        DownloadStore.removeSegmentFiles(for: id)
        records[i].totalBytes = totalBytes
        records[i].segments = SegmentPlanner.plan(totalBytes: totalBytes, supportsRanges: acceptsRanges)
        records[i].assembledSegments = 0
        records[i].state = .downloading
        retryAt[prepKey(id)] = nil
        saveNow()
    }

    private func handlePreparationError(_ id: String, _ error: Error) {
        guard let i = index(of: id) else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            let kind = SegmentPlanner.classify(error)
            if kind == .unreachableHost { resolveEndpoint(serverID: records[i].serverID) }
            postponePreparation(id, message: NetworkMonitor.shared.isConnected ? "Can't reach server – retrying" : "Waiting for network")
            return
        }
        if case PlexError.http(let code, _) = error, code == 401 || code == 403 {
            records[i].state = .failed
            records[i].lastError = "The server refused access. Sign in again, then retry."
            saveNow()
            return
        }
        records[i].prepareAttempts += 1
        if records[i].prepareAttempts >= 6 {
            records[i].state = .failed
            records[i].lastError = error.localizedDescription
            saveNow()
        } else {
            postponePreparation(id, message: error.localizedDescription)
        }
    }

    private func postponePreparation(_ id: String, message: String) {
        guard let i = index(of: id) else { return }
        records[i].lastError = message
        let attempts = records[i].prepareAttempts
        retryAt[prepKey(id)] = Date().addingTimeInterval(SegmentPlanner.backoff(attempts: max(2, attempts + 2)))
        scheduleSave()
    }

    // MARK: - Assembly

    private func startAssembly(_ id: String) {
        guard !assembling.contains(id), let i = index(of: id), let total = records[i].totalBytes else { return }
        assembling.insert(id)
        records[i].state = .assembling
        saveNow()
        let segments = records[i].segments
        let ext = records[i].fileExtension
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "assemble-\(id)")

        Task.detached(priority: .utility) {
            let result = Result { try Assembler.assemble(id: id, segments: segments, totalBytes: total, ext: ext) }
            await MainActor.run {
                DownloadManager.shared.finishAssembly(id, result: result)
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    private func finishAssembly(_ id: String, result: Result<String, Error>) {
        assembling.remove(id)
        guard let i = index(of: id) else {
            DownloadStore.removeFiles(for: id)
            return
        }
        switch result {
        case .success(let name):
            assemblyFailures[id] = nil
            retryAt[asmKey(id)] = nil
            records[i].fileName = name
            records[i].state = .completed
            records[i].completedAt = Date()
            records[i].segments = []
            records[i].lastError = nil
            liveBytes[id] = records[i].totalBytes
        case .failure(let error):
            // Re-download whatever isn't safely on disk, keep everything that is.
            let assembled = Assembler.assembledCount(id: id)
            let finalExists = FileManager.default.fileExists(atPath: DownloadStore.mediaURL(id: id, ext: records[i].fileExtension).path)
            if !finalExists { try? FileManager.default.removeItem(at: Assembler.sidecarURL(id: id)) }
            if case Assembler.AssemblyError.sizeMismatch = error {
                // Corrupt result: start over cleanly rather than ship a broken file.
                try? FileManager.default.removeItem(at: DownloadStore.mediaURL(id: id, ext: records[i].fileExtension))
                resetForPreparation(i, note: "Verification failed; downloading again.")
                return
            }
            for j in records[i].segments.indices {
                let seg = records[i].segments[j]
                let onDisk = DownloadStore.fileSize(DownloadStore.segmentURL(id: id, index: seg.index)) == seg.length
                let alreadyMerged = finalExists && j < assembled
                records[i].segments[j].done = onDisk || alreadyMerged
            }
            if SegmentPlanner.classify(error) == .storage {
                // Disk full: retrying can't help until space is freed, so wait for the person.
                records[i].state = .paused
                records[i].lastError = "Not enough storage space to finish. Free up space and resume."
                break
            }
            records[i].state = .downloading
            records[i].lastError = nil
            if records[i].segments.allSatisfy(\.done) {
                // Every piece is still here, so the same failure would repeat at once: back off.
                let failures = (assemblyFailures[id] ?? 0) + 1
                assemblyFailures[id] = failures
                if failures >= 5 {
                    records[i].state = .failed
                    records[i].lastError = "Couldn't finish saving the file: " + error.localizedDescription
                    assemblyFailures[id] = nil
                } else {
                    retryAt[asmKey(id)] = Date().addingTimeInterval(SegmentPlanner.backoff(attempts: failures + 2))
                }
            }
        }
        saveNow()
        pump()
    }

    // MARK: - Network & endpoints

    private func networkChanged(connected: Bool) {
        guard connected else { return }
        // Connectivity is back (or changed interface): retry immediately.
        retryAt.removeAll()
        let servers = Set(records.filter { [.queued, .preparing, .downloading].contains($0.state) }.map(\.serverID))
        servers.forEach { resolveEndpoint(serverID: $0) }
        pump()
        Task { await syncOfflineProgress() }
    }

    /// Finds the best current address for a server; if it changed, restarts
    /// segments that were bound to the old (now unreachable) address.
    func resolveEndpoint(serverID: String) {
        guard !resolving.contains(serverID), let server = ServerDirectory.shared.server(id: serverID) else { return }
        resolving.insert(serverID)
        let before = ServerDirectory.shared.endpointURI(for: serverID)
        Task {
            let uri = try? await ConnectionResolver.resolve(server)
            resolving.remove(serverID)
            if let uri, uri != before, let api = ServerDirectory.shared.api(for: serverID) {
                restartAllTasks(serverID: serverID, unlessBase: api.baseURL.absoluteString)
            }
            for (key, _) in retryAt where records.contains(where: { $0.serverID == serverID && key.hasPrefix($0.id) }) {
                retryAt[key] = nil
            }
            pump()
        }
    }

    // MARK: - Power policy ("only while charging")

    private func updatePowerState() {
        let state = UIDevice.current.batteryState
        let powered = state == .charging || state == .full || state == .unknown
        guard powered != isOnPower else { return }
        isOnPower = powered
        powerPolicyChanged()
    }

    private func powerPolicyChanged() {
        if transfersAllowed {
            pump()
        } else {
            // Unplugged: stop transfers but keep every finished segment.
            for id in Array(tasks.keys) { cancelTasks(for: id, keepResumeData: true) }
        }
    }

    /// Lets iOS launch us when the phone is plugged in (typically overnight).
    func scheduleChargingTask() {
        guard chargingOnly, !isOnPower,
              records.contains(where: { $0.state == .downloading || $0.state == .queued || $0.state == .preparing }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.chargingTaskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleChargingTask(_ task: BGProcessingTask) {
        isOnPower = true
        queueEverything = true
        retryAt.removeAll()
        pump()
        let work = Task {
            await SmartDownloads.shared.refresh()
            try? await Task.sleep(for: .seconds(25))
            saveNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Storage limit

    private var capBytes: Int64? { storageCapGB > 0 ? Int64(storageCapGB) * 1_073_741_824 : nil }

    /// Space already taken or claimed by other downloads.
    private func committedBytes(excluding id: String) -> Int64 {
        records.reduce(0) { sum, r in
            guard r.id != id, let total = r.totalBytes else { return sum }
            switch r.state {
            case .completed, .downloading, .assembling: return sum + total
            case .paused, .failed: return sum + r.downloadedSegmentBytes
            default: return sum
            }
        }
    }

    var usedByDownloads: Int64 { committedBytes(excluding: "") }

    private func isFullyWatched(_ r: DownloadRecord) -> Bool {
        (r.metadata.viewCount ?? 0) > 0 && (r.metadata.viewOffset ?? 0) == 0
    }

    /// Ensures `bytes` fits under the storage limit, removing watched downloads if
    /// allowed. Returns false (and parks the record) when it can't.
    private func makeRoom(for id: String, bytes: Int64) -> Bool {
        guard let cap = capBytes else { return true }
        var overBy = committedBytes(excluding: id) + bytes - cap
        if overBy > 0, freeSpaceWithWatched {
            // Songs in a downloaded playlist stay: removing them would only bring them back on the next update.
            let inPlaylists = Set(collections.flatMap(\.itemIDs))
            let candidates = records
                .filter { $0.id != id && $0.state == .completed && !$0.hasPendingProgress && isFullyWatched($0) && !inPlaylists.contains($0.id) }
                .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            // Only remove anything when that actually makes enough room.
            if candidates.reduce(Int64(0), { $0 + ($1.totalBytes ?? 0) }) >= overBy {
                bulkUpdate = true
                for r in candidates where overBy > 0 {
                    overBy -= r.totalBytes ?? 0
                    delete(r.id)
                }
                bulkUpdate = false
            }
        }
        guard overBy > 0, let i = index(of: id) else { return true }
        records[i].state = .paused
        records[i].waitingForSpace = true
        records[i].lastError = "Storage limit reached (\(storageCapGB) GB). Remove downloads or raise the limit in Settings."
        saveNow()
        return false
    }

    /// Something freed up space or the limit changed: retry parked downloads.
    private func resumeWaitingForSpace() {
        for r in records where r.waitingForSpace {
            if let i = index(of: r.id) { records[i].waitingForSpace = false }
            resume(r.id)
        }
    }

    // MARK: - Offline subtitles

    /// Saves every sidecar text subtitle next to the download (as SRT).
    private func saveSubtitles(id: String, part: PlexPart, api: PlexServerAPI) {
        let streams = part.subtitleStreams.filter(\.isSidecarText)
        guard !streams.isEmpty else { return }
        Task {
            var files: [DownloadRecord.SubtitleFile] = []
            let dir = DownloadStore.ensureDirectory(for: id)
            for s in streams {
                guard let data = try? await api.subtitleFile(streamID: s.id) else { continue }
                let name = "sub_\(s.id).srt"
                guard (try? data.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { continue }
                files.append(.init(streamID: s.id, label: s.label, fileName: name, selected: s.selected == true))
            }
            if let i = index(of: id), !files.isEmpty {
                records[i].subtitleFiles = files
                scheduleSave()
            }
        }
    }

    // MARK: - Background refresh (polls server conversions while suspended)

    func scheduleBackgroundRefresh() {
        guard records.contains(where: { $0.state == .preparing || $0.state == .queued }) || !SmartDownloads.shared.rules.isEmpty
                || collections.contains(where: \.keepsUpdated)
                || LiveTVStore.shared.needsBackgroundChecks else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        retryAt.removeAll()
        pump()
        let work = Task {
            await LiveTVStore.shared.backgroundCheck()
            await SmartDownloads.shared.refresh()
            await self.syncPlaylistDownloads()
            try? await Task.sleep(for: .seconds(20))
            saveNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Progress & persistence

    private func publishProgress() {
        let snapshot = delegate.progressSnapshot()
        var next: [String: Int64] = [:]
        for rec in records where rec.state == .downloading || rec.state == .assembling {
            let inflight = snapshot[rec.id]?.values.reduce(0, +) ?? 0
            next[rec.id] = rec.downloadedSegmentBytes + inflight
        }
        for rec in records where rec.state == .paused || rec.state == .failed {
            next[rec.id] = rec.downloadedSegmentBytes
        }
        if next != liveBytes { liveBytes = next }
    }

    func saveNow() {
        saveScheduled = false
        guard indexReadable else { return }
        DownloadStore.save(records)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            if saveScheduled { saveNow() }
        }
    }

    private func clearRetries(for id: String) {
        for key in retryAt.keys where key.hasPrefix(id + "|") { retryAt[key] = nil }
    }

    private func index(of id: String) -> Int? {
        if let i = indexByID[id], i < records.count, records[i].id == id { return i }
        return nil
    }
    private func segKey(_ id: String, _ index: Int) -> String { "\(id)|\(index)" }
    private func prepKey(_ id: String) -> String { "\(id)|prep" }
    private func asmKey(_ id: String) -> String { "\(id)|asm" }

    private static func fileExtension(part: PlexPart, media: PlexMedia) -> String {
        if let file = part.file, let ext = file.split(separator: ".").last, ext.count <= 5 { return String(ext).lowercased() }
        return (part.container ?? media.container ?? "mp4").lowercased()
    }

    private func saveArtwork(for rec: DownloadRecord) {
        guard let api = ServerDirectory.shared.api(for: rec.serverID) else { return }
        let jobs: [(String?, Int, Int, URL)] = [
            (rec.metadata.posterThumb, 400, 600, DownloadStore.posterURL(id: rec.id)),
            (rec.metadata.kind == .episode ? rec.metadata.thumb : rec.metadata.backdrop, 960, 540, DownloadStore.artURL(id: rec.id)),
        ]
        for (path, w, h, dest) in jobs {
            guard let url = api.imageURL(path, width: w, height: h) else { continue }
            let id = rec.id
            Task.detached(priority: .background) {
                DownloadStore.ensureDirectory(for: id)
                if let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 {
                    try? data.write(to: dest, options: .atomic)
                }
            }
        }
    }
}
