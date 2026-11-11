import Foundation

extension Workspace {
    func canEditDeviceHosts(_ connection: UUID, kind: DeviceHostKind) -> Bool {
        connectionID == connection && can("settings:write") && deviceHostSettings.supports(kind)
    }

    func saveDeviceHost(_ draft: DeviceHostDraft, id: String, original: DeviceHostConfiguration?, connection: UUID) async throws {
        guard canEditDeviceHosts(connection, kind: draft.kind) else { throw ClientError.disconnected }
        try validateDeviceCredential(draft.credential)
        let previous = deviceHostSettings
        let patch = try previous.patch(draft, id: id, original: original)
        try await updateDeviceSettings(patch, previous: previous, connection: connection)
    }

    func removeDeviceHost(_ original: DeviceHostConfiguration, connection: UUID) async throws {
        guard canEditDeviceHosts(connection, kind: original.kind) else { throw ClientError.disconnected }
        let previous = deviceHostSettings
        try await updateDeviceSettings(previous.removal(original), previous: previous, connection: connection)
    }

    func setSimlockHostsEnabled(_ enabled: Bool, connection: UUID) async throws {
        guard canEditDeviceHosts(connection, kind: .simlock) else { throw ClientError.disconnected }
        try await updateDeviceSettings(["simlockDeviceHostsEnabled": .bool(enabled)], previous: deviceHostSettings, connection: connection)
    }

    func checkDeviceHost(_ draft: DeviceHostDraft, id: String, original: DeviceHostConfiguration?, connection: UUID) async throws -> Wire {
        guard canEditDeviceHosts(connection, kind: draft.kind), let method = draft.kind.checkMethod else {
            throw ClientError.disconnected
        }
        try validateDeviceCredential(draft.credential)
        let current = try deviceHostSettings.current(kind: draft.kind, id: id, original: original)
        let result = try await request(method, draft.checkInput(id: id, current: current), timeout: .seconds(60))
        guard canEditDeviceHosts(connection, kind: draft.kind) else { throw ClientError.disconnected }
        return result
    }

    private func validateDeviceCredential(_ credential: DeviceHostDraft.Credential) throws {
        if case .reference(let reference) = credential, !settingsSecretProviders.contains(where: { $0.id == reference.provider }) {
            throw ClientError.message("The selected secret provider is no longer available.")
        }
    }

    private func updateDeviceSettings(_ patch: Payload, previous: DeviceHostSettings, connection: UUID) async throws {
        let result = try await request("server.updateSettings", ["patch": .object(patch)])
        guard connectionID == connection else { throw ClientError.disconnected }
        acceptDeviceHostSettings(result, replacing: previous)
    }
}
