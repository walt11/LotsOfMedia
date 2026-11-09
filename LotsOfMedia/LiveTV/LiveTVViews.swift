import SwiftUI

// MARK: - Live tab

struct LiveTVView: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @State private var mode: Mode = .onNow
    @State private var selected: LiveAiring?
    @State private var pendingChannel: LiveChannel?
    @State private var newCollectionFor: LiveChannel?
    @State private var newCollectionName = ""
    @FocusState private var filterFocused: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case onNow = "On Now", guide = "Guide", recordings = "Recordings"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if mode != .recordings {
                HStack {
                    TextField("Filter channels", text: $store.channelQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($filterFocused)
                        .submitLabel(.done)
                        .onSubmit { filterFocused = false }
                        .autocorrectionDisabled()
                        .overlay(alignment: .trailing) {
                            if !store.channelQuery.isEmpty {
                                Button { store.channelQuery = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .padding(.trailing, 6)
                                .accessibilityLabel("Clear filter")
                            }
                        }
                    if let last = store.lastChannel {
                        Button { LivePlayerViewController.present(channel: last, app: app) } label: {
                            Label(last.number, systemImage: "arrow.uturn.backward")
                        }.accessibilityLabel("Return to \(last.title)")
                    }
                }.padding(.horizontal).padding(.vertical, 6)
                LiveFilterBar()
                if store.visibleChannels.isEmpty && !store.channels.isEmpty {
                    Text("No matching channels. Clear the filter, or press and hold a channel to add it to Favorites or a collection.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            // Plain row (not a scroll view), so the navigation bar keeps tracking the content below.
            HStack(spacing: 22) {
                ForEach(Mode.allCases) { m in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { mode = m } } label: {
                        VStack(spacing: 6) {
                            Text(m.rawValue)
                                .font(.system(size: 15, weight: mode == m ? .bold : .semibold))
                                .foregroundStyle(mode == m ? Color.white : Cinema.muted)
                            Capsule().fill(mode == m ? Cinema.accent : .clear).frame(height: 3)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mode == m ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Group {
                if store.channels.isEmpty {
                    if let error = store.error {
                        EmptyStateView(title: "Live TV Unavailable", systemImage: "antenna.radiowaves.left.and.right", message: error)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    switch mode {
                    case .onNow: OnNowList(selected: $selected) { newCollectionFor = $0 }
                    case .guide: GuideView(selected: $selected) { newCollectionFor = $0 }
                    case .recordings: RecordingsList(selected: $selected)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // Pull to refresh on the channel lists only (not on the filter row above them).
            .refreshable { await reload(force: true) }
            // Scrolling the channels puts the keyboard away so the tab bar is reachable again.
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Cinema.background)
        .pageTitle("Live TV")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isLoadingGuide { ProgressView() }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { filterFocused = false }.fontWeight(.semibold)
            }
        }
        .onChange(of: mode) { filterFocused = false }
        // Also when the app comes back after a while (contentVersion), so the guide isn't stale.
        .task(id: app.contentVersion) { await reload(force: false) }
        // The player opens only after the sheet has fully closed; presenting while
        // it's still dismissing is silently dropped by UIKit.
        .sheet(item: $selected, onDismiss: {
            if let ch = pendingChannel {
                pendingChannel = nil
                LivePlayerViewController.present(channel: ch, app: app)
            }
        }) { ProgramSheet(airing: $0) { pendingChannel = $0 } }
        .alert("New Collection", isPresented: Binding(get: { newCollectionFor != nil }, set: { if !$0 { newCollectionFor = nil } })) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                if let ch = newCollectionFor { store.createCollection(newCollectionName, with: ch.id) }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }

    private func reload(force: Bool) async {
        guard let api = app.api else { return }
        #if DEBUG
        // Development and screenshots: `-liveSample` shows a made-up guide on servers without a DVR.
        if ProcessInfo.processInfo.arguments.contains("-liveSample") { store.loadSample(serverID: api.serverID); return }
        #endif
        await store.refresh(api: api, force: force)
    }
}

// MARK: - Shared bits

/// All Channels, Favorites, your collections, then program categories.
struct LiveFilterBar: View {
    @Environment(LiveTVStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", systemImage: nil, on: !store.favoritesOnly && store.collectionFilter == nil) {
                    store.favoritesOnly = false; store.collectionFilter = nil
                }
                pill("Favorites", systemImage: "star.fill", on: store.favoritesOnly) { store.favoritesOnly.toggle() }
                ForEach(store.collectionNames, id: \.self) { name in
                    pill(name, systemImage: "rectangle.stack", on: store.collectionFilter == name) {
                        store.collectionFilter = store.collectionFilter == name ? nil : name
                    }
                    .contextMenu {
                        Button("Delete Collection", systemImage: "trash", role: .destructive) { store.deleteCollection(name) }
                    }
                }
                Divider().frame(height: 22)
                ForEach(GuideCategory.allCases) { c in
                    pill(c.rawValue, systemImage: c.systemImage, on: store.category == c) {
                        store.category = store.category == c ? nil : c
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private func pill(_ title: String, systemImage: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.caption) }
                Text(title).font(.subheadline.weight(on ? .semibold : .regular))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? Cinema.accent : Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Long-press menu for a channel: favorite it and add it to collections.
struct ChannelMenuItems: View {
    @Environment(LiveTVStore.self) private var store
    let channel: LiveChannel
    let onNewCollection: (LiveChannel) -> Void

    var body: some View {
        Button { store.toggleFavorite(channel) } label: {
            store.favoriteIDs.contains(channel.id) ? Label("Remove from Favorites", systemImage: "star.slash") : Label("Add to Favorites", systemImage: "star")
        }
        ForEach(store.collectionNames, id: \.self) { name in
            Button { store.toggle(channel.id, inCollection: name) } label: {
                store.channels(inCollection: name).contains(channel.id)
                    ? Label("Remove from \(name)", systemImage: "minus.circle") : Label("Add to \(name)", systemImage: "rectangle.stack.badge.plus")
            }
        }
        Button { onNewCollection(channel) } label: { Label("New Collection…", systemImage: "plus") }
    }
}

/// Guide artwork through the app's image cache, so rows scrolling back don't fetch it again.
private struct CachedArtwork<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        Group {
            if let shown = loaded.flatMap({ $0.url == url ? $0.image : nil }) ?? url.flatMap({ ImageLoader.shared.cached($0) }) {
                content(Image(uiImage: shown))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, ImageLoader.shared.cached(url) == nil, let image = await ImageLoader.shared.image(for: url) else { return }
            loaded = (url, image)
        }
    }
}

struct ChannelLogo: View {
    let channel: LiveChannel
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
            if let thumb = channel.thumb, let url = URL(string: thumb) {
                CachedArtwork(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit).padding(size * 0.12)
                } placeholder: { number }
            } else {
                number
            }
        }
        .frame(width: size, height: size)
    }

    private var number: some View {
        Text(channel.number).font(.system(size: size * 0.28, weight: .bold)).foregroundStyle(.white.opacity(0.8))
    }
}

/// Small red dot / label for airings set to record.
struct RecordBadge: View {
    let state: LiveTVStore.RecordState
    var compact = true

    var body: some View {
        switch state {
        case .none: EmptyView()
        case .recording:
            Label(compact ? "REC" : "Recording", systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon).font(.system(size: 10, weight: .heavy)).foregroundStyle(.red)
        case .scheduled, .series:
            Image(systemName: state == .series ? "record.circle" : "record.circle.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                .accessibilityLabel(state == .series ? "Series recording" : "Will record")
        }
    }
}

/// Artwork from the guide, resized by the server.
struct GuideImage: View {
    @Environment(AppState.self) private var app
    let path: String?
    var width = 480, height = 270

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            CachedArtwork(url: app.imageURL(path, width: width, height: height)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "tv").font(.title2).foregroundStyle(.white.opacity(0.25))
            }
        }
        .clipped()
    }
}

// MARK: - On Now

struct OnNowList: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Binding var selected: LiveAiring?
    var onNewCollection: (LiveChannel) -> Void = { _ in }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.visibleChannels) { ch in
                        row(ch, now: context.date)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func row(_ ch: LiveChannel, now: Date) -> some View {
        let airing = store.current(on: ch.id, at: now)
        let next = store.next(on: ch.id, after: now)
        HStack(spacing: 12) {
            Button { store.toggleFavorite(ch) } label: {
                Image(systemName: store.favoriteIDs.contains(ch.id) ? "star.fill" : "star")
            }.accessibilityLabel(store.favoriteIDs.contains(ch.id) ? "Remove \(ch.title) from favorites" : "Favorite \(ch.title)")
            Button { LivePlayerViewController.present(channel: ch, app: app) } label: {
                GuideImage(path: airing?.backdrop, width: 320, height: 180)
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomLeading) {
                        Text(ch.number).font(.system(size: 11, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                    }
                    .overlay {
                        Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch \(ch.title) live")

            Button { if let airing { selected = airing } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(airing?.showTitle ?? ch.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let airing { RecordBadge(state: store.recordState(airing)) }
                    }
                    Text(airing?.episodeLine ?? "\(ch.number) \(ch.title)")
                        .font(.caption).foregroundStyle(Cinema.muted).lineLimit(1)
                    if let airing {
                        HStack(spacing: 6) {
                            ProgressView(value: airing.progress(at: now)).tint(Cinema.accent).frame(maxWidth: 90)
                            Text("\(Fmt.relative(minutes: Int(airing.endsAt.timeIntervalSince(now) / 60))) left")
                                .font(.caption2).foregroundStyle(Cinema.muted)
                        }
                    }
                    if let next {
                        Text("Next \(Fmt.time(next.beginsAt)) · \(next.showTitle)")
                            .font(.caption2).foregroundStyle(Cinema.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(8)
        .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu { ChannelMenuItems(channel: ch, onNewCollection: onNewCollection) }
    }
}

// MARK: - Guide grid

struct GuideView: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Binding var selected: LiveAiring?
    var onNewCollection: (LiveChannel) -> Void = { _ in }
    @State private var offset: CGPoint = .zero
    @State private var viewport: CGSize = .zero

    static let perMinute: CGFloat = 4.4         // 30 minutes ≈ 132pt
    static let rowHeight: CGFloat = 62
    static let channelWidth: CGFloat = 70
    static let rulerHeight: CGFloat = 28

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let start = store.guideStart
            let end = store.loadedUntil
            let width = max(0, CGFloat(end.timeIntervalSince(start) / 60) * Self.perMinute)
            let height = CGFloat(store.visibleChannels.count) * Self.rowHeight
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        GuideRows(channels: store.visibleChannels, airings: store.airings, start: start, end: end,
                                  states: recordStates(), now: context.date, category: store.category) { selected = $0 }
                            .frame(width: width, height: height, alignment: .topLeading)
                            .offset(x: Self.channelWidth, y: Self.rulerHeight)

                        // "Now" line
                        let nowX = CGFloat(context.date.timeIntervalSince(start) / 60) * Self.perMinute
                        if nowX >= 0 && nowX <= width {
                            Rectangle().fill(Cinema.accent).frame(width: 2, height: height + Self.rulerHeight)
                                .offset(x: Self.channelWidth + nowX - 1, y: 0)
                                .allowsHitTesting(false)
                        }

                        // Time ruler, pinned to the top.
                        TimeRuler(start: start, end: end)
                            .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
                            .background(Cinema.background)
                            .offset(x: Self.channelWidth, y: max(0, -offset.y))

                        // Channel column, pinned to the left.
                        VStack(spacing: 0) {
                            ForEach(store.visibleChannels) { ch in
                                Button { LivePlayerViewController.present(channel: ch, app: app) } label: {
                                    VStack(spacing: 2) {
                                        ChannelLogo(channel: ch, size: 36)
                                        Text(ch.number).font(.system(size: 10, weight: .semibold)).foregroundStyle(Cinema.muted)
                                    }
                                    .frame(width: Self.channelWidth, height: Self.rowHeight)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Watch \(ch.number) \(ch.title)")
                                .contextMenu { ChannelMenuItems(channel: ch, onNewCollection: onNewCollection) }
                            }
                        }
                        .background(Cinema.background)
                        .offset(x: max(0, -offset.x), y: Self.rulerHeight)

                        // Corner cover so the ruler and column don't overlap visibly.
                        Cinema.background.frame(width: Self.channelWidth, height: Self.rulerHeight)
                            .offset(x: max(0, -offset.x), y: max(0, -offset.y))
                    }
                    .frame(width: width + Self.channelWidth, height: height + Self.rulerHeight, alignment: .topLeading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GuideOffsetKey.self, value: g.frame(in: .named("guide")).origin)
                    })
                }
                .coordinateSpace(name: "guide")
                .modifier(ScrollOriginTracker { origin in
                    offset = origin
                    // Near the right edge: fetch more guide.
                    if -origin.x + geo.size.width > width + Self.channelWidth - 400, let api = app.api {
                        Task { await store.loadMore(api: api) }
                    }
                })
            }
        }
    }

    private func recordStates() -> [String: LiveTVStore.RecordState] {
        var out: [String: LiveTVStore.RecordState] = [:]
        for row in store.airings.values {
            for a in row {
                let s = store.recordState(a)
                if s != .none { out[a.id] = s }
            }
        }
        return out
    }
}

/// Reports the content's origin as it scrolls (negative = scrolled), for pinned guide parts.
private struct ScrollOriginTracker: ViewModifier {
    let onChange: (CGPoint) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGPoint.self) { geo in
                CGPoint(x: -(geo.contentOffset.x + geo.contentInsets.leading), y: -(geo.contentOffset.y + geo.contentInsets.top))
            } action: { _, origin in
                onChange(origin)
            }
        } else {
            content.onPreferenceChange(GuideOffsetKey.self) { onChange($0) }
        }
    }
}

private struct GuideOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct TimeRuler: View {
    let start: Date
    let end: Date

    var body: some View {
        let slots = Int(end.timeIntervalSince(start) / 1800)
        ZStack(alignment: .topLeading) {
            ForEach(0..<max(slots, 0), id: \.self) { i in
                let t = start.addingTimeInterval(TimeInterval(i) * 1800)
                Text(i == 0 || Calendar.current.component(.hour, from: t) == 0 && Calendar.current.component(.minute, from: t) == 0
                     ? t.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : Fmt.time(t))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Cinema.muted)
                    .offset(x: CGFloat(i) * 30 * GuideView.perMinute + 6, y: 6)
            }
        }
    }
}

/// All guide cells. Separate (and Equatable) so scrolling only moves the pinned parts.
private struct GuideRows: View, Equatable {
    let channels: [LiveChannel]
    let airings: [String: [LiveAiring]]
    let start: Date
    let end: Date
    let states: [String: LiveTVStore.RecordState]
    let now: Date
    /// Programs outside this category are dimmed.
    var category: GuideCategory?
    let onSelect: (LiveAiring) -> Void

    static func == (a: GuideRows, b: GuideRows) -> Bool {
        a.channels == b.channels && a.airings == b.airings && a.start == b.start && a.end == b.end
            && a.states == b.states && Int(a.now.timeIntervalSince1970 / 60) == Int(b.now.timeIntervalSince1970 / 60)
            && a.category == b.category
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(channels) { ch in
                ZStack(alignment: .topLeading) {
                    ForEach(airings[ch.id] ?? []) { a in
                        cell(a)
                    }
                }
                .frame(height: GuideView.rowHeight, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private func cell(_ a: LiveAiring) -> some View {
        let from = max(a.beginsAt, start), to = min(a.endsAt, end)
        if to > from {
            let x = CGFloat(from.timeIntervalSince(start) / 60) * GuideView.perMinute
            let w = CGFloat(to.timeIntervalSince(from) / 60) * GuideView.perMinute
            let onAir = a.isOnAir(at: now)
            Button { onSelect(a) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if a.beginsAt < start { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                        Text(a.showTitle).font(.caption.weight(.semibold)).lineLimit(1)
                        if let s = states[a.id] { RecordBadge(state: s) }
                    }
                    Text(a.episodeLine ?? Fmt.timeRange(a.beginsAt, a.endsAt))
                        .font(.caption2).foregroundStyle(Cinema.muted).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(width: max(w - 3, 0), height: GuideView.rowHeight - 4, alignment: .leading)
                .background(onAir ? Color.white.opacity(0.13) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    if a.isPremiere { Capsule().fill(Cinema.accent).frame(width: 3).padding(.vertical, 10) }
                }
                .foregroundStyle(.white)
                .opacity(category.map { $0.matches(a) } ?? true ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .offset(x: x, y: 2)
        }
    }
}

// MARK: - Program sheet

struct ProgramSheet: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let airing: LiveAiring
    /// Asks the presenter to start this channel once the sheet is gone.
    var watch: (LiveChannel) -> Void = { _ in }
    @State private var options: [RecordingOption] = []
    @State private var others: [LiveAiring] = []
    @State private var working = false
    @State private var error: String?
    @State private var seriesOption: RecordingOption?

    var body: some View {
        let state = store.recordState(airing)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GuideImage(path: airing.backdrop, width: 960, height: 540)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(LinearGradient(colors: [.clear, Cinema.background], startPoint: .center, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 8) {
                    Text(airing.showTitle).font(Cinema.title(34)).textCase(.uppercase).lineLimit(2).minimumScaleFactor(0.6)
                    if let line = airing.episodeLine { Text(line).font(.headline).foregroundStyle(.white.opacity(0.85)) }
                    Text("\(airing.timeRange) · \(airing.channelNumber ?? "") \(store.channel(airing.channelID)?.title ?? "")")
                        .font(.subheadline).foregroundStyle(Cinema.muted)
                    HStack(spacing: 6) {
                        if airing.isPremiere { chip("NEW", highlight: true) }
                        if let r = airing.contentRating { chip(r) }
                        if let res = airing.resolution, let n = Int(res), n >= 720 { chip("HD") }
                        ForEach(airing.genres.prefix(2), id: \.self) { chip($0) }
                        RecordBadge(state: state, compact: false)
                    }
                }
                .padding(.horizontal)

                actions(state)
                    .padding(.horizontal)

                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }

                if let summary = airing.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.white.opacity(0.8)).padding(.horizontal)
                }

                let upcoming = others.filter { $0.id != airing.id && $0.endsAt > Date() }
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other Airings").font(.headline)
                        ForEach(upcoming.prefix(6)) { other in
                            HStack {
                                Text(other.timeRange).font(.subheadline)
                                Spacer()
                                Text("\(other.channelNumber ?? "") \(store.channel(other.channelID)?.title ?? "")")
                                    .font(.caption).foregroundStyle(Cinema.muted)
                                RecordBadge(state: store.recordState(other))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Cinema.background)
        // Tall enough that Watch Live and the record buttons show without scrolling.
        .presentationDetents([.fraction(0.85), .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .sheet(item: $seriesOption) { option in
            RecordSeriesSheet(airing: airing, option: option) { dismiss() }
        }
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text).font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(highlight ? Cinema.accent : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(highlight ? Color.black : .white)
    }

    @ViewBuilder private func actions(_ state: LiveTVStore.RecordState) -> some View {
        VStack(spacing: 10) {
            if let warning = store.conflictMessage(for: airing) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if airing.isOnAir(), let ch = store.channel(airing.channelID) {
                Button {
                    watch(ch)
                    dismiss()
                } label: {
                    Label("Watch Live", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(CinemaPlayButtonStyle())
            }
            HStack(spacing: 10) {
                if let rule = store.oneShotRule(for: airing), state != .none {
                    recordButton("Don't Record", icon: "record.circle", destructive: true) { try await cancel(rule) }
                } else if state == .none || state == .series {
                    if let single = options.first(where: { !$0.isSeries }) {
                        recordButton(airing.isEpisode ? "Record Episode" : "Record", icon: "record.circle") {
                            try await record(single)
                        }
                        .disabled(state == .series)
                    }
                }
                if let rule = store.seriesRule(for: airing) {
                    recordButton("Stop Series", icon: "stop.circle", destructive: true) { try await cancel(rule) }
                } else if let series = options.first(where: \.isSeries) {
                    Button { seriesOption = series } label: {
                        Label("Record Series…", systemImage: "square.stack.3d.down.right").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(working)
            if options.isEmpty && !working {
                Text(airing.endsAt < Date() ? "This airing has ended." : "Loading recording options…")
                    .font(.caption).foregroundStyle(Cinema.muted)
            }
        }
    }

    private func recordButton(_ title: String, icon: String, destructive: Bool = false,
                              action: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                working = true
                defer { working = false }
                do { try await action(); error = nil } catch { self.error = error.localizedDescription }
            }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .background(Cinema.glass, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(destructive ? .red : .white)
    }

    private func load() async {
        guard let api = app.api else { return }
        if let guid = airing.guid { options = (try? await api.recordingOptions(guid: guid)) ?? [] }
        if let key = airing.key { others = (try? await api.liveProgram(key)) ?? [] }
    }

    private func record(_ option: RecordingOption) async throws {
        guard let api = app.api else { return }
        try await store.record(option, prefs: [:], airing: airing, autoDownload: nil, api: api)
    }

    private func cancel(_ rule: LiveSubscription) async throws {
        guard let api = app.api else { return }
        try await store.cancel(rule, api: api)
    }
}

// MARK: - Series options

struct RecordSeriesSheet: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let airing: LiveAiring
    let option: RecordingOption
    var onDone: () -> Void = {}

    @State private var newOnly = true
    @State private var keep = "0"
    @State private var channel = ""
    @State private var download = false
    @State private var downloadKeep = 3
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let warning = store.conflictMessage(for: airing) {
                    Section { Text(warning).foregroundStyle(.orange) }
                }
                Section {
                    Toggle("New Episodes Only", isOn: $newOnly)
                    if let keepSetting = option.setting("autoDeletionItemPolicyUnwatchedLibrary"), !keepSetting.choices.isEmpty {
                        Picker("Keep", selection: $keep) {
                            ForEach(keepSetting.choices, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                    if let ch = option.setting("lineupChannel"), ch.choices.count > 1 {
                        Picker("Channel", selection: $channel) {
                            ForEach(ch.choices, id: \.value) { Text($0.label).tag($0.value) }
                        }
                    }
                }
                Section {
                    Toggle("Download to This iPhone", isOn: $download)
                    if download {
                        Picker("Keep on iPhone", selection: $downloadKeep) {
                            ForEach(SmartDownloads.keepChoices, id: \.self) { Text("\($0) episode\($0 == 1 ? "" : "s")").tag($0) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .pageTitle(airing.showTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { Task { await save() } }.disabled(working)
                }
            }
            .onAppear {
                newOnly = option.setting("onlyNewAirings")?.value != "0"
                keep = option.setting("autoDeletionItemPolicyUnwatchedLibrary")?.value ?? "0"
                channel = option.setting("lineupChannel")?.value ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let api = app.api else { return }
        working = true
        defer { working = false }
        var prefs = ["onlyNewAirings": newOnly ? "1" : "0", "autoDeletionItemPolicyUnwatchedLibrary": keep]
        if option.setting("lineupChannel") != nil { prefs["lineupChannel"] = channel }
        do {
            try await store.record(option, prefs: prefs, airing: airing, autoDownload: download ? downloadKeep : nil, api: api)
            dismiss()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Recordings

struct RecordingsList: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Binding var selected: LiveAiring?
    @State private var editing: LiveSubscription?
    /// Finished recordings, found in the library from each recording rule (as on Apple TV).
    @State private var recorded: [PlexMetadata] = []

    var body: some View {
        let now = store.scheduled.filter(\.isRecording)
        let upcoming = store.scheduled.filter { !$0.isRecording }
        let series = store.rules.filter(\.isSeries)
        List {
            if now.isEmpty && upcoming.isEmpty && series.isEmpty && recorded.isEmpty {
                EmptyStateView(title: "Nothing Scheduled", systemImage: "record.circle",
                               message: "Tap a program in the guide to record it, or record every new episode of a series.")
                    .listRowBackground(Color.clear)
            }
            if !now.isEmpty {
                Section("Recording Now") { ForEach(now) { grabRow($0) } }
            }
            if !upcoming.isEmpty {
                Section("Upcoming") { ForEach(upcoming) { grabRow($0) } }
            }
            if !series.isEmpty {
                Section("Series") {
                    ForEach(series) { rule in
                        Button { editing = rule } label: {
                            HStack(spacing: 12) {
                                GuideImage(path: rule.itemThumb, width: 120, height: 180)
                                    .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.itemTitle).font(.subheadline.weight(.semibold))
                                    Text(seriesSummary(rule)).font(.caption).foregroundStyle(Cinema.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Cinema.muted)
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            if !recorded.isEmpty {
                Section("Recorded") {
                    ForEach(recorded) { item in
                        NavigationLink(value: item.route) {
                            HStack(spacing: 12) {
                                PlexImage(path: item.posterThumb ?? item.thumb, width: 120, height: 180)
                                    .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if let n = item.leafCount { Text("\(n) episode\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(Cinema.muted) }
                                    else if let y = item.year { Text(String(y)).font(.caption).foregroundStyle(Cinema.muted) }
                                }
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { SeriesRuleSheet(rule: $0) }
        .task(id: store.rules.compactMap(\.guid)) { await loadRecorded() }
    }

    private func loadRecorded() async {
        guard let api = app.api else { return }
        var found: [PlexMetadata] = []
        for guid in store.rules.compactMap(\.guid) {
            guard let item = try? await api.container("/library/all", query: [URLQueryItem(name: "guid", value: guid)]).metadata.first,
                  !found.contains(where: { $0.ratingKey == item.ratingKey }) else { continue }
            found.append(item)
        }
        if !Task.isCancelled { recorded = found }
    }

    @ViewBuilder private func grabRow(_ grab: ScheduledRecording) -> some View {
        if let a = grab.airing {
            Button { selected = a } label: {
                HStack(spacing: 12) {
                    GuideImage(path: a.backdrop, width: 240, height: 136)
                        .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.showTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if grab.isRecording { RecordBadge(state: .recording) }
                        }
                        if let line = a.episodeLine { Text(line).font(.caption).lineLimit(1) }
                        Text("\(a.timeRange) · \(a.channelNumber ?? "")")
                            .font(.caption).foregroundStyle(grab.status == "error" ? .red : Cinema.muted)
                    }
                }
            }
            .foregroundStyle(.white)
            .swipeActions {
                if let rule = store.rules.first(where: { $0.id == grab.subscriptionID && !$0.isSeries }) {
                    Button(role: .destructive) {
                        Task { if let api = app.api { try? await store.cancel(rule, api: api) } }
                    } label: { Label("Don't Record", systemImage: "trash") }
                }
            }
        }
    }

    private func seriesSummary(_ rule: LiveSubscription) -> String {
        var parts = [rule.settings["onlyNewAirings"] == "0" ? "All airings" : "New episodes"]
        if let keep = rule.settings["autoDeletionItemPolicyUnwatchedLibrary"], keep != "0", let n = Int(keep) {
            parts.append(n > 0 ? "keep \(n)" : "keep \(-n) days")
        }
        if store.autoDownloadKeep(for: rule.guid) != nil { parts.append("downloads to iPhone") }
        let count = rule.upcoming.count
        if count > 0 { parts.append("\(count) upcoming") }
        return parts.joined(separator: " · ")
    }
}

struct SeriesRuleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(LiveTVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let rule: LiveSubscription
    @State private var newOnly = true
    @State private var keep = "0"
    @State private var confirmDelete = false
    @State private var error: String?

    private static let keepChoices: [(String, String)] = [("0", "All episodes"), ("5", "5 latest episodes"), ("3", "3 latest episodes"),
                                                           ("1", "Latest episode"), ("-7", "Past 7 days"), ("-30", "Past 30 days")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("New Episodes Only", isOn: $newOnly)
                    Picker("Keep", selection: $keep) {
                        ForEach(Self.keepChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if !rule.upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(rule.upcoming.sorted { ($0.airing?.beginsAt ?? .distantFuture) < ($1.airing?.beginsAt ?? .distantFuture) }) { grab in
                            if let a = grab.airing {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.episodeLine ?? a.title).font(.subheadline)
                                    Text("\(a.timeRange) · \(a.channelNumber ?? "")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Stop Recording Series", role: .destructive) { confirmDelete = true }
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .pageTitle(rule.itemTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
            }
            .confirmationDialog("Stop recording \(rule.itemTitle)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Stop Recording", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Episodes already recorded stay in your library.")
            }
            .onAppear {
                newOnly = rule.settings["onlyNewAirings"] != "0"
                keep = rule.settings["autoDeletionItemPolicyUnwatchedLibrary"] ?? "0"
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let api = app.api else { return }
        do {
            try await store.update(rule, prefs: ["onlyNewAirings": newOnly ? "1" : "0", "autoDeletionItemPolicyUnwatchedLibrary": keep], api: api)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        guard let api = app.api else { return }
        do { try await store.cancel(rule, api: api); dismiss() } catch { self.error = error.localizedDescription }
    }
}
