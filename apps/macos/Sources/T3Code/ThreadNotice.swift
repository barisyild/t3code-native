import Foundation

struct ThreadNotice: Equatable, Sendable {
    struct Target: Hashable, Sendable {
        let environmentID: String
        let threadID: String
    }

    enum Kind: Equatable, Sendable {
        case completed, approval, input, guest, failed, limited

        var title: String {
            switch self {
            case .completed: "Thread completed"
            case .approval: "Approval needed"
            case .input: "Input needed"
            case .guest: "Guest request"
            case .failed: "Thread failed"
            case .limited: "Usage limit reached"
            }
        }
    }

    let target: Target
    let title: String
    let kind: Kind
}

struct ThreadNoticeTracker {
    enum Change: Equatable {
        case present(ThreadNotice)
        case dismiss(ThreadNotice.Target)
    }

    private struct Attention: Equatable {
        let kind: ThreadNotice.Kind
        let id: String?

        init?(_ thread: ThreadSummary) {
            if let request = thread.pendingRequest["kind"].string, request != "auth_refresh" {
                kind = request == "user_input" ? .input : .approval
                id = thread.pendingRequest["id"].string ?? thread.latestRunID
            } else if thread.pendingGuestMessageCount > 0 {
                kind = .guest
                id = nil
            } else if thread.status == "failed" && !thread.isWorking {
                kind = thread.lastErrorClass == "usage_limit" ? .limited : .failed
                id = thread.latestRunID
            } else {
                return nil
            }
        }
    }

    private struct Observation {
        let attention: Attention?
        let seenCompletion: Date
    }

    private var observations: [String: Observation] = [:]

    mutating func receive(_ update: Workspace.ThreadShellChange, environmentID: String, data: WorkspaceData) -> [Change] {
        let ids: Set<String>
        switch update {
        case .snapshot: ids = Set(data.threads.keys).union(observations.keys)
        case .threads(let updated): ids = updated
        }
        return ids.compactMap { id in
            let target = ThreadNotice.Target(environmentID: environmentID, threadID: id)
            guard let thread = data.threads[id], !thread.archived else {
                return observations.removeValue(forKey: id) == nil ? nil : .dismiss(target)
            }
            let listed = data.isListed(thread)
            let attention = thread.isProviderNativeSubagent && !listed ? nil : Attention(thread)
            let completion = attention == nil && thread.status == "completed" && !thread.isActive
                ? WorkspaceStyle.date(thread.latestRunCompletedAt) : nil
            let prior = observations[id]
            let previousCompletion = prior?.seenCompletion ?? .distantPast
            observations[id] = Observation(attention: attention, seenCompletion: max(previousCompletion, completion ?? .distantPast))
            guard let prior else { return nil }
            if let attention, attention != prior.attention {
                return .present(.init(target: target, title: thread.title, kind: attention.kind))
            }
            if let completion, listed, !thread.stopRequested, completion > previousCompletion {
                return .present(.init(target: target, title: thread.title, kind: .completed))
            }
            return prior.attention != nil && attention == nil ? .dismiss(target) : nil
        }
    }
}
