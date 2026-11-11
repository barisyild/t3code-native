import Foundation

struct ProjectTarget: Hashable, Sendable {
    let id: String
    let connection: UUID
}

enum ProjectMetadataChange: Sendable {
    case rename(String)
    case pin(Bool)
    case archive(Bool)

    var fields: Payload {
        switch self {
        case .rename(let name): ["title": .string(name)]
        case .pin(let pinned): ["pinned": .bool(pinned)]
        case .archive(let archived): ["archived": .bool(archived)]
        }
    }
}

struct ProjectPreferences: Equatable, Sendable {
    enum Setting: String, CaseIterable, Sendable {
        case model = "defaultModelSelection"
        case checkout = "defaultThreadEnvMode"
        case autoPull = "defaultAutoPull"
        case actions = "defaultProjectScripts"

        var legacyKey: String {
            switch self {
            case .autoPull: "autoPull"
            case .actions: "scripts"
            default: rawValue
            }
        }
    }

    let loaded: Bool
    private let defaults: Payload
    private let overrides: Payload?
    private let folded: Bool
    private let legacyScripts: Payload

    init(_ settings: Wire = .null) {
        loaded = settings.object != nil
        let keys = Set(Setting.allCases.map(\.rawValue))
        defaults = settings.object?.filter { keys.contains($0.key) } ?? [:]
        overrides = settings["projectSettingsOverrides"].object
        folded = settings["projectSettingsFolded"].bool == true
        legacyScripts = settings["projectScriptOverrides"].object ?? [:]
    }

    var supportsOverrides: Bool { overrides != nil }

    func override(_ setting: Setting, for project: Project) -> Wire? {
        if let value = overrides?[project.id]?.object?[setting.rawValue] { return value }
        guard !folded else { return nil }
        switch setting {
        case .model: return project.defaultModel == .null ? nil : project.defaultModel
        case .checkout: return project.defaultCheckout.map(Wire.string)
        case .autoPull: return project.autoPull ? .bool(true) : nil
        case .actions:
            if let legacy = legacyScripts[project.id] { return legacy == .null ? nil : legacy }
            return project.scripts.isEmpty ? nil : .array(project.scripts)
        }
    }

    func value(_ setting: Setting, for project: Project) -> Wire {
        override(setting, for: project) ?? defaults[setting.rawValue] ?? .null
    }

    func configuredCheckout(for project: Project) -> ProjectCheckoutMode? {
        value(.checkout, for: project).string.flatMap(ProjectCheckoutMode.init(rawValue:))
    }

    func checkout(for project: Project, fileMode: ProjectCheckoutMode?, newProjectsRoot: String?, hasThreads: @autoclosure () -> Bool) -> WorkspaceCheckout {
        if let mode = override(.checkout, for: project)?.string.flatMap(ProjectCheckoutMode.init(rawValue:)) { return mode.checkout }
        guard let mode = configuredCheckout(for: project) else { return (fileMode ?? .local).checkout }
        if mode == .worktree, let newProjectsRoot,
           case .workspace(let child) = WorkspaceFilePath.resolve(project.root, in: newProjectsRoot),
           !child.isEmpty, !child.contains("/"), !hasThreads() {
            return .root()
        }
        return mode.checkout
    }

    func patch(_ setting: Setting, value: Wire?, for project: Project) -> Payload {
        var entry = overrides?[project.id]?.object ?? [:]
        entry[setting.rawValue] = value
        return ["projectSettingsOverrides": .object([project.id: entry.isEmpty ? .null : .object(entry)])]
    }
}
