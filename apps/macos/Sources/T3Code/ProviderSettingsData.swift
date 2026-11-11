import Foundation

struct ProviderSetupTarget: Equatable, Sendable {
    let environmentID: String
    let connection: UUID
    let instanceID: String
}

struct ProviderManagement: Equatable, Sendable {
    let installed: Bool?
    let version: String?
    let canInstall: Bool
    let canAuthenticate: Bool
    let canLogout: Bool
    let authStatus: String?
    let authLabel: String?
    let homePath: String?
    let shadowHomePath: String?
    let updateVersion: String?
    let updateStatus: String?
    let updateMessage: String?

    init(_ value: Wire) {
        installed = value["installed"].bool
        version = value["installedVersion"].string ?? value["version"].string
        canInstall = value["setup"]["canInstall"].bool == true
        canAuthenticate = value["setup"]["canAuthenticate"].bool == true
        canLogout = value["auth"]["canLogout"].bool ?? canAuthenticate
        authStatus = value["auth"]["status"].string
        authLabel = value["auth"]["label"].string
        homePath = value["runtimePaths"]["homePath"].string
        shadowHomePath = value["runtimePaths"]["shadowHomePath"].string
        let advisory = value["versionAdvisory"]
        updateVersion = advisory["canUpdate"].bool == true && advisory["status"].string == "behind_latest" ?
            advisory["latestVersion"].string : nil
        updateStatus = value["updateState"]["status"].string
        updateMessage = value["updateState"]["message"].string
    }

    var updating: Bool { updateStatus == "queued" || updateStatus == "running" }
}

enum ProviderCreationKind: String, CaseIterable, Sendable {
    case managedCodex, codexCLI, claudeCLI

    var title: String {
        switch self {
        case .managedCodex: "Codex · T3 managed"
        case .codexCLI: "Codex · Existing CLI"
        case .claudeCLI: "Claude · Existing CLI"
        }
    }

    var family: ComposerProvider { self == .claudeCLI ? .claude : .codex }
    var driver: String { family.rawValue }
    var setupMode: String? { self == .managedCodex ? "managed" : self == .codexCLI ? "existing" : nil }
    var instanceID: String { driver + "-" + UUID().uuidString.lowercased() }
}

struct ProviderConfigurationFields: Equatable, Sendable {
    var name: String
    var enabled: Bool
    var binaryPath: String
    var homePath: String
    var shadowHomePath: String
    var launchArgs: String

    init(name: String, enabled: Bool = true, config: Wire = .null) {
        self.name = name
        self.enabled = enabled
        binaryPath = config["binaryPath"].string ?? ""
        homePath = config["homePath"].string ?? ""
        shadowHomePath = config["shadowHomePath"].string ?? ""
        launchArgs = config["launchArgs"].string ?? ""
    }

    init(provider: Provider, envelope: Wire) {
        let config = envelope["config"]
        let enabled = envelope["enabled"].bool != false && config["enabled"].bool != false &&
            (envelope["enabled"].bool ?? config["enabled"].bool ?? provider.enabled)
        self.init(name: envelope["displayName"].string ?? provider.name, enabled: enabled, config: config)
    }
}

struct ProviderConfigurationEdit: Sendable {
    let before: ProviderConfigurationFields
    let after: ProviderConfigurationFields

    func envelope(driver: String, preserving current: Wire) throws -> Wire {
        var fields = current.object ?? ["driver": .string(driver)]
        guard fields["driver"]?.string == driver else { throw ClientError.disconnected }
        var config = fields["config"]?.object ?? [:]
        if before.name != after.name {
            let name = after.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ClientError.message("Enter a provider name.") }
            fields["displayName"] = .string(name)
        }
        if before.enabled != after.enabled {
            fields["enabled"] = .bool(after.enabled)
            config.removeValue(forKey: "enabled")
        }
        if config["setupMode"]?.string != "managed", ComposerProvider(rawValue: driver) != nil {
            for (key, previous, next) in [
                ("binaryPath", before.binaryPath, after.binaryPath), ("homePath", before.homePath, after.homePath),
                ("launchArgs", before.launchArgs, after.launchArgs), ("shadowHomePath", before.shadowHomePath, after.shadowHomePath),
            ] where previous != next && (key != "shadowHomePath" || driver == ComposerProvider.codex.rawValue) {
                let value = next.trimmingCharacters(in: .whitespacesAndNewlines)
                config[key] = value.isEmpty ? nil : .string(value)
            }
        }
        if !config.isEmpty || fields["config"]?.object != nil { fields["config"] = .object(config) }
        return .object(fields)
    }

    static func create(_ kind: ProviderCreationKind, fields: ProviderConfigurationFields) throws -> Wire {
        let config = kind.setupMode.map { ["setupMode": Wire.string($0)] } ?? [:]
        let current: Wire = .object(["driver": .string(kind.driver), "config": .object(config), "enabled": .bool(true)])
        let before = ProviderConfigurationFields(name: "")
        return try Self(before: before, after: fields).envelope(driver: kind.driver, preserving: current)
    }
}

struct ProviderInstallState: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, downloading, extracting, verifying, succeeded, failed, cancelled
    }

    let phase: Phase
    let operationID: String?
    let downloaded: Int
    let total: Int?
    let version: String?
    let installedVersion: String?
    let executable: String?
    let source: String?
    let canRemove: Bool
    let message: String?

    init?(_ value: Wire) {
        guard value["driver"].string != nil, let phase = value["phase"].string.flatMap(Phase.init(rawValue:)) else { return nil }
        self.phase = phase
        operationID = value["operationId"].string
        downloaded = max(0, value["downloadedBytes"].int ?? 0)
        total = value["totalBytes"].int.flatMap { $0 > 0 ? $0 : nil }
        version = value["version"].string
        installedVersion = value["installedVersion"].string
        executable = value["executablePath"].string
        source = value["source"].string
        canRemove = value["canRemove"].bool == true
        message = value["message"].string
    }

    var active: Bool { phase == .downloading || phase == .extracting || phase == .verifying }
    var fraction: Double? { total.map { min(1, Double(downloaded) / Double($0)) } }
    var updateAvailable: Bool { source != "local" && installedVersion != nil && version != nil && installedVersion != version }
}

struct ProviderAuthMethod: Equatable, Sendable {
    let id: String
    let name: String
    let canRemove: Bool

    init?(_ value: Wire) {
        guard let id = value["id"].string, let name = value["name"].string else { return nil }
        self.id = id
        self.name = name
        canRemove = value["canRemove"].bool == true
    }
}

struct ProviderAuthField: Equatable, Sendable {
    let name: String
    let label: String
    let secret: Bool

    init?(_ value: Wire) {
        guard let name = value["name"].string, let label = value["label"].string, let secret = value["secret"].bool else { return nil }
        self.name = name
        self.label = label
        self.secret = secret
    }
}

struct ProviderAuthInteraction: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case browser(url: String, consent: Bool, callback: Bool)
        case device(url: String, code: String)
        case terminal(output: String, offset: Int)
        case credentials([ProviderAuthField])
    }

    let id: String
    let content: Content

    init?(_ value: Wire) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        switch value["type"].string {
        case "browser":
            guard let url = value["url"].string else { return nil }
            content = .browser(url: url, consent: value["requiresConsent"].bool == true, callback: value["acceptsCallback"].bool == true)
        case "deviceCode":
            guard let url = value["url"].string, let code = value["userCode"].string else { return nil }
            content = .device(url: url, code: code)
        case "terminal":
            guard let output = value["output"].string else { return nil }
            content = .terminal(output: output, offset: value["outputOffset"].int ?? output.utf16.count)
        case "credentials":
            let fields = value["fields"].array.compactMap(ProviderAuthField.init)
            guard !fields.isEmpty, fields.count <= 16, Set(fields.map(\.name)).count == fields.count else { return nil }
            content = .credentials(fields)
        default: return nil
        }
    }
}

struct ProviderAuthState: Equatable, Sendable {
    enum Phase: String, Sendable { case idle, starting, waiting, verifying, succeeded, failed, cancelled }

    let instanceID: String
    let phase: Phase
    let flowID: String?
    let authorizationURL: String?
    let message: String?
    let methods: [ProviderAuthMethod]
    let interaction: ProviderAuthInteraction?

    init?(_ value: Wire) {
        guard let instanceID = value["instanceId"].string, let phase = value["phase"].string.flatMap(Phase.init(rawValue:)) else { return nil }
        self.instanceID = instanceID
        self.phase = phase
        flowID = value["flowId"].string
        authorizationURL = value["authorizationUrl"].string
        message = value["message"].string
        methods = value["methods"].array.compactMap(ProviderAuthMethod.init)
        interaction = ProviderAuthInteraction(value["interaction"])
    }

    var active: Bool { phase == .starting || phase == .waiting || phase == .verifying }
}
