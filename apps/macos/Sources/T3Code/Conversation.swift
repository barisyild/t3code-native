import AppKit
import UniformTypeIdentifiers

@MainActor
final class ConversationController: NSViewController {
    private struct DraftKey: Hashable {
        let environmentID: String
        let selection: Workspace.Selection
    }

    private struct BranchKey: Equatable {
        let connection: UUID
        let path: String
    }

    private struct QueueScope: Equatable {
        let threadID: String
        let connection: UUID
    }

    private struct MessageJump {
        let scope: MessageSearchScope
        let threadID: String
        let messageID: String?
        let needle: String
    }

    private let workspace: Workspace
    private let embedded: Bool
    private let voiceOwner = UUID()
    private let titleField = label("T3 Code", size: 13.5, weight: .semibold, color: WorkspaceStyle.ink)
    private let subtitle = label(size: 11, color: WorkspaceStyle.muted)
    private let timeline = TimelineView()
    private lazy var attachmentStore = AttachmentStore { [workspace] attachment, scope in
        try await workspace.attachmentFile(attachment, scope: scope)
    }
    private var attachmentPreview: AttachmentPreviewController?
    private lazy var findBar = ThreadFindBar(workspace: workspace)
    private let composer = ComposerView()
    private lazy var cloneBanner = ProjectCloneBanner(workspace: workspace)
    private let queuedMessages = QueuedMessagesView()
    private let emptyTitle = label("Connect an environment", size: 26, weight: .semibold)
    private let emptyDetail = label(size: 13, color: WorkspaceStyle.muted)
    private let composerStatus = label(size: 11, color: WorkspaceStyle.muted)
    private let requestLabel = label(size: 12, weight: .medium, color: WorkspaceStyle.accent)
    private let noticeLabel = label(size: 12, color: WorkspaceStyle.negative)
    private let activityBadge = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 14)
    private let activityIcon = WorkspaceStyle.icon("circle.dotted", size: 12)
    private let activityText = label(size: 12, color: WorkspaceStyle.ink)
    private let activityTime = label(size: 12, color: WorkspaceStyle.secondary)
    private var embeddedActivityStrip: NSView?
    private lazy var terminal = TerminalPanel(workspace: workspace)
    private lazy var files = ActionButton("Files", symbol: "folder", iconOnly: true, style: .subtle) { [weak self] in self?.onInspector?(.files) }
    private lazy var changes = ActionButton("Changes", symbol: "plus.forwardslash.minus", iconOnly: true, style: .subtle) { [weak self] in
        self?.onInspector?(.changes)
    }
    private lazy var gitButton = ActionButton("Source Control", symbol: "arrow.triangle.branch", iconOnly: true, style: .subtle) { [weak self] in
        self?.showSourceControl()
    }
    private lazy var terminalButton = ActionButton("Terminal", symbol: "terminal", iconOnly: true, style: .subtle) { [weak self] in self?.toggleTerminal() }
    private lazy var browserButton = ActionButton("Browser", symbol: "globe", iconOnly: true, style: .subtle) { [weak self] in
        self?.onInspector?(.browser)
    }
    private lazy var sideChatsButton = ActionButton("Side Chats", symbol: "bubble.left.and.bubble.right", iconOnly: true, style: .subtle) {
        [weak self] in self?.openSideChatMenu()
    }
    private lazy var broughtBack = ActionButton("Side chat context", symbol: "arrow.turn.down.left", style: .subtle) { [weak self] in
        guard let self, let source = displayedDetail.pendingMergeBacks.values.first?.sourceID else { return }
        openThreadLink(source)
    }
    private lazy var guestSharing = ActionButton("Guest Sharing", symbol: "person.2", style: .subtle) { [weak self] in
        self?.openGuestShare()
    }
    private lazy var guestSharingRow = row([guestSharing, NSView()])
    private lazy var more = ActionButton("Conversation Actions", symbol: "ellipsis", iconOnly: true, style: .subtle) { [weak self] in self?.threadMenu() }
    private lazy var stopButton = ActionButton("Stop", symbol: "stop.fill", iconOnly: true, style: .subtle) { [weak self] in self?.stop() }
    private lazy var primary = ActionButton("Pair Environment…") { [weak self] in self?.primaryAction() }
    private lazy var cloud = ActionButton("T3 Connect…", symbol: "globe") { [weak self] in self?.onT3Connect?() }
    private lazy var local = ActionButton("Start Local Server", symbol: "desktopcomputer") { [weak self] in self?.onStartLocal?() }
    private lazy var scratch = ActionButton("Start Without a Project") { [weak self] in self?.perform { try await self?.workspace.startScratch() } }
    private lazy var earlier = ActionButton("Load Earlier Messages", symbol: "arrow.up") { [weak self] in self?.loadEarlier() }
    private lazy var review = ActionButton("Review…", style: .subtle) { [weak self] in self?.reviewRequest() }
    private lazy var requestBar = row([requestLabel, NSView(), review])
    private lazy var emptyActions = row([primary, cloud, local, scratch], spacing: 8)
    private let emptyView = NSView()
    private var drafts: [DraftKey: ComposerView.Draft] = [:]
    private var draftKey: DraftKey?
    private var preparingAttachments = Set<DraftKey>()
    private var isLoadingHistory = false
    private var pendingMessageJump: MessageJump?
    private var messageJumpTask: Task<Void, Never>?
    private var citationJump: (citation: AssistantCitation, connection: UUID)?
    private var citationJumpTask: Task<Void, Never>?
    private var latestRequest: (id: String, entry: TimelineEntry?)?
    private var terminalShown = false
    private var startingProjectAction = false
    private var workspaceVisible = true
    private var activityStart: Date?
    private var branchKey: BranchKey?
    private var branchTask: Task<Void, Never>?
    private var liveBranch: String?
    private var liveBranchLoaded = false
    private var gitPanel: RepositoryActionsController?
    private var branchPicker: RepositoryBranchPicker?
    private var requestCheckout: RepositoryRequestCheckout?
    private var queueBusy = false
    private var isForking = false
    private var startingSideChat = false
    private var rewindKey: DraftKey?
    private var queueEditor: QueuedMessageEditor?
    private var questionEditor: QuestionAnswerController?
    private var planSave: ProposedPlanSaveController?
    private var planSaveTarget: ProposedPlan.SaveTarget?
    private var guestSheet: GuestShareSheet?
    private var guestResolutions = Set<String>()
    private var guestExpiry: Date?
    private var guestExpiryTask: Task<Void, Never>?
    private var queueEditTarget: (scope: QueueScope, runID: String)?
    var onPair: (() -> Void)?
    var onT3Connect: (() -> Void)?
    var onStartLocal: (() -> Void)?
    var onAdd: (() -> Void)?
    var onInspector: ((InspectorController.Tab) -> Void)?
    var onOpenWorkspaceFile: ((WorkspaceFileReference, WorkspaceFileContext) -> Void)?
    var onTerminalToggle: ((Bool) -> Void)?
    var onThreadAction: ((String, String) -> Void)?
    var onProjectSettings: ((ProjectTarget) -> Void)?
    var onProjectActionPreview: ((String, ProjectActionTarget) -> Void)?
    var onError: ((String) -> Void)?
    var onRepositoryChange: (() -> Void)?
    var onOpenPullRequest: ((PullRequestReference) -> Void)?
    var onShowUsageLimits: (() -> Void)?
    var onVoiceSettings: (() -> Void)?
    var onOpenCitation: ((AssistantCitation) -> Void)?
    var onOpenSideChat: ((String) -> Bool)?
    var onSideChatStarted: ((SideChatReference, Wire) -> Void)?
    var onRelatedConversations: (() -> Void)?

    init(workspace: Workspace, embedded: Bool = false) {
        self.workspace = workspace
        self.embedded = embedded
        super.init(nibName: nil, bundle: nil)
    }

    private var displayedThread: ThreadSummary? { embedded ? workspace.sideChatThread : workspace.selectedThread }
    private var displayedSelection: Workspace.Selection? {
        embedded ? workspace.sideChat.map { .thread($0.threadID) } : workspace.selection
    }
    private var displayedProject: Project? {
        embedded ? displayedThread.flatMap { workspace.data.projects[$0.projectId] } : workspace.selectedProject
    }
    private var displayedDetail: ThreadDetail { embedded ? workspace.sideChatDetail : workspace.detail }
    private var displayedError: String? { embedded ? workspace.sideChatError : workspace.detailError }
    private var displayedCheckout: WorkspaceCheckout { embedded ? .root(branch: displayedThread?.branch) : workspace.draftCheckout }
    private var displayedPath: String? { embedded ? displayedThread.flatMap(workspace.checkoutPath) : workspace.workspacePath }
    private var displayedFileContext: WorkspaceFileContext? {
        if !embedded { return workspace.workspaceFileContext }
        guard let environment = workspace.environment, let thread = displayedThread, let root = displayedPath else { return nil }
        return .init(environmentID: environment.id, root: root, threadID: thread.id)
    }
    private var displayedFindScope: ThreadFindScope? { workspace.threadFindScope(for: displayedThread?.id) }
    private var displayedPlanTarget: ProposedPlan.SaveTarget? { workspace.planSaveTarget(for: displayedThread?.id) }
    private var displayedGoalOwner: ThreadGoal.Owner? { workspace.goalOwner(for: displayedThread) }
    private var displayedSwitchDelivery: ThreadQueue.ModelSwitchDelivery? { workspace.modelSwitchDelivery(for: displayedThread) }
    private var displayedGuestTarget: GuestShareTarget? { workspace.guestShareTarget(for: displayedThread?.id) }
    var canOpenGuestShare: Bool {
        displayedGuestTarget != nil && (workspace.canCreateGuestShare || displayedDetail.guestShare != nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.canvas)
        timeline.attachmentStore = attachmentStore
        timeline.loadWebPage = { [workspace] reference, scope in
            try await workspace.downloadAttachment(reference.resource, fileName: reference.fileName,
                                                   maximumBytes: reference.maximumBytes, scope: scope)
        }
        timeline.makeMcpAppSession = { [weak self] app, scope in
            guard let self, let conversation = displayedThread?.id else { return nil }
            return McpAppSession(page: app, conversationID: conversation, isConnected: { [weak self] in
                self?.workspace.attachmentScope == scope && self?.displayedThread?.id == conversation
            }, request: { [workspace] method, payload in
                try await workspace.request(method, payload)
            }, sendMessage: { [weak self] text in
                guard let self else { throw ClientError.disconnected }
                try await sendAppMessage(text, conversation: conversation, scope: scope)
            })
        }
        composer.usageLimits.presentationView = view
        let header = makeHeader()
        let body = NSView()
        body.addSubview(timeline)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timeline.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 19),
            timeline.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -19),
            timeline.topAnchor.constraint(equalTo: body.topAnchor),
            timeline.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
        fill(emptyView, in: body)
        layoutEmptyView()
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.lineBreakMode = .byWordWrapping
        composerStatus.alignment = .right
        terminal.heightAnchor.constraint(equalToConstant: 176).isActive = true
        terminal.isHidden = true
        terminal.onClose = { [weak self] in self?.toggleTerminal() }
        terminal.onError = { [weak self] message in self?.onError?(message) }
        terminal.onAddContext = { [weak self] context, target in
            guard let self else { throw ClientError.disconnected }
            try attachTerminalContext(context, target: target)
        }
        cloneBanner.onRemoved = { [weak self] id in
            guard let self, let environmentID = workspace.environment?.id else { return }
            let key = DraftKey(environmentID: environmentID, selection: .project(id))
            drafts.removeValue(forKey: key)
            preparingAttachments.remove(key)
            if draftKey == key { composer.load(.init()) }
        }

        let history = row([NSView(), earlier, NSView()])
        let context = row([broughtBack, NSView()])
        broughtBack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.isHidden = true
        let center = column([findBar, history, body, noticeLabel, requestBar, queuedMessages, cloneBanner, context, guestSharingRow,
                             composer, composerStatus, terminal],
                            spacing: 6, alignment: .width)
        let centered = NSView()
        centered.addSubview(center)
        center.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = center.widthAnchor.constraint(equalTo: centered.widthAnchor, multiplier: embedded ? 1 : 0.80,
                                                           constant: embedded ? -22 : 0)
        preferredWidth.priority = .defaultHigh
        let minimumWidth = center.widthAnchor.constraint(greaterThanOrEqualToConstant: 350)
        minimumWidth.priority = NSLayoutConstraint.Priority(751)
        NSLayoutConstraint.activate([
            preferredWidth,
            minimumWidth,
            center.widthAnchor.constraint(lessThanOrEqualTo: centered.widthAnchor, constant: -26),
            center.widthAnchor.constraint(lessThanOrEqualToConstant: WorkspaceStyle.composerWidth),
            center.centerXAnchor.constraint(equalTo: centered.centerXAnchor),
            center.topAnchor.constraint(equalTo: centered.topAnchor, constant: 9),
            center.bottomAnchor.constraint(equalTo: centered.bottomAnchor, constant: -12),
        ])
        let layout = column([header, centered], spacing: 0, alignment: .width)
        fill(layout, in: view)
        composer.onDraftChange = { [weak self] draft in
            guard let self, let draftKey else { return }
            drafts[draftKey] = draft
        }
        composer.onSend = { [weak self] draft in self?.send(draft) }
        composer.onWorktree = { [weak self] in self?.chooseWorktree() }
        composer.onRootCheckout = { [weak self] in self?.workspace.setDraftCheckout(.root()) }
        composer.onBranch = { [weak self] in self?.showBranches() }
        composer.onAttach = { [weak self] in self?.chooseAttachments() }
        composer.onVoiceToggle = { [weak self] in self?.toggleDictation() }
        composer.onVoiceCancel = { [weak self] in
            guard let self else { return }
            workspace.voiceInput.cancel(owner: voiceOwner)
        }
        composer.onVoiceSend = { [weak self] in
            guard let self else { return }
            workspace.voiceInput.finish(owner: voiceOwner, send: true)
        }
        composer.onVoiceSettings = { [weak self] in self?.onVoiceSettings?() }
        composer.onReadAttachment = { [weak self] pasteboard in
            guard let self, let key = draftKey else { return false }
            let inputs = AttachmentInput.read(pasteboard)
            guard !inputs.isEmpty else { return false }
            prepareAttachments(inputs, for: key)
            return true
        }
        composer.onModelChange = { [weak self] in self?.render(.providers) }
        composer.onSwitchModel = { [weak self] model in self?.switchModelNow(model) }
        composer.onModeChange = { [weak self] kind, value in self?.setMode(kind, value) }
        composer.onEditQueued = { [weak self] in self?.editLastQueuedMessage() ?? false }
        composer.goalBar.onAction = { [weak self] action in self?.runGoalAction(action) }
        composer.usageLimits.onViewAll = { [weak self] in self?.onShowUsageLimits?() }
        composer.loadCommandCatalog = { [workspace] scope in try await workspace.composerCommands(for: scope) }
        queuedMessages.onAction = { [weak self] action in self?.handleQueueAction(action) }
        findBar.onReveal = { [weak self] match, query in
            try await self?.revealFindMatch(match, query: query) ?? false
        }
        findBar.onClear = { [weak self] in self?.timeline.clearFind() }
        timeline.onFork = { [weak self] entry in self?.fork(from: entry) }
        timeline.onRewind = { [weak self] entry in self?.editFromHere(entry) }
        timeline.onPlanAction = { [weak self] entry, action in self?.handlePlanAction(entry, action: action) }
        timeline.onOpenAttachment = { [weak self] entry, attachment in self?.openAttachment(attachment, in: entry) }
        timeline.onOpenGuestAttachment = { [weak self] shareID, message, attachment in
            guard let self, let share = displayedDetail.guestShare, share.id == shareID, share.pending.contains(message) else { return }
            openAttachment(attachment, among: message.attachments)
        }
        timeline.onResolveGuestMessage = { [weak self] shareID, messageID, decision in
            self?.resolveGuestMessage(messageID, shareID: shareID, decision: decision)
        }
        timeline.onOpenFile = { [weak self] reference, context in self?.onOpenWorkspaceFile?(reference, context) }
        timeline.onOpenThread = { [weak self] id in self?.openThreadLink(id) }
        timeline.onCite = { [weak self] citation in
            guard let self, workspace.currentServerID == citation.environmentID, draftKey != nil,
                  workspaceVisible, composer.cite(citation) else {
                self?.onError?("Open an editable draft before adding a quote.")
                return
            }
        }
        timeline.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
        composer.onOpenCitation = timeline.onOpenCitation
        timeline.loadFileDetail = { [workspace] entry in try await workspace.fileChangeDetail(entry) }
    }

    private func makeHeader() -> NSView {
        let activity = row([activityIcon, activityText, activityTime, stopButton], spacing: 6)
        activityText.setContentCompressionResistancePriority(.required, for: .horizontal)
        activityTime.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        activityTime.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.widthAnchor.constraint(equalToConstant: 23).isActive = true
        stopButton.heightAnchor.constraint(equalToConstant: 23).isActive = true
        activityBadge.addSubview(activity)
        activity.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activity.leadingAnchor.constraint(equalTo: activityBadge.leadingAnchor, constant: 10),
            activity.trailingAnchor.constraint(equalTo: activityBadge.trailingAnchor, constant: -5),
            activity.centerYAnchor.constraint(equalTo: activityBadge.centerYAnchor),
            activityBadge.heightAnchor.constraint(equalToConstant: 28),
        ])
        if embedded {
            let strip = row([NSView(), activityBadge, NSView()])
            strip.heightAnchor.constraint(equalToConstant: 32).isActive = true
            embeddedActivityStrip = strip
            return strip
        }
        let title = column([titleField, subtitle], spacing: 2)
        let controls = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 12)
        let buttons = [files, changes, gitButton, terminalButton, browserButton, sideChatsButton, more]
        for button in buttons {
            button.widthAnchor.constraint(equalToConstant: 31).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        fill(row(buttons, spacing: 2), in: controls, inset: 2)
        let leadingSpace = NSView()
        let trailingSpace = NSView()
        let line = row([title, leadingSpace, activityBadge, trailingSpace, controls], spacing: 8)
        let balanced = leadingSpace.widthAnchor.constraint(equalTo: trailingSpace.widthAnchor)
        balanced.priority = .defaultHigh
        balanced.isActive = true
        let header = NSView()
        header.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 48),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 1),
        ])
        return header
    }

    func render(_ change: Workspace.Change) {
        let _ = view
        if change == .voiceInput || change == .voiceSettings { renderVoice(); return }
        let selection = displayedSelection
        let thread = displayedThread
        let project = displayedProject
        let nativeSubagent = thread?.isProviderNativeSubagent == true
        let key = workspace.environment.flatMap { environment in selection.map { DraftKey(environmentID: environment.id, selection: $0) } }
        let changedThread = draftKey != key
        if changedThread {
            workspace.voiceInput.cancel(owner: voiceOwner)
            composer.goalBar.closeDetails()
            draftKey = key
            composer.load(key.flatMap { drafts[$0] } ?? .init())
            composer.setPreparingAttachments(key.map(preparingAttachments.contains) ?? false)
            timeline.reset()
            isLoadingHistory = false
        }
        if changedThread || !change.intersection([.selection, .connection, .sidebar, .providers]).isEmpty {
            let ready = workspace.connection == .ready
            let canOperate = workspace.can("orchestration:operate") && (!embedded || workspace.selectedThread?.archived == false)
            titleField.stringValue = thread?.title ?? (project == nil ? "T3 Code" : "New thread")
            titleField.toolTip = thread?.title
            updateActivity(thread, canOperate: canOperate)
            if !embedded {
                subscribeBranch(ready: ready)
                updateContext()
                let canInspect = workspace.can("filesystem:read") && displayedPath != nil
                files.isEnabled = files.isMarked || canInspect
                changes.isEnabled = changes.isMarked || canInspect
                gitButton.isEnabled = workspace.repository != nil
                terminalButton.isEnabled = terminalShown || (workspace.can("terminal:operate") && thread != nil)
                browserButton.isEnabled = browserButton.isMarked || (workspace.can("orchestration:read") && thread != nil)
                sideChatsButton.isHidden = !workspace.supportsSideChats || thread == nil || thread?.isSubagent == true || thread?.isSideChat == true
                sideChatsButton.isEnabled = workspace.data.threads.values.contains { $0.isSideChat && $0.parentThreadID == thread?.id } ||
                    (workspace.sideChatParent != nil && !startingSideChat)
            }
            composer.isHidden = nativeSubagent || selection == nil || (thread == nil && project == nil)
            composer.setTerminalClipboardSource(workspace.currentServerID.map { .init(environmentID: $0, threadID: thread?.id) })
            composer.render(providers: workspace.providers, defaultModel: thread?.model ?? workspace.defaultModel(for: project),
                            thread: thread, checkout: displayedCheckout,
                            projectAvailable: project != nil && (thread != nil || project?.archived == false), canOperate: canOperate,
                            sending: selection.map(workspace.sending.contains) ?? false)
            composerStatus.stringValue = nativeSubagent ? "Provider-native subagent · Read only" :
                thread?.archived == true ? "Restore this thread to continue" :
                rewindKey == key && key != nil ? "Restoring conversation…" :
                !ready ? "Waiting for connection" : !canOperate ? "Read-only connection" : ""
            composerStatus.isHidden = (composer.isHidden && !nativeSubagent) || composerStatus.stringValue.isEmpty
            if workspaceVisible && terminalShown { terminal.sync() }
            gitPanel?.render()
        }
        if embedded { cloneBanner.isHidden = true }
        else if !change.intersection([.selection, .connection, .sidebar, .clones]).isEmpty { renderProjectClone() }

        let entries = displayedDetail.timeline
        timeline.citationEnvironmentID = workspace.currentServerID
        let guestShare = displayedDetail.guestShare
        renderGuestShare(guestShare)
        renderVoice()
        timeline.setAttachmentScope(workspace.attachmentScope)
        let hasHistory = thread != nil && entries.contains(where: \.isMessage)
        composer.setCommandContext(connection: workspace.connectionID, cwd: displayedPath,
                                   freshSession: workspace.supportsFreshContext && hasHistory, hasHistory: hasHistory,
                                   sideChats: !embedded && workspace.sideChatParent != nil)
        let fileContext = workspace.can("filesystem:read") ? displayedFileContext : nil
        if changedThread || fileContext != timeline.fileContext ||
            !change.intersection([.timeline, .selection, .providers, .connection, embedded ? .sideChat : []]).isEmpty {
            timeline.render(entries, runModels: displayedDetail.runModels,
                            providers: workspace.providers, workspacePath: displayedPath, fileContext: fileContext,
                            guestShare: guestShare, canResolveGuestMessages: displayedGuestTarget != nil && workspace.can("orchestration:operate"),
                            busyGuestMessages: guestResolutions)
        }
        timeline.isHidden = !timeline.hasContent
        emptyView.isHidden = !timeline.isHidden
        earlier.superview?.isHidden = displayedDetail.historyCursor == nil
        earlier.isEnabled = !isLoadingHistory
        let error = displayedError ?? thread?.lastError
        noticeLabel.isHidden = error == nil
        noticeLabel.stringValue = error ?? ""
        renderRequest(entries)
        renderQueue()
        renderGoal(thread)
        let activeModel = thread?.activeRunId.map { displayedDetail.queue.activeModel(for: $0) }
        composer.renderModelSwitch(activeModel: activeModel ?? .null, canSwitch: displayedSwitchDelivery != nil)
        let usageModel = thread?.isWorking == true ? activeModel ?? displayedDetail.queue.activeModel(for: nil) : nil
        composer.renderUsageLimits(activeModel: usageModel, sources: workspace.usageLimitSources,
                                   canRead: workspace.can("orchestration:read"))
        findBar.sync(scope: displayedFindScope, sequence: displayedDetail.sequence)
        timeline.setForkEnabled(!embedded && !nativeSubagent && workspace.can("orchestration:operate") && !isForking)
        timeline.canSavePlanToWorkspace = displayedPlanTarget != nil
        planSave?.setAvailable(planSaveTarget != nil && displayedPlanTarget == planSaveTarget)
        timeline.setRewind(available: !embedded && !nativeSubagent && workspace.supportsRewind && workspace.can("orchestration:operate") && thread?.archived == false,
                           enabled: canRewindSelected)
        more.isEnabled = canOpenGuestShare || project.flatMap { workspace.projectTarget($0.id) } != nil ||
            (thread != nil && (canFindInThread || workspace.can("orchestration:operate") ||
                (workspace.can("orchestration:read") && thread?.pullRequests.isEmpty == false)))
        let pending = displayedDetail.pendingMergeBacks.values.first
        broughtBack.superview?.isHidden = embedded || pending == nil
        if let pending {
            let name = workspace.data.threads[pending.sourceID]?.title ?? "Side chat"
            broughtBack.title = "Next message includes \(name)"
            broughtBack.isEnabled = workspace.data.threads[pending.sourceID] != nil || workspace.data.archived[pending.sourceID] != nil
            broughtBack.setAccessibilityLabel(broughtBack.title)
        }
        if !emptyView.isHidden { renderEmpty(project: project, thread: thread) }
        advanceMessageJump()
        advanceCitationJump()
    }

    func renderProjectClone() {
        let project = displayedProject
        let id: String? = if let project { project.id }
            else if case .project(let id) = displayedSelection { id }
            else { nil }
        let clone = id.flatMap(workspace.cloneStatus)
        cloneBanner.render(clone, projectName: project?.name)
        composer.setSendBlockReason(clone?.sendReason)
    }

    private func updateContext() {
        let project = displayedProject
        let branch = liveBranchLoaded ? liveBranch : displayedThread?.branch ?? displayedCheckout.branch
        let name = project.map { workspace.isScratch($0) ? "Chat" : $0.name } ?? workspace.environment?.name
        subtitle.stringValue = [name, branch].compactMap { $0 }.joined(separator: " · ")
        subtitle.toolTip = displayedPath
        let displayBranch: String?
        if case .newWorktree(let base) = displayedCheckout { displayBranch = base }
        else { displayBranch = branch }
        let target = workspace.repository
        composer.setBranch(displayBranch, available: target != nil, enabled: canChooseBranch)
    }

    private func subscribeBranch(ready: Bool) {
        let key = ready ? workspace.connectionID.flatMap { connection in
            displayedPath.map { BranchKey(connection: connection, path: $0) }
        } : nil
        guard branchKey != key else { return }
        branchKey = key
        liveBranch = nil
        liveBranchLoaded = false
        branchTask?.cancel()
        guard let key else { return }
        branchTask = Task { [weak self, workspace] in
            try? await workspace.subscribe("subscribeVcsBranch", ["cwd": .string(key.path)]) { frames in
                guard let self, self.branchKey == key, let update = frames.last else { return }
                self.liveBranch = update["refName"].string
                self.liveBranchLoaded = true
                self.updateContext()
            }
        }
    }

    private func updateActivity(_ thread: ThreadSummary?, canOperate: Bool) {
        let working = thread?.isWorking == true
        let waiting = (thread?.pendingRequest ?? .null) != .null
        activityBadge.isHidden = !working && !waiting
        embeddedActivityStrip?.isHidden = activityBadge.isHidden
        activityIcon.contentTintColor = waiting ? WorkspaceStyle.accent : WorkspaceStyle.secondary
        activityText.stringValue = waiting ? "Needs input" : thread?.status == "queued" ? "Queued" : "Working"
        stopButton.isEnabled = canOperate && working
        stopButton.isHidden = !working
        let start = working ? WorkspaceStyle.date(thread?.activeSince) : nil
        activityTime.isHidden = start == nil
        activityStart = start
        refreshActivityTime()
    }

    func refreshActivityTime() {
        if let activityStart { activityTime.stringValue = WorkspaceStyle.elapsed(since: activityStart) }
    }

    private func layoutEmptyView() {
        let image = NSImageView(image: NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 30, weight: .light)
        image.contentTintColor = WorkspaceStyle.accent
        emptyTitle.alignment = .center
        emptyDetail.alignment = .center
        emptyDetail.maximumNumberOfLines = 4
        emptyDetail.lineBreakMode = .byWordWrapping
        let content = column([image, emptyTitle, emptyDetail, emptyActions], spacing: 10, alignment: .centerX)
        content.setCustomSpacing(14, after: image)
        content.setCustomSpacing(16, after: emptyDetail)
        emptyView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: emptyView.widthAnchor, constant: -8),
            emptyDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func renderEmpty(project: Project?, thread: ThreadSummary?) {
        primary.isHidden = true
        cloud.isHidden = true
        scratch.isHidden = true
        local.isHidden = true
        switch workspace.connection {
        case .offline, .needsPairing:
            emptyTitle.stringValue = "Connect an environment"
            emptyDetail.stringValue = workspace.connectionError ?? "Pair a server or open a linked environment with T3 Connect."
            primary.title = workspace.environment?.relay == nil ? "Pair Environment…" : "T3 Connect…"
            primary.isHidden = false
            cloud.isHidden = workspace.environment?.relay != nil
            local.isHidden = false
        case .connecting, .retrying:
            emptyTitle.stringValue = workspace.connection == .connecting ? "Connecting…" : "Reconnecting…"
            emptyDetail.stringValue = workspace.connectionError ?? "Waiting for the T3 Code server."
        case .ready:
            if workspace.isShowingArchive && thread == nil {
                emptyTitle.stringValue = "Archive"
                if workspace.data.projects.values.contains(where: \.archived) {
                    emptyDetail.stringValue = "Open an archived thread or right-click a project to restore it."
                } else {
                    emptyDetail.stringValue = workspace.data.archived.isEmpty ? "Archived threads appear here." :
                        "Select an archived thread to review or restore it."
                }
            } else if case .thread = displayedSelection {
                if displayedError != nil {
                    emptyTitle.stringValue = "Couldn’t open this thread"
                    emptyDetail.stringValue = displayedError ?? ""
                    primary.title = "Try Again"
                    primary.isHidden = false
                } else {
                    emptyTitle.stringValue = displayedDetail.loaded ? "No messages yet" : "Loading conversation…"
                    emptyDetail.stringValue = displayedDetail.loaded ? "Send a message to continue this thread." : ""
                }
            } else if let project {
                emptyTitle.stringValue = "What should we work on?"
                emptyDetail.stringValue = workspace.cloneStatus(project.id)?.blocksCheckout == true ? "" : "Start a thread in \(project.name)."
            } else {
                emptyTitle.stringValue = "What should we work on?"
                emptyDetail.stringValue = "Add a project to start your first thread."
                primary.title = "Add Project…"
                primary.isHidden = !workspace.can("orchestration:operate")
                scratch.isHidden = primary.isHidden
            }
        }
        primary.setAccessibilityLabel(primary.title)
        emptyActions.isHidden = primary.isHidden && cloud.isHidden && scratch.isHidden && local.isHidden
    }

    func setStartingLocal(_ starting: Bool) {
        local.isEnabled = !starting
        local.title = starting ? "Starting Server…" : "Start Local Server"
        local.setAccessibilityLabel(local.title)
    }

    private func primaryAction() {
        if workspace.connection != .ready {
            if workspace.environment?.relay != nil { onT3Connect?() } else { onPair?() }
        }
        else if displayedError != nil {
            if embedded { workspace.subscribeToSideChat() }
            else { workspace.retryThread() }
        }
        else { onAdd?() }
    }

    func focusComposer() { composer.focus() }

    var containsFocus: Bool {
        guard isViewLoaded, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func toggleTerminal() {
        guard terminalShown || terminalButton.isEnabled else { return }
        terminalShown.toggle()
        terminal.isHidden = !terminalShown
        terminalButton.isMarked = terminalShown
        onTerminalToggle?(terminalShown)
        if terminalShown { terminal.sync(); terminal.focus() }
        else { terminal.hide() }
    }

    func runProjectAction(_ action: ProjectAction, target: ProjectActionTarget) {
        guard !startingProjectAction else { return }
        startingProjectAction = true
        perform {
            defer { self.startingProjectAction = false }
            let session = try await self.workspace.runProjectAction(action, target: target)
            guard self.workspaceVisible, self.workspace.projectActionTarget == target else { return }
            self.terminalShown = true
            self.terminal.isHidden = false
            self.terminalButton.isMarked = true
            self.onTerminalToggle?(true)
            self.terminal.reveal(session)
            if action.draft.autoOpenPreview { self.onProjectActionPreview?(action.draft.preview, target) }
        }
    }

    func setWorkspaceVisible(_ visible: Bool) {
        workspaceVisible = visible
        if !visible {
            workspace.voiceInput.cancel(owner: voiceOwner)
            cancelMessageJump()
            findBar.dismiss(restoreFocus: false)
            composer.closeModelMenu()
            composer.closeQuote()
            composer.goalBar.closeDetails()
            composer.usageLimits.close()
        }
        renderVoice()
        guard terminalShown else { return }
        if visible { terminal.sync() }
        else { terminal.hide() }
    }

    var canFindInThread: Bool { displayedFindScope != nil }
    var canStepFind: Bool { findBar.canNavigate }

    private var voiceAvailable: Bool {
        workspaceVisible && displayedSelection != nil && !composer.isHidden && composer.canDictate && workspace.voiceTarget != nil
    }

    var canToggleDictation: Bool {
        let voice = workspace.voiceInput
        return voiceAvailable && (!voice.phase.busy || (voice.owner == voiceOwner && voice.phase == .recording))
    }

    private func renderVoice() {
        let voice = workspace.voiceInput
        let available = voiceAvailable
        if !available, voice.owner == voiceOwner { voice.cancel(owner: voiceOwner) }
        let ownsCapture = voice.owner == voiceOwner
        composer.renderVoice(available: available, occupied: voice.phase.busy && !ownsCapture,
                             phase: ownsCapture ? voice.phase : .idle, preview: ownsCapture ? voice.preview : nil)
    }

    func toggleDictation() {
        guard canToggleDictation, let target = workspace.voiceTarget, let key = draftKey else { return }
        let voice = workspace.voiceInput
        if voice.owner == voiceOwner, voice.phase == .recording { voice.finish(owner: voiceOwner); return }
        let preferences = workspace.voicePreferences
        guard let grant = preferences.grant, workspace.supportsVoiceDestination(preferences.cloud) else { onVoiceSettings?(); return }
        do {
            let api = try workspace.voiceAPI(target)
            let anchor = composer.voiceAnchor
            composer.focus()
            let cleanup = preferences.cleanupGrant.flatMap { _ in
                composer.voiceCleanupContext(at: anchor).map { draft in
                    VoiceDictation.Cleanup(draft: draft, vocabulary: workspace.voiceVocabulary(
                        for: displayedProject, hints: [preferences.cleanedCorrectionCue].compactMap { $0 }))
                }
            }
            let request = VoiceDictation.Request(owner: voiceOwner, target: target, preferences: preferences,
                                                 vocabulary: workspace.voiceVocabulary(for: displayedProject), api: api, cleanup: cleanup)
            voice.start(request, isCurrent: { [weak self] in
                guard let self else { return false }
                return voiceAvailable && draftKey == key && workspace.voiceTarget == target && workspace.voicePreferences.grant == grant &&
                    workspace.voicePreferences.cloud == preferences.cloud && composer.voiceAnchor.revision == anchor.revision
            }, isCleanupCurrent: { [weak self] in
                guard let self, let cleanupGrant = preferences.cleanupGrant else { return false }
                return workspace.voiceTarget == target && workspace.voicePreferences.cleanupGrant == cleanupGrant
            }, commit: { [weak self] text, language, send in
                guard let self, draftKey == key else { return }
                try composer.insertDictation(text, at: anchor, language: language, send: send)
            })
        } catch { onError?(error.localizedDescription) }
    }

    var terminalHasFocus: Bool {
        guard terminalShown, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: terminal)
    }

    @objc func findInThread() {
        guard canFindInThread, workspaceVisible else { return }
        findBar.open()
    }

    func stepFind(_ direction: Int) { findBar.step(direction) }

    private func revealFindMatch(_ match: ThreadFindMatch, query: String) async throws -> Bool {
        guard let scope = displayedFindScope else { return false }
        return try await revealEntry(match, query: query, threadID: scope.threadID, connection: scope.connection)
    }

    private func revealEntry(_ match: ThreadFindMatch, query: String, threadID: String, connection: UUID) async throws -> Bool {
        guard workspace.connectionID == connection, displayedSelection == .thread(threadID) else { return false }
        while !timeline.revealFindMatch(match, query: query) {
            try Task.checkCancellation()
            guard let cursor = displayedDetail.historyCursor else { return false }
            try await workspace.loadEarlier(throughEntryID: match.entryID, inSideChat: embedded)
            try Task.checkCancellation()
            guard workspace.connectionID == connection, displayedSelection == .thread(threadID) else { return false }
            if displayedDetail.historyCursor == cursor { return timeline.revealFindMatch(match, query: query) }
        }
        return true
    }

    func openMessageSearchResult(_ result: MessageSearchResult, query: String, scope: MessageSearchScope) {
        guard workspace.messageSearchScope == scope, displayedSelection == .thread(result.hit.threadID) else { return }
        cancelMessageJump()
        findBar.dismiss(restoreFocus: false)
        timeline.clearFind()
        pendingMessageJump = .init(scope: scope, threadID: result.hit.threadID, messageID: result.hit.messageID,
                                   needle: SearchText.messageNeedle(query: query, snippet: result.hit.snippet))
        advanceMessageJump()
    }

    private func cancelMessageJump() {
        pendingMessageJump = nil
        messageJumpTask?.cancel()
        messageJumpTask = nil
        citationJump = nil
        citationJumpTask?.cancel()
        citationJumpTask = nil
    }

    func openCitationSource(_ citation: AssistantCitation) {
        guard workspace.currentServerID == citation.environmentID, displayedSelection == .thread(citation.threadID),
              let connection = workspace.connectionID else { return }
        cancelMessageJump()
        findBar.dismiss(restoreFocus: false)
        timeline.clearFind()
        citationJump = (citation, connection)
        advanceCitationJump()
    }

    private func advanceCitationJump() {
        guard let jump = citationJump else { return }
        let citation = jump.citation
        guard workspaceVisible, workspace.connectionID == jump.connection, displayedSelection == .thread(citation.threadID) else {
            cancelMessageJump()
            return
        }
        if let error = displayedError {
            cancelMessageJump()
            onError?(error)
            return
        }
        guard displayedDetail.loaded, citationJumpTask == nil else { return }
        citationJumpTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { citationJump = nil; citationJumpTask = nil }
            }
            do {
                while workspace.connectionID == jump.connection, displayedSelection == .thread(citation.threadID) {
                    try Task.checkCancellation()
                    switch timeline.revealCitation(citation) {
                    case .shown: return
                    case .changed: throw ClientError.message("The saved quote no longer matches the source response.")
                    case .missing: break
                    }
                    guard let cursor = displayedDetail.historyCursor else { throw ClientError.message("The source response is unavailable.") }
                    try await workspace.loadEarlier(throughEntryID: citation.messageID, inSideChat: embedded)
                    if displayedDetail.historyCursor == cursor {
                        throw ClientError.message("The source response is unavailable.")
                    }
                }
            } catch {
                if !Task.isCancelled, workspace.connectionID == jump.connection, displayedSelection == .thread(citation.threadID) {
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    private func advanceMessageJump() {
        guard let jump = pendingMessageJump else { return }
        guard workspaceVisible, workspace.messageSearchScope == jump.scope, displayedSelection == .thread(jump.threadID) else {
            cancelMessageJump()
            return
        }
        if let error = displayedError {
            cancelMessageJump()
            onError?(error)
            return
        }
        guard displayedDetail.loaded, messageJumpTask == nil else { return }
        guard let id = jump.messageID else {
            pendingMessageJump = nil
            if canFindInThread { findBar.open(searching: jump.needle) }
            else { onError?("The environment could not locate the matching message.") }
            return
        }
        let match = ThreadFindMatch(entryID: id, occurrence: 0)
        messageJumpTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { pendingMessageJump = nil; messageJumpTask = nil }
            }
            do {
                let revealed = try await revealEntry(match, query: jump.needle, threadID: jump.threadID, connection: jump.scope.connection)
                guard !Task.isCancelled, workspace.messageSearchScope == jump.scope,
                      displayedSelection == .thread(jump.threadID) else { return }
                guard revealed else { throw ClientError.message("The matching message is no longer available.") }
                if canFindInThread,
                   let text = displayedDetail.timeline.first(where: { $0.findID == id })?.value["text"].string,
                   !ThreadFindText.ranges(of: jump.needle, in: text).isEmpty {
                    findBar.open(searching: jump.needle, at: match)
                }
            } catch {
                if !Task.isCancelled, workspace.messageSearchScope == jump.scope, displayedSelection == .thread(jump.threadID) {
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    private func openAttachment(_ attachment: ChatAttachment, in entry: TimelineEntry) {
        guard displayedDetail.timeline.contains(where: { $0.id == entry.id && $0.sourceThreadID == entry.sourceThreadID }) else { return }
        openAttachment(attachment, among: entry.attachments)
    }

    private func openAttachment(_ attachment: ChatAttachment, among attachments: [ChatAttachment]) {
        guard let scope = workspace.attachmentScope else { return }
        do {
            let preview = try AttachmentPreviewController(attachments: attachments, selectedID: attachment.id,
                                                          scope: scope, store: attachmentStore)
            attachmentPreview?.close()
            attachmentPreview = preview
            preview.onClose = { [weak self, weak preview] in
                if self?.attachmentPreview === preview { self?.attachmentPreview = nil }
            }
            preview.present()
        } catch { onError?(error.localizedDescription) }
    }

    private func handlePlanAction(_ entry: TimelineEntry, action: ProposedPlan.Action) {
        guard entry.type == "proposed_plan", let markdown = entry.value["markdown"].string,
              let window = view.window else { return }
        let plan = ProposedPlan(markdown: markdown)
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plan.exportContents, forType: .string)
        case .download:
            let panel = NSSavePanel()
            panel.title = "Save Plan as Markdown"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = plan.filename
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { [weak self] result in
                guard result == .OK, let url = panel.url else { return }
                do { try plan.exportContents.write(to: url, atomically: true, encoding: .utf8) }
                catch { self?.onError?(error.localizedDescription) }
            }
        case .saveToWorkspace:
            guard planSave == nil, let target = displayedPlanTarget,
                  displayedDetail.timeline.contains(where: { $0.id == entry.id && $0.sourceThreadID == entry.sourceThreadID }) else { return }
            let editor = ProposedPlanSaveController(plan: plan, workspaceRoot: target.root)
            planSave = editor
            planSaveTarget = target
            editor.onSubmit = { [workspace] path in
                _ = try await workspace.savePlan(plan, relativePath: path, target: target)
            }
            editor.onClose = { [weak self] in
                self?.planSave = nil
                self?.planSaveTarget = nil
            }
            editor.present(in: window)
        }
    }

    private func fork(from entry: TimelineEntry) {
        guard !isForking else { return }
        isForking = true
        timeline.setForkEnabled(false)
        perform {
            defer {
                self.isForking = false
                self.timeline.setForkEnabled(self.workspace.can("orchestration:operate"))
            }
            if try await self.workspace.forkThread(from: entry) { self.focusComposer() }
        }
    }

    private var canRewindSelected: Bool {
        guard !embedded, let thread = displayedThread else { return false }
        return rewindKey == nil && queueEditor == nil && workspace.supportsRewind && workspace.can("orchestration:operate") &&
            !thread.archived && !thread.isWorking && !workspace.sending.contains(.thread(thread.id)) &&
            displayedDetail.requests.isEmpty
    }

    var canEditLastMessage: Bool {
        canRewindSelected && displayedDetail.timeline.contains(where: \.canRewind)
    }

    func editLastMessage() {
        if let entry = displayedDetail.timeline.last(where: \.canRewind) { editFromHere(entry) }
    }

    private func editFromHere(_ entry: TimelineEntry) {
        guard canRewindSelected, entry.canRewind, let key = draftKey, let window = view.window,
              let connection = workspace.connectionID else { return }
        rewindKey = key
        render(.selection)
        perform {
            defer { self.rewindKey = nil; self.render(.selection) }
            let plan = try await self.workspace.prepareRewind(from: entry)
            guard self.draftKey == key, self.workspace.connectionID == connection else { return }
            _ = try self.composer.currentDraft.restoring(plan)
            let confirm = NSAlert()
            confirm.messageText = "Edit from here?"
            confirm.informativeText = "Rewind the conversation to before this message and add its prompt and attachments to your draft. Rewinding files also restores the checkpoint’s file contents."
            confirm.addButton(withTitle: "Rewind Chat")
            confirm.addButton(withTitle: "Rewind Chat and Files")
            confirm.addButton(withTitle: "Cancel")
            confirm.buttons[1].isEnabled = plan.canRestoreFiles
            let response = await confirm.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn,
                  self.workspace.connectionID == connection, self.draftKey == key else { return }
            _ = try self.composer.currentDraft.restoring(plan)
            try await self.workspace.rewind(plan, restoreFiles: response == .alertSecondButtonReturn)
            let current = self.draftKey == key ? self.composer.currentDraft : self.drafts[key] ?? .init()
            let restored = try current.restoring(plan)
            self.drafts[key] = restored
            if self.draftKey == key {
                self.composer.load(restored)
                self.render(.selection)
                self.composer.focusAtEnd()
            }
        }
    }

    func markInspector(_ tab: InspectorController.Tab?) {
        files.isMarked = tab == .files
        changes.isMarked = tab == .changes
        browserButton.isMarked = tab == .browser
    }

    func showBrowserRecording(_ active: Bool) {
        browserButton.contentTintColor = active ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        browserButton.toolTip = active ? "Browser recording active" : "Browser"
        browserButton.setAccessibilityHelp(active ? "A browser recording is active." : nil)
    }

    func attachBrowserRecording(_ clip: BrowserRecordingClip) throws {
        try attachBrowserMedia(PickedAttachment(url: clip.file), target: clip.target)
    }

    func attachBrowserMedia(_ file: PickedAttachment, target: BrowserTabTarget?) throws {
        guard !embedded, let key = draftKey, case .thread(let threadID) = key.selection,
              workspace.environment?.id == key.environmentID, workspace.selectedThread?.id == threadID,
              workspace.selectedThread?.archived == false, workspace.can("orchestration:operate") else {
            throw ClientError.message("Open a conversation with an editable draft to attach the browser capture.")
        }
        if let target, target.environmentID != key.environmentID || target.threadID != threadID {
            throw ClientError.message("Open the conversation that owns this browser tab to attach the capture.")
        }
        try composer.addAttachments([file])
        focusComposer()
    }

    private func attachTerminalContext(_ context: TerminalContext, target: TerminalContextTarget) throws {
        guard !embedded, let key = draftKey, key.environmentID == target.environmentID, key.selection == .thread(target.threadID),
              workspace.connectionID == target.connection, displayedThread?.id == target.threadID,
              displayedThread?.archived == false, displayedThread?.isProviderNativeSubagent != true,
              workspace.can("orchestration:operate") else { throw ClientError.disconnected }
        try composer.addTerminalContext(context)
    }

    func markSideChat(_ shown: Bool) { sideChatsButton.isMarked = shown }

    func seedSideChatDraft(_ reference: SideChatReference, model: Wire) {
        guard embedded, ComposerModels.isSelection(model) else { return }
        let key = DraftKey(environmentID: reference.environmentID, selection: .thread(reference.threadID))
        if drafts[key] == nil { drafts[key] = .init(model: model) }
    }

    func forgetSideChatDraft(_ reference: SideChatReference) {
        guard embedded else { return }
        drafts.removeValue(forKey: DraftKey(environmentID: reference.environmentID, selection: .thread(reference.threadID)))
    }

    func startSideChat() { startSideChat(prompt: "", submitted: nil) }

    private func startSideChat(prompt: String, submitted: ComposerView.Draft?) {
        guard !startingSideChat else { return }
        guard !embedded, let parent = workspace.sideChatParent else {
            onError?(embedded ? "Side chats start from a main conversation." : workspace.sideChatBlockedReason ?? "Side chats are unavailable.")
            return
        }
        let model = submitted?.model ?? composer.selectedModelSelection
        let runtimeMode = submitted?.runtime ?? composer.currentDraft.runtime ?? displayedThread?.runtimeMode
        let key = draftKey
        startingSideChat = true
        render(.selection)
        perform {
            defer { self.startingSideChat = false; self.render(.selection) }
            let reference = try await self.workspace.startSideChat(parent: parent, prompt: prompt, model: model, runtimeMode: runtimeMode)
            if let key, let submitted, self.workspace.environment?.id == reference.environmentID {
                var current = self.draftKey == key ? self.composer.currentDraft : self.drafts[key] ?? .init()
                if current.text == submitted.text {
                    current.text = ""
                    self.drafts[key] = current
                    if self.draftKey == key { self.composer.load(current) }
                }
            }
            self.onSideChatStarted?(reference, prompt.isEmpty ? model : .null)
        }
    }

    private func openThreadLink(_ id: String) {
        if onOpenSideChat?(id) == true { return }
        perform { try await self.workspace.openRelatedThread(id) }
    }

    private func openSideChatMenu() {
        guard let thread = displayedThread else { return }
        let menu = NSMenu()
        if workspace.sideChatParent != nil && !startingSideChat {
            menu.addItem(menuItem("New Side Chat", target: self, action: #selector(newSideChatAction)))
        }
        let children = workspace.data.sideChats(of: thread.id)
        if !menu.items.isEmpty && !children.isEmpty { menu.addItem(.separator()) }
        for child in children {
            let item = menuItem(child.title, target: self, action: #selector(openSideChatFromMenu(_:)))
            item.representedObject = child.id
            if child.isWorking { item.image = WorkspaceStyle.symbol("circle.dotted", size: 11) }
            if workspace.sideChat?.threadID == child.id { item.state = .on }
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sideChatsButton.bounds.height), in: sideChatsButton) }
    }

    @objc private func newSideChatAction() { startSideChat() }
    @objc private func openSideChatFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { openThreadLink(id) }
    }

    private func send(_ draft: ComposerView.Draft) {
        guard let key = draftKey else { return }
        if let prompt = SideChatCommand.prompt(in: draft.text) {
            guard !draft.hasAttachments, !draft.retainedContextRecords.contains(where: { $0["kind"].string == "terminal" }) else {
                onError?("Remove attachments and terminal selections before sending a side chat prompt.")
                return
            }
            startSideChat(prompt: prompt, submitted: draft)
            return
        }
        let text = draft.outgoingText
        let intent = Workspace.SendIntent(destination: key.selection, text: text, model: draft.model,
                                          runtimeMode: draft.runtime ?? "approval-required", interactionMode: draft.interaction ?? "default",
                                          checkout: workspace.explicitDraftCheckout, preparedThreadID: workspace.preparedDraftThreadID,
                                          freshContext: draft.freshContext,
                                          attachments: draft.attachments, retainedAttachments: draft.retainedAttachments,
                                          retainedContextRecords: draft.retainedContextRecords)
        perform {
            try await self.workspace.send(intent)
            self.drafts.removeValue(forKey: key)
            if self.draftKey == key {
                self.composer.load(.init(model: draft.model))
                self.render(.selection)
                self.focusComposer()
            }
        }
    }

    private func renderGoal(_ thread: ThreadSummary?) {
        guard let thread, let goal = thread.goal else { composer.goalBar.render(nil); return }
        let owner = displayedGoalOwner
        let canOperate = !thread.archived && workspace.can("orchestration:operate") &&
            !workspace.sending.contains(.thread(thread.id)) &&
            owner?.commandModel(threadModel: thread.model, providers: workspace.providers) != nil
        composer.goalBar.render(goal, driver: owner?.driver, working: thread.isWorking, canOperate: canOperate)
    }

    private func switchModelNow(_ model: Wire) {
        guard let thread = displayedThread, let runID = thread.activeRunId,
              let connection = workspace.connectionID else { return }
        perform {
            let workspace = self.workspace
            guard workspace.connectionID == connection, let current = self.displayedThread, current.id == thread.id,
                  current.activeRunId == runID, let delivery = self.displayedSwitchDelivery,
                  ComposerModels(providers: workspace.providers).modelSwitch(
                    from: self.displayedDetail.queue.activeModel(for: runID), to: model) != nil else { return }
            try await workspace.send(.init(destination: .thread(current.id), text: "Continue", model: model,
                                           runtimeMode: current.runtimeMode ?? "approval-required",
                                           interactionMode: current.interactionMode ?? "default", checkout: .root(),
                                           preparedThreadID: nil, modelSwitch: delivery))
        }
    }

    private func runGoalAction(_ action: ThreadGoal.Action) {
        guard let thread = displayedThread, let objective = thread.goal?.objective,
              let connection = workspace.connectionID else { return }
        perform {
            let workspace = self.workspace
            guard workspace.connectionID == connection, let current = self.displayedThread,
                  current.id == thread.id, !current.archived, current.activeProviderThreadID == thread.activeProviderThreadID,
                  let goal = current.goal, goal.objective == objective, let owner = self.displayedGoalOwner,
                  goal.allows(action, driver: owner.driver, working: current.isWorking),
                  let model = owner.commandModel(threadModel: current.model, providers: workspace.providers) else { return }
            try await workspace.send(.init(destination: .thread(current.id), text: action.command, model: model,
                                           runtimeMode: current.runtimeMode ?? "approval-required",
                                           interactionMode: current.interactionMode ?? "default", checkout: .root(),
                                           preparedThreadID: nil, deliveryIntent: "auto"))
        }
    }

    var canSendNextQueuedMessage: Bool {
        guard queueScope != nil, !queueBusy, queueEditor == nil else { return false }
        let state = displayedDetail.queue.state
        return state.messages.first.flatMap { state.delivery(for: $0) } != nil
    }

    func sendNextQueuedMessage() {
        guard canSendNextQueuedMessage, let message = displayedDetail.queue.state.messages.first else { return }
        handleQueueAction(.send(message.id))
    }

    private var queueScope: QueueScope? {
        guard let thread = displayedThread, let connection = workspace.connectionID,
              workspace.canEditQueue(threadID: thread.id, connection: connection) else { return nil }
        return QueueScope(threadID: thread.id, connection: connection)
    }

    private var queueEditAllowed: Bool {
        !queueBusy && queueEditor == nil &&
            !displayedDetail.requests.values.contains { $0["kind"].string == "user_input" }
    }

    private func renderQueue() {
        let state = displayedThread != nil ? displayedDetail.queue.state : .init()
        let scope = queueScope
        queuedMessages.render(state, canOperate: scope != nil, canEdit: queueEditAllowed, busy: queueBusy || queueEditor != nil)
        if let target = queueEditTarget {
            queueEditor?.setAvailable(target.scope == scope && state.messages.contains { $0.id == target.runID && $0.editable })
        }
    }

    private func editLastQueuedMessage() -> Bool {
        guard let scope = queueScope, queueEditAllowed, let last = displayedDetail.queue.state.messages.last, last.editable else {
            return false
        }
        return openQueueEditor(last, scope: scope)
    }

    private func handleQueueAction(_ action: QueuedMessagesView.Action) {
        guard let scope = queueScope, !queueBusy, queueEditor == nil else { return }
        let state = displayedDetail.queue.state
        switch action {
        case .resume:
            guard state.held, state.activeRunID == nil else { return }
            runQueueCommand("queue.resume", scope: scope)
        case .send(let runID):
            guard let message = state.messages.first(where: { $0.id == runID }), let delivery = state.delivery(for: message) else { return }
            switch delivery {
            case .start: runQueueCommand("queued-run.start", scope: scope, fields: ["runId": .string(runID)])
            case .steer(let active):
                runQueueCommand("queued-message.promote-to-steer", scope: scope,
                                fields: ["queuedRunId": .string(runID), "targetRunId": .string(active)])
            }
        case .edit(let runID):
            guard queueEditAllowed, let message = state.messages.first(where: { $0.id == runID && $0.editable }) else { return }
            _ = openQueueEditor(message, scope: scope)
        case .remove(let runID):
            guard state.messages.contains(where: { $0.id == runID }) else { return }
            runQueueCommand("queued-run.cancel", scope: scope, fields: ["runId": .string(runID)])
        }
    }

    private func runQueueCommand(_ type: String, scope: QueueScope, fields: Payload = [:]) {
        queueBusy = true
        renderQueue()
        perform {
            defer { self.queueBusy = false; self.renderQueue() }
            guard self.queueScope == scope else { throw ClientError.disconnected }
            try await self.workspace.dispatch(type, threadId: scope.threadID, fields)
        }
    }

    private func openQueueEditor(_ message: QueuedMessage, scope: QueueScope) -> Bool {
        guard let window = view.window, window.attachedSheet == nil else { return false }
        let clipboardSource = workspace.currentServerID.map { TerminalContextClipboard.Source(environmentID: $0, threadID: scope.threadID) }
        let editor = QueuedMessageEditor(message: message, terminalClipboardSource: clipboardSource)
        queueEditor = editor
        queueEditTarget = (scope, message.id)
        editor.onSubmit = { [workspace] attempt in
            try await workspace.editQueuedMessage(attempt, threadID: scope.threadID, runID: message.id, connection: scope.connection)
        }
        editor.onClose = { [weak self] in
            guard let self else { return }
            queueEditTarget = nil
            queueEditor = nil
            renderQueue()
            focusComposer()
        }
        editor.present(in: window)
        return true
    }

    private func loadEarlier() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        earlier.isEnabled = false
        perform {
            defer { self.isLoadingHistory = false; self.earlier.isEnabled = true }
            try await self.workspace.loadEarlier(inSideChat: self.embedded)
        }
    }

    private func stop() {
        guard let thread = displayedThread else { return }
        perform { try await self.workspace.dispatch("thread.stop", threadId: thread.id) }
    }

    private func setMode(_ kind: String, _ value: String) {
        guard let thread = displayedThread else { return }
        let command = kind == "runtimeMode" ? "thread.runtime-mode.set" : "thread.interaction-mode.set"
        perform { try await self.workspace.dispatch(command, threadId: thread.id, [kind: .string(value)]) }
    }

    func showSourceControl() {
        guard let target = workspace.repository, let window = view.window, window.attachedSheet == nil else { return }
        let panel = RepositoryActionsController(workspace: workspace, target: target)
        gitPanel = panel
        panel.onRepositoryChange = onRepositoryChange
        panel.onClose = { [weak self] in self?.gitPanel = nil }
        panel.present(in: window)
    }

    var canChooseBranch: Bool {
        guard let target = workspace.repository, workspace.can("orchestration:operate") else { return false }
        if case .newWorktree = displayedCheckout { return true }
        return workspace.canChangeRepository(target)
    }

    func showBranches() {
        if case .newWorktree = displayedCheckout { chooseWorktree() }
        else { showBranchPicker(.checkout) }
    }

    private func chooseWorktree() {
        let base = displayedCheckout.branch
        showBranchPicker(.worktreeBase(base))
        render(.selection)
    }

    private func showBranchPicker(_ mode: RepositoryBranchPicker.Mode) {
        guard let target = workspace.repository, workspace.can("orchestration:operate"),
              let window = view.window, window.attachedSheet == nil else { return }
        if !mode.selectsBase && !workspace.canChangeRepository(target) { return }
        let panel = RepositoryBranchPicker(workspace: workspace, target: target, mode: mode)
        branchPicker = panel
        panel.onClose = { [weak self] in
            self?.branchPicker = nil
            self?.focusComposer()
        }
        panel.present(in: window)
    }

    func showPullRequestCheckout(reference: String? = nil) {
        guard let target = workspace.repository, workspace.canChangeRepository(target), workspace.can("orchestration:operate"),
              let window = view.window, window.attachedSheet == nil else { return }
        let panel = RepositoryRequestCheckout(workspace: workspace, target: target, initialReference: reference)
        requestCheckout = panel
        panel.onClose = { [weak self] in self?.requestCheckout = nil }
        panel.onPrepared = { [weak self] checkout, threadID, onHead in
            guard let self, workspace.isCurrent(target) else { return }
            workspace.showArchive(false)
            workspace.select(.project(target.project.id))
            workspace.setDraftCheckout(checkout, threadID: threadID)
            focusComposer()
            if !onHead {
                onError?("The existing checkout has local commits or edits. Review it before using this thread.")
            }
        }
        panel.present(in: window)
    }

    private func chooseAttachments() {
        guard let window = view.window, let key = draftKey else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach Files"
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.prepareAttachments(panel.urls.map(AttachmentInput.file), for: key) }
        }
    }

    private func prepareAttachments(_ inputs: [AttachmentInput], for key: DraftKey) {
        guard preparingAttachments.insert(key).inserted else {
            onError?("Wait for the current attachments to finish preparing.")
            return
        }
        if draftKey == key { composer.setPreparingAttachments(true) }
        Task { [weak self] in
            defer {
                if let self {
                    preparingAttachments.remove(key)
                    if draftKey == key { composer.setPreparingAttachments(false) }
                }
            }
            do {
                let files = try await AttachmentInput.prepare(inputs)
                guard let self, preparingAttachments.contains(key) else { return }
                if draftKey == key { try composer.addAttachments(files) }
                else {
                    var draft = drafts[key] ?? .init()
                    try draft.addAttachments(files)
                    drafts[key] = draft
                }
            } catch { self?.onError?(error.localizedDescription) }
        }
    }

    private func threadMenu() {
        let menu = NSMenu()
        if let thread = displayedThread { addThreadActions(thread, to: menu) }
        if let target = workspace.projectActionTarget, let project = displayedProject {
            let actions = workspace.projectActions(project)
            if !actions.isEmpty {
                let submenu = NSMenu()
                for action in actions {
                    let item = menuItem(action.draft.name, target: self, action: #selector(runProjectActionFromMenu(_:)))
                    item.image = WorkspaceStyle.symbol(action.draft.icon.symbol, size: 11)
                    item.representedObject = (action, target)
                    submenu.addItem(item)
                }
                let item = NSMenuItem(title: "Run Project Action", action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        if let target = displayedProject.flatMap({ workspace.projectTarget($0.id) }) {
            if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            let item = menuItem("Project Settings…", target: self, action: #selector(openProjectSettings(_:)))
            item.representedObject = target
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more)
    }

    private func addThreadActions(_ thread: ThreadSummary, to menu: NSMenu) {
        if !embedded, workspace.deviceScope != nil {
            let item = menuItem("Toggle Device", target: self, action: #selector(toggleDevice))
            item.image = WorkspaceStyle.symbol("iphone", size: 11)
            menu.addItem(item)
        }
        if workspace.threadRelationshipScope != nil && onRelatedConversations != nil {
            menu.addItem(menuItem("Related Conversations…", target: self, action: #selector(showRelatedConversations)))
            menu.addItem(.separator())
        }
        if canFindInThread {
            menu.addItem(menuItem("Find in Thread…", target: self, action: #selector(findInThread)))
            if workspace.can("orchestration:operate") || !thread.pullRequests.isEmpty { menu.addItem(.separator()) }
        }
        if canEditLastMessage {
            menu.addItem(menuItem("Edit Last Message…", target: self, action: #selector(editLastMessageAction)))
            menu.addItem(.separator())
        }
        if canOpenGuestShare {
            let item = menuItem(displayedDetail.guestShare == nil ? "Share with Guest…" : "Manage Guest Share…",
                                target: self, action: #selector(openGuestShare))
            item.image = WorkspaceStyle.symbol("person.2", size: 11)
            menu.addItem(item)
        }
        let actions = thread.archived ? [("Restore Thread", "thread.unarchive")] : [
            ("Rename Thread…", "rename"),
            ("Schedule Task…", "schedule"),
            (thread.pinned ? "Unpin Thread" : "Pin Thread", thread.pinned ? "thread.unpin" : "thread.pin"),
            ("Archive Thread", "thread.archive"),
        ]
        for (title, command) in actions where workspace.can("orchestration:operate") {
            let item = menuItem(title, target: self, action: #selector(runThreadAction(_:)))
            item.representedObject = [thread.id, command]
            menu.addItem(item)
        }
        if workspace.can("orchestration:read"), !thread.pullRequests.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for reference in thread.pullRequests {
                let item = menuItem("Review \(reference.repository) #\(reference.number)", target: self, action: #selector(openLinkedPullRequest(_:)))
                item.representedObject = reference
                menu.addItem(item)
            }
        }
    }

    @objc private func showRelatedConversations() { onRelatedConversations?() }

    @objc func openGuestShare() {
        guard canOpenGuestShare, let target = displayedGuestTarget, let thread = displayedThread,
              let window = view.window, window.attachedSheet == nil else { return }
        let sheet = GuestShareSheet(workspace: workspace, target: target, threadTitle: thread.title)
        guestSheet = sheet
        sheet.onClose = { [weak self, weak sheet] in
            if self?.guestSheet === sheet { self?.guestSheet = nil }
        }
        sheet.present(in: window)
    }

    private func renderGuestShare(_ share: GuestShare?) {
        if let share {
            let status = workspace.guestSharingEnabled == false ? "Guest links off" : share.status(at: Date())
            let count = share.pending.count
            guestSharing.title = count == 0 ? status : "\(status) · \(count) waiting"
            guestSharing.setAccessibilityLabel("Manage Guest Share")
            guestSharing.setAccessibilityHelp(guestSharing.title)
            guestSharing.isEnabled = canOpenGuestShare
            guestSharing.isMarked = count > 0
        }
        guestSharingRow.isHidden = share == nil
        guestSheet?.sync()
        let expiry = share?.expiresAt
        guard guestExpiry != expiry else { return }
        guestExpiry = expiry
        guestExpiryTask?.cancel()
        guestExpiryTask = nil
        if let seconds = expiry?.timeIntervalSinceNow, seconds > 0 {
            guestExpiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                self?.render(.timeline)
            }
        }
    }

    private func resolveGuestMessage(_ id: String, shareID: String, decision: GuestMessage.Decision) {
        guard let target = displayedGuestTarget, guestResolutions.insert(id).inserted else { return }
        render(.timeline)
        Task { [weak self] in
            guard let self else { return }
            defer {
                guestResolutions.remove(id)
                render(.timeline)
            }
            do { try await workspace.resolveGuestMessage(id, shareID: shareID, decision: decision, target: target) }
            catch {
                if displayedGuestTarget == target { onError?(error.localizedDescription) }
            }
        }
    }

    @objc private func toggleDevice() { onInspector?(.device) }

    @objc private func openProjectSettings(_ item: NSMenuItem) {
        if let target = item.representedObject as? ProjectTarget { onProjectSettings?(target) }
    }

    @objc private func runProjectActionFromMenu(_ item: NSMenuItem) {
        guard let (action, target) = item.representedObject as? (ProjectAction, ProjectActionTarget) else { return }
        runProjectAction(action, target: target)
    }

    @objc private func openLinkedPullRequest(_ item: NSMenuItem) {
        if let reference = item.representedObject as? PullRequestReference { onOpenPullRequest?(reference) }
    }

    @objc private func editLastMessageAction() { editLastMessage() }

    @objc private func runThreadAction(_ item: NSMenuItem) {
        if let args = item.representedObject as? [String], args.count == 2 { onThreadAction?(args[0], args[1]) }
    }

    private func renderRequest(_ entries: [TimelineEntry]) {
        if let questionEditor { questionEditor.setAvailable(workspace.canAnswerQuestion(questionEditor.target)) }
        let pending = displayedDetail.requests.values.filter { value in
            ["command", "file-read", "file-change", "mcp-elicitation", "permission", "user_input"].contains(value["kind"].string ?? "")
        }.sorted { ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "") }
        let id = pending.first?["id"].string
        timeline.setAppAwaitingUser(id != nil)
        latestRequest = id.map { id in (id, entries.last { $0.requestId == id }) }
        requestBar.isHidden = id == nil
        requestLabel.stringValue = pending.count > 1 ? "\(pending.count) requests need your attention" :
            pending.first?["kind"].string == "user_input" ? "The agent has a question" : "The agent is requesting approval"
        review.isEnabled = workspace.can("orchestration:operate") && latestRequest?.entry != nil
    }

    private func sendAppMessage(_ text: String, conversation: String, scope: AttachmentScope) async throws {
        guard let thread = displayedThread, thread.id == conversation, !thread.archived, !thread.isProviderNativeSubagent,
              workspace.attachmentScope == scope, workspace.can("orchestration:operate") else { throw ClientError.disconnected }
        let model = composer.selectedModelSelection == .null ? thread.model : composer.selectedModelSelection
        try await workspace.send(.init(destination: .thread(conversation), text: text, model: model,
                                       runtimeMode: composer.currentDraft.runtime ?? thread.runtimeMode ?? "approval-required",
                                       interactionMode: "default", checkout: nil, preparedThreadID: nil))
    }

    private func reviewRequest() {
        guard let window = view.window, let request = latestRequest, let entry = request.entry,
              let thread = displayedThread else { return }
        if entry.type == "user_input_request" {
            reviewQuestions(entry, requestID: request.id, threadID: thread.id, window: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = entry.value["title"].string ?? "Approval requested"
        alert.informativeText = String((entry.value["prompt"].string ?? entry.value["reason"].string ?? "Review this provider request.").prefix(1_800))
        let supplied = entry.value["options"].array.compactMap { option -> (String, String)? in
            guard let label = option["label"].string, let decision = option["decision"].string else { return nil }
            return (label, decision)
        }
        let options = supplied.isEmpty ? [("Allow Once", "accept"), ("Decline", "decline")] : supplied
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        for (label, _) in options { alert.addButton(withTitle: label) }
        alert.beginSheetModal(for: window) { [weak self] result in
            let index = result.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - 1
            guard let self, options.indices.contains(index) else { return }
            perform {
                try await self.workspace.dispatch("runtime-request.respond", threadId: thread.id, [
                    "requestId": .string(request.id), "decision": .string(options[index].1),
                ])
            }
        }
    }

    private func reviewQuestions(_ entry: TimelineEntry, requestID: String, threadID: String, window: NSWindow) {
        guard questionEditor == nil, workspace.can("orchestration:operate"), let environment = workspace.environment else { return }
        let target = Workspace.QuestionResponseTarget(environmentID: environment.id, threadID: threadID, requestID: requestID)
        let capability = displayedDetail.requests[requestID]?["responseCapability"]
        if capability?["type"].string == "not_resumable" {
            let alert = NSAlert()
            alert.messageText = "Question unavailable"
            alert.informativeText = capability?["reason"].string ?? "The provider session has ended."
            alert.addButton(withTitle: "Dismiss Question")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] result in
                guard let self, result == .alertFirstButtonReturn else { return }
                perform {
                    let workspace = self.workspace
                    guard workspace.environment?.id == target.environmentID, self.displayedSelection == .thread(threadID),
                          workspace.can("orchestration:operate"),
                          self.displayedDetail.requests[requestID]?["responseCapability"]["type"].string == "not_resumable" else {
                        throw ClientError.disconnected
                    }
                    try await workspace.dispatch("thread.user-input.dismiss", threadId: threadID, ["requestId": .string(requestID)])
                }
            }
            return
        }
        guard workspace.canAnswerQuestion(target) else { return }
        let questions = entry.value["questions"].array.compactMap(AgentQuestion.init)
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count else {
            onError?("The provider returned an invalid set of questions.")
            return
        }
        let controller = QuestionAnswerController(target: target, questions: questions, supportsAttachments: workspace.supportsQuestionAttachments)
        questionEditor = controller
        controller.onSubmit = { [workspace] attempt in try await workspace.answerQuestion(attempt, target: target) }
        controller.onClose = { [weak self] in self?.questionEditor = nil }
        controller.present(in: window)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch { onError?(error.localizedDescription) }
        }
    }
}
