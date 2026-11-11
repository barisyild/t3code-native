import Foundation

struct WorkspaceFileContext: Equatable, Sendable {
    let environmentID: String
    let root: String
    let threadID: String?
}

enum WorkspaceFilePath: Hashable, Sendable {
    case workspace(String)
    case host(String)

    var value: String {
        switch self {
        case .workspace(let path), .host(let path): path
        }
    }

    var workspaceRelative: String? {
        if case .workspace(let path) = self { path } else { nil }
    }

    var requestPath: String {
        if case .workspace(let path) = self, path.hasPrefix("~/") { return "./" + path }
        return value
    }

    static func resolve(_ raw: String, in root: String) -> Self? {
        let windows = isWindowsDrive(root) || isNetwork(root)
        let normalizedRoot = windows ? root.replacingOccurrences(of: "\\", with: "/") : root
        var path = windows ? raw.replacingOccurrences(of: "\\", with: "/") : raw
        if path.hasPrefix("/"), isWindowsDrive(String(path.dropFirst())) { path.removeFirst() }
        guard !path.isEmpty, path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        if path.hasPrefix("~/") { return .host(path) }
        let drive = isWindowsDrive(path)
        let network = isNetwork(path)
        if path.hasPrefix("/") || drive || network {
            guard windows == (drive || network) else { return nil }
            let base = normalizedRoot.split(separator: "/")
            let parts = path.split(separator: "/")
            let matches = base.count <= parts.count && zip(base, parts).allSatisfy { first, second in
                windows ? first.lowercased() == second.lowercased() : first.utf8.elementsEqual(second.utf8)
            }
            if matches, isNetwork(normalizedRoot) == network {
                return contained(parts.dropFirst(base.count)).map(Self.workspace)
            }
            return network ? nil : .host(path)
        }
        guard path.first != "\\", path.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:/) == nil else { return nil }
        return contained(path.split(separator: "/")[...]).map(Self.workspace)
    }

    private static func contained(_ parts: ArraySlice<Substring>) -> String? {
        var result: [Substring] = []
        for part in parts where part != "." {
            if part == ".." {
                guard result.popLast() != nil else { return nil }
            } else { result.append(part) }
        }
        return result.joined(separator: "/")
    }

    private static func isWindowsDrive(_ path: String) -> Bool {
        path.firstMatch(of: /^[A-Za-z]:[\\\/]/) != nil
    }

    private static func isNetwork(_ path: String) -> Bool {
        path.firstMatch(of: /^[\\\/]{2}/) != nil
    }
}

struct WorkspaceFilePosition: Hashable, Sendable {
    let line: Int
    let column: Int?

    init?(line: Int?, column: Int?) {
        guard let line, line > 0 else { return nil }
        self.line = line
        self.column = column.flatMap { $0 > 0 ? $0 : nil }
    }

    func selection(in text: String) -> NSRange? {
        let contents = text as NSString
        var start = 0
        for _ in 1..<line {
            guard start < contents.length else { return nil }
            var end = 0
            var contentEnd = 0
            contents.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: start, length: 0))
            guard end > contentEnd else { return nil }
            start = end
        }
        var end = 0
        contents.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
        guard let column else { return NSRange(location: start, length: end - start) }
        let index = start + min(column - 1, end - start)
        return index < end ? contents.rangeOfComposedCharacterSequence(at: index) : NSRange(location: index, length: 0)
    }
}

enum WorkspaceFileReference: Hashable, Sendable {
    case file(WorkspaceFilePath, WorkspaceFilePosition?)
    case directory(String)

    private static let linkScheme = "t3code-appkit-file"
    private static let extensionless = Set([
        "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile", "justfile",
        "Rakefile", "Gemfile", "Procfile", "Brewfile", "Caddyfile", "Vagrantfile", "Jenkinsfile",
        "Podfile", "Fastfile", "BUILD", "WORKSPACE", "LICENSE", "LICENCE", "COPYING", "NOTICE",
        "AUTHORS", "CONTRIBUTORS", "CHANGELOG", "README", "CODEOWNERS",
    ])

    init?(markdown link: URL, root: String) {
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        let destination: String
        if components.scheme?.lowercased() == "file" {
            guard components.user == nil, components.password == nil, components.port == nil,
                  components.percentEncodedPath.hasPrefix("/") else { return nil }
            let host = components.host ?? ""
            destination = (host.isEmpty || host.lowercased() == "localhost" ? "" : "//" + host) + components.percentEncodedPath
        } else {
            destination = String(link.relativeString.prefix { $0 != "#" && $0 != "?" })
            guard !destination.hasPrefix("//") else { return nil }
        }
        let decoded = destination.removingPercentEncoding ?? destination
        self.init(authored: decoded, fragment: components.fragment, root: root, inline: false)
    }

    init?(inlineCode code: String, root: String) {
        guard !code.contains(where: \.isWhitespace), !code.contains("`") else { return nil }
        self.init(authored: code, fragment: nil, root: root, inline: true)
    }

    init?(changedPath path: String, root: String) {
        guard let resolved = WorkspaceFilePath.resolve(path, in: root), resolved.workspaceRelative != "" else { return nil }
        self = .file(resolved, nil)
    }

    private init?(authored: String, fragment: String?, root: String, inline: Bool) {
        var path = authored
        let position: WorkspaceFilePosition?
        if let match = path.firstMatch(of: /:([0-9]+)(?::([0-9]+))?$/) {
            position = .init(line: Int(match.1), column: match.2.flatMap { Int($0) })
            path.removeSubrange(match.range)
        } else if let match = fragment?.wholeMatch(of: /[Ll]([0-9]+)(?:[Cc]([0-9]+))?/) {
            position = .init(line: Int(match.1), column: match.2.flatMap { Int($0) })
        } else { position = nil }

        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let name = segments.last.map(String.init) ?? ""
        let suffix = (name as NSString).pathExtension
        let containsSeparator = path.contains("/") || path.contains("\\")
        let directory = path.hasSuffix("/") || path.hasSuffix("\\")
        if inline {
            guard containsSeparator || position != nil, !directory,
                  !segments.contains(where: { $0 == "…" || ($0.count >= 3 && $0.allSatisfy { $0 == "." }) }) else { return nil }
            let explicit = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/") ||
                path.firstMatch(of: /^[A-Za-z]:[\\\/]/) != nil
            if !explicit {
                guard !suffix.isEmpty, name.firstMatch(of: /[0-9]\.[0-9][^.]*$/) == nil else { return nil }
                let first = segments.first?.lowercased() ?? ""
                guard first != "localhost", first.wholeMatch(of: /[0-9]+(?:\.[0-9]+)+/) == nil,
                      first.firstMatch(of: /\.(?:com|net|org|io|dev|app|ai|co|edu|gov)$/) == nil else { return nil }
            }
        } else {
            guard containsSeparator || !suffix.isEmpty || Self.extensionless.contains(name) || path == "." else { return nil }
        }

        guard let resolved = WorkspaceFilePath.resolve(path, in: root) else { return nil }
        if let relative = resolved.workspaceRelative, directory || relative.isEmpty {
            self = .directory(relative)
        } else {
            self = .file(resolved, position)
        }
    }

    var link: URL? {
        var components = URLComponents()
        components.scheme = Self.linkScheme
        components.host = "open"
        switch self {
        case .directory(let path):
            components.queryItems = [.init(name: "directory", value: path)]
        case .file(let path, let position):
            var items = [URLQueryItem(name: path.workspaceRelative == nil ? "host" : "file", value: path.value)]
            if let position {
                items.append(.init(name: "line", value: String(position.line)))
                if let column = position.column { items.append(.init(name: "column", value: String(column))) }
            }
            components.queryItems = items
        }
        return components.url
    }

    static func isFileLink(_ link: URL) -> Bool { link.scheme == linkScheme }

    init?(internalLink link: URL) {
        guard Self.isFileLink(link),
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let directory = value("directory") { self = .directory(directory); return }
        let position = WorkspaceFilePosition(line: value("line").flatMap(Int.init), column: value("column").flatMap(Int.init))
        if let path = value("file") { self = .file(.workspace(path), position) }
        else if let path = value("host") { self = .file(.host(path), position) }
        else { return nil }
    }
}
