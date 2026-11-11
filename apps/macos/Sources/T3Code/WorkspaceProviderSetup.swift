import Foundation

enum ProviderAuthReply: Sendable {
    case acceptBrowser
    case terminal(String, cols: Int?, rows: Int?)
    case credentials([String: String])

    var wire: Wire {
        switch self {
        case .acceptBrowser:
            return .object(["type": .string("browser"), "action": .string("accept")])
        case .terminal(let data, let cols, let rows):
            var value: Payload = ["type": .string("terminal"), "data": .string(data)]
            if let cols, let rows { value["size"] = .object(["cols": .int(cols), "rows": .int(rows)]) }
            return .object(value)
        case .credentials(let values):
            return .object(["type": .string("credentials"), "values": .object(values.mapValues(Wire.string))])
        }
    }
}

enum ProviderSetupCommand: Sendable {
    case install
    case cancelInstall(String)
    case removeInstall
    case signIn(method: String?, clientCallback: Bool)
    case respond(flow: String, interaction: String, reply: ProviderAuthReply)
    case complete(flow: String, callback: String)
    case cancelSignIn(String)
    case signOut
    case removeMethod(String)
    case updateCLI(String)

    func request(driver: String) -> (String, Payload) {
        switch self {
        case .install: ("provider.install.start", [:])
        case .cancelInstall(let id): ("provider.install.cancel", ["operationId": .string(id)])
        case .removeInstall: ("provider.install.remove", [:])
        case .signIn(let method, let callback):
            ("provider.auth.start", ["callbackMode": .string(callback ? "client" : "server")]
                .merging(method.map { ["methodId": .string($0)] } ?? [:]) { _, new in new })
        case .respond(let flow, let interaction, let reply):
            ("provider.auth.respond", ["flowId": .string(flow), "interactionId": .string(interaction), "response": reply.wire])
        case .complete(let flow, let callback):
            ("provider.auth.complete", ["flowId": .string(flow), "callbackUrl": .string(callback)])
        case .cancelSignIn(let id): ("provider.auth.cancel", ["flowId": .string(id)])
        case .signOut: ("provider.auth.logout", [:])
        case .removeMethod(let id): ("provider.auth.removeMethod", ["methodId": .string(id)])
        case .updateCLI(let version): ("server.updateProvider", ["provider": .string(driver), "targetVersion": .string(version)])
        }
    }
}

enum ProviderSetupStream {
    case installation, authentication

    var method: String { self == .installation ? "provider.install.subscribe" : "provider.auth.subscribe" }
    var permission: String { self == .installation ? "orchestration:read" : "providers:manage" }
}

extension Workspace {
    func providerSetupTarget(_ id: String) -> ProviderSetupTarget? {
        guard let connectionID, let environment, providers.contains(where: { $0.id == id }) else { return nil }
        return .init(environmentID: environment.id, connection: connectionID, instanceID: id)
    }

    func providerEnvelope(_ provider: Provider) -> Wire? {
        guard let providerConfigurations else { return nil }
        return providerConfigurations[provider.id] ?? .object(["driver": .string(provider.driver)])
    }

    func createProvider(_ kind: ProviderCreationKind, id: String, fields: ProviderConfigurationFields, connection: UUID) async throws {
        guard connectionID == connection, can("providers:manage"), let previous = providerConfigurations else {
            throw ClientError.disconnected
        }
        if previous[id] != nil { return }
        let instance = try ProviderConfigurationEdit.create(kind, fields: fields)
        try await saveProviderMutation(["operation": .string("create"), "instanceId": .string(id), "instance": instance],
                                       previous: previous, connection: connection)
    }

    func configureProvider(_ target: ProviderSetupTarget, edit: ProviderConfigurationEdit) async throws {
        guard providerSetupTarget(target.instanceID) == target, can("providers:manage"), let previous = providerConfigurations,
              let provider = providers.first(where: { $0.id == target.instanceID }), let envelope = providerEnvelope(provider) else {
            throw ClientError.disconnected
        }
        let next = try edit.envelope(driver: provider.driver, preserving: envelope)
        guard next != envelope else { return }
        try await saveProviderMutation(["operation": .string("upsert"), "instanceId": .string(provider.id), "instance": next],
                                       previous: previous, connection: target.connection)
    }

    func removeProvider(_ target: ProviderSetupTarget) async throws {
        guard providerSetupTarget(target.instanceID) == target, can("providers:manage"), let previous = providerConfigurations,
              let envelope = previous[target.instanceID], envelope["driver"].string != target.instanceID else {
            throw ClientError.disconnected
        }
        try await saveProviderMutation(["operation": .string("remove"), "instanceId": .string(target.instanceID)],
                                       previous: previous, connection: target.connection)
    }

    private func saveProviderMutation(_ mutation: Payload, previous: Payload, connection: UUID) async throws {
        let settings = try await request("server.updateSettings", ["patch": .object([:]), "providerInstanceMutation": .object(mutation)])
        guard connectionID == connection else { throw ClientError.disconnected }
        acceptProviderConfigurations(settings, replacing: previous)
    }

    func providerSetup(_ target: ProviderSetupTarget, _ command: ProviderSetupCommand) async throws -> Wire {
        guard providerSetupTarget(target.instanceID) == target, can("providers:manage"),
              let provider = providers.first(where: { $0.id == target.instanceID }) else { throw ClientError.disconnected }
        let (method, input) = command.request(driver: provider.driver)
        var payload = input
        payload["instanceId"] = .string(target.instanceID)
        let result = try await request(method, payload)
        guard providerSetupTarget(target.instanceID) == target else { throw ClientError.disconnected }
        return result
    }

    func subscribeProviderSetup(_ target: ProviderSetupTarget, _ stream: ProviderSetupStream, receive: ([Wire]) -> Void) async throws {
        guard providerSetupTarget(target.instanceID) == target, can(stream.permission) else { throw ClientError.disconnected }
        try await subscribe(stream.method, ["instanceId": .string(target.instanceID)]) { frames in
            if providerSetupTarget(target.instanceID) == target { receive(frames) }
        }
    }
}
