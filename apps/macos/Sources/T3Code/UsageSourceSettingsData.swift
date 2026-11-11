import Foundation

struct UsageHubAddress: Equatable, Sendable {
    let value: String
    let host: String

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port.map({ (1...65_535).contains($0) }) != false else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.query = nil
        parts.fragment = nil
        var path = parts.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/management.html") { path.removeLast("/management.html".count) }
        parts.percentEncodedPath = path + "/"
        guard let url = parts.url else { return nil }
        value = url.absoluteString
        self.host = host
    }
}

struct UsageHubConfiguration: Equatable, Sendable {
    let id: String
    let label: String
    let address: UsageHubAddress?
    let enabled: Bool
    let hasKey: Bool
    let reference: SettingsSecretReference?

    init?(id: String, value: Wire) {
        guard value["kind"].string == "cliproxy", let url = value["url"].string else { return nil }
        self.id = id
        label = value["label"].string ?? ""
        address = UsageHubAddress(url)
        enabled = value["enabled"].bool != false
        let key = value["managementKey"]
        reference = SettingsSecretReference(key)
        hasKey = reference != nil || key.string?.isEmpty == false
    }

    var name: String { label.isEmpty ? address?.host ?? "CLIProxyAPI hub" : label }
}

struct UsageHubSettings: Equatable, Sendable {
    var configurations: [String: UsageHubConfiguration]?
    var supportsReferences = false
    private(set) var secretProviders: [SettingsSecretProvider] = []

    mutating func apply(_ settings: Wire) {
        configurations = settings["usageLimitSources"].object.map { configs in
            Dictionary(uniqueKeysWithValues: configs.compactMap { id, value in
                UsageHubConfiguration(id: id, value: value).map { (id, $0) }
            })
        }
        secretProviders = supportsReferences ? (settings["secretProviders"].object ?? [:]).compactMap { id, provider in
            guard provider["config"].object != nil, let label = provider["label"].string else { return nil }
            return SettingsSecretProvider(id: id, label: label)
        }.sorted { ($0.label, $0.id) < ($1.label, $1.id) } : []
    }
}

struct UsageHubEdit: Sendable {
    enum Key: Sendable {
        case keep
        case value(String)
        case reference(SettingsSecretReference)
    }

    let url: String
    let label: String
    let enabled: Bool
    let key: Key

    func value(original: UsageHubConfiguration?, current: UsageHubConfiguration?, hubs: [String: UsageHubConfiguration]) throws -> Wire {
        let entered = UsageHubAddress(url)
        let address = original != nil && original?.address == entered ? current?.address : entered
        guard let address else { throw ClientError.message("Enter a valid HTTP or HTTPS hub URL.") }
        guard current?.address == address || !hubs.values.contains(where: { $0.id != current?.id && $0.address == address }) else {
            throw ClientError.message("A hub already uses this URL. Edit its settings to update the key.")
        }
        let credential: Wire
        switch key {
        case .keep:
            guard current?.hasKey == true, current?.address == address else {
                throw ClientError.message("Enter the management key for this hub URL.")
            }
            credential = .string(SettingsSecret.savedMarker)
        case .value(let text):
            guard address == entered else { throw ClientError.message("The hub URL changed. Reopen the settings to update its key.") }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != SettingsSecret.savedMarker else { throw ClientError.message("Enter the management key.") }
            credential = .string(value)
        case .reference(let reference):
            guard address == entered else { throw ClientError.message("The hub URL changed. Reopen the settings to update its key.") }
            credential = reference.wire
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenName = original?.label == name ? current?.label ?? name : name
        let active = original?.enabled == enabled ? current?.enabled ?? enabled : enabled
        var fields: Payload = ["kind": .string("cliproxy"), "url": .string(address.value), "enabled": .bool(active),
                               "managementKey": credential]
        if !chosenName.isEmpty { fields["label"] = .string(chosenName) }
        return .object(fields)
    }
}
