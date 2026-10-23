import Darwin
import Foundation

/// A Plex player that can take over playback ("Play on Another Device").
struct PlexPlayerTarget: Identifiable, Hashable {
    let id: String              // the player's machine identifier
    var name: String
    var product: String?
    /// Where to send companion commands directly; nil means only through the server.
    var baseURL: URL?
    var sources: Set<Source>

    enum Source: String, Hashable { case network, account, server }
}

/// Finds Plex players three ways and merges them:
/// - the local network (Plex's GDM discovery, sent to each address on this subnet: iOS
///   only lets apps with Apple's multicast entitlement use the usual group address),
/// - players signed in to the Plex account (plex.tv resources that provide "player"),
/// - players the server knows about (`/clients`; empty when it runs in Docker without host networking).
enum PlayerDiscovery {
    static func discover(api: PlexServerAPI, accountToken: String?) async -> [PlexPlayerTarget] {
        async let network = scanNetwork()
        async let account = accountPlayers(token: accountToken)
        async let server = (try? await api.playbackDevices()) ?? []
        var byID: [String: PlexPlayerTarget] = [:]
        func add(_ p: PlexPlayerTarget) {
            guard p.id != PlexClient.identifier, !p.id.isEmpty else { return }
            if var existing = byID[p.id] {
                existing.sources.formUnion(p.sources)
                if existing.baseURL == nil || p.sources.contains(.network) { existing.baseURL = p.baseURL ?? existing.baseURL }
                byID[p.id] = existing
            } else {
                byID[p.id] = p
            }
        }
        for p in await network { add(p) }
        for p in await account { add(p) }
        for d in await server {
            add(PlexPlayerTarget(id: d.machineIdentifier, name: d.name, product: d.product, baseURL: nil, sources: [.server]))
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: plex.tv

    private static func accountPlayers(token: String?) async -> [PlexPlayerTarget] {
        guard let token, let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=0&includeIPv6=0") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            let provides = (r["provides"] as? String ?? "").split(separator: ",")
            guard provides.contains("player"), let id = r["clientIdentifier"] as? String else { return nil }
            let conns = (r["connections"] as? [[String: Any]]) ?? []
            let local = conns.first { $0["local"] as? Bool == true } ?? conns.first
            return PlexPlayerTarget(id: id, name: r["name"] as? String ?? "Plex player", product: r["product"] as? String,
                                    baseURL: (local?["uri"] as? String).flatMap(URL.init(string:)), sources: [.account])
        }
    }

    // MARK: GDM on the local network

    static let gdmPort: UInt16 = 32412

    /// Parses a GDM reply ("HTTP/1.0 200 OK" followed by header lines).
    static func parseGDM(_ text: String, from host: String) -> PlexPlayerTarget? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = fields["resource-identifier"], !id.isEmpty else { return nil }
        let caps = (fields["protocol-capabilities"] ?? "").split(separator: ",")
        // A server answering (it has no playback capability) isn't a player.
        if fields["content-type"] == "plex/media-server" || (!caps.isEmpty && !caps.contains("playback")) { return nil }
        let port = fields["port"].flatMap(Int.init) ?? 32500
        return PlexPlayerTarget(id: id, name: fields["name"] ?? "Plex player", product: fields["product"],
                                baseURL: URL(string: "http://\(host):\(port)"), sources: [.network])
    }

    /// Every other address on this device's Wi-Fi/Ethernet subnet (at most a /22, as mesh routers use).
    static func subnetHosts() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet, not cellular or VPN
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            m = max(m, 0xFFFF_FC00)                         // never sweep more than 1,022 addresses
            let net = ip & m, broadcast = net | ~m
            guard broadcast > net + 1 else { continue }
            for host in (net + 1)..<broadcast where host != ip {
                out.append("\(host >> 24).\((host >> 16) & 0xFF).\((host >> 8) & 0xFF).\(host & 0xFF)")
            }
        }
        return out
    }

    private static func scanNetwork(timeout: TimeInterval = 2.0) async -> [PlexPlayerTarget] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: scanNetworkBlocking(timeout: timeout))
            }
        }
    }

    private static func scanNetworkBlocking(timeout: TimeInterval) -> [PlexPlayerTarget] {
        let hosts = subnetHosts()
        guard !hosts.isEmpty else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let message = Array("M-SEARCH * HTTP/1.1\r\n\r\n".utf8)
        func send(to host: String) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = gdmPort.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        // Twice, in case a reply or request is dropped.
        for _ in 0..<2 { hosts.forEach(send) }

        var found: [String: PlexPlayerTarget] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: ipBuf)
            if let text = String(bytes: buffer[0..<n], encoding: .utf8), let player = parseGDM(text, from: host) {
                found[player.id] = player
            }
        }
        return Array(found.values)
    }
}

// MARK: - Sending playback

extension PlexServerAPI {
    /// Starts `item` on another Plex player at `offset` ms. Sends the command straight to the
    /// player when its address is known (Plex's companion protocol), else asks the server to relay it.
    func handoff(_ item: PlexMetadata, offset: Int, to player: PlexPlayerTarget) async throws {
        guard let machine = try await container("/identity").machineIdentifier else { throw PlexError.invalidResponse }
        guard let base = player.baseURL else {
            let query = try HandoffRequest.query(item: item, offset: offset, machine: machine, serverURL: baseURL)
            let (response, _) = try await data("/player/playback/createPlayQueue", query: query,
                                                headers: ["X-Plex-Target-Client-Identifier": player.id], timeout: 15)
            try HandoffRequest.validateResponse(response)
            return
        }
        // A play queue on the server, so the player gets the item and can move on from it.
        let type = item.kind == .track ? "audio" : "video"
        let queue = try await container("/playQueues", query: [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "uri", value: "server://\(machine)/com.plexapp.plugins.library/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "shuffle", value: "0"), URLQueryItem(name: "repeat", value: "0"),
            URLQueryItem(name: "continuous", value: "1"),
        ], method: "POST")
        let query = try HandoffRequest.playMediaQuery(item: item, offset: offset, machine: machine, serverURL: baseURL,
                                                      playQueueID: queue.playQueueID, serverToken: token)
        var comps = URLComponents(url: base.appendingPathComponent("player/playback/playMedia"), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        PlexClient.headers(token: nil).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue(player.id, forHTTPHeaderField: "X-Plex-Target-Client-Identifier")
        let (body, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlexError.unsupported("\(player.name) didn't accept playback. Make sure Plex is open on it.")
        }
        try HandoffRequest.validateResponse(body)
    }
}

extension HandoffRequest {
    /// Query for a player's `/player/playback/playMedia`. The player streams from the server
    /// itself, so it gets the server's access token (never the Plex account's token).
    static func playMediaQuery(item: PlexMetadata, offset: Int, machine: String, serverURL: URL,
                               playQueueID: Int?, serverToken: String?) throws -> [URLQueryItem] {
        guard item.kind == .track || item.isPlayableVideo, !item.ratingKey.isEmpty, item.ratingKey.allSatisfy(\.isNumber),
              let host = serverURL.host, let scheme = serverURL.scheme, ["http", "https"].contains(scheme) else {
            throw PlexError.unsupported("This item cannot be sent to a Plex player.")
        }
        var q: [URLQueryItem] = [
            URLQueryItem(name: "key", value: "/library/metadata/\(item.ratingKey)"),
            URLQueryItem(name: "offset", value: "\(max(0, offset))"),
            URLQueryItem(name: "machineIdentifier", value: machine),
            URLQueryItem(name: "address", value: host),
            URLQueryItem(name: "port", value: "\(serverURL.port ?? (scheme == "https" ? 443 : 80))"),
            URLQueryItem(name: "protocol", value: scheme),
            URLQueryItem(name: "type", value: item.kind == .track ? "music" : "video"),
            URLQueryItem(name: "commandID", value: "\(Int64(Date().timeIntervalSince1970 * 1000) % 1_000_000)"),
        ]
        if let playQueueID { q.append(URLQueryItem(name: "containerKey", value: "/playQueues/\(playQueueID)?own=1&window=200")) }
        if let serverToken { q.append(URLQueryItem(name: "token", value: serverToken)) }
        return q
    }
}
