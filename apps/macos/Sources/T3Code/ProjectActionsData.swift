import Foundation

enum ProjectActionIcon: String, CaseIterable, Sendable {
    case play, test, lint, configure, build, debug

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .play: "play"
        case .test: "checkmark.seal"
        case .lint: "checklist"
        case .configure: "gearshape"
        case .build: "hammer"
        case .debug: "ladybug"
        }
    }
}

struct ProjectAction: Equatable, Sendable {
    let id: String
    let value: Wire
    let draft: ProjectActionDraft

    init?(_ value: Wire) {
        guard let id = value["id"].string, !id.isEmpty else { return nil }
        let draft = ProjectActionDraft(value)
        guard !draft.name.isEmpty, !draft.command.isEmpty else { return nil }
        self.id = id
        self.value = value
        self.draft = draft
    }
}

struct ProjectActionDraft: Equatable, Sendable {
    var name: String
    var command: String
    var icon: ProjectActionIcon
    var setup: Bool
    var waitForSetup: Bool
    var onSettle: Bool
    var stopOnSettle: Bool
    var preview: String
    var autoOpenPreview: Bool

    init(_ value: Wire = .null) {
        name = value["name"].string ?? ""
        command = value["command"].string ?? ""
        icon = value["icon"].string.flatMap(ProjectActionIcon.init(rawValue:)) ?? .play
        setup = value["runOnWorktreeCreate"].bool == true
        waitForSetup = setup && value["async"].bool == false
        onSettle = value["runOnSettle"].bool == true
        stopOnSettle = value["stopOnSettle"].bool == true
        preview = value["previewUrl"].string ?? ""
        autoOpenPreview = !preview.isEmpty && value["autoOpenPreview"].bool == true
    }

    init?(fromFile value: Wire) {
        guard let fields = value.object, fields["name"]?.string != nil, fields["command"]?.string != nil else { return nil }
        if let icon = fields["icon"], icon.string.flatMap(ProjectActionIcon.init(rawValue:)) == nil { return nil }
        for key in ["runOnWorktreeCreate", "async", "runOnSettle", "stopOnSettle", "autoOpenPreview"] {
            if let field = fields[key], field.bool == nil { return nil }
        }
        if let url = fields["previewUrl"], url.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
        self.init(value)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return nil }
    }

    func encode(id: String, preserving original: Wire = .null) throws -> Wire {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { throw ClientError.message("Enter a name and a command.") }
        let preview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = original.object ?? [:]
        fields["id"] = .string(id)
        fields["name"] = .string(name)
        fields["command"] = .string(command)
        fields["icon"] = .string(icon.rawValue)
        fields["runOnWorktreeCreate"] = .bool(setup)
        fields["async"] = setup ? .bool(!waitForSetup) : nil
        fields["runOnSettle"] = .bool(onSettle)
        fields["stopOnSettle"] = .bool(stopOnSettle)
        fields["previewUrl"] = preview.isEmpty ? nil : .string(preview)
        fields["autoOpenPreview"] = preview.isEmpty ? nil : .bool(autoOpenPreview)
        return .object(fields)
    }
}

enum ProjectActionChange: Sendable {
    case save(ProjectActionDraft, id: String, replacing: ProjectAction?)
    case remove(ProjectAction)
    case inherit

    func applying(to scripts: [Wire]) throws -> Wire? {
        var next = scripts
        switch self {
        case .inherit: return nil
        case .save(let draft, let id, let previous):
            let action = try draft.encode(id: id, preserving: previous?.value ?? .null)
            if let previous {
                next[try Self.index(of: previous, in: scripts)] = action
            } else if let existing = scripts.first(where: { $0["id"].string == id }) {
                guard existing == action else { throw ClientError.message("This action already exists. Reopen it to make more changes.") }
            } else { next.append(action) }
        case .remove(let previous):
            if scripts.contains(where: { $0["id"].string == previous.id }) {
                next.remove(at: try Self.index(of: previous, in: scripts))
            }
        }
        return .array(next)
    }

    static func newID() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24))
    }

    private static func index(of action: ProjectAction, in scripts: [Wire]) throws -> Int {
        guard let index = scripts.firstIndex(where: { $0["id"].string == action.id }), scripts[index] == action.value else {
            throw ClientError.message("This action changed on the server. Reopen it to edit the latest version.")
        }
        return index
    }
}
