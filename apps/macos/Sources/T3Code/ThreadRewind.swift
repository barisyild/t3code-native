import Foundation

enum ThreadRewind {
    static let terminalStatuses: Set<String> = ["completed", "interrupted", "failed", "cancelled"]

    struct Plan: Equatable, Sendable {
        let threadID: String
        let entryID: String
        let providerThreadID: String
        let providerInstanceID: String
        let initialProviderThreadIDs: Set<String>
        let checkpointID: String
        let scopeID: String
        let turnCount: Int
        let witnessRunID: String
        let text: String
        let attachments: [Wire]
        let contextRecords: [Wire]
        let canRestoreFiles: Bool
    }

    static func prepare(_ projection: Wire, message: TimelineEntry) throws -> Plan {
        let thread = projection["thread"]
        guard let threadID = thread["id"].string, message.isLocal, message.sourceThreadID == threadID,
              message.canRewind, let runID = message.value["runId"].string,
              thread["archivedAt"] == .null, thread["deletedAt"] == .null else {
            throw ClientError.message("This message is no longer available to edit.")
        }
        let runs = projection["runs"].array
        guard !runs.contains(where: { ThreadSummary.working.contains($0["status"].string ?? "") && $0["status"].string != "queued" }),
              !projection["runtimeRequests"].array.contains(where: { $0["status"].string == "pending" }) else {
            throw ClientError.message("Stop the current turn before editing an earlier message.")
        }
        let providers = projection["providerThreads"].array
        guard let providerID = thread["activeProviderThreadId"].string,
              let provider = providers.first(where: { $0["id"].string == providerID }),
              let instanceID = provider["providerInstanceId"].string,
              let sessionID = provider["providerSessionId"].string,
              projection["providerSessions"].array.contains(where: {
                  $0["id"].string == sessionID && $0["capabilities"]["checkpointing"]["providerCanRollbackConversation"].bool == true
              }) else { throw ClientError.message("This provider does not support rewinding this conversation.") }
        let source = projection["visibleTurnItems"].array.compactMap(TimelineEntry.init(row:))
        guard source.contains(where: { $0.id == message.id && $0.isLocal && $0.value["messageId"] == message.value["messageId"] }) else {
            throw ClientError.message("The conversation changed. Choose the message again.")
        }
        var seen = Set<String>()
        let orderedRuns = source.filter { $0.isLocal && ($0.isMessage || $0.type == "notification") }.compactMap {
            $0.value["runId"].string
        }.filter { seen.insert($0).inserted }
        guard let index = orderedRuns.firstIndex(of: runID),
              let sourceRun = runs.first(where: { $0["id"].string == runID }),
              terminalStatuses.contains(sourceRun["status"].string ?? "") else {
            throw ClientError.message("Wait for this turn to finish before editing it.")
        }
        let previous = index > 0 ? runs.first { $0["id"].string == orderedRuns[index - 1] } : nil
        let turnCount: Int
        if index == 0 { turnCount = 0 }
        else if let ordinal = previous?["ordinal"].int { turnCount = ordinal }
        else { throw ClientError.message("The checkpoint before this message is unavailable.") }
        let scopes = projection["checkpointScopes"].array.filter {
            $0["threadId"].string == threadID && $0["kind"].string == "root_run" &&
                $0["parentScopeId"] == .null && $0["advancesAppRunCount"].bool != false
        }
        let checkpoint = projection["checkpoints"].array.last { checkpoint in
            checkpoint["status"].string == "ready" &&
                scopes.contains(where: { $0["id"] == checkpoint["scopeId"] }) &&
                (turnCount == 0 ? checkpoint["ordinalWithinScope"].int == 0 && checkpoint["appRunOrdinal"] == .null :
                    checkpoint["appRunOrdinal"].int == turnCount)
        }
        guard let checkpoint, let checkpointID = checkpoint["id"].string, let scopeID = checkpoint["scopeId"].string else {
            throw ClientError.message("The checkpoint before this message is unavailable.")
        }
        if let previous, previous["providerThreadId"].string != providerID {
            throw ClientError.message("The earlier checkpoint belongs to a different provider conversation.")
        }
        guard let witness = runs.filter({
            ($0["ordinal"].int ?? 0) > turnCount && terminalStatuses.contains($0["status"].string ?? "")
        }).max(by: { ($0["ordinal"].int ?? 0) < ($1["ordinal"].int ?? 0) }), let witnessID = witness["id"].string else {
            throw ClientError.message("The conversation changed. Choose the message again.")
        }
        let original = projection["messages"].array.first { $0["id"] == message.value["messageId"] }
        let attachments = original?["attachments"].array ?? message.value["attachments"].array
        let context = original?["context"] ?? message.value["context"]
        let text = GuestAttribution(context)?.text ?? original?["text"].string ?? message.value["text"].string ?? ""
        guard attachments.allSatisfy({ $0["id"].string != nil }) else { throw ClientError.invalidResponse }
        return Plan(threadID: threadID, entryID: message.id, providerThreadID: providerID, providerInstanceID: instanceID,
                    initialProviderThreadIDs: Set(providers.compactMap { $0["id"].string }), checkpointID: checkpointID,
                    scopeID: scopeID, turnCount: turnCount, witnessRunID: witnessID,
                    text: QueuedMessage.recallableText(BrowserAnnotationContext.removingReferences(from: text, context: context)),
                    attachments: attachments,
                    contextRecords: BrowserAnnotationContext.linkedRecords(in: context, attachments: attachments) +
                        TerminalContext.referencedRecords(in: text, records: context["records"].array),
                    canRestoreFiles: thread["worktreePath"].string != nil)
    }

    struct State: Sendable {
        private var rolledBackRuns: Set<String> = []
        private var providers: [String: Wire] = [:]
        private var checkpoints: [String: Int] = [:]
        private var failure: Wire = .null

        var checkpointCount: Int { checkpoints.values.max() ?? 0 }
        var hasRolledBackRuns: Bool { !rolledBackRuns.isEmpty }
        func rolledBack(_ id: String) -> Bool { rolledBackRuns.contains(id) }

        mutating func load(_ projection: Wire) {
            self = .init()
            failure = projection["thread"]["rollbackFailure"]
            for run in projection["runs"].array { apply("run.updated", run) }
            for provider in projection["providerThreads"].array { apply("provider-thread.updated", provider) }
            for checkpoint in projection["checkpoints"].array { apply("checkpoint.captured", checkpoint) }
        }

        mutating func apply(_ type: String?, _ value: Wire) {
            switch type {
            case "run.created", "run.updated":
                if let id = value["id"].string, let status = value["status"].string {
                    if status == "rolled_back" { rolledBackRuns.insert(id) }
                    else { rolledBackRuns.remove(id) }
                }
            case "provider-thread.updated":
                if let id = value["id"].string { providers[id] = value }
            case "checkpoint.captured":
                if let id = value["id"].string {
                    checkpoints[id] = value["status"].string == "ready" ? value["appRunOrdinal"].int : nil
                }
            default:
                if type?.hasPrefix("thread.") == true, let object = value.object, object["rollbackFailure"] != nil {
                    failure = value["rollbackFailure"]
                }
            }
        }

        func outcome(for plan: Plan, requestID: String) -> Result<Void, ClientError>? {
            if failure["requestId"].string == requestID {
                return .failure(.message(failure["message"].string ?? "The conversation could not be rewound."))
            }
            guard rolledBack(plan.witnessRunID), providers.values.contains(where: { provider in
                let id = provider["id"].string ?? ""
                let matches = id == plan.providerThreadID ||
                    (plan.turnCount == 0 && !plan.initialProviderThreadIDs.contains(id) &&
                     provider["appThreadId"].string == plan.threadID && provider["ownerNodeId"] == .null &&
                     provider["providerInstanceId"].string == plan.providerInstanceID)
                return matches && (plan.turnCount == 0 ? provider["lastRunOrdinal"] == .null :
                    provider["lastRunOrdinal"].int == plan.turnCount)
            }) else { return nil }
            return .success(())
        }
    }
}
