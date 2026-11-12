import Foundation

struct QueuedMessage: Equatable {
    let id: String
    let text: String
    let attachments: [Wire]
    let context: Wire
    let guestName: String?
    let editable: Bool
    let freshContext: Bool

    init?(run: Wire, message: Wire) {
        guard let id = run["id"].string, let text = message["text"].string,
              message["notification"] == .null, message["delegatedCompletion"] == .null else { return nil }
        self.id = id
        let guest = message["context"]["guest"]
        self.text = guest["text"].string ?? text
        guestName = guest["name"].string
        attachments = message["attachments"].array
        context = message["context"]
        editable = guest == .null
        freshContext = run["freshContext"].bool == true
    }

    static let attachmentOnlyText =
        "[User attached one or more files without additional text. Respond using the conversation context and the attached files.]"

    var displayText: String {
        Self.recallableText(BrowserAnnotationContext.removingReferences(from: text, context: context))
    }

    static func recallableText(_ text: String) -> String {
        if text == Self.attachmentOnlyText { return "" }
        let prefix = "Ultrathink:\n"
        if text.hasPrefix(prefix), text.dropFirst(prefix.count) == Self.attachmentOnlyText { return String(prefix.dropLast()) }
        return text
    }
}

struct ThreadQueue {
    enum Delivery: Equatable { case start, steer(String) }
    enum ModelSwitchDelivery: Equatable { case restart(String), interrupt(String) }

    struct Reorder: Equatable {
        let runID: String
        let beforeRunID: String?
    }

    struct State: Equatable {
        var messages: [QueuedMessage] = []
        var held = false
        var activeRunID: String?
        var canSteer = false
        var skipsCompaction = false

        func delivery(for message: QueuedMessage) -> Delivery? {
            guard let activeRunID else { return .start }
            if canSteer && (!message.freshContext || skipsCompaction) { return .steer(activeRunID) }
            return nil
        }

        func reorder(moving runID: String, to insertionIndex: Int) -> Reorder? {
            guard let source = messages.firstIndex(where: { $0.id == runID }),
                  (0...messages.count).contains(insertionIndex),
                  insertionIndex != source, insertionIndex != source + 1 else { return nil }
            return Reorder(runID: runID, beforeRunID: insertionIndex == messages.count ? nil : messages[insertionIndex].id)
        }
    }

    private var runs: [String: Wire] = [:]
    private var messages: [String: Wire] = [:]
    private var cancelledRuns: Set<String> = []
    private var providerThreads: [String: Wire] = [:]
    private var providerSessions: [String: Wire] = [:]
    private var runningTurns: [String: Wire] = [:]
    private var attemptModels: [String: (runID: String, selection: Wire)] = [:]
    private var threadProviderID: String?

    var hasQueuedRuns: Bool { runs.values.contains { $0["status"].string == "queued" } }
    var needsTimelineFilter: Bool { !cancelledRuns.isEmpty || hasQueuedRuns }
    var attachedSessionIDs: [String] {
        providerSessions.compactMap { id, session in
            let status = session["status"].string
            return status == "stopped" || status == "error" ? nil : id
        }.sorted()
    }

    func hides(_ entry: TimelineEntry) -> Bool {
        guard entry.isLocal, entry.type == "user_message", let run = entry.value["runId"].string else { return false }
        return runs[run]?["status"].string == "queued" ||
            (cancelledRuns.contains(run) && entry.value["inputIntent"].string == "queued_turn")
    }

    var state: State {
        let queued = runs.values.filter { $0["status"].string == "queued" }
        let pending = queued.sorted { lhs, rhs in
            let left = lhs["ordinal"].int ?? 0, right = rhs["ordinal"].int ?? 0
            return (lhs["queuePosition"].int ?? left, left) < (rhs["queuePosition"].int ?? right, right)
        }.compactMap { run in
            QueuedMessage(run: run, message: messages[run["id"].string ?? ""] ?? .null)
        }
        var result = State(messages: pending, held: queued.contains { $0["queueHeld"].bool == true })
        guard let active = runs.values.filter({ $0["status"].string != "queued" }).max(by: {
            ($0["ordinal"].int ?? 0) < ($1["ordinal"].int ?? 0)
        }), let id = active["id"].string else { return result }
        result.activeRunID = id
        let message = messages[id]
        result.skipsCompaction = message?["role"].string == "user" &&
            message?["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/compact" &&
            message?["attachments"].array.isEmpty == true
        let capabilities = session(for: active)?["capabilities"]["turns"]
        let supportsSteer = capabilities?["supportsActiveSteering"].bool == true ||
            capabilities?["supportsSteeringByInterruptRestart"].bool == true
        result.canSteer = result.skipsCompaction || (supportsSteer && hasRunningTurn(active))
        return result
    }

    func modelSwitchDelivery(for runID: String) -> ModelSwitchDelivery? {
        guard let run = runs[runID], hasRunningTurn(run),
              let capabilities = session(for: run)?["capabilities"]["turns"],
              capabilities["supportsInterrupt"].bool == true else { return nil }
        let message = messages[runID]
        if message?["attachments"].array.isEmpty == true,
           let text = message?["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           text == "/compact" || text == "/logout" { return nil }
        return capabilities["supportsSteeringByInterruptRestart"].bool == true ? .restart(runID) : .interrupt(runID)
    }

    func supportsRewind(providerThreadID: String?) -> Bool {
        guard let providerThreadID, let sessionID = providerThreads[providerThreadID]?["providerSessionId"].string,
              let session = providerSessions[sessionID] else { return false }
        return session["capabilities"]["checkpointing"]["providerCanRollbackConversation"].bool == true
    }

    func activeModel(for runID: String?) -> Wire {
        let run = if let runID {
            runs[runID]
        } else {
            runs.values.filter { $0["status"].string != "queued" }.max {
                ($0["ordinal"].int ?? 0) < ($1["ordinal"].int ?? 0)
            }
        }
        guard let run, let id = run["id"].string else { return .null }
        let current = run["activeAttemptId"].string
        let turn = runningTurns.values.filter {
            guard let attempt = $0["runAttemptId"].string else { return false }
            return attempt == current || attemptModels[attempt]?.runID == id
        }.max { left, right in
            let lhs = left["runAttemptId"].string == current ? 1 : 0
            let rhs = right["runAttemptId"].string == current ? 1 : 0
            return (lhs, left["startedAt"].string ?? "", left["ordinal"].int ?? 0) <
                (rhs, right["startedAt"].string ?? "", right["ordinal"].int ?? 0)
        }
        guard let turn, let attempt = turn["runAttemptId"].string else { return run["modelSelection"] }
        let selection = attemptModels[attempt]?.selection ?? (attempt == current ? run["modelSelection"] : .null)
        let providerThread = turn["providerThreadId"].string.flatMap { providerThreads[$0] }
        guard let instance = ComposerModels.instanceID(selection) ?? providerThread?["providerInstanceId"].string else { return .null }
        let model = turn["model"].string ?? selection["model"].string
        return .object(["instanceId": .string(instance), "model": model.map(Wire.string) ?? .null])
    }

    private func hasRunningTurn(_ run: Wire) -> Bool {
        run["status"].string == "running" &&
            run["activeAttemptId"].string.map { hasRunningAttempt($0) } == true
    }

    private func hasRunningAttempt(_ id: String) -> Bool {
        runningTurns.values.contains { $0["runAttemptId"].string == id }
    }

    private mutating func pruneAttempt(_ id: String) {
        guard let attempt = attemptModels[id], runs[attempt.runID]?["activeAttemptId"].string != id,
              !hasRunningAttempt(id) else { return }
        attemptModels.removeValue(forKey: id)
    }

    private func session(for run: Wire) -> Wire? {
        let threadID = run["providerThreadId"].string ?? threadProviderID
        return threadID.flatMap { providerThreads[$0]?["providerSessionId"].string }.flatMap { providerSessions[$0] } ??
            providerSessions.values.filter {
                $0["providerInstanceId"] == run["providerInstanceId"] &&
                $0["status"].string != "stopped" && $0["status"].string != "error"
            }.max { ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "") }
    }

    mutating func load(_ projection: Wire, messageIndex: [String: Wire]) {
        self = .init()
        threadProviderID = projection["thread"]["activeProviderThreadId"].string
        for run in projection["runs"].array { applyRun(run, message: run["userMessageId"].string.flatMap { messageIndex[$0] }) }
        for session in projection["providerSessions"].array { apply("provider-session.updated", session) }
        for thread in projection["providerThreads"].array { apply("provider-thread.updated", thread) }
        for turn in projection["providerTurns"].array { apply("provider-turn.updated", turn) }
        let activeAttemptIDs = Set(runningTurns.values.compactMap { $0["runAttemptId"].string })
        for attempt in projection["attempts"].array {
            guard let id = attempt["id"].string, activeAttemptIDs.contains(id), attemptModels[id] == nil,
                  let runID = attempt["runId"].string, let instance = attempt["providerInstanceId"].string else { continue }
            attemptModels[id] = (runID, .object(["instanceId": .string(instance)]))
        }
    }

    mutating func applyRun(_ run: Wire, message: Wire?) {
        guard let id = run["id"].string, let status = run["status"].string else { return }
        let previousAttempt = runs[id]?["activeAttemptId"].string
        if ThreadSummary.working.contains(status) {
            runs[id] = run
            if let message { messages[id] = message }
            if let attempt = run["activeAttemptId"].string, run["modelSelection"] != .null {
                attemptModels[attempt] = (id, run["modelSelection"])
            }
        } else {
            runs.removeValue(forKey: id)
            messages.removeValue(forKey: id)
        }
        if status == "cancelled" { cancelledRuns.insert(id) }
        else { cancelledRuns.remove(id) }
        if let previousAttempt { pruneAttempt(previousAttempt) }
    }

    mutating func apply(_ type: String?, _ value: Wire) {
        switch type {
        case "message.updated":
            if let run = value["runId"].string, let owner = runs[run], owner["userMessageId"] == value["id"] { messages[run] = value }
        case "provider-session.attached", "provider-session.updated":
            if let id = value["id"].string { providerSessions[id] = value }
        case "provider-session.detached":
            if let id = value["providerSessionId"].string { providerSessions.removeValue(forKey: id) }
        case "provider-thread.updated":
            if let id = value["id"].string { providerThreads[id] = value }
        case "provider-turn.updated":
            if let id = value["id"].string {
                let previousAttempt = runningTurns[id]?["runAttemptId"].string
                runningTurns[id] = value["status"].string == "running" ? value : nil
                if let previousAttempt { pruneAttempt(previousAttempt) }
            }
        default:
            if type?.hasPrefix("thread.") == true, value.object?["activeProviderThreadId"] != nil {
                threadProviderID = value["activeProviderThreadId"].string
            }
        }
    }
}
