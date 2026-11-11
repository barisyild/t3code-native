import Foundation
import Testing
@testable import T3Code

struct ThreadRelationshipTests {
    @Test func directLineageWinsOverTransfersAndRetainsSeparateEnvironmentTargets() throws {
        let current = try thread("current", parent: "other", kind: "fork", extra: [
            "forkedFrom": .object(["type": .string("run"), "threadId": .string("parent")]),
            "delegatedFrom": .object(["environmentId": .string("remote"), "threadId": .string("parent"),
                                      "title": .string("Remote source")]),
        ])
        let parent = try thread("parent", parent: nil)
        let child = try thread("child", parent: current.id, kind: "subagent")
        let side = try thread("side", parent: current.id, kind: "fork", side: true)
        var projection = ThreadRelationshipProjection()
        projection.apply("subagent.updated", .object([
            "id": .string("agent"), "threadId": .string(current.id), "childThreadId": .string(child.id),
            "status": .string("running"), "origin": .string("app_owned"),
        ]))
        for id in [parent.id, child.id, side.id] {
            projection.apply("context-transfer.created", .object([
                "id": .string(id), "type": .string("fork"), "status": .string("resolved"),
                "sourceThreadId": .string(current.id), "targetThreadId": .string(id),
            ]))
        }
        let rows = ThreadRelationships.rows(for: current, threads: [parent.id: parent, child.id: child, side.id: side],
                                             projection: projection)
        #expect(rows.filter { $0.kind == .parent }.count == 2)
        #expect(rows.first { $0.target?.environmentID == "remote" }?.title == "Remote source")
        #expect(rows.first { $0.target?.threadID == parent.id && $0.target?.environmentID == nil }?.title == parent.title)
        #expect(rows.filter { $0.target?.threadID == child.id }.map(\.kind) == [.activeAgent])
        #expect(rows.filter { $0.target?.threadID == side.id }.map(\.kind) == [.sideChat])
        #expect(current.mergeBackTargetID == parent.id)
    }

    @Test func missingAgentConversationKeepsResultAndRetainsDeduplicatedBodies() throws {
        let current = try thread("current", parent: nil)
        var projection = ThreadRelationshipProjection()
        let base: Payload = ["id": .string("agent"), "threadId": .string(current.id), "childThreadId": .string("deleted"),
                             "status": .string("completed"), "origin": .string("app_owned")]
        projection.apply("subagent.updated", .object(base.merging(["prompt": .string("Review layout"), "result": .string("Done")]) { _, new in new }))
        projection.apply("subagent.updated", .object(base.merging(["promptOmitted": .bool(true), "resultOmitted": .bool(true)]) { _, new in new }))
        let rows = ThreadRelationships.rows(for: current, threads: [:], projection: projection, unavailable: ["deleted"])
        let row = try #require(rows.first)
        #expect(row.kind == .previousAgent)
        #expect(row.target == nil)
        #expect(row.subagent?.prompt == "Review layout")
        #expect(row.subagent?.result == "Done")
    }

    @Test func nestedWorkSurfacesThroughItsListedParentAndNativeChildrenAreReadOnly() throws {
        let parent = try thread("root", parent: nil)
        let child = try thread("child", parent: parent.id, kind: "subagent")
        let nested = try thread("native", parent: child.id, kind: "subagent", extra: [
            "creationSource": .string("provider"), "activeRunId": .string("running"),
        ])
        let orphan = try thread("orphan", parent: "missing", kind: "subagent")
        var data = WorkspaceData()
        data.apply(.object(["kind": .string("snapshot"), "snapshot": .object([
            "snapshotSequence": .int(1),
            "threads": .array([
                shell(parent.id, parent: nil), shell(child.id, parent: parent.id, kind: "subagent"),
                shell(nested.id, parent: child.id, kind: "subagent", extra: ["activeRunId": .string("running")]),
                shell(orphan.id, parent: "missing", kind: "subagent"),
            ]),
        ])]))
        #expect(data.isListed(parent))
        #expect(!data.isListed(child))
        #expect(data.isListed(orphan))
        #expect(nested.isProviderNativeSubagent)
        #expect(!child.isProviderNativeSubagent)
        #expect(data.listedActivityParents(for: data.threads) == ["root", "child"])
    }

    private func shell(_ id: String, parent: String?, kind: String? = nil, side: Bool = false, extra: Payload = [:]) -> Wire {
        var lineage: Payload = ["sideChat": .bool(side)]
        lineage["parentThreadId"] = parent.map(Wire.string)
        lineage["relationshipToParent"] = kind.map(Wire.string)
        let base: Payload = ["id": .string(id), "title": .string("Title " + id), "projectId": .string("project"), "lineage": .object(lineage)]
        return .object(base.merging(extra) { _, new in new })
    }

    private func thread(_ id: String, parent: String?, kind: String? = nil, side: Bool = false, extra: Payload = [:]) throws -> ThreadSummary {
        try #require(ThreadSummary(shell(id, parent: parent, kind: kind, side: side, extra: extra)))
    }
}
