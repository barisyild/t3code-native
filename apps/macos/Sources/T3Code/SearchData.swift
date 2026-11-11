import Foundation

struct MessageSearchScope: Equatable, Sendable {
    let connection: UUID
    let environmentID: String
}

struct FileSearchScope: Equatable, Sendable {
    let connection: UUID
    let context: WorkspaceFileContext
}

enum SearchText {
    static func limited(_ value: String, to limit: Int) -> String {
        guard value.utf16.count > limit else { return value }
        var end = value.startIndex
        var used = 0
        for character in value {
            used += character.utf16.count
            guard used <= limit else { break }
            end = value.index(after: end)
        }
        return String(value[..<end])
    }

    static func messageQuery(_ value: String) -> String {
        limited(value.trimmingCharacters(in: .whitespacesAndNewlines), to: 200)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func messageWords(_ query: String) -> [String] {
        let quotes = CharacterSet(charactersIn: "\"'\u{60}“”‘’").union(.whitespacesAndNewlines)
        let words = query.trimmingCharacters(in: quotes)
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.filter { word in
            let scalars = word.unicodeScalars
            return scalars.count >= 3 || (scalars.count == 2 && scalars.contains {
                switch $0.value {
                case 0x3040...0x30ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xac00...0xd7af, 0xf900...0xfaff: true
                default: false
                }
            })
        }
    }

    static func ranges(in text: String, for words: [String]) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        for word in words where !word.isEmpty {
            var start = 0
            while start < source.length {
                let match = source.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: NSRange(location: start, length: source.length - start))
                guard match.location != NSNotFound, match.length > 0 else { break }
                ranges.append(match)
                start = NSMaxRange(match)
            }
        }
        return ranges.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    }

    static func messageNeedle(query: String, snippet: String) -> String {
        let source = snippet as NSString
        if query.contains(where: \.isWhitespace), let phrase = ranges(in: snippet, for: [query]).first {
            return source.substring(with: phrase)
        }
        let word = messageWords(query).max(by: { $0.utf16.count < $1.utf16.count }) ?? query
        let matches = ranges(in: snippet, for: [word])
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < source.length, let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        let whole = matches.first { match in
            !isWordCharacter(at: match.location - 1) && !isWordCharacter(at: NSMaxRange(match))
        }
        return (whole ?? matches.first).map { source.substring(with: $0) } ?? word
    }
}

struct ThreadMessageHit: Equatable, Sendable {
    let threadID: String
    let projectID: String
    let messageID: String?
    let role: String
    let snippet: String
    let createdAt: String?

    init?(_ value: Wire) {
        guard let threadID = value["threadId"].string, !threadID.isEmpty,
              let projectID = value["projectId"].string, !projectID.isEmpty,
              let role = value["source"].string, role == "user" || role == "assistant",
              let snippet = value["snippet"].string else { return nil }
        self.threadID = threadID
        self.projectID = projectID
        self.role = role
        self.snippet = snippet
        messageID = value["messageId"].string.flatMap { $0.isEmpty ? nil : $0 }
        createdAt = value["messageCreatedAt"].string
    }

    var roleTitle: String { role == "user" ? "You" : "Agent" }
}

struct MessageSearchResult: Equatable, Sendable {
    let hit: ThreadMessageHit
    let title: String
    let projectTitle: String?
}

struct FileContentSearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

struct FileSearchHit: Equatable {
    let path: String
    let position: WorkspaceFilePosition?
    let excerpt: String?
    let ranges: [NSRange]

    var reference: WorkspaceFileReference { .file(.workspace(path), position) }

    init?(_ value: Wire, root: String, content: Bool) {
        guard let raw = value["path"].string, case .workspace(let path) = WorkspaceFilePath.resolve(raw, in: root),
              !path.isEmpty else { return nil }
        self.path = path
        if content {
            guard let text = value["lineContent"].string else { return nil }
            let length = text.utf16.count
            ranges = value["matchRanges"].array.compactMap { match in
                guard let start = match["start"].int, let end = match["end"].int,
                      start >= 0, start < end, end <= length else { return nil }
                return NSRange(location: start, length: end - start)
            }
            guard let position = WorkspaceFilePosition(line: value["lineNumber"].int, column: ranges.first.map { $0.location + 1 }) else { return nil }
            self.position = position
            excerpt = text
        } else {
            guard value["kind"].string == "file" else { return nil }
            position = nil
            excerpt = nil
            ranges = []
        }
    }
}

struct WorkspaceSearchResults {
    let hits: [FileSearchHit]
    let truncated: Bool
    let warning: String?
}
