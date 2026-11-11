import Foundation

struct ProjectFileScope: Equatable, Sendable {
    let target: ProjectTarget
    let root: String
}

enum ProjectCheckoutMode: String, Sendable {
    case local
    case worktree

    var checkout: WorkspaceCheckout { self == .worktree ? .newWorktree(base: "HEAD") : .root() }
}

struct ProjectFileConfiguration: Sendable {
    let checkout: ProjectCheckoutMode?
    let actions: [ProjectActionDraft]

    init?(_ response: Wire) {
        guard response["exists"].bool != false, response["truncated"].bool != true,
              let text = response["contents"].string else { return nil }
        let withoutComments = text.replacing(#/("(?:[^"\\]|\\.)*")|//[^\r\n]*|/\*[\s\S]*?\*//#) { match in
            match.1.map(String.init) ?? " "
        }
        let json = withoutComments.replacing(#/("(?:[^"\\]|\\.)*")|,(\s*[}\]])/#) { match in
            match.1.map(String.init) ?? match.2.map(String.init) ?? ""
        }
        guard let file = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)), let fields = file.object else { return nil }
        if let field = fields["defaultThreadEnvMode"] {
            guard let mode = field.string.flatMap(ProjectCheckoutMode.init(rawValue:)) else { return nil }
            checkout = mode
        } else { checkout = nil }
        if let scripts = fields["scripts"] {
            guard case .array(let entries) = scripts, entries.count <= 50 else { return nil }
            actions = entries.compactMap(ProjectActionDraft.init(fromFile:))
            guard actions.count == entries.count else { return nil }
        } else { actions = [] }
    }
}
