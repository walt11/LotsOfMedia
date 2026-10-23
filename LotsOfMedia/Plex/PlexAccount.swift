import Foundation

/// plex.tv account operations: PIN sign-in, user info, server discovery.
enum PlexAccount {
    struct PreparedSession {
        let token: String
        let user: PlexUser
        let servers: [PlexServer]
    }

    /// Resolve everything before the caller commits any identity or credentials.
    static func prepareSession(token: String, fallbackUser: PlexUser? = nil,
                               discover: (String) async throws -> [PlexServer] = { try await servers(token: $0) },
                               loadUser: (String) async throws -> PlexUser = { try await user(token: $0) }) async throws -> PreparedSession {
        let discovered = try await discover(token)
        try Task.checkCancellation()
        let resolvedUser: PlexUser
        do { resolvedUser = try await loadUser(token) }
        catch {
            try Task.checkCancellation()
            guard let fallbackUser else { throw error }
            resolvedUser = fallbackUser
        }
        try Task.checkCancellation()
        return PreparedSession(token: token, user: resolvedUser, servers: discovered)
    }

    struct Pin: Decodable {
        var id: Int
        var code: String
        var authToken: String?
        var expiresIn: Int?
    }

    private static func request(_ url: URL, method: String = "GET", token: String? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }

    /// `strong: true` gives a long code for the app.plex.tv browser flow;
    /// `strong: false` gives a 4-character code the user can type at plex.tv/link.
    static func createPin(strong: Bool) async throws -> Pin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=\(strong ? "true" : "false")")!
        return try JSONDecoder().decode(Pin.self, from: try await request(url, method: "POST"))
    }

    static func checkPin(_ id: Int) async throws -> Pin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        return try JSONDecoder().decode(Pin.self, from: try await request(url))
    }

    /// Browser sign-in page for a strong PIN. Deliberately no `forwardUrl`:
    /// app.plex.tv rejects non-http(s) forward URLs and silently redirects to
    /// its home page without ever showing the sign-in prompt. Instead we poll
    /// the PIN and close the browser ourselves once it's claimed.
    static func authURL(for pin: Pin) -> URL {
        var c = URLComponents()
        c.queryItems = [
            URLQueryItem(name: "clientID", value: PlexClient.identifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: PlexClient.product),
            URLQueryItem(name: "context[device][version]", value: PlexClient.version),
            URLQueryItem(name: "context[device][platform]", value: PlexClient.platform),
            URLQueryItem(name: "context[device][platformVersion]", value: PlexClient.platformVersion),
            URLQueryItem(name: "context[device][device]", value: PlexClient.deviceKind),
            URLQueryItem(name: "context[device][deviceName]", value: "LotsOfMedia (\(PlexClient.deviceName))"),
            URLQueryItem(name: "context[device][layout]", value: "mobile"),
        ]
        return URL(string: "https://app.plex.tv/auth#?" + (c.percentEncodedQuery ?? ""))!
    }

    static func user(token: String) async throws -> PlexUser {
        let data = try await request(URL(string: "https://plex.tv/api/v2/user")!, token: token)
        return try JSONDecoder().decode(PlexUser.self, from: data)
    }

    static func servers(token: String) async throws -> [PlexServer] {
        let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1")!
        let data = try await request(url, token: token)
        let resources = try JSONDecoder().decode([PlexResource].self, from: data)
        return resources
            .filter { ($0.provides ?? "").split(separator: ",").contains("server") }
            .map(\.server)
    }

    // MARK: Plex Home

    static func homeUsers(token: String) async throws -> [PlexHomeUser] {
        do {
            let data = try await request(URL(string: "https://plex.tv/api/v2/home/users")!, token: token)
            struct Home: Decodable { var users: [PlexHomeUser] }
            if let home = try? JSONDecoder().decode(Home.self, from: data), !home.users.isEmpty { return home.users }
            if let users = try? JSONDecoder().decode([PlexHomeUser].self, from: data), !users.isEmpty { return users }
        } catch PlexError.http(let code, _) where code == 401 || code == 403 {
            throw PlexError.http(code, nil)
        } catch {}
        // Legacy XML endpoint.
        var req = URLRequest(url: URL(string: "https://plex.tv/api/home/users")!, timeoutInterval: 20)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PlexError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, nil) }
        return XMLAttributes.elements(named: "User", in: data).map(PlexHomeUser.init(xml:))
    }

    /// Returns the account token for `user`. `pin` is required for protected users.
    static func switchUser(_ user: PlexHomeUser, pin: String?, token: String) async throws -> String {
        var comps = URLComponents(string: "https://plex.tv/api/v2/home/users/\(user.uuid)/switch")!
        if let pin, !pin.isEmpty { comps.queryItems = [URLQueryItem(name: "pin", value: pin)] }
        do {
            let data = try await request(comps.url!, method: "POST", token: token)
            struct Switched: Decodable { var authToken: String? }
            if let t = try? JSONDecoder().decode(Switched.self, from: data).authToken, !t.isEmpty { return t }
        } catch PlexError.http(let code, let body) where code == 401 || code == 403 || code == 422 {
            throw PlexError.unsupported(body?.lowercased().contains("pin") == true || pin != nil ? "Incorrect PIN." : "Not allowed to switch to this user.")
        } catch {}
        // Legacy endpoint keyed by numeric id.
        var legacy = URLComponents(string: "https://plex.tv/api/home/users/\(user.id)/switch")!
        if let pin, !pin.isEmpty { legacy.queryItems = [URLQueryItem(name: "pin", value: pin)] }
        var req = URLRequest(url: legacy.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw PlexError.unsupported("Incorrect PIN.") }
        guard status < 300, let token = XMLAttributes.elements(named: "user", in: data).first?["authenticationToken"]
                ?? XMLAttributes.elements(named: "User", in: data).first?["authenticationToken"] else {
            throw PlexError.http(status, nil)
        }
        return token
    }
}

struct PlexHomeUser: Codable, Identifiable, Hashable {
    var id: Int
    var uuid: String
    var title: String
    var username: String?
    var thumb: String?
    /// Requires a PIN to switch to.
    var isProtected: Bool
    var admin: Bool
    var restricted: Bool
    var guest: Bool

    enum CodingKeys: String, CodingKey { case id, uuid, title, username, thumb, protected, hasPassword, admin, restricted, guest }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyInt(.id) ?? 0
        uuid = c.lossyString(.uuid) ?? ""
        username = c.lossyString(.username)
        title = c.lossyString(.title) ?? username ?? "User"
        thumb = c.lossyString(.thumb)
        isProtected = c.lossyBool(.protected) ?? c.lossyBool(.hasPassword) ?? false
        admin = c.lossyBool(.admin) ?? false
        restricted = c.lossyBool(.restricted) ?? false
        guest = c.lossyBool(.guest) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(uuid, forKey: .uuid); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(username, forKey: .username); try c.encodeIfPresent(thumb, forKey: .thumb)
        try c.encode(isProtected, forKey: .protected); try c.encode(admin, forKey: .admin)
        try c.encode(restricted, forKey: .restricted); try c.encode(guest, forKey: .guest)
    }

    init(xml a: [String: String]) {
        id = Int(a["id"] ?? "") ?? 0
        uuid = a["uuid"] ?? ""
        username = a["username"]
        title = a["title"] ?? a["username"] ?? "User"
        thumb = a["thumb"]
        isProtected = a["protected"] == "1"
        admin = a["admin"] == "1"
        restricted = a["restricted"] == "1"
        guest = a["guest"] == "1"
    }
}

/// Tiny XML attribute reader for the couple of legacy plex.tv endpoints.
enum XMLAttributes {
    static func elements(named name: String, in data: Data) -> [[String: String]] {
        final class Collector: NSObject, XMLParserDelegate {
            let name: String
            var found: [[String: String]] = []
            init(_ name: String) { self.name = name }
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
                if elementName == name { found.append(attributeDict) }
            }
        }
        let parser = XMLParser(data: data)
        let collector = Collector(name)
        parser.delegate = collector
        parser.parse()
        return collector.found
    }
}
