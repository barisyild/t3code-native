import Foundation

struct PullRequestReference: Hashable, Sendable {
    let projectID: String
    let host: String?
    let repository: String
    let number: Int

    init?(_ value: Wire, projectID: String? = nil) {
        guard let projectID = value["projectId"].string ?? projectID,
              let repository = value["repository"].string, let number = value["number"].int, number > 0 else { return nil }
        self.projectID = projectID
        self.repository = repository
        self.number = number
        if let host = value["host"].string { self.host = host }
        else if let text = value["url"].string, let url = RepositoryRequestReference.webURL(text), let hostname = url.host() {
            host = url.port.map { "\(hostname):\($0)" } ?? hostname
        } else { host = nil }
    }

    var input: Payload {
        var input: Payload = ["projectId": .string(projectID), "repository": .string(repository), "number": .int(number)]
        if let host { input["host"] = .string(host) }
        return input
    }
}

struct PullRequestTarget: Equatable, Sendable {
    let reference: PullRequestReference
    let connection: UUID
}

struct PullRequestItem: Equatable {
    let reference: PullRequestReference
    let value: Wire

    var title: String { value["title"].string ?? reference.repository }
    var sigil: String { value["provider"].string == "gitlab" ? "!" : "#" }
    var state: String { value["isDraft"].bool == true && value["state"].string == "open" ? "Draft" : value["state"].string?.capitalized ?? "Pull request" }
    var updatedAt: String { value["updatedAt"].string ?? "" }
    var observedAt: Double { value["observedAt"].double ?? 0 }

    init?(_ value: Wire) {
        guard let reference = PullRequestReference(value) else { return nil }
        self.reference = reference
        self.value = value
    }
}

struct PullRequestListing {
    private(set) var items: [PullRequestItem] = []
    private(set) var cursors: Payload = [:]
    private(set) var errors: [String] = []
    private(set) var providerHints: [String] = []
    private(set) var truncated = false
    private var viewers: Payload = [:]

    mutating func apply(_ page: Wire, append: Bool) {
        let incoming = page["entries"].array.compactMap(PullRequestItem.init)
        var byReference: [PullRequestReference: PullRequestItem] = [:]
        for item in (append ? items + incoming : incoming) {
            if let old = byReference[item.reference],
               old.updatedAt > item.updatedAt || (old.updatedAt == item.updatedAt && old.observedAt > item.observedAt) { continue }
            byReference[item.reference] = item
        }
        items = byReference.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.reference.repository != $1.reference.repository { return $0.reference.repository < $1.reference.repository }
            if $0.reference.number != $1.reference.number { return $0.reference.number > $1.reference.number }
            return $0.reference.projectID < $1.reference.projectID
        }
        cursors = page["nextCursors"].object ?? [:]
        let pageErrors = page["errors"].array.compactMap { $0["message"].string }
        errors = append ? Array(Set(errors + pageErrors)).sorted() : pageErrors
        providerHints = page["providers"].array.compactMap { $0["detail"].string }
        truncated = page["truncated"].bool == true
        viewers = page["viewers"].object ?? [:]
    }

    func visibleItems(query: String, involvement: String) -> [PullRequestItem] {
        items.filter { item in
            let author = item.value["author"]["login"].string ?? ""
            if involvement == "reviewing" && item.value["viewerReviewRequested"].bool != true { return false }
            if involvement == "authored" {
                guard let host = item.reference.host, let viewer = viewers[host]?.string,
                      author.caseInsensitiveCompare(viewer) == .orderedSame else { return false }
            }
            if query.isEmpty { return true }
            let number = "\(item.sigil)\(item.reference.number)"
            let text = [number, item.title, item.reference.repository, item.value["headBranch"].string ?? "", author].joined(separator: " ")
            return text.localizedCaseInsensitiveContains(query)
        }
    }
}

struct PullRequestFile: Sendable, Equatable {
    let oldPath: String
    let newPath: String
    let kind: String
    let patch: String?
    let additions: Int
    let deletions: Int

    var path: String { kind == "deleted" ? oldPath : newPath }

    static func page(_ result: Wire) -> [Self] {
        var files = parse(result["patch"].string ?? "")
        let known = Set(files.map(\.path))
        for stat in result["omittedFileStats"].array {
            guard let path = stat["path"].string, !known.contains(path) else { continue }
            files.append(.init(oldPath: path, newPath: path, kind: "change", patch: nil,
                               additions: stat["additions"].int ?? 0, deletions: stat["deletions"].int ?? 0))
        }
        return files
    }

    private static func parse(_ patch: String) -> [Self] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() where line.hasPrefix("diff --git ") {
            if let start { ranges.append(start..<index) }
            start = index
        }
        if let start { ranges.append(start..<lines.endIndex) }
        else if !patch.isEmpty { ranges.append(lines.startIndex..<lines.endIndex) }
        return ranges.compactMap { parseFile(lines[$0]) }
    }

    private static func parseFile(_ lines: ArraySlice<Substring>) -> Self? {
        var old: String?
        var new: String?
        var headerOld: String?
        var headerNew: String?
        var kind = "change"
        var additions = 0
        var deletions = 0
        var inHunk = false
        for line in lines {
            if line.hasPrefix("@@") { inHunk = true }
            if inHunk {
                if line.first == "+" { additions += 1 }
                else if line.first == "-" { deletions += 1 }
            } else if line.hasPrefix("--- ") { old = pathFromMarker(line.dropFirst(4), prefix: "a/") }
            else if line.hasPrefix("+++ ") { new = pathFromMarker(line.dropFirst(4), prefix: "b/") }
            else if line.hasPrefix("rename from ") { old = decodePath(line.dropFirst(12)) }
            else if line.hasPrefix("rename to ") { new = decodePath(line.dropFirst(10)) }
            else if line.hasPrefix("new file mode ") { kind = "new" }
            else if line.hasPrefix("deleted file mode ") { kind = "deleted" }
            else if line.hasPrefix("diff --git ") {
                let paths = line.dropFirst(11)
                if let parts = headerPaths(paths) {
                    headerOld = pathFromMarker(parts.0, prefix: "a/")
                    headerNew = pathFromMarker(parts.1, prefix: "b/")
                }
            }
        }
        if old == "/dev/null" { kind = "new"; old = nil }
        if new == "/dev/null" { kind = "deleted"; new = nil }
        old = old ?? headerOld ?? new
        new = new ?? headerNew ?? old
        guard let old, let new else { return nil }
        if kind == "change", old != new { kind = inHunk ? "rename-changed" : "rename-pure" }
        return .init(oldPath: old, newPath: new, kind: kind, patch: lines.joined(separator: "\n"),
                     additions: additions, deletions: deletions)
    }

    private static func headerPaths(_ raw: Substring) -> (Substring, Substring)? {
        if raw.first == "\"", let end = quotedEnd(raw) {
            let rest = raw[raw.index(after: end)...].drop(while: { $0 == " " })
            if !rest.isEmpty { return (raw[...end], rest) }
        }
        for separator in [" \"b/", " b/"] {
            if let split = raw.range(of: separator, options: .backwards) {
                return (raw[..<split.lowerBound], raw[raw.index(after: split.lowerBound)...])
            }
        }
        return nil
    }

    private static func quotedEnd(_ text: Substring) -> String.Index? {
        var escaped = false
        for index in text.indices.dropFirst() {
            if escaped { escaped = false }
            else if text[index] == "\\" { escaped = true }
            else if text[index] == "\"" { return index }
        }
        return nil
    }

    private static func pathFromMarker(_ text: Substring, prefix: String) -> String {
        let path = decodePath(text.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? text)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func decodePath(_ raw: Substring) -> String {
        guard raw.first == "\"", let end = quotedEnd(raw) else { return String(raw) }
        let escaped = Array(raw[raw.index(after: raw.startIndex)..<end].utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < escaped.count {
            let byte = escaped[i]
            i += 1
            guard byte == 92, i < escaped.count else { bytes.append(byte); continue }
            let next = escaped[i]
            i += 1
            if (48...51).contains(next), i + 1 < escaped.count, (48...55).contains(escaped[i]), (48...55).contains(escaped[i + 1]) {
                bytes.append((next - 48) * 64 + (escaped[i] - 48) * 8 + (escaped[i + 1] - 48))
                i += 2
            } else {
                let controls: [UInt8: UInt8] = [97: 7, 98: 8, 102: 12, 110: 10, 114: 13, 116: 9, 118: 11]
                bytes.append(controls[next] ?? next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
