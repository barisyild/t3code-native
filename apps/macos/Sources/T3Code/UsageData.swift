import Foundation

enum UsagePeriod: Int, CaseIterable {
    case day = 1, week = 7, month = 30, quarter = 90

    var title: String { self == .day ? "Past 24h" : "\(rawValue) days" }
}

struct UsageWindow {
    let payload: Payload
    let keys: [String]
    let labels: [String]
    private let firstHour: Date?

    init(period: UsagePeriod, now: Date = .now, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = calendar
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let label = DateFormatter()
        label.timeZone = timeZone
        label.setLocalizedDateFormatFromTemplate(period == .day ? "jmm" : "MMMd")
        let start: Date
        let end: Date
        let dates: [Date]
        var request: Payload = ["timeZone": .string(timeZone.identifier)]
        if period == .day {
            end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
            start = end.addingTimeInterval(-86_400)
            dates = (0..<24).map { start.addingTimeInterval(Double($0 * 3_600)) }
            let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            request["resolution"] = .string("hour")
            request["sinceTime"] = .string(iso.format(start))
            request["untilTime"] = .string(iso.format(end))
            firstHour = start
            keys = dates.map(iso.format)
        } else {
            end = calendar.startOfDay(for: now)
            dates = (0..<period.rawValue).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: end) }
            start = dates.first ?? end
            request["resolution"] = .string("day")
            firstHour = nil
            keys = dates.map(day.string(from:))
        }
        request["sinceDay"] = .string(day.string(from: start))
        request["untilDay"] = .string(day.string(from: end))
        labels = dates.map(label.string(from:))
        payload = request
    }

    func intervalKey(for bucket: Wire) -> String? {
        guard let firstHour else { return bucket["day"].string }
        guard let hour = WorkspaceStyle.date(bucket["hourStart"].string) else { return nil }
        let offset = hour.timeIntervalSince(firstHour)
        guard offset >= 0, offset < 86_400, offset.truncatingRemainder(dividingBy: 3_600) == 0 else { return nil }
        return keys[Int(offset / 3_600)]
    }
}

struct UsageTotals {
    var cost: Double = 0
    var input: Double = 0
    var output: Double = 0
    var unpriced: Double = 0
    var records: Double = 0
    var tokens: Double { input + output }

    init() {}

    init(bucket: Wire) {
        let tokens = bucket["totals"]
        input = ["uncachedInputTokens", "cachedInputTokens", "cacheCreationTokens"].reduce(0) {
            $0 + (tokens[$1].double ?? 0)
        }
        output = tokens["outputTokens"].double ?? 0
        cost = bucket["costUsd"].double ?? 0
        records = bucket["records"].double ?? 0
        unpriced = bucket["unpricedRecords"].double ?? (bucket["costSource"].string == "unpriced" ? records : 0)
    }

    mutating func add(_ other: Self) {
        cost += other.cost
        input += other.input
        output += other.output
        unpriced += other.unpriced
        records += other.records
    }
}

struct UsageReport {
    struct Model: Hashable {
        let provider: String
        let name: String
    }

    struct Breakdown {
        var total = UsageTotals()
        var intervals: [String: UsageTotals] = [:]
        var models: [Model: UsageTotals] = [:]
    }

    private struct Bucket {
        let interval: String
        let model: Model
        let totals: UsageTotals
    }

    private let buckets: [Bucket]
    let window: UsageWindow
    let providers: [String]
    let refreshing: Bool
    let incompleteSources: [String]

    init(_ value: Wire, window: UsageWindow) throws {
        guard let version = value["contractVersion"].int, (4...6).contains(version) else {
            throw ClientError.message("This environment’s usage report requires a compatible client and server version.")
        }
        self.window = window
        let intervals = Set(window.keys)
        buckets = value["buckets"].array.compactMap { bucket in
            guard let interval = window.intervalKey(for: bucket), intervals.contains(interval),
                  let provider = bucket["provider"].string, let model = bucket["model"].string else { return nil }
            return Bucket(interval: interval, model: Model(provider: provider, name: model), totals: UsageTotals(bucket: bucket))
        }
        providers = Set(buckets.map(\.model.provider)).sorted()
        let sources = value["sources"].array
        refreshing = sources.contains { $0["refreshing"].bool == true }
        incompleteSources = Array(Set(sources.compactMap { source -> String? in
            guard ["partial", "failed"].contains(source["status"].string ?? "") else { return nil }
            return source["fingerprint"]["provider"].string
        })).sorted()
    }

    func breakdown(provider: String?) -> Breakdown {
        var result = Breakdown()
        for bucket in buckets where provider == nil || bucket.model.provider == provider {
            result.total.add(bucket.totals)
            result.intervals[bucket.interval, default: UsageTotals()].add(bucket.totals)
            result.models[bucket.model, default: UsageTotals()].add(bucket.totals)
        }
        return result
    }
}

struct UsageLimitAccount: Equatable {
    struct Reset: Equatable {
        let label: String?
        let description: String?
        let count: Int
        let expiresAt: Date?
        let target: UsageResetTarget?
    }

    struct Window: Equatable {
        let id: String?
        let kind: String?
        let label: String
        let remaining: Double
        let resetsAt: Date?

        var used: Double { 100 - remaining }
        var previewLabel: String {
            kind == "weekly" && label == "Weekly" ? "Weekly · All models" : label
        }
    }

    struct Identity: Equatable {
        let email: String
        let workspaceID: String?

        init?(_ value: Wire) {
            guard let email = value["email"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            self.email = email
            workspaceID = value["workspaceId"].string
        }
    }

    struct ExternalUsage: Equatable {
        let label: String
        let url: URL

        init?(_ value: Wire) {
            guard let label = value["label"].string, let address = value["url"].string,
                  let url = URL(string: address), url.scheme == "https", url.host != nil else { return nil }
            self.label = label
            self.url = url
        }
    }

    let title: String
    let detail: String
    let driver: String
    let checkedAt: Date?
    let windows: [Window]
    let notice: String?
    let resetCredits: Int?
    let resets: [Reset]
    let identity: Identity?
    let externalUsage: ExternalUsage?

    init?(title: String, detail: String, driver: String, limits: Wire, identity: Identity? = nil, resetTarget: UsageResetTarget? = nil) {
        guard let checkedAt = limits["checkedAt"].string else { return nil }
        let external = ExternalUsage(limits["externalUsage"])
        guard limits["unavailable"]["reason"].string != "unsupported" || external != nil else { return nil }
        self.title = title
        self.detail = detail
        self.driver = Self.normalizedDriver(driver)
        self.identity = identity
        externalUsage = external
        self.checkedAt = WorkspaceStyle.date(checkedAt)
        notice = limits["unavailable"]["reason"].string.map { _ in
            limits["unavailable"]["message"].string ?? "Couldn’t refresh these limits."
        }
        let credits = limits["resetCredits"]
        resetCredits = credits["availableCount"].int
        let options = credits["options"]
        if case .provider(let instance, _) = resetTarget, case .array(let reported) = options {
            resets = reported.compactMap { option in
                guard let id = option["creditId"].string, !id.isEmpty,
                      let label = option["label"].string, !label.isEmpty,
                      let count = option["availableCount"].int, count > 0 else { return nil }
                return Reset(label: label, description: option["description"].string, count: count,
                             expiresAt: WorkspaceStyle.date(option["expiresAt"].string),
                             target: .provider(instance, creditID: id))
            }
        } else if let resetCredits, resetCredits > 0 {
            resets = [Reset(label: nil, description: nil, count: resetCredits,
                            expiresAt: WorkspaceStyle.date(credits["nextExpiresAt"].string),
                            target: options == .null ? resetTarget : nil)]
        } else {
            resets = []
        }
        windows = limits["windows"].array.compactMap { window in
            guard let label = window["label"].string, let used = window["usedPercent"].double,
                  (0...100).contains(used) else { return nil }
            return Window(id: window["id"].string, kind: window["kind"].string, label: label,
                          remaining: 100 - used, resetsAt: WorkspaceStyle.date(window["resetsAt"].string))
        }
        guard !windows.isEmpty || notice != nil || resetCredits != nil || externalUsage != nil else { return nil }
    }

    func previewWindows(modelNames: [String]) -> [Window] {
        let names = modelNames.map(Self.claudeModelTokens)
        let applicable = windows.compactMap { window -> (window: Window, shared: Int)? in
            guard window.id != "monthly_spend" else { return nil }
            guard driver == "claude" else { return (window, 1) }
            let scope: [Substring]
            if let id = window.id, id.hasPrefix("seven_day_") {
                scope = Self.claudeModelTokens(String(id.dropFirst("seven_day_".count)))
            } else if window.id == nil, window.label.hasPrefix("Weekly · ") {
                scope = Self.claudeModelTokens(String(window.label.dropFirst("Weekly · ".count)))
            } else {
                return (window, 1)
            }
            if scope == ["all", "models"] { return (window, 1) }
            guard !scope.isEmpty, names.contains(where: { $0.starts(with: scope) }) else { return nil }
            return (window, 0)
        }
        return applicable.sorted {
            ($0.shared, $0.window.remaining, $0.window.id ?? $0.window.label) <
                ($1.shared, $1.window.remaining, $1.window.id ?? $1.window.label)
        }.map(\.window)
    }

    private static func claudeModelTokens(_ name: String) -> [Substring] {
        let tokens = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return tokens.first == "claude" ? Array(tokens.dropFirst()) : tokens
    }

    static func normalizedDriver(_ driver: String) -> String {
        driver == ComposerProvider.claude.rawValue ? "claude" : driver
    }

    static func providerTitle(_ driver: String) -> String {
        switch driver {
        case "claude", "claudeAgent": "Claude"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        default: driver.capitalized
        }
    }
}

struct UsageLimitSource: Equatable {
    let id: String?
    let name: String
    let accounts: [UsageLimitAccount]
    let notice: String?

    init?(_ value: Wire) {
        guard let name = value["label"].string else { return nil }
        let sourceID = value["id"].string
        id = sourceID
        self.name = name
        accounts = value["accounts"].array.compactMap { account in
            guard let driver = account["driver"].string else { return nil }
            let accountID = account["id"].string
            let limits = account["usageLimits"]
            let target: UsageResetTarget? = if let sourceID, let accountID, let creditID = limits["resetCredits"]["nextCreditId"].string,
                                               !sourceID.isEmpty, !accountID.isEmpty, !creditID.isEmpty {
                .hub(sourceID: sourceID, accountID: accountID, creditID: creditID)
            } else { nil }
            return UsageLimitAccount(title: account["email"].string ?? accountID ?? UsageLimitAccount.providerTitle(driver),
                                     detail: [account["plan"].string, name].compactMap { $0 }.joined(separator: " · "),
                                     driver: driver, limits: limits, identity: UsageLimitAccount.Identity(account), resetTarget: target)
        }
        notice = value["error"].string
    }
}

enum UsageResetTarget: Equatable, Sendable {
    case provider(String, creditID: String? = nil)
    case hub(sourceID: String, accountID: String, creditID: String)

    var payload: Payload {
        switch self {
        case .provider(let id, let credit):
            var payload: Payload = ["instanceId": .string(id)]
            if let credit { payload["creditId"] = .string(credit) }
            return payload
        case .hub(let source, let account, let credit):
            return ["sourceId": .string(source), "accountId": .string(account), "creditId": .string(credit)]
        }
    }
}

struct UsageResetResult {
    let message: String
    let warning: Bool

    init(_ result: Wire) throws {
        if let warning = result["warning"].string {
            message = warning
            self.warning = true
            return
        }
        switch result["outcome"].string {
        case "reset": message = "Rate limits reset."; warning = false
        case "nothingToReset": message = "Nothing to reset right now."; warning = false
        case "noCredit": message = "No reset credit is available."; warning = true
        case "alreadyRedeemed": message = "That credit was already redeemed."; warning = true
        default: throw ClientError.invalidResponse
        }
    }
}

struct UsageLimitPreview: Equatable {
    let provider: String
    let model: String?
    let account: UsageLimitAccount?
    let windows: [UsageLimitAccount.Window]
}
