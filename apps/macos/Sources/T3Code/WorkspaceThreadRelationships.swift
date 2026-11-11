import Foundation

struct ThreadRelationshipScope: Equatable {
    let threadID: String
    let connection: UUID
}

struct RelatedThreadFamily {
    let sequence: Int
    let threads: [String: ThreadSummary]
}

extension Workspace {
    var threadRelationshipScope: ThreadRelationshipScope? {
        guard can("orchestration:read"), let thread = selectedThread, let connectionID else { return nil }
        return .init(threadID: thread.id, connection: connectionID)
    }

    var relationshipThreads: [String: ThreadSummary] {
        data.threads.merging(data.archived) { live, _ in live }
    }

    func relatedThreadFamily(_ scope: ThreadRelationshipScope) async throws -> RelatedThreadFamily {
        guard threadRelationshipScope == scope, supportsThreadFamilies else { throw ClientError.disconnected }
        let result = try await request("orchestration.getThreadFamily", ["threadId": .string(scope.threadID)])
        guard threadRelationshipScope == scope else { throw ClientError.disconnected }
        guard let sequence = result["snapshotSequence"].int else { throw ClientError.invalidResponse }
        let threads = Dictionary(result["threads"].array.filter { $0["deletedAt"] == .null }.compactMap { ThreadSummary($0) }
            .map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return .init(sequence: sequence, threads: threads)
    }

    func relatedThreadTitles(_ ids: Set<String>, scope: ThreadRelationshipScope) async throws -> [String: String] {
        guard threadRelationshipScope == scope else { throw ClientError.disconnected }
        let result = try await request("orchestration.getThreadTitles", ["threadIds": .array(ids.sorted().map(Wire.string))])
        guard threadRelationshipScope == scope else { throw ClientError.disconnected }
        guard let titles = result.object else { throw ClientError.invalidResponse }
        return titles.compactMapValues(\.string)
    }

    var canReadNativeChildWork: Bool {
        guard let thread = selectedThread, thread.isProviderNativeSubagent, let instance = thread.model["instanceId"].string else { return false }
        return (providers.first { $0.id == instance }?.driver ?? instance) == "antigravity"
    }

    func nativeChildWork(_ scope: ThreadRelationshipScope) async throws -> [NativeSubagentWork] {
        guard threadRelationshipScope == scope, canReadNativeChildWork else { throw ClientError.disconnected }
        let result = try await request("orchestration.getNativeChildWork", ["threadId": .string(scope.threadID)])
        guard threadRelationshipScope == scope else { throw ClientError.disconnected }
        return result["children"].array.compactMap(NativeSubagentWork.init)
    }

    func workflowScript(_ id: String, scope: ThreadRelationshipScope) async throws -> (contents: String, truncated: Bool) {
        guard threadRelationshipScope == scope, let path = detail.relationships.subagents[id]?.workflowScript else { throw ClientError.disconnected }
        let result = try await request("orchestration.getWorkflowScript", ["scriptPath": .string(path)])
        guard threadRelationshipScope == scope else { throw ClientError.disconnected }
        guard let contents = result["contents"].string else { throw ClientError.invalidResponse }
        return (contents, result["truncated"].bool == true)
    }

    func stopRelatedSubagent(_ id: String, scope: ThreadRelationshipScope) async throws {
        guard threadRelationshipScope == scope, can("orchestration:operate"),
              let agent = detail.relationships.subagents[id], agent.ownerID == scope.threadID,
              agent.canStopTask || agent.canStopWorkflow,
              agent.isActive || agent.childID.flatMap({ data.threads[$0]?.isWorking }) == true else {
            throw ClientError.disconnected
        }
        if agent.canStopWorkflow {
            _ = try await request("orchestration.stopWorkflow", ["threadId": .string(scope.threadID), "subagentId": .string(id)])
        } else if !agent.native, let childID = agent.childID {
            if let runID = agent.runID {
                try? await dispatch("subagent.stop", threadId: scope.threadID, ["runId": .string(runID), "subagentId": .string(id)])
            }
            guard connectionID == scope.connection, data.threads[childID]?.parentThreadID == scope.threadID else {
                throw ClientError.disconnected
            }
            try await dispatch("thread.stop", threadId: childID)
        } else if let runID = agent.runID {
            try await dispatch("subagent.stop", threadId: scope.threadID, ["runId": .string(runID), "subagentId": .string(id)])
        } else {
            throw ClientError.message("This subagent has no active run.")
        }
        guard connectionID == scope.connection else { throw ClientError.disconnected }
    }

    func detachRelatedSessions(_ scope: ThreadRelationshipScope) async throws {
        guard threadRelationshipScope == scope, can("orchestration:operate") else { throw ClientError.disconnected }
        for id in detail.queue.attachedSessionIDs {
            guard connectionID == scope.connection, can("orchestration:operate") else { throw ClientError.disconnected }
            try await dispatch("provider-session.detach", threadId: scope.threadID, [
                "providerSessionId": .string(id), "reason": .string("client-requested"),
            ])
        }
    }

    func forkMergeBackBlockedReason(_ targetID: String) -> String? {
        guard can("orchestration:operate"), let thread = selectedThread, thread.mergeBackTargetID == targetID,
              !thread.isSideChat else { return "This conversation cannot merge back." }
        if data.threads[targetID]?.isWorking == true || sending.contains(.thread(targetID)) {
            return "Available when the source conversation is idle."
        }
        if detail.mergeBackRunID == nil { return "Available after a finished reply." }
        return nil
    }

    func mergeForkBack(_ targetID: String, scope: ThreadRelationshipScope) async throws {
        guard threadRelationshipScope == scope, forkMergeBackBlockedReason(targetID) == nil,
              let runID = detail.mergeBackRunID else { throw ClientError.disconnected }
        try await dispatchMergeBack(sourceID: scope.threadID, targetID: targetID, runID: runID, connection: scope.connection)
    }

    func dispatchMergeBack(sourceID: String, targetID: String, runID: String, connection: UUID) async throws {
        guard connectionID == connection, can("orchestration:operate") else { throw ClientError.disconnected }
        _ = try await request("orchestration.dispatchCommand", [
            "type": .string("thread.merge_back"), "commandId": .string(UUID().uuidString),
            "sourceThreadId": .string(sourceID), "targetThreadId": .string(targetID),
            "sourcePoint": .object(["type": .string("run"), "runId": .string(runID)]),
            "createdBy": .string("user"), "creationSource": .string("web"),
        ])
        guard connectionID == connection else { throw ClientError.disconnected }
    }
}
