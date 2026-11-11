import Foundation
import Testing
@testable import T3Code

struct ScheduledTaskTests {
    @Test func editingANamePreservesScheduleAndProviderOptions() throws {
        let schedule: Wire = .object(["type": .string("fixed_time"), "timeOfDay": .string("9:05"), "weekdays": .array([])])
        let task = try #require(task(schedule: schedule))
        var draft = ScheduledTaskDraft(task: task, project: "", model: .null)
        draft.title = "Revised name"
        let payload = try draft.encode(id: "new")
        #expect(payload["schedule"] == schedule)
        #expect(payload["modelSelection"] == task.model)
        #expect(payload["id"] == .string("task"))
        #expect(payload["requireExisting"] == .bool(true))
    }

    @Test func savedOneTimeScheduleKeepsItsExactInstantWhenUntouched() throws {
        let time = "2027-11-07T01:30:14-04:00"
        let schedule: Wire = .object(["type": .string("once"), "runAt": .string(time)])
        var draft = ScheduledTriggerDraft(schedule)
        #expect(try draft.encode(original: schedule) == schedule)
        draft.date.addTimeInterval(60)
        draft.dateChanged = true
        let changed = try draft.encode(original: schedule)
        #expect(changed["runAt"].string == "2027-11-07T05:31:14.000Z")
    }

    @Test func webhookEditRetainsSecretAndCanClearStoredFilters() throws {
        let filter: Wire = .object(["path": .string("body.action"), "op": .string("equals"), "value": .string("opened")])
        let original: Wire = .object(["type": .string("webhook"), "filters": .array([filter]), "signature": .object([
            "header": .string("x-hub-signature-256"), "encoding": .string("hex"), "prefix": .string("sha256="),
        ])])
        var draft = ScheduledTriggerDraft(original)
        let unchanged = try draft.encode(original: original, hasStoredSecret: true)
        #expect(unchanged["signature"]["secret"] == .null)
        #expect(unchanged["filters"] == .null)
        draft.filters = []
        #expect(try draft.encode(original: original, hasStoredSecret: true)["filters"] == .array([]))
        #expect(throws: ClientError.self) { try draft.encode(original: original, hasStoredSecret: false) }
        draft.replayKey = "plain text"
        #expect(throws: ClientError.self) { try draft.encode(original: original, hasStoredSecret: true) }
    }

    @Test func legacyBoundTaskContinuesUntilSwitchedToNewThreads() throws {
        let task = try #require(task(schedule: .object(["type": .string("interval"), "everyMs": .int(90_000)]), thread: "bound"))
        var draft = ScheduledTaskDraft(task: task, project: "", model: .null)
        #expect(task.threadMode == .continueThread)
        #expect(try draft.encode(id: "unused")["threadId"] == .string("bound"))
        draft.threadMode = .newThread
        #expect(try draft.encode(id: "unused")["threadId"] == .null)
    }

    @Test func intervalsUseTheServerMinimumAndRoundFractionalMinutes() throws {
        var draft = ScheduledTriggerDraft()
        draft.kind = .interval
        draft.minutes = "0.5"
        #expect(throws: ClientError.self) { try draft.encode() }
        draft.minutes = "1,5"
        #expect(try draft.encode()["everyMs"] == .int(90_000))
    }

    private func task(schedule: Wire, thread: String? = nil) -> ScheduledTask? {
        ScheduledTask(.object([
            "id": .string("task"), "title": .string("Task"), "prompt": .string("Prompt"), "projectId": .string("project"),
            "enabled": .bool(true), "schedule": schedule, "threadId": thread.map(Wire.string) ?? .null,
            "workspaceStrategy": .object(["type": .string("root")]),
            "modelSelection": .object(["instanceId": .string("provider"), "model": .string("model"), "options": .object(["effort": .string("high")])]),
        ]))
    }
}
