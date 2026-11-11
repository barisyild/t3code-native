import Testing
@testable import T3Code

struct ThreadRewindTests {
    @Test func targetUsesThePreviousVisibleRunAndItsRootCheckpoint() throws {
        let projection = fixture()
        let entry = try #require(TimelineEntry(row: projection["visibleTurnItems"].array.last!))
        let plan = try ThreadRewind.prepare(projection, message: entry)
        #expect(plan.turnCount == 1)
        #expect(plan.checkpointID == "first-checkpoint")
        #expect(plan.scopeID == "root")
        #expect(plan.witnessRunID == "fifth")
        #expect(plan.text == "Edit this prompt")
        #expect(plan.attachments.first?["id"].string == "saved-attachment")
        #expect(plan.canRestoreFiles)
        let inherited = try #require(TimelineEntry(row: projection["visibleTurnItems"].array[1]))
        #expect(throws: ClientError.self) { try ThreadRewind.prepare(projection, message: inherited) }
    }

    @Test func completionRequiresTheProviderHeadAndTheRolledBackSuffix() throws {
        let projection = fixture()
        let entry = try #require(TimelineEntry(row: projection["visibleTurnItems"].array.last!))
        let plan = try ThreadRewind.prepare(projection, message: entry)
        var state = ThreadRewind.State()
        state.load(projection)
        #expect(state.outcome(for: plan, requestID: "request") == nil)
        state.apply("provider-thread.updated", .object(["id": .string("provider"), "lastRunOrdinal": .int(1)]))
        #expect(state.outcome(for: plan, requestID: "request") == nil)
        state.apply("run.updated", .object(["id": .string("fifth"), "status": .string("rolled_back")]))
        guard case .success? = state.outcome(for: plan, requestID: "request") else {
            Issue.record("Rewind completion was not recognized")
            return
        }
        state.apply("thread.metadata-updated", .object(["rollbackFailure": .object([
            "requestId": .string("other-request"), "message": .string("Old failure"),
        ])]))
        guard case .success? = state.outcome(for: plan, requestID: "request") else {
            Issue.record("An unrelated failure replaced the completed rewind")
            return
        }
        state.apply("thread.metadata-updated", .object(["rollbackFailure": .object([
            "requestId": .string("request"), "message": .string("Restore failed"),
        ])]))
        guard case .failure? = state.outcome(for: plan, requestID: "request") else {
            Issue.record("The matching rewind failure was ignored")
            return
        }
    }

    @Test func liveRollbackRemovesLocalMessagesAndStaleChangeCounts() throws {
        let projection = fixture()
        var detail = ThreadDetail()
        detail.apply(.object(["kind": .string("snapshot"), "snapshotSequence": .int(1), "projection": projection]))
        #expect(detail.checkpointCount == 5)
        detail.apply(event("run.updated", .object(["id": .string("fifth"), "status": .string("rolled_back")]), sequence: 2))
        detail.apply(event("checkpoint.captured", .object([
            "id": .string("fifth-checkpoint"), "status": .string("stale"), "appRunOrdinal": .int(5),
        ]), sequence: 3))
        #expect(detail.timeline.map(\.id) == ["first-prompt", "inherited"])
        #expect(detail.checkpointCount == 1)
        let inherited = try #require(detail.timeline.last)
        #expect(!inherited.isLocal)
        #expect(!inherited.canRewind)
    }

    @Test @MainActor func restoredDraftKeepsExistingContentAndReusesSavedAttachments() throws {
        let projection = fixture()
        let entry = try #require(TimelineEntry(row: projection["visibleTurnItems"].array.last!))
        let plan = try ThreadRewind.prepare(projection, message: entry)
        let selected: Wire = .object(["instanceId": .string("claude"), "model": .string("opus")])
        var draft = ComposerView.Draft(text: "Keep my pending prompt", model: selected, freshContext: true)
        draft.retainedAttachments = plan.attachments
        let restored = try draft.restoring(plan)
        #expect(restored.text == "Keep my pending prompt\n\nEdit this prompt")
        #expect(restored.model == selected)
        #expect(restored.freshContext)
        #expect(restored.retainedAttachments.count == 1)
        #expect(restored.retainedContextRecords.map { $0["kind"].string } == ["preview-annotation", "image"])
        #expect(restored.retainedContextRecords.first?["comment"].string == "Keep this label.")
        var attachmentOnly = ComposerView.Draft()
        attachmentOnly.retainedAttachments = plan.attachments
        #expect(attachmentOnly.outgoingText == QueuedMessage.attachmentOnlyText)
        var full = ComposerView.Draft()
        full.retainedAttachments = (0..<100).map { .object(["id": .string("pending-\($0)")]) }
        #expect(throws: ClientError.self) { try full.restoring(plan) }
    }

    @Test func threadStartCanCompleteWithANewRootProviderThread() throws {
        let projection = fixture()
        let first = try #require(TimelineEntry(row: projection["visibleTurnItems"].array.first!))
        let plan = try ThreadRewind.prepare(projection, message: first)
        #expect(plan.turnCount == 0)
        #expect(plan.checkpointID == "baseline")
        var state = ThreadRewind.State()
        state.load(projection)
        state.apply("run.updated", .object(["id": .string(plan.witnessRunID), "status": .string("rolled_back")]))
        #expect(state.outcome(for: plan, requestID: "request") == nil)
        state.apply("provider-thread.updated", .object([
            "id": .string("fresh-provider"), "appThreadId": .string(plan.threadID),
            "providerInstanceId": .string(plan.providerInstanceID), "ownerNodeId": .null, "lastRunOrdinal": .null,
        ]))
        guard case .success? = state.outcome(for: plan, requestID: "request") else {
            Issue.record("The new root conversation did not complete the rewind to thread start")
            return
        }
    }

    private func event(_ type: String, _ payload: Wire, sequence: Int) -> Wire {
        .object(["kind": .string("event"), "sequence": .int(sequence),
                 "event": .object(["type": .string(type), "payload": payload])])
    }

    private func fixture() -> Wire {
        func run(_ id: String, ordinal: Int, status: String = "completed") -> Wire {
            .object(["id": .string(id), "ordinal": .int(ordinal), "status": .string(status),
                     "providerThreadId": .string("provider")])
        }
        func prompt(_ id: String, runID: String, ordinal: Int, local: Bool = true) -> Wire {
            .object(["visibility": .string(local ? "local" : "inherited"), "sourceThreadId": .string(local ? "thread" : "source"),
                     "item": .object([
                        "id": .string(id), "threadId": .string(local ? "thread" : "source"), "runId": .string(runID),
                        "messageId": .string(id + "-message"), "ordinal": .int(ordinal), "type": .string("user_message"),
                        "inputIntent": .string("turn_start"), "text": .string("Preview"),
                     ])])
        }
        func checkpoint(_ id: String, count: Wire, scope: String = "root") -> Wire {
            .object(["id": .string(id), "scopeId": .string(scope), "status": .string("ready"),
                     "appRunOrdinal": count, "ordinalWithinScope": count == .null ? .int(0) : count])
        }
        let annotation = BrowserRegionAnnotation(address: nil, pageTitle: "Fixture", comment: "Keep this label.")
        let image: Wire = .object(["id": .string("saved-attachment"), "type": .string("image"),
                                   "name": .string(annotation.fileName), "mimeType": .string("image/png"), "sizeBytes": .int(400)])
        let records = annotation.records(for: image)
        let text = BrowserAnnotationContext.addingReferences(to: "Edit this prompt", records: records)
        return .object([
            "thread": .object(["id": .string("thread"), "activeProviderThreadId": .string("provider"),
                                "worktreePath": .string("/isolated/worktree")]),
            "runs": .array([run("first", ordinal: 1), run("second", ordinal: 2, status: "rolled_back"), run("fifth", ordinal: 5)]),
            "visibleTurnItems": .array([
                prompt("first-prompt", runID: "first", ordinal: 1),
                prompt("inherited", runID: "fifth", ordinal: 2, local: false),
                prompt("fifth-prompt", runID: "fifth", ordinal: 5),
            ]),
            "messages": .array([.object([
                "id": .string("fifth-prompt-message"), "role": .string("user"), "text": .string(text),
                "attachments": .array([image]),
                "context": BrowserAnnotationContext.messageContext(records),
            ])]),
            "providerThreads": .array([.object([
                "id": .string("provider"), "providerSessionId": .string("session"), "providerInstanceId": .string("codex"),
                "lastRunOrdinal": .int(5),
            ])]),
            "providerSessions": .array([.object([
                "id": .string("session"), "capabilities": .object([
                    "checkpointing": .object(["providerCanRollbackConversation": .bool(true)]),
                ]),
            ])]),
            "checkpointScopes": .array([
                .object(["id": .string("root"), "threadId": .string("thread"), "kind": .string("root_run")]),
                .object(["id": .string("child"), "threadId": .string("thread"), "kind": .string("subagent")]),
            ]),
            "checkpoints": .array([
                checkpoint("baseline", count: .null),
                checkpoint("first-checkpoint", count: .int(1)), checkpoint("fifth-checkpoint", count: .int(5)),
                checkpoint("nested-checkpoint", count: .int(1), scope: "child"),
            ]),
        ])
    }
}
