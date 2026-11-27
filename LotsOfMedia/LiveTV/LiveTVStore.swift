import Foundation
import Observation
import UserNotifications

/// Guide, channels and recordings for the selected server's DVR.
@MainActor
@Observable
final class LiveTVStore {
    static let shared = LiveTVStore()

    /// How much guide is fetched at a time, and how far ahead it can go.
    static let chunk: TimeInterval = 4 * 3600
    static let maxAhead: TimeInterval = 24 * 3600

    var favoritesOnly = false { didSet { if favoritesOnly { collectionFilter = nil } } }
    var channelQuery = ""
    /// Shows only the channels in this collection.
    var collectionFilter: String? { didSet { if collectionFilter != nil { favoritesOnly = false } } }
    /// Shows only channels with this kind of program on (now and the next few hours).
    var category: GuideCategory?
    private(set) var favoriteIDs: Set<String> = []
    private(set) var lastChannelID: String?
    private(set) var recentChannelIDs: [String] = []
    var visibleChannels: [LiveChannel] {
        let collection = collectionFilter.map { Set(channels(inCollection: $0)) }
        let from = Date(), to = Date().addingTimeInterval(4 * 3600)
        return channels.filter { ch in
            (!favoritesOnly || favoriteIDs.contains(ch.id))
                && (collection?.contains(ch.id) ?? true)
                && (channelQuery.isEmpty || (ch.number + " " + ch.title).localizedCaseInsensitiveContains(channelQuery))
                && (category.map { c in (airings[ch.id] ?? []).contains { $0.endsAt > from && $0.beginsAt < to && c.matches($0) } } ?? true)
        }
    }

    // MARK: Channel collections

    /// Your own named groups of channels ("Kids", "Sports"), saved per server on this device.
    struct ChannelCollection: Codable, Hashable { var name: String; var channelIDs: [String] }
    private(set) var collections: [ChannelCollection] = []
    var collectionNames: [String] { collections.map(\.name) }

    func channels(inCollection name: String) -> [String] { collections.first { $0.name == name }?.channelIDs ?? [] }

    func createCollection(_ name: String, with channelID: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            collections.append(ChannelCollection(name: name, channelIDs: []))
        }
        if let channelID, !channels(inCollection: name).contains(channelID) { toggle(channelID, inCollection: name) } else { saveCollections() }
    }

    func deleteCollection(_ name: String) {
        collections.removeAll { $0.name == name }
        if collectionFilter == name { collectionFilter = nil }
        saveCollections()
    }

    func toggle(_ channelID: String, inCollection name: String) {
        guard let i = collections.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        if let j = collections[i].channelIDs.firstIndex(of: channelID) { collections[i].channelIDs.remove(at: j) }
        else { collections[i].channelIDs.append(channelID) }
        saveCollections()
    }

    private static func collectionsKey(_ serverID: String) -> String { "live.collections." + serverID }

    /// Recent channels and the last channel are each profile's own (favorites and collections are
    /// the household's): keyed by server and the profile in use. Before a profile has its own,
    /// it starts from what was saved for the whole server by older versions.
    nonisolated static func profileKey(_ prefix: String, _ serverID: String, profile: String? = UserDefaults.standard.string(forKey: "currentUserUUID")) -> String {
        guard let profile else { return prefix + serverID }
        return prefix + serverID + "|" + profile
    }
    private static func recentChannels(serverID: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: profileKey("live.recent.", serverID))
            ?? UserDefaults.standard.stringArray(forKey: "live.recent." + serverID) ?? []
    }
    private static func lastChannel(serverID: String) -> String? {
        UserDefaults.standard.string(forKey: profileKey("live.lastChannel.", serverID))
            ?? UserDefaults.standard.string(forKey: "live.lastChannel." + serverID)
    }
    private func loadCollections(serverID: String) {
        collections = UserDefaults.standard.data(forKey: Self.collectionsKey(serverID))
            .flatMap { try? JSONDecoder().decode([ChannelCollection].self, from: $0) } ?? []
    }
    private func saveCollections() {
        guard let serverID, let data = try? JSONEncoder().encode(collections) else { return }
        UserDefaults.standard.set(data, forKey: Self.collectionsKey(serverID))
    }
    var lastChannel: LiveChannel? { channels.first { $0.id == lastChannelID } }
    func toggleFavorite(_ channel: LiveChannel) {
        if !favoriteIDs.insert(channel.id).inserted { favoriteIDs.remove(channel.id) }
        if let serverID { UserDefaults.standard.set(Array(favoriteIDs), forKey: "live.favorites." + serverID) }
    }
    func rememberChannel(_ id: String, serverID: String) {
        UserDefaults.standard.set(id, forKey: Self.profileKey("live.lastChannel.", serverID))
        var recent = Self.recentChannels(serverID: serverID)
        recent.removeAll { $0 == id }; recent.insert(id, at: 0); recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: Self.profileKey("live.recent.", serverID))
        if self.serverID == serverID { lastChannelID = id; recentChannelIDs = recent }
    }
    func conflictMessage(for airing: LiveAiring) -> String? {
        guard let tuners = dvr?.tunerCount, tuners > 0 else { return nil }
        let others = scheduled.filter { ["scheduled", "inprogress"].contains($0.status) }.compactMap(\.airing)
        guard RecordingConflict.hasConflict(airing, scheduled: others, tuners: tuners) else { return nil }
        return "Potential recording conflict: all \(tuners) tuners are scheduled during this airing. Check Other Airings before recording. Live viewing also uses a tuner."
    }

    private(set) var dvr: LiveDVR?
    private(set) var channels: [LiveChannel] = []
    private(set) var airings: [String: [LiveAiring]] = [:]     // by channel ID, sorted by start
    private(set) var guideStart = LiveTVStore.slot(containing: Date())
    private(set) var loadedUntil = Date.distantPast
    private(set) var rules: [LiveSubscription] = []
    private(set) var scheduled: [ScheduledRecording] = []
    private(set) var isLoadingGuide = false
    private(set) var error: String?
    private(set) var serverID: String?

    /// True once a DVR is found, and right away at launch for a server known to
    /// have one, so the Live TV tab doesn't pop in a few seconds later.
    var isAvailable: Bool {
        if dvr != nil { return true }
        #if DEBUG
        if isSample { return true }
        #endif
        guard let id = serverID ?? UserDefaults.standard.string(forKey: "selectedServerID") else { return false }
        return UserDefaults.standard.bool(forKey: Self.hasDVRKey(id))
    }

    private static func hasDVRKey(_ serverID: String) -> String { "liveTV.hasDVR." + serverID }

    private var loadingMore = false
    private var guideRevision = UUID()
    private var contextToken: String?
    private var contextGeneration = UUID()

    private init() {
        tracked = (Self.load([String: Tracked].self, "live-tracked.json") ?? [:]).filter { $0.value.serverID != nil }
        let saved = Self.load([String: AutoDownloadPlan].self, "live-autodownload.json") ?? [:]
        autoDownloads = [:]
        for (key, var plan) in saved {
            let guid = plan.guid ?? key
            plan.guid = guid
            autoDownloads[Self.scopedKey(serverID: plan.serverID, id: guid)] = plan
        }
    }

    /// Start of the half hour containing `date` (guide columns begin on :00 and :30).
    nonisolated static func slot(containing date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 1800))
    }

    // MARK: Loading

    /// Checks the server for a DVR and loads channels, the guide and recordings.
    func clearSession() {
        contextGeneration = UUID()
        serverID = nil; contextToken = nil
        favoriteIDs = []; lastChannelID = nil; recentChannelIDs = []; favoritesOnly = false; channelQuery = ""
        collections = []; collectionFilter = nil; category = nil
        dvr = nil; channels = []; airings = [:]; rules = []; scheduled = []
        loadedUntil = .distantPast; error = nil; isLoadingGuide = false; loadingMore = false
    }

    private func matches(_ api: PlexServerAPI) -> Bool { serverID == api.serverID && contextToken == api.token }

    func refresh(api: PlexServerAPI, force: Bool = false) async {
        #if DEBUG
        if isSample { return }
        #endif
        if !matches(api) {
            clearSession()
            contextToken = api.token
            serverID = api.serverID
            favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "live.favorites." + api.serverID) ?? [])
            loadCollections(serverID: api.serverID)
            recentChannelIDs = Self.recentChannels(serverID: api.serverID)
            lastChannelID = Self.lastChannel(serverID: api.serverID)
            dvr = nil; channels = []; airings = [:]; rules = []; scheduled = []; loadedUntil = .distantPast
        }
        let generation = contextGeneration
        error = nil
        do {
            let found = try await api.liveDVRs().first(where: { !$0.epgIdentifier.isEmpty })
            guard generation == contextGeneration, !Task.isCancelled else { return }
            guard let found else {
                dvr = nil
                channels = []
                airings = [:]
                loadedUntil = .distantPast
                guideRevision = UUID()
                UserDefaults.standard.set(false, forKey: Self.hasDVRKey(api.serverID))
                return
            }
            dvr = found
            UserDefaults.standard.set(true, forKey: Self.hasDVRKey(api.serverID))
            if channels.isEmpty || force {
                let loaded = try await api.liveChannels(epg: found.epgIdentifier)
                guard generation == contextGeneration, !Task.isCancelled else { return }
                channels = loaded
            }
            if channels.isEmpty {
                error = "Your server's DVR has no channels."
                return
            }
            // A stale guide (left open for a while) restarts at the current half hour.
            let currentSlot = Self.slot(containing: Date())
            if force || currentSlot != guideStart || loadedUntil < Date().addingTimeInterval(3600) {
                await reloadGuide(api: api, from: currentSlot)
            }
        } catch {
            guard generation == contextGeneration, !Task.isCancelled else { return }
            // Keep the remembered answer; the tab shows this error and pull-to-refresh retries.
            self.error = error.localizedDescription
        }
        guard generation == contextGeneration, !Task.isCancelled else { return }
        await refreshRecordings(api: api)
    }

    private func reloadGuide(api: PlexServerAPI, from start: Date) async {
        guard let dvr, !isLoadingGuide else { return }
        let generation = contextGeneration
        isLoadingGuide = true
        defer { if generation == contextGeneration { isLoadingGuide = false } }
        let end = start.addingTimeInterval(Self.chunk)
        do {
            let list = try await api.liveGrid(epg: dvr.epgIdentifier, from: start, to: end)
            guard generation == contextGeneration, !Task.isCancelled else { return }
            guideRevision = UUID()
            guideStart = start
            airings = Self.group(list)
            loadedUntil = end
        } catch {
            guard generation == contextGeneration, !Task.isCancelled else { return }
            self.error = "Couldn't load the guide. \(error.localizedDescription)"
        }
    }

    /// Extends the guide to the right as the user scrolls.
    func loadMore(api: PlexServerAPI) async {
        guard matches(api), let dvr, loadedUntil != .distantPast, !isLoadingGuide, !loadingMore, loadedUntil < guideStart.addingTimeInterval(Self.maxAhead) else { return }
        let generation = contextGeneration
        loadingMore = true
        defer { if generation == contextGeneration { loadingMore = false } }
        let revision = guideRevision
        let from = loadedUntil
        let end = from.addingTimeInterval(Self.chunk)
        guard let list = try? await api.liveGrid(epg: dvr.epgIdentifier, from: from, to: end) else { return }
        guard generation == contextGeneration, revision == guideRevision, !Task.isCancelled else { return }
        var merged = airings
        for (ch, items) in Self.group(list) {
            var known = Set((merged[ch] ?? []).map(\.id))
            var row = merged[ch] ?? []
            for a in items where known.insert(a.id).inserted { row.append(a) }
            merged[ch] = row.sorted { $0.beginsAt < $1.beginsAt }
        }
        airings = merged
        loadedUntil = end
    }

    private static func group(_ list: [LiveAiring]) -> [String: [LiveAiring]] {
        Dictionary(grouping: list, by: \.channelID).mapValues { row in
            var seen = Set<String>()
            return row.sorted { $0.beginsAt < $1.beginsAt }.filter { seen.insert($0.id).inserted }
        }
    }

    // MARK: Lookups

    func channel(_ id: String) -> LiveChannel? { channels.first { $0.id == id } }

    func current(on channelID: String, at date: Date = Date()) -> LiveAiring? {
        airings[channelID]?.first { $0.isOnAir(at: date) }
    }

    func next(on channelID: String, after date: Date = Date()) -> LiveAiring? {
        airings[channelID]?.first { $0.beginsAt > date }
    }

    enum RecordState: Equatable { case none, scheduled, recording, series }

    func recordState(_ airing: LiveAiring) -> RecordState {
        if let grab = scheduled.first(where: { $0.airing?.channelID == airing.channelID && $0.airing?.beginsAt == airing.beginsAt }) {
            return grab.isRecording ? .recording : .scheduled
        }
        if let show = airing.grandparentGuid, rules.contains(where: { $0.isSeries && $0.guid == show }) { return .series }
        return .none
    }

    /// The rule that schedules this exact airing, if it's a one-off.
    func oneShotRule(for airing: LiveAiring) -> LiveSubscription? {
        rules.first { !$0.isSeries && $0.upcoming.contains { $0.airing?.beginsAt == airing.beginsAt && $0.airing?.channelID == airing.channelID } }
            ?? rules.first { !$0.isSeries && $0.guid != nil && $0.guid == airing.guid }
    }

    func seriesRule(for airing: LiveAiring) -> LiveSubscription? {
        guard let show = airing.grandparentGuid else { return nil }
        return rules.first { $0.isSeries && $0.guid == show }
    }

    // MARK: Recording

    func refreshRecordings(api: PlexServerAPI) async {
        if let r = try? await api.recordingRules(), matches(api), !Task.isCancelled { rules = r }
        if let list = try? await api.scheduledRecordings() {
            guard !Task.isCancelled, ServerDirectory.shared.authorizes(api) else { return }
            let sorted = list.sorted { ($0.airing?.beginsAt ?? .distantFuture) < ($1.airing?.beginsAt ?? .distantFuture) }
            if matches(api) { scheduled = sorted }
            noteRecordingProgress(sorted, serverID: api.serverID)
        }
        guard !Task.isCancelled, ServerDirectory.shared.authorizes(api) else { return }
        await setUpAutoDownloads(api: api)
    }

    func record(_ option: RecordingOption, prefs: [String: String], airing: LiveAiring, autoDownload: Int?, api: PlexServerAPI) async throws {
        var location: String?
        if option.targetSectionLocationID == nil, let section = option.targetLibrarySectionID {
            location = await api.sectionLocationID(section)
        }
        try await api.createRecording(option, prefs: prefs, locationID: location)
        Haptics.success()
        if let keep = autoDownload, let show = airing.grandparentGuid ?? airing.guid {
            autoDownloads[Self.scopedKey(serverID: api.serverID, id: show)] = AutoDownloadPlan(serverID: api.serverID, title: airing.showTitle, thumb: airing.poster, keep: keep, guid: show)
            persistAutoDownloads()
        }
        Notifier.requestPermission()
        await refreshRecordings(api: api)
    }

    func cancel(_ rule: LiveSubscription, api: PlexServerAPI) async throws {
        try await api.deleteRecording(id: rule.id)
        if let guid = rule.guid, autoDownloads.removeValue(forKey: Self.scopedKey(serverID: api.serverID, id: guid)) != nil { persistAutoDownloads() }
        await refreshRecordings(api: api)
    }

    func update(_ rule: LiveSubscription, prefs: [String: String], api: PlexServerAPI) async throws {
        try await api.updateRecording(id: rule.id, prefs: prefs)
        await refreshRecordings(api: api)
    }

    // MARK: Finished-recording alerts

    /// Recordings we've seen scheduled, so we can tell when one finishes.
    struct Tracked: Codable { var title: String; var endsAt: Date; var failed: Bool; var serverID: String? }
    private var tracked: [String: Tracked]

    nonisolated static func scopedKey(serverID: String, id: String) -> String {
        "\(serverID.utf8.count):\(serverID)\(id)"
    }

    nonisolated static func missingRecordings(_ tracked: [String: Tracked], current: Set<String>, serverID: String) -> [String] {
        tracked.filter { $0.value.serverID == serverID && !current.contains($0.key) }.map(\.key)
    }

    private func noteRecordingProgress(_ recordings: [ScheduledRecording], serverID: String) {
        let now = Date()
        var current = Set<String>()
        for grab in recordings {
            guard let a = grab.airing else { continue }
            let id = Self.scopedKey(serverID: serverID, id: grab.id)
            current.insert(id)
            let title = a.isEpisode ? [a.showTitle, a.episodeLine].compactMap { $0 }.joined(separator: " · ") : a.title
            tracked[id] = Tracked(title: title, endsAt: a.endsAt, failed: grab.status == "error", serverID: serverID)
        }
        for id in Self.missingRecordings(tracked, current: current, serverID: serverID) {
            guard let t = tracked[id] else { continue }
            // Gone from the schedule after its end time: it finished. Gone earlier: cancelled.
            if now >= t.endsAt.addingTimeInterval(-120) {
                Notifier.post(id: "recording-\(id)",
                              title: t.failed ? "Recording failed" : "Recording finished",
                              body: t.failed ? "\(t.title) couldn't be recorded." : "\(t.title) is ready to watch.")
            }
            tracked.removeValue(forKey: id)
        }
        Self.save(tracked, "live-tracked.json")
    }

    var needsBackgroundChecks: Bool { !tracked.isEmpty || !autoDownloads.isEmpty }

    /// Background refresh: notices finished recordings and new episodes to download.
    func backgroundCheck() async {
        guard NetworkMonitor.shared.isConnected else { return }
        var ids = Set(tracked.values.compactMap(\.serverID) + autoDownloads.values.map(\.serverID))
        if let selected = UserDefaults.standard.string(forKey: "selectedServerID") { ids.insert(selected) }
        for id in ids {
            guard !Task.isCancelled else { return }
            if let api = ServerDirectory.shared.api(for: id) { await refreshRecordings(api: api) }
        }
    }

    // MARK: Downloading recordings

    /// A series whose recordings should be downloaded once the show reaches the library.
    struct AutoDownloadPlan: Codable { var serverID: String; var title: String; var thumb: String?; var keep: Int; var guid: String? }
    private(set) var autoDownloads: [String: AutoDownloadPlan]

    private func setUpAutoDownloads(api: PlexServerAPI) async {
        for (key, plan) in autoDownloads where plan.serverID == api.serverID {
            guard let guid = plan.guid else { continue }
            // The first recording creates the show in the library; then Smart Downloads takes over.
            guard let show = await api.libraryShow(guid: guid) else { continue }
            guard !Task.isCancelled, ServerDirectory.shared.authorizes(api), autoDownloads[key] != nil else { return }
            #if os(iOS)
            SmartDownloads.shared.set(SmartDownloadRule(serverID: plan.serverID, showRatingKey: show.ratingKey, showTitle: show.title,
                                                        showThumb: show.thumb, keepCount: plan.keep, deleteWatched: true))
            #endif
            autoDownloads.removeValue(forKey: key)
            persistAutoDownloads()
        }
    }

    func autoDownloadKeep(for showGuid: String?) -> Int? {
        guard let showGuid, let serverID else { return nil }
        return autoDownloads[Self.scopedKey(serverID: serverID, id: showGuid)]?.keep
    }

    private func persistAutoDownloads() { Self.save(autoDownloads, "live-autodownload.json") }

    #if DEBUG
    // MARK: Sample guide (development and screenshots only)

    /// True while the made-up guide below is shown instead of a server's.
    private(set) var isSample = false

    /// Fills the store with fictional channels and a realistic schedule, for servers without a DVR.
    func loadSample(serverID: String) {
        let names = ["Metro News", "City Sports", "Kids Zone", "Classic Cinema", "Nature HD", "Laugh Track",
                     "Food Network East", "History Now", "Sports Extra", "Movie Vault", "Science Channel One", "Family Time",
                     "World News 24", "Home & Garden", "Music Live", "Retro TV"]
        let shows: [String: [(String, String, Int)]] = [   // title, genre, minutes
            "News": [("Morning Report", "News", 60), ("Midday Update", "News", 30), ("Evening News", "News", 30), ("Newsnight", "News", 60)],
            "Sports": [("Game Night Live", "Sports", 180), ("Sports Desk", "Sports", 30), ("College Football", "Sports", 210), ("Highlights", "Sports", 30)],
            "Kids": [("Space Pups", "Children", 30), ("The Doodle Club", "Animation", 30), ("Wild Wonders", "Children", 30), ("Robot Pals", "Animation", 30)],
            "Movies": [("The Long Road", "Drama", 120), ("Midnight Heist", "Action", 110), ("Summer in Paris", "Romance", 100), ("Starfall", "Science Fiction", 130)],
            "Nature": [("Ocean Giants", "Documentary", 60), ("Desert Life", "Documentary", 60), ("Wild Planet", "Documentary", 30)],
            "Comedy": [("The Neighbors", "Comedy", 30), ("Office Hours", "Comedy", 30), ("Stand-Up Tonight", "Comedy", 60)],
        ]
        let kinds = ["News", "Sports", "Kids", "Movies", "Nature", "Comedy", "Nature", "Nature", "Sports", "Movies", "Nature", "Kids",
                     "News", "Comedy", "Comedy", "Comedy"]
        var channelJSON: [[String: Any]] = []
        var airingJSON: [[String: Any]] = []
        let start = Self.slot(containing: Date()).addingTimeInterval(-3 * 3600)
        for (i, name) in names.enumerated() {
            let id = "sample-\(i)"
            let number = "\(i * 2 + 2).1"
            channelJSON.append(["id": id, "vcn": number, "title": name, "isHd": "1"])
            let list = shows[kinds[i]] ?? []
            var t = start
            var n = i
            while t < start.addingTimeInterval(12 * 3600) {
                let (title, genre, minutes) = list[n % list.count]
                let end = t.addingTimeInterval(TimeInterval(minutes * 60))
                let movie = kinds[i] == "Movies"
                airingJSON.append([
                    "ratingKey": "\(id)-\(n)", "guid": "sample://\(title)", "grandparentGuid": movie ? "" : "sample://show/\(title)",
                    "type": movie ? "movie" : "episode", "title": title, "grandparentTitle": movie ? "" : title,
                    "summary": "A sample listing for trying out the guide.", "Genre": [["tag": genre]],
                    "Media": [["beginsAt": Int(t.timeIntervalSince1970), "endsAt": Int(end.timeIntervalSince1970),
                               "channelIdentifier": id, "channelTitle": name, "channelVcn": number]],
                ])
                t = end
                n += 1
            }
        }
        let decoder = JSONDecoder()
        channels = channelJSON.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { try? decoder.decode(LiveChannel.self, from: $0) } }
        airings = Self.group(airingJSON.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { try? decoder.decode(LiveAiring.self, from: $0) } })
        guideStart = Self.slot(containing: Date())
        loadedUntil = start.addingTimeInterval(12 * 3600)
        self.serverID = serverID
        isSample = true
        error = nil
        UserDefaults.standard.set(true, forKey: Self.hasDVRKey(serverID))
        favoriteIDs = Set(UserDefaults.standard.stringArray(forKey: "live.favorites." + serverID) ?? [])
        loadCollections(serverID: serverID)
    }
    #endif

    // MARK: Persistence

    #if os(iOS)
    private static func url(_ name: String) -> URL { DownloadStore.root.deletingLastPathComponent().appendingPathComponent(name) }
    #else
    private static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }
    #endif
    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func save<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url(name), options: .atomic) }
    }
}

/// Local notifications (recording finished).
enum Notifier {
    static func requestPermission() {
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Apple TV can't show notification banners, so there this does nothing.
    static func post(id: String, title: String, body: String) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        #endif
    }
}


/// Half-open broadcast intervals: adjacent recordings don't compete for a tuner.
enum RecordingConflict {
    static func hasConflict(_ airing: LiveAiring, scheduled: [LiveAiring], tuners: Int) -> Bool {
        guard tuners > 0 else { return false }
        var seen = Set<String>()
        let overlaps = scheduled.filter { $0.id != airing.id && seen.insert($0.id).inserted && $0.beginsAt < airing.endsAt && $0.endsAt > airing.beginsAt }
        let points = [airing.beginsAt] + overlaps.map(\.beginsAt).filter { $0 >= airing.beginsAt }
        return points.contains { time in overlaps.filter { $0.beginsAt <= time && time < $0.endsAt }.count >= tuners }
    }
}
