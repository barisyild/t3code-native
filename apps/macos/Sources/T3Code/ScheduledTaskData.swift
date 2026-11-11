import Foundation

struct ScheduledTask: Equatable, Sendable {
    let id: String
    let title: String
    let prompt: String
    let enabled: Bool
    let projectId: String
    let threadId: String?
    let threadMode: ScheduledThreadMode
    let schedule: Wire
    let workspace: Wire
    let model: Wire
    let runtime: String
    let interaction: String
    let nextRun: String?
    let lastRun: String?
    let status: String
    let lastError: String?
    let runCount: Int
    let policyBlock: String?
    let webhook: Wire

    var isWebhook: Bool { schedule["type"].string == "webhook" }

    init?(_ value: Wire) {
        guard let id = value["id"].string, let title = value["title"].string,
              let projectId = value["projectId"].string, let prompt = value["prompt"].string,
              let enabled = value["enabled"].bool, ScheduledTrigger(value["schedule"]["type"].string) != nil else { return nil }
        self.id = id
        self.title = title
        self.prompt = prompt
        self.projectId = projectId
        self.enabled = enabled
        threadId = value["threadId"].string
        threadMode = value["threadMode"].string.flatMap(ScheduledThreadMode.init(rawValue:)) ??
            (threadId == nil ? .newThread : .continueThread)
        schedule = value["schedule"]
        workspace = value["workspaceStrategy"]
        model = value["modelSelection"]
        runtime = value["runtimeMode"].string ?? "approval-required"
        interaction = value["interactionMode"].string ?? "default"
        nextRun = value["nextRunAt"].string
        lastRun = value["lastRunAt"].string
        status = value["lastRunStatus"].string ?? "never"
        lastError = value["lastRunError"].string
        runCount = value["runCount"].int ?? 0
        policyBlock = value["blockedByPolicy"].string
        webhook = value["webhook"]
    }

    var scheduleName: String {
        switch ScheduledTrigger(schedule["type"].string) {
        case .interval:
            guard let milliseconds = schedule["everyMs"].int else { return "Interval" }
            if milliseconds.isMultiple(of: 60_000) { return "Every \(milliseconds / 60_000) min" }
            return "Every \((Double(milliseconds) / 1_000).formatted(.number.precision(.fractionLength(0...3)))) sec"
        case .once:
            guard let date = WorkspaceStyle.date(schedule["runAt"].string) else { return "Once" }
            return "Once, \(date.formatted(date: .abbreviated, time: .shortened))"
        case .fixed:
            let days = ScheduledTriggerDraft.days(schedule)
            let name = switch days {
            case ScheduledTriggerDraft.allDays: "Daily"
            case Set(1...5): "Weekdays"
            default: days.sorted().map { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$0] }.joined(separator: ", ")
            }
            return "\(name) at \(schedule["timeOfDay"].string ?? "")"
        case .webhook: return "On webhook"
        case nil: return "Schedule"
        }
    }
}

enum ScheduledTrigger: String, CaseIterable, Equatable {
    case fixed = "fixed_time", interval, once, webhook

    init?(_ value: String?) {
        guard let value else { return nil }
        self.init(rawValue: value)
    }

    var name: String {
        switch self {
        case .fixed: "At a fixed time"
        case .interval: "At an interval"
        case .once: "Once"
        case .webhook: "On webhook"
        }
    }
}

enum ScheduledThreadMode: String, CaseIterable, Equatable {
    case newThread = "new_thread", continueThread = "continue", freshSession = "fresh_session"

    var name: String {
        switch self {
        case .newThread: "New thread each run"
        case .continueThread: "Continue one thread"
        case .freshSession: "Fresh session in one thread"
        }
    }
}

enum ScheduledCheckout: String, CaseIterable, Equatable {
    case root, worktree, existing = "existing_worktree"

    var name: String {
        switch self {
        case .root: "Use the project checkout"
        case .worktree: "Create a new worktree"
        case .existing: "Use a specific checkout"
        }
    }
}

struct ScheduledWebhookFilter: Equatable {
    enum Operation: String, CaseIterable {
        case equals, notEquals, startsWith, `in`, exists

        var name: String {
            switch self {
            case .equals: "Equals"
            case .notEquals: "Does not equal"
            case .startsWith: "Starts with"
            case .in: "Matches one of"
            case .exists: "Exists"
            }
        }
    }

    var path = ""
    var operation = Operation.equals
    var value = ""

    init() {}

    init?(_ stored: Wire) {
        guard let path = stored["path"].string, let operation = stored["op"].string.flatMap(Operation.init(rawValue:)) else { return nil }
        self.path = path
        self.operation = operation
        value = operation == .in ? stored["value"].array.compactMap(\.string).joined(separator: ", ") : stored["value"].string ?? ""
    }

    func encode() throws -> Wire {
        let path = path.trimmedForSchedule
        guard path.range(of: "^(body|headers|query)(\\.|$)", options: .regularExpression) != nil else {
            throw ClientError.message("Filter paths start with body, headers, or query.")
        }
        var fields: Payload = ["path": .string(path), "op": .string(operation.rawValue)]
        if operation == .in {
            let values = value.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmedForSchedule }
            guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
                throw ClientError.message("Enter one or more non-empty filter values separated by commas.")
            }
            fields["value"] = .array(values.map(Wire.string))
        } else if operation != .exists { fields["value"] = .string(value) }
        return .object(fields)
    }
}

struct ScheduledTriggerDraft: Equatable {
    static let allDays = Set(0...6)

    var kind = ScheduledTrigger.fixed
    var minutes = "15"
    var time = "09:00"
    var weekdays = Set(1...5)
    var date = Date().addingTimeInterval(3_600)
    var dateChanged = false
    var signed = false
    var signatureHeader = "x-hub-signature-256"
    var signatureEncoding = "hex"
    var signaturePrefix = "sha256="
    var signatureSecret = ""
    var maxAge = ""
    var replayKey = ""
    var coalesceKey = ""
    var coalesceSeconds = ""
    var filters: [ScheduledWebhookFilter] = []

    init(_ original: Wire = .null) {
        guard let kind = ScheduledTrigger(original["type"].string) else { return }
        self.kind = kind
        switch kind {
        case .fixed:
            time = Self.paddedTime(original["timeOfDay"].string ?? "09:00")
            weekdays = Self.days(original)
        case .interval:
            let interval = max(60_000, original["everyMs"].int ?? 900_000)
            minutes = interval.isMultiple(of: 60_000) ? String(interval / 60_000) : String(Double(interval) / 60_000)
        case .once: date = WorkspaceStyle.date(original["runAt"].string) ?? date
        case .webhook:
            let signature = original["signature"]
            signed = signature.object != nil
            signatureHeader = signature["header"].string ?? signatureHeader
            signatureEncoding = signature["encoding"].string ?? signatureEncoding
            signaturePrefix = signature["prefix"].string ?? signaturePrefix
            maxAge = original["maxDeliveryAgeMinutes"].int.map(String.init) ?? ""
            replayKey = original["dedupe"]["replayKey"].string ?? ""
            coalesceKey = original["dedupe"]["coalesceKey"].string ?? ""
            coalesceSeconds = original["dedupe"]["coalesceWindowSeconds"].int.map(String.init) ?? ""
            filters = original["filters"].array.compactMap(ScheduledWebhookFilter.init)
        }
    }

    func encode(original: Wire = .null, hasStoredSecret: Bool = false) throws -> Wire {
        let sameKind = original["type"].string == kind.rawValue
        switch kind {
        case .fixed:
            let value = Self.paddedTime(time.trimmedForSchedule)
            guard value.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else {
                throw ClientError.message("Enter a host time as HH:MM, for example 09:30.")
            }
            let days = weekdays.isEmpty ? Self.allDays : weekdays
            if sameKind, value == Self.paddedTime(original["timeOfDay"].string ?? ""), days == Self.days(original) { return original }
            var schedule: Payload = ["type": .string(kind.rawValue), "timeOfDay": .string(value)]
            if days != Self.allDays { schedule["weekdays"] = .array(days.sorted().map(Wire.int)) }
            return .object(schedule)
        case .interval:
            let number = minutes.trimmedForSchedule.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(number), value.isFinite else { throw ClientError.message("Enter the interval in minutes.") }
            let milliseconds = (value * 60_000).rounded()
            guard milliseconds >= 60_000 else {
                throw ClientError.message("The interval must be at least one minute.")
            }
            guard milliseconds <= 9_007_199_254_740_991 else {
                throw ClientError.message("The interval is too large.")
            }
            if sameKind, original["everyMs"].int == Int(milliseconds) { return original }
            return .object(["type": .string(kind.rawValue), "everyMs": .int(Int(milliseconds))])
        case .once:
            if sameKind && !dateChanged && date == WorkspaceStyle.date(original["runAt"].string) { return original }
            return .object(["type": .string(kind.rawValue),
                            "runAt": .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))])
        case .webhook:
            return try webhook(original: sameKind ? original : .null, hasStoredSecret: sameKind && hasStoredSecret)
        }
    }

    private func webhook(original: Wire, hasStoredSecret: Bool) throws -> Wire {
        var signature: Wire = .null
        if signed {
            let header = signatureHeader.trimmedForSchedule
            let secret = signatureSecret.trimmedForSchedule
            guard !header.isEmpty, header.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil else {
                throw ClientError.message("Enter a valid HTTP header for the webhook signature.")
            }
            guard hasStoredSecret || !secret.isEmpty else { throw ClientError.message("Enter a webhook signing secret.") }
            var fields: Payload = ["header": .string(header), "encoding": .string(signatureEncoding), "prefix": .string(signaturePrefix)]
            if !secret.isEmpty { fields["secret"] = .string(secret) }
            signature = .object(fields)
        }
        let age = try Self.optionalInteger(maxAge, range: 1...1_440, name: "Maximum delivery age")
        let window = try Self.optionalInteger(coalesceSeconds, range: 10...3_600, name: "Coalesce window")
        var dedupe: Payload = [:]
        for (key, value) in [("replayKey", replayKey), ("coalesceKey", coalesceKey)] {
            let template = value.trimmedForSchedule
            guard !template.isEmpty else { continue }
            let pattern = #"\{\{\s*(?:(?:body|headers|query)(?:\.[^{}.\s]+)*|request)\s*\}\}"#
            let remainder = template.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            guard remainder != template, !remainder.contains("{{"), !remainder.contains("}}") else {
                throw ClientError.message("Webhook deduplication keys must include a request placeholder such as {{body.id}}.")
            }
            dedupe[key] = .string(template)
        }
        if let window { dedupe["coalesceWindowSeconds"] = .int(window) }
        var schedule: Payload = ["type": .string(kind.rawValue), "signature": signature,
                                 "maxDeliveryAgeMinutes": age.map(Wire.int) ?? .null, "dedupe": .object(dedupe)]
        guard filters.count <= 16 else { throw ClientError.message("Use up to 16 webhook filters.") }
        if filters != original["filters"].array.compactMap(ScheduledWebhookFilter.init) {
            schedule["filters"] = .array(try filters.map { try $0.encode() })
        }
        return .object(schedule)
    }

    private static func optionalInteger(_ text: String, range: ClosedRange<Int>, name: String) throws -> Int? {
        let value = text.trimmedForSchedule
        guard !value.isEmpty else { return nil }
        guard let parsed = Int(value), range.contains(parsed) else {
            throw ClientError.message("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return parsed
    }

    static func days(_ schedule: Wire) -> Set<Int> {
        let days = Set(schedule["weekdays"].array.compactMap(\.int).filter { (0...6).contains($0) })
        return days.isEmpty ? allDays : days
    }

    private static func paddedTime(_ time: String) -> String { time.count == 4 ? "0" + time : time }
}

struct ScheduledTaskDraft: Equatable {
    let original: ScheduledTask?
    var title: String
    var prompt: String
    var enabled: Bool
    var project: String
    var thread: String?
    var threadMode: ScheduledThreadMode
    var trigger: ScheduledTriggerDraft
    var checkout: ScheduledCheckout
    var branch: String
    var baseRef: String
    var startFromOrigin: Bool
    var checkoutPath: String
    var model: Wire
    var runtime: String
    var interaction: String

    init(task: ScheduledTask?, project: String, model: Wire) {
        original = task
        title = task?.title ?? ""
        prompt = task?.prompt ?? ""
        enabled = task?.enabled ?? true
        self.project = task?.projectId ?? project
        thread = task?.threadId
        threadMode = task?.threadMode ?? .newThread
        trigger = ScheduledTriggerDraft(task?.schedule ?? .null)
        let workspace = task?.workspace ?? .null
        checkout = workspace["type"].string.flatMap(ScheduledCheckout.init(rawValue:)) ?? .root
        branch = workspace["branch"].string ?? ""
        baseRef = workspace["baseRef"].string ?? "main"
        startFromOrigin = workspace["startFromOrigin"].bool ?? (task == nil)
        checkoutPath = workspace["worktreePath"].string ?? ""
        self.model = task?.model ?? model
        runtime = task?.runtime ?? "approval-required"
        interaction = task?.interaction ?? "default"
    }

    func encode(id: String) throws -> Payload {
        let title = title.trimmedForSchedule
        let prompt = prompt.trimmedForSchedule
        guard !title.isEmpty, !prompt.isEmpty else { throw ClientError.message("Enter a task name and a prompt.") }
        guard !project.isEmpty, model["instanceId"].string != nil, model["model"].string != nil else {
            throw ClientError.message("Choose a project and an agent model.")
        }
        let target = threadMode == .newThread ? nil : thread ?? (project == original?.projectId ? original?.threadId : nil)
        var workspace: Payload = ["type": .string(checkout.rawValue)]
        if !branch.trimmedForSchedule.isEmpty { workspace["branch"] = .string(branch.trimmedForSchedule) }
        if checkout == .worktree {
            guard !baseRef.trimmedForSchedule.isEmpty else { throw ClientError.message("Enter a base branch for the new worktree.") }
            workspace["baseRef"] = .string(baseRef.trimmedForSchedule)
            workspace["startFromOrigin"] = .bool(startFromOrigin)
        } else if checkout == .existing {
            guard !checkoutPath.trimmedForSchedule.isEmpty else { throw ClientError.message("Enter the checkout path on the host.") }
            workspace["worktreePath"] = .string(checkoutPath.trimmedForSchedule)
        }
        var fields: Payload = [
            "id": .string(original?.id ?? id), "title": .string(title), "prompt": .string(prompt), "enabled": .bool(enabled),
            "schedule": try trigger.encode(original: original?.schedule ?? .null, hasStoredSecret: original?.webhook["hasSecret"].bool == true),
            "projectId": .string(project), "threadId": target.map(Wire.string) ?? .null, "threadMode": .string(threadMode.rawValue),
            "workspaceStrategy": .object(workspace), "modelSelection": model,
            "runtimeMode": .string(runtime), "interactionMode": .string(interaction),
        ]
        if original != nil { fields["requireExisting"] = .bool(true) }
        else { fields["creationSource"] = .string("web") }
        return fields
    }
}

private extension String {
    var trimmedForSchedule: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
