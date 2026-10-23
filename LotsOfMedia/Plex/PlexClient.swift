import Foundation
import UIKit

/// Identity of this app as a Plex client. Sent with every request.
enum PlexClient {
    static let product = "LotsOfMedia"
    #if os(tvOS)
    static let platform = "tvOS"
    #else
    static let platform = "iOS"
    #endif

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Stable per-install identifier (stored in Keychain so it survives reinstalls).
    static let identifier: String = {
        if let existing = Keychain.string(for: "clientIdentifier") { return existing }
        let id = UUID().uuidString
        Keychain.set(id, for: "clientIdentifier")
        return id
    }()

    static let platformVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    static let deviceName: String = {
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return model.isEmpty ? deviceKind : model
    }()
    #if os(tvOS)
    static let deviceKind = "Apple TV"
    #else
    static let deviceKind = "iPhone"
    #endif

    static func headers(token: String?) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": identifier,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion,
            "X-Plex-Device": deviceKind,
            "X-Plex-Device-Name": "LotsOfMedia (\(deviceName))",
            "X-Plex-Model": deviceName,
            "X-Plex-Provides": "player",
            "X-Plex-Language": Locale.preferredLanguages.first ?? "en",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    /// Same identity as query items, for URLs consumed by AVPlayer where we can't set headers.
    static func queryItems(token: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "X-Plex-Product", value: product),
            URLQueryItem(name: "X-Plex-Version", value: version),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: identifier),
            URLQueryItem(name: "X-Plex-Platform", value: platform),
            URLQueryItem(name: "X-Plex-Platform-Version", value: platformVersion),
            URLQueryItem(name: "X-Plex-Device", value: deviceKind),
            URLQueryItem(name: "X-Plex-Device-Name", value: "LotsOfMedia (\(deviceName))"),
        ]
        if let token { items.append(URLQueryItem(name: "X-Plex-Token", value: token)) }
        return items
    }
}

enum PlexError: LocalizedError {
    case http(Int, String?)
    case invalidResponse
    case notSignedIn
    case noServer
    case noReachableConnection
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            switch code {
            case 401: return "Not authorized. Try signing in again."
            case 404: return "Not found on the server."
            default: return "Server returned HTTP \(code)" + (body.map { ": \($0.prefix(120))" } ?? "")
            }
        case .invalidResponse: return "Unexpected response from server."
        case .notSignedIn: return "You're not signed in."
        case .noServer: return "No server selected."
        case .noReachableConnection: return "Couldn't reach the server on any of its addresses."
        case .unsupported(let s): return s
        }
    }
}
