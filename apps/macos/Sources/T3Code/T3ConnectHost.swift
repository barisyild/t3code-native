import Foundation

struct T3ConnectHostTarget: Equatable, Sendable {
    let connection: UUID
    let environmentID: String
    let serverID: String
    let localOrigin: URL?

    func linkProof(challenge: String, relay: URL, mode: T3ConnectLinkMode) -> Payload? {
        guard let localOrigin, var socket = URLComponents(url: localOrigin, resolvingAgainstBaseURL: false),
              let scheme = socket.scheme, ["http", "https"].contains(scheme),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(socket.host ?? ""),
              socket.user == nil, socket.password == nil, socket.query == nil, socket.fragment == nil,
              socket.path.isEmpty || socket.path == "/" else { return nil }
        let port = socket.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return nil }
        socket.scheme = scheme == "https" ? "wss" : "ws"
        guard let websocket = socket.url else { return nil }
        return [
            "challenge": .string(challenge), "relayIssuer": .string(relay.absoluteString),
            "endpoint": .object(["httpBaseUrl": .string(localOrigin.absoluteString), "wsBaseUrl": .string(websocket.absoluteString),
                                 "providerKind": .string(mode.providerKind)]),
            "origin": .object(["localHttpHost": .string("127.0.0.1"), "localHttpPort": .int(port)]),
        ]
    }
}

enum T3ConnectLinkMode: Equatable, Sendable {
    case tunnel, activity

    var providerKind: String { self == .tunnel ? "cloudflare_tunnel" : "manual" }

    var permissions: Payload {
        ["notificationsEnabled": .bool(true), "liveActivitiesEnabled": .bool(true), "managedTunnelsEnabled": .bool(self == .tunnel)]
    }

    func relayConfiguration(_ reply: Wire, serverID: String, relay: URL) throws -> Payload {
        guard reply["ok"].bool == true, reply["environmentId"].string == serverID,
              reply["endpoint"]["providerKind"].string == providerKind else {
            throw ClientError.message("T3 Connect returned credentials for a different environment or link mode.")
        }
        let runtime = reply["endpointRuntime"]
        if self == .tunnel {
            guard RelayEndpoint(reply["endpoint"]) != nil, runtime["providerKind"].string == providerKind,
                  runtime["connectorToken"].string?.isEmpty == false else { throw ClientError.invalidResponse }
        } else if runtime != .null { throw ClientError.invalidResponse }
        var fields: Payload = ["relayUrl": .string(relay.absoluteString), "endpointRuntime": runtime]
        for name in ["relayIssuer", "cloudUserId", "environmentCredential", "cloudMintPublicKey"] {
            let value = try reply.requireString(name)
            guard !value.isEmpty else { throw ClientError.invalidResponse }
            fields[name] = .string(value)
        }
        return fields
    }
}

struct T3ConnectReachability: Equatable, Sendable {
    let reachable: Bool
    let detail: String

    init?(_ value: Wire) {
        switch value["status"].string {
        case "reachable":
            reachable = true
            let connections = value["readyConnections"].int.map { $0 == 1 ? "1 connection" : "\($0) connections" }
            detail = ["Tunnel connected", connections, value["protocol"].string?.uppercased()].compactMap { $0 }.joined(separator: " · ")
        case "unreachable":
            reachable = false
            detail = [value["reason"].string, value["hint"].string, value["fix"].string].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: " ")
        default: return nil
        }
    }
}

struct T3ConnectHostState: Equatable, Sendable {
    enum Update: Sendable { case tunnel(Bool), activity(Bool), holdWebhooks(Bool) }
    enum Change: Equatable { case unlink, link(T3ConnectLinkMode), preferences }

    struct Desired: Equatable {
        let tunnel: Bool
        let activity: Bool
        let holdWebhooks: Bool?

        var preferences: Payload {
            var fields: Payload = ["publishAgentActivity": .bool(activity)]
            if let holdWebhooks { fields["holdWebhooksWhileOffline"] = .bool(holdWebhooks) }
            return fields
        }
    }

    let linked: Bool
    let revoked: Bool
    let tunnel: Bool
    let activity: Bool
    let holdWebhooks: Bool
    let linkableHere: Bool
    let relay: URL?
    let hostname: String?
    let reachability: T3ConnectReachability?

    init?(_ value: Wire) {
        guard let linked = value["linked"].bool, let activity = value["publishAgentActivity"].bool else { return nil }
        self.linked = linked
        self.activity = activity
        revoked = value["linkRevoked"].bool == true
        tunnel = !revoked && (value["managedTunnelActive"].bool ?? linked)
        holdWebhooks = value["holdWebhooksWhileOffline"].bool == true
        linkableHere = value["linkableHere"].bool == true
        relay = value["relayUrl"].string.flatMap(RelayEndpoint.secureOrigin)
        hostname = value["tunnelHostname"].string
        reachability = T3ConnectReachability(value["reachability"])
    }

    func desired(_ update: Update) -> Desired {
        switch update {
        case .tunnel(let enabled): .init(tunnel: enabled, activity: activity, holdWebhooks: nil)
        case .activity(let enabled): .init(tunnel: tunnel, activity: enabled, holdWebhooks: nil)
        case .holdWebhooks(let enabled): .init(tunnel: tunnel, activity: activity, holdWebhooks: enabled)
        }
    }

    func change(to desired: Desired) -> Change {
        if !desired.tunnel && !desired.activity { return .unlink }
        if !linked || revoked || tunnel != desired.tunnel { return .link(desired.tunnel ? .tunnel : .activity) }
        return .preferences
    }
}

enum T3ConnectHostRoute: String {
    case state = "link-state", proof = "link-proof", configuration = "relay-config"
    case reachability, preferences, unlink

    var scope: String { self == .state || self == .reachability ? "relay:read" : "relay:write" }
}

@MainActor
struct T3ConnectHostOperations {
    let workspace: Workspace
    let relay: ManagedRelayClient?

    func state(_ target: T3ConnectHostTarget) async throws -> T3ConnectHostState {
        let reply = try await workspace.t3ConnectHostRequest(.state, target: target)
        guard let state = T3ConnectHostState(reply) else { throw ClientError.invalidResponse }
        return state
    }

    func check(_ target: T3ConnectHostTarget) async throws -> T3ConnectReachability {
        let reply = try await workspace.t3ConnectHostRequest(.reachability, target: target)
        guard let reachability = T3ConnectReachability(reply) else { throw ClientError.invalidResponse }
        return reachability
    }

    func apply(_ update: T3ConnectHostState.Update, target: T3ConnectHostTarget, accountID: String?,
               approveInstall: (String) async -> Bool, progress: (String) -> Void) async throws -> String? {
        try requireTarget(target)
        let current = try await state(target)
        let desired = current.desired(update)
        if case .holdWebhooks = update, !current.tunnel { throw ClientError.message("Turn on the T3 Connect tunnel to hold webhooks.") }
        switch current.change(to: desired) {
        case .unlink:
            return try await unlink(current, target: target, accountID: accountID)
        case .link(let mode):
            guard current.linkableHere, target.localOrigin != nil else {
                throw ClientError.message("Open T3 Code on the environment’s host to change its T3 Connect link mode.")
            }
            guard !workspace.sharingConfiguration.blocksConnect else {
                throw ClientError.message("This environment’s policy restricts T3 Connect.")
            }
            guard let relay, let accountID else { throw ClientError.message("Sign in to T3 Connect to link this environment.") }
            if mode == .tunnel { try await ensureRelayClient(target, approveInstall: approveInstall, progress: progress) }
            progress("Linking environment…")
            try requireTarget(target)
            let challenge = try await relay.linkChallenge(mode, accountID: accountID)
            guard let payload = target.linkProof(challenge: challenge, relay: relay.origin, mode: mode) else {
                throw ClientError.invalidResponse
            }
            let signed = try await workspace.t3ConnectHostRequest(.proof, target: target, payload: payload)
            guard let proof = signed.string, !proof.isEmpty else { throw ClientError.invalidResponse }
            try requireTarget(target)
            let config = try await relay.linkEnvironment(mode, proof: proof, serverID: target.serverID, accountID: accountID)
            let result = try await workspace.t3ConnectHostRequest(.configuration, target: target, payload: config)
            guard result["ok"].bool == true else { throw ClientError.invalidResponse }
        case .preferences: break
        }
        _ = try await workspace.t3ConnectHostRequest(.preferences, target: target, payload: desired.preferences)
        return nil
    }

    private func requireTarget(_ target: T3ConnectHostTarget) throws {
        try Task.checkCancellation()
        guard workspace.t3ConnectHostTarget == target, workspace.can("relay:write") else { throw ClientError.disconnected }
    }

    private func unlink(_ current: T3ConnectHostState, target: T3ConnectHostTarget, accountID: String?) async throws -> String? {
        let result = try await workspace.t3ConnectHostRequest(.unlink, target: target)
        guard result["ok"].bool == true else { throw ClientError.invalidResponse }
        guard current.linked, !current.revoked else { return nil }
        guard let relay, relay.origin == current.relay, let accountID else {
            return "The environment is disconnected. Sign in to its T3 Connect account to remove the old entry."
        }
        do { try await relay.unlinkEnvironment(serverID: target.serverID, accountID: accountID) }
        catch {
            throw ClientError.message("The environment was disconnected. T3 Connect could not remove the old entry. \(error.localizedDescription)")
        }
        return nil
    }

    private func ensureRelayClient(_ target: T3ConnectHostTarget, approveInstall: (String) async -> Bool,
                                   progress: (String) -> Void) async throws {
        let status = try await workspace.request("cloud.getRelayClientStatus")
        try requireTarget(target)
        switch status["status"].string {
        case "available": return
        case "missing":
            guard await approveInstall(try status.requireString("version")) else { throw CancellationError() }
        case "unsupported":
            let platform = status["platform"].string ?? "this platform"
            let arch = status["arch"].string.map { " (\($0))" } ?? ""
            throw ClientError.message("Automatic relay client installation is unavailable on \(platform)\(arch).")
        default: throw ClientError.invalidResponse
        }
        try requireTarget(target)
        var completed = false
        try await workspace.subscribe("cloud.installRelayClient", [:]) { frames in
            guard workspace.t3ConnectHostTarget == target else { return }
            for frame in frames {
                if frame["type"].string == "complete" { completed = frame["status"]["status"].string == "available" }
                else {
                    switch frame["stage"].string {
                    case "downloading": progress("Downloading the relay client…")
                    case "verifying": progress("Verifying the relay client…")
                    case "installing", "activating": progress("Installing the relay client…")
                    default: progress("Preparing the relay client…")
                    }
                }
            }
        }
        try requireTarget(target)
        guard completed else { throw ClientError.message("The relay client did not become available after installation.") }
    }
}
