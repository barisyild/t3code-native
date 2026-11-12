import Foundation

struct Project: Equatable, Sendable {
    let id: String
    let name: String
    let root: String
    let defaultModel: Wire
    let defaultCheckout: String?
    let autoPull: Bool
    let scripts: [Wire]
    let pinned: Bool
    let archived: Bool

    init?(_ value: Wire) {
        guard let id = value["id"].string, let name = value["title"].string,
              let root = value["workspaceRoot"].string else { return nil }
        self.id = id
        self.name = name
        self.root = root
        defaultModel = value["defaultModelSelection"]
        defaultCheckout = value["defaultThreadEnvMode"].string
        autoPull = value["autoPull"].bool == true
        scripts = value["scripts"].array
        pinned = value["pinnedAt"].string != nil
        archived = value["archivedAt"].string != nil
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.archived != rhs.archived { return !lhs.archived }
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}

struct ThreadSummary: Equatable, Sendable {
    static let working: Set<String> = ["queued", "preparing", "starting", "running", "waiting"]

    let id: String
    let projectId: String
    let title: String
    let status: String
    let activeRunId: String?
    let stopRequested: Bool
    let activeSince: String?
    let pendingRequest: Wire
    let model: Wire
    let activeProviderThreadID: String?
    let goal: ThreadGoal?
    let runtimeMode: String?
    let interactionMode: String?
    let branch: String?
    let worktreePath: String?
    let pullRequests: [PullRequestReference]
    let archived: Bool
    let pinned: Bool
    let pinOrderKey: String?
    let createdAt: String
    let updatedAt: String
    let lastError: String?
    let lastErrorClass: String?
    let pendingGuestMessageCount: Int
    let isWaitingForBackgroundWork: Bool
    let isSideChat: Bool
    let parentThreadID: String?
    let relationshipToParent: String?
    let forkSourceThreadID: String?
    let delegatedFrom: DelegatedThreadLink?
    let creationSource: String?
    let latestRunID: String?
    let latestRunCompletedAt: String?

    var relationshipParentID: String? { forkSourceThreadID ?? parentThreadID }
    var isSubagent: Bool { relationshipToParent == "subagent" || delegatedFrom != nil }
    var isProviderNativeSubagent: Bool { relationshipToParent == "subagent" && creationSource == "provider" }
    var mergeBackTargetID: String? { relationshipToParent == "fork" ? relationshipParentID : nil }
    var isWorking: Bool { activeRunId != nil || Self.working.contains(status) }
    var needsInput: Bool { pendingRequest != .null }
    var needsAttention: Bool { needsInput || pendingGuestMessageCount > 0 }
    var isActive: Bool { !archived && (isWorking || needsAttention || isWaitingForBackgroundWork) }

    init?(_ value: Wire, archived: Bool = false) {
        guard let id = value["id"].string, let projectId = value["projectId"].string,
              let title = value["title"].string else { return nil }
        self.id = id
        self.projectId = projectId
        self.title = title
        status = value["activityRunStatus"].string ?? value["status"].string ?? "idle"
        activeRunId = value["activeRunId"].string
        stopRequested = value["latestRunStopRequested"].bool == true
        activeSince = value["activityRunStartedAt"].string ?? value["latestRunStartedAt"].string ?? value["latestRunRequestedAt"].string
        pendingRequest = value["pendingRuntimeRequest"]
        model = value["modelSelection"]
        activeProviderThreadID = value["activeProviderThreadId"].string
        goal = ThreadGoal(value["goal"])
        runtimeMode = value["runtimeMode"].string
        interactionMode = value["interactionMode"].string
        branch = value["branch"].string
        worktreePath = value["worktreePath"].string
        let links = value["pullRequests"].array.filter { $0["source"].string != "stack-dismissed" }
        var seen = Set<PullRequestReference>()
        pullRequests = (links + [value["linkedPullRequest"], value["branchPullRequest"]])
            .compactMap { PullRequestReference($0, projectID: projectId) }.filter { seen.insert($0).inserted }
        self.archived = archived || value["archivedAt"].string != nil
        pinned = value["pinnedAt"].string != nil
        pinOrderKey = value["pinOrderKey"].string
        updatedAt = value["updatedAt"].string ?? ""
        createdAt = value["createdAt"].string ?? updatedAt
        lastError = value["lastError"].string
        lastErrorClass = value["lastErrorClass"].string
        pendingGuestMessageCount = value["pendingGuestMessageCount"].int ?? 0
        isSideChat = value["lineage"]["sideChat"].bool == true
        parentThreadID = value["lineage"]["parentThreadId"].string
        relationshipToParent = value["lineage"]["relationshipToParent"].string
        forkSourceThreadID = value["forkedFrom"]["type"].string == "run" ? value["forkedFrom"]["threadId"].string : nil
        delegatedFrom = DelegatedThreadLink(value["delegatedFrom"], fallbackLabel: value["linkOrigin"]["label"].string)
        creationSource = value["creationSource"].string
        latestRunID = value["latestRunId"].string
        latestRunCompletedAt = value["latestRunCompletedAt"].string
        isWaitingForBackgroundWork = value["pendingBackgroundTasks"].array.contains { task in
            let kind = task["kind"].string
            return task["awaited"].bool == true || kind == "subagent" || kind == "background_task"
        }
    }
}

struct ProviderModel: Equatable, Sendable {
    let name: String
    let slug: String
    let isDefault: Bool
    let isCustom: Bool
    let aliases: [String]
    let options: [ComposerModelOption]
}

struct Provider: Equatable, Sendable {
    let id: String
    let driver: String
    let name: String
    let status: String
    let message: String?
    let enabled: Bool
    let isAvailable: Bool
    let models: [ProviderModel]
    let modes: [String]?
    let supportsPlan: Bool
    let supportsTextGeneration: Bool
    let commandCatalog: ComposerCommandCatalog
    let usageLimit: UsageLimitAccount?
    let usageIdentity: UsageLimitAccount.Identity?
    let management: ProviderManagement

    init?(_ value: Wire) {
        guard let id = value["instanceId"].string else { return nil }
        self.id = id
        driver = value["driver"].string ?? id
        name = value["displayName"].string ?? id.capitalized
        status = value["status"].string ?? "unknown"
        message = value["unavailableReason"].string ?? value["message"].string
        enabled = value["enabled"].bool == true
        isAvailable = enabled && value["availability"].string != "unavailable" &&
            status != "error" && value["installed"].bool != false
        modes = value["supportedRuntimeModes"] == .null ? nil : value["supportedRuntimeModes"].array.compactMap(\.string)
        supportsPlan = value["showInteractionModeToggle"].bool == true
        supportsTextGeneration = value["supportsTextGeneration"].bool != false
        commandCatalog = ComposerCommandCatalog(value)
        usageIdentity = UsageLimitAccount.Identity(value["auth"])
        management = ProviderManagement(value)
        var limits = value["usageLimits"]
        if limits == .null, status == "error" || value["installed"].bool == false, let message {
            limits = .object([
                "checkedAt": value["checkedAt"], "windows": .array([]),
                "unavailable": .object(["reason": .string("probeFailed"), "message": .string(message)]),
            ])
        }
        usageLimit = enabled ? UsageLimitAccount(title: name, detail: value["auth"]["label"].string ?? "",
                                                driver: driver, limits: limits, identity: usageIdentity,
                                                resetTarget: .provider(id)) : nil
        models = value["models"].array.compactMap { model in
            guard let slug = model["slug"].string else { return nil }
            return ProviderModel(name: model["shortName"].string ?? model["name"].string ?? slug,
                                 slug: slug, isDefault: model["isDefault"].bool == true,
                                 isCustom: model["isCustom"].bool == true,
                                 aliases: model["aliases"].array.compactMap(\.string),
                                 options: model["capabilities"]["optionDescriptors"].array.compactMap(ComposerModelOption.init))
        }
    }

    func selection(_ model: ProviderModel) -> Wire {
        .object(["instanceId": .string(id), "model": .string(model.slug)])
    }
}

struct WorkspaceData {
    private(set) var projects: [String: Project] = [:]
    private(set) var threads: [String: ThreadSummary] = [:]
    private(set) var archived: [String: ThreadSummary] = [:]
    private(set) var sequence: Int?
    private var olderSettledProjects: Set<String> = []

    var orderedProjects: [Project] { projects.values.sorted(by: Project.precedes) }

    func isListed(_ thread: ThreadSummary) -> Bool {
        if thread.isSideChat { return false }
        guard thread.relationshipToParent == "subagent", let parent = thread.parentThreadID else { return true }
        return threads[parent] == nil && archived[parent] == nil
    }

    func listedActivityParents(for threads: [String: ThreadSummary]) -> Set<String> {
        var activeParents = Set<String>()
        for thread in threads.values where thread.isActive {
            var child = thread
            var seen = Set([child.id])
            while !isListed(child), let id = child.parentThreadID, seen.insert(id).inserted, let parent = threads[id] {
                activeParents.insert(id)
                child = parent
            }
        }
        return activeParents
    }

    func sideChats(of parentID: String) -> [ThreadSummary] {
        threads.values.filter { $0.isSideChat && $0.parentThreadID == parentID }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    func hasThreads(in projectID: String) -> Bool {
        olderSettledProjects.contains(projectID) || threads.values.contains { $0.projectId == projectID } ||
            archived.values.contains { $0.projectId == projectID }
    }

    mutating func apply(_ value: Wire) {
        let kind = value["kind"].string
        if kind == "snapshot" {
            // Marked snapshots refresh repository identity only, which this view does not use.
            guard value["resolvedRepositoryIdentityRoots"] == .null else { return }
            let snapshot = value["snapshot"]
            sequence = snapshot["snapshotSequence"].int
            projects = Self.index(snapshot["projects"].array.compactMap(Project.init), id: \.id)
            threads = Self.index(snapshot["threads"].array.compactMap { ThreadSummary($0) }, id: \.id)
            archived = Self.index(snapshot["archivedThreads"].array.compactMap { ThreadSummary($0, archived: true) }, id: \.id)
            olderSettledProjects = Set(snapshot["olderSettled"]["counts"].array.compactMap {
                ($0["count"].int ?? 0) > 0 ? $0["projectId"].string : nil
            })
            return
        }
        guard let next = value["sequence"].int, next > (sequence ?? -1) else { return }
        sequence = next
        switch kind {
        case "project.updated":
            if let project = Project(value["project"]) { projects[project.id] = project }
        case "project.removed":
            if let id = value["projectId"].string {
                projects.removeValue(forKey: id)
                olderSettledProjects.remove(id)
            }
        case "thread.updated":
            let isArchived = value["location"].string == "archive"
            guard let thread = ThreadSummary(value["thread"], archived: isArchived) else { return }
            if thread.archived {
                threads.removeValue(forKey: thread.id)
                archived[thread.id] = thread
            } else {
                archived.removeValue(forKey: thread.id)
                threads[thread.id] = thread
            }
        case "thread.removed":
            guard let id = value["threadId"].string else { return }
            threads.removeValue(forKey: id)
            archived.removeValue(forKey: id)
        default: break
        }
    }

    mutating func replaceArchive(_ value: Wire) -> Bool {
        guard let asOf = value["snapshotSequence"].int, asOf >= (sequence ?? 0) else { return false }
        archived = Self.index(value["threads"].array.compactMap { ThreadSummary($0, archived: true) }, id: \.id)
        for project in value["projects"].array.compactMap(Project.init) where projects[project.id] == nil {
            projects[project.id] = project
        }
        return true
    }

    private static func index<T>(_ values: [T], id: KeyPath<T, String>) -> [String: T] {
        Dictionary(values.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { _, latest in latest })
    }
}

struct TimelineEntry: Equatable, Sendable {
    let id: String
    let threadId: String
    let sourceThreadID: String
    let ordinal: Int
    let isLocal: Bool
    let value: Wire

    var type: String { value["type"].string ?? "" }
    var guest: GuestAttribution? { type == "user_message" ? GuestAttribution(value["context"]) : nil }
    var requestId: String? { value["requestId"].string }
    var isMessage: Bool { type == "user_message" || type == "assistant_message" }
    var findID: String { isMessage ? value["messageId"].string ?? id : id }
    var attachments: [ChatAttachment] {
        let direct = value["attachments"].array
        guard let groups = value["questionAnswer"]["attachmentsByQuestionId"].object else {
            return direct.compactMap(ChatAttachment.init)
        }
        let questions = value["questions"].array.compactMap { $0["id"].string }
        let order = questions + groups.keys.filter { !questions.contains($0) }.sorted()
        return (direct + order.flatMap { groups[$0]?.array ?? [] }).compactMap(ChatAttachment.init)
    }
    var canFork: Bool { type == "assistant_message" && value["status"].string == "completed" && value["runId"].string != nil }
    var canRewind: Bool {
        isLocal && type == "user_message" && value["runId"].string != nil && value["messageId"].string != nil &&
            ["turn_start", "queued_turn"].contains(value["inputIntent"].string ?? "")
    }

    init?(item: Wire, isLocal: Bool = true, sourceThreadID: String? = nil) {
        guard let id = item["id"].string, let threadId = item["threadId"].string,
              let ordinal = item["ordinal"].int, item["type"].string != nil else { return nil }
        self.id = id
        self.threadId = threadId
        self.sourceThreadID = sourceThreadID ?? threadId
        self.ordinal = ordinal
        self.isLocal = isLocal
        value = item
    }

    init?(row: Wire) {
        self.init(item: row["item"], isLocal: row["visibility"].string == "local", sourceThreadID: row["sourceThreadId"].string)
    }
}

struct ThreadDetail {
    private var entries: [TimelineEntry] = []
    private(set) var queue = ThreadQueue()
    private(set) var runModels: [String: Wire] = [:]
    private(set) var requests: [String: Wire] = [:]
    private(set) var goalOwners: [String: ThreadGoal.Owner] = [:]
    private(set) var relationships = ThreadRelationshipProjection()
    private(set) var guestShare: GuestShare?
    private var mergeRuns = ThreadMergeRuns()
    var mergeBackRunID: String? { mergeRuns.latestFinishedID }
    var pendingMergeBacks: [String: ThreadContextTransfer] {
        relationships.transfers.filter { $0.value.kind == "merge_back" && $0.value.status == "pending" }
    }
    private(set) var rewind = ThreadRewind.State()
    var checkpointCount: Int { rewind.checkpointCount }
    private(set) var historyCursor: String?
    private(set) var loaded = false
    private(set) var sequence = -1
    private var latestOrdinal = -1
    private(set) var activeRunIDs: Set<String> = []
    private var recentMessages: [String: Wire] = [:]
    private var messageOrder: [String] = []

    var timeline: [TimelineEntry] {
        guard queue.needsTimelineFilter || rewind.hasRolledBackRuns else { return entries }
        return entries.filter { entry in
            !queue.hides(entry) && !(entry.isLocal && entry.value["runId"].string.map(rewind.rolledBack) == true)
        }
    }

    func liveActivity(for runID: String?) -> ThreadLiveActivity? {
        guard let runID, activeRunIDs.contains(runID) else { return nil }
        for entry in entries.reversed() where entry.isLocal && entry.value["runId"].string == runID {
            if let activity = ThreadLiveActivity(entry: entry) { return activity }
        }
        return nil
    }

    mutating func apply(_ frame: Wire) {
        switch frame["kind"].string {
        case "snapshot":
            load(frame["projection"], sequence: frame["snapshotSequence"].int ?? -1,
                 cursor: frame["hasMoreHistory"].bool == true ? frame["historyCursor"].string : nil,
                 latestOrdinal: frame["latestLocalTurnOrdinal"].int)
        case "event":
            guard let next = frame["sequence"].int, next > sequence else { return }
            sequence = next
            let event = frame["event"]
            let value = event["payload"]
            let type = event["type"].string
            queue.apply(type, value)
            rewind.apply(type, value)
            switch type {
            case "run.created", "run.updated":
                applyRun(value)
                queue.applyRun(value, message: value["userMessageId"].string.flatMap { recentMessages[$0] })
            case "message.updated": rememberMessage(value)
            case "provider-thread.updated":
                if let id = value["id"].string { goalOwners[id] = ThreadGoal.Owner(value) }
            case "runtime-request.updated": applyRequest(value)
            case "thread.guest-share-updated": guestShare = GuestShare(value["guestShare"])
            case "subagent.updated", "context-transfer.created", "context-transfer.updated":
                relationships.apply(type, value)
            case "turn-item.updated":
                if let entry = TimelineEntry(item: Self.restoreText(value, from: recentMessages)) { upsert(entry) }
            default: break
            }
        default: break
        }
    }

    mutating func prepend(_ page: Wire) {
        let known = Set(entries.map(\.id))
        let earlier = page["items"].array.compactMap(TimelineEntry.init(row:)).filter { !known.contains($0.id) }
        entries.insert(contentsOf: earlier, at: 0)
        historyCursor = page["hasMoreHistory"].bool == true ? page["nextCursor"].string : nil
    }

    private mutating func load(_ projection: Wire, sequence: Int, cursor: String?, latestOrdinal: Int?) {
        loaded = true
        self.sequence = sequence
        historyCursor = cursor
        let messages = projection["messages"].array
        let messageIndex = Dictionary(messages.compactMap { message in
            message["id"].string.map { ($0, message) }
        }, uniquingKeysWith: { _, last in last })
        recentMessages.removeAll()
        messageOrder.removeAll()
        for message in messages.suffix(32) { rememberMessage(message) }
        entries = projection["visibleTurnItems"].array.compactMap { row in
            let local = row["visibility"].string == "local"
            return TimelineEntry(item: local ? Self.restoreText(row["item"], from: messageIndex) : row["item"], isLocal: local,
                                 sourceThreadID: row["sourceThreadId"].string)
        }
        queue.load(projection, messageIndex: messageIndex)
        guestShare = GuestShare(projection["thread"]["guestShare"])
        rewind.load(projection)
        relationships.load(projection)
        mergeRuns = ThreadMergeRuns()
        self.latestOrdinal = latestOrdinal ?? entries.lazy.filter(\.isLocal).map(\.ordinal).max() ?? -1
        activeRunIDs.removeAll()
        runModels.removeAll()
        for run in projection["runs"].array { applyRun(run) }
        requests.removeAll()
        for request in projection["runtimeRequests"].array { applyRequest(request) }
        goalOwners.removeAll()
        for provider in projection["providerThreads"].array {
            if let id = provider["id"].string { goalOwners[id] = ThreadGoal.Owner(provider) }
        }
    }

    private mutating func applyRun(_ value: Wire) {
        guard let id = value["id"].string, let status = value["status"].string else { return }
        mergeRuns.apply(value)
        if value["modelSelection"] != .null { runModels[id] = value["modelSelection"] }
        if ThreadSummary.working.contains(status) { activeRunIDs.insert(id) }
        else { activeRunIDs.remove(id) }
    }

    private mutating func applyRequest(_ value: Wire) {
        guard let id = value["id"].string else { return }
        if value["status"].string == "pending" { requests[id] = value }
        else { requests.removeValue(forKey: id) }
    }

    private mutating func rememberMessage(_ message: Wire) {
        guard let id = message["id"].string else { return }
        recentMessages[id] = message
        messageOrder.removeAll { $0 == id }
        messageOrder.append(id)
        if messageOrder.count > 32 { recentMessages.removeValue(forKey: messageOrder.removeFirst()) }
    }

    private static func restoreText(_ item: Wire, from messages: [String: Wire]) -> Wire {
        guard let id = item["messageId"].string, let message = messages[id], var fields = item.object else { return item }
        let restoreGuest = item["context"] == .null && message["context"]["guest"] != .null
        let omittedText = item["textOmitted"].bool == true ? message["text"].string : nil
        guard restoreGuest || omittedText != nil else { return item }
        if let omittedText {
            fields["text"] = .string(omittedText)
            fields.removeValue(forKey: "textOmitted")
        }
        if restoreGuest { fields["context"] = message["context"] }
        return .object(fields)
    }

    private mutating func upsert(_ entry: TimelineEntry) {
        if let index = entries.lastIndex(where: { $0.id == entry.id }) {
            if entries[index].ordinal == entry.ordinal {
                entries[index] = entry
                return
            }
            entries.remove(at: index)
        } else if historyCursor != nil && entry.ordinal <= latestOrdinal {
            let run = entry.value["runId"].string
            let isVisibleRun = run.map { id in
                activeRunIDs.contains(id) || entries.contains {
                    $0.isLocal && $0.value["runId"].string == id && $0.ordinal <= entry.ordinal
                }
            } ?? false
            guard isVisibleRun else { return }
        }
        latestOrdinal = max(latestOrdinal, entry.ordinal)
        let index = entries.firstIndex { row in
            row.isLocal && (row.ordinal, row.id) > (entry.ordinal, entry.id)
        } ?? entries.endIndex
        entries.insert(entry, at: index)
    }
}
