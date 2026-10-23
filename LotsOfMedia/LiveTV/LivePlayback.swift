import AVKit
import SwiftUI
import Combine

/// Plays a live channel: tunes it on the server, streams the converted
/// broadcast, keeps the server session alive and follows the guide.
@MainActor
final class LivePlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var previousChannel: LiveChannel?
    @Published private(set) var channel: LiveChannel
    @Published private(set) var airing: LiveAiring?
    @Published private(set) var upNext: LiveAiring?
    @Published private(set) var isTuning = true
    @Published private(set) var isBehindLive = false
    @Published private(set) var chromeVisible = true
    @Published var errorMessage: String?
    @Published private(set) var airPlayDevice: String?
    private var externalObservation: NSKeyValueObservation?

    private let api: PlexServerAPI
    private let dvrKey: String
    private let quality: StreamingQuality
    private let isLocal: Bool
    private var session: LiveSession?
    private var sessionID = ""
    private var timeObserver: Any?
    private var itemCancellables = Set<AnyCancellable>()
    private var focusObservation: AnyCancellable?
    private var lastReport = Date.distantPast
    private var stopped = false
    private var chromeTask: Task<Void, Never>?
    private var tuneTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// The previous stream being stopped on the server; the next tune waits for it.
    private var ending: Task<Void, Never>?
    /// Closes the player (back to the guide), set by whoever presented it.
    var close: (() -> Void)?
    private var wentToBackground: Date?

    init(channel: LiveChannel, api: PlexServerAPI, dvrKey: String, quality: StreamingQuality, isLocal: Bool) {
        self.channel = channel
        self.api = api
        self.dvrKey = dvrKey
        self.quality = quality
        self.isLocal = isLocal
        refreshGuideInfo()
    }

    func start() {
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                AirPlayStatus.shared.update()
                self?.airPlayDevice = AirPlayStatus.name(forExternal: player)
            }
        }
        PlaybackFocus.claim(player)
        focusObservation = player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in
                if let self, self.player.timeControlStatus == .playing { PlaybackFocus.claim(self.player) }
            }
        }
        AudioPlayer.shared.pause()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tune(channel)
        noteInteraction()
        // Away from the app (and not playing in picture in picture), the server ends the live
        // session. Coming back after a while, or to a stream that stopped, closes the player and
        // shows the guide, brought up to date, ready to pick a channel again (as on Apple TV).
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wentToBackground = Date() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    let away = self.wentToBackground.map { Date().timeIntervalSince($0) } ?? 0
                    self.wentToBackground = nil
                    let stalled = self.player.currentItem?.status == .failed || self.errorMessage != nil
                    if stalled || (away > 15 && self.player.timeControlStatus != .playing) {
                        let api = self.api
                        Task { await LiveTVStore.shared.refresh(api: api) }
                        self.close?()
                    }
                }
            },
        ]
    }

    /// Changes channel without leaving the player.
    func switchTo(_ new: LiveChannel) {
        guard new.id != channel.id || errorMessage != nil else { return }
        PlaybackFocus.claim(player)
        endSession()
        if new.id != channel.id { previousChannel = channel }
        channel = new
        refreshGuideInfo()
        tune(new)
    }

    private func tune(_ ch: LiveChannel) {
        isTuning = true
        errorMessage = nil
        tuneTask?.cancel()
        guard MediaPreferences.shared.streamAllowed(.watch) else { isTuning = false; errorMessage = "Watch streaming over cellular is disabled in Playback Preferences."; return }
        let previousEnd = ending
        tuneTask = Task {
            // The stream uses this device's identifier, so the old one must be fully stopped
            // first: a late stop would end the new stream (the server then answers 400).
            await previousEnd?.value
            do {
                // A tuner can take a few seconds to free up after the last stream; retry briefly.
                var tuned: LiveSession?
                for attempt in 0..<3 {
                    do { tuned = try await api.tune(dvr: dvrKey, channel: ch.id); break } catch {
                        if attempt == 2 || Task.isCancelled { throw error }
                        try await Task.sleep(for: .seconds(4))
                    }
                }
                guard let s = tuned else { return }
                guard !Task.isCancelled, !stopped, ch.id == channel.id else { return }
                session = s
                LiveTVStore.shared.rememberChannel(ch.id, serverID: api.serverID)
                // The server registers this device (by client identifier) as the live session's
                // viewer, and the converter reads `/livetv/sessions/<id>/<session>/…`, so the
                // stream's session must be the client identifier. Reusing the live session's own
                // ID would replace the tuner capture instead.
                sessionID = PlexClient.identifier
                // The tune response's times describe the server's rolling capture, not the
                // program, so the guide's entry wins when there is one.
                if LiveTVStore.shared.current(on: ch.id) == nil, let a = s.airing { airing = a }
                let url = api.liveStreamURL(session: s, sessionID: sessionID, quality: quality, isLocal: isLocal)
                // Plex sets up the conversion during the decision request; asking for the
                // stream first fails with 400.
                try await api.liveDecision(streamURL: url)
                try await api.waitForLiveSegments(streamURL: url)
                guard !Task.isCancelled, !stopped, ch.id == channel.id else { return }
                load(url)
            } catch {
                guard !Task.isCancelled, ch.id == channel.id else { return }
                isTuning = false
                errorMessage = Self.friendly(error)
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("tuner") || text.localizedCaseInsensitiveContains("tune") {
            return "Couldn't tune this channel. Both tuners may be busy recording, or the signal is too weak right now."
        }
        return text
    }

    private func load(_ url: URL) {
        itemCancellables.removeAll()
        guard MediaPreferences.shared.streamAllowed(.watch) else { isTuning = false; endSession(); errorMessage = "Watch streaming over cellular is disabled in Playback Preferences."; return }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: MediaPreferences.shared.allowsCellular(.watch)]))
        item.externalMetadata = metadataItems()
        item.preferredForwardBufferDuration = 6
        player.replaceCurrentItem(with: item)
        player.allowsExternalPlayback = true
        item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                switch status {
                case .readyToPlay:
                    self.isTuning = false
                    if PlaybackFocus.owns(self.player) { self.player.play() }
                case .failed:
                    self.isTuning = false
                    self.errorMessage = "The live stream stopped. " + (item.error?.localizedDescription ?? "")
                default: break
                }
            }
            .store(in: &itemCancellables)
    }

    func retry() { switchTo(channel) }

    /// Channel up (+1) or down (−1) through the guide's channel order, as on Apple TV.
    func step(_ delta: Int) {
        let list = LiveTVStore.shared.channels
        guard !list.isEmpty, let i = list.firstIndex(where: { $0.id == channel.id }) else { return }
        switchTo(list[(i + delta + list.count) % list.count])
    }

    func jumpToLive() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        PlaybackFocus.claim(player)
        let edge = CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 2, preferredTimescale: 600))
        player.seek(to: edge, toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { [weak self] _ in
            Task { @MainActor in
                if let self, PlaybackFocus.owns(self.player) { self.player.play() }
            }
        }
    }

    private func tick() {
        // Behind live = paused or rewound by more than a few seconds.
        if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
            let lag = CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - CMTimeGetSeconds(player.currentTime())
            let behind = lag.isFinite && lag > 15
            if behind != isBehindLive { isBehindLive = behind }
        }
        if let a = airing, !a.isOnAir() { refreshGuideInfo() }
        if Date().timeIntervalSince(lastReport) >= 10 { report(state: player.timeControlStatus == .paused ? "paused" : "playing") }
    }

    private func refreshGuideInfo() {
        let store = LiveTVStore.shared
        if let now = store.current(on: channel.id) { airing = now }
        upNext = store.next(on: channel.id)
        player.currentItem?.externalMetadata = metadataItems()
    }

    private func metadataItems() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        let title = airing?.showTitle ?? channel.title
        var sub = "\(channel.number) \(channel.title)"
        if let a = airing { sub += " · until \(Fmt.time(a.endsAt))" }
        return [item(.commonIdentifierTitle, title), item(.iTunesMetadataTrackSubTitle, sub),
                item(.commonIdentifierDescription, airing?.summary)].compactMap { $0 }
    }

    /// Keeps the server's live session alive (and shows it in Plex's dashboard).
    @discardableResult
    private func report(state: String) -> Task<Void, Never>? {
        guard let session else { return nil }
        lastReport = Date()
        let t = CMTimeGetSeconds(player.currentTime())
        let ms = t.isFinite ? Int(t * 1000) : 0
        let api = api, sid = sessionID
        return Task.detached {
            try? await api.timeline(ratingKey: session.ratingKey, key: session.path, state: state, timeMs: ms, durationMs: nil, sessionID: sid)
        }
    }

    private func endSession() {
        tuneTask?.cancel()
        itemCancellables.removeAll()
        player.replaceCurrentItem(with: nil)
        guard session != nil else { return }
        let reported = report(state: "stopped")
        let api = api, sid = sessionID
        ending = Task {
            await reported?.value
            await api.stopTranscode(sessionID: sid)
        }
        session = nil
    }

    func stop() {
        guard !stopped else { return }
        if PlaybackSleepTimer.shared.isSet(for: player) { PlaybackSleepTimer.shared.cancel() }
        stopped = true
        player.pause()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        chromeTask?.cancel()
        endSession()
    }

    func noteInteraction() {
        chromeVisible = true
        chromeTask?.cancel()
        chromeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { chromeVisible = false }
        }
    }
}

/// Player screen for live TV. AVKit's player is embedded as a child with our
/// overlay beside it (not inside it): inside AVPlayerViewController, AVKit's own
/// tap handling swallows touches meant for overlay buttons.
final class LivePlayerViewController: UIViewController, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    var playback: LivePlaybackController?
    var onClose: (() -> Void)?
    private let playerVC = AVPlayerViewController()

    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let playback else { return }

        playerVC.player = playback.player
        playerVC.delegate = self
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.updatesNowPlayingInfoCenter = true
        addChild(playerVC)
        playerVC.view.frame = view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        let overlay = UIHostingController(rootView: LivePlayerOverlay(playback: playback) { [weak self] in self?.presentChannels() })
        overlay.view.backgroundColor = .clear
        addChild(overlay)
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay.view)
        // A fixed band under AVKit's top controls (its title and timeline sit at the bottom).
        // Sizing the hosting view to its content left it at its first, empty size, so
        // buttons drew outside its bounds and couldn't be tapped.
        NSLayoutConstraint.activate([
            overlay.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            overlay.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            overlay.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            overlay.view.heightAnchor.constraint(equalToConstant: 150),
        ])
        overlay.didMove(toParent: self)

        let tap = UITapGestureRecognizer(target: self, action: #selector(userTapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        playerVC.view.addGestureRecognizer(tap)
    }

    @objc private func userTapped() { playback?.noteInteraction() }

    // Keyboard (Mac, iPad keyboards): ⌘↑ and ⌘↓ change channel, ⌘L returns to the last one.
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Channel Up", action: #selector(keyChannelUp), input: UIKeyCommand.inputUpArrow, modifierFlags: .command),
            UIKeyCommand(title: "Channel Down", action: #selector(keyChannelDown), input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
            UIKeyCommand(title: "Last Channel", action: #selector(keyLastChannel), input: "l", modifierFlags: .command),
        ]
    }
    @objc private func keyChannelUp() { playback?.step(1) }
    @objc private func keyChannelDown() { playback?.step(-1) }
    @objc private func keyLastChannel() { if let previous = playback?.previousChannel { playback?.switchTo(previous) } }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func presentChannels() {
        guard let playback, presentedViewController == nil else { return }
        let sheet = UIHostingController(rootView: ChannelSwitcher(current: playback.channel.id) { [weak self, weak playback] ch in
            playback?.switchTo(ch)
            self?.dismiss(animated: true)
        }
        .environment(LiveTVStore.shared)
        .preferredColorScheme(.dark)
        .tint(Cinema.accent))
        sheet.overrideUserInterfaceStyle = .dark
        sheet.view.backgroundColor = UIColor(Cinema.background)
        if let s = sheet.sheetPresentationController {
            s.detents = [.medium(), .large()]
            s.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onClose?()
            onClose = nil
        }
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    @MainActor
    static func present(channel: LiveChannel, app: AppState) {
        guard let api = app.api, let dvr = LiveTVStore.shared.dvr, let top = VideoPresenter.topViewController() else { return }
        let playback = LivePlaybackController(channel: channel, api: api, dvrKey: dvr.key,
                                              quality: app.streamingQuality, isLocal: app.isLocalConnection)
        let vc = LivePlayerViewController()
        vc.playback = playback
        vc.modalPresentationStyle = .fullScreen
        playback.close = { [weak vc] in vc?.presentingViewController?.dismiss(animated: true) }
        vc.onClose = { [weak app] in
            Task { @MainActor in
                playback.stop()
                app?.playbackEnded()
            }
        }
        top.present(vc, animated: true) { playback.start() }
    }
}

/// LIVE badge, now/next line, Jump to Live and the channel list button.
struct LivePlayerOverlay: View {
    @ObservedObject var playback: LivePlaybackController
    var showChannels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let device = playback.airPlayDevice { AirPlayPill(deviceName: device) }
            if playback.isTuning && playback.errorMessage == nil {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Tuning \(playback.channel.number) \(playback.channel.title)…").font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if let error = playback.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.subheadline)
                    HStack {
                        Button("Try Again") { playback.retry() }.prominentButton()
                        Button("Other Channels", action: showChannels).buttonStyle(.bordered)
                    }
                }
                .padding(14)
                .frame(maxWidth: 360, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if playback.chromeVisible || playback.isBehindLive {
                HStack(spacing: 10) {
                    SleepTimerMenu(player: playback.player, endLabel: nil).labelStyle(.iconOnly)
                    Button(action: showChannels) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Channels")
                    Button { playback.step(-1) } label: {
                        Image(systemName: "chevron.down").frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Channel Down").disabled(playback.isTuning)
                    Button { playback.step(1) } label: {
                        Image(systemName: "chevron.up").frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Channel Up").disabled(playback.isTuning)
                    if let previous = playback.previousChannel {
                        Button { playback.switchTo(previous) } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }.accessibilityLabel("Return to \(previous.title)").disabled(playback.isTuning)
                    }
                    // The player shows its own LIVE badge; this appears only after rewinding.
                    if playback.isBehindLive {
                        Button { playback.jumpToLive() } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("JUMP TO LIVE").font(.caption.weight(.heavy)).kerning(0.6)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    if let next = playback.upNext {
                        Text("Next \(Fmt.time(next.beginsAt)) · \(next.showTitle)")
                            .font(.caption.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: playback.chromeVisible || playback.isBehindLive)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Channel list with what's on now, for switching channels.
struct ChannelSwitcher: View {
    @Environment(LiveTVStore.self) private var store
    let current: String
    let select: (LiveChannel) -> Void
    @State private var filter = "All"
    @State private var query = ""
    private var channels: [LiveChannel] {
        let base = filter == "Recent" ? store.recentChannelIDs.compactMap { id in store.channels.first { $0.id == id } } : store.channels
        return base.filter { (filter != "Favorites" || store.favoriteIDs.contains($0.id)) && (query.isEmpty || ($0.title + " " + $0.number).localizedStandardContains(query)) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Picker("Channels", selection: $filter) { ForEach(["All", "Favorites", "Recent"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    ForEach(channels) { ch in
                    Button { select(ch) } label: {
                        HStack(spacing: 12) {
                            ChannelLogo(channel: ch, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.current(on: ch.id)?.showTitle ?? ch.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(ch.number) \(ch.title)").font(.caption).foregroundStyle(.secondary)
                                if let next = store.next(on: ch.id) { Text("\(next.beginsAt.formatted(date: .omitted, time: .shortened)): " + next.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if ch.id == current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Cinema.accent) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .id(ch.id)
                    .swipeActions { Button { store.toggleFavorite(ch) } label: { Label("Favorite", systemImage: store.favoriteIDs.contains(ch.id) ? "star.fill" : "star") }.tint(.yellow) }
                    .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Cinema.background)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .searchable(text: $query, prompt: "Channel name or number")
            .pageTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
