import Foundation

/// Races every advertised connection for a server and picks the best one that
/// answers. Local direct connections win, then remote direct, then relay.
enum ConnectionResolver {
    struct Result { let uri: String; let rank: Int }
    /// How long a better (local or https) address may still answer after a worse one has.
    static let graceAfterFirstAnswer: Duration = .milliseconds(400)

    static func resolve(_ server: PlexServer) async throws -> String {
        var candidates = server.connections
        if let last = ServerDirectory.shared.endpointURI(for: server.id), !candidates.contains(where: { $0.uri == last }) {
            candidates.append(PlexConnection(uri: last, local: false, relay: false))
        }
        guard !candidates.isEmpty else { throw PlexError.noReachableConnection }

        enum Outcome { case answered(Result), failed, graceOver }
        let best: Result? = await withTaskGroup(of: Outcome.self) { group in
            for conn in candidates {
                group.addTask {
                    let ok = await probe(uri: conn.uri, token: server.accessToken, timeout: conn.local ? 4 : 8,
                                         expectedID: server.isManual ? nil : server.clientIdentifier)
                    return ok ? .answered(Result(uri: conn.uri, rank: conn.rank)) : .failed
                }
            }
            var best: Result?
            var graceStarted = false
            for await outcome in group {
                switch outcome {
                case .answered(let r):
                    if best == nil || r.rank < best!.rank { best = r }
                    if r.rank <= 1 { group.cancelAll(); return best }  // can't beat local
                    // A remote address works: give a better one a moment, instead of waiting for
                    // every unreachable address (away from home) to time out.
                    if !graceStarted {
                        graceStarted = true
                        group.addTask { try? await Task.sleep(for: ConnectionResolver.graceAfterFirstAnswer); return .graceOver }
                    }
                case .graceOver:
                    group.cancelAll()
                    return best
                case .failed:
                    continue
                }
            }
            return best
        }
        guard let best else { throw PlexError.noReachableConnection }
        try Task.checkCancellation()
        if let current = ServerDirectory.shared.server(id: server.id), current.accessToken == server.accessToken {
            ServerDirectory.shared.setEndpoint(best.uri, for: server.id)
        }
        return best.uri
    }

    static func probe(uri: String, token: String?, timeout: TimeInterval, expectedID: String?) async -> Bool {
        guard let url = URL(string: uri)?.appendingPathComponent("identity") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
            guard let expectedID else { return true }
            let container = try JSONDecoder().decode(PlexResponse.self, from: data).MediaContainer
            return container.machineIdentifier == nil || container.machineIdentifier == expectedID
        } catch {
            return false
        }
    }

    /// Validates a manually-entered server URL and returns its identity.
    static func identify(uri: String, token: String?) async throws -> PlexContainer {
        guard let url = URL(string: uri)?.appendingPathComponent("identity") else { throw PlexError.invalidResponse }
        var req = URLRequest(url: url, timeoutInterval: 10)
        PlexClient.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.invalidResponse }
        guard http.statusCode == 200 else { throw PlexError.http(http.statusCode, nil) }
        let identity = try JSONDecoder().decode(PlexResponse.self, from: data).MediaContainer
        // /identity is unauthenticated; confirm the token actually grants library access.
        var libReq = URLRequest(url: URL(string: uri)!.appendingPathComponent("library/sections"), timeoutInterval: 10)
        PlexClient.headers(token: token).forEach { libReq.setValue($1, forHTTPHeaderField: $0) }
        let (_, libResp) = try await URLSession.shared.data(for: libReq)
        if let code = (libResp as? HTTPURLResponse)?.statusCode, code != 200 { throw PlexError.http(code, nil) }
        return identity
    }
}
