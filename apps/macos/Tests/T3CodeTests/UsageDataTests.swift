import Foundation
import Testing
@testable import T3Code

struct UsageDataTests {
    @Test func dailyUsageGroupsModelsAndCountsReasoningOnce() throws {
        let now = try #require(WorkspaceStyle.date("2026-03-09T07:30:00Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let window = UsageWindow(period: .week, now: now, timeZone: zone)
        #expect(window.keys == (3...9).map { "2026-03-0\($0)" })
        let report = try UsageReport(.object([
            "contractVersion": .int(6),
            "buckets": .array([
                bucket(day: "2026-03-08", provider: "codex", cost: 0.125),
                bucket(day: "2026-03-09", provider: "codex", cost: 0.25),
                bucket(day: "2026-03-09", provider: "claude", cost: nil),
                bucket(day: "2026-03-02", provider: "codex", cost: 99),
            ]),
        ]), window: window)
        let all = report.breakdown(provider: nil)
        #expect(all.total.cost == 0.375)
        #expect(all.total.tokens == 78)
        #expect(all.total.unpriced == 1)
        #expect(all.models.count == 2)
        #expect(all.intervals["2026-03-09"]?.tokens == 52)
        let codex = report.breakdown(provider: "codex")
        #expect(codex.total.tokens == 52)
        #expect(codex.total.unpriced == 0)
        #expect(codex.models.count == 1)
    }

    @Test func pastDayUsesExactRollingHoursAcrossDaylightSaving() throws {
        let now = try #require(WorkspaceStyle.date("2026-03-08T10:22:59Z"))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let window = UsageWindow(period: .day, now: now, timeZone: zone)
        #expect(window.payload["sinceDay"] == .string("2026-03-07"))
        #expect(window.payload["untilDay"] == .string("2026-03-08"))
        #expect(window.payload["sinceTime"] == .string("2026-03-07T10:22:00.000Z"))
        #expect(window.payload["untilTime"] == .string("2026-03-08T10:22:00.000Z"))
        #expect(window.keys.count == 24)
        #expect(window.intervalKey(for: .object(["hourStart": .string("2026-03-08T09:22:00Z")])) == window.keys.last)
        #expect(window.intervalKey(for: .object(["hourStart": .string("2026-03-08T10:22:00Z")])) == nil)
    }

    @Test func usageLimitUsesRemainingPercentAndRetainsProbeFailure() throws {
        let account = try #require(UsageLimitAccount(title: "Claude", detail: "Pro", driver: "claude", limits: .object([
            "checkedAt": .string("2026-11-10T10:00:00Z"),
            "windows": .array([.object([
                "label": .string("Weekly"), "usedPercent": .double(73.5), "resetsAt": .string("2026-11-11T10:00:00Z"),
            ])]),
            "unavailable": .object(["reason": .string("probeFailed"), "message": .string("Refresh failed")]),
        ])))
        #expect(account.windows.first?.remaining == 26.5)
        #expect(account.windows.first?.resetsAt == WorkspaceStyle.date("2026-11-11T10:00:00Z"))
        #expect(account.notice == "Refresh failed")
        let failedProvider = try #require(Provider(.object([
            "instanceId": .string("codex"), "driver": .string("codex"), "enabled": .bool(true),
            "installed": .bool(false), "status": .string("error"),
            "checkedAt": .string("2026-11-10T10:00:00Z"), "message": .string("Codex CLI not found"),
        ])))
        #expect(failedProvider.usageLimit?.notice == "Codex CLI not found")
        #expect(failedProvider.usageLimit?.windows.isEmpty == true)
        let shared = try #require(UsageLimitAccount(title: "Codex", detail: "ChatGPT", driver: "codex", limits: .object([
            "checkedAt": .string("2026-11-10T10:00:00Z"), "windows": .array([]),
            "unavailable": .object(["reason": .string("unsupported"), "message": .string("Open ChatGPT usage settings")]),
            "externalUsage": .object(["label": .string("ChatGPT usage"), "url": .string("https://chatgpt.com/#settings/Usage")]),
        ])))
        #expect(shared.windows.isEmpty)
        #expect(shared.externalUsage?.url.absoluteString == "https://chatgpt.com/#settings/Usage")
    }

    @Test func quotaPreviewShowsOnlySharedAndApplicableModelWindows() throws {
        func window(_ id: String, label: String, used: Int) -> Wire {
            .object(["id": .string(id), "kind": .string("weekly"), "label": .string(label), "usedPercent": .int(used)])
        }
        let account = try #require(UsageLimitAccount(title: "Claude", detail: "Max", driver: "claudeAgent", limits: .object([
            "checkedAt": .string("2026-11-10T10:00:00Z"), "windows": .array([
                window("seven_day", label: "Weekly", used: 76),
                window("seven_day_opus", label: "Weekly · Opus", used: 63),
                window("seven_day_sonnet", label: "Weekly · Sonnet", used: 90),
                window("monthly_spend", label: "Monthly spend", used: 98),
            ]),
        ])))
        let windows = account.previewWindows(modelNames: ["claude-opus-5-5"])
        #expect(windows.map(\.previewLabel) == ["Weekly · Opus", "Weekly · All models"])
        #expect(windows.map(\.used) == [63, 76])
        #expect(account.previewWindows(modelNames: []).map(\.id) == ["seven_day"])
    }

    @Test func quotaPreviewNeverBorrowsAnotherWorkspaceSubscription() throws {
        let provider = try #require(Provider(.object([
            "instanceId": .string("work"), "driver": .string("claudeAgent"), "enabled": .bool(true),
            "auth": .object(["email": .string("shared@example.test"), "workspaceId": .string("work")]),
        ])))
        let limits: Wire = .object([
            "checkedAt": .string("2026-11-10T10:00:00Z"), "windows": .array([.object([
                "id": .string("seven_day"), "kind": .string("weekly"), "label": .string("Weekly"), "usedPercent": .int(43),
            ])]),
        ])
        func source(_ workspace: String) throws -> UsageLimitSource {
            try #require(UsageLimitSource(.object(["label": .string(workspace), "accounts": .array([.object([
                "driver": .string("claudeAgent"), "email": .string("shared@example.test"), "workspaceId": .string(workspace),
                "usageLimits": limits,
            ])])])))
        }
        let catalog = ComposerModels(providers: [provider])
        let selection: Wire = .object(["instanceId": .string("work"), "model": .string("claude-opus")])
        let other = try source("personal")
        #expect(catalog.usageLimitPreview(for: selection, sources: [other])?.windows.isEmpty == true)
        let work = try source("work")
        #expect(catalog.usageLimitPreview(for: selection, sources: [other, work])?.windows.first?.used == 43)
    }

    @Test func codexQuotaUsesItsHubWhenOnlyOneWorkspaceMatchesTheLogin() throws {
        func provider(_ id: String, workspace: String?) throws -> Provider {
            var auth: Payload = ["email": .string("shared@example.test")]
            auth["workspaceId"] = workspace.map(Wire.string)
            return try #require(Provider(.object([
                "instanceId": .string(id), "driver": .string("codex"), "enabled": .bool(true), "auth": .object(auth),
                "usageLimits": .object([
                    "checkedAt": .string("2026-11-10T10:00:00Z"), "windows": .array([]),
                    "unavailable": .object(["reason": .string("probeFailed")]),
                ]),
            ])))
        }
        let source = try #require(UsageLimitSource(.object([
            "id": .string("hub"), "label": .string("Fixture"),
            "accounts": .array([.object([
                "id": .string("account"), "driver": .string("codex"), "email": .string("shared@example.test"),
                "workspaceId": .string("work"), "usageLimits": .object([
                    "checkedAt": .string("2026-11-10T10:00:00Z"),
                    "windows": .array([.object(["id": .string("weekly"), "label": .string("Weekly"), "usedPercent": .int(61)])]),
                ]),
            ])]),
        ])))
        let login = try provider("codex", workspace: nil)
        let selection: Wire = .object(["instanceId": .string("codex"), "model": .string("fixture")])
        let catalog = ComposerModels(providers: [login])
        #expect(catalog.usageLimitPreview(for: selection, sources: [source])?.windows.first?.used == 61)
        #expect(catalog.usageLimitAccounts(sources: [source]).count == 1)
        let personal = try provider("codex-personal", workspace: "personal")
        let ambiguous = ComposerModels(providers: [login, personal])
        #expect(ambiguous.usageLimitPreview(for: selection, sources: [source])?.windows.isEmpty == true)
        #expect(ambiguous.usageLimitAccounts(sources: [source]).count == 3)
    }

    private func bucket(day: String, provider: String, cost: Double?) -> Wire {
        .object([
            "day": .string(day), "provider": .string(provider), "model": .string("fixture-model"),
            "records": .int(1), "costUsd": .double(cost ?? 0), "unpricedRecords": .int(cost == nil ? 1 : 0),
            "totals": .object([
                "uncachedInputTokens": .int(10), "cachedInputTokens": .int(8), "cacheCreationTokens": .int(2),
                "outputTokens": .int(6), "reasoningTokens": .int(4),
            ]),
        ])
    }
}
