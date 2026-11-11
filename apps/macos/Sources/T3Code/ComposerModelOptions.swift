import Foundation

struct ComposerModelOption: Equatable, Sendable {
    enum Kind: String, Sendable { case select, boolean }

    struct Choice: Equatable, Sendable {
        let value: Wire
        let title: String
        let description: String?
        var isDefault = false
    }

    let id: String
    let title: String
    let description: String?
    let kind: Kind
    let choices: [Choice]
    let defaultValue: Wire?
    let promptValues: Set<String>
    let isReasoning: Bool

    var isSpeed: Bool { id == "serviceTier" || id == "fastMode" }

    var effortLevels: [Choice] {
        guard isReasoning, kind == .select else { return [] }
        return ["low", "medium", "high", "xhigh", "max", "ultra"].compactMap { level in
            choices.first { $0.value == .string(level) }
        }
    }

    init?(_ wire: Wire) {
        guard let id = wire["id"].string, let title = wire["label"].string,
              let type = wire["type"].string, let kind = Kind(rawValue: type) else { return nil }
        self.id = id
        self.title = title
        self.kind = kind
        description = wire["description"].string
        isReasoning = wire["role"].string == "reasoning" ||
            ["reasoningEffort", "effort", "reasoning", "variant", "reasoning_effort", "thinking_level", "thinking"].contains(id)
        let injected = Set(wire["promptInjectedValues"].array.compactMap(\.string))
        promptValues = injected
        switch kind {
        case .select:
            choices = wire["options"].array.compactMap { option in
                guard let id = option["id"].string, let title = option["label"].string, !injected.contains(id) else { return nil }
                return Choice(value: .string(id), title: title, description: option["description"].string,
                              isDefault: option["isDefault"].bool == true)
            }
        case .boolean:
            choices = [
                .init(value: .bool(false), title: id == "fastMode" ? "Standard" : "Off", description: nil),
                .init(value: .bool(true), title: id == "fastMode" ? "Fast" : "On", description: nil),
            ]
        }
        guard !choices.isEmpty else { return nil }
        let current = wire["currentValue"]
        defaultValue = choices.contains { $0.value == current } ? current : choices.first(where: \.isDefault)?.value
    }

    func accepts(_ value: Wire) -> Bool { choices.contains { $0.value == value } }
}

struct ComposerModelOptions: Equatable {
    struct EffortDots: Equatable {
        let count: Int
        let lit: Int
    }

    let descriptors: [ComposerModelOption]
    private let selection: Wire
    private let overrides: Payload

    init(selection: Wire = .null, descriptors: [ComposerModelOption] = []) {
        self.selection = selection
        self.descriptors = descriptors
        var values: Payload = [:]
        let options = selection["options"]
        if let legacy = options.object {
            for (id, value) in legacy where value.bool != nil || value.string?.isEmpty == false {
                values[id] = value
            }
        } else {
            for option in options.array {
                let value = option["value"]
                guard let id = option["id"].string, value.bool != nil || value.string?.isEmpty == false else { continue }
                values[id] = value
            }
        }
        if values["effort"] == .string("ultracode"),
           descriptors.contains(where: { $0.id == "ultracode" && $0.kind == .boolean }),
           descriptors.contains(where: { $0.id == "effort" && $0.accepts(.string("xhigh")) }) {
            values["effort"] = .string("xhigh")
            values["ultracode"] = values["ultracode"] ?? .bool(true)
        }
        overrides = values
    }

    var reasoning: ComposerModelOption? { descriptors.first(where: \.isReasoning) }
    var speed: ComposerModelOption? { descriptors.first(where: \.isSpeed) }

    func override(for option: ComposerModelOption) -> Wire? { overrides[option.id] }

    func title(for option: ComposerModelOption) -> String {
        let value = effectiveValue(for: option)
        return option.choices.first { $0.value == value }?.title ?? option.title
    }

    func effortDots(for option: ComposerModelOption) -> EffortDots? {
        let levels = option.effortLevels
        guard !levels.isEmpty, let value = effectiveValue(for: option)?.string else { return nil }
        if value == "none" || value == "off" { return EffortDots(count: levels.count, lit: 0) }
        guard let index = levels.firstIndex(where: { $0.value == .string(value) }) else { return nil }
        return EffortDots(count: levels.count, lit: index + 1)
    }

    private func effectiveValue(for option: ComposerModelOption) -> Wire? {
        overrides[option.id].flatMap { option.accepts($0) ? $0 : nil } ?? option.defaultValue
    }

    func usesPromptEffort(_ prompt: String) -> Bool {
        guard reasoning?.promptValues.contains("ultrathink") == true else { return false }
        return prompt.range(of: #"\bultrathink\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func setting(_ value: Wire?, for id: String) -> Wire {
        guard var model = selection.object,
              let descriptor = descriptors.first(where: { $0.id == id }),
              value.map(descriptor.accepts) ?? true else { return selection }
        var next = overrides
        next[id] = value
        guard next != overrides else { return selection }
        model["options"] = next.isEmpty ? nil : .array(next.sorted { $0.key < $1.key }.map { entry in
            .object(["id": .string(entry.key), "value": entry.value])
        })
        return .object(model)
    }
}
