import Foundation

struct ProjectOnboardingScope: Equatable, Sendable {
    let environmentID: String
    let connection: UUID
}

struct ProjectOnboardingSettings: Sendable {
    let baseDirectory: String
    let ghqLayout: Bool

    init(_ settings: Wire = .null) {
        let directory = settings["addProjectBaseDirectory"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        baseDirectory = directory.isEmpty ? "~/" : directory
        ghqLayout = settings["ghqCloneLayout"].bool == true
    }
}

struct ProjectAddAttempt: Sendable {
    let projectID = UUID().uuidString
    let commandID = UUID().uuidString
    let createdAt = Date().formatted(.iso8601)
}

enum ProjectHostPath {
    static func resolve(_ raw: String, cwd: String?, platform: String?) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count > 1, let quote = path.first, (quote == "\"" || quote == "'"), path.last == quote {
            path = String(path.dropFirst().dropLast())
            if quote == "'" { path = path.replacingOccurrences(of: "'\\''", with: "'") }
        }
        guard !path.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ClientError.message("Enter a folder path on the environment.")
        }
        if isWindows(path), platform != nil, platform != "windows", platform != "unknown" {
            throw ClientError.message("Windows-style paths require a Windows environment.")
        }
        let relative = [".", ".."].contains(path) || ["./", "../", ".\\", "..\\"].contains(where: path.hasPrefix)
        if relative {
            guard let cwd else { throw ClientError.message("Choose a project before using a relative folder path.") }
            let windows = usesBackslashes(cwd, platform: platform)
            let parts = path.split { $0 == "/" || (windows && $0 == "\\") }
            path = cwd
            for part in parts where part != "." {
                if part == ".." { path = parent(of: path, platform: platform) ?? path }
                else { path = append(String(part), to: path, platform: platform) }
            }
        }
        return trimSeparators(path, platform: platform)
    }

    static func folderName(_ path: String, platform: String?) -> String {
        let normalized = trimSeparators(path, platform: platform)
        let separator = usesBackslashes(normalized, platform: platform)
        return normalized.split(whereSeparator: { $0 == "/" || (separator && $0 == "\\") }).last.map(String.init) ?? normalized
    }

    static func append(_ child: String, to base: String, platform: String?) -> String {
        let directory = browseDirectory(base, platform: platform)
        let name = directory.hasSuffix("\\") ? child.replacingOccurrences(of: "/", with: "\\") : child
        return directory + name
    }

    static func browseDirectory(_ path: String, platform: String?) -> String {
        if path == "~" { return "~/" }
        let windows = usesBackslashes(path, platform: platform)
        if path.hasSuffix("/") || (windows && path.hasSuffix("\\")) { return path }
        return path + (windows ? "\\" : "/")
    }

    static func parent(of path: String, platform: String?) -> String? {
        let windows = usesBackslashes(path, platform: platform)
        let normalized = trimSeparators(path, platform: platform)
        let slash = windows ? normalized.replacingOccurrences(of: "\\", with: "/") : normalized
        guard slash != "/", slash.firstMatch(of: /^[A-Za-z]:\/$/) == nil,
              let index = slash.lastIndex(of: "/") else { return nil }
        if slash.hasPrefix("//"), slash.split(separator: "/").count <= 2 { return nil }
        let parent = index == slash.startIndex ? "/" : String(slash[..<index])
        let directory = parent.firstMatch(of: /^[A-Za-z]:$/) != nil ? parent + "/" : parent
        return windows ? directory.replacingOccurrences(of: "/", with: "\\") : directory
    }

    static func matches(_ lhs: String, _ rhs: String, platform: String?) -> Bool {
        let first = trimSeparators(lhs, platform: platform)
        let second = trimSeparators(rhs, platform: platform)
        if platform == "windows" || isWindows(first) || isWindows(second) {
            return first.replacingOccurrences(of: "/", with: "\\").lowercased() ==
                second.replacingOccurrences(of: "/", with: "\\").lowercased()
        }
        return first.utf8.elementsEqual(second.utf8)
    }

    private static func trimSeparators(_ value: String, platform: String?) -> String {
        let windows = usesBackslashes(value, platform: platform)
        let suffix = value.reversed().prefix { $0 == "/" || (windows && $0 == "\\") }.count
        let path = String(value.dropLast(suffix))
        if path.isEmpty { return value.isEmpty ? value : String(value.prefix(1)) }
        if windows, path.firstMatch(of: /^[A-Za-z]:$/) != nil { return path + (value.hasSuffix("/") ? "/" : "\\") }
        return path
    }

    private static func usesBackslashes(_ value: String, platform: String?) -> Bool {
        !value.hasPrefix("~/") && (platform == "windows" || isWindows(value))
    }

    private static func isWindows(_ value: String) -> Bool {
        value.hasPrefix("\\\\") || value.firstMatch(of: /^[A-Za-z]:(?:[\\\/]|$)/) != nil
    }
}

struct ProjectFolderListing: Sendable {
    struct Entry: Equatable, Sendable {
        let name: String
        let path: String
    }

    let directory: String
    let entries: [Entry]

    init(_ value: Wire) throws {
        directory = try value.requireString("parentPath")
        entries = value["entries"].array.compactMap {
            guard let name = $0["name"].string, let path = $0["fullPath"].string else { return nil }
            return Entry(name: name, path: path)
        }
    }
}

struct CloneRepository: Sendable {
    let name: String
    let https: String
    let ssh: String

    init(_ value: Wire) throws {
        name = try value.requireString("nameWithOwner")
        https = try value.requireString("url")
        ssh = try value.requireString("sshUrl")
    }
}

struct CloneProviderChoice: Equatable, Sendable {
    let id: String
    let title: String

    init?(_ value: Wire) {
        guard value["status"].string == "available", value["auth"]["status"].string != "unauthenticated",
              let id = value["kind"].string, id != "unknown", let title = value["label"].string else { return nil }
        self.id = id
        self.title = title
    }
}

enum ProjectCloneControl: Sendable { case cancel, retry, remove }

enum CloneAddress {
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.wholeMatch(of: /[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*/) != nil {
            return "https://github.com/" + trimmed + (trimmed.hasSuffix(".git") ? "" : ".git")
        }
        return trimmed
    }

    static func directory(_ address: String, ghq: Bool) -> String? {
        let host: String?
        let path: String
        if address.contains("://"), let url = URLComponents(string: address) {
            host = url.scheme?.lowercased() == "file" ? nil : url.host
            path = url.percentEncodedPath
        } else if address.firstMatch(of: /^[A-Za-z]:[\\\/]/) == nil,
                  let match = address.wholeMatch(of: /(?:[^@\/\s]+@)?(\[[^\]@\/\s]+\]|[^:\/\s\[\]]+):(?!\/)(.+)/) {
            host = String(match.1)
            path = String(match.2)
        } else {
            host = nil
            path = address.replacingOccurrences(of: "\\", with: "/")
        }
        let withoutQuery = path.prefix { $0 != "?" && $0 != "#" }
        var segments = withoutQuery.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let last = segments.popLast() else { return nil }
        let leaf = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        guard validSegment(leaf) else { return nil }
        if ghq, let host, ([host] + segments).allSatisfy(validSegment) {
            return ([host] + segments + [leaf]).joined(separator: "/")
        }
        return leaf
    }

    private static func validSegment(_ value: String) -> Bool {
        guard !value.isEmpty, ![".", ".."].contains(value), !value.hasSuffix("."), !value.hasSuffix(" "),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)) == nil else { return false }
        return value.firstMatch(of: /(?i)^(?:con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³])(?: *\.| *$)/) == nil
    }
}

struct ProjectCloneStatus: Equatable, Sendable {
    enum Phase: String, Sendable { case starting, running, done, failed, cancelled }
    let id: String
    let phase: Phase
    let stage: String
    let percent: Int?
    let detail: String?
    let stalled: Bool
    let error: String?
    let sequence: Int

    init(starting id: String) {
        self.id = id
        phase = .starting
        stage = "connecting"
        percent = nil
        detail = nil
        stalled = false
        error = nil
        sequence = -1
    }

    init?(_ value: Wire) {
        guard let id = value["projectId"].string, let phase = value["phase"].string.flatMap(Phase.init(rawValue:)),
              phase != .starting, let sequence = value["sequence"].int else { return nil }
        self.id = id
        self.phase = phase
        self.sequence = sequence
        stage = value["stage"].string ?? "connecting"
        percent = value["percent"].int.map { min(100, max(0, $0)) }
        detail = value["detail"].string
        stalled = value["stalled"].bool == true
        error = value["error"].string
    }

    var blocksCheckout: Bool { phase != .done }
    var canRetry: Bool { phase == .failed || phase == .cancelled }
    var sendReason: String? {
        blocksCheckout ? (canRetry ? "Retry the clone before sending." : "Cloning repository…") : nil
    }

    var progressText: String {
        let label: String = switch stage {
        case "counting": "Counting objects"
        case "receiving": "Receiving objects"
        case "resolving": "Resolving deltas"
        case "checkout": "Checking out files"
        default: "Connecting"
        }
        return [label, percent.map { "\($0)%" }, stalled ? "Stalled" : detail].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProjectCloneList {
    private(set) var tracked: [String: ProjectCloneStatus] = [:]
    private var starting: Set<String> = []

    func status(_ id: String) -> ProjectCloneStatus? {
        tracked[id] ?? (starting.contains(id) ? ProjectCloneStatus(starting: id) : nil)
    }

    var blockedPhases: [String: ProjectCloneStatus.Phase] {
        var phases = tracked.compactMapValues { $0.blocksCheckout ? $0.phase : nil }
        for id in starting where phases[id] == nil { phases[id] = .starting }
        return phases
    }

    mutating func markStarting(_ id: String) {
        if tracked[id] == nil { starting.insert(id) }
    }
    mutating func clearStarting(_ id: String) { starting.remove(id) }
    mutating func clearStarting() { starting.removeAll() }

    mutating func apply(_ value: Wire, reconnecting: Bool = false) -> Bool {
        guard case .array(let entries) = value else { return false }
        var next: [String: ProjectCloneStatus] = [:]
        for status in entries.compactMap(ProjectCloneStatus.init) {
            let previous = next[status.id] ?? (reconnecting ? nil : tracked[status.id])
            next[status.id] = previous.flatMap { $0.sequence > status.sequence ? $0 : nil } ?? status
        }
        let changed = tracked != next || !starting.isDisjoint(with: next.keys)
        starting.subtract(next.keys)
        tracked = next
        return changed
    }
}
