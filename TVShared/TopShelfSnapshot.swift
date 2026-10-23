import Foundation
import Security

/// Continue Watching, saved by the app into a keychain group it shares with its extension: the
/// Apple TV Top Shelf, and the iPhone and iPad Home Screen widget. The extension shows it without
/// signing in itself.
struct TopShelfSnapshot: Codable {
    struct Item: Codable {
        var ratingKey: String
        var title: String
        var subtitle: String?
        /// Server poster artwork, including its access token, as the app built it.
        var imageURL: URL?
        /// 0…1
        var progress: Double?
    }

    var items: [Item]
    /// The server these items are from; links carry it so they never open another server's item
    /// with the same key. (Absent in snapshots saved by older versions.)
    var serverID: String?
    /// The profile whose Continue Watching this is: a link opened as someone else (picked at
    /// "Who's Watching?") opens the item page instead of resuming another person's progress.
    var userID: String? = nil
    /// That profile's name, shown on the Top Shelf when there's more than one to tell apart.
    var userName: String? = nil
    /// Set when items carry poster art; the Top Shelf skips older snapshots, whose art is wide stills.
    var posterArt: Bool? = nil

    static let urlScheme = "lotsofmedia"
    private static let account = "topshelf"

    /// "<team prefix>.net.jwalter.LotsOfMedia.shared", from the Info.plist's AppIdentifierPrefix.
    private static var accessGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "") + "net.jwalter.LotsOfMedia.shared"
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "net.jwalter.LotsOfMedia.topshelf",
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    static func load() -> TopShelfSnapshot? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let q = Self.query
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }

    /// lotsofmedia://item/<key>?server=<id>&user=<uuid> opens the item; lotsofmedia://play/… starts it.
    static func link(_ action: String, _ ratingKey: String, server: String?, user: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = action
        c.path = "/" + ratingKey
        let query = [server.map { URLQueryItem(name: "server", value: $0) }, user.map { URLQueryItem(name: "user", value: $0) }].compactMap { $0 }
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    /// The pieces of a link: action ("item" or "play"), key, and the server and profile it belongs to.
    static func parse(_ url: URL) -> (action: String, key: String, server: String?, user: String?)? {
        guard url.scheme == urlScheme, let action = url.host, ["item", "play"].contains(action),
              let key = url.pathComponents.dropFirst().first else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return (action, key, items?.first { $0.name == "server" }?.value, items?.first { $0.name == "user" }?.value)
    }
}
