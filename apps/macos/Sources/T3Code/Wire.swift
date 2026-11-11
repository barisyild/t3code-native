import Foundation

typealias Payload = [String: Wire]

enum Wire: Codable, Sendable, Equatable {
    case object(Payload)
    case array([Wire])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .int(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .double(decoded) }
        else if let decoded = try? value.decode(Payload.self) { self = .object(decoded) }
        else { self = .array(try value.decode([Wire].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .int(let int): try value.encode(int)
        case .double(let double): try value.encode(double)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Wire { object?[key] ?? .null }
    var object: Payload? { if case .object(let value) = self { value } else { nil } }
    var array: [Wire] { if case .array(let value) = self { value } else { [] } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .int(let value) = self { value } else { nil } }
    var double: Double? {
        if case .double(let value) = self { return value }
        return int.map(Double.init)
    }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var identifier: String? { string ?? int.map { String($0) } }

    var serverErrorMessage: String? {
        if let message = self["message"].string ?? string { return message }
        switch self["_tag"].string {
        case "GitCommandError", "GitManagerError", "SourceControlProviderError", "PullRequestOperationError", "UsageReadError", "UsageLimitSourceError", "ProviderSetupError":
            return self["detail"].string
        case "ServerProviderUpdateError", "DeviceEasAccountError", "DeviceSimlockIdentityError",
             "DeviceHostUnavailableError", "DevicePlatformUnavailableError":
            return self["reason"].string
        case "PreviewClearProfileError": return "The environment could not delete this browser profile’s data."
        case "CloudSpeechError":
            return self["provider"].string.flatMap(VoiceCloudProvider.init(rawValue:))?.error(self["reason"].string)
        case "RelayEnvironmentLinkLimitExceededError":
            if let limit = self["maxTunnels"].int { return "This T3 Connect account has reached its tunnel limit of \(limit)." }
            return "This T3 Connect account has reached its tunnel limit."
        case "GuestShareCreateError":
            switch self["reason"].string {
            case "disabled": return "Turn on Guest links in Sharing & Access to create an invite."
            case "connect_unavailable": return "Guest links need a running T3 Connect tunnel on this environment."
            case "thread_unavailable": return "This conversation can’t be shared."
            case "changed": return "The guest share changed while the link was being created."
            default: return "The environment could not create a guest link."
            }
        case "OrchestratorDispatchError": return self["cause"].string
        case "McpAppRequestError":
            switch self["reason"].string {
            case "not-an-app": return "This tool call has no MCP app."
            case "provider-unsupported": return "This conversation’s provider cannot run MCP app requests."
            case "session-stopped": return "The app’s source conversation is stopped. Send a message there to use the app again."
            case "tool-not-callable": return "This app cannot call that tool."
            case "unsupported-content": return "Only text and structured content are supported."
            default: return "The app’s MCP server request failed."
            }
        case "PullRequestUnavailableError":
            if let requirement = self["requirement"].string { return requirement }
            switch self["reason"].string {
            case "cli-missing": return "Set up the source control tool on this environment to browse its pull requests."
            case "cli-unauthenticated": return "Sign in to the source control host on this environment."
            default: return "This environment cannot browse pull requests for this host."
            }
        default: return nil
        }
    }

    func requireString(_ key: String) throws -> String {
        guard let value = self[key].string else { throw ClientError.invalidResponse }
        return value
    }
}

enum ClientError: LocalizedError, Sendable {
    case message(String)
    case rpc(Wire)
    case http(Int, String?)
    case invalidResponse
    case disconnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .rpc(let failure): failure.serverErrorMessage ?? "The T3 Code server rejected the request."
        case .http(let status, let detail): detail ?? "The server returned HTTP \(status)."
        case .invalidResponse: "The T3 Code server returned an unexpected response."
        case .disconnected: "The connection to the T3 Code server closed."
        case .timedOut: "The T3 Code server did not respond in time."
        }
    }

    var requiresPairing: Bool {
        if case .http(401, _) = self { return true }
        return false
    }
}
