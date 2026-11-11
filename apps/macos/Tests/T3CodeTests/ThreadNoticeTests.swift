import Testing
@testable import T3Code

struct ThreadNoticeTests {
    @Test func onlyNewSettledCompletionsNotify() {
        var shell = Shell()
        #expect(shell.snapshot([thread("completed", at: 1)]).isEmpty)
        #expect(shell.update(thread("running")).isEmpty)
        #expect(shell.update(thread("completed", at: 2)) == [.present(notice(.completed))])
        #expect(shell.snapshot([thread("completed", at: 2)]).isEmpty)
        #expect(shell.update(thread("completed", at: 1)).isEmpty)
        #expect(shell.update(thread("completed", at: 3, extra: ["latestRunStopRequested": .bool(true)])).isEmpty)
        #expect(shell.update(thread("completed", at: 3)).isEmpty)
        #expect(shell.update(thread("completed", at: 4, extra: [
            "pendingBackgroundTasks": .array([.object(["kind": .string("background_task")])]),
        ])).isEmpty)
        #expect(shell.update(thread("completed", at: 4)) == [.present(notice(.completed))])
    }

    @Test func newRequestsNotifyOnceAndResolveIndependentlyOfCompletions() {
        var shell = Shell()
        #expect(shell.snapshot([thread("running", extra: request("command", id: "existing"))]).isEmpty)
        #expect(shell.update(thread("running", extra: request("command", id: "existing"))).isEmpty)
        #expect(shell.update(thread("running", extra: request("command", id: "second"))) == [.present(notice(.approval))])
        #expect(shell.update(thread("running", extra: request("user_input", id: "question"))) == [.present(notice(.input))])
        #expect(shell.update(thread("running", extra: request("auth_refresh", id: "auth"))) == [.dismiss(target())])
        #expect(shell.update(thread("running", extra: ["pendingGuestMessageCount": .int(1)])) == [.present(notice(.guest))])
        #expect(shell.update(thread("running", extra: ["pendingGuestMessageCount": .int(2)])).isEmpty)
        #expect(shell.update(thread("completed", at: 5)) == [.present(notice(.completed))])
        #expect(shell.update(thread("failed", extra: ["lastErrorClass": .string("usage_limit")])) == [.present(notice(.limited))])
        #expect(shell.update(thread("failed")) == [.present(notice(.failed))])
        #expect(shell.update(thread("failed")).isEmpty)
        #expect(shell.update(thread("failed"), location: "archive") == [.dismiss(target())])
        #expect(shell.update(thread("failed")).isEmpty)
        #expect(shell.snapshot([]) == [.dismiss(target())])
    }

    @Test func sideChatsRouteTheirRequestsAndNativeSubagentsLeaveAlertsWithTheParent() {
        let side: Payload = ["lineage": .object(["parentThreadId": .string("thread"), "sideChat": .bool(true)])]
        let subagent: Payload = [
            "lineage": .object(["parentThreadId": .string("thread"), "relationshipToParent": .string("subagent")]),
            "creationSource": .string("provider"),
        ]
        var shell = Shell()
        #expect(shell.snapshot([thread("running"), thread("running", id: "side", extra: side), thread("running", id: "child", extra: subagent)]).isEmpty)
        #expect(shell.update(thread("completed", at: 2, id: "side", extra: side)).isEmpty)
        #expect(shell.update(thread("running", id: "side", extra: side.merging(request("user_input", id: "question")) { _, next in next })) ==
                [.present(notice(.input, id: "side"))])
        #expect(shell.update(thread("running", id: "child", extra: subagent.merging(request("command", id: "approve")) { _, next in next })).isEmpty)
    }

    private struct Shell {
        var data = WorkspaceData()
        var tracker = ThreadNoticeTracker()
        var sequence = 0

        mutating func snapshot(_ threads: [Wire]) -> [ThreadNoticeTracker.Change] {
            sequence += 1
            data.apply(.object(["kind": .string("snapshot"), "snapshot": .object([
                "snapshotSequence": .int(sequence), "threads": .array(threads),
            ])]))
            return tracker.receive(.snapshot, environmentID: "host", data: data)
        }

        mutating func update(_ thread: Wire, location: String = "active") -> [ThreadNoticeTracker.Change] {
            sequence += 1
            data.apply(.object(["kind": .string("thread.updated"), "sequence": .int(sequence), "location": .string(location), "thread": thread]))
            return tracker.receive(.threads([thread["id"].string ?? ""]), environmentID: "host", data: data)
        }
    }

    private func thread(_ status: String, at second: Int? = nil, id: String = "thread", extra: Payload = [:]) -> Wire {
        let fields: Payload = [
            "id": .string(id), "title": .string("Conversation"), "projectId": .string("project"),
            "status": .string(status), "latestRunId": .string("run"),
            "latestRunCompletedAt": second.map { .string("2026-11-11T10:00:0\($0).000Z") } ?? .null,
        ]
        return .object(fields.merging(extra) { _, next in next })
    }

    private func request(_ kind: String, id: String) -> Payload {
        ["pendingRuntimeRequest": .object(["id": .string(id), "kind": .string(kind)])]
    }

    private func target(_ id: String = "thread") -> ThreadNotice.Target { .init(environmentID: "host", threadID: id) }

    private func notice(_ kind: ThreadNotice.Kind, id: String = "thread") -> ThreadNotice {
        .init(target: target(id), title: "Conversation", kind: kind)
    }
}
