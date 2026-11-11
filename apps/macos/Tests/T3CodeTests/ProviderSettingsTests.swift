import Foundation
import Testing
@testable import T3Code

struct ProviderSettingsTests {
    @Test func editingOneFieldPreservesTheLatestProviderConfiguration() throws {
        let redactedVariable: Wire = .object(["name": .string("FIXTURE_TOKEN"), "value": .string("[REDACTED]"), "secret": .bool(true)])
        let current: Wire = .object([
            "driver": .string("codex"),
            "enabled": .bool(true),
            "displayName": .string("Codex"),
            "environment": .array([redactedVariable]),
            "config": .object(["binaryPath": .string("/new/codex"), "homePath": .string("/home/old"), "newSetting": .bool(true)]),
        ])
        let original = ProviderConfigurationFields(name: "Codex", config: .object([
            "binaryPath": .string("/old/codex"), "homePath": .string("/home/old"),
        ]))
        var edited = original
        edited.name = "  Work Codex "
        edited.homePath = ""
        let result = try ProviderConfigurationEdit(before: original, after: edited).envelope(driver: "codex", preserving: current)
        #expect(result["displayName"].string == "Work Codex")
        #expect(result["environment"].array == [redactedVariable])
        #expect(result["config"]["binaryPath"].string == "/new/codex")
        #expect(result["config"]["homePath"] == .null)
        #expect(result["config"]["newSetting"].bool == true)
    }

    @Test func enablingALegacyEntryPreservesManagedRuntimePaths() throws {
        let current: Wire = .object([
            "driver": .string("codex"), "enabled": .bool(true),
            "config": .object(["enabled": .bool(false), "setupMode": .string("managed"), "homePath": .string("/managed/home")]),
        ])
        let provider = try #require(Provider(.object(["instanceId": .string("codex"), "enabled": .bool(false)])))
        let original = ProviderConfigurationFields(provider: provider, envelope: current)
        #expect(!original.enabled)
        var edited = original
        edited.enabled = true
        edited.homePath = "/ignored"
        let result = try ProviderConfigurationEdit(before: original, after: edited).envelope(driver: "codex", preserving: current)
        #expect(result["enabled"].bool == true)
        #expect(result["config"]["enabled"] == .null)
        #expect(result["config"]["homePath"].string == "/managed/home")
    }

    @Test func createsDistinctManagedAndExistingRuntimeConfigurations() throws {
        var fields = ProviderConfigurationFields(name: "Fixture")
        fields.binaryPath = "/fixture/agent"
        fields.shadowHomePath = "/fixture/shadow"
        let managed = try ProviderConfigurationEdit.create(.managedCodex, fields: fields)
        let codex = try ProviderConfigurationEdit.create(.codexCLI, fields: fields)
        let claude = try ProviderConfigurationEdit.create(.claudeCLI, fields: fields)
        #expect(managed["config"]["setupMode"].string == "managed")
        #expect(managed["config"]["binaryPath"] == .null)
        #expect(codex["config"]["setupMode"].string == "existing")
        #expect(codex["config"]["shadowHomePath"].string == "/fixture/shadow")
        #expect(claude["driver"].string == "claudeAgent")
        #expect(claude["config"]["binaryPath"].string == "/fixture/agent")
        #expect(claude["config"]["shadowHomePath"] == .null)
    }

    @Test func authenticationRepliesDoNotReplaceTheInstalledRuntime() throws {
        let auth: Wire = .object(["instanceId": .string("codex-fixture"), "phase": .string("succeeded")])
        let install: Wire = .object([
            "driver": .string("codex"), "phase": .string("succeeded"),
            "installedVersion": .string("1.2.3"), "canRemove": .bool(true),
        ])
        #expect(ProviderAuthState(auth)?.phase == .succeeded)
        #expect(ProviderInstallState(auth) == nil)
        #expect(ProviderAuthState(install) == nil)
        let runtime = try #require(ProviderInstallState(install))
        #expect(runtime.canRemove && runtime.installedVersion == "1.2.3")
    }

    @Test func rejectsCallbacksFromOtherSignInFlows() throws {
        let state = "fixture-state-1234567"
        let redirect = "http://127.0.0.1:49152/auth/callback"
        let query = [
            URLQueryItem(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: String(repeating: "a", count: 43)),
            .init(name: "client_id", value: "dynamic_agent_client"),
        ]
        var page = try #require(URLComponents(string: "https://auth.openai.com/api/accounts/authorize"))
        page.queryItems = query
        let authorization = try #require(page.string)
        let flow = try #require(CodexAuthorizationRequest(authorization))
        page.host = "example.com"
        let wrongHost = try #require(page.string)
        #expect(CodexAuthorizationRequest(wrongHost) == nil)
        page.host = "auth.openai.com"
        page.queryItems = query + [.init(name: "state", value: state)]
        let duplicateState = try #require(page.string)
        #expect(CodexAuthorizationRequest(duplicateState) == nil)

        let goodQuery = "?code=fixture-code&state=" + state
        #expect(try flow.callback("127.0.0.1:49152/auth/callback" + goodQuery) == redirect + goodQuery)
        #expect(try flow.callback(request: Data("GET /auth/callback\(goodQuery) HTTP/1.1\r\nHost: 127.0.0.1:49152".utf8)) == redirect + goodQuery)
        for invalid in [
            redirect + "?code=fixture-code&state=another-state-1234567",
            redirect + goodQuery + "&code=duplicate",
            redirect + goodQuery + "&error=access_denied",
            redirect + goodQuery + "&client_id=unexpected",
            "http://127.0.0.1:49153/auth/callback" + goodQuery,
            "https://127.0.0.1:49152/auth/callback" + goodQuery,
            "http://127.0.0.1:49152/different" + goodQuery,
        ] {
            #expect(throws: ClientError.self) { try flow.callback(invalid) }
        }
        #expect(throws: ClientError.self) {
            try flow.callback(request: Data("POST /auth/callback\(goodQuery) HTTP/1.1".utf8))
        }
    }
}
