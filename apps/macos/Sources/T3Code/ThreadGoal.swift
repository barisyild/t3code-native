import Foundation

struct ThreadGoal: Equatable, Sendable {
    enum Status: String, Sendable {
        case active, paused, blocked, complete
        case usageLimited = "usage_limited"
        case budgetLimited = "budget_limited"
    }

    enum Action: String {
        case pause, resume, clear

        var command: String { "/goal \(rawValue)" }
    }

    static func editCommand(_ draft: String, driver: ComposerProvider) throws -> String {
        let objective = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { throw ClientError.message("Enter a goal before saving.") }
        guard !["clear", "pause", "resume", "edit", "show"].contains(objective.lowercased()) else {
            throw ClientError.message("Enter a description of the goal.")
        }
        if driver == .codex, objective.unicodeScalars.count > 4_000 {
            throw ClientError.message("Codex goals can contain up to 4,000 characters.")
        }
        return "/goal \(objective)"
    }

    struct Timing: Equatable {
        let seconds: Int
        let startedAt: Date?

        func label(at now: Date) -> String {
            let elapsed = startedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
            let (total, overflow) = seconds.addingReportingOverflow(elapsed)
            return ThreadGoal.duration(overflow ? Int.max : total)
        }
    }

    struct Owner: Equatable, Sendable {
        let driver: ComposerProvider
        let instanceID: String
        let model: Wire

        init?(_ value: Wire) {
            guard let driver = value["driver"].string.flatMap(ComposerProvider.init(rawValue:)),
                  let instanceID = value["providerInstanceId"].string else { return nil }
            self.driver = driver
            self.instanceID = instanceID
            model = value["nativeMetadata"]["modelSelection"]
        }

        func commandModel(threadModel: Wire, providers: [Provider]) -> Wire? {
            if let selection = [threadModel, model].first(where: {
                ComposerModels.instanceID($0) == instanceID && $0["model"].string?.isEmpty == false
            }) { return selection }
            guard let provider = providers.first(where: { $0.id == instanceID && $0.driver == driver.rawValue }),
                  let fallback = provider.models.first(where: \.isDefault) ?? provider.models.first else { return nil }
            return provider.selection(fallback)
        }
    }

    let objective: String
    let status: Status
    let tokensUsed: Int?
    let tokenBudget: Int?
    let timeUsedSeconds: Int?
    let checks: Int?
    let lastCheck: String?

    init?(_ value: Wire) {
        guard let objective = value["objective"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty,
              let status = value["status"].string.flatMap(Status.init(rawValue:)) else { return nil }
        self.objective = objective
        self.status = status
        tokensUsed = value["tokensUsed"].int
        tokenBudget = value["tokenBudget"].int
        timeUsedSeconds = value["timeUsedSeconds"].int
        checks = value["checks"].int
        lastCheck = value["lastCheck"].string
    }

    var title: String {
        switch status {
        case .active: "Pursuing goal"
        case .paused: "Goal paused"
        case .blocked: "Goal blocked"
        case .usageLimited: "Goal hit a usage limit"
        case .budgetLimited: "Goal reached its token budget"
        case .complete: "Goal complete"
        }
    }

    var progress: String? {
        if let timeUsedSeconds, timeUsedSeconds >= 0 { return Self.duration(timeUsedSeconds) }
        return checkProgress
    }

    var checkProgress: String? {
        checks.map { "\($0) \($0 == 1 ? "check" : "checks")" }
    }

    func timing(activeSince: Date?, providerUpdatedAt: Date? = nil) -> Timing? {
        if let timeUsedSeconds, timeUsedSeconds >= 0 {
            let liveSince: Date? = if status == .active, let activeSince, let providerUpdatedAt {
                max(activeSince, providerUpdatedAt)
            } else { nil }
            return .init(seconds: timeUsedSeconds, startedAt: liveSince)
        }
        guard status == .active, let activeSince else { return nil }
        return .init(seconds: 0, startedAt: activeSince)
    }

    private static func duration(_ value: Int) -> String {
        let hours = value / 3600
        let minutes = value / 60 % 60
        let seconds = value % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    func allows(_ action: Action, driver: ComposerProvider, working: Bool) -> Bool {
        switch action {
        case .clear: true
        case .pause: driver == .codex && status == .active
        case .resume: driver == .codex && status != .active && status != .complete && !working
        }
    }
}
