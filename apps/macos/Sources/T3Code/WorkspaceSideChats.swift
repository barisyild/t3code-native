import Foundation

extension Workspace {
    var sideChatThread: ThreadSummary? { sideChat.flatMap { data.threads[$0.threadID] } }

    func checkoutPath(_ thread: ThreadSummary) -> String? {
        guard cloneStatus(thread.projectId)?.blocksCheckout != true else { return nil }
        return thread.worktreePath ?? data.projects[thread.projectId]?.root
    }

    var sideChatBlockedReason: String? {
        guard connectionID != nil else { return "Reconnect to the environment to open a side chat." }
        guard supportsSideChats else { return "Update this environment’s T3 Code server to use side chats." }
        guard let parent = selectedThread else { return "Side chats start after the first message." }
        guard !parent.isSideChat, !parent.isSubagent else { return "Side chats start from a main conversation." }
        guard !parent.archived, can("orchestration:operate") else { return "This conversation is read-only." }
        return nil
    }

    var sideChatParent: SideChatParent? {
        guard sideChatBlockedReason == nil, let environment, let connectionID, let selectedThread else { return nil }
        return .init(environmentID: environment.id, connection: connectionID, threadID: selectedThread.id)
    }

    func sideChatReference(to threadID: String) -> SideChatReference? {
        guard let environment, let thread = data.threads[threadID], thread.isSideChat,
              let parent = thread.parentThreadID else { return nil }
        return .init(environmentID: environment.id, parentID: parent, threadID: threadID)
    }

    func startSideChat(parent: SideChatParent, prompt: String, model: Wire, runtimeMode: String?) async throws -> SideChatReference {
        guard sideChatParent == parent else { throw ClientError.disconnected }
        let reference = parent.child(UUID().uuidString)
        do {
            _ = try await request("orchestration.dispatchCommand", [
                "type": .string("thread.fork"), "commandId": .string(UUID().uuidString),
                "sourceThreadId": .string(parent.threadID), "targetThreadId": .string(reference.threadID),
                "sourcePoint": .object(["type": .string("latest_stable")]), "title": .string("Side chat"),
                "sideChat": .bool(true), "createdBy": .string("user"), "creationSource": .string("web"),
            ])
            let child = try await awaitSideChatShell(reference, connection: parent.connection)
            if let runtimeMode, runtimeMode != child.runtimeMode {
                try await dispatch("thread.runtime-mode.set", threadId: child.id, ["runtimeMode": .string(runtimeMode)])
            }
            try Task.checkCancellation()
            guard connectionID == parent.connection else { throw ClientError.disconnected }
            if !prompt.isEmpty {
                try await send(.init(destination: .thread(child.id), text: prompt, model: model == .null ? child.model : model,
                                     runtimeMode: runtimeMode ?? child.runtimeMode ?? "approval-required", interactionMode: "default",
                                     checkout: nil, preparedThreadID: nil))
            }
            return reference
        } catch {
            if connectionID == parent.connection, can("orchestration:operate") {
                try? await dispatch("thread.delete", threadId: reference.threadID, ["onlyIfUnused": .bool(true)])
            }
            throw error
        }
    }

    var bringBackBlockedReason: String? {
        guard let reference = sideChat, selectedThread?.id == reference.parentID,
              selectedThread?.archived == false, can("orchestration:operate") else { return "This conversation is read-only." }
        if selectedThread?.isWorking == true || detail.queue.hasQueuedRuns || sending.contains(.thread(reference.parentID)) {
            return "Available when the main conversation is idle and its queue is empty."
        }
        if detail.pendingMergeBacks.values.contains(where: { $0.sourceID != reference.threadID }) {
            return "Send a message in the main conversation to use its pending context first."
        }
        if sideChatDetail.mergeBackRunID == nil { return "Available after a finished reply." }
        return nil
    }

    func bringBackSideChat(_ reference: SideChatReference, connection: UUID) async throws {
        guard sideChat == reference, connectionID == connection,
              bringBackBlockedReason == nil, let runID = sideChatDetail.mergeBackRunID else {
            throw ClientError.message(bringBackBlockedReason ?? "The side chat is no longer open.")
        }
        try await dispatchMergeBack(sourceID: reference.threadID, targetID: reference.parentID, runID: runID, connection: connection)
    }

    func removeSideChat(_ reference: SideChatReference, connection: UUID, onlyIfUnused: Bool) async throws {
        guard connectionID == connection, can("orchestration:operate"),
              sideChatReference(to: reference.threadID) == reference else { throw ClientError.disconnected }
        try await dispatch("thread.delete", threadId: reference.threadID,
                           onlyIfUnused ? ["onlyIfUnused": .bool(true)] : [:])
        guard connectionID == connection else { throw ClientError.disconnected }
    }
}
