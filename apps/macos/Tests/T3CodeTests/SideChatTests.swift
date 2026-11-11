import Testing
@testable import T3Code

struct SideChatTests {
    @Test func sideChatCommandConsumesOnlyTheLeadingCommandAndKeepsMultilinePrompt() {
        #expect(SideChatCommand.prompt(in: "  /BTW\nFirst line\nSecond line  ") == "First line\nSecond line")
        #expect(SideChatCommand.prompt(in: "/side") == "")
        #expect(SideChatCommand.prompt(in: "/sideways") == nil)
        #expect(SideChatCommand.prompt(in: "Write about /side") == nil)
    }

    @Test func onlyProviderFinishedRepliesCanBeBroughtBack() {
        var side = ThreadDetail()
        side.apply(.object(["kind": .string("snapshot"), "snapshotSequence": .int(5),
                            "projection": .object(["runs": .array([run("older", 1, "completed"), run("newer", 2, "running")])])]))
        #expect(side.mergeBackRunID == nil)
        side.apply(event("run.updated", sequence: 6, value: run("newer", 2, "waiting")))
        #expect(side.mergeBackRunID == "newer")
        side.apply(event("run.updated", sequence: 5, value: run("newer", 2, "running")))
        #expect(side.mergeBackRunID == "newer")
        side.apply(event("run.updated", sequence: 7, value: run("newer", 2, "failed")))
        #expect(side.mergeBackRunID == "older")
    }

    @Test func contextFromASideChatRemainsPendingUntilTheMainRunConsumesIt() {
        var detail = ThreadDetail()
        let transfer: Payload = ["id": .string("merge"), "sourceThreadId": .string("side"), "targetThreadId": .string("main"),
                                 "type": .string("merge_back")]
        let pending = Wire.object(transfer.merging(["status": .string("pending")]) { _, new in new })
        detail.apply(event("context-transfer.created", sequence: 1, value: pending))
        #expect(detail.pendingMergeBacks["merge"]?.sourceID == "side")
        detail.apply(event("context-transfer.updated", sequence: 2,
                           value: .object(transfer.merging(["status": .string("resolved")]) { _, new in new })))
        #expect(detail.pendingMergeBacks.isEmpty)
    }

    @Test func parentListsOnlyItsOwnSideChatsAndRemovesDeletedChildren() {
        func shell(_ id: String, parent: String, side: Bool) -> Wire {
            .object(["id": .string(id), "title": .string(id), "projectId": .string("repo"),
                     "lineage": .object(["parentThreadId": .string(parent), "sideChat": .bool(side)])])
        }
        var data = WorkspaceData()
        data.apply(.object(["kind": .string("snapshot"), "snapshot": .object([
            "snapshotSequence": .int(4), "threads": .array([shell("side", parent: "main", side: true),
                shell("fork", parent: "main", side: false), shell("other", parent: "unrelated", side: true)]),
        ])]))
        #expect(data.sideChats(of: "main").map(\.id) == ["side"])
        data.apply(.object(["kind": .string("thread.removed"), "threadId": .string("side"), "sequence": .int(5)]))
        #expect(data.sideChats(of: "main").isEmpty)
        #expect(data.threads["fork"] != nil)
    }

    private func run(_ id: String, _ ordinal: Int, _ status: String) -> Wire {
        .object(["id": .string(id), "ordinal": .int(ordinal), "status": .string(status)])
    }

    private func event(_ type: String, sequence: Int, value: Wire) -> Wire {
        .object(["kind": .string("event"), "sequence": .int(sequence),
                 "event": .object(["type": .string(type), "payload": value])])
    }
}
