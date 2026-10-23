import SwiftUI
import UniformTypeIdentifiers

/// Settings → Back Up Settings: preferences, Favorites, Watch Later, Home layouts and channel
/// collections as one file, to restore on a new iPhone or iPad (or after reinstalling).
/// Sign-ins, server addresses and anything about this device's session stay out of it.
enum SettingsTransfer {
    static let fileType = UTType.propertyList
    private static let marker = "LotsOfMediaSettings"

    /// This session and device: never carried to another install.
    private static let excludedKeys: Set<String> = [
        "selectedServerID", "serverEndpoints", "currentUserUUID", "mediaMode", "clientIdentifier",
    ]
    private static let excludedPrefixes = [
        "NS", "Apple", "AK", "com.apple", "WebKit", "PK", "MSV", "INNext", "liveTV.hasDVR.", "live.recent.", "live.last.",
    ]

    static func isTransferable(_ key: String) -> Bool {
        let lower = key.lowercased()
        return !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
            && !lower.contains("token") && !lower.contains("password")
    }

    /// The settings as a property list (it keeps the saved lists that are stored as data).
    /// `domainName`: where `defaults` keeps its values (the app's bundle ID, or a suite's name).
    static func export(defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier) throws -> Data {
        let domain = domainName.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var values = domain.filter { isTransferable($0.key) }
        values[marker] = 1
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    /// Restores a backup over the current settings; returns how many were restored.
    @discardableResult
    static func restore(_ data: Data, defaults: UserDefaults = .standard) throws -> Int {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values[marker] != nil else {
            throw PlexError.unsupported("That file isn't a LotsOfMedia settings backup.")
        }
        var count = 0
        for (key, value) in values where key != marker && isTransferable(key) {
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }
}

/// The backup as a file for the share sheet.
struct SettingsBackupFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: SettingsTransfer.fileType) { $0.data }
            .suggestedFileName("LotsOfMedia Settings.plist")
    }
}

/// Settings rows: share a backup, or restore one from Files.
struct SettingsTransferSection: View {
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Section {
            if let data = try? SettingsTransfer.export() {
                ShareLink(item: SettingsBackupFile(data: data), preview: SharePreview("LotsOfMedia Settings")) {
                    Label("Back Up Settings", systemImage: "square.and.arrow.up")
                }
            }
            Button { importing = true } label: { Label("Restore Settings…", systemImage: "square.and.arrow.down") }
        } header: {
            Text("Backup")
        } footer: {
            Text(message ?? "Preferences, Favorites, Watch Later and Home layouts. Sign-ins and servers aren't included.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [SettingsTransfer.fileType, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let count = try SettingsTransfer.restore(Data(contentsOf: url))
                message = "Restored \(count) settings. Some take effect the next time the app opens."
                Haptics.success()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
