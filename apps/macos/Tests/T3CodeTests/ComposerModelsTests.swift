import Testing
@testable import T3Code

struct ComposerModelsTests {
    @Test func claudeChoicesFilterByDriverAndKeepTheProviderInstance() throws {
        let catalog = ComposerModels(providers: [
            try instance("work", driver: "claudeAgent", model: "Claude Opus 5.5"),
            try instance("personal", driver: "claudeAgent", model: "Claude Opus 5.5"),
            try instance("codex", driver: "codex", model: "GPT-6"),
            try instance("replay", driver: "devReplay", model: "Showcase"),
        ])
        let selection = Wire.object(["instanceId": .string("personal"), "model": .string("default"),
                                     "options": .array([.object(["id": .string("effort"), "value": .string("high")])])])

        let choices = catalog.choices(preserving: selection)
        #expect(choices.map(\.title) == ["Opus 5.5", "Opus 5.5"])
        #expect(choices.map { $0.selection["instanceId"].string } == ["work", "personal"])
        #expect(choices.first?.instanceTitle != choices.last?.instanceTitle)
        #expect(choices.last?.selection == selection)
        #expect(catalog.defaultSelection(for: .claude, preferred: selection) == selection)
        #expect(catalog.choices(preserving: catalog.defaultSelection(for: .codex, preferred: selection)).map(\.title) == ["GPT-6"])
    }

    @Test func existingOtherProviderRemainsUsableAndNewThreadsUseTheTwoVisibleFamilies() throws {
        let catalog = ComposerModels(providers: [
            try instance("devReplay", driver: "devReplay", model: "Showcase"),
            try instance("codex", driver: "codex", model: "GPT-6"),
        ])
        let legacy: Wire = .object(["provider": .string("devReplay"), "model": .string("default")])

        let existing = catalog.initialSelection(draft: .null, fallback: legacy, existingThread: true)
        #expect(existing == legacy)
        #expect(catalog.choices(preserving: existing).map(\.selection) == [legacy])
        #expect(catalog.initialSelection(draft: .null, fallback: legacy, existingThread: false)["instanceId"].string == "codex")
        #expect(!catalog.isAvailable(.claude))
        #expect(catalog.defaultSelection(for: .claude, preferred: legacy) == .null)
    }

    @Test func settingAndResettingAnOptionKeepsOtherOverridesAndProviderDefaults() throws {
        let tier = select("serviceTier", "Service Tier", values: [("default", "Standard"), ("fast", "Fast")], defaultValue: "default")
        let catalog = ComposerModels(providers: [try instance("codex", driver: "codex", model: "GPT-6", options: [tier])])
        let existing: Wire = .object([
            "provider": .string("codex"), "model": .string("default"),
            "options": .object(["futureOption": .bool(true)]),
        ])
        let options = catalog.options(for: existing)
        let descriptor = try #require(options.speed)
        #expect(options.title(for: descriptor) == "Standard")
        #expect(options.override(for: descriptor) == nil)
        #expect(options.setting(nil, for: descriptor.id) == existing)
        #expect(options.setting(.string("invalid"), for: descriptor.id) == existing)
        let edited = options.setting(.string("fast"), for: descriptor.id)
        #expect(edited["provider"].string == "codex")
        #expect(edited["options"].array.contains(.object(["id": .string("futureOption"), "value": .bool(true)])))
        #expect(catalog.options(for: edited).title(for: descriptor) == "Fast")
        let reset = catalog.options(for: edited).setting(nil, for: descriptor.id)
        #expect(reset["options"].array.map { $0["id"].string } == ["futureOption"])

        let only = catalog.options(for: .object(["instanceId": .string("codex"), "model": .string("default")]))
            .setting(.string("fast"), for: "serviceTier")
        #expect(catalog.options(for: only).setting(nil, for: "serviceTier")["options"] == .null)
    }

    @Test(arguments: ["xhigh", "high"])
    func claudeUltracodeIsTheLastEffortAndUsesProviderOptions(_ base: String) throws {
        let tiers = [("high", "High")] + (base == "xhigh" ? [("xhigh", "Extra High")] : [])
        let effort = select("effort", "Reasoning", values: tiers + [("ultrathink", "Ultrathink")],
                            defaultValue: "high", promptValues: ["ultrathink"])
        let ultracode: Wire = .object([
            "type": .string("boolean"), "id": .string("ultracode"), "label": .string("Ultracode"), "currentValue": .bool(true),
        ])
        let catalog = ComposerModels(providers: [try instance("work", driver: "claudeAgent", model: "Claude Opus", options: [effort, ultracode])])
        let speed: Wire = .object(["id": .string("fastMode"), "value": .bool(true)])
        let existing: Wire = .object([
            "instanceId": .string("work"), "model": .string("alias"),
            "options": .array([.object(["id": .string("effort"), "value": .string("ultracode")]), speed]),
        ])
        let options = catalog.options(for: existing)
        let descriptor = try #require(options.reasoning)
        #expect(options.title(for: descriptor) == "Ultracode")
        #expect(options.choices(for: descriptor).map(\.value) == tiers.map { Wire.string($0.0) } + [.string("ultracode")])
        #expect(options.override(for: descriptor) == .string("ultracode"))
        #expect(options.effortDots(for: descriptor) == .init(count: tiers.count + 1, lit: tiers.count + 1))
        #expect(options.usesPromptEffort("Try ULTRATHINK today"))
        #expect(!options.usesPromptEffort("ultrathinking"))
        #expect(options.setting(.string("ultrathink"), for: "effort") == existing)
        let edited = options.setting(.string("high"), for: "effort")
        #expect(edited["options"].array.contains(.object(["id": .string("ultracode"), "value": .bool(false)])))
        #expect(edited["model"].string == "alias")
        let regular = catalog.options(for: edited)
        #expect(regular.title(for: descriptor) == "High")
        let enabled = regular.setting(.string("ultracode"), for: "effort")
        #expect(enabled["options"].array == [
            .object(["id": .string("effort"), "value": .string(base)]),
            speed,
            .object(["id": .string("ultracode"), "value": .bool(true)]),
        ])
        let reset = regular.setting(nil, for: "effort")
        #expect(reset["options"].array == [speed])
        #expect(catalog.options(for: reset).title(for: descriptor) == "Ultracode")
        #expect(catalog.options(for: reset).override(for: descriptor) == nil)
    }

    @Test func claudeVersionsStayInTheirFamilyAndProviderInstance() throws {
        let work = try instance("work", driver: "claudeAgent", models: [
            model("claude-opus-5-5", "Claude Opus 5.5"),
            model("claude-opus-4-6", "Claude Opus 4.6", aliases: ["opus-4.6"]),
            model("claude-sonnet-5-5", "Claude Sonnet 5.5"),
            model("claude-fable-5-2", "Claude Fable 5.2"),
            model("claude-fable-5-1", "Claude Fable 5.1"),
        ])
        let personal = try instance("personal", driver: "claudeAgent", models: [
            model("claude-opus-5-5", "Claude Opus 5.5"),
        ])
        let catalog = ComposerModels(providers: [work, personal])
        let current: Wire = .object([
            "instanceId": .string("work"), "model": .string("opus-4.6"),
            "options": .array([.object(["id": .string("effort"), "value": .string("high")])]),
        ])
        let groups = catalog.groups(preserving: current)
        #expect(groups.map(\.title) == ["Fable", "Opus", "Sonnet", "Opus"])
        #expect(groups.first?.choices.map(\.version) == ["5.2", "5.1"])
        #expect(groups.first?.choices.map { $0.selection["instanceId"].string } == ["work", "work"])
        #expect(groups[1].choices.map(\.version) == ["5.5", "4.6"])
        #expect(groups[1].choices.last?.selection == current)
        #expect(groups.last?.choices.map { $0.selection["instanceId"].string } == ["personal"])
        #expect(groups.last?.choices.map(\.version) == ["5.5"])
    }

    @Test func codexVariantsGroupByNameAndCustomModelNamesStayIntact() throws {
        let catalog = ComposerModels(providers: [try instance("codex", driver: "codex", models: [
            model("openai.gpt-6.1-sol", "GPT-6.1-Sol"),
            model("gpt-6-sol", "GPT-6-Sol"),
            model("gpt-6-astra", "GPT-6-Astra"),
            model("gpt-6.1-team", "Team GPT 2026", custom: true),
        ])])
        let current: Wire = .object(["instanceId": .string("codex"), "model": .string("openai.gpt-6.1-sol")])
        let groups = catalog.groups(preserving: current)
        #expect(groups.map(\.title) == ["GPT Sol", "GPT Astra", "Team GPT 2026"])
        #expect(groups.first?.choices.map(\.version) == ["6.1", "6"])
        #expect(groups.first?.choices.first?.selection == current)
        #expect(groups.last?.choices.first?.version == nil)
    }

    @Test func modelSwitchComparesProviderAndVersionInsteadOfAliasesOrOptions() throws {
        let catalog = ComposerModels(providers: [
            try instance("claude", driver: "claudeAgent", models: [
                model("claude-opus-5-5", "Claude Opus 5.5", aliases: ["opus"]),
                model("claude-opus-4-6", "Claude Opus 4.6"),
            ]),
            try instance("codex", driver: "codex", models: [model("gpt-6.1-sol", "GPT-6.1-Sol")]),
        ])
        let active: Wire = .object(["provider": .string("claude"), "model": .string("opus")])
        let same: Wire = .object([
            "instanceId": .string("claude"), "model": .string("claude-opus-5-5"),
            "options": .array([.object(["id": .string("effort"), "value": .string("high")])]),
        ])
        #expect(catalog.modelSwitch(from: active, to: same) == nil)
        let version: Wire = .object(["instanceId": .string("claude"), "model": .string("claude-opus-4-6")])
        #expect(catalog.modelSwitch(from: active, to: version)?.activeTitle == "Opus 5.5")
        #expect(catalog.modelSwitch(from: active, to: version)?.selectedTitle == "Opus 4.6")
        let codex: Wire = .object(["instanceId": .string("codex"), "model": .string("gpt-6.1-sol")])
        #expect(catalog.modelSwitch(from: active, to: codex)?.selectedTitle == "GPT-6.1-Sol")
        #expect(catalog.modelSwitch(from: .null, to: codex) == nil)
    }

    @Test func effortDotsUseTheAvailableTiersAndKeepNamedModesSeparate() throws {
        let effort = try #require(ComposerModelOption(select(
            "effort", "Reasoning",
            values: [("default", "Default"), ("high", "High"), ("off", "Off"), ("medium", "Medium"),
                     ("ultracode", "Ultracode"), ("max", "Max"), ("low", "Low"), ("ultrathink", "Ultrathink")],
            defaultValue: "medium", promptValues: ["ultrathink"]
        )))
        let selection: Wire = .object(["instanceId": .string("claude"), "model": .string("opus")])
        let options = ComposerModelOptions(selection: selection, descriptors: [effort], family: .claude)
        #expect(options.effortDots(for: effort) == .init(count: 5, lit: 2))
        #expect(options.choices(for: effort).last?.value == .string("ultracode"))
        for (tier, lit) in [("off", 0), ("low", 1), ("high", 3), ("max", 4), ("ultracode", 5)] {
            let updated = ComposerModelOptions(selection: options.setting(.string(tier), for: "effort"),
                                               descriptors: [effort], family: .claude)
            #expect(updated.effortDots(for: effort) == .init(count: 5, lit: lit))
        }
        let unresolved = ComposerModelOptions(selection: options.setting(.string("default"), for: "effort"),
                                              descriptors: [effort], family: .claude)
        #expect(unresolved.effortDots(for: effort) == nil)
        #expect(options.setting(.string("ultrathink"), for: "effort") == selection)
        #expect(ComposerModelOptions(selection: selection, descriptors: [effort], family: .codex)
            .effortDots(for: effort) == .init(count: 4, lit: 2))
    }

    private func instance(_ id: String, driver: String, model: String, options: [Wire] = []) throws -> Provider {
        try instance(id, driver: driver, models: [self.model("default", model, aliases: ["alias"], options: options)])
    }

    private func instance(_ id: String, driver: String, models: [Wire]) throws -> Provider {
        try #require(Provider(.object([
            "instanceId": .string(id), "driver": .string(driver), "displayName": .string(driver), "enabled": .bool(true),
            "models": .array(models),
        ])))
    }

    private func model(_ slug: String, _ name: String, aliases: [String] = [], custom: Bool = false, options: [Wire] = []) -> Wire {
        .object([
            "slug": .string(slug), "name": .string(name), "isCustom": .bool(custom),
            "aliases": .array(aliases.map(Wire.string)), "capabilities": .object(["optionDescriptors": .array(options)]),
        ])
    }

    private func select(_ id: String, _ title: String, values: [(String, String)], defaultValue: String,
                        promptValues: [String] = []) -> Wire {
        .object([
            "id": .string(id), "type": .string("select"), "label": .string(title), "currentValue": .string(defaultValue),
            "promptInjectedValues": .array(promptValues.map(Wire.string)),
            "options": .array(values.map { .object(["id": .string($0.0), "label": .string($0.1)]) }),
        ])
    }
}
