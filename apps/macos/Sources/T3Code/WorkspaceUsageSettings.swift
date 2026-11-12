import Foundation

@MainActor
final class UsageLimitRefresh {
    private static let periodicInterval = Duration.seconds(5 * 60)

    private weak var workspace: Workspace?
    private var connection: UUID?
    private var lastAttempt: ContinuousClock.Instant?
    private var task: Task<Void, Error>?
    private var periodicTask: Task<Void, Never>?

    init(workspace: Workspace) { self.workspace = workspace }

    func startPeriodic() {
        guard let workspace, let connection = workspace.connectionID, workspace.can("orchestration:read") else { return }
        useConnection(connection)
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now.advanced(by: Self.periodicInterval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: deadline, tolerance: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled, let self, workspaceIsCurrent(connection) else { return }
                if let lastAttempt {
                    let nextAttempt = lastAttempt.advanced(by: Self.periodicInterval)
                    if clock.now < nextAttempt {
                        deadline = nextAttempt
                        continue
                    }
                }
                try? await run()
                deadline = (lastAttempt ?? clock.now).advanced(by: Self.periodicInterval)
            }
        }
    }

    func run(automatic: Bool = false) async throws {
        guard let workspace, let connection = workspace.connectionID, workspace.can("orchestration:read") else {
            throw ClientError.disconnected
        }
        useConnection(connection)
        if let task {
            try await task.value
            return
        }
        if automatic, let lastAttempt, lastAttempt.duration(to: .now) < .seconds(60) { return }

        let request = Task { [weak self, workspace] in
            defer {
                if let self, self.connection == connection {
                    lastAttempt = .now
                    task = nil
                }
            }
            try await workspace.readFreshUsageLimits(connection: connection)
        }
        task = request
        try await request.value
    }

    private func useConnection(_ connection: UUID) {
        guard self.connection != connection else { return }
        reset()
        self.connection = connection
    }

    private func workspaceIsCurrent(_ connection: UUID) -> Bool {
        workspace?.connectionID == connection && workspace?.can("orchestration:read") == true
    }

    func reset() {
        periodicTask?.cancel()
        periodicTask = nil
        task?.cancel()
        task = nil
        connection = nil
        lastAttempt = nil
    }
}

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
        guard accounts.contains(where: { $0.resets.contains(where: { $0.target == target }) }) else {
            throw ClientError.message("The displayed reset credit is no longer available.")
        }
        let result = try await request("provider.consumeResetCredit", target.payload)
        guard connectionID == connection else { throw ClientError.disconnected }
        return try UsageResetResult(result)
    }
}
