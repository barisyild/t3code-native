import Foundation

extension DeviceHostKind {
    static let configuredKinds: [Self] = [.ssh, .eas, .simlock]

    var title: String {
        switch self {
        case .local: "This machine"
        case .ssh: "SSH"
        case .eas: "EAS Simulator"
        case .simlock: "Simlock"
        }
    }

    var settingsKey: String? {
        switch self {
        case .local: nil
        case .ssh: "deviceHosts"
        case .eas: "easDeviceHosts"
        case .simlock: "simlockDeviceHosts"
        }
    }

    var tokenKey: String? {
        switch self {
        case .eas: "accessToken"
        case .simlock: "agentToken"
        default: nil
        }
    }

    var checkMethod: String? {
        switch self {
        case .local: nil
        case .ssh: "device.testHost"
        case .eas: "device.easAccount"
        case .simlock: "device.simlockIdentity"
        }
    }
}

struct DeviceHostConfiguration: Equatable, Sendable {
    let kind: DeviceHostKind
    let id: String
    let name: String
    let fields: Payload

    init?(_ value: Wire, kind: DeviceHostKind) {
        guard let fields = value.object, let id = value["id"].string, let name = value["label"].string,
              value["kind"].string == kind.rawValue || (kind == .ssh && value["kind"] == .null) else { return nil }
        self.kind = kind
        self.id = id
        self.name = name
        self.fields = fields
    }

    var token: Wire { kind.tokenKey.flatMap { fields[$0] } ?? .null }
    var reference: SettingsSecretReference? { SettingsSecretReference(token) }
    var hasToken: Bool { reference != nil || token.string?.isEmpty == false }

    var subtitle: String {
        switch kind {
        case .ssh:
            let target = fields["target"]?.string ?? ""
            return fields["port"]?.int.map { "\(target) · Port \($0)" } ?? target
        case .eas:
            return fields["appId"]?.string ?? "Project from the conversation"
        case .simlock: return fields["gatewayUrl"]?.string ?? ""
        case .local: return ""
        }
    }
}

struct DeviceHostSettings: Equatable, Sendable {
    private var lists: [DeviceHostKind: [Wire]] = [:]
    let simlockEnabled: Bool

    init(_ settings: Wire = .null) {
        for kind in DeviceHostKind.configuredKinds {
            guard let key = kind.settingsKey, case .array(let values) = settings[key] else { continue }
            lists[kind] = values.map { value in
                guard let key = kind.tokenKey, var fields = value.object, value[key].string?.isEmpty == false else {
                    return value
                }
                fields[key] = .string(SettingsSecret.savedMarker)
                return .object(fields)
            }
        }
        simlockEnabled = settings["simlockDeviceHostsEnabled"].bool == true
    }

    func supports(_ kind: DeviceHostKind) -> Bool { lists[kind] != nil }

    var configurations: [DeviceHostConfiguration] {
        DeviceHostKind.configuredKinds.flatMap { kind in
            (lists[kind] ?? []).compactMap { DeviceHostConfiguration($0, kind: kind) }
        }
    }

    func current(kind: DeviceHostKind, id: String, original: DeviceHostConfiguration?) throws -> DeviceHostConfiguration? {
        guard let list = lists[kind] else { throw ClientError.message("This environment does not support \(kind.title) hosts.") }
        let row = list.first { $0["id"].string == id }
        let current = row.flatMap { DeviceHostConfiguration($0, kind: kind) }
        guard current == original, row == nil || current != nil else {
            throw ClientError.message("This host changed on the environment. Reopen its settings and try again.")
        }
        return current
    }

    func patch(_ draft: DeviceHostDraft, id: String, original: DeviceHostConfiguration?) throws -> Payload {
        let current = try current(kind: draft.kind, id: id, original: original)
        guard let key = draft.kind.settingsKey, var list = lists[draft.kind] else { throw ClientError.invalidResponse }
        if current == nil, lists.values.contains(where: { $0.contains { $0["id"].string == id } }) {
            throw ClientError.message("A device host already uses this identifier.")
        }
        let value = try draft.value(id: id, current: current)
        if let index = list.firstIndex(where: { $0["id"].string == id }) { list[index] = value }
        else { list.append(value) }
        return [key: .array(list)]
    }

    func removal(_ original: DeviceHostConfiguration) throws -> Payload {
        _ = try current(kind: original.kind, id: original.id, original: original)
        guard let key = original.kind.settingsKey, let list = lists[original.kind] else { throw ClientError.invalidResponse }
        return [key: .array(list.filter { $0["id"].string != original.id })]
    }
}

struct DeviceHostDraft: Sendable {
    enum Endpoint: Sendable {
        case ssh(target: String, identityFile: String, port: String)
        case eas(project: String, session: String, idle: String, concurrent: String)
        case simlock(gateway: String, leases: String, duration: String)
    }

    enum Credential: Sendable {
        case keep
        case environment
        case value(String)
        case reference(SettingsSecretReference)
    }

    let name: String
    let endpoint: Endpoint
    let credential: Credential

    var kind: DeviceHostKind {
        switch endpoint {
        case .ssh: .ssh
        case .eas: .eas
        case .simlock: .simlock
        }
    }

    func value(id: String, current: DeviceHostConfiguration?) throws -> Wire {
        let label = trimmed(name)
        guard !label.isEmpty else { throw ClientError.message("Enter a name for the device host.") }
        guard id != "local", id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]{0,127}/) != nil else {
            throw ClientError.invalidResponse
        }
        var fields = current?.fields ?? [:]
        fields["id"] = .string(id)
        fields["label"] = .string(label)
        fields["kind"] = .string(kind.rawValue)
        switch endpoint {
        case .ssh(let target, let identityFile, let port):
            try setSSHFields(&fields, target: target, identityFile: identityFile, port: port)
        case .eas(let project, let session, let idle, let concurrent):
            let minutes = try number(session, "Session limit", 1...115)
            let idleMinutes = try number(idle, "Idle limit", 1...60)
            guard idleMinutes < minutes else { throw ClientError.message("Idle limit must be shorter than the session limit.") }
            fields["appId"] = optional(project)
            fields["accessToken"] = try token(current: current, gateway: nil)
            fields["maxSessionMinutes"] = .int(minutes)
            fields["idleMinutes"] = .int(idleMinutes)
            fields["maxConcurrentSessions"] = .int(try number(concurrent, "Concurrent sessions", 1...20))
        case .simlock(let gateway, let leases, let duration):
            let origin = try gatewayOrigin(gateway)
            fields["gatewayUrl"] = .string(origin)
            fields["agentToken"] = try token(current: current, gateway: origin)
            fields["maxLeases"] = .int(try number(leases, "Concurrent leases", 1...20))
            fields["maxLeaseMinutes"] = .int(try number(duration, "Lease limit", 5...240))
        }
        return .object(fields)
    }

    func checkInput(id: String, current: DeviceHostConfiguration?) throws -> Payload {
        switch endpoint {
        case .ssh(let target, let identityFile, let port):
            var fields: Payload = ["id": .string(id), "kind": .string("ssh"),
                                   "label": .string(trimmed(name).isEmpty ? trimmed(target) : trimmed(name))]
            try setSSHFields(&fields, target: target, identityFile: identityFile, port: port)
            return fields
        case .eas:
            if case .keep = credential, let current, current.hasToken { return ["hostId": .string(current.id)] }
            return ["accessToken": try token(current: current, gateway: nil)]
        case .simlock(let gateway, _, _):
            let origin = trimmed(gateway).isEmpty ? nil : try gatewayOrigin(gateway)
            var input: Payload = [:]
            input["gatewayUrl"] = origin.map(Wire.string)
            if case .keep = credential, let current, current.hasToken {
                _ = try token(current: current, gateway: origin)
                input["hostId"] = .string(current.id)
            } else { input["agentToken"] = try token(current: current, gateway: origin) }
            return input
        }
    }

    private func setSSHFields(_ fields: inout Payload, target: String, identityFile: String, port: String) throws {
        let destination = trimmed(target)
        guard !destination.isEmpty, !destination.hasPrefix("-"),
              destination.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw ClientError.message("Enter an SSH alias or a user@host address.")
        }
        fields["target"] = .string(destination)
        fields["identityFile"] = optional(identityFile)
        fields["port"] = trimmed(port).isEmpty ? nil : .int(try number(port, "SSH port", 1...65_535))
    }

    private func token(current: DeviceHostConfiguration?, gateway: String?) throws -> Wire {
        switch credential {
        case .keep:
            guard let current, current.hasToken else { throw ClientError.message("The host has no saved token.") }
            if current.kind == .simlock {
                guard let gateway, let saved = current.fields["gatewayUrl"]?.string, (try? gatewayOrigin(saved)) == gateway else {
                    throw ClientError.message("Choose a token for the new gateway or use the environment’s token.")
                }
            }
            return current.token
        case .environment: return .string("")
        case .value(let input):
            let value = trimmed(input)
            guard !value.isEmpty, value != SettingsSecret.savedMarker else { throw ClientError.message("Enter an access token.") }
            return .string(value)
        case .reference(let reference): return reference.wire
        }
    }

    private func gatewayOrigin(_ input: String) throws -> String {
        let text = trimmed(input)
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port.map({ (1...65_535).contains($0) }) != false else {
            throw ClientError.message("Enter the HTTP or HTTPS origin of the Simlock gateway.")
        }
        parts.scheme = scheme
        parts.host = host
        parts.percentEncodedPath = ""
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        guard let url = parts.url else { throw ClientError.invalidResponse }
        return url.absoluteString
    }

    private func number(_ input: String, _ label: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(trimmed(input)), range.contains(value) else {
            throw ClientError.message("\(label) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private func optional(_ input: String) -> Wire? {
        let value = trimmed(input)
        return value.isEmpty ? nil : .string(value)
    }

    private func trimmed(_ input: String) -> String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
}
