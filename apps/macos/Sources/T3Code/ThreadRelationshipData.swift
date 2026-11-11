import Foundation

struct RelatedThreadTarget: Equatable, Hashable, Sendable {
    let threadID: String
    var environmentID: String?
}

struct DelegatedThreadLink: Equatable, Sendable {
    let target: RelatedThreadTarget
    let title: String?
    let label: String?

    init?(_ value: Wire, fallbackLabel: String? = nil) {
        guard let threadID = value["threadId"].string, let environmentID = value["environmentId"].string,
              !threadID.isEmpty, !environmentID.isEmpty else { return nil }
        target = .init(threadID: threadID, environmentID: environmentID)
        title = value["title"].string
        label = value["label"].string ?? fallbackLabel
    }
}

struct ThreadSubagent: Equatable, Sendable {
    let id: String
    let ownerID: String
    let runID: String?
    let childID: String?
    let remoteChild: DelegatedThreadLink?
    let providerID: String?
    let model: String?
    let title: String?
    let status: String
    let prompt: String
    let progress: String?
    let result: String?
    let updatedAt: String
    let native: Bool
    let driver: String?
    let nativeTaskID: String?
    let nativeTaskStrength: String?
    let workflowName: String?
    let workflowScript: String?

    init?(_ value: Wire, previous: Self? = nil) {
        guard let id = value["id"].string, let ownerID = value["threadId"].string, let status = value["status"].string else { return nil }
        self.id = id
        self.ownerID = ownerID
        self.status = status
        runID = value["runId"].string
        childID = value["childThreadId"].string
        remoteChild = DelegatedThreadLink(value["remoteChild"])
        providerID = value["providerInstanceId"].string
        model = value["modelSelection"]["model"].string ?? value["model"].string
        title = value["title"].string
        prompt = value["promptOmitted"].bool == true ? previous?.prompt ?? "" : value["prompt"].string ?? ""
        result = value["resultOmitted"].bool == true ? previous?.result : value["result"].string
        progress = value["progress"].string
        updatedAt = value["updatedAt"].string ?? ""
        native = value["origin"].string == "provider_native"
        driver = value["driver"].string
        nativeTaskID = value["nativeTaskRef"]["nativeId"].string
        nativeTaskStrength = value["nativeTaskRef"]["strength"].string
        workflowName = value["workflow"].object.map { $0["name"]?.string ?? "Workflow" }
        workflowScript = value["workflow"]["runHandles"]["scriptPath"].string
    }

    var isActive: Bool { ["pending", "running", "waiting"].contains(status) }
    var hasFinished: Bool { ["completed", "failed", "cancelled", "interrupted", "rolled_back"].contains(status) }
    var canStopTask: Bool {
        if !native { return runID != nil || childID != nil }
        return driver == "claudeAgent" && runID != nil && nativeTaskID?.isEmpty == false && nativeTaskStrength == "strong"
    }
    var canStopWorkflow: Bool {
        native && driver == "claudeAgent" && workflowName != nil && nativeTaskID?.isEmpty == false && status == "running"
    }
}

struct ThreadContextTransfer: Equatable, Sendable {
    let id: String
    let sourceID: String
    let targetID: String
    let kind: String
    let status: String

    init?(_ value: Wire) {
        guard let id = value["id"].string, let sourceID = value["sourceThreadId"].string,
              let targetID = value["targetThreadId"].string, let kind = value["type"].string,
              let status = value["status"].string else { return nil }
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.status = status
    }
}

struct ThreadRelationshipProjection: Equatable, Sendable {
    private(set) var subagents: [String: ThreadSubagent] = [:]
    private(set) var transfers: [String: ThreadContextTransfer] = [:]

    mutating func load(_ projection: Wire) {
        self = .init()
        for agent in projection["subagents"].array { apply("subagent.updated", agent) }
        for transfer in projection["contextTransfers"].array { apply("context-transfer.created", transfer) }
    }

    mutating func apply(_ type: String?, _ value: Wire) {
        guard let id = value["id"].string else { return }
        switch type {
        case "subagent.updated": subagents[id] = ThreadSubagent(value, previous: subagents[id])
        case "context-transfer.created", "context-transfer.updated": transfers[id] = ThreadContextTransfer(value)
        default: break
        }
    }
}

struct ThreadMergeRuns {
    private struct Run {
        let id: String
        let ordinal: Int
        let status: String
    }

    private var runs: [String: Run] = [:]

    var latestFinishedID: String? {
        guard let finished = runs.values.filter({ $0.status == "waiting" || $0.status == "completed" })
            .max(by: { $0.ordinal < $1.ordinal }),
              !runs.values.contains(where: { $0.ordinal > finished.ordinal && ["preparing", "starting", "running"].contains($0.status) }) else {
            return nil
        }
        return finished.id
    }

    mutating func apply(_ value: Wire) {
        guard let id = value["id"].string, let ordinal = value["ordinal"].int, let status = value["status"].string else { return }
        runs[id] = Run(id: id, ordinal: ordinal, status: status)
    }
}

struct ThreadRelationshipRow: Equatable {
    enum Kind: Int, CaseIterable {
        case parent, fork, transfer, activeAgent, previousAgent, sideChat

        var symbol: String {
            switch self {
            case .parent: "arrow.turn.up.left"
            case .fork: "arrow.triangle.branch"
            case .transfer: "arrow.turn.down.left"
            case .activeAgent, .previousAgent: "cpu"
            case .sideChat: "bubble.left.and.bubble.right"
            }
        }
    }

    let kind: Kind
    let target: RelatedThreadTarget?
    let title: String
    let detail: String?
    let status: String?
    let updatedAt: String
    let subagent: ThreadSubagent?

    var isWorking: Bool { subagent?.isActive == true || status.map(ThreadSummary.working.contains) == true }
}

enum ThreadRelationships {
    static func rows(for current: ThreadSummary, threads: [String: ThreadSummary],
                     projection: ThreadRelationshipProjection, missingTitles: [String: String] = [:],
                     unavailable: Set<String> = []) -> [ThreadRelationshipRow] {
        var seen = Set<RelatedThreadTarget>()
        var rows: [ThreadRelationshipRow] = []

        func append(_ kind: ThreadRelationshipRow.Kind, target: RelatedThreadTarget?, name: String?,
                    detail: String?, status: String?, agent: ThreadSubagent? = nil) {
            let target = target.flatMap {
                $0.environmentID == nil && threads[$0.threadID] == nil && unavailable.contains($0.threadID) ? nil : $0
            }
            if target == nil && agent == nil { return }
            if let target {
                guard target.environmentID != nil || target.threadID != current.id,
                      seen.insert(target).inserted else { return }
            }
            let local = target.flatMap { $0.environmentID == nil ? threads[$0.threadID] : nil }
            let title = agent?.workflowName ?? local?.title ?? name ??
                target.flatMap { $0.environmentID == nil ? missingTitles[$0.threadID] : nil } ?? (agent == nil ? "Conversation" : "Subagent")
            let resolvedStatus = local?.archived == true ? "archived" : local?.needsInput == true ? "needs input" : status ?? local?.status
            rows.append(.init(kind: kind, target: target, title: title, detail: detail, status: resolvedStatus,
                              updatedAt: local?.createdAt ?? agent?.updatedAt ?? "", subagent: agent))
        }

        if let remote = current.delegatedFrom {
            append(.parent, target: remote.target, name: remote.title, detail: remote.label ?? "Linked environment", status: nil)
        }
        if let id = current.relationshipParentID {
            append(.parent, target: .init(threadID: id), name: nil,
                   detail: current.relationshipToParent == "fork" ? "Fork source" : "Parent conversation", status: nil)
        }

        for agent in projection.subagents.values.sorted(by: { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }) where agent.ownerID == current.id {
            let target = agent.remoteChild?.target ?? agent.childID.map { RelatedThreadTarget(threadID: $0) }
            let child = agent.childID.flatMap { threads[$0] }
            let status = child?.isWorking == true || (child?.latestRunID != nil && !agent.isActive) ? child?.status ?? agent.status : agent.status
            let working = agent.isActive || child?.isActive == true
            let kind: ThreadRelationshipRow.Kind = working || !agent.hasFinished ? .activeAgent : .previousAgent
            let promptTitle = agent.prompt.split(whereSeparator: \.isNewline).first.map { String($0.prefix(90)) }
            append(kind, target: target, name: agent.remoteChild?.title ?? agent.title ?? promptTitle,
                   detail: agent.remoteChild?.label, status: status, agent: agent)
        }

        for child in threads.values where child.relationshipParentID == current.id {
            let kind: ThreadRelationshipRow.Kind = child.isSideChat ? .sideChat : child.relationshipToParent == "subagent" ?
                (child.isActive ? .activeAgent : .previousAgent) : .fork
            append(kind, target: .init(threadID: child.id), name: nil, detail: kind == .fork ? "Fork" : nil, status: nil)
        }
        for transfer in projection.transfers.values.sorted(by: { $0.id < $1.id }) {
            let id: String
            if transfer.sourceID == current.id { id = transfer.targetID }
            else if transfer.targetID == current.id { id = transfer.sourceID }
            else { continue }
            append(.transfer, target: .init(threadID: id), name: nil, detail: "Shared context", status: nil)
        }
        return rows.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.updatedAt, $0.target?.threadID ?? $0.subagent?.id ?? "") >
                ($1.updatedAt, $1.target?.threadID ?? $1.subagent?.id ?? "")
        }
    }
}
