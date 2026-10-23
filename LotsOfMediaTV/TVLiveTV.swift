import AVKit
import SwiftUI

/// Live TV & DVR (a Pro feature): a TV guide grid, what's on now, and recordings, with
/// favorite channels, your own channel collections and program categories.
/// Uses the same LiveTVStore (and filters) as the iPhone app.
struct TVLiveTVView: View {
    @Environment(TVSession.self) private var session
    @Environment(ProStore.self) private var store
    @State private var mode: Mode = .guide
    private var now: TVLiveNow { .shared }
    @FocusState private var windowFocused: Bool
    /// Back while the window is playing moves focus to it (if it doesn't have it already).
    private var focusWindowOnBack: (() -> Void)? {
        TVLiveBack.windowCanTakeFocus(playing: now.channel != nil, fullScreen: now.isFullScreen, windowFocused: windowFocused)
            ? { windowFocused = true } : nil
    }
    @State private var selected: LiveAiring?
    @Environment(\.scenePhase) private var scenePhase
    /// Bumped when the guide is stale (a new half hour since it was built): the grid is rebuilt
    /// at the current time, as switching tabs used to do.
    @State private var guideEpoch = 0
    @State private var guideSlot = LiveTVStore.slot(containing: Date())
    /// The program under focus in the guide or On Now; the preview band describes it.
    @State private var spotlight: LiveAiring?
    /// Finished recordings, found in the library from each recording rule.
    @State private var recorded: [PlexMetadata] = []
    @State private var newCollectionFor: LiveChannel?
    @State private var newCollectionName = ""
    private var live: LiveTVStore { .shared }

    enum Mode: String, CaseIterable, Identifiable {
        case guide = "Guide", onNow = "On Now", recordings = "Recordings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .guide: "square.grid.3x3.fill"
            case .onNow: "dot.radiowaves.left.and.right"
            case .recordings: "record.circle"
            }
        }
    }

    /// What the preview band shows: the focused program, else what's playing, else the first channel's.
    private var heroAiring: LiveAiring? {
        spotlight ?? now.channel.flatMap { live.current(on: $0.id) } ?? live.visibleChannels.first.flatMap { live.current(on: $0.id) }
    }

    var body: some View {
        Group {
            if !store.isUnlocked {
                ProPaywallView(feature: .liveTV, inline: true)
            } else if live.channels.isEmpty {
                if let error = live.error {
                    VStack(spacing: 20) {
                        Text("Live TV Unavailable").font(.title2.bold())
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await refresh(force: true) } }.buttonStyle(TVActionStyle())
                    }
                } else {
                    ProgressView("Loading the guide…")
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    // The selected program on the left, the playing channel's window on the right.
                    TVLiveHero(airing: heroAiring, focus: $windowFocused)
                    controlBar
                    switch mode {
                    case .guide:
                        TVGuideGrid(channels: live.visibleChannels, category: live.category,
                                    onAiring: { selected = $0 }, onWatch: { watch($0) },
                                    onFocusAiring: { if let a = $0 { spotlight = a } },
                                    backOverride: focusWindowOnBack,
                                    channelMenu: { channelMenu($0) })
                            .id(guideEpoch)
                    case .onNow: onNow
                    case .recordings:
                        TVPageScrollView { VStack(alignment: .leading, spacing: 16) { recordings }.padding(.vertical, 10) }
                            .task(id: live.rules.map(\.id)) { await loadRecorded() }
                    }
                }
                .padding(.horizontal, 60)
            }
        }
        .task(id: session.contentVersion) {
            await refresh(force: false)
            #if DEBUG
            showMiniSample()
            #endif
        }
        // Full screen live TV; Back returns here with the channel still playing in the preview window.
        .fullScreenCover(isPresented: Binding(get: { now.isFullScreen }, set: { now.isFullScreen = $0 })) { TVLiveFullScreen() }
        .onChange(of: mode) { spotlight = nil }
        // Back from the Home Screen, or out of full screen: bring the guide up to now.
        .onChange(of: scenePhase) { _, phase in if phase == .active { catchUpGuide() } }
        .onChange(of: now.isFullScreen) { was, isFull in if was && !isFull { catchUpGuide() } }
        .onExitCommand(perform: focusWindowOnBack)
        // Play/Pause on the remote returns to the playing channel.
        .onPlayPauseCommand { if now.channel != nil, !now.isFullScreen { now.isFullScreen = true } }
        .sheet(item: $selected) { airing in
            TVAiringDetail(airing: airing) { channel in selected = nil; watch(channel) }
        }
        .alert("New Collection", isPresented: Binding(get: { newCollectionFor != nil }, set: { if !$0 { newCollectionFor = nil } })) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                if let ch = newCollectionFor { live.createCollection(newCollectionName, with: ch.id) }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }

    private func watch(_ channel: LiveChannel) { now.watch(channel, session: session) }

    /// Reloads the guide if it's out of date, and rebuilds the grid at the current half hour.
    private func catchUpGuide() {
        let slot = LiveTVStore.slot(containing: Date())
        if slot != guideSlot {
            guideSlot = slot
            spotlight = nil
            guideEpoch += 1
        }
        Task { await refresh(force: false) }
    }

    /// What each recording rule has put in the library (shows and movies).
    private func loadRecorded() async {
        guard let api = session.api else { return }
        var found: [PlexMetadata] = []
        for rule in live.rules {
            guard let guid = rule.guid,
                  let item = try? await api.container("/library/all", query: [URLQueryItem(name: "guid", value: guid)]).metadata.first,
                  !found.contains(where: { $0.ratingKey == item.ratingKey }) else { continue }
            found.append(item)
        }
        recorded = found
    }

    #if DEBUG
    /// Development: `-tvMiniSample` shows the corner window for the first channel (sample guide has no tuner).
    private func showMiniSample() {
        guard ProcessInfo.processInfo.arguments.contains("-tvMiniSample"), now.channel == nil, let first = live.channels.first else { return }
        now.watch(first, session: session)
        now.isFullScreen = false
    }
    #endif

    private func refresh(force: Bool) async {
        guard store.isUnlocked, let api = session.api else { return }
        #if DEBUG
        // Development and screenshots: `-tvLiveSample` shows a made-up guide on servers without a DVR.
        if ProcessInfo.processInfo.arguments.contains("-tvLiveSample"), let id = session.selectedServer?.id ?? session.selectedServerID {
            if !live.isSample { live.loadSample(serverID: id) }
            return
        }
        #endif
        await live.refresh(api: api, force: force)
    }

    // MARK: Filters

    /// Guide · On Now · Recordings, then the channel filters and categories, in one row.
    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Mode.allCases) { m in
                    chip(m.rawValue, systemImage: m.systemImage, on: mode == m) { mode = m }
                }
                if mode != .recordings {
                    divider
                    chip("All Channels", systemImage: "square.grid.2x2", on: !live.favoritesOnly && live.collectionFilter == nil) {
                        live.favoritesOnly = false; live.collectionFilter = nil
                    }
                    chip("Favorites", systemImage: "star.fill", on: live.favoritesOnly) { live.favoritesOnly = true }
                    ForEach(live.collectionNames, id: \.self) { name in
                        chip(name, systemImage: "rectangle.stack", on: live.collectionFilter == name) { live.collectionFilter = name }
                            .contextMenu {
                                Button("Delete Collection", role: .destructive) { live.deleteCollection(name) }
                            }
                    }
                    divider
                    ForEach(GuideCategory.allCases) { c in
                        chip(c.rawValue, systemImage: c.systemImage, on: live.category == c) { live.category = live.category == c ? nil : c }
                    }
                }
            }
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private var divider: some View {
        Capsule().fill(.white.opacity(0.15)).frame(width: 2, height: 30).padding(.horizontal, 6)
    }

    private func chip(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .buttonStyle(TVActionStyle(selected: on, compact: true))
    }

    /// Press and hold a channel: favorite it, add it to collections, or watch.
    @ViewBuilder private func channelMenu(_ channel: LiveChannel) -> some View {
        Button { watch(channel) } label: { Label("Watch \(channel.title)", systemImage: "play.fill") }
        Button { live.toggleFavorite(channel) } label: {
            live.favoriteIDs.contains(channel.id) ? Label("Remove from Favorites", systemImage: "star.slash") : Label("Add to Favorites", systemImage: "star")
        }
        ForEach(live.collectionNames, id: \.self) { name in
            Button { live.toggle(channel.id, inCollection: name) } label: {
                live.channels(inCollection: name).contains(channel.id)
                    ? Label("Remove from \(name)", systemImage: "minus.circle") : Label("Add to \(name)", systemImage: "rectangle.stack.badge.plus")
            }
        }
        Button { newCollectionFor = channel } label: { Label("New Collection…", systemImage: "plus") }
    }

    // MARK: On Now

    private var onNow: some View {
        TVPageScrollView {
            // Redrawn every minute so ended programs move on.
            TimelineView(.everyMinute) { _ in
            LazyVStack(spacing: 8) {
                ForEach(live.visibleChannels) { channel in
                    Button { watch(channel) } label: {
                        HStack(spacing: 24) {
                            TVChannelBadge(channel: channel, favorite: live.favoriteIDs.contains(channel.id)).frame(width: 300, alignment: .leading)
                            if let now = live.current(on: channel.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(now.showTitle).font(.callout.weight(.semibold)).lineLimit(1)
                                    HStack(spacing: 12) {
                                        Text(now.timeRange).font(.caption2).foregroundStyle(.secondary)
                                        ProgressView(value: now.progress()).tint(TVTheme.accent).frame(width: 200)
                                    }
                                }
                                Spacer()
                                if let next = live.next(on: channel.id) {
                                    Text("Next \(Fmt.time(next.beginsAt)) · \(next.showTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .frame(maxWidth: 520, alignment: .trailing)
                                }
                            } else {
                                Text("No guide information").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 76)
                        .modifier(TVFocusReporter { if let a = live.current(on: channel.id) { spotlight = a } })
                    }
                    .buttonStyle(.card)
                    .contextMenu { channelMenu(channel) }
                }
            }
            .padding(.vertical, 16)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Recordings

    @ViewBuilder private var recordings: some View {
        if !recorded.isEmpty {
            TVRow(title: "Recorded") {
                ForEach(recorded) { item in
                    NavigationLink(value: item) { TVPosterCard(item: item) }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, -60)
        }
        if live.scheduled.isEmpty && live.rules.isEmpty && recorded.isEmpty {
            Text("No recordings scheduled. Pick a show in the Guide to record it.").foregroundStyle(.secondary)
        }
        if !live.scheduled.isEmpty {
            Text("Upcoming").font(.headline).foregroundStyle(.secondary)
            LazyVStack(spacing: 10) {
                ForEach(live.scheduled) { grab in
                    if let a = grab.airing {
                        Button { selected = a } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(a.showTitle).font(.callout.weight(.semibold))
                                    Text([a.episodeLine, a.channelTitle, Fmt.timeRange(a.beginsAt, a.endsAt)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label(grab.isRecording ? "Recording" : "Scheduled", systemImage: grab.isRecording ? "record.circle" : "clock")
                                    .font(.caption).foregroundStyle(grab.isRecording ? .red : .secondary)
                            }
                            .padding(.horizontal, 18).frame(height: 76)
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .focusSection()
        }
        if !live.rules.isEmpty {
            Text("Recording Rules").font(.headline).foregroundStyle(.secondary).padding(.top, 20)
            LazyVStack(spacing: 10) {
                ForEach(live.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.itemTitle).font(.callout.weight(.semibold))
                            Text("\(rule.title) · \(rule.upcoming.count) upcoming").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel Rule", role: .destructive) {
                            Task { if let api = session.api { try? await live.cancel(rule, api: api) } }
                        }
                    }
                    .padding(14)
                    .background(TVTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .focusSection()
        }
    }
}

// MARK: - Guide grid

/// Where Back goes on the Live TV page, one press at a time: first to now and the first channel
/// (from further down or later in the guide), then the playing corner window, then the tab bar
/// (where Down comes to the filters and Down again to the guide).
enum TVLiveBack: Equatable {
    case firstChannel, window, tabBar

    static func step(awayFromNow: Bool, windowCanTakeFocus: Bool) -> TVLiveBack {
        if awayFromNow { return .firstChannel }
        return windowCanTakeFocus ? .window : .tabBar
    }

    /// The guide is scrolled down past the first channel, or later than the current half hour.
    static func awayFromNow(windowStart: Date, nowSlot: Date, focusedRow: Int) -> Bool {
        windowStart > nowSlot || focusedRow > 0
    }

    /// A channel plays in the corner window (not full screen) and the window doesn't have focus yet.
    static func windowCanTakeFocus(playing: Bool, fullScreen: Bool, windowFocused: Bool) -> Bool {
        playing && !fullScreen && !windowFocused
    }
}

/// A TV guide: channels down the left, a time ruler across the top, programs sized by their
/// length, and a line at the current time. The grid follows the remote: moving onto a program
/// that runs past the right edge moves later; onto one that started before the left edge, earlier
/// (never before now). Back returns to now and the top row; pressed again, it goes back as usual.
struct TVGuideGrid<Menu: View>: View {
    let channels: [LiveChannel]
    let category: GuideCategory?
    let onAiring: (LiveAiring) -> Void
    let onWatch: (LiveChannel) -> Void
    /// The program under focus (a channel's current program when its name is focused).
    var onFocusAiring: (LiveAiring?) -> Void = { _ in }
    /// Back when the guide is already at the top and now (the playing window takes focus);
    /// nil lets Back go on to the tab bar.
    var backOverride: (() -> Void)? = nil
    @ViewBuilder let channelMenu: (LiveChannel) -> Menu
    @State private var windowStart = LiveTVStore.slot(containing: Date())
    @State private var focusedRow = 0
    @FocusState private var focus: GuideFocus?
    /// The time moving up and down keeps to: set by moving across a row (or entering the guide),
    /// so each row lands on what's on at that time instead of drifting later.
    @State private var anchorTime: Date?
    /// The next focus change is one this grid made itself.
    @State private var redirected = false
    @Environment(TVSession.self) private var session
    private var live: LiveTVStore { .shared }
    private var now: TVLiveNow { .shared }

    enum GuideFocus: Hashable { case channel(String), airing(String) }

    /// How much of the schedule the grid shows at once.
    static var window: TimeInterval { 2 * 3600 }
    private let channelWidth: CGFloat = 300
    private let rowHeight: CGFloat = 70
    /// Programs this far past the right edge are laid out (off screen) so the remote can move onto them.
    private let lookAhead: TimeInterval = 3 * 3600
    private var windowEnd: Date { windowStart.addingTimeInterval(Self.window) }
    private var nowSlot: Date { LiveTVStore.slot(containing: Date()) }
    private var awayFromNow: Bool { TVLiveBack.awayFromNow(windowStart: windowStart, nowSlot: nowSlot, focusedRow: focusedRow) }

    var body: some View {
        GeometryReader { geo in
            let gridWidth = geo.size.width - channelWidth - 12
            let perSecond = gridWidth / Self.window
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    ruler(gridWidth: gridWidth, perSecond: perSecond)
                    if channels.isEmpty {
                        Text("No channels match. Press and hold a channel to add it to Favorites or a collection.")
                            .foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ScrollView {
                        // Redrawn every minute so the shading, the now line and what's on stay current.
                        TimelineView(.everyMinute) { _ in
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(channels.enumerated()), id: \.element.id) { i, channel in
                                    row(channel, gridWidth: gridWidth, perSecond: perSecond).id(channel.id)
                                }
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .topLeading) { nowLine(perSecond: perSecond) }
                        }
                    }
                    .scrollClipDisabled()
                }
                .onChange(of: focus) { old, new in
                    if case .airing(let id)? = new, let landed = airing(withID: id) {
                        if redirected {
                            redirected = false
                        } else if old == nil {
                            // Coming into the guide from above (the filters): start on what's on now in
                            // that row, not whichever later program happened to sit under the button.
                            if !landed.isOnAir(), let onNow = live.current(on: landed.channelID), onNow.id != id {
                                redirected = true
                                anchorTime = nil
                                focus = .airing(onNow.id)
                                return
                            }
                            anchorTime = nil
                        } else if let from = rowChannel(old), from != landed.channelID {
                            // Up or down a row: the program on at the time being followed.
                            if let at = anchorTime, let match = airing(on: landed.channelID, at: at), match.id != id {
                                redirected = true
                                focus = .airing(match.id)
                                return
                            }
                        } else {
                            anchorTime = nil   // across the row (or from the channel name): follow this one
                        }
                        if anchorTime == nil { anchorTime = max(landed.beginsAt, windowStart, Date()) }
                    }
                    follow(new)
                    switch new {
                    case .airing(let id): onFocusAiring(airing(withID: id))
                    case .channel(let id): onFocusAiring(live.current(on: id))
                    case nil: break
                    }
                }
                // Back: first to now and the first channel; then the playing window (if any); then
                // the tab bar, where Down comes to the filters and Down again to the guide.
                .onExitCommand(perform: backAction(proxy))
            }
        }
        .onChange(of: windowStart) { Task { await loadAhead() } }
        .onChange(of: now.isFullScreen) { wasFullScreen, isFullScreen in
            if wasFullScreen && !isFullScreen {
                let slot = LiveTVStore.slot(containing: Date())
                if windowStart < slot { windowStart = slot }
            }
        }
        #if DEBUG
        // Development: `-tvGuideAhead <minutes>` opens the grid later than now.
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tvGuideAhead"), args.indices.contains(i + 1), let m = Double(args[i + 1]) {
                windowStart = nowSlot.addingTimeInterval(m * 60)
            }
            // `-tvGuideFocus` focuses the first channel's current program (to check the highlight).
            if args.contains("-tvGuideFocus"), let first = channels.first, let a = live.current(on: first.id) {
                Task { try? await Task.sleep(for: .seconds(1)); focus = .airing(a.id) }
            }
        }
        #endif
    }

    // Time ruler; the day sits above the channel column.
    private func ruler(gridWidth: CGFloat, perSecond: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(dayLabel).font(.callout.weight(.semibold)).frame(width: channelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                ForEach(0..<Int(Self.window / 1800), id: \.self) { i in
                    let t = windowStart.addingTimeInterval(Double(i) * 1800)
                    Text(Fmt.time(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .offset(x: CGFloat(Double(i) * 1800) * perSecond)
                }
            }
            .frame(width: gridWidth, alignment: .leading)
        }
    }

    private var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(windowStart) { return "Today" }
        if cal.isDateInTomorrow(windowStart) { return "Tomorrow" }
        return windowStart.formatted(.dateTime.weekday(.wide))
    }

    private func row(_ channel: LiveChannel, gridWidth: CGFloat, perSecond: CGFloat) -> some View {
        HStack(spacing: 12) {
            Button { onWatch(channel) } label: {
                TVChannelBadge(channel: channel, favorite: live.favoriteIDs.contains(channel.id), compact: true)
                    .padding(.horizontal, 14)
                    .frame(width: channelWidth, height: rowHeight, alignment: .leading)
            }
            .buttonStyle(TVGuideCellStyle(base: TVTheme.surface))
            .focused($focus, equals: .channel(channel.id))
            .contextMenu { channelMenu(channel) }

            // The row is laid out from `rowStart` (off screen to the left, never before now) to well past
            // the right edge, so the remote always has a program to move onto in either direction.
            let rowStart = max(nowSlot, windowStart.addingTimeInterval(-lookAhead))
            let shown = (live.airings[channel.id] ?? []).filter { $0.endsAt > rowStart && $0.beginsAt < windowEnd.addingTimeInterval(lookAhead) }
            HStack(spacing: 0) {
                if shown.isEmpty {
                    Text("No guide information").font(.caption).foregroundStyle(.secondary)
                        .frame(width: gridWidth, height: rowHeight, alignment: .leading).padding(.leading, 14)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, airing in
                    // Empty time before this program keeps every row true to the clock.
                    let gapStart = i == 0 ? rowStart : max(shown[i - 1].endsAt, rowStart)
                    let gap = airing.beginsAt.timeIntervalSince(gapStart)
                    if gap > 0 { Color.clear.frame(width: CGFloat(gap) * perSecond) }
                    let from = max(airing.beginsAt, rowStart), to = airing.endsAt
                    let width = max(CGFloat(to.timeIntervalSince(from)) * perSecond - 4, 40)
                    // How much of the cell sits left of the grid's edge; its title starts after that.
                    let hidden = max(0, CGFloat(windowStart.timeIntervalSince(from)) * perSecond)
                    // Click: a program that's on now starts its channel, a later one opens its details.
                    // Hold: details and recording. (A plain focusable tile: tvOS buttons ignore hold gestures.)
                    let isFocused = focus == .airing(airing.id)
                    TVGuideCell(airing: airing, visibleFrom: from, visibleTo: to, width: width, height: rowHeight,
                                dimmed: category.map { !$0.matches(airing) } ?? false, startsEarlier: airing.beginsAt < windowStart,
                                textInset: min(hidden, max(0, width - 120)), focused: isFocused)
                        .modifier(TVGuideCellChrome(base: airing.isOnAir() ? TVTheme.surface : TVTheme.placeholder.opacity(0.55), focused: isFocused))
                        .focusable()
                        .focused($focus, equals: .airing(airing.id))
                        // One element per program, so VoiceOver (and UI tests) see the tile that has focus.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("airing-\(channel.id)\(airing.isOnAir() ? "-now" : "")")
                        .onTapGesture {
                            if airing.isOnAir(), let ch = live.channel(airing.channelID) { onWatch(ch) } else { onAiring(airing) }
                        }
                        .onLongPressGesture(minimumDuration: 0.5) { onAiring(airing) }
                    .padding(.trailing, 4)
                    // Drawn above its neighbors, so the next program doesn't cover the enlarged tile's edge.
                    .zIndex(isFocused ? 1 : 0)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            // Shifted so the window's start lines up with the grid's left edge (real layout, so focus follows it).
            .padding(.leading, -CGFloat(windowStart.timeIntervalSince(rowStart)) * perSecond)
            .frame(width: gridWidth, alignment: .leading)
            .clipped()
        }
        .focusSection()
    }

    /// Moves the grid so the focused program is visible, in half-hour steps.
    private func follow(_ newFocus: GuideFocus?) {
        switch newFocus {
        case .channel(let id):
            focusedRow = channels.firstIndex { $0.id == id } ?? 0
        case .airing(let id):
            guard let airing = airing(withID: id) else { return }
            focusedRow = channels.firstIndex { $0.id == airing.channelID } ?? focusedRow
            if airing.endsAt > windowEnd {
                // Show its end if it fits in the window, but never scroll past its start.
                let endSlot = LiveTVStore.slot(containing: airing.endsAt.addingTimeInterval(-1)).addingTimeInterval(1800)
                windowStart = max(windowStart, min(LiveTVStore.slot(containing: airing.beginsAt), endSlot.addingTimeInterval(-Self.window)))
            } else if airing.beginsAt < windowStart, windowStart > nowSlot {
                windowStart = max(nowSlot, LiveTVStore.slot(containing: airing.beginsAt))
            }
        case nil:
            break
        }
    }

    private func airing(withID id: String) -> LiveAiring? {
        let channelID = String(id.split(separator: "@").first ?? "")
        return live.airings[channelID]?.first { $0.id == id }
    }

    /// nil lets the system take Back on to the tab bar.
    private func backAction(_ proxy: ScrollViewProxy) -> (() -> Void)? {
        switch TVLiveBack.step(awayFromNow: awayFromNow, windowCanTakeFocus: backOverride != nil) {
        case .firstChannel: return { goToNow(proxy) }
        case .window: return backOverride
        case .tabBar: return nil
        }
    }

    private func goToNow(_ proxy: ScrollViewProxy) {
        windowStart = nowSlot
        focusedRow = 0
        anchorTime = nil
        guard let first = channels.first else { return }
        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
        focus = live.current(on: first.id).map { .airing($0.id) } ?? .channel(first.id)
    }

    /// The channel of the row a focus is in.
    private func rowChannel(_ f: GuideFocus?) -> String? {
        switch f {
        case .channel(let id): id
        case .airing(let id): airing(withID: id)?.channelID
        case nil: nil
        }
    }

    private func airing(on channelID: String, at time: Date) -> LiveAiring? {
        live.airings[channelID]?.first { $0.beginsAt <= time && $0.endsAt > time }
    }

    /// The guide loads a few hours at a time; fetch more as the grid moves later.
    private func loadAhead() async {
        guard let api = session.api, windowEnd.addingTimeInterval(lookAhead) > live.loadedUntil else { return }
        #if DEBUG
        if live.isSample { return }
        #endif
        await live.loadMore(api: api)
    }

    /// The current time, across every row.
    @ViewBuilder private func nowLine(perSecond: CGFloat) -> some View {
        let offset = Date().timeIntervalSince(windowStart)
        if offset >= 0, offset <= Self.window {
            Rectangle()
                .fill(TVTheme.accent)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .offset(x: channelWidth + 12 + CGFloat(offset) * perSecond)
                .allowsHitTesting(false)
        }
    }
}

/// One program in the grid: title and time, the part already aired shaded, a red dot when recording.
private struct TVGuideCell: View {
    let airing: LiveAiring
    /// The part of the program inside the grid's window.
    let visibleFrom: Date
    let visibleTo: Date
    let width: CGFloat
    let height: CGFloat
    let dimmed: Bool
    let startsEarlier: Bool
    /// Width of the cell hidden left of the grid's edge, so the title stays in view.
    var textInset: CGFloat = 0
    /// From the guide's focus state (plain focusable views don't get `isFocused` like buttons do).
    var focused = false
    private var live: LiveTVStore { .shared }

    /// How much of the visible part has aired, so the shading ends exactly at the now line.
    private func airedFraction(at date: Date) -> CGFloat {
        let span = visibleTo.timeIntervalSince(visibleFrom)
        guard span > 0 else { return 0 }
        return CGFloat(min(max(date.timeIntervalSince(visibleFrom) / span, 0), 1))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if startsEarlier { Image(systemName: "chevron.left").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
                    Text(airing.showTitle).font(.callout.weight(.semibold)).lineLimit(1)
                    stateDot
                }
                Text(airing.episodeLine ?? Fmt.timeRange(airing.beginsAt, airing.endsAt)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 14 + textInset).padding(.trailing, 14)
            .foregroundStyle(focused ? .black : .primary)
        }
        .frame(width: width, height: height, alignment: .leading)
        // Shade what has already aired, up to the now line (the grid redraws every minute).
        .background(alignment: .leading) {
            if airing.isOnAir() {
                RoundedRectangle(cornerRadius: 10)
                    .fill(TVTheme.accent.opacity(focused ? 0.3 : 0.16))
                    .frame(width: width * airedFraction(at: Date()))
            }
        }
        .opacity(dimmed && !focused ? 0.35 : 1)
    }

    @ViewBuilder private var stateDot: some View {
        switch live.recordState(airing) {
        case .recording: Circle().fill(.red).frame(width: 12, height: 12)
        case .scheduled, .series: Image(systemName: "record.circle").font(.caption2).foregroundStyle(.red)
        case .none: EmptyView()
        }
    }
}

/// Program tiles: the same look as TVGuideCellStyle for a focusable view that isn't a button.
private struct TVGuideCellChrome: ViewModifier {
    let base: Color
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .background(focused ? Color.white : base, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(focused ? 1.03 : 1)
            // Shadow the tile as a whole: ungrouped, the dark title casts a grey smudge onto the white.
            .compositingGroup()
            .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Guide cells: flat tiles that turn white when focused, instead of the big card lift.
private struct TVGuideCellStyle: ButtonStyle {
    let base: Color
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration, base: base) }

    private struct Inner: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let base: Color
        var body: some View {
            configuration.label
                .background(focused ? Color.white : base, in: RoundedRectangle(cornerRadius: 10))
                .scaleEffect(focused ? 1.03 : (configuration.isPressed ? 0.98 : 1))
                .compositingGroup()
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

/// Channel logo, number, name and a star for favorites.
struct TVChannelBadge: View {
    @Environment(\.isFocused) private var focused
    let channel: LiveChannel
    var favorite = false
    var compact = false

    var body: some View {
        HStack(spacing: 14) {
            TVImage(path: channel.thumb, width: 120, height: 120, placeholderIcon: "tv")
                .frame(width: compact ? 52 : 60, height: compact ? 52 : 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.number).font(.caption.monospacedDigit()).foregroundStyle(focused ? .black.opacity(0.6) : .secondary)
                Text(channel.title).font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(focused ? .black : .primary)
            }
            Spacer(minLength: 0)
            if favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
        }
    }
}


/// A program from the guide: watch it if it's on, or record it.
struct TVAiringDetail: View {
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let airing: LiveAiring
    let watch: (LiveChannel) -> Void
    @State private var options: [RecordingOption] = []
    @State private var message: String?
    @State private var working = false
    private var live: LiveTVStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            TVImage(path: airing.poster, width: 500, height: 750)
                .frame(width: 340, height: 510)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 20) {
                Text(airing.showTitle).font(.system(size: 54, weight: .heavy).width(.compressed))
                Text([airing.episodeLine, airing.channelTitle, airing.timeRange].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let summary = airing.summary { Text(summary).font(.callout).lineLimit(6) }
                HStack(spacing: 24) {
                    if airing.isOnAir(), let channel = live.channel(airing.channelID) {
                        Button { watch(channel) } label: { Label("Watch Live", systemImage: "play.fill") }
                    }
                    switch live.recordState(airing) {
                    case .none:
                        ForEach(options) { option in
                            Button { record(option) } label: {
                                Label(option.title, systemImage: option.isSeries ? "repeat" : "record.circle")
                            }
                            .disabled(working)
                        }
                    case .scheduled: Label("Recording scheduled", systemImage: "clock").foregroundStyle(TVTheme.accent)
                    case .recording: Label("Recording now", systemImage: "record.circle").foregroundStyle(.red)
                    case .series: Label("Recording all episodes", systemImage: "repeat").foregroundStyle(TVTheme.accent)
                    }
                }
                .buttonStyle(TVActionStyle())
                if let message { Text(message).foregroundStyle(.secondary) }
                if let conflict = live.conflictMessage(for: airing) { Text(conflict).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(80)
        .task {
            guard let api = session.api, let guid = airing.guid else { return }
            options = (try? await api.recordingOptions(guid: guid)) ?? []
        }
    }

    private func record(_ option: RecordingOption) {
        guard let api = session.api else { return }
        working = true
        Task {
            do {
                try await live.record(option, prefs: [:], airing: airing, autoDownload: nil, api: api)
                message = option.isSeries ? "Every episode will be recorded." : "It will be recorded."
            } catch {
                message = "Couldn't schedule the recording: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

/// The player's Guide tab: channels side by side with what's on now; select one to switch.
struct TVLiveMiniGuide: View {
    let currentID: () -> String?
    let onWatch: (LiveChannel) -> Void
    private var live: LiveTVStore { .shared }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(live.channels) { ch in
                        Button { onWatch(ch) } label: { card(ch) }
                            .buttonStyle(.card)
                            .id(ch.id)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
            .onAppear { if let id = currentID() { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func card(_ ch: LiveChannel) -> some View {
        let now = live.current(on: ch.id)
        let isCurrent = ch.id == currentID()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TVImage(path: ch.thumb, width: 80, height: 80, placeholderIcon: "tv")
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                Text(ch.number).font(.caption.monospacedDigit().weight(.bold))
                Text(ch.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent { TVLiveBadge() }
            }
            Text(now?.showTitle ?? "No guide information").font(.callout.weight(.semibold)).lineLimit(1)
            if let now {
                Text(now.timeRange).font(.caption2).foregroundStyle(.secondary)
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.2))
                        .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * now.progress()) }
                }
                .frame(height: 4)
            }
        }
        .padding(18)
        .frame(width: 400, height: 170, alignment: .topLeading)
        .background(isCurrent ? Color.white.opacity(0.18) : TVTheme.surface)
    }
}

// MARK: - Live player

/// The live channel being watched. It keeps playing after Back (in the corner window) until it's
/// stopped, the Live TV tab is left, or other playback starts.
@MainActor @Observable
final class TVLiveNow {
    static let shared = TVLiveNow()
    private(set) var channel: LiveChannel?
    var isFullScreen = false
    @ObservationIgnored private(set) var controller: TVLivePlaybackController?
    var player: AVPlayer? { controller?.player }
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var wentToBackground: Date?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// When the corner window was paused because the app went inactive (the screen saver).
    @ObservationIgnored private var pausedInactive: Date?

    private init() {
        // Away at the Home Screen, the app stops keeping the server's live session alive and the
        // server ends it. A quick look away keeps the stream; after longer (or if the stream
        // stopped), the channel is closed and the guide shows, brought up to date, ready to pick
        // a channel again — rather than waiting on a stream that may not come back.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground = Date() }
        }
        // The screen saver (or Control Center) only makes the app inactive: the corner window
        // would keep playing under it. It pauses, picks up again after a quick look away, and
        // after longer is closed like a return from the Home Screen. (Full screen keeps the TV
        // awake itself, so no screen saver comes over it.)
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillResignActive() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller else { return }
                let away = self.wentToBackground.map { Date().timeIntervalSince($0) } ?? 0
                self.wentToBackground = nil
                if away > 15 || controller.player.currentItem?.status == .failed || controller.player.timeControlStatus != .playing {
                    self.stop()
                }
            }
        }
    }

    /// The screen saver is coming over the app: the corner window pauses (full screen plays on).
    func appWillResignActive(at date: Date = Date()) {
        guard let controller, !isFullScreen else { return }
        controller.player.pause()
        pausedInactive = date
    }

    /// Back from the screen saver: a quick look away picks up again; after longer the channel closes.
    func appDidBecomeActive(at date: Date = Date()) {
        guard let paused = pausedInactive else { return }
        pausedInactive = nil
        guard let controller else { return }
        if date.timeIntervalSince(paused) > 15 || controller.player.currentItem?.status == .failed {
            stop()
        } else {
            controller.player.play()
        }
    }

    func watch(_ channel: LiveChannel, session: TVSession) {
        if let controller {
            controller.watch(channel)
        } else {
            let c = TVLivePlaybackController(channel: channel, session: session) { [weak self] in self?.stop() }
            c.onChannelChange = { [weak self] in self?.channel = $0 }
            controller = c
            c.start()
        }
        self.channel = channel
        isFullScreen = true
    }

    func stop() {
        pausedInactive = nil
        controller?.stop()
        controller = nil
        channel = nil
        isFullScreen = false
    }
}

/// Full screen live TV: Apple's player on the shared live player, with a Channels menu.
struct TVLiveFullScreen: View {
    var body: some View { TVLiveFullScreenRepresentable().ignoresSafeArea() }
}

private struct TVLiveFullScreenRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = false
        if let c = TVLiveNow.shared.controller {
            vc.player = c.player
            c.viewController = vc
            c.refreshMenu()
        }
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    // Leaving full screen keeps the channel playing (the corner window shows it).
}

/// The playing channel's window in the preview band: select for full screen; press and hold to stop.
struct TVLiveMiniPlayer: View {
    let channel: LiveChannel
    let player: AVPlayer
    var focus: FocusState<Bool>.Binding
    var size = CGSize(width: 480, height: 270)
    private var live: LiveTVStore { .shared }

    var body: some View {
        Button { TVLiveNow.shared.isFullScreen = true } label: {
            TVPlayerLayerView(player: player)
                .frame(width: size.width, height: size.height)
                .background(.black)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 10) {
                        TVLiveBadge()
                        Text("\(channel.number) · \(live.current(on: channel.id)?.showTitle ?? channel.title)")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.card)
        .focused(focus)
        .contextMenu {
            Button { TVLiveNow.shared.isFullScreen = true } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button(role: .destructive) { TVLiveNow.shared.stop() } label: { Label("Stop Watching", systemImage: "stop.fill") }
        }
        .focusSection()
    }
}

/// A small red LIVE tag.
struct TVLiveBadge: View {
    var body: some View {
        Text("LIVE").font(.caption2.weight(.heavy)).tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(.red, in: Capsule())
    }
}

// MARK: - Preview band

/// The top of the Live TV page: the selected program (title, channel, time left, summary) and,
/// on the right, the playing channel's window, or the program's artwork when nothing is playing.
struct TVLiveHero: View {
    let airing: LiveAiring?
    var focus: FocusState<Bool>.Binding
    private var now: TVLiveNow { .shared }
    private var live: LiveTVStore { .shared }
    static let window = CGSize(width: 480, height: 270)

    var body: some View {
        HStack(alignment: .top, spacing: 50) {
            info.frame(maxWidth: .infinity, alignment: .topLeading)
            ZStack {
                if let channel = now.channel, !now.isFullScreen, let player = now.player {
                    TVLiveMiniPlayer(channel: channel, player: player, focus: focus, size: Self.window)
                        .transition(.opacity)
                } else {
                    artwork.transition(.opacity)
                }
            }
            .frame(width: Self.window.width, height: Self.window.height)
            .animation(.easeInOut(duration: 0.3), value: now.channel?.id)
        }
        .frame(height: Self.window.height)
    }

    @ViewBuilder private var info: some View {
        if let airing {
            // Redrawn every minute so "LIVE · 23 min left" and the progress stay current.
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let thumb = live.channel(airing.channelID)?.thumb ?? airing.channelThumb {
                            TVImage(path: thumb, width: 80, height: 80, placeholderIcon: "tv")
                                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text([airing.channelNumber, airing.channelTitle].compactMap { $0 }.joined(separator: " · ").uppercased())
                            .font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(airing.showTitle)
                        .font(.system(size: 60, weight: .heavy).width(.compressed))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityIdentifier("live-spotlight")
                    HStack(spacing: 14) {
                        if airing.isOnAir(at: context.date) {
                            TVLiveBadge()
                            Text("\(airing.timeRange) · \(Self.left(airing, at: context.date))")
                                .font(.callout).foregroundStyle(.secondary)
                            GeometryReader { g in
                                Capsule().fill(.white.opacity(0.2))
                                    .overlay(alignment: .leading) { Capsule().fill(TVTheme.accent).frame(width: g.size.width * airing.progress(at: context.date)) }
                            }
                            .frame(width: 180, height: 6)
                        } else {
                            Text(Self.when(airing)).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Self.chips(airing), id: \.self) { chip in
                            Text(chip).font(.caption2.weight(.bold)).tracking(0.6)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    if let line = airing.episodeLine {
                        Text(line).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    if let summary = airing.summary, !summary.isEmpty {
                        Text(summary).font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
            }
            .id(airing.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: airing.id)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Live TV").font(.system(size: 60, weight: .heavy).width(.compressed))
                Text("Pick a channel to start watching. It keeps playing here while you browse.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The program's artwork, or the channel's logo, where the window goes.
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(TVTheme.surface)
            if let path = airing?.art ?? airing?.grandparentArt ?? airing?.thumb {
                TVImage(path: path, width: 960, height: 540, placeholderIcon: "tv")
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let airing, let thumb = live.channel(airing.channelID)?.thumb ?? airing.channelThumb {
                TVImage(path: thumb, width: 240, height: 240, placeholderIcon: "tv")
                    .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Image(systemName: "play.tv").font(.system(size: 64)).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.window.width, height: Self.window.height)
        .overlay(alignment: .bottomLeading) {
            Text(airing?.isOnAir() == true ? "Select it to watch" : "Plays here while you browse")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
        }
    }

    static func left(_ a: LiveAiring, at date: Date) -> String {
        let minutes = max(1, Int(ceil(a.endsAt.timeIntervalSince(date) / 60)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes) min left"
    }

    static func when(_ a: LiveAiring) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(a.beginsAt) ? "" : cal.isDateInTomorrow(a.beginsAt) ? "Tomorrow " : a.beginsAt.formatted(.dateTime.weekday(.wide)) + " "
        return "\(day)\(a.timeRange)"
    }

    static func chips(_ a: LiveAiring) -> [String] {
        var out: [String] = []
        if a.isPremiere { out.append("NEW") }
        if let r = a.resolution?.lowercased() { out.append(r.contains("1080") || r.contains("720") || r == "hd" ? "HD" : r.uppercased()) }
        if let rating = a.contentRating { out.append(rating) }
        if let genre = a.genres.first { out.append(genre.uppercased()) }
        return out
    }
}

/// Inside a button's label: calls `action` when the button gains focus.
struct TVFocusReporter: ViewModifier {
    @Environment(\.isFocused) private var focused
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: focused) { _, now in if now { action() } }
    }
}

/// Video from an AVPlayer, without controls.
struct TVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        // Video only: input goes to the button around it, so the window can take focus.
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) { v.playerLayer.player = player }
}

@MainActor
final class TVLivePlaybackController: NSObject {
    let player = AVPlayer()
    weak var viewController: AVPlayerViewController?
    private var channel: LiveChannel
    private let session: TVSession
    private let onClose: () -> Void
    private var liveSession: LiveSession?
    private var tuneTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var lastReport = Date.distantPast
    private var stopped = false
    private var live: LiveTVStore { .shared }
    var onChannelChange: ((LiveChannel) -> Void)?
    /// The channel watched before this one, for Last Channel.
    private var previousChannel: LiveChannel?
    /// The previous stream being stopped on the server.
    private var ending: Task<Void, Never>?
    private var jumpShown = false

    init(channel: LiveChannel, session: TVSession, onClose: @escaping () -> Void) {
        self.channel = channel
        self.session = session
        self.onClose = onClose
    }

    func start() {
        TVMusicPlayer.shared.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tune(channel)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        endSession()
    }

    private func tune(_ ch: LiveChannel) {
        tuneTask?.cancel()
        channel = ch
        updateMenu()
        guard let api = session.api, let dvr = live.dvr else { return }
        let previousEnd = ending
        tuneTask = Task {
            // The stream is tied to this device's identifier, so the old one must be fully
            // stopped first: a late stop would end the new stream (the server then answers 400).
            await previousEnd?.value
            do {
                var url: URL?
                // Setting up the stream can fail once while the server is still letting go of the
                // last one: stop it, wait a moment, and go through the whole sequence again.
                for setup in 0..<2 {
                    do {
                        var tuned: LiveSession?
                        // A tuner can take a few seconds to free up after the last stream.
                        for attempt in 0..<3 {
                            do { tuned = try await api.tune(dvr: dvr.key, channel: ch.id); break } catch {
                                if attempt == 2 || Task.isCancelled { throw error }
                                try await Task.sleep(for: .seconds(4))
                            }
                        }
                        guard let s = tuned, !Task.isCancelled, !stopped else { return }
                        liveSession = s
                        live.rememberChannel(ch.id, serverID: api.serverID)
                        // The server ties the live stream to this device's client identifier.
                        let streamURL = api.liveStreamURL(session: s, sessionID: PlexClient.identifier, quality: .original, isLocal: session.isLocalConnection)
                        try await api.liveDecision(streamURL: streamURL)
                        try await api.waitForLiveSegments(streamURL: streamURL)
                        url = streamURL
                        break
                    } catch {
                        if setup == 1 || Task.isCancelled || stopped { throw error }
                        await api.stopTranscode(sessionID: PlexClient.identifier)
                        try await Task.sleep(for: .seconds(2))
                    }
                }
                guard let url, !Task.isCancelled, !stopped else { return }
                let item = AVPlayerItem(url: url)
                item.externalMetadata = metadata()
                item.preferredForwardBufferDuration = 6
                player.replaceCurrentItem(with: item)
                player.play()
            } catch {
                guard !Task.isCancelled, !stopped else { return }
                showError(error.localizedDescription.localizedCaseInsensitiveContains("tune")
                          ? "Couldn't tune \(ch.title). The tuners may be busy recording." : error.localizedDescription)
            }
        }
    }

    /// Changes channel without leaving the player.
    func watch(_ ch: LiveChannel) {
        guard ch.id != channel.id else { return }
        previousChannel = channel
        endSession()
        tune(ch)
        onChannelChange?(ch)
    }

    func refreshMenu() {
        updateMenu()
        installGuide()
    }

    /// Channel up (+1) or down (−1) through the guide's channel order.
    func step(_ delta: Int) {
        let list = live.channels
        guard let i = list.firstIndex(where: { $0.id == channel.id }), !list.isEmpty else { return }
        watch(list[(i + delta + list.count) % list.count])
    }

    /// A Guide tab in the player's info panel (swipe down): every channel with what's on.
    private func installGuide() {
        guard let vc = viewController else { return }
        let guide = UIHostingController(rootView: TVLiveMiniGuide(currentID: { [weak self] in self?.channel.id }) { [weak self] ch in
            self?.watch(ch)
        }.environment(session))
        guide.title = "Guide"
        guide.preferredContentSize = CGSize(width: 1920, height: 330)
        guide.view.backgroundColor = .clear
        vc.customInfoViewControllers = [guide]
    }

    /// Stops the server's stream; the next tune waits for this to finish.
    private func endSession() {
        tuneTask?.cancel()
        player.replaceCurrentItem(with: nil)
        guard let s = liveSession, let api = session.api else { return }
        liveSession = nil
        ending = Task {
            try? await api.timeline(ratingKey: s.ratingKey, key: s.path, state: "stopped", timeMs: 0, durationMs: nil, sessionID: PlexClient.identifier)
            await api.stopTranscode(sessionID: PlexClient.identifier)
        }
    }

    /// Keeps the server's live session alive.
    private func tick() {
        updateJumpToLive()
        guard let s = liveSession, let api = session.api, Date().timeIntervalSince(lastReport) >= 10 else { return }
        lastReport = Date()
        let t = player.currentTime().seconds
        let ms = t.isFinite ? Int(t * 1000) : 0
        let state = player.timeControlStatus == .paused ? "paused" : "playing"
        Task { try? await api.timeline(ratingKey: s.ratingKey, key: s.path, state: state, timeMs: ms, durationMs: nil, sessionID: PlexClient.identifier) }
        player.currentItem?.externalMetadata = metadata()
    }

    /// The transport bar: channel down, channel up, last channel and a Channels menu.
    private func updateMenu() {
        let actions = live.channels.map { ch in
            UIAction(title: "\(ch.number)  \(ch.title)", subtitle: live.current(on: ch.id)?.showTitle,
                     state: ch.id == channel.id ? .on : .off) { [weak self] _ in self?.watch(ch) }
        }
        var items: [UIMenuElement] = [
            UIAction(title: "Channel Down", image: UIImage(systemName: "chevron.down")) { [weak self] _ in self?.step(-1) },
            UIAction(title: "Channel Up", image: UIImage(systemName: "chevron.up")) { [weak self] _ in self?.step(1) },
        ]
        if let prev = previousChannel {
            items.append(UIAction(title: "Last Channel · \(prev.number)", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.watch(prev)
            })
        }
        items.append(UIMenu(title: "Channels", image: UIImage(systemName: "list.bullet"), children: actions))
        items.append(TVSleepTimer.shared.menu(endLabel: nil))
        viewController?.transportBarCustomMenuItems = items
    }

    /// After pausing or rewinding, a Jump to Live button returns to the live edge.
    private func updateJumpToLive() {
        guard let item = player.currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let behind = range.end.seconds - player.currentTime().seconds
        let show = behind.isFinite && behind > 30
        guard show != jumpShown else { return }
        jumpShown = show
        viewController?.contextualActions = show ? [UIAction(title: "Jump to Live", image: UIImage(systemName: "forward.end.alt.fill")) { [weak self] _ in
            guard let self, let end = self.player.currentItem?.seekableTimeRanges.last?.timeRangeValue.end else { return }
            self.player.seek(to: end)
            self.player.play()
        }] : []
    }

    private func metadata() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m.copy() as? AVMetadataItem
        }
        let airing = live.current(on: channel.id)
        var sub = "\(channel.number) \(channel.title)"
        if let a = airing { sub += " · until \(Fmt.time(a.endsAt))" }
        return [item(.commonIdentifierTitle, airing?.showTitle ?? channel.title), item(.iTunesMetadataTrackSubTitle, sub),
                item(.commonIdentifierDescription, airing?.summary)].compactMap { $0 }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Live TV", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.onClose() })
        viewController?.present(alert, animated: true)
    }
}


