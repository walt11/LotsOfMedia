import SwiftUI
import TVServices

/// Home: a spotlight on whatever is focused (its artwork fills the screen behind the page),
/// then Continue Watching and the server's own recommendation rows.
struct TVHomeView: View {
    @Environment(TVSession.self) private var session
    private var spotlight: TVSpotlight { .shared }
    @State private var continueWatching: [PlexMetadata] = []
    @State private var hubs: [PlexHub] = []
    @State private var loaded = false
    @State private var playing: TVPlayRequest?
    @State private var opening: PlexMetadata?

    var body: some View {
        Group {
            if session.status != .connected && !loaded {
                TVConnectionStatus()
            } else {
                ZStack(alignment: .topLeading) {
                TVAmbientBackdrop(item: spotlight.item)
                TVPageScrollView {
                    LazyVStack(alignment: .leading, spacing: 44) {
                        TVSpotlightHeader(item: spotlight.item)
                            .padding(.horizontal, 80)
                            .frame(height: 380, alignment: .bottomLeading)
                        if !continueWatching.isEmpty {
                            TVRow(title: "Continue Watching") {
                                ForEach(continueWatching) { item in
                                    TVWideCard(item: item) { playing = TVPlayRequest(item: item, resume: true) }
                                        .playsOnPlayPause(item)
                                        .contextMenu { continueMenu(item) }
                                }
                            }
                        }
                        ForEach(hubs) { hub in
                            TVRow(title: hub.title) {
                                ForEach(hub.metadata) { item in
                                    NavigationLink(value: item) { TVPosterCard(item: item) }.playsOnPlayPause(item).buttonStyle(.borderless)
                                }
                            }
                        }
                        if loaded && continueWatching.isEmpty && hubs.isEmpty {
                            Text("Nothing here yet. Add media to your Plex server to see it here.")
                                .foregroundStyle(.secondary).padding(.horizontal, 80)
                        }
                    }
                    .padding(.bottom, 60)
                }
                }
            }
        }
        .task(id: "\(session.status == .connected)-\(session.contentVersion)") { await load() }
        .fullScreenCover(item: $playing) { TVPlayerView(request: $0) }
        .navigationDestination(item: $opening) { TVDetailView(item: $0) }
    }

    /// Press and hold a Continue Watching card.
    @ViewBuilder private func continueMenu(_ item: PlexMetadata) -> some View {
        Button { playing = TVPlayRequest(item: item, resume: true) } label: { Label("Resume", systemImage: "play.fill") }
        Button { playing = TVPlayRequest(item: item, resume: false) } label: { Label("Play From Beginning", systemImage: "gobackward") }
        Button { opening = item } label: { Label(item.kind == .episode ? "Go to Episode" : "Go to Details", systemImage: "info.circle") }
        if item.kind == .episode, let show = item.grandparentRatingKey {
            Button {
                Task { if let s = try? await session.api?.metadata(show) { opening = s } }
            } label: { Label("Go to Show", systemImage: "tv") }
        }
        Button { Task { await session.setWatched(item, true) } } label: { Label("Mark Watched", systemImage: "eye") }
        Button {
            Task {
                continueWatching.removeAll { $0.id == item.id }
                try? await session.api?.removeFromContinueWatching(item.ratingKey)
                session.contentVersion += 1
            }
        } label: { Label("Remove from Continue Watching", systemImage: "minus.circle") }
    }

    private func load() async {
        guard let api = session.api, session.status == .connected else { return }
        let profile = session.user?.uuid
        async let cw = try? api.continueWatching()
        async let h = try? api.homeHubs()
        let watching = await cw ?? []
        // A load that outlived a profile or server switch: its list is the previous one's, and
        // saving it would put their Continue Watching on the Top Shelf under the new profile.
        guard !Task.isCancelled, session.user?.uuid == profile, session.api?.serverID == api.serverID else { return }
        continueWatching = watching
        saveTopShelf()
        // Continue Watching is shown above; skip hubs with nothing a TV can open.
        let shownAbove = ["continuewatching", "ondeck", "inprogress", "home.continue"]
        hubs = (await h ?? []).filter { hub in
            let id = (hub.hubIdentifier ?? "").lowercased()
            return !hub.metadata.isEmpty && !shownAbove.contains { id.contains($0) } && hub.title != "Continue Watching"
                && hub.metadata.contains { [.movie, .show, .season, .episode, .album, .artist, .collection, .playlist].contains($0.kind) }
        }
        spotlight.seed(continueWatching.first ?? hubs.first?.metadata.first)
        loaded = true
    }
}

extension TVHomeView {
    /// Continue Watching for the Top Shelf (shown when the app is in the Home screen's top row).
    fileprivate func saveTopShelf() {
        TopShelfSnapshot(items: continueWatching.prefix(10).map { item in
            TopShelfSnapshot.Item(ratingKey: item.ratingKey, title: item.tvCardTitle,
                                  subtitle: item.kind == .episode ? item.subtitleLine : Fmt.remaining(ms: item.duration, offset: item.viewOffset),
                                  imageURL: session.imageURL(item.posterThumb, width: 600, height: 900), progress: item.progress)
        }, serverID: session.api?.serverID, userID: session.user?.uuid,
           userName: session.canSwitchUsers ? session.currentHomeUser?.title ?? session.user?.title : nil,
           posterArt: true).save()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}

// MARK: - Rows and cards

struct TVRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) { content }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 30)   // room for the focus lift
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A poster with its title underneath; lifts when focused.
struct TVPosterCard: View {
    @Environment(\.isFocused) private var focused
    let item: PlexMetadata
    var width: CGFloat = 250

    private var square: Bool { [.album, .artist, .track, .playlist].contains(item.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVImage(path: item.posterThumb ?? item.thumb, width: 500, height: square ? 500 : 750,
                    placeholderIcon: square ? "music.note" : "film")
                .frame(width: width, height: square ? width : width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .bottom) { TVProgressBar(item: item) }
                .hoverEffect(.highlight)
            Text(item.tvCardTitle).font(.callout.weight(.semibold)).lineLimit(1)
                .foregroundStyle(focused ? .white : .white.opacity(0.7))
            Text(item.tvCardSubtitle ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .opacity(focused ? 1 : 0.7)
        }
        .frame(width: width)
        .offset(y: focused ? 8 : 0)   // the title follows the lifted poster
        .animation(.easeOut(duration: 0.18), value: focused)
        .clearsSpotlight()
    }
}

/// Wide artwork for Continue Watching, with progress and what's left.
struct TVWideCard: View {
    let item: PlexMetadata
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVImage(path: item.tvWideArt, width: 960, height: 540)
                .frame(width: 480, height: 270)
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.tvCardTitle).font(.headline).lineLimit(1)
                        Text([item.kind == .episode ? item.subtitleLine : nil,
                              Fmt.remaining(ms: item.duration, offset: item.viewOffset)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: item.progress ?? 0).tint(TVTheme.accent)
                    }
                    .padding(20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .reportsSpotlight(item)
        }
        .buttonStyle(.card)
    }
}

struct TVProgressBar: View {
    let item: PlexMetadata
    var body: some View {
        if let p = item.progress, p > 0 {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.6))
                    Capsule().fill(TVTheme.accent).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6)
            .padding(10)
        } else if item.isWatched, item.isPlayableVideo {
            HStack { Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(TVTheme.accent).padding(10) }
        }
    }
}
