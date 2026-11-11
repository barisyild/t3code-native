import Foundation

extension Workspace {
    var canEditUsageHubs: Bool { usageHubSettings.configurations != nil && can("providers:manage") }

    func saveUsageHub(id: String, original: UsageHubConfiguration?, edit: UsageHubEdit, connection: UUID) async throws {
        let previous = usageHubSettings
        guard connectionID == connection, canEditUsageHubs, let configs = previous.configurations else { throw ClientError.disconnected }
        let current = configs[id]
        if original == nil && current != nil { throw ClientError.message("This hub has already been added. Open its settings to edit it.") }
        if original != nil && current == nil { throw ClientError.message("This hub was removed from the environment.") }
        if case .reference(let reference) = edit.key,
           !settingsSecretProviders.contains(where: { $0.id == reference.provider }) {
            throw ClientError.message("The selected secret provider is no longer available.")
        }
        let value = try edit.value(original: original, current: current, hubs: configs)
        try await updateUsageHub(id, value: value, previous: previous, connection: connection)
    }

    func removeUsageHub(id: String, connection: UUID) async throws {
        let previous = usageHubSettings
        guard connectionID == connection, canEditUsageHubs else { throw ClientError.disconnected }
        guard previous.configurations?[id] != nil else { return }
        try await updateUsageHub(id, value: .null, previous: previous, connection: connection)
    }

    private func updateUsageHub(_ id: String, value: Wire, previous: UsageHubSettings, connection: UUID) async throws {
        let settings = try await request("server.updateSettings", [
            "patch": .object(["usageLimitSources": .object([id: value])]),
        ])
        guard connectionID == connection else { throw ClientError.disconnected }
        acceptUsageHubSettings(settings, replacing: previous)
    }

    func redeemUsageCredit(_ target: UsageResetTarget, connection: UUID) async throws -> UsageResetResult {
        guard connectionID == connection, can("providers:manage") else { throw ClientError.disconnected }
        let accounts = providers.compactMap(\.usageLimit) + usageLimitSources.flatMap(\.accounts)
        guard accounts.contains(where: { $0.resetTarget == target }) else {
            throw ClientError.message("The displayed reset credit is no longer available.")
        }
        let result = try await request("provider.consumeResetCredit", target.payload)
        guard connectionID == connection else { throw ClientError.disconnected }
        return try UsageResetResult(result)
    }
}
