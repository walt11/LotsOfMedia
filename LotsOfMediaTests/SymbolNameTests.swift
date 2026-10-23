import XCTest
import UIKit

/// A misspelled SF Symbol renders as nothing, silently. Every literal symbol
/// name in the app's source must exist on this iOS version.
final class SymbolNameTests: XCTestCase {
    func testEverySymbolNameExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LotsOfMedia")
        let pattern = try NSRegularExpression(pattern: #"(?:systemName|systemImage|icon)\s*:\s*"([a-z0-9.]+)""#)
        var names: [String: String] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "Source files not found at \(root.path)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { names[String(text[r])] = file.lastPathComponent }
            }
        }
        // Also the icons returned from computed properties (`return "music.note"` etc.).
        let returns = try NSRegularExpression(pattern: #"\? "([a-z0-9]+(?:\.[a-z0-9]+)+)" : "([a-z0-9]+(?:\.[a-z0-9]+)+)""#)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in returns.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for g in 1...2 { if let r = Range(m.range(at: g), in: text) { names[String(text[r])] = file.lastPathComponent } }
            }
        }
        XCTAssertGreaterThan(names.count, 50)
        let missing = names.filter { UIImage(systemName: $0.key) == nil }
        XCTAssertTrue(missing.isEmpty, "Unknown SF Symbols: " + missing.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", "))
    }
}
