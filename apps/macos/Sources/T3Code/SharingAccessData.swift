import Foundation

enum PairingScope: String, CaseIterable {
    case environmentRead = "orchestration:read"
    case environmentOperate = "orchestration:operate"
    case settingsWrite = "settings:write"
    case providersManage = "providers:manage"
    case environmentMaintain = "environment:maintain"
    case previewOperate = "preview:operate"
    case diagnosticsRead = "diagnostics:read"
    case terminalRead = "terminal:read"
    case terminalOperate = "terminal:operate"
    case sourceControlWrite = "source-control:write"
    case filesRead = "filesystem:read"
    case filesWrite = "filesystem:write"
    case accessRead = "access:read"
    case accessWrite = "access:write"
    case relayRead = "relay:read"
    case relayWrite = "relay:write"

    var title: String {
        switch self {
        case .environmentRead: "View environment"
        case .environmentOperate: "Operate tasks"
        case .settingsWrite: "Change settings"
        case .providersManage: "Manage providers"
        case .environmentMaintain: "Maintain environment"
        case .previewOperate: "Control previews"
        case .diagnosticsRead: "View diagnostics and usage"
        case .terminalRead: "View terminals"
        case .terminalOperate: "Use terminals"
        case .sourceControlWrite: "Change source control"
        case .filesRead: "Read files"
        case .filesWrite: "Write files"
        case .accessRead: "View access"
        case .accessWrite: "Manage access"
        case .relayRead: "View relay"
        case .relayWrite: "Manage relay"
        }
    }

    static func titles(_ scopes: [String]) -> String {
        scopes.map { Self(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
    }

    static func grantedBy(_ value: Wire) -> [String] {
        (value["permissions"] == .null ? value["scopes"] : value["permissions"]).array.compactMap(\.string)
    }
}

struct PairingPermissions {
    let available: Set<PairingScope>
    private(set) var selected: Set<PairingScope>

    init(granted: [String]) {
        available = Set(granted.compactMap(PairingScope.init(rawValue:)))
        selected = available
    }

    mutating func standard() { selected = available }

    mutating func readOnly() {
        selected = available.intersection([.environmentRead, .filesRead, .diagnosticsRead, .terminalRead])
    }

    mutating func set(_ scope: PairingScope, enabled: Bool) {
        guard available.contains(scope) else { return }
        if enabled {
            selected.insert(scope)
            if scope == .terminalOperate && available.contains(.terminalRead) { selected.insert(.terminalRead) }
        } else {
            selected.remove(scope)
            if scope == .terminalRead { selected.remove(.terminalOperate) }
        }
    }

    var scopes: [String] { PairingScope.allCases.filter(selected.contains).map(\.rawValue) }
}

struct PairingAddress: Equatable {
    let origin: URL
    let kind: String?

    init?(_ value: String, kind: String? = nil) {
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) { components.port = nil }
        guard let origin = components.url else { return nil }
        self.origin = origin
        self.kind = kind
    }

    var isLoopback: Bool {
        let host = origin.host()?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    var title: String {
        let address = origin.absoluteString
        if isLoopback { return "This Mac only · \(address)" }
        if kind == "lan" { return "Local network · \(address)" }
        if kind == "tailnet" { return "Tailscale · \(address)" }
        return address
    }

    func link(credential: String) -> URL? {
        guard !credential.isEmpty, var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "token", value: credential)]
        components.path = "/pair"
        components.percentEncodedFragment = fragment.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

struct SharingConfiguration {
    let directAddresses: [PairingAddress]
    let blocksRemoteClients: Bool
    let blocksConnect: Bool

    init(_ config: Wire = .null) {
        directAddresses = config["directEndpoints"].array.compactMap { endpoint in
            guard let url = endpoint["httpBaseUrl"].string, let kind = endpoint["kind"].string,
                  kind == "lan" || kind == "tailnet" else { return nil }
            return PairingAddress(url, kind: kind)
        }
        let clients = config["managedPolicy"]["limits"]["clients"]
        blocksRemoteClients = clients != .null && !clients.array.contains(.string("remote"))
        blocksConnect = config["managedPolicy"]["limits"]["connect"].bool == false
    }

    func addresses(for origin: URL?) -> [PairingAddress] {
        var addresses = directAddresses
        if let origin, let address = PairingAddress(origin.absoluteString) {
            if address.isLoopback { addresses.append(address) }
            else if !addresses.contains(where: { $0.origin == address.origin }) { addresses.insert(address, at: 0) }
        }
        var seen = Set<URL>()
        return addresses.filter { seen.insert($0.origin).inserted }
    }
}

struct AccessLink: Equatable {
    let id: String
    let label: String
    let scopes: [String]
    let expiresAt: Date

    init?(_ value: Wire) {
        guard let id = value["id"].string, let date = WorkspaceStyle.date(value["expiresAt"].string) else { return nil }
        self.init(id: id, label: value["label"].string ?? "Pairing link", scopes: PairingScope.grantedBy(value), expiresAt: date)
    }

    init(id: String, label: String, scopes: [String], expiresAt: Date) {
        self.id = id
        self.label = label
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

struct AccessClient: Equatable {
    let id: String
    let label: String
    let scopes: [String]
    let current: Bool
    let connected: Bool
    let lastConnected: Date?

    init?(_ value: Wire) {
        guard let id = value["sessionId"].string else { return nil }
        self.id = id
        label = value["client"]["label"].string ?? value["client"]["os"].string ?? "Paired client"
        scopes = PairingScope.grantedBy(value)
        current = value["current"].bool == true
        connected = value["connected"].bool == true
        lastConnected = WorkspaceStyle.date(value["lastConnectedAt"].string)
    }
}

struct SharingAccessSnapshot {
    private(set) var revision: Int?
    private(set) var links: [String: AccessLink] = [:]
    private(set) var clients: [String: AccessClient] = [:]

    mutating func receive(_ event: Wire) -> Bool {
        guard event["version"].int == 1, let next = event["revision"].int, next > (revision ?? 0) else { return false }
        let payload = event["payload"]
        switch event["type"].string {
        case "snapshot":
            links = Dictionary(payload["pairingLinks"].array.compactMap(AccessLink.init).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            clients = Dictionary(payload["clientSessions"].array.compactMap(AccessClient.init).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        case "pairingLinkUpserted":
            guard revision != nil, let link = AccessLink(payload) else { return false }
            links[link.id] = link
        case "pairingLinkRemoved":
            guard revision != nil, let id = payload["id"].string else { return false }
            links.removeValue(forKey: id)
        case "clientUpserted":
            guard revision != nil, let client = AccessClient(payload) else { return false }
            clients[client.id] = client
        case "clientRemoved":
            guard revision != nil, let id = payload["sessionId"].string else { return false }
            clients.removeValue(forKey: id)
        default: return false
        }
        revision = next
        return true
    }
}

enum SharingAccessMutation {
    case createLink(label: String, scopes: [String])
    case revokeLink(String)
    case revokeClient(String)
    case revokeOthers

    var request: (path: String, payload: Payload?) {
        switch self {
        case .createLink(let label, let scopes):
            var payload: Payload = ["scopes": .array(scopes.map(Wire.string))]
            if !label.isEmpty { payload["label"] = .string(label) }
            return ("/api/auth/pairing-token", payload)
        case .revokeLink(let id): return ("/api/auth/pairing-links/revoke", ["id": .string(id)])
        case .revokeClient(let id): return ("/api/auth/clients/revoke", ["sessionId": .string(id)])
        case .revokeOthers: return ("/api/auth/clients/revoke-others", nil)
        }
    }
}
