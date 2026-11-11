import Foundation

extension Workspace {
    var deviceScope: DeviceScope? {
        guard can("orchestration:read"), let connectionID, let environment,
              case .thread(let id) = selection else { return nil }
        return .init(environmentID: environment.id, connection: connectionID, threadID: id)
    }

    func watchDevices(_ scope: DeviceScope, receive: ([Wire]) -> Void) async throws {
        guard deviceScope == scope else { throw ClientError.disconnected }
        try await watchDevices(scope.connection) { frames in
            if deviceScope == scope { receive(frames) }
        }
    }

    func watchDevices(_ connection: UUID, receive: ([Wire]) -> Void) async throws {
        guard connectionID == connection, can("orchestration:read") else { throw ClientError.disconnected }
        try await subscribe("subscribeDeviceState", [:]) { frames in
            if connectionID == connection { receive(frames) }
        }
    }

    func listDevices(_ scope: DeviceScope, inspectOnly: Bool, retryHost: String? = nil) async throws -> DeviceState {
        guard deviceScope == scope else { throw ClientError.disconnected }
        let state = try await listDevices(scope.connection, inspectOnly: inspectOnly, retryHost: retryHost)
        guard deviceScope == scope else { throw ClientError.disconnected }
        return state
    }

    func configureDevices(_ scope: DeviceScope, fields: Payload) async throws -> DeviceState {
        guard deviceScope == scope else { throw ClientError.disconnected }
        let state = try await configureDevices(scope.connection, fields: fields)
        guard deviceScope == scope else { throw ClientError.disconnected }
        return state
    }

    func listDevices(_ connection: UUID, inspectOnly: Bool, retryHost: String? = nil, updateTool: DeviceTool? = nil) async throws -> DeviceState {
        guard connectionID == connection, can("orchestration:read"),
              (retryHost == nil && updateTool == nil) || can("orchestration:operate") else { throw ClientError.disconnected }
        var input: Payload = ["inspectOnly": .bool(inspectOnly && retryHost == nil && updateTool == nil)]
        input["retryHostId"] = retryHost.map(Wire.string)
        input["updateTool"] = updateTool.map { .string($0.rawValue) }
        let result = try await request("device.list", input, timeout: updateTool == nil ? .seconds(120) : .seconds(300))
        guard connectionID == connection else { throw ClientError.disconnected }
        guard let state = DeviceState(result) else { throw ClientError.invalidResponse }
        return state
    }

    func configureDevices(_ connection: UUID, fields: Payload) async throws -> DeviceState {
        guard connectionID == connection, can("settings:write") else { throw ClientError.disconnected }
        let result = try await request("device.configure", fields, timeout: .seconds(300))
        guard connectionID == connection else { throw ClientError.disconnected }
        guard let state = DeviceState(result) else { throw ClientError.invalidResponse }
        return state
    }

    func openDevice(_ target: DeviceTarget) async throws -> DeviceSession {
        guard deviceScope == target.scope, can("orchestration:operate"), selectedThread?.archived == false else {
            throw ClientError.disconnected
        }
        var input = target.sessionPayload
        input["platform"] = .string(target.platform.rawValue)
        let result = try await request("device.open", input, timeout: .seconds(300))
        guard deviceScope == target.scope else { throw ClientError.disconnected }
        // Android may replace an AVD name with its emulator serial after boot.
        guard let session = DeviceSession(result), session.key.hostID == target.key.hostID,
              session.platform == target.platform, session.threadID == target.scope.threadID else {
            throw ClientError.invalidResponse
        }
        return session
    }

    func closeDevice(_ target: DeviceTarget, shutdown: Bool) async throws {
        guard deviceScope == target.scope, can("orchestration:operate") else { throw ClientError.disconnected }
        var input = target.sessionPayload
        input["shutdown"] = .bool(shutdown)
        _ = try await request("device.close", input)
        guard deviceScope == target.scope else { throw ClientError.disconnected }
    }

    func deviceDetail(_ target: DeviceTarget) async throws -> Wire {
        guard deviceScope == target.scope, target.hostKind.hasHostTools else { throw ClientError.disconnected }
        let result = try await request("device.detail", target.key.payload)
        guard deviceScope == target.scope else { throw ClientError.disconnected }
        return result
    }

    func deviceAction(_ target: DeviceTarget, fields: Payload) async throws -> Wire {
        guard deviceScope == target.scope, target.hostKind.hasHostTools, can("orchestration:operate") else {
            throw ClientError.disconnected
        }
        let result = try await request("device.action", fields.merging(target.key.payload) { _, new in new })
        guard deviceScope == target.scope else { throw ClientError.disconnected }
        return result
    }

    func deviceMedia(_ target: DeviceTarget) async throws -> DeviceMediaAccess {
        guard deviceScope == target.scope else { throw ClientError.disconnected }
        let media = try await issueDeviceMedia(target)
        guard deviceScope == target.scope else { throw ClientError.disconnected }
        return media
    }

    func endDeviceCapture(_ target: DeviceTarget, sessionID: String) async throws {
        let media = try await issueDeviceMedia(target)
        _ = try await media.json(.close, body: ["sessionId": .string(sessionID)])
    }

    private func issueDeviceMedia(_ target: DeviceTarget) async throws -> DeviceMediaAccess {
        guard connectionID == target.scope.connection else { throw ClientError.disconnected }
        let api = try browserAPI(for: target.scope.environmentID)
        let ticket = try await api.http("/api/auth/websocket-ticket/media", method: "POST", timeout: 8)
        guard connectionID == target.scope.connection else { throw ClientError.disconnected }
        return .init(origin: api.origin, target: target, ticket: try ticket.requireString("ticket"))
    }
}
