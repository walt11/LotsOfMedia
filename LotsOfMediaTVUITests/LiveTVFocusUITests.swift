import XCTest

/// Drives the Siri Remote over the Live TV page's sample guide (no server tuner needed).
final class LiveTVFocusUITests: XCTestCase {
    private func focusedLabel(_ app: XCUIApplication) -> String {
        let f = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return f.exists ? f.label : ""
    }

    /// Guide programs are named "airing-<channel>[-now]".
    private func focusedID(_ app: XCUIApplication) -> String {
        let f = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return f.exists ? f.identifier : ""
    }

    /// The filter row's first chips; Down from the tab bar lands on whichever is under Live TV.
    private static let filters: Set<String> = ["Guide", "On Now", "Recordings", "All Channels", "Favorites"]

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button); sleep(1) }
    }

    /// With a channel in the corner window: Back goes to the first channel, then the window, then
    /// the tab bar; Down from there reaches the filters, and Down again the guide.
    func testBackAndDownRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["-tvLiveSample", "-tvTab", "live", "-tvMiniSample"]
        app.launch()
        sleep(6)
        press(.down, times: 2)                       // filters, then the guide's first row
        let firstRow = "airing-sample-0-now"
        XCTAssertEqual(focusedID(app), firstRow)
        press(.down, times: 6)
        press(.menu)
        XCTAssertEqual(focusedID(app), firstRow, "Back goes to the first channel, on now")
        press(.menu)
        XCTAssertTrue(focusedLabel(app).hasPrefix("LIVE"), "then the playing window")
        press(.menu)
        XCTAssertEqual(focusedLabel(app), "Live TV", "then the tab bar")
        press(.down)
        XCTAssertTrue(Self.filters.contains(focusedLabel(app)), "Down reaches the filters")
        press(.down)
        XCTAssertEqual(focusedID(app), firstRow, "and Down again the guide")
    }

    /// The program the preview band describes (it follows the guide's focus).
    private func spotlight(_ app: XCUIApplication) -> String {
        app.staticTexts["live-spotlight"].firstMatch.label
    }

    /// Nothing playing, and the guide scrolled down and later in time: Back goes to the first
    /// channel on now, then straight to the tab bar; Down reaches the filters, then the guide.
    /// After moving across the guide, `hasFocus` stops reporting the program tiles (the remote
    /// still moves correctly), so those steps check the preview band instead.
    func testBackWithoutAChannelPlaying() {
        let app = XCUIApplication()
        app.launchArguments = ["-tvLiveSample", "-tvTab", "live"]
        app.launch()
        sleep(6)
        press(.down, times: 2)
        let firstRow = "airing-sample-0-now"
        XCTAssertEqual(focusedID(app), firstRow)
        let onNow = spotlight(app)
        XCTAssertFalse(onNow.isEmpty)
        press(.down, times: 4)
        press(.right, times: 4)
        XCTAssertNotEqual(spotlight(app), onNow, "moved off the first channel's current program")
        press(.menu)
        XCTAssertEqual(spotlight(app), onNow, "Back goes to the first channel, on now")
        press(.menu)
        XCTAssertEqual(focusedLabel(app), "Live TV", "then the tab bar")
        press(.down)
        XCTAssertTrue(Self.filters.contains(focusedLabel(app)), "Down reaches the filters")
        press(.down)
        // The band still shows the last program, so step along the row and back to prove where focus is.
        press(.right)
        XCTAssertNotEqual(spotlight(app), onNow, "Down again comes into the guide")
        press(.left)
        XCTAssertEqual(spotlight(app), onNow, "on the first channel, on now")
    }
}

/// Full-screen live TV over a local test stream: Play/Pause and Select are pressed with pauses
/// between, while the app logs the player's state (read from the host). Development only.
final class LivePlayPauseUITests: XCTestCase {
    func testPlayPausePresses() throws {
        guard let stream = ProcessInfo.processInfo.environment["LIVE_URL"] else {
            throw XCTSkip("Set LIVE_URL to a live HLS fixture (tools/live_seek_fixture.py).")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-tvLiveSample", "-tvTab", "live", "-tvMiniSample",
                               "-tvLiveURL", stream, "-tvLiveDiagnostics", "-tvLiveFull"]
        app.launch()
        sleep(10)
        XCUIRemote.shared.press(.playPause)   // pause
        sleep(8)
        XCUIRemote.shared.press(.playPause)   // play
        sleep(8)
        XCUIRemote.shared.press(.select)      // pause
        sleep(8)
        XCUIRemote.shared.press(.select)      // play
        sleep(8)
        XCUIRemote.shared.press(.playPause)   // pause and play again, quickly
        sleep(1)
        XCUIRemote.shared.press(.playPause)
        sleep(8)
    }

    /// The way it's watched: a channel picked in the guide, Play/Pause right away and after it
    /// starts; then Back to the corner window, Select to go full screen again, and Play/Pause.
    func testPlayPauseFromTheGuide() throws {
        guard let stream = ProcessInfo.processInfo.environment["LIVE_URL"] else {
            throw XCTSkip("Set LIVE_URL to a live HLS fixture (tools/live_seek_fixture.py).")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-tvLiveSample", "-tvTab", "live",
                               "-tvLiveURL", stream, "-tvLiveDiagnostics"]
        app.launch()
        sleep(6)
        for _ in 0..<2 { XCUIRemote.shared.press(.down); sleep(1) }
        XCUIRemote.shared.press(.select)      // watch the first channel
        sleep(10)
        XCUIRemote.shared.press(.playPause)   // pause
        sleep(6)
        XCUIRemote.shared.press(.playPause)   // play
        sleep(6)
        XCUIRemote.shared.press(.menu)        // back to the guide, the channel in the corner
        sleep(4)
        XCUIRemote.shared.press(.menu)        // focus to the corner window
        sleep(2)
        XCUIRemote.shared.press(.select)      // full screen again
        sleep(4)
        XCUIRemote.shared.press(.playPause)   // pause
        sleep(6)
        XCUIRemote.shared.press(.playPause)   // play
        sleep(6)
    }

    /// Leaving for the Home Screen pauses the channel (read from the log); a quick return resumes it.
    func testHomeScreenPausesTheChannel() throws {
        guard let stream = ProcessInfo.processInfo.environment["LIVE_URL"] else {
            throw XCTSkip("Set LIVE_URL to a live HLS fixture (tools/live_seek_fixture.py).")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-tvLiveSample", "-tvTab", "live", "-tvMiniSample",
                               "-tvLiveURL", stream, "-tvLiveDiagnostics", "-tvLiveFull"]
        app.launch()
        sleep(10)
        XCUIRemote.shared.press(.home)
        sleep(6)
        app.activate()
        sleep(6)
    }
}
