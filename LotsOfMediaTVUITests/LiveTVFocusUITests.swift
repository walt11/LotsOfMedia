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

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times { XCUIRemote.shared.press(button); sleep(1) }
    }

    /// With a channel in the corner window: Back goes to the first channel, then the window, then
    /// the tab bar; Down from there reaches the filters, and Down again the guide.
    func testBackAndDownRoute() {
        let app = XCUIApplication()
        app.launchArguments = ["-proUnlocked", "-tvLiveSample", "-tvTab", "live", "-tvMiniSample"]
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
        XCTAssertEqual(focusedLabel(app), "All Channels", "Down reaches the filters")
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
        app.launchArguments = ["-proUnlocked", "-tvLiveSample", "-tvTab", "live"]
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
        XCTAssertEqual(focusedLabel(app), "All Channels", "Down reaches the filters")
        press(.down)
        // The band still shows the last program, so step along the row and back to prove where focus is.
        press(.right)
        XCTAssertNotEqual(spotlight(app), onNow, "Down again comes into the guide")
        press(.left)
        XCTAssertEqual(spotlight(app), onNow, "on the first channel, on now")
    }
}
