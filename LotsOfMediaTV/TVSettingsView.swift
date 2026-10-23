import SwiftUI

/// Settings: who's signed in and the server on the left; grouped rows on the right.
struct TVSettingsView: View {
    @Environment(TVSession.self) private var session
    @Environment(ProStore.self) private var store
    @State private var showPaywall = false
    @State private var showJellyfin = false
    @State private var showAddPlex = false
    @State private var userToSwitch: PlexHomeUser?
    @State private var switchError: String?
    @State private var confirmSignOut = false
    @State private var builtInPlayer = BuiltInPlayer.isEnabled
    @State private var evenOutVolume = VolumeLeveling.isOn
    @State private var passthrough = TVAudioOutput.passthrough
    @State private var stereoOnly = TVAudioOutput.stereoOnly
    @State private var askWhoIsWatching = TVProfilePicker.isEnabled
    @State private var videoQuality = TVVideoQuality.fixed

    private var displayName: String {
        session.jellyfinUser ?? session.currentHomeUser?.title ?? session.user?.title ?? session.user?.username ?? "Plex user"
    }
    private var avatarPath: String? { session.jellyfinUser != nil ? nil : session.currentHomeUser?.thumb ?? session.user?.thumb }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            profilePanel.frame(width: 520)
            TVPageScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    if session.canSwitchUsers { profiles }
                    playback
                    servers
                    pro
                    about
                    if session.token != nil {
                        TVSettingsGroup {
                            Button { confirmSignOut = true } label: {
                                TVSettingsRow(icon: "rectangle.portrait.and.arrow.right", tint: .red, title: "Sign Out of Plex",
                                              subtitle: session.user?.email ?? session.user?.username)
                            }
                        }
                    }
                }
                .padding(.vertical, 40)
                .padding(.horizontal, 30)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 90)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showPaywall) { ProPaywallView() }
        .fullScreenCover(item: $userToSwitch) { user in
            TVPinPad(user: user) { pin in
                try await session.switchUser(user, pin: pin)
                userToSwitch = nil
            } cancel: { userToSwitch = nil }
        }
        .alert("Sign out of Plex?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { session.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("LotsOfMedia Pro", isPresented: Binding(get: { store.message != nil && !showPaywall }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .task { await store.loadProduct() }
        .onChange(of: store.isUnlocked) { builtInPlayer = BuiltInPlayer.isEnabled }
    }

    // MARK: Left panel

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 22) {
                TVAvatar(path: avatarPath, name: displayName, size: 170)
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName).font(.system(size: 52, weight: .bold)).lineLimit(2)
                    if session.jellyfinUser != nil {
                        Text("Jellyfin account").font(.callout).foregroundStyle(.secondary)
                    } else if let username = session.user?.username, username != displayName {
                        Text(username).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if let server = session.selectedServer {
                HStack(alignment: .top, spacing: 14) {
                    Circle().fill(statusColor).frame(width: 14, height: 14).padding(.top, 13)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(.headline)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if store.isUnlocked {
                Label("LotsOfMedia Pro", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TVTheme.accent)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(TVTheme.accent.opacity(0.15), in: Capsule())
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("LotsOfMedia \(PlexClient.version)")
                Text("© 2026 John Walter. All rights reserved.")
                Text("Plex is a trademark of Plex, Inc. LotsOfMedia is not affiliated with Plex.")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 40)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusColor: Color {
        switch session.status {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    /// "Plex · Local", "Jellyfin · Remote"; the selected server's connection as it is now.
    private func serverSubtitle(_ server: PlexServer, selected: Bool) -> String {
        guard selected else { return server.kindLabel(local: server.lastConnectionIsLocal) }
        switch session.status {
        case .connected: return server.kindLabel(local: session.isLocalConnection)
        case .connecting: return server.kindName + " · Connecting…"
        case .failed: return server.kindName + " · Unavailable"
        case .idle: return server.kindLabel(local: server.lastConnectionIsLocal)
        }
    }

    private var statusText: String {
        switch session.status {
        case .connected: session.isLocalConnection ? "Connected · Local network" : "Connected · Remote"
        case .connecting: "Connecting…"
        case .failed: "Unavailable"
        case .idle: "Not connected"
        }
    }

    // MARK: Groups

    private var profiles: some View {
        TVSettingsGroup("Profiles", footer: switchError) {
            Button {
                askWhoIsWatching.toggle()
                TVProfilePicker.isEnabled = askWhoIsWatching
            } label: {
                TVSettingsRow(icon: "person.2.fill", tint: .teal, title: "Ask Who's Watching", subtitle: "When LotsOfMedia opens") {
                    if store.isUnlocked { TVOnOff(on: askWhoIsWatching) } else { TVProBadge() }
                }
            }
            ForEach(session.homeUsers) { user in
                Button {
                    guard ProStore.require(.homeUsers), user.uuid != session.user?.uuid else { return }
                    if user.isProtected { userToSwitch = user } else { Task { await switchTo(user, pin: nil) } }
                } label: {
                    TVSettingsRow(title: user.title, subtitle: user.isProtected ? "PIN protected" : nil) {
                        TVAvatar(path: user.thumb, name: user.title, size: 52)
                    } trailing: {
                        if user.uuid == session.user?.uuid {
                            Image(systemName: "checkmark").font(.headline)
                        } else if !store.isUnlocked {
                            TVProBadge()
                        }
                    }
                }
            }
        }
    }

    private var playback: some View {
        TVSettingsGroup("Playback") {
            Button {
                // Automatic, then each quality from Original down, then back to Automatic.
                let all = StreamingQuality.allCases
                if let current = videoQuality, let i = all.firstIndex(of: current) {
                    videoQuality = i + 1 < all.count ? all[i + 1] : nil
                } else {
                    videoQuality = all.first
                }
                TVVideoQuality.fixed = videoQuality
            } label: {
                TVSettingsRow(icon: "dial.medium.fill", tint: .blue, title: "Video Quality") {
                    Text(videoQuality?.label ?? "Automatic").font(.headline)
                }
            }
            Button {
                guard ProStore.require(.builtInPlayer) else { return }
                builtInPlayer.toggle()
                BuiltInPlayer.isEnabled = builtInPlayer
            } label: {
                TVSettingsRow(icon: "play.rectangle.fill", tint: .orange, title: "Built-in Player", subtitle: "For formats Apple TV can't play") {
                    if store.isUnlocked { TVOnOff(on: builtInPlayer) } else { TVProBadge() }
                }
            }
            Button {
                evenOutVolume.toggle()
                VolumeLeveling.isOn = evenOutVolume
            } label: {
                TVSettingsRow(icon: "speaker.wave.2.fill", tint: .green, title: "Even Out Volume") {
                    TVOnOff(on: evenOutVolume)
                }
            }
            Button {
                stereoOnly.toggle()
                TVAudioOutput.stereoOnly = stereoOnly
            } label: {
                TVSettingsRow(icon: "hifispeaker.2.fill", tint: .teal, title: "Stereo Only", subtitle: "Mix surround sound down to two channels") {
                    TVOnOff(on: stereoOnly)
                }
            }
            Button {
                passthrough.toggle()
                TVAudioOutput.passthrough = passthrough
            } label: {
                TVSettingsRow(icon: "hifireceiver.fill", tint: .purple, title: "Audio Passthrough",
                              subtitle: "Built-in player: send Dolby and DTS untouched to your receiver") {
                    TVOnOff(on: passthrough)
                }
            }
        }
    }

    private var servers: some View {
        TVSettingsGroup("Server") {
            ForEach(session.servers) { server in
                let selected = server.id == session.selectedServer?.id
                Button { Task { await session.select(server) } } label: {
                    TVSettingsRow(icon: "server.rack", tint: server.isJellyfin ? .purple : .indigo, title: server.name,
                                  subtitle: serverSubtitle(server, selected: selected)) {
                        if selected {
                            if session.status == .connecting { ProgressView() } else { Image(systemName: "checkmark").font(.headline) }
                        }
                    }
                }
                .contextMenu {
                    if server.isJellyfin {
                        Button("Sign Out of \(server.name)", role: .destructive) { Task { await session.removeServer(server) } }
                    } else if server.isManual {
                        Button("Remove \(server.name)", role: .destructive) { Task { await session.removeServer(server) } }
                    }
                }
            }
            Button { showAddPlex = true } label: {
                TVSettingsRow(icon: "plus", tint: .orange, title: "Add Plex Server")
            }
            Button { showJellyfin = true } label: {
                TVSettingsRow(icon: "plus", tint: .purple, title: "Add Jellyfin Server")
            }
        }
        .fullScreenCover(isPresented: $showJellyfin) { TVJellyfinSignInView() }
        .fullScreenCover(isPresented: $showAddPlex) { TVAddPlexServerView() }
    }

    @ViewBuilder private var pro: some View {
        if !store.isUnlocked {
            TVSettingsGroup("LotsOfMedia Pro") {
                Button { showPaywall = true } label: {
                    TVSettingsRow(icon: "star.fill", tint: .yellow, title: "Unlock Pro",
                                  subtitle: "Profiles, the built-in player and more") {
                        if let price = store.price { Text(price).font(.headline) }
                    }
                }
                Button { Task { await store.restore() } } label: {
                    TVSettingsRow(icon: "arrow.clockwise", tint: .gray, title: "Restore Purchase")
                }
            }
        }
    }

    private var about: some View {
        TVSettingsGroup("About") {
            NavigationLink { TVAcknowledgementsView() } label: {
                TVSettingsRow(icon: "doc.text.fill", tint: .gray, title: "Acknowledgements", subtitle: "VLCKit license") {
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold))
                }
            }
        }
    }

    private func switchTo(_ user: PlexHomeUser, pin: String?) async {
        switchError = nil
        do { try await session.switchUser(user, pin: pin) } catch { switchError = error.localizedDescription }
    }
}

// MARK: - Building blocks

/// A titled stack of rows with an optional note underneath.
struct TVSettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            VStack(spacing: 10) { content }
                .buttonStyle(TVSettingsRowStyle())
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
        }
        .focusSection()
    }
}

/// Icon (or any leading view), title and subtitle, and a value on the right.
struct TVSettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let leading: Leading
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.leading = leading(); self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 24) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.caption).opacity(0.65).lineLimit(1) }
            }
            Spacer(minLength: 20)
            trailing
        }
    }
}

extension TVSettingsRow where Leading == TVSettingsIcon {
    init(icon: String, tint: Color, title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, leading: { TVSettingsIcon(symbol: icon, tint: tint) }, trailing: trailing)
    }
}

extension TVSettingsRow where Leading == TVSettingsIcon, Trailing == EmptyView {
    init(icon: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// White symbol on a colored rounded square, like the system Settings app.
struct TVSettingsIcon: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// Rows lift and turn white under focus.
struct TVSettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : TVTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(focused ? 1.03 : (configuration.isPressed ? 0.98 : 1))
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A switch-like On/Off capsule (tvOS has no toggle switch).
struct TVOnOff: View {
    let on: Bool
    var body: some View {
        Text(on ? "On" : "Off")
            .font(.callout.weight(.semibold))
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 20).padding(.vertical, 6)
            .background(on ? Color.green : Color.gray.opacity(0.35), in: Capsule())
    }
}

struct TVProBadge: View {
    var body: some View {
        Text("PRO").font(.caption.weight(.heavy)).tracking(1)
            .foregroundStyle(.black)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(.white, in: Capsule())
    }
}

/// A profile picture, or the name's first letter when there isn't one.
struct TVAvatar: View {
    @Environment(TVSession.self) private var session
    let path: String?
    let name: String
    var size: CGFloat = 60
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.gray.gradient)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: path) {
            guard let url = session.imageURL(path, width: Int(size * 2), height: Int(size * 2)) else { image = nil; return }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.3)) { image = loaded }
        }
    }
}

/// VLCKit's license notice (LGPL 2.1): required with the built-in player.
struct TVAcknowledgementsView: View {
    private var paragraphs: [String] {
        let text = Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        TVPageScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("VLCKit 3.7.3").font(.headline)
                    Text("The built-in video player uses VLCKit by VideoLAN and the VLC authors, licensed under the GNU Lesser General Public License, version 2.1.")
                    Text("VLCKit is included unmodified as a separate dynamic framework (TVVLCKit.framework), which can be replaced with your own build. Its complete source code is available at code.videolan.org/videolan/VLCKit")
                }
                .focusable()
                Text("GNU Lesser General Public License 2.1").font(.headline).padding(.top, 20)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(p).font(.caption.monospaced()).foregroundStyle(.secondary).focusable()
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(80)
        }
        .navigationTitle("Acknowledgements")
    }
}

// MARK: - Who's watching

/// At launch in a Plex Home with Pro: pick who's watching (with their PIN if they have one).
struct TVProfilePicker: View {
    /// Asked for first (a Top Shelf item's PIN-protected profile); Cancel leaves the choice open.
    var suggested: PlexHomeUser? = nil
    @Environment(TVSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var userToSwitch: PlexHomeUser?
    @State private var error: String?

    static let preferenceKey = "tv.askWhoIsWatching"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    var body: some View {
        ZStack {
            if let user = userToSwitch {
                TVPinPad(user: user) { pin in
                    try await session.switchUser(user, pin: pin)
                    dismiss()
                } cancel: { userToSwitch = nil }
            } else {
                profiles
            }
        }
        // Once: Cancel on the suggested profile's PIN leaves the choice open.
        .onAppear { if let suggested { userToSwitch = suggested } }
    }

    private var profiles: some View {
        VStack(spacing: 60) {
            Text("Who's Watching?").font(.system(size: 66, weight: .heavy).width(.compressed))
            HStack(spacing: 60) {
                ForEach(session.homeUsers) { user in
                    Button {
                        // Already them (with their PIN given, if they have one): nothing to switch.
                        if user.uuid == session.currentHomeUser?.uuid || (!user.isProtected && user.uuid == session.user?.uuid) { dismiss() }
                        else if user.isProtected { userToSwitch = user }
                        else { Task { await switchTo(user, pin: nil) } }
                    } label: {
                        VStack(spacing: 18) {
                            TVAvatar(path: user.thumb, name: user.title, size: 200)
                            HStack(spacing: 8) {
                                Text(user.title).font(.headline).lineLimit(1)
                                if user.isProtected { Image(systemName: "lock.fill").font(.caption) }
                            }
                        }
                        .frame(width: 240)
                    }
                    .buttonStyle(TVProfileStyle())
                }
            }
            .focusSection()
            if let error { Text(error).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVTheme.background.ignoresSafeArea())
    }

    private func switchTo(_ user: PlexHomeUser, pin: String?) async {
        error = nil
        do {
            try await session.switchUser(user, pin: pin)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Profile pictures that grow and gain a ring under focus.
private struct TVProfileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        var body: some View {
            configuration.label
                .scaleEffect(focused ? 1.12 : (configuration.isPressed ? 0.96 : 1))
                .opacity(focused ? 1 : 0.7)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
