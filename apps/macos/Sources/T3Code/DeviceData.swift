import Foundation

enum DevicePlatform: String, Equatable, Sendable {
    case ios, android

    var title: String { self == .ios ? "iOS" : "Android" }
}

enum DeviceHostKind: String, Hashable, Sendable {
    case local, ssh, eas, simlock

    var hasHostTools: Bool { self == .local || self == .ssh }
}

enum DeviceTool: String, CaseIterable, Hashable, Sendable {
    case hub, agent

    var title: String { self == .hub ? "Device Hub" : "agent-device" }
}

struct DeviceKey: Hashable, Sendable {
    let hostID: String
    let deviceID: String

    init?(_ value: Wire, field: String) {
        guard let hostID = value["hostId"].string, !hostID.isEmpty, hostID.utf16.count <= 128,
              let deviceID = value[field].string, !deviceID.isEmpty, deviceID.utf16.count <= 256,
              deviceID != ".", deviceID != "..",
              hostID.rangeOfCharacter(from: .controlCharacters) == nil,
              deviceID.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        self.hostID = hostID
        self.deviceID = deviceID
    }

    var payload: Payload { ["hostId": .string(hostID), "deviceId": .string(deviceID)] }
}

struct DeviceSummary: Equatable, Sendable {
    let key: DeviceKey
    let platform: DevicePlatform
    let name: String
    let version: String
    let booted: Bool
    let physical: Bool

    init?(_ value: Wire) {
        guard let key = DeviceKey(value, field: "id"), let platform = value["platform"].string.flatMap(DevicePlatform.init(rawValue:)),
              let name = value["name"].string, !name.isEmpty else { return nil }
        self.key = key
        self.platform = platform
        self.name = name
        version = value["version"].string ?? ""
        booted = value["booted"].bool == true
        physical = value["physical"].bool == true
    }
}

struct DeviceHost: Equatable, Sendable {
    struct ToolVersion: Equatable, Sendable {
        let required: String
        let installed: [String]
        let running: String?

        init?(_ value: Wire) {
            guard let required = value["requiredVersion"].string else { return nil }
            self.required = required
            installed = value["installedVersions"].array.compactMap(\.string)
            running = value["runningVersion"].string
        }

        var needsUpdate: Bool { !installed.contains(required) }
    }

    struct Availability: Equatable, Sendable {
        let platform: DevicePlatform
        let available: Bool
        let reason: String?

        init?(_ value: Wire) {
            guard let platform = value["platform"].string.flatMap(DevicePlatform.init(rawValue:)) else { return nil }
            self.platform = platform
            available = value["available"].bool == true
            reason = value["reason"].string
        }
    }

    let id: String
    let name: String
    let kind: DeviceHostKind
    let platforms: [Availability]
    let tools: [DeviceTool: ToolVersion]
    let toolInspectionError: String?

    init?(_ value: Wire) {
        guard let id = value["id"].string, let name = value["label"].string,
              let kind = value["kind"].string.flatMap(DeviceHostKind.init(rawValue:)) else { return nil }
        self.id = id
        self.name = name
        self.kind = kind
        platforms = value["platforms"].array.compactMap(Availability.init)
        tools = Dictionary(uniqueKeysWithValues: DeviceTool.allCases.compactMap { tool in
            ToolVersion(value["tools"][tool.rawValue]).map { (tool, $0) }
        })
        toolInspectionError = value["toolInspectionError"].string
    }
}

struct DeviceSession: Equatable, Sendable {
    let key: DeviceKey
    let threadID: String
    let platform: DevicePlatform

    init?(_ value: Wire) {
        guard let key = DeviceKey(value, field: "deviceId"), let threadID = value["threadId"].string,
              let platform = value["platform"].string.flatMap(DevicePlatform.init(rawValue:)) else { return nil }
        self.key = key
        self.threadID = threadID
        self.platform = platform
    }
}

struct DeviceState: Equatable, Sendable {
    struct HostStatus: Equatable, Sendable {
        let status: String
        let detail: String?

        init?(_ value: Wire) {
            guard let status = value["status"].string else { return nil }
            self.status = status
            detail = value["detail"].string
        }
    }

    let revision: Int
    let hosts: [DeviceHost]
    let devices: [DeviceSummary]
    let sessions: [DeviceSession]
    let bootingDevices: [DeviceSession]
    let hostStatus: String
    let hostDetail: String?
    let hostStatuses: [String: HostStatus]
    let onboardingCompleted: Bool
    let agentAccessEnabled: Bool
    let supportsHostRetry: Bool
    let supportsToolInspection: Bool
    let supportsToolUpdate: Bool
    let supportsEasHosts: Bool
    let supportsSimlockHosts: Bool

    init?(_ value: Wire) {
        guard let revision = value["revision"].int, let hostStatus = value["hostStatus"].string,
              value["hubBasePath"].string == "/api/device-hub" else { return nil }
        self.revision = revision
        self.hostStatus = hostStatus
        hosts = (value["hosts"].array + value["easHosts"].array + value["simlockHosts"].array).compactMap(DeviceHost.init)
        devices = value["devices"].array.compactMap(DeviceSummary.init)
        sessions = value["sessions"].array.compactMap(DeviceSession.init)
        bootingDevices = value["bootingDevices"].array.compactMap { row in
            guard var fields = row.object else { return nil }
            fields["deviceId"] = fields["id"]
            return DeviceSession(.object(fields))
        }
        hostDetail = value["hostStatusDetail"].string
        hostStatuses = value["hostStatuses"].object?.compactMapValues(HostStatus.init) ?? [:]
        onboardingCompleted = value["onboardingCompleted"].bool == true
        agentAccessEnabled = value["agentAccessEnabled"].bool == true
        supportsHostRetry = value["supportsHostRetry"].bool == true
        supportsToolInspection = value["supportsToolInspection"].bool == true
        supportsToolUpdate = value["supportsToolUpdate"].bool == true
        supportsEasHosts = value["supportsEasHosts"].bool == true
        supportsSimlockHosts = value["supportsSimlockHosts"].bool == true
    }

    func host(for key: DeviceKey) -> DeviceHost? { hosts.first { $0.id == key.hostID } }
    func device(_ key: DeviceKey) -> DeviceSummary? { devices.first { $0.key == key } }
}

struct DeviceScope: Equatable, Sendable {
    let environmentID: String
    let connection: UUID
    let threadID: String
}

struct DeviceTarget: Equatable, Sendable {
    let scope: DeviceScope
    let key: DeviceKey
    let platform: DevicePlatform
    let hostKind: DeviceHostKind

    var avcc: Bool { platform == .ios || hostKind == .simlock }
    var sessionPayload: Payload { key.payload.merging(["threadId": .string(scope.threadID)]) { _, new in new } }
}

struct DeviceScreenConfig: Equatable, Sendable {
    enum Orientation: String, CaseIterable, Sendable {
        case portrait
        case left = "landscape_left"
        case upsideDown = "portrait_upside_down"
        case right = "landscape_right"

        var next: Self {
            switch self {
            case .portrait: .left
            case .left: .upsideDown
            case .upsideDown: .right
            case .right: .portrait
            }
        }
    }

    let size: CGSize
    let orientation: Orientation
    let inputUnavailable: Bool

    init?(_ value: Wire) {
        guard let width = value["width"].double, let height = value["height"].double,
              width.isFinite, height.isFinite, width > 0, height > 0,
              let orientation = value["orientation"].string.flatMap(Orientation.init(rawValue:)) else { return nil }
        size = CGSize(width: width, height: height)
        self.orientation = orientation
        inputUnavailable = value["inputUnavailable"].bool == true
    }

    func rawPoint(_ point: CGPoint) -> CGPoint {
        guard size.width <= size.height else { return point }
        switch orientation {
        case .portrait: return point
        case .left: return CGPoint(x: point.y, y: 1 - point.x)
        case .right: return CGPoint(x: 1 - point.y, y: point.x)
        case .upsideDown: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        }
    }
}
