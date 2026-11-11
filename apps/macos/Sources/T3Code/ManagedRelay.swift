import Foundation

struct RelayRoute: Codable, Hashable, Sendable {
    let relayOrigin: URL
    let accountID: String
    let environmentID: String

    var storageID: String { "relay:\(relayOrigin.absoluteString)/\(accountID)/\(environmentID)" }
}

struct RelayEndpoint: Equatable, Sendable {
    let origin: URL
    let socket: URL

    init?(_ value: Wire) {
        guard let http = value["httpBaseUrl"].string.flatMap(Self.secureOrigin),
              let address = value["wsBaseUrl"].string,
              var ws = URLComponents(string: address), ws.scheme?.lowercased() == "wss",
              ws.host?.lowercased() == http.host()?.lowercased(), (ws.port ?? 443) == (http.port ?? 443),
              ws.query == nil, ws.fragment == nil, ws.user == nil, ws.password == nil else { return nil }
        ws.scheme = "wss"
        ws.host = ws.host?.lowercased()
        if ws.port == 443 { ws.port = nil }
        if ws.path.isEmpty || ws.path == "/" { ws.path = "/ws" }
        guard let socket = ws.url else { return nil }
        self.origin = http
        self.socket = socket
    }

    static func secureOrigin(_ raw: String) -> URL? {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.allSatisfy({ $0 == "/" }) else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        return parts.url
    }
}

struct RelayHTTPAuthorization: Sendable {
    let token: String
    let proof: String

    func apply(to request: URLRequest) -> URLRequest {
        var signed = request
        signed.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
        signed.setValue(proof, forHTTPHeaderField: "DPoP")
        return signed
    }
}

struct RelayEnvironmentAccess: Sendable {
    let client: ManagedRelayClient
    let route: RelayRoute
    let endpoint: RelayEndpoint

    func authorize(method: String, url: URL) async throws -> RelayHTTPAuthorization {
        try await client.authorize(self, method: method, url: url)
    }
}

actor ManagedRelayClient {
    private struct AccessToken: Sendable {
        let value: String
        let expires: Date
        let renew: Date

        init(_ wire: Wire, issued: Date) throws {
            guard wire["token_type"].string == "DPoP", let value = wire["access_token"].string,
                  !value.isEmpty, let ttl = wire["expires_in"].double, ttl.isFinite, ttl > 0 else {
                throw ClientError.invalidResponse
            }
            self.value = value
            expires = issued.addingTimeInterval(ttl)
            renew = expires.addingTimeInterval(-min(60, ttl / 2))
        }
    }

    private struct Lease: Sendable {
        let endpoint: RelayEndpoint
        let label: String
        let token: AccessToken
    }

    private struct Flight<Value: Sendable> {
        let id = UUID()
        let task: Task<Value, Error>
    }

    private static let scopes = "environment:connect environment:status"
    let origin: URL
    private let persistent: Bool
    private let subject: @Sendable (String) async throws -> String
    private let transport: EnvironmentHTTP
    private let now: @Sendable () -> Date
    private var key: DPoPKey?
    private var relayTokens: [String: AccessToken] = [:]
    private var relayFlights: [String: Flight<AccessToken>] = [:]
    private var leases: [RelayRoute: Lease] = [:]
    private var leaseFlights: [RelayRoute: Flight<Lease>] = [:]
    private var accountGenerations: [String: UUID] = [:]

    init(origin: URL, persistent: Bool, transport: @escaping EnvironmentHTTP = EnvironmentAPI.send,
         now: @escaping @Sendable () -> Date = { .now },
         subject: @escaping @Sendable (String) async throws -> String) {
        self.origin = origin
        self.persistent = persistent
        self.transport = transport
        self.now = now
        self.subject = subject
    }

    func environments(accountID: String) async throws -> [SavedEnvironment] {
        let reply = try await accountRequest("/v1/environments", accountID: accountID)
        guard case .array(let rows) = reply["environments"] else { throw ClientError.invalidResponse }
        var ids = Set<String>()
        return rows.compactMap { value in
            guard let id = value["environmentId"].string, Self.isEnvironmentID(id), ids.insert(id).inserted,
                  let endpoint = RelayEndpoint(value["endpoint"]) else { return nil }
            let route = RelayRoute(relayOrigin: origin, accountID: accountID, environmentID: id)
            return SavedEnvironment(origin: endpoint.origin, name: value["label"].string ?? "Environment", relay: route)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func linkChallenge(_ mode: T3ConnectLinkMode, accountID: String) async throws -> String {
        let reply = try await accountRequest("/v1/client/environment-link-challenges", accountID: accountID,
                                             method: "POST", payload: mode.permissions)
        let challenge = try reply.requireString("challenge")
        guard !challenge.isEmpty else { throw ClientError.invalidResponse }
        return challenge
    }

    func linkEnvironment(_ mode: T3ConnectLinkMode, proof: String, serverID: String, accountID: String) async throws -> Payload {
        guard Self.isEnvironmentID(serverID) else { throw ClientError.invalidResponse }
        var payload = mode.permissions
        payload["proof"] = .string(proof)
        let reply = try await accountRequest("/v1/client/environment-links", accountID: accountID, method: "POST", payload: payload)
        return try mode.relayConfiguration(reply, serverID: serverID, relay: origin)
    }

    func unlinkEnvironment(serverID: String, accountID: String) async throws {
        guard Self.isEnvironmentID(serverID) else { throw ClientError.invalidResponse }
        let reply = try await accountRequest("/v1/client/environment-links/\(serverID)", accountID: accountID, method: "DELETE")
        guard reply["ok"].bool == true else { throw ClientError.invalidResponse }
    }

    private func accountRequest(_ path: String, accountID: String, method: String = "GET", payload: Payload? = nil) async throws -> Wire {
        let generation = generation(for: accountID)
        let clerk = try await subject(accountID)
        try requireGeneration(generation, accountID: accountID)
        let body = try payload.map { try JSONEncoder().encode(Wire.object($0)) }
        let api = EnvironmentAPI(origin: origin, token: clerk, transport: transport)
        let reply = try await api.http(path, method: method, body: body, contentType: body == nil ? nil : "application/json", timeout: 60)
        try requireGeneration(generation, accountID: accountID)
        return reply
    }

    func status(_ route: RelayRoute) async throws -> String {
        let reply = try await relayRequest(route, action: "status")
        guard reply["environmentId"].string == route.environmentID,
              let state = reply["status"].string, ["online", "offline"].contains(state) else {
            throw ClientError.invalidResponse
        }
        return state
    }

    func connect(_ route: RelayRoute) async throws -> (label: String, access: RelayEnvironmentAccess) {
        let lease = try await lease(for: route)
        return (lease.label, RelayEnvironmentAccess(client: self, route: route, endpoint: lease.endpoint))
    }

    func authorize(_ access: RelayEnvironmentAccess, method: String, url: URL) async throws -> RelayHTTPAuthorization {
        let lease = try await lease(for: access.route)
        guard access.endpoint.origin == lease.endpoint.origin, let urlParts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              urlParts.scheme == "https", urlParts.host == lease.endpoint.origin.host(),
              (urlParts.port ?? 443) == (lease.endpoint.origin.port ?? 443), urlParts.user == nil, urlParts.password == nil else {
            throw ClientError.message("The T3 Connect route changed. Reconnect to use the new address.")
        }
        return .init(token: lease.token.value, proof: try proof(method: method, url: url, token: lease.token.value))
    }

    func proof(method: String, url: URL, token: String? = nil) throws -> String {
        try proofKey().proof(method: method, url: url, accessToken: token, now: now())
    }

    func invalidate(_ rejected: String, for route: RelayRoute) {
        if leases[route]?.token.value == rejected { leases.removeValue(forKey: route) }
    }

    func forget(_ route: RelayRoute) {
        leases.removeValue(forKey: route)
        leaseFlights.removeValue(forKey: route)?.task.cancel()
    }

    func signOut(accountID: String) {
        accountGenerations[accountID] = UUID()
        relayFlights.removeValue(forKey: accountID)?.task.cancel()
        relayTokens.removeValue(forKey: accountID)
        for route in Set(leases.keys).union(leaseFlights.keys) where route.accountID == accountID { forget(route) }
    }

    func keepAlive(_ access: RelayEnvironmentAccess) async {
        while !Task.isCancelled {
            let wait: TimeInterval
            do {
                let lease = try await lease(for: access.route)
                guard lease.endpoint == access.endpoint else { return }
                wait = max(5, lease.token.renew.timeIntervalSince(now()))
            } catch ClientError.http(401, _) { return }
            catch {
                guard !Task.isCancelled, let token = leases[access.route]?.token, token.expires > now() else { return }
                wait = 5
            }
            do { try await Task.sleep(for: .seconds(wait)) }
            catch { return }
        }
    }

    private func generation(for accountID: String) -> UUID {
        if let generation = accountGenerations[accountID] { return generation }
        let generation = UUID()
        accountGenerations[accountID] = generation
        return generation
    }

    private func requireGeneration(_ value: UUID, accountID: String) throws {
        try Task.checkCancellation()
        guard generation(for: accountID) == value else { throw ClientError.disconnected }
    }

    private func proofKey() throws -> DPoPKey {
        if let key { return key }
        let loaded: DPoPKey
        if persistent {
            let id = "t3-connect-proof:\(origin.absoluteString)"
            if try EnvironmentKeychain.load(account: id) == nil {
                let created = try DPoPKey()
                try EnvironmentKeychain.save(created.rawRepresentation.base64EncodedString(), account: id, onlyIfAbsent: true)
            }
            guard let saved = try EnvironmentKeychain.load(account: id), let bytes = Data(base64Encoded: saved) else {
                throw ClientError.message("Could not load the T3 Connect proof key from Keychain.")
            }
            loaded = try DPoPKey(rawRepresentation: bytes)
        } else { loaded = try DPoPKey() }
        key = loaded
        return loaded
    }

    private static func isEnvironmentID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 200 && id != "." && id != ".." &&
            id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 126].contains($0) }
    }

    private func lease(for route: RelayRoute) async throws -> Lease {
        guard route.relayOrigin == origin, Self.isEnvironmentID(route.environmentID) else {
            throw ClientError.http(401, "Choose the environment again from T3 Connect.")
        }
        if let existing = leases[route], existing.token.renew > now() { return existing }
        let generation = generation(for: route.accountID)
        if let flight = leaseFlights[route] {
            let value = try await flight.task.value
            try requireGeneration(generation, accountID: route.accountID)
            return value
        }
        let flight = Flight(task: Task { try await self.exchangeEnvironment(route) })
        leaseFlights[route] = flight
        defer { if leaseFlights[route]?.id == flight.id { leaseFlights.removeValue(forKey: route) } }
        let value = try await flight.task.value
        try requireGeneration(generation, accountID: route.accountID)
        guard leaseFlights[route]?.id == flight.id else { throw ClientError.disconnected }
        leases[route] = value
        return value
    }

    private func exchangeEnvironment(_ route: RelayRoute) async throws -> Lease {
        let bootstrap = try await relayRequest(route, action: "connect", body: .object([
            "clientProofKeyThumbprint": .string(try proofKey().thumbprint),
        ]))
        guard bootstrap["environmentId"].string == route.environmentID,
              let endpoint = RelayEndpoint(bootstrap["endpoint"]),
              let credential = bootstrap["credential"].string, !credential.isEmpty else { throw ClientError.invalidResponse }
        let api = EnvironmentAPI(origin: endpoint.origin, transport: transport)
        let descriptor = try await api.http("/.well-known/t3/environment")
        guard descriptor["environmentId"].string == route.environmentID else {
            throw ClientError.message("This address did not identify the linked T3 environment.")
        }
        try Task.checkCancellation()
        guard let exchangeURL = URL(string: "/oauth/token", relativeTo: endpoint.origin)?.absoluteURL else {
            throw ClientError.invalidResponse
        }
        let issued = now()
        let result = try await api.exchangeBootstrap(credential, proof: proof(method: "POST", url: exchangeURL))
        try Task.checkCancellation()
        return Lease(endpoint: endpoint, label: descriptor["label"].string ?? "Environment",
                     token: try AccessToken(result, issued: issued))
    }

    private func relayRequest(_ route: RelayRoute, action: String, body: Wire? = nil) async throws -> Wire {
        guard route.relayOrigin == origin, Self.isEnvironmentID(route.environmentID) else { throw ClientError.invalidResponse }
        let path = "/v1/environments/\(route.environmentID)/\(action)"
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw ClientError.invalidResponse }
        let api = EnvironmentAPI(origin: origin, transport: transport)
        let data = try body.map { try JSONEncoder().encode($0) }
        let generation = generation(for: route.accountID)
        for attempt in 0...1 {
            let token = try await relayToken(accountID: route.accountID)
            try requireGeneration(generation, accountID: route.accountID)
            let headers = ["Authorization": "DPoP \(token.value)", "DPoP": try proof(method: "POST", url: url, token: token.value)]
            do {
                let reply = try await api.http(path, method: "POST", body: data,
                                               contentType: data == nil ? nil : "application/json", headers: headers)
                try requireGeneration(generation, accountID: route.accountID)
                return reply
            }
            catch ClientError.http(401, _) where attempt == 0 {
                if relayTokens[route.accountID]?.value == token.value { relayTokens.removeValue(forKey: route.accountID) }
            }
        }
        throw ClientError.disconnected
    }

    private func relayToken(accountID: String) async throws -> AccessToken {
        if let existing = relayTokens[accountID], existing.renew > now() { return existing }
        let generation = generation(for: accountID)
        if let flight = relayFlights[accountID] {
            let value = try await flight.task.value
            try requireGeneration(generation, accountID: accountID)
            return value
        }
        let flight = Flight(task: Task { try await self.exchangeRelayToken(accountID: accountID) })
        relayFlights[accountID] = flight
        defer { if relayFlights[accountID]?.id == flight.id { relayFlights.removeValue(forKey: accountID) } }
        let value = try await flight.task.value
        try requireGeneration(generation, accountID: accountID)
        relayTokens[accountID] = value
        return value
    }

    private func exchangeRelayToken(accountID: String) async throws -> AccessToken {
        let clerk = try await subject(accountID)
        try Task.checkCancellation()
        let path = "/v1/client/dpop-token"
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw ClientError.invalidResponse }
        let issued = now()
        let result = try await EnvironmentAPI(origin: origin, transport: transport).http(path, method: "POST", body: EnvironmentAPI.form([
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange", "subject_token": clerk,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt", "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "resource": origin.absoluteString, "scope": Self.scopes, "client_id": "t3-web",
        ]), contentType: "application/x-www-form-urlencoded", headers: ["DPoP": try proof(method: "POST", url: url)])
        try Task.checkCancellation()
        guard Set(result["scope"].string?.split(whereSeparator: \.isWhitespace) ?? []) == Set(Self.scopes.split(separator: " ")) else {
            throw ClientError.invalidResponse
        }
        return try AccessToken(result, issued: issued)
    }
}
