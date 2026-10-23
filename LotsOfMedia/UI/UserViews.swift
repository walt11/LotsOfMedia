import SwiftUI

/// "Who's Watching?" when the app opens (Plex Home with Pro), as on Apple TV. On by default on
/// a Mac, which a household tends to share; off on iPhone and iPad.
enum WhoIsWatching {
    static let preferenceKey = "askWhoIsWatching"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? ProcessInfo.processInfo.isiOSAppOnMac }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }
}

/// Plex Home profile picker.
struct UserPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pinTarget: PlexHomeUser?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 20)], spacing: 24) {
                    ForEach(app.homeUsers) { user in
                        Button { select(user) } label: { UserAvatar(user: user, isCurrent: user.uuid == app.currentUserID) }
                            .buttonStyle(.plain)
                            .disabled(app.isSwitchingUser)
                    }
                }
                .padding(24)
                if app.isSwitchingUser { ProgressView("Switching…") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote).padding() }
            }
            .pageTitle("Who's Watching?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await app.loadHomeUsers() }
            .sheet(item: $pinTarget) { user in
                PINEntryView(user: user) { pin in
                    try await app.switchUser(to: user, pin: pin)
                    dismiss()
                }
            }
        }
    }

    private func select(_ user: PlexHomeUser) {
        guard user.uuid != app.currentUserID else { dismiss(); return }
        error = nil
        if user.isProtected {
            pinTarget = user
        } else {
            Task {
                do {
                    try await app.switchUser(to: user, pin: nil)
                    dismiss()
                } catch {
                    // Some accounts are protected without advertising it.
                    if case PlexError.unsupported = error { pinTarget = user } else { self.error = error.localizedDescription }
                }
            }
        }
    }
}

struct UserAvatar: View {
    let user: PlexHomeUser
    var isCurrent = false
    var size: CGFloat = 84

    var body: some View {
        VStack(spacing: 8) {
            PlexImage(path: user.thumb, width: 200, height: 200, placeholderIcon: "person.fill")
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(isCurrent ? Cinema.accent : .clear, lineWidth: 3))
                .overlay(alignment: .bottomTrailing) {
                    if user.isProtected {
                        Image(systemName: "lock.fill").font(.caption2)
                            .padding(5).background(.thickMaterial, in: Circle())
                    }
                }
            Text(user.title).font(.subheadline.weight(isCurrent ? .bold : .regular)).lineLimit(1)
            if user.admin { Text("Admin").font(.caption2).foregroundStyle(.secondary) }
            else if user.restricted { Text("Managed").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct PINEntryView: View {
    let user: PlexHomeUser
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            UserAvatar(user: user, size: 72).padding(.top, 32)
            Text("Enter PIN").font(.headline)
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Cinema.accent : Color.secondary.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
            }
            .overlay {
                TextField("", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
            }
            .onTapGesture { focused = true }
            if working { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Button("Cancel") { dismiss() }.padding(.top)
            Spacer()
        }
        .presentationDetents([.medium])
        .onAppear { focused = true }
        .onChange(of: pin) { _, value in
            let digits = String(value.filter(\.isNumber).prefix(4))
            if digits != value { pin = digits; return }
            if digits.count == 4 { Task { await attempt(digits) } }
        }
    }

    private func attempt(_ code: String) async {
        working = true
        error = nil
        do {
            try await submit(code)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            pin = ""
        }
        working = false
    }
}

/// Toolbar button showing the active Home user; opens the picker.
/// Avatar in Home's toolbar: switch Plex Home users and open Settings.
struct UserSwitcherButton: View {
    @Environment(AppState.self) private var app
    @Environment(\.mediaMode) private var mediaMode
    @State private var customizing = false
    @State private var showPicker = false
    @State private var showSettings = false

    var body: some View {
        Menu {
            if let name = app.profileName {
                Text([name, app.selectedServer?.name].compactMap { $0 }.joined(separator: " · "))
            }
            NavigationLink(value: Route.history) {
                Label(mediaMode == .music ? "Listening History" : "Watch History", systemImage: "clock.arrow.circlepath")
            }
            Button { customizing = true } label: { Label("Customize Home", systemImage: "slider.horizontal.3") }
            Divider()
            if app.canSwitchUsers {
                Button { showPicker = true } label: { Label("Switch User", systemImage: "person.2") }
            }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            PlexImage(path: app.profileThumb, width: 80, height: 80, placeholderIcon: "person.fill")
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        }
        .accessibilityLabel("Profile menu")
        .sheet(isPresented: $customizing) { HomeCustomizeView() }
        .sheet(isPresented: $showPicker) { ProGate(.homeUsers) { UserPickerView() } }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                    }
            }
        }
    }
}

// MARK: - Watch history

struct WatchHistoryView: View {
    @Environment(\.mediaMode) private var mediaMode
    @Environment(AppState.self) private var app
    @State private var items: [PlexMetadata] = []
    @State private var loading = true
    @State private var exhausted = false
    @State private var rawCount = 0
    @State private var error: String?

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(value: Route.item(ratingKey: item.ratingKey, title: item.title)) {
                    HStack(spacing: 12) {
                        PlexImage(path: item.kind == .episode ? item.thumb : item.posterThumb ?? item.thumb, width: 200, height: 200,
                                  placeholderIcon: item.kind == .track ? "music.note" : "film")
                            .frame(width: item.kind == .episode ? 96 : 48, height: item.kind == .episode ? 54 : (item.kind == .track ? 48 : 72))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kind == .episode ? (item.grandparentTitle ?? item.title) : item.title)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if item.kind == .episode || item.kind == .track, let sub = item.subtitleLine {
                                Text(item.kind == .episode ? sub : (item.grandparentTitle ?? "")).font(.caption).lineLimit(1)
                            }
                            if let at = item.viewedAt {
                                Text(Date(timeIntervalSince1970: TimeInterval(at)), format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                .listRowBackground(Color.clear)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !loading && !exhausted { Button("Load More") { Task { await loadMore() } } }
            if !loading, items.isEmpty {
                EmptyStateView(title: "No History Yet", systemImage: "clock.arrow.circlepath",
                               message: error ?? (mediaMode == .music ? "Music you play on your devices appears here." : "Things you watch on any device show up here."))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .titleWithDownloadStatus(mediaMode == .music ? "Listening History" : "Watch History")
        .refreshable { await reload() }
        .task(id: app.contentVersion) { await reload() }
    }

    private func reload() async {
        items = []
        rawCount = 0
        exhausted = false
        await loadMore()
    }

    private func loadMore() async {
        guard let api = app.api, !exhausted else { loading = false; return }
        loading = true
        defer { loading = false }
        do {
            // Each viewing is its own history row; show each item once.
            let page = try await api.history(ownServer: app.selectedServer?.owned ?? false, start: rawCount, size: 60)
            rawCount += page.count
            exhausted = page.count < 60
            let seen = Set(items.map(\.id))
            var added = Set<String>()
            items += page.filter { mediaMode.includes($0) && !$0.ratingKey.isEmpty && !seen.contains($0.id) && added.insert($0.id).inserted }
            error = nil
        } catch {
            exhausted = true
            self.error = error.localizedDescription
        }
    }
}
