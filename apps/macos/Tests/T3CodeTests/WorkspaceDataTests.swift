import Testing
@testable import T3Code

struct WorkspaceDataTests {
    @Test func messageBodyDeduplicationPreservesTranscriptText() {
        var detail = ThreadDetail()
        let message: Wire = .object(["id": .string("message"), "text": .string("A complete prompt")])
        let item: Wire = .object([
            "id": .string("turn-item"), "threadId": .string("thread"), "ordinal": .int(1),
            "type": .string("user_message"), "messageId": .string("message"),
            "text": .string(""), "textOmitted": .bool(true),
        ])
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(1),
            "projection": .object([
                "messages": .array([message]),
                "visibleTurnItems": .array([.object(["item": item, "visibility": .string("local")])]),
            ]),
        ]))
        #expect(detail.timeline.first?.value["text"].string == "A complete prompt")
        detail.apply(.object([
            "kind": .string("event"), "sequence": .int(2),
            "event": .object(["type": .string("message.updated"), "payload": .object([
                "id": .string("message"), "text": .string("Edited prompt"),
            ])]),
        ]))
        detail.apply(.object([
            "kind": .string("event"), "sequence": .int(3),
            "event": .object(["type": .string("turn-item.updated"), "payload": item]),
        ]))
        #expect(detail.timeline.first?.value["text"].string == "Edited prompt")
    }

    @Test func repositoryIdentityRefreshPreservesProjectsAndThreads() {
        let project: Wire = .object(["id": .string("project"), "title": .string("Project"), "workspaceRoot": .string("/work/project")])
        let other: Wire = .object(["id": .string("other"), "title": .string("Other"), "workspaceRoot": .string("/work/other")])
        let thread: Wire = .object(["id": .string("thread"), "projectId": .string("project"), "title": .string("Thread")])
        var workspace = WorkspaceData()
        workspace.apply(.object([
            "kind": .string("snapshot"),
            "snapshot": .object(["snapshotSequence": .int(5), "projects": .array([project, other]), "threads": .array([thread])]),
        ]))
        workspace.apply(.object([
            "kind": .string("snapshot"), "resolvedRepositoryIdentityRoots": .array([.string("/work/project")]),
            "snapshot": .object(["snapshotSequence": .int(7), "projects": .array([project]), "threads": .array([])]),
        ]))
        #expect(Set(workspace.projects.keys) == Set(["project", "other"]))
        #expect(workspace.threads["thread"] != nil)
        #expect(workspace.sequence == 5)
    }

    @Test func pinnedProjectsLeadPickersAndArchivedProjectsRemainAvailableToRestore() {
        let base: Payload = ["id": .string("alpha"), "title": .string("Alpha"), "workspaceRoot": .string("/work/alpha")]
        let time = Wire.string("2026-10-01T00:00:00Z")
        let pinned: Wire = .object(["id": .string("zeta"), "title": .string("Zeta"), "workspaceRoot": .string("/work/zeta"), "pinnedAt": time])
        var workspace = WorkspaceData()
        workspace.apply(.object(["kind": .string("snapshot"), "snapshot": .object([
            "snapshotSequence": .int(5), "projects": .array([.object(base), pinned]),
        ])]))
        #expect(workspace.orderedProjects.map(\.id) == ["zeta", "alpha"])

        var archived = pinned.object ?? [:]
        archived["archivedAt"] = time
        workspace.apply(.object(["kind": .string("project.updated"), "sequence": .int(6), "project": .object(archived)]))
        #expect(workspace.orderedProjects.map(\.id) == ["alpha", "zeta"])
        #expect(workspace.projects["zeta"]?.archived == true)
        workspace.apply(.object(["kind": .string("project.updated"), "sequence": .int(7), "project": pinned]))
        #expect(workspace.orderedProjects.map(\.id) == ["zeta", "alpha"])
    }

    @Test func aProjectDefaultsEditKeepsOtherOverridesAndDistinguishesAutomaticFromInherit() throws {
        let legacyModel: Wire = .object(["instanceId": .string("claudeAgent"), "model": .string("claude-opus")])
        let environmentModel: Wire = .object(["instanceId": .string("codex"), "model": .string("gpt-codex")])
        let project = try #require(Project(.object([
            "id": .string("project"), "title": .string("Project"), "workspaceRoot": .string("/work/project"),
            "defaultModelSelection": legacyModel, "defaultThreadEnvMode": .string("local"), "autoPull": .bool(true),
        ])))
        let legacy = ProjectPreferences(.object(["defaultModelSelection": environmentModel]))
        #expect(legacy.value(.model, for: project) == legacyModel)
        #expect(legacy.value(.checkout, for: project) == .string("local"))

        let future: Wire = .object(["enabled": .bool(true)])
        let settings: Payload = [
            "projectSettingsFolded": .bool(true), "defaultModelSelection": environmentModel,
            "defaultThreadEnvMode": .string("worktree"), "defaultAutoPull": .bool(false),
            "projectSettingsOverrides": .object([
                project.id: .object(["defaultModelSelection": .null, "futureSetting": future]),
                "another": .object(["defaultAutoPull": .bool(true)]),
            ]),
        ]
        let stored = ProjectPreferences(.object(settings))
        #expect(stored.override(.model, for: project) == Wire.null)
        #expect(stored.value(.model, for: project) == .null)
        #expect(stored.value(.checkout, for: project) == .string("worktree"))
        #expect(stored.value(.autoPull, for: project) == .bool(false))
        let patch = stored.patch(.model, value: nil, for: project)
        #expect(patch == ["projectSettingsOverrides": .object([project.id: .object(["futureSetting": future])])])
        let inherited = ProjectPreferences(.object(settings.merging(patch) { _, next in next }))
        #expect(inherited.override(.model, for: project) == nil)
        #expect(inherited.value(.model, for: project) == environmentModel)
    }

    @Test func projectFileCheckoutIgnoresCommentsWithoutChangingQuotedText() throws {
        let config = #"""
        {
          // Keep a branch-specific project file in the repository.
          "$schema": "https://t3.codes/schema/t3.json",
          "description": "/* this is text, not a comment */",
          /* Start in an isolated checkout. */
          "defaultThreadEnvMode": "worktree",
        }
        """#
        let response: Payload = ["contents": .string(config), "exists": .bool(true), "truncated": .bool(false)]
        #expect(ProjectFileConfiguration(.object(response))?.checkout == .worktree)
        #expect(ProjectFileConfiguration(.object(response.merging(["truncated": .bool(true)]) { _, value in value })) == nil)
        #expect(ProjectFileConfiguration(.object(response.merging(["exists": .bool(false)]) { _, value in value })) == nil)
        #expect(ProjectFileConfiguration(.object(["contents": .string("{\"defaultThreadEnvMode\": nul/**/l}")])) == nil)
        #expect(ProjectFileConfiguration(.object(["contents": .string("{\"defaultThreadEnvMode\": \"unknown\"}")])) == nil)
    }

    @Test func fileCheckoutYieldsToConfiguredDefaultsAndManagedProjectRules() throws {
        let root = "/work/managed"
        let project = try #require(Project(.object([
            "id": .string("project"), "title": .string("Project"), "workspaceRoot": .string(root + "/project"),
        ])))
        let global = ProjectPreferences(.object(["defaultThreadEnvMode": .string("worktree")]))
        #expect(global.checkout(for: project, fileMode: .local, newProjectsRoot: nil, hasThreads: false) == .newWorktree(base: "HEAD"))
        #expect(global.checkout(for: project, fileMode: nil, newProjectsRoot: root, hasThreads: false) == .root())
        #expect(global.checkout(for: project, fileMode: nil, newProjectsRoot: root, hasThreads: true) == .newWorktree(base: "HEAD"))
        let projectLocal = ProjectPreferences(.object([
            "defaultThreadEnvMode": .string("worktree"),
            "projectSettingsOverrides": .object([project.id: .object(["defaultThreadEnvMode": .string("local")])]),
        ]))
        #expect(projectLocal.checkout(for: project, fileMode: .worktree, newProjectsRoot: nil, hasThreads: true) == .root())
        let inherited = ProjectPreferences()
        #expect(inherited.checkout(for: project, fileMode: .worktree, newProjectsRoot: root, hasThreads: false) == .newWorktree(base: "HEAD"))
        #expect(inherited.checkout(for: project, fileMode: nil, newProjectsRoot: nil, hasThreads: false) == .root())
    }

    @Test func archivedThreadDoesNotReappearFromOlderShellEvent() {
        let thread: Wire = .object(["id": .string("thread"), "projectId": .string("project"), "title": .string("Thread")])
        var workspace = WorkspaceData()
        workspace.apply(.object([
            "kind": .string("snapshot"),
            "snapshot": .object(["snapshotSequence": .int(5), "threads": .array([thread])]),
        ]))
        workspace.apply(.object([
            "kind": .string("thread.updated"), "sequence": .int(7), "location": .string("archive"), "thread": thread,
        ]))
        workspace.apply(.object([
            "kind": .string("thread.updated"), "sequence": .int(6), "location": .string("active"), "thread": thread,
        ]))
        #expect(workspace.threads.isEmpty)
        #expect(workspace.archived["thread"]?.archived == true)
        workspace.apply(.object([
            "kind": .string("thread.updated"), "sequence": .int(8), "location": .string("active"), "thread": thread,
        ]))
        #expect(workspace.archived.isEmpty)
        #expect(workspace.threads["thread"]?.archived == false)
    }

    @Test func sidebarActivityIncludesRunningAndWaitingThreads() throws {
        let fields: [String: Wire] = ["id": .string("thread"), "projectId": .string("project"), "title": .string("Thread")]
        let cases: [([String: Wire], Bool)] = [
            ([:], false),
            (["status": .string("queued")], true),
            (["activityRunStatus": .string("running")], true),
            (["activeRunId": .string("run")], true),
            (["pendingRuntimeRequest": .object(["kind": .string("approval")])], true),
            (["pendingGuestMessageCount": .int(1)], true),
            (["pendingBackgroundTasks": .array([.object(["kind": .string("command"), "awaited": .bool(true)])])], true),
            (["pendingBackgroundTasks": .array([.object(["kind": .string("monitor")])])], false),
            (["status": .string("running"), "archivedAt": .string("2026-10-01T00:00:00Z")], false),
        ]
        for (overrides, isActive) in cases {
            let thread = try #require(ThreadSummary(.object(fields.merging(overrides) { _, override in override })))
            #expect(thread.isActive == isActive)
        }
    }

    @Test func goalStatusFollowsTheShellAndClearsWithoutReloadingTheThread() {
        let fields: Payload = ["id": .string("thread"), "projectId": .string("project"), "title": .string("Thread")]
        var workspace = WorkspaceData()
        func update(_ goal: Wire, at sequence: Int) -> Wire {
            .object([
                "kind": .string("thread.updated"), "location": .string("active"), "sequence": .int(sequence),
                "thread": .object(fields.merging(["goal": goal]) { _, goal in goal }),
            ])
        }
        workspace.apply(update(.object(["objective": .string("Finish the port"), "status": .string("active"),
                                        "timeUsedSeconds": .int(12_510)]), at: 1))
        #expect(workspace.threads["thread"]?.goal?.status == .active)
        #expect(workspace.threads["thread"]?.goal?.progress == "3h 28m 30s")
        workspace.apply(update(.object(["objective": .string("Finish the port"), "status": .string("paused")]), at: 2))
        #expect(workspace.threads["thread"]?.goal?.status == .paused)
        workspace.apply(update(.null, at: 3))
        #expect(workspace.threads["thread"]?.goal == nil)
    }

    @Test func goalCommandsUseTheProviderThreadEvenWhenTheSelectedModelDiffers() throws {
        let codexModel: Wire = .object(["instanceId": .string("managed-codex"), "model": .string("gpt-codex")])
        let claudeModel: Wire = .object(["instanceId": .string("claude"), "model": .string("claude-opus")])
        var detail = ThreadDetail()
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(1),
            "projection": .object(["providerThreads": .array([.object([
                "id": .string("codex-thread"), "driver": .string("codex"), "providerInstanceId": .string("managed-codex"),
                "nativeMetadata": .object(["modelSelection": codexModel]),
            ])])]),
        ]))
        let owner = try #require(detail.goalOwners["codex-thread"])
        #expect(owner.commandModel(threadModel: claudeModel, providers: []) == codexModel)
        detail.apply(event("provider-thread.updated", .object([
            "id": .string("claude-thread"), "driver": .string("claudeAgent"), "providerInstanceId": .string("claude"),
        ]), sequence: 2))
        #expect(detail.goalOwners["claude-thread"]?.commandModel(threadModel: claudeModel, providers: []) == claudeModel)
        #expect(detail.goalOwners["claude-thread"]?.commandModel(threadModel: codexModel, providers: []) == nil)
        let paused = try #require(ThreadGoal(.object(["objective": .string("Ship the fix"), "status": .string("paused")])))
        #expect(paused.allows(.resume, driver: .codex, working: false))
        #expect(!paused.allows(.resume, driver: .codex, working: true))
        #expect(!paused.allows(.resume, driver: .claude, working: false))
        #expect(paused.allows(.clear, driver: .claude, working: false))
    }

    @Test func historyPageKeepsNewerStreamedMessage() {
        var detail = ThreadDetail()
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(10), "latestLocalTurnOrdinal": .int(10),
            "historyCursor": .string("cursor"), "hasMoreHistory": .bool(true),
            "projection": .object(["visibleTurnItems": .array([row(id: "active", ordinal: 10, text: "Beginning")])]),
        ]))
        detail.apply(.object([
            "kind": .string("event"), "sequence": .int(11),
            "event": .object(["type": .string("turn-item.updated"), "payload": item(id: "active", ordinal: 10, text: "Complete")]),
        ]))
        detail.prepend(.object([
            "items": .array([row(id: "early", ordinal: 1, text: "Earlier"), row(id: "active", ordinal: 10, text: "Beginning")]),
            "hasMoreHistory": .bool(false),
        ]))
        #expect(detail.timeline.map(\.id) == ["early", "active"])
        #expect(detail.timeline.last?.value["text"].string == "Complete")
        #expect(detail.historyCursor == nil)
    }

    @Test func boundedSnapshotKeepsNewItemsFromAnActiveQueuedRun() {
        var detail = ThreadDetail()
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(10), "latestLocalTurnOrdinal": .int(10),
            "historyCursor": .string("cursor"), "hasMoreHistory": .bool(true),
            "projection": .object([
                "visibleTurnItems": .array([row(id: "active", ordinal: 10, text: "New message")]),
                "runs": .array([.object(["id": .string("queued"), "status": .string("queued")])]),
            ]),
        ]))
        let events = [item(id: "old", ordinal: 1, text: "Unloaded"), item(id: "queued", ordinal: 8, text: "Queued", run: "queued")]
        for (index, event) in events.enumerated() {
            detail.apply(.object([
                "kind": .string("event"), "sequence": .int(11 + index),
                "event": .object(["type": .string("turn-item.updated"), "payload": event]),
            ]))
        }
        #expect(detail.timeline.map(\.id) == ["queued", "active"])
    }

    @Test func liveActivityFollowsOnlyRunningItemsFromTheCurrentTurn() {
        func work(_ id: String, ordinal: Int, run: String, type: String, status: String,
                  fields: Payload = [:]) -> Wire {
            .object(fields.merging([
                "id": .string(id), "ordinal": .int(ordinal), "runId": .string(run), "threadId": .string("thread"),
                "type": .string(type), "status": .string(status),
            ], uniquingKeysWith: { _, required in required }))
        }
        func projected(_ item: Wire, visibility: String = "local") -> Wire {
            .object(["item": item, "visibility": .string(visibility)])
        }
        let search = work("search", ordinal: 2, run: "run", type: "file_search", status: "running",
                          fields: ["pattern": .string("Sources/T3Code"), "title": .string("Searched Composer.swift in T3Code")])
        let previous = work("previous", ordinal: 4, run: "old-run", type: "command_execution", status: "running",
                            fields: ["input": .string("Old command")])
        let inherited = work("inherited", ordinal: 5, run: "run", type: "command_execution", status: "running")
        var detail = ThreadDetail()
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(5),
            "projection": .object([
                "runs": .array([.object(["id": .string("run"), "status": .string("running")])]),
                "visibleTurnItems": .array([projected(search), projected(previous), projected(inherited, visibility: "inherited")]),
            ]),
        ]))
        #expect(detail.liveActivity(for: "run")?.detail == "Composer.swift in T3Code")

        let command = work("command", ordinal: 6, run: "run", type: "command_execution", status: "running",
                           fields: ["input": .string("swift test\nprint done")])
        detail.apply(event("turn-item.updated", command, sequence: 6))
        #expect(detail.liveActivity(for: "run")?.detail == "swift test")

        detail.apply(event("turn-item.updated",
                           work("command", ordinal: 6, run: "run", type: "command_execution", status: "completed"),
                           sequence: 7))
        #expect(detail.liveActivity(for: "run")?.detail == "Composer.swift in T3Code")
        detail.apply(event("run.updated", .object(["id": .string("run"), "status": .string("completed")]), sequence: 8))
        #expect(detail.liveActivity(for: "run") == nil)
    }

    @Test func queuedMessagesStayInDeliveryOrderAndEnterTheTranscriptOnlyWhenSent() {
        var detail = ThreadDetail()
        let first = queueRun("first", ordinal: 1, position: 2, status: "queued")
        let second = queueRun("second", ordinal: 2, position: 1, status: "queued")
        let auto = queueRun("auto", ordinal: 3, position: 3, status: "queued")
        let cancelledItem = queuedPrompt("first", ordinal: 1)
        let sentItem = queuedPrompt("second", ordinal: 2)
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(1),
            "projection": .object([
                "runs": .array([first, second, auto]),
                "messages": .array([
                    .object(["id": .string("first-prompt"), "text": .string("First")]),
                    .object(["id": .string("second-prompt"), "text": .string("Second"),
                             "context": .object(["guest": .object(["text": .string("Guest’s message")])])]),
                    .object(["id": .string("auto-prompt"), "text": .string("Background notification"),
                             "notification": .object([:])]),
                ]),
                "visibleTurnItems": .array([cancelledItem, sentItem].map {
                    .object(["item": $0, "visibility": .string("local")])
                }),
            ]),
        ]))
        #expect(detail.timeline.isEmpty)
        #expect(detail.queue.state.messages.map(\.id) == ["second", "first"])
        #expect(detail.queue.state.messages.first?.text == "Guest’s message")
        #expect(detail.queue.state.messages.first?.editable == false)
        #expect(detail.queue.state.held)
        #expect(detail.queue.state.reorder(moving: "first", to: 0) == .init(runID: "first", beforeRunID: "second"))
        #expect(detail.queue.state.reorder(moving: "second", to: 2) == .init(runID: "second", beforeRunID: nil))
        #expect(detail.queue.state.reorder(moving: "second", to: 1) == nil)
        #expect(detail.queue.state.reorder(moving: "auto", to: 0) == nil)
        #expect(detail.queue.state.reorder(moving: "first", to: 3) == nil)

        detail.apply(event("run.updated", queueRun("first", ordinal: 1, position: 2, status: "cancelled"), sequence: 2))
        detail.apply(event("turn-item.updated", cancelledItem, sequence: 3))
        detail.apply(event("run.updated", queueRun("second", ordinal: 2, position: 1, status: "starting"), sequence: 4))
        #expect(detail.timeline.map(\.id) == ["second-item"])
        #expect(detail.queue.state.messages.isEmpty)
    }

    @Test func queuedDeliveryRequiresACompatibleRunningProviderTurn() throws {
        var detail = ThreadDetail()
        func session(restart: Bool) -> Wire {
            .object([
                "id": .string("session"), "providerInstanceId": .string("codex"), "status": .string("running"),
                "capabilities": .object(["turns": .object([
                    "supportsActiveSteering": .bool(true), "supportsInterrupt": .bool(true),
                    "supportsSteeringByInterruptRestart": .bool(restart),
                ])]),
            ])
        }
        let active: Wire = .object([
            "id": .string("active"), "status": .string("running"), "ordinal": .int(1),
            "activeAttemptId": .string("attempt"), "providerInstanceId": .string("codex"),
            "userMessageId": .string("active-prompt"), "providerThreadId": .string("provider-thread"),
        ])
        detail.apply(.object([
            "kind": .string("snapshot"), "snapshotSequence": .int(1), "projection": .object([
                "runs": .array([active, queueRun("next", ordinal: 2, position: 1, status: "queued")]),
                "messages": .array([.object(["id": .string("next-prompt"), "text": .string("Next")])]),
                "providerThreads": .array([.object(["id": .string("provider-thread"), "providerSessionId": .string("session")])]),
                "providerSessions": .array([session(restart: true)]),
            ]),
        ]))
        let message = try #require(detail.queue.state.messages.first)
        #expect(detail.queue.state.delivery(for: message) == nil)
        #expect(detail.queue.modelSwitchDelivery(for: "active") == nil)
        detail.apply(event("provider-turn.updated", .object([
            "id": .string("turn"), "status": .string("running"), "runAttemptId": .string("attempt"),
        ]), sequence: 2))
        #expect(detail.queue.state.delivery(for: message) == .steer("active"))
        #expect(detail.queue.modelSwitchDelivery(for: "active") == .restart("active"))
        detail.apply(event("provider-session.updated", session(restart: false), sequence: 3))
        #expect(detail.queue.modelSwitchDelivery(for: "active") == .interrupt("active"))
        detail.apply(event("provider-session.detached", .object(["providerSessionId": .string("session")]), sequence: 4))
        #expect(detail.queue.state.delivery(for: message) == nil)
        #expect(detail.queue.modelSwitchDelivery(for: "active") == nil)
        detail.apply(event("run.updated", .object(["id": .string("active"), "status": .string("completed")]), sequence: 5))
        #expect(detail.queue.state.delivery(for: message) == .start)
    }

    @Test func activeModelTracksTheOldProviderTurnUntilTheNewAttemptRuns() {
        let old: Wire = .object(["instanceId": .string("codex"), "model": .string("requested-codex")])
        let next: Wire = .object(["instanceId": .string("claude"), "model": .string("requested-claude")])
        func run(_ attempt: String, status: String, model: Wire) -> Wire {
            .object(["id": .string("run"), "status": .string(status), "activeAttemptId": .string(attempt),
                     "modelSelection": model, "ordinal": .int(1)])
        }
        func turn(_ id: String, status: String, model: String) -> Wire {
            .object(["id": .string(id + "-turn"), "runAttemptId": .string(id), "status": .string(status),
                     "model": .string(model)])
        }
        let oldTurn = turn("old", status: "running", model: "actual-codex")
        func snapshot(_ run: Wire, sequence: Int) -> Wire {
            .object([
                "kind": .string("snapshot"), "snapshotSequence": .int(sequence), "projection": .object([
                    "runs": .array([run]), "providerTurns": .array([oldTurn]), "attempts": .array([.object([
                        "id": .string("old"), "runId": .string("run"), "providerInstanceId": .string("codex"),
                    ])]),
                ]),
            ])
        }
        var detail = ThreadDetail()
        detail.apply(snapshot(run("old", status: "running", model: old), sequence: 1))
        #expect(detail.queue.activeModel(for: "run")["model"].string == "actual-codex")
        let accepted = run("new", status: "starting", model: next)
        detail.apply(event("run.updated", accepted, sequence: 2))
        #expect(detail.queue.activeModel(for: "run") == .object(["instanceId": .string("codex"), "model": .string("actual-codex")]))

        var reopened = ThreadDetail()
        reopened.apply(snapshot(accepted, sequence: 2))
        #expect(reopened.queue.activeModel(for: "run") == detail.queue.activeModel(for: "run"))
        detail.apply(event("provider-turn.updated", turn("new", status: "running", model: "actual-claude"), sequence: 3))
        #expect(detail.queue.activeModel(for: "run") == .object(["instanceId": .string("claude"), "model": .string("actual-claude")]))
    }

    private func event(_ type: String, _ payload: Wire, sequence: Int) -> Wire {
        .object(["kind": .string("event"), "sequence": .int(sequence),
                 "event": .object(["type": .string(type), "payload": payload])])
    }

    private func queueRun(_ id: String, ordinal: Int, position: Int, status: String) -> Wire {
        .object(["id": .string(id), "ordinal": .int(ordinal), "queuePosition": .int(position),
                 "status": .string(status), "queueHeld": .bool(true), "userMessageId": .string("\(id)-prompt")])
    }

    private func queuedPrompt(_ run: String, ordinal: Int) -> Wire {
        .object(["id": .string("\(run)-item"), "ordinal": .int(ordinal), "threadId": .string("thread"),
                 "runId": .string(run), "inputIntent": .string("queued_turn"), "type": .string("user_message"),
                 "text": .string("Prompt")])
    }

    private func item(id: String, ordinal: Int, text: String, run: String? = nil) -> Wire {
        .object(["id": .string(id), "ordinal": .int(ordinal), "text": .string(text),
                 "runId": run.map(Wire.string) ?? .null, "threadId": .string("thread"), "type": .string("assistant_message")])
    }

    private func row(id: String, ordinal: Int, text: String) -> Wire {
        .object(["visibility": .string("local"), "item": item(id: id, ordinal: ordinal, text: text)])
    }
}
