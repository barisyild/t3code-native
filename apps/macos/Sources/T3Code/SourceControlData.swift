import Foundation

enum WorkspaceCheckout: Equatable {
    case root(branch: String? = nil)
    case newWorktree(base: String)
    case worktree(path: String, branch: String?)

    var branch: String? {
        switch self {
        case .root(let branch), .worktree(_, let branch): branch
        case .newWorktree(let base): base
        }
    }

    var path: String? {
        if case .worktree(let path, _) = self { return path }
        return nil
    }

    var strategy: Wire {
        var fields: Payload
        switch self {
        case .root: fields = ["type": .string("root")]
        case .newWorktree(let base): return .object(["type": .string("worktree"), "baseRef": .string(base)])
        case .worktree(let path, _): fields = ["type": .string("existing_worktree"), "worktreePath": .string(path)]
        }
        if let branch { fields["branch"] = .string(branch) }
        return .object(fields)
    }
}

struct RepositoryRef: Equatable {
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let isDefault: Bool
    let worktreePath: String?

    init?(_ wire: Wire) {
        guard let name = wire["name"].string else { return nil }
        self.name = name
        isRemote = wire["isRemote"].bool == true
        isCurrent = wire["current"].bool == true
        isDefault = wire["isDefault"].bool == true
        worktreePath = wire["worktreePath"].string
    }

    func checkout(projectRoot: String, activeWorktree: String?) -> WorkspaceCheckout {
        if let worktreePath {
            // A project can point to a subdirectory of its main checkout.
            let root = projectRoot.replacingOccurrences(of: "\\", with: "/")
            let checkout = worktreePath.replacingOccurrences(of: "\\", with: "/")
            let prefix = checkout.hasSuffix("/") ? checkout : checkout + "/"
            if root == checkout || root.hasPrefix(prefix) { return .root(branch: name) }
            return .worktree(path: worktreePath, branch: name)
        }
        if let activeWorktree, !isDefault { return .worktree(path: activeWorktree, branch: name) }
        return .root(branch: name)
    }
}

struct RepositoryStatus: Equatable {
    struct File: Equatable {
        let path: String
        let insertions: Int
        let deletions: Int

        init?(_ wire: Wire) {
            guard let path = wire["path"].string else { return nil }
            self.path = path
            insertions = wire["insertions"].int ?? 0
            deletions = wire["deletions"].int ?? 0
        }
    }

    private var local: Wire = .null
    private var remote: Wire = .null

    var isLoaded: Bool { local != .null }
    var isRepo: Bool { local["isRepo"].bool == true }
    var branch: String? { local["refName"].string }
    var defaultRef: Bool { local["isDefaultRef"].bool == true }
    var hasChanges: Bool { local["hasWorkingTreeChanges"].bool == true }
    var files: [File] { local["workingTree"]["files"].array.compactMap(File.init) }
    var hasRemoteStatus: Bool { remote != .null }
    var hasUpstream: Bool { remote["hasUpstream"].bool == true }
    var canPush: Bool { hasUpstream || local["hasPrimaryRemote"].bool == true }
    var ahead: Int { remote["aheadCount"].int ?? 0 }
    var behind: Int { remote["behindCount"].int ?? 0 }
    var aheadOfDefault: Int { remote["aheadOfDefaultCount"].int ?? ahead }
    var pullRequest: Wire { remote["pr"] }
    var hasChangeRequestProvider: Bool {
        guard let kind = local["sourceControlProvider"]["kind"].string else { return false }
        return kind != "unknown"
    }
    var changeRequestName: String {
        local["sourceControlProvider"]["kind"].string == "gitlab" ? "Merge Request" : "Pull Request"
    }

    mutating func apply(_ event: Wire) {
        switch event["_tag"].string {
        case "snapshot":
            local = event["local"]
            remote = event["remote"]
        case "localUpdated":
            let next = event["local"]
            if next["refName"] != local["refName"] || next["isRepo"] != local["isRepo"] { remote = .null }
            local = next
        case "remoteUpdated": remote = event["remote"]
        default: break
        }
    }
}

enum RepositoryAction: String, CaseIterable {
    case commit
    case push
    case createRequest = "create_pr"
    case commitPush = "commit_push"
    case commitPushRequest = "commit_push_pr"

    var commits: Bool { self == .commit || self == .commitPush || self == .commitPushRequest }
    var createsRequest: Bool { self == .createRequest || self == .commitPushRequest }

    func title(_ requestName: String) -> String {
        switch self {
        case .commit: "Commit"
        case .push: "Push"
        case .createRequest: "Create \(requestName)"
        case .commitPush: "Commit and Push"
        case .commitPushRequest: "Commit, Push and Create \(requestName)"
        }
    }

    func isAvailable(status: RepositoryStatus, hasSelectedFiles: Bool) -> Bool {
        guard status.isRepo else { return false }
        if commits && (!status.hasChanges || !hasSelectedFiles) { return false }
        if self == .commit { return true }
        guard status.hasRemoteStatus, status.branch != nil, status.canPush, status.behind == 0 else { return false }
        if createsRequest && (!status.hasChangeRequestProvider || status.pullRequest["state"].string == "open") { return false }
        if self == .createRequest { return !status.defaultRef && status.aheadOfDefault > 0 }
        if self == .push { return status.ahead > 0 }
        return true
    }
}

struct RepositoryRequestReference {
    let value: String

    init?(_ input: String) {
        var reference = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = reference.split(whereSeparator: \.isWhitespace)
        let command = words.prefix(3).joined(separator: " ").lowercased()
        let checkoutCommands = ["gh pr checkout", "glab mr checkout", "tea pr checkout", "tea pulls checkout", "origin pr checkout"]
        if checkoutCommands.contains(command) {
            guard words.count == 4 else { return nil }
            reference = String(words[3])
        } else if words.prefix(4).joined(separator: " ").lowercased() == "az repos pr checkout" {
            let arguments = words.dropFirst(4)
            if let id = arguments.first(where: { $0.hasPrefix("--id=") }) {
                reference = String(id.dropFirst("--id=".count))
            } else if let flag = arguments.firstIndex(of: "--id"), flag + 1 < words.count {
                reference = String(words[flag + 1])
            } else { return nil }
        }
        let digits = reference.hasPrefix("#") ? String(reference.dropFirst()) : reference
        if let number = Int(digits), number > 0, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
            value = String(number)
        } else if Self.webURL(reference) != nil { value = reference }
        else { return nil }
    }

    static func webURL(_ reference: String) -> URL? {
        guard let components = URLComponents(string: reference),
              let scheme = components.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}
