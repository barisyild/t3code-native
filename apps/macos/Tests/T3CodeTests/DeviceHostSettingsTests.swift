import Testing
@testable import T3Code

struct DeviceHostSettingsTests {
    @Test func changingALegacySSHHostKeepsOtherRowsAndUnrelatedFields() throws {
        let saved: Wire = .object([
            "id": .string("mac"), "label": .string("Mac"), "target": .string("mac-mini"),
            "port": .int(2222), "identityFile": .string("/fixture/key"), "otherField": .bool(true),
        ])
        let second: Wire = .object(["id": .string("other"), "label": .string("Other"), "target": .string("other-mac")])
        let base = DeviceHostSettings(.object(["deviceHosts": .array([saved])]))
        let original = try #require(base.configurations.first)
        let settings = DeviceHostSettings(.object(["deviceHosts": .array([saved, second]), "easDeviceHosts": .array([])]))
        let edit = DeviceHostDraft(name: " Build Mac ", endpoint: .ssh(target: " ci@mac-mini ", identityFile: "", port: ""), credential: .environment)
        let patch = try settings.patch(edit, id: "mac", original: original)
        #expect(patch == ["deviceHosts": .array([
            .object(["id": .string("mac"), "label": .string("Build Mac"), "kind": .string("ssh"),
                     "target": .string("ci@mac-mini"), "otherField": .bool(true)]),
            second,
        ])])
        #expect(try settings.removal(original) == ["deviceHosts": .array([second])])
        #expect(throws: ClientError.self) { try DeviceHostSettings(.object(patch)).patch(edit, id: "mac", original: original) }
        #expect(throws: ClientError.self) { try DeviceHostSettings(.object(patch)).removal(original) }
    }

    @Test func anSSHCheckUsesTheWireSchemaBeforeSendingTheDestination() throws {
        let draft = DeviceHostDraft(name: "", endpoint: .ssh(target: " mac-mini ", identityFile: "~/keys/test", port: "2222"),
                                    credential: .environment)
        #expect(try draft.checkInput(id: "ssh-host", current: nil) == [
            "id": .string("ssh-host"), "kind": .string("ssh"), "label": .string("mac-mini"),
            "target": .string("mac-mini"), "identityFile": .string("~/keys/test"), "port": .int(2222),
        ])
        let invalid = DeviceHostDraft(name: "Mac", endpoint: .ssh(target: "-invalid", identityFile: "", port: ""),
                                      credential: .environment)
        #expect(throws: ClientError.self) { try invalid.checkInput(id: "ssh-host", current: nil) }
    }

    @Test(arguments: [
        Wire.string(SettingsSecret.savedMarker),
        .object(["provider": .string("vault"), "reference": .string("op://fixture/eas/token")]),
    ])
    func checkingASavedExpoAccountAndClearingItsTokenAreDistinct(token: Wire) throws {
        let settings = DeviceHostSettings(.object(["easDeviceHosts": .array([
            .object(["id": .string("expo"), "kind": .string("eas"), "label": .string("Expo"), "accessToken": token]),
        ])]))
        let original = try #require(settings.configurations.first)
        let endpoint = DeviceHostDraft.Endpoint.eas(project: "fixture-project", session: "30", idle: "10", concurrent: "2")
        let retain = DeviceHostDraft(name: "Expo", endpoint: endpoint, credential: .keep)
        #expect(try retain.checkInput(id: "expo", current: original) == ["hostId": .string("expo")])
        let kept = try settings.patch(retain, id: "expo", original: original)
        #expect(kept["easDeviceHosts"]?.array.first?["accessToken"] == token)
        #expect(kept["easDeviceHosts"]?.array.first?["appId"].string == "fixture-project")

        let clear = DeviceHostDraft(name: "Expo", endpoint: endpoint, credential: .environment)
        #expect(try clear.checkInput(id: "expo", current: original) == ["accessToken": .string("")])
        let cleared = try settings.patch(clear, id: "expo", original: original)
        #expect(cleared["easDeviceHosts"]?.array.first?["accessToken"] == .string(""))
        let invalid = DeviceHostDraft(name: "Expo", endpoint: .eas(project: "", session: "10", idle: "10", concurrent: "2"),
                                      credential: .keep)
        #expect(throws: ClientError.self) { try settings.patch(invalid, id: "expo", original: original) }
    }

    @Test func simlockKeepsATokenOnlyForItsGatewayOrigin() throws {
        let settings = DeviceHostSettings(.object(["simlockDeviceHosts": .array([
            .object(["id": .string("simlock"), "kind": .string("simlock"), "label": .string("Gateway"),
                     "gatewayUrl": .string("https://gateway.example.test:443/"), "agentToken": .string(SettingsSecret.savedMarker)]),
        ])]))
        let original = try #require(settings.configurations.first)
        let same = simlock(" HTTPS://Gateway.Example.Test/ ", .keep)
        let patch = try settings.patch(same, id: "simlock", original: original)
        #expect(patch["simlockDeviceHosts"]?.array.first?["gatewayUrl"].string == "https://gateway.example.test")
        #expect(try same.checkInput(id: "simlock", current: original) ==
                ["gatewayUrl": .string("https://gateway.example.test"), "hostId": .string("simlock")])
        let changed = simlock("https://new-gateway.example.test", .keep)
        #expect(throws: ClientError.self) { try settings.patch(changed, id: "simlock", original: original) }
        #expect(throws: ClientError.self) { try changed.checkInput(id: "simlock", current: original) }

        let replacement = try #require(SettingsSecretReference(provider: "vault", reference: "op://fixture/simlock/token"))
        let new = simlock("http://[::1]:4700/", .reference(replacement))
        #expect(try new.checkInput(id: "simlock", current: original) ==
                ["gatewayUrl": .string("http://[::1]:4700"), "agentToken": replacement.wire])
        for url in ["https://user@example.test", "https://example.test/path", "https://example.test?token=fixture"] {
            #expect(throws: ClientError.self) { try simlock(url, .environment).value(id: "new", current: nil) }
        }
    }

    private func simlock(_ gateway: String, _ credential: DeviceHostDraft.Credential) -> DeviceHostDraft {
        .init(name: "Gateway", endpoint: .simlock(gateway: gateway, leases: "2", duration: "60"), credential: credential)
    }
}
