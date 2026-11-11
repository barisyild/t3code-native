import Testing
@testable import T3Code

struct UsageHubSettingsTests {
    @Test func hubAddressNormalizesManagementPagesAndRejectsCredentials() {
        #expect(UsageHubAddress(" HTTPS://Hub.Example.Test:443/proxy/management.html?tab=usage#top ")?.value ==
                "https://hub.example.test/proxy/")
        #expect(UsageHubAddress("http://[::1]:8318/management.html")?.value == "http://[::1]:8318/")
        #expect(UsageHubAddress("https://user:password@hub.example.test") == nil)
        #expect(UsageHubAddress("file:///tmp/fixture") == nil)
    }

    @Test func savedKeyIsKeptOnlyAtItsExistingHubAddress() throws {
        let original = try configuration("first", url: "https://first.example.test", label: "First")
        let edit = UsageHubEdit(url: "https://first.example.test/management.html", label: "Renamed", enabled: false, key: .keep)
        let wire = try edit.value(original: original, current: original, hubs: [original.id: original])
        #expect(wire["managementKey"].string == SettingsSecret.savedMarker)
        #expect(wire["enabled"].bool == false)
        #expect(wire["label"].string == "Renamed")
        let moved = UsageHubEdit(url: "https://other.example.test", label: "Renamed", enabled: true, key: .keep)
        #expect(throws: ClientError.self) { try moved.value(original: original, current: original, hubs: [original.id: original]) }

        let current = try configuration("first", url: "https://other.example.test", label: "First")
        let replace = UsageHubEdit(url: "https://first.example.test", label: "Renamed", enabled: true, key: .value("fixture"))
        #expect(throws: ClientError.self) { try replace.value(original: original, current: current, hubs: [current.id: current]) }
    }

    @Test func alternateManagementPageDoesNotCreateADuplicateHub() throws {
        let existing = try configuration("first", url: "https://same.example.test/proxy", label: "First")
        let add = UsageHubEdit(url: "https://same.example.test/proxy/management.html", label: "Second", enabled: true, key: .value("fixture"))
        #expect(throws: ClientError.self) { try add.value(original: nil, current: nil, hubs: [existing.id: existing]) }
    }

    @Test func aConfiguredSecretProviderCanSupplyTheManagementKey() throws {
        let reference = try #require(SettingsSecretReference(provider: "fixture", reference: "op://vault/item/password"))
        let edit = UsageHubEdit(url: "https://hub.example.test", label: "", enabled: true, key: .reference(reference))
        let config = try edit.value(original: nil, current: nil, hubs: [:])
        var settings = UsageHubSettings(supportsReferences: true)
        settings.apply(.object([
            "usageLimitSources": .object(["hub": config]),
            "secretProviders": .object([
                "fixture": .object(["label": .string("Fixture"), "config": .object([:])]),
                "unsupported": .object(["label": .string("Unsupported")]),
            ]),
        ]))
        #expect(settings.secretProviders.map(\.id) == ["fixture"])
        #expect(settings.configurations?["hub"]?.reference == reference)
        #expect(settings.configurations?["hub"]?.hasKey == true)
    }

    @Test func sourceSnapshotsPinResetCreditToItsAccountAndHub() throws {
        let source = try #require(UsageLimitSource(.object([
            "id": .string("hub"), "label": .string("Fixture"), "accounts": .array([
                account("first.json", credit: "credit-one"), account("second.json", credit: nil),
            ]),
        ])))
        let first = try #require(source.accounts.first)
        #expect(first.title == "first.json")
        #expect(first.resets.first?.target?.payload == ["sourceId": .string("hub"), "accountId": .string("first.json"), "creditId": .string("credit-one")])
        #expect(source.accounts.last?.resets.first?.target == nil)
    }

    private func configuration(_ id: String, url: String, label: String) throws -> UsageHubConfiguration {
        try #require(UsageHubConfiguration(id: id, value: .object([
            "kind": .string("cliproxy"), "url": .string(url), "label": .string(label),
            "managementKey": .string(SettingsSecret.savedMarker), "enabled": .bool(true),
        ])))
    }

    private func account(_ id: String, credit: String?) -> Wire {
        var credits: Payload = ["availableCount": .int(1)]
        credits["nextCreditId"] = credit.map(Wire.string)
        return .object(["id": .string(id), "driver": .string("codex"), "usageLimits": .object([
            "checkedAt": .string("2026-11-10T10:00:00Z"), "windows": .array([]), "resetCredits": .object(credits),
        ])])
    }
}
