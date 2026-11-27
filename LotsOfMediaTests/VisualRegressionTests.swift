import XCTest
import SwiftUI
import Vision
@testable import LotsOfMedia

/// Renders real screens and reads them back with text recognition, so layout
/// regressions (hidden or clipped titles, overflowing text, broken iPad/landscape
/// layouts) fail a test instead of shipping. Every render is attached to the
/// test results for a quick visual look.
@MainActor
final class VisualRegressionTests: XCTestCase {
    struct Seen { let text: String; let frame: CGRect }

    private var window: UIWindow!
    private var previousWindow: UIWindow?
    private var previousMode: Any?
    private var lastImage: UIImage?

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        previousMode = UserDefaults.standard.object(forKey: "mediaMode")
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
    }

    override func tearDown() async throws {
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        previousWindow?.makeKeyAndVisible()
        if let previousMode { UserDefaults.standard.set(previousMode, forKey: "mediaMode") }
        else { UserDefaults.standard.removeObject(forKey: "mediaMode") }
    }

    // MARK: Helpers

    private func environment<V: View>(_ view: V, app: AppState) -> some View {
        view.environment(app)
            .environment(DownloadManager.shared)
            .environment(AudioPlayer.shared)
            .environment(NetworkMonitor.shared)
            .environment(LiveTVStore.shared)
            .environment(ProStore.shared)
            .preferredColorScheme(.dark)
            .tint(Cinema.accent)
    }

    /// Shows `view`, waits for layout, and returns the recognized text in window points.
    private func render<V: View>(_ view: V, name: String, size: CGSize? = nil,
                                 configure: (UIHostingController<V>) -> Void = { _ in }) async throws -> [Seen] {
        let host = UIHostingController(rootView: view)
        configure(host)
        if let size { window.frame = CGRect(origin: .zero, size: size) }
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        lastImage = image
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        let bounds = window.bounds
        return (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let box = obs.boundingBox
            return Seen(text: text, frame: CGRect(x: box.minX * bounds.width, y: (1 - box.maxY) * bounds.height,
                                                  width: box.width * bounds.width, height: box.height * bounds.height))
        }
    }

    private func navigationBars() -> [UINavigationBar] {
        func all(_ v: UIView) -> [UIView] { v.subviews.flatMap { [$0] + all($0) } }
        return all(window).compactMap { $0 as? UINavigationBar }.filter { !$0.isHidden && $0.alpha > 0 }
    }

    /// The page heading is drawn, near the top, fully on screen, aligned to the content margin.
    private func assertHeading(_ heading: String, in seen: [Seen], leftMargin: CGFloat? = 40,
                               file: StaticString = #filePath, line: UInt = #line) {
        let matches = seen.filter { $0.text == heading || $0.text.hasPrefix(heading) }
        XCTAssertFalse(matches.isEmpty, "Heading \"\(heading)\" must be visible", file: file, line: line)
        // The page title is the largest instance (the mode switch also says "Watch"/"Listen").
        guard let h = matches.max(by: { $0.frame.height < $1.frame.height }) else { return }
        XCTAssertLessThan(h.frame.minY, window.bounds.height * 0.4, "\"\(heading)\" must sit at the top of the page", file: file, line: line)
        if let leftMargin {
            XCTAssertLessThan(h.frame.minX, leftMargin, "\"\(heading)\" must align with the left margin", file: file, line: line)
        }
    }

    /// No recognized text runs past the window's edges.
    private func assertNothingClipped(_ seen: [Seen], file: StaticString = #filePath, line: UInt = #line) {
        let bounds = window.bounds.insetBy(dx: -2, dy: -2)
        for s in seen where !bounds.contains(s.frame) {
            XCTFail("Text \"\(s.text)\" extends off screen at \(s.frame)", file: file, line: line)
        }
    }

    private func tabsApp(mode: MediaMode) -> AppState {
        let app = AppState()
        app.mediaMode = mode
        return app
    }

    // MARK: Tabs in both modes

    func testRootTabsInBothModes() async throws {
        for mode in MediaMode.allCases {
            let app = tabsApp(mode: mode)
            for (tab, heading) in [(AppState.Tab.home, mode.title), (.library, "Library"), (.search, "Search"), (.downloads, "Downloads")] {
                app.selectedTab = tab
                let seen = try await render(environment(MainTabView(), app: app), name: "\(mode.title)-\(tab)")
                assertHeading(heading, in: seen)
                assertNothingClipped(seen)
                // The Listen/Watch switch lives in Home's title only; other tabs stay uncluttered.
                let other = mode == .music ? "Watch" : "Listen"
                XCTAssertFalse(seen.contains { $0.text == other }, "No permanent mode switch on \(mode)-\(tab)")
                for bar in navigationBars() {
                    XCTAssertLessThanOrEqual(bar.bounds.height, tab == .search ? 120 : 64, "No extra large-title row on \(mode)-\(tab)")
                }
            }
        }
    }

    // MARK: Pushed pages

    func testPushedPagesShareTheTitleRow() async throws {
        let app = tabsApp(mode: .music)
        let pages: [(String, AnyView)] = [
            ("Watch Later", AnyView(WatchLaterView())),
            ("Mixes", AnyView(MixesView())),
            ("Free Up Space", AnyView(StorageCleanupView())),
            ("Favorites", AnyView(FavoritesView())),
        ]
        for (heading, page) in pages {
            let seen = try await render(environment(NavigationStack { page.withRoutes() }, app: app), name: "Pushed-\(heading)")
            assertHeading(heading, in: seen)
            assertNothingClipped(seen)
            for bar in navigationBars() { XCTAssertLessThanOrEqual(bar.bounds.height, 64, "\(heading) must use one title row") }
        }
    }

    // MARK: Long titles

    func testLongTitleTruncatesInsteadOfOverflowing() async throws {
        let app = tabsApp(mode: .watch)
        let title = "The Extraordinarily Long Title Of A Playlist That Never Seems To End"
        let page = NavigationStack {
            List { Text("Row") }
                .pageTitle(title)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") {} } }
        }
        let seen = try await render(environment(page, app: app), name: "Long-title")
        XCTAssertTrue(seen.contains { $0.text.hasPrefix("The Extra") }, "The start of a long title must stay visible")
        XCTAssertTrue(seen.contains { $0.text == "Edit" }, "Toolbar actions must not be pushed off by a long title")
        assertNothingClipped(seen)
        for bar in navigationBars() { XCTAssertLessThanOrEqual(bar.bounds.height, 64) }
    }

    // MARK: Larger text

    func testLargestTextSizesKeepHeadingsOnScreen() async throws {
        let app = tabsApp(mode: .watch)
        for tab in [AppState.Tab.library, .downloads] {
            app.selectedTab = tab
            let seen = try await render(environment(MainTabView(), app: app), name: "AX-text-\(tab)") { host in
                host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
            }
            assertHeading(tab == .library ? "Library" : "Downloads", in: seen)
            assertNothingClipped(seen)
        }
    }

    func testQualityBadgesWrapOnNarrowLayout() async throws {
        let json = """
        {"ratingKey":"1","type":"movie","title":"Sample","contentRating":"TV-MA","addedAt":\(Int(Date().timeIntervalSince1970)),
        "Media":[{"videoResolution":"4k","audioChannels":8,"Part":[{"Stream":[{"streamType":1,"DOVIPresent":true}]}]}]}
        """
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        let view = QualityChips(item: item)
            .frame(width: 220, alignment: .leading)
            .padding().background(.black)
            .environment(\.dynamicTypeSize, .accessibility2)
        let seen = try await render(view, name: "Narrow-quality-badges")
        let new = try XCTUnwrap(seen.first { $0.text.contains("NEW") })
        let hdr = try XCTUnwrap(seen.first { $0.text.contains("DOLBY") })
        XCTAssertGreaterThan(hdr.frame.midY, new.frame.midY + 8)
        assertNothingClipped(seen)
    }

    // MARK: Disconnected

    /// Once connecting fails, Home says so and offers the next steps instead of endless placeholders.
    func testDisconnectedHomeOffersNextSteps() async throws {
        let savedServer = UserDefaults.standard.string(forKey: "selectedServerID")
        defer { UserDefaults.standard.set(savedServer, forKey: "selectedServerID"); LibraryCache.isOffline = false }
        let app = tabsApp(mode: .watch)
        let den = PlexServer(name: "Den", clientIdentifier: "den", accessToken: "t", owned: true, connections: [], isManual: false)
        app.setForTesting(servers: [den], selected: "den", status: .failed("The request timed out."))
        app.selectedTab = .home
        let seen = try await render(environment(MainTabView(), app: app), name: "Disconnected-Home")
        XCTAssertTrue(seen.contains { $0.text.contains("Reach Den") || $0.text.contains("Offline") }, "Says what's wrong")
        XCTAssertTrue(seen.contains { $0.text.contains("Choose Server") }, "Offers another server")
        if NetworkMonitor.shared.isConnected { XCTAssertTrue(seen.contains { $0.text.contains("Retry") }, "Offers to try again") }
        assertNothingClipped(seen)
    }

    // MARK: Downloads card, populated

    /// Every status at once, the largest text size, a narrow phone: nothing cut off.
    func testReadinessCardWithMixedStatesAtLargeText() async throws {
        func rec(_ key: String, _ state: DownloadRecord.State) throws -> DownloadRecord {
            let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [["ratingKey": key, "type": "movie", "title": key]]]])
            var r = DownloadRecord(serverID: "s", metadata: try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first), quality: .original)
            r.state = state
            return r
        }
        let records = try [rec("a", .completed), rec("b", .completed), rec("c", .preparing), rec("d", .downloading),
                           rec("e", .paused), rec("f", .paused), rec("g", .failed)]
        let app = tabsApp(mode: .watch)
        let view = ScrollView { OfflineReadinessCard(records: records, music: false, userID: nil).padding(.top, 60) }
            .background(Cinema.background)
        let seen = try await render(environment(view, app: app), name: "Readiness-mixed-AX", size: CGSize(width: 375, height: 812)) { host in
            host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        }
        XCTAssertTrue(seen.contains { $0.text.localizedCaseInsensitiveContains("paused") }, "Paused is shown")
        XCTAssertTrue(seen.contains { $0.text.localizedCaseInsensitiveContains("failed") }, "Failed is shown")
        XCTAssertTrue(seen.contains { $0.text.contains("Resume") }, "Resume is offered")
        assertNothingClipped(seen)
    }

    // MARK: Large text with the mini player

    /// The biggest text size, Listen mode, with the mini player showing a long song title.
    func testLargestTextWithMiniPlayer() async throws {
        let json: [String: Any] = ["ratingKey": "9001", "type": "track", "duration": 200_000,
                                   "title": "An Extremely Long Song Title That Keeps Going Well Past the Edge",
                                   "grandparentTitle": "A Band With Quite a Long Name"]
        let data = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [json]]])
        let song = try XCTUnwrap(PlexServerAPI.decodeContainer(data).metadata.first)
        AudioPlayer.shared.play([song], serverID: "none")
        defer { AudioPlayer.shared.stop() }
        let app = tabsApp(mode: .music)
        app.selectedTab = .library
        let seen = try await render(environment(MainTabView(), app: app), name: "AX-text-mini-player") { host in
            host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        }
        assertHeading("Library", in: seen)
        assertNothingClipped(seen)
    }

    // MARK: Landscape

    func testLandscapeLayout() async throws {
        let app = tabsApp(mode: .watch)
        let portrait = window.bounds.size
        let landscape = CGSize(width: max(portrait.width, portrait.height), height: min(portrait.width, portrait.height))
        for (tab, heading) in [(AppState.Tab.library, "Library"), (.downloads, "Downloads")] {
            app.selectedTab = tab
            let seen = try await render(environment(MainTabView(), app: app), name: "Landscape-\(tab)", size: landscape) { host in
                host.traitOverrides.verticalSizeClass = .compact
            }
            // Landscape adds safe-area insets on the sides, so the margin is wider.
            assertHeading(heading, in: seen, leftMargin: 120)
            assertNothingClipped(seen)
        }
    }

    // MARK: Themes

    /// Color of one rendered pixel, in window points.
    private func pixel(at point: CGPoint) throws -> (CGFloat, CGFloat, CGFloat) {
        let image = try XCTUnwrap(lastImage)
        let scaled = CGPoint(x: point.x * image.scale, y: point.y * image.scale)
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: scaled, size: CGSize(width: 1, height: 1))))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    func testColorsTheMainScreens() async throws {
        let app = tabsApp(mode: .watch)
        for (tab, heading) in [(AppState.Tab.library, "Library"), (.downloads, "Downloads")] {
            app.selectedTab = tab
            let seen = try await render(environment(MainTabView(), app: app), name: "Theme-\(tab)")
            assertHeading(heading, in: seen)
            assertNothingClipped(seen)
            // The page background (just under the status bar) is the app's ground.
            let got = try pixel(at: CGPoint(x: window.bounds.midX, y: 4))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(AppTheme.background).getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertEqual(got.0, r, accuracy: 0.03, "Background on \(tab)")
            XCTAssertEqual(got.1, g, accuracy: 0.03, "Background on \(tab)")
            XCTAssertEqual(got.2, b, accuracy: 0.03, "Background on \(tab)")
        }
    }

    /// Filled buttons are green with black text, which must stay legible.
    func testProminentButtonsReadable() async throws {
        let app = tabsApp(mode: .music)
        let view = ZStack {
            Cinema.background.ignoresSafeArea()
            Button {} label: { Text("Play Everything").font(.title.bold()).padding(.vertical, 8) }
                .prominentButton()
        }
        let seen = try await render(environment(view, app: app), name: "Button-Prominent")
        XCTAssertTrue(seen.contains { $0.text.contains("Play Everything") }, "The button label must be legible")
    }

        // MARK: AirPlay

    func testAirPlayPillNamesTheDevice() async throws {
        let app = tabsApp(mode: .music)
        let view = ZStack { Cinema.background.ignoresSafeArea(); AirPlayPill(deviceName: "Living Room TV") }
        let seen = try await render(environment(view, app: app), name: "AirPlay-pill")
        XCTAssertTrue(seen.contains { $0.text.contains("Playing on Living Room TV") }, "AirPlay must say where it's playing")
        assertNothingClipped(seen)
    }

    // MARK: iPad

    func testRegularWidthUsesSidebar() async throws {
        let app = tabsApp(mode: .watch)
        app.selectedTab = .library
        let seen = try await render(environment(MainTabView(), app: app), name: "iPad-sidebar",
                                    size: CGSize(width: 1180, height: 820)) { host in
            host.traitOverrides.horizontalSizeClass = .regular
        }
        // Sidebar lists the sections; the detail shows the selected page.
        for label in ["Home", "Library", "Search", "Downloads"] {
            XCTAssertTrue(seen.contains { $0.text == label }, "Sidebar should list \(label)")
        }
        assertHeading("Library", in: seen, leftMargin: nil)
        assertNothingClipped(seen)
    }

    /// iPad Home with the sidebar open: one Listen/Watch switch (the sidebar's), not three.
    func testRegularWidthHasOneModeSwitch() async throws {
        let app = tabsApp(mode: .watch)
        app.selectedTab = .home
        let seen = try await render(environment(MainTabView(), app: app), name: "iPad-home-one-switch",
                                    size: CGSize(width: 1180, height: 820)) { host in
            host.traitOverrides.horizontalSizeClass = .regular
        }
        XCTAssertEqual(seen.filter { $0.text == "Watch" }.count, 1, "Only the sidebar picker says Watch")
        XCTAssertEqual(seen.filter { $0.text == "Listen" }.count, 1, "Only the sidebar picker says Listen")
        XCTAssertTrue(seen.contains { $0.text == "Home" }, "Home's title reads Home")
    }
}
