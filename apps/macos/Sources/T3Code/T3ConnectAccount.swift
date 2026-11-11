import ClerkKit
import Foundation

struct T3ConnectConfiguration: Sendable {
    let relay: URL
    let publishableKey: String
    let jwtTemplate: String

    static func read(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        func setting(_ name: String) -> String? {
            (environment[name] ?? bundle.object(forInfoDictionaryKey: name) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let relay = setting("T3CODE_RELAY_URL").flatMap(RelayEndpoint.secureOrigin),
              let key = setting("T3CODE_CLERK_PUBLISHABLE_KEY"), validKey(key),
              let template = setting("T3CODE_CLERK_JWT_TEMPLATE"), !template.isEmpty else { return nil }
        return .init(relay: relay, publishableKey: key, jwtTemplate: template)
    }

    private static func validKey(_ key: String) -> Bool {
        guard key.hasPrefix("pk_live_") || key.hasPrefix("pk_test_"),
              let bytes = Data(base64Encoded: String(key.dropFirst(8))),
              let host = String(data: bytes, encoding: .utf8), host.last == "$",
              !host.dropLast().isEmpty else { return false }
        return host.dropLast().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

@MainActor
final class T3ConnectAccount {
    struct Identity: Equatable {
        let id: String
        let label: String
    }

    let configuration: T3ConnectConfiguration
    private var sdk: Clerk?
    private var watcher: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private(set) var identity: Identity?
    var onChange: ((Identity?, Identity?) -> Void)?

    init(configuration: T3ConnectConfiguration) { self.configuration = configuration }

    func restore() async {
        if let restoration {
            await restoration.value
            return
        }
        let clerk = client()
        let task = Task { [weak self] in
            _ = try? await clerk.refreshClient()
            guard !Task.isCancelled else { return }
            self?.updateIdentity()
        }
        restoration = task
        await task.value
    }

    func signIn() async throws {
        let clerk = client()
        _ = try await clerk.auth.startHostedAuth()
        updateIdentity()
        guard identity != nil else {
            throw ClientError.http(401, "Finish signing in to T3 Connect in the browser.")
        }
    }

    func signOut() async throws {
        guard let sdk else { return }
        try await sdk.auth.signOut()
        updateIdentity()
    }

    func token(for accountID: String) async throws -> String {
        await restore()
        try Task.checkCancellation()
        guard let sdk, let session = sdk.session, session.status == .active, session.user?.id == accountID,
              let token = try await session.getToken(.init(template: configuration.jwtTemplate, skipCache: true)),
              sdk.session?.id == session.id, sdk.user?.id == accountID else {
            throw ClientError.http(401, "Sign in to this environment's T3 Connect account.")
        }
        try Task.checkCancellation()
        return token
    }

    func shutdown() {
        watcher?.cancel()
        restoration?.cancel()
    }

    private func client() -> Clerk {
        if let sdk { return sdk }
        // The browser authentication session receives the callback without registering Electron's scheme.
        let clerk = Clerk.configure(publishableKey: configuration.publishableKey, options: .init(
            telemetryEnabled: false,
            redirectConfig: .init(redirectUrl: "t3code://app/", callbackUrlScheme: "t3code")
        ))
        sdk = clerk
        watcher = Task { [weak self] in
            for await event in clerk.auth.events {
                switch event {
                case .sessionChanged, .signedOut, .accountDeleted: self?.updateIdentity()
                default: break
                }
            }
        }
        updateIdentity()
        return clerk
    }

    private func updateIdentity() {
        let next: Identity?
        if let sdk, sdk.session?.status == .active, let user = sdk.user {
            next = .init(id: user.id, label: user.primaryEmailAddress?.emailAddress ?? user.username ?? "Signed in")
        } else { next = nil }
        guard next != identity else { return }
        let previous = identity
        identity = next
        onChange?(previous, next)
    }
}
