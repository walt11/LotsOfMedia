import XCTest
import SwiftUI
@testable import LotsOfMedia

/// The app's one color scheme: dark slate with green highlights, used everywhere,
/// and every app icon design is present.
final class ThemeTests: XCTestCase {
    private func rgb(_ c: Color) -> (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    func testColorsAreDarkWithWhiteAccent() {
        let bg = rgb(AppTheme.background), surface = rgb(AppTheme.surface), accent = rgb(AppTheme.accent)
        XCTAssertLessThan(max(bg.0, bg.1, bg.2), 0.08, "The background must stay dark")
        XCTAssertGreaterThan(max(surface.0, surface.1, surface.2), max(bg.0, bg.1, bg.2), "Cards sit a step above the background")
        XCTAssertGreaterThan(accent.1, 0.8, "Highlights are the icon's bright green")
        XCTAssertGreaterThan(accent.1, accent.0 + 0.3, "Highlights are green")
        XCTAssertEqual(rgb(Cinema.accent).0, accent.0)
    }

    func testOldActivityPayloadsWithAThemeStillDecode() throws {
        let state = DownloadActivityAttributes.ContentState(phase: .downloading, title: "Movie", progress: 0.5,
                                                            bytesDone: 1, bytesTotal: 2, remainingItems: 1, completedItems: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["theme"] = "forest"
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(DownloadActivityAttributes.ContentState.self, from: old).title, "Movie")
    }

    /// The accent comes from the theme everywhere; the asset-catalog accent can't change at runtime.
    func testNoHardCodedAccent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for dir in ["LotsOfMedia", "LotsOfMediaWidgets"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty)
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("accentColor") || text.contains(".systemOrange") || text.contains("Color.orange") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Use Cinema.accent instead of a fixed accent in: \(offenders.joined(separator: ", "))")
    }

    /// Every design is a real icon in the app, with a picker preview.
    func testEveryIconChoiceExists() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for style in AppIconStyle.allCases {
            if let name = style.iconName {
                XCTAssertNotNil(alternates[name], "Missing alternate icon \(name)")
            } else {
                XCTAssertEqual(style, .lettermark)   // the primary icon (LoM)
            }
            for dark in [false, true] {
                let name = style.previewName(dark: dark)
                XCTAssertNotNil(UIImage(named: name), "Missing preview \(name)")
            }
        }
    }
}
