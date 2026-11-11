import Foundation

struct ComposerCommandTrigger: Equatable {
    enum Kind { case slash, skill }

    let kind: Kind
    let query: String
    let range: NSRange
    let atStart: Bool

    static func detect(_ text: String, caret: NSRange) -> Self? {
        let source = text as NSString
        guard caret.length == 0, caret.location > 0, caret.location <= source.length else { return nil }
        let before = NSRange(location: 0, length: caret.location)
        let boundary = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: before)
        let start = boundary.location == NSNotFound ? 0 : NSMaxRange(boundary)
        let range = NSRange(location: start, length: caret.location - start)
        let token = source.substring(with: range)
        let kind: Kind
        if token.hasPrefix("/") { kind = .slash }
        else if token.hasPrefix("$") { kind = .skill }
        else { return nil }
        let query = String(token.dropFirst())
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard query.unicodeScalars.allSatisfy(allowed.contains),
              kind != .skill || query.first?.isNumber != true else { return nil }
        let atStart = source.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Self(kind: kind, query: query, range: range, atStart: atStart)
    }

    func replacementRange(in text: String, inserting replacement: String) -> NSRange {
        let source = text as NSString
        let end = NSMaxRange(range)
        if replacement.hasSuffix(" "), end < source.length, source.character(at: end) == 32 {
            return NSRange(location: range.location, length: range.length + 1)
        }
        return range
    }
}

struct ComposerCommandItem: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case insert(String)
        case model
        case freshSession
    }

    let title: String
    let detail: String
    let action: Action
}

struct ComposerCommandCatalog: Equatable, Sendable {
    let commands: [ComposerCommandItem]
    let skills: [ComposerCommandItem]
    let pending: Bool

    init(_ value: Wire = .null) {
        var seenCommands = Set<String>()
        commands = value["slashCommands"].array.compactMap { command in
            guard let name = command["name"].string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  !name.isEmpty, seenCommands.insert(name.lowercased()).inserted else { return nil }
            return ComposerCommandItem(title: "/\(name)",
                                       detail: command["description"].string ?? command["input"]["hint"].string ?? "",
                                       action: .insert("/\(name) "))
        }
        var seenSkills = Set<String>()
        skills = value["skills"].array.compactMap { skill in
            guard skill["enabled"].bool == true, skill["userInvocable"].bool != false,
                  let name = skill["name"].string, !name.isEmpty, seenSkills.insert(name.lowercased()).inserted else { return nil }
            let display = skill["displayName"].string ?? name
            return ComposerCommandItem(title: "$\(display)",
                                       detail: skill["shortDescription"].string ?? skill["description"].string ?? "",
                                       action: .insert("$\(name) "))
        }
        pending = value["slashCommandsPending"].bool == true
    }

    func items(for trigger: ComposerCommandTrigger, freshSession: Bool, compact: Bool = true, sideChats: Bool = false) -> [ComposerCommandItem] {
        var items: [ComposerCommandItem] = []
        if trigger.kind == .slash {
            items.append(.init(title: "/model", detail: "Choose a response model", action: .model))
            if trigger.atStart {
                if sideChats {
                    items.append(.init(title: "/side", detail: "Start a side chat", action: .insert("/side ")))
                }
                if freshSession {
                    items.append(.init(title: "/clear", detail: "Start the next message in a fresh session", action: .freshSession))
                }
                let reserved = Set(items.map { $0.title.lowercased() })
                items += commands.filter {
                    let title = $0.title.lowercased()
                    return !reserved.contains(title) && (compact || title != "/compact")
                }
            }
        }
        items += skills
        let query = trigger.query.lowercased()
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (Int, Int, ComposerCommandItem)? in
            let label = String(item.title.dropFirst()).lowercased()
            let isSkill = item.title.hasPrefix("$")
            let search = isSkill && query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
            let token: String
            if case .insert(let text) = item.action {
                token = text.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            } else { token = label }
            if token == search || label == search { return (0, index, item) }
            if token.hasPrefix(search) || label.hasPrefix(search) { return (1, index, item) }
            if token.contains(search) || label.contains(search) { return (2, index, item) }
            if item.detail.lowercased().contains(search) { return (3, index, item) }
            return nil
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
}

struct ComposerCommandScope: Hashable {
    let connection: UUID
    let instanceID: String
    let cwd: String
}
