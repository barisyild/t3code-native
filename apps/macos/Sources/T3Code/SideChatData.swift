import Foundation

struct SideChatReference: Hashable, Sendable {
    let environmentID: String
    let parentID: String
    let threadID: String
}

struct SideChatParent: Equatable, Sendable {
    let environmentID: String
    let connection: UUID
    let threadID: String

    func child(_ id: String) -> SideChatReference {
        .init(environmentID: environmentID, parentID: threadID, threadID: id)
    }
}

enum SideChatCommand {
    static func prompt(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        guard ["/side", "/btw"].contains(text[..<end].lowercased()) else { return nil }
        return text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
