import AppKit

@MainActor
private final class PromptTextView: CitationTextView {
    var onSend: (() -> Void)?
    var onEditQueued: (() -> Bool)?
    var onSuggestionKey: ((NSEvent) -> Bool)?
    var onCancelQueueEdit: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onSuggestionKey?(event) == true { return }
        if event.keyCode == 53, event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           !hasMarkedText(), onCancelQueueEdit?() == true { return }
        if event.keyCode == 126, event.modifierFlags.intersection([.shift, .control, .option, .command]) == .option,
           !event.isARepeat, !hasMarkedText(), selectedRange() == NSRange(location: 0, length: 0),
           onEditQueued?() == true { return }
        if !handleSendKey(event, modifiers: []) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleSendKey(event, modifiers: .command) || super.performKeyEquivalent(with: event)
    }

    private func handleSendKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        let pressed = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard pressed == modifiers, event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else { return false }
        if !event.isARepeat { onSend?() }
        return true
    }
}

@MainActor
final class ComposerView: NSView, NSTextViewDelegate {
    enum QueueEditState: Equatable {
        case editing, saving, unavailable, failed(String)

        var canSave: Bool {
            switch self {
            case .editing, .failed: true
            case .saving, .unavailable: false
            }
        }
    }

    struct Draft {
        var text = ""
        var model: Wire = .null
        var runtime: String?
        var interaction: String?
        var freshContext = false
        var attachments: [PickedAttachment] = []
        var retainedAttachments: [Wire] = []
        var retainedContextRecords: [Wire] = []

        var hasAttachments: Bool { !attachments.isEmpty || !retainedAttachments.isEmpty }
        var outgoingText: String {
            let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty && hasAttachments ? QueuedMessage.attachmentOnlyText : prompt
        }

        mutating func addAttachments(_ files: [PickedAttachment]) throws {
            let combined = attachments + files
            try PickedAttachment.validate(combined, retaining: retainedAttachments)
            attachments = combined
        }

        func restoring(_ plan: ThreadRewind.Plan) throws -> Self {
            var next = self
            if !plan.text.isEmpty { next.text = text.isEmpty ? plan.text : text + "\n\n" + plan.text }
            var ids = Set(retainedAttachments.compactMap { $0["id"].string })
            next.retainedAttachments += plan.attachments.filter {
                guard let id = $0["id"].string else { return false }
                return ids.insert(id).inserted
            }
            var contextIDs = Set(retainedContextRecords.compactMap { $0["contextId"].string })
            next.retainedContextRecords += plan.contextRecords.filter {
                guard let id = $0["contextId"].string else { return false }
                return contextIDs.insert(id).inserted
            }
            try PickedAttachment.validate(next.attachments, retaining: next.retainedAttachments)
            return next
        }
    }

    private let editor = PromptTextView()
    let goalBar = ThreadGoalBar()
    let usageLimits = ComposerUsageLimits()
    private let suggestions = ComposerCommandSuggestions()
    private let activeModelLabel = label(size: 11.5, color: WorkspaceStyle.secondary)
    private lazy var switchModel = ActionButton("Switch now", symbol: "arrow.right", style: .subtle) { [weak self] in
        self?.submitModelSwitch()
    }
    private lazy var modelSwitchBar = row([
        WorkspaceStyle.icon("arrow.left.arrow.right", size: 11, tint: WorkspaceStyle.muted), activeModelLabel, NSView(), switchModel,
    ], spacing: 6)
    private let freshLabel = label("Next message starts a new session", size: 11.5, color: WorkspaceStyle.secondary)
    private let queueEditTitle = label("Editing queued message", size: 11.5, weight: .medium, color: WorkspaceStyle.modelFocus)
    private let queueEditNotice = label(size: 11.5, color: WorkspaceStyle.muted)
    private lazy var cancelQueueEdit = ActionButton("Cancel Edit", symbol: "xmark", iconOnly: true, style: .subtle) {
        [weak self] in _ = self?.cancelQueuedEdit()
    }
    private lazy var queueEditBar = row([
        WorkspaceStyle.icon("pencil", size: 11, tint: WorkspaceStyle.modelFocus), queueEditTitle, NSView(), cancelQueueEdit,
    ], spacing: 6)
    private lazy var freshBanner = row([
        WorkspaceStyle.icon("arrow.counterclockwise", size: 11), freshLabel, NSView(),
        ActionButton("Cancel Fresh Session", symbol: "xmark", iconOnly: true, style: .subtle) { [weak self] in
            self?.setFreshContext(false)
        },
    ], spacing: 6)
    private let placeholder = label("Ask the agent to do something…", size: 14, color: WorkspaceStyle.muted)
    private let modelPicker = ComposerModelPicker()
    private let runtime = NSPopUpButton()
    private let interaction = NSPopUpButton()
    private let checkout = NSPopUpButton()
    private let workspaceLabel = label("Local checkout", size: 11.5, color: WorkspaceStyle.muted)
    private lazy var branch = ActionButton("Branch", symbol: "arrow.triangle.branch", style: .subtle) { [weak self] in
        self?.onBranch?()
    }
    private lazy var permissionControl = row([WorkspaceStyle.icon("lock", size: 12), runtime], spacing: 3)
    private lazy var modeControl = row([WorkspaceStyle.icon("hammer", size: 12), interaction], spacing: 3)
    private lazy var attach = ActionButton("Attach Files…", symbol: "paperclip", iconOnly: true, style: .subtle) { [weak self] in self?.onAttach?() }
    private lazy var voice = ActionButton("Start Dictation", symbol: "mic", iconOnly: true, style: .subtle) { [weak self] in self?.onVoiceToggle?() }
    private lazy var cancelVoice = ActionButton("Cancel Dictation", symbol: "xmark", iconOnly: true, style: .subtle) { [weak self] in self?.onVoiceCancel?() }
    private let voiceStatus = label(size: 11.5, weight: .medium, color: WorkspaceStyle.muted)
    private let voicePreview = label(size: 12, color: WorkspaceStyle.secondary)
    private lazy var voiceSettings = ActionButton("Voice Settings…", style: .subtle) { [weak self] in self?.onVoiceSettings?() }
    private lazy var voiceBar = row([voiceStatus, voicePreview, NSView(), voiceSettings], spacing: 7)
    private lazy var attachmentMenu = ActionButton("Attachments", symbol: "paperclip", style: .subtle) { [weak self] in self?.showAttachments() }
    private lazy var send = ActionButton("Send (↩)", symbol: "arrow.up", iconOnly: true, style: .send) { [weak self] in self?.submit() }
    private var selectedModel: Wire = .null
    private var catalog = ComposerModels(providers: [])
    private var modelOptions = ComposerModelOptions()
    private var lastFallbackModel: Wire = .null
    private var draft = Draft()
    private var queueEditState: QueueEditState?
    private var canSend = false
    private var isSending = false
    private var preparingAttachments = false
    private var isWorking = false
    private var commandConnection: UUID?
    private var commandCwd: String?
    private var commandHistory = false
    private var sideChatsAvailable = false
    private var freshAvailable = false
    private var commandScope: ComposerCommandScope?
    private var scopedCatalog: ComposerCommandCatalog?
    private var catalogTask: Task<Void, Never>?
    private var catalogFailed = false
    private var activeTrigger: ComposerCommandTrigger?
    private var dismissedTrigger: ComposerCommandTrigger?
    private var promptHeight: NSLayoutConstraint?
    private var lastPromptWidth: CGFloat = 0
    private var voicePhase = VoiceDictation.Phase.idle
    private var draftRevision = 0
    var onSend: ((Draft) -> Void)?
    var onDraftChange: ((Draft) -> Void)?
    var onModeChange: ((String, String) -> Void)?
    var onWorktree: (() -> Void)?
    var onRootCheckout: (() -> Void)?
    var onBranch: (() -> Void)?
    var onAttach: (() -> Void)?
    var onVoiceToggle: (() -> Void)?
    var onVoiceCancel: (() -> Void)?
    var onVoiceSend: (() -> Void)?
    var onVoiceSettings: (() -> Void)?
    var onOpenCitation: ((AssistantCitation) -> Void)? {
        didSet { editor.onOpenCitation = onOpenCitation }
    }
    var onReadAttachment: ((NSPasteboard) -> Bool)? {
        didSet { editor.onReadAttachment = onReadAttachment }
    }
    var onModelChange: (() -> Void)?
    var onSwitchModel: ((Wire) -> Void)?
    var onEditQueued: (() -> Bool)?
    var onSaveQueuedEdit: ((Draft) -> Void)?
    var onCancelQueuedEdit: (() -> Void)?
    var loadCommandCatalog: (@MainActor (ComposerCommandScope) async throws -> ComposerCommandCatalog)?
    var currentDraft: Draft { draft }
    var selectedModelSelection: Wire { selectedModel }
    var canDictate: Bool { canSend && !isSending && queueEditState == nil }
    var canManageAttachments: Bool { canSend && !isSending && queueEditState?.canSave != false }
    var canAttachFiles: Bool { canManageAttachments && !preparingAttachments }
    var voiceAnchor: VoiceDraftAnchor { .init(revision: draftRevision, range: editor.selectedRange()) }
    private var sendBlockReason: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let shell = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 20)
        let prompt = NSView()
        let scroll = textScroller(editor, editable: true)
        fill(scroll, in: prompt)
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = WorkspaceStyle.ink
        editor.insertionPointColor = WorkspaceStyle.ink
        editor.enableCitationEditing()
        editor.textContainerInset = NSSize(width: 3, height: 4)
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.delegate = self
        editor.setAccessibilityLabel("Prompt")
        editor.onSend = { [weak self] in self?.submit() }
        editor.onEditQueued = { [weak self] in self?.onEditQueued?() ?? false }
        editor.onSuggestionKey = { [weak self] event in self?.handleSuggestionKey(event) ?? false }
        editor.onCancelQueueEdit = { [weak self] in self?.cancelQueuedEdit() ?? false }
        suggestions.onPick = { [weak self] item in self?.applySuggestion(item) }
        prompt.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let inputHeight = prompt.heightAnchor.constraint(equalToConstant: 42)
        promptHeight = inputHeight
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: prompt.leadingAnchor, constant: 8),
            placeholder.topAnchor.constraint(equalTo: prompt.topAnchor, constant: 4),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: prompt.trailingAnchor, constant: -6),
            inputHeight,
        ])
        placeholder.setAccessibilityElement(false)

        for picker in [runtime, interaction, checkout] {
            picker.controlSize = .small
            picker.isBordered = false
            picker.font = .systemFont(ofSize: 12)
            picker.contentTintColor = WorkspaceStyle.secondary
            picker.target = self
            picker.action = #selector(picked(_:))
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        runtime.setAccessibilityLabel("Permissions")
        interaction.setAccessibilityLabel("Interaction Mode")
        checkout.setAccessibilityLabel("Workspace")
        checkout.cell?.lineBreakMode = .byTruncatingTail
        checkout.widthAnchor.constraint(lessThanOrEqualToConstant: 145).isActive = true
        for picker in [runtime, interaction, checkout] {
            picker.font = .systemFont(ofSize: 11.5)
        }
        send.image = WorkspaceStyle.symbol("arrow.up", size: 13, weight: .semibold)
        send.widthAnchor.constraint(equalToConstant: 31).isActive = true
        send.heightAnchor.constraint(equalToConstant: 31).isActive = true
        attach.widthAnchor.constraint(equalToConstant: 27).isActive = true
        attach.heightAnchor.constraint(equalToConstant: 27).isActive = true
        attachmentMenu.alignment = .left
        modelPicker.onPickModel = { [weak self] model in self?.pickModel(model) }
        modelPicker.onPickOption = { [weak self] id, value in self?.setModelOption(id, value: value) }
        for control in [voice, cancelVoice] {
            control.widthAnchor.constraint(equalToConstant: 27).isActive = true
            control.heightAnchor.constraint(equalToConstant: 27).isActive = true
            control.isHidden = true
        }
        voiceBar.isHidden = true
        voiceStatus.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        voicePreview.lineBreakMode = .byTruncatingHead
        let actions = row([modelPicker, NSView(), attach, cancelVoice, voice, send], spacing: 10)
        freshBanner.isHidden = true
        freshBanner.heightAnchor.constraint(equalToConstant: 21).isActive = true
        switchModel.font = .systemFont(ofSize: 11.5, weight: .medium)
        switchModel.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelSwitchBar.isHidden = true
        modelSwitchBar.heightAnchor.constraint(equalToConstant: 24).isActive = true
        cancelQueueEdit.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cancelQueueEdit.heightAnchor.constraint(equalToConstant: 21).isActive = true
        queueEditBar.isHidden = true
        queueEditNotice.maximumNumberOfLines = 2
        queueEditNotice.lineBreakMode = .byWordWrapping
        queueEditNotice.isHidden = true
        let stack = column([goalBar, modelSwitchBar, freshBanner, queueEditBar, prompt, attachmentMenu, queueEditNotice, voiceBar, actions],
                           spacing: 5, alignment: .width)
        fill(stack, in: shell, inset: 11)

        let location = row([WorkspaceStyle.icon("folder", size: 11, tint: WorkspaceStyle.muted), checkout, workspaceLabel], spacing: 5)
        branch.font = .systemFont(ofSize: 11.5)
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([location, NSView(), permissionControl, modeControl, branch, usageLimits], spacing: 8)
        runtime.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        interaction.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        footer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let panel = column([suggestions, shell, footer], spacing: 5, alignment: .width)
        fill(panel, in: self)
        updateAttachments()
        setBranch(nil, available: false, enabled: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if abs(editor.bounds.width - lastPromptWidth) > 1 {
            lastPromptWidth = editor.bounds.width
            updatePromptHeight()
        }
    }

    func load(_ draft: Draft) {
        draftRevision += 1
        self.draft = draft
        usageLimits.close()
        modelPicker.close()
        modelSwitchBar.isHidden = true
        dismissedTrigger = nil
        activeTrigger = nil
        suggestions.dismiss()
        editor.setPromptSource(draft.text, contextRecords: draft.retainedContextRecords)
        editor.undoManager?.removeAllActions()
        lastFallbackModel = .null
        updateAttachments()
        updatePromptHeight()
        updateSend()
    }

    func render(providers: [Provider], defaultModel: Wire, thread: ThreadSummary?, checkout draftCheckout: WorkspaceCheckout,
                projectAvailable: Bool,
                canOperate: Bool, sending: Bool) {
        catalog = ComposerModels(providers: providers)
        lastFallbackModel = defaultModel
        canSend = canOperate && projectAvailable && thread?.archived != true
        isSending = sending
        isWorking = thread?.isWorking == true
        let current = catalog.initialSelection(draft: draft.model, fallback: defaultModel, existingThread: thread != nil)
        updateModelPickers(current)
        let provider = catalog.provider(for: current)
        let modes = [("approval-required", "Ask for approval"), ("auto-accept-edits", "Auto-accept edits"),
                     ("auto", "Auto"), ("full-access", "Full access")]
        let supported = provider?.modes ?? ["approval-required", "auto-accept-edits", "auto", "full-access"]
        let available = modes.filter { supported.contains($0.0) || $0.0 == thread?.runtimeMode }
        configure(runtime, values: available, selection: draft.runtime ?? thread?.runtimeMode ?? "approval-required")
        permissionControl.isHidden = available.isEmpty
        configure(interaction, values: [("default", "Agent"), ("plan", "Plan")], selection: draft.interaction ?? thread?.interactionMode)
        modeControl.isHidden = provider?.supportsPlan != true && thread?.interactionMode != "plan"
        let selectedCheckout: String
        let checkoutTitle: String
        switch draftCheckout {
        case .root: (selectedCheckout, checkoutTitle) = ("root", "New worktree…")
        case .newWorktree(let base): (selectedCheckout, checkoutTitle) = ("worktree", "Worktree from \(base)")
        case .worktree: (selectedCheckout, checkoutTitle) = ("existing", "New worktree…")
        }
        var choices = [("root", "Local checkout"), ("worktree", checkoutTitle)]
        if selectedCheckout == "existing" { choices.append(("existing", "Existing worktree")) }
        configure(checkout, values: choices, selection: selectedCheckout)
        checkout.item(at: 1)?.title = checkoutTitle
        checkout.isHidden = thread != nil
        workspaceLabel.isHidden = thread == nil
        workspaceLabel.stringValue = thread?.worktreePath == nil ? "Local checkout" : "Worktree"
        checkout.isEnabled = canSend && !sending
        placeholder.stringValue = isWorking ? "Queue a follow-up…" :
            thread == nil ? "Ask the agent to do something…" : "Continue the conversation…"
        updateAttachments()
        updateSend()
    }

    func renderQueueEdit(_ state: QueueEditState?) {
        guard queueEditState != state else { return }
        queueEditState = state
        queueEditBar.isHidden = state == nil
        queueEditTitle.stringValue = state == .saving ? "Saving queued message…" : "Editing queued message"
        cancelQueueEdit.isEnabled = state != .saving
        let notice: String
        switch state {
        case .unavailable: notice = "This queued message is unavailable. You can copy your changes or cancel the edit."
        case .failed(let error): notice = error
        default: notice = ""
        }
        if case .failed = state { queueEditNotice.textColor = WorkspaceStyle.negative }
        else { queueEditNotice.textColor = WorkspaceStyle.muted }
        queueEditNotice.stringValue = notice
        queueEditNotice.toolTip = notice
        queueEditNotice.isHidden = notice.isEmpty
        modelPicker.isHidden = state != nil
        if state != nil { modelPicker.close(); modelSwitchBar.isHidden = true }
        send.image = WorkspaceStyle.symbol(state == nil ? "arrow.up" : "checkmark", size: 13, weight: .semibold)
        send.setAccessibilityLabel(state == nil ? "Send (↩)" : "Save Queued Message")
        updateAttachments()
        updateSend()
    }

    private func cancelQueuedEdit() -> Bool {
        guard let queueEditState else { return false }
        if queueEditState != .saving { onCancelQueuedEdit?() }
        return true
    }

    func focus() { window?.makeFirstResponder(editor) }

    func setTerminalClipboardSource(_ source: TerminalContextClipboard.Source?) { editor.terminalClipboardSource = source }

    func addTerminalContext(_ context: TerminalContext) throws {
        guard editor.isEditable else { throw ClientError.message("This conversation’s draft is read-only.") }
        guard draft.retainedContextRecords.count < TerminalContext.maximumRecords else {
            throw ClientError.message("A message can contain up to 200 context items.")
        }
        focus()
        guard editor.addTerminalContext(context) else { throw ClientError.message("The terminal selection could not be added.") }
    }

    func cite(_ citation: AssistantCitation) -> Bool {
        guard editor.isEditable else { return false }
        focus()
        return editor.addCitation(citation)
    }

    func closeQuote() { editor.closeCitation() }

    func voiceCleanupContext(at anchor: VoiceDraftAnchor) -> Wire? {
        anchor.cleanupContext(editor.string)
    }

    func renderVoice(available: Bool, occupied: Bool, phase: VoiceDictation.Phase, preview: String?) {
        let changed = voicePhase != phase
        voicePhase = phase
        voice.isHidden = !available && !phase.busy
        voice.isEnabled = !occupied && (phase == .recording || !phase.busy)
        if changed {
            voice.isMarked = phase == .recording
            voice.image = WorkspaceStyle.symbol(phase == .recording ? "checkmark" : "mic", size: 14)
            let title = phase == .recording ? "Finish Dictation" : "Start Dictation"
            voice.toolTip = title
            voice.setAccessibilityLabel(title)
        }
        cancelVoice.isHidden = !phase.busy
        voiceBar.isHidden = phase == .idle
        voiceSettings.isHidden = true
        voiceStatus.textColor = WorkspaceStyle.muted
        voiceStatus.stringValue = switch phase {
        case .idle: ""
        case .preparing: "Preparing dictation…"
        case .recording: "Recording"
        case .transcribing: "Transcribing…"
        case .cleaning: "Cleaning up transcript…"
        case .notice(let notice): notice
        case .failed(let error): error
        }
        if case .failed = phase {
            voiceStatus.textColor = WorkspaceStyle.negative
            voiceSettings.isHidden = false
        } else if case .notice = phase { voiceStatus.textColor = WorkspaceStyle.quota }
        else if phase == .recording { voiceStatus.textColor = WorkspaceStyle.accent }
        voiceStatus.toolTip = voiceStatus.stringValue
        voicePreview.stringValue = preview ?? ""
        voicePreview.toolTip = preview
        voicePreview.isHidden = preview?.isEmpty != false
        if changed { updateSend() }
    }

    func insertDictation(_ transcript: String, at anchor: VoiceDraftAnchor, language: String, send: Bool) throws {
        guard canDictate else { throw ClientError.disconnected }
        let text = try anchor.insertion(transcript, draft: editor.string, revision: draftRevision, language: language)
        editor.insertText(text, replacementRange: anchor.range)
        if send { submit() }
    }

    func setSendBlockReason(_ reason: String?) {
        guard sendBlockReason != reason else { return }
        sendBlockReason = reason
        updateSend()
    }

    func focusAtEnd() {
        window?.contentView?.layoutSubtreeIfNeeded()
        focus()
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.setSelectedRange(end)
        editor.scrollRangeToVisible(end)
    }

    private func updatePromptHeight() {
        guard editor.bounds.width > 0, let container = editor.textContainer, let manager = editor.layoutManager else { return }
        manager.ensureLayout(for: container)
        let trailingLine = editor.string.hasSuffix("\n") ? manager.extraLineFragmentRect.height : 0
        let measured = manager.usedRect(for: container).height + trailingLine + 2 * editor.textContainerInset.height
        let height = min(164, max(42, ceil(measured)))
        if promptHeight?.constant != height { promptHeight?.constant = height }
    }

    func closeModelMenu() { modelPicker.close() }

    func renderUsageLimits(activeModel: Wire?, sources: [UsageLimitSource], canRead: Bool) {
        let accounts = canRead ? catalog.usageLimitAccounts(sources: sources) : []
        let available = !accounts.isEmpty
        let preview = available ? catalog.usageLimitPreview(for: activeModel ?? selectedModel, sources: sources) : nil
        usageLimits.render(preview, accounts: accounts, available: available)
    }

    func renderModelSwitch(activeModel: Wire, canSwitch: @autoclosure () -> Bool) {
        guard queueEditState == nil, canSend, draft.model != .null,
              let change = catalog.modelSwitch(from: activeModel, to: selectedModel) else {
            modelSwitchBar.isHidden = true
            return
        }
        let title = "This turn is still using \(change.activeTitle)."
        if activeModelLabel.stringValue != title {
            activeModelLabel.stringValue = title
            activeModelLabel.toolTip = title
        }
        switchModel.toolTip = "Send Continue with \(change.selectedTitle)"
        switchModel.isEnabled = !isSending && canSwitch()
        switchModel.contentTintColor = switchModel.isEnabled ? WorkspaceStyle.accent : WorkspaceStyle.muted
        modelSwitchBar.isHidden = false
    }

    private func submitModelSwitch() {
        guard switchModel.isEnabled, !modelSwitchBar.isHidden, !voicePhase.busy else { return }
        onSwitchModel?(selectedModel)
    }

    func setCommandContext(connection: UUID?, cwd: String?, freshSession: Bool, hasHistory: Bool = false, sideChats: Bool = false) {
        guard commandConnection != connection || commandCwd != cwd ||
                freshAvailable != freshSession || commandHistory != hasHistory || sideChatsAvailable != sideChats else { return }
        commandConnection = connection
        commandCwd = cwd
        freshAvailable = freshSession
        commandHistory = hasHistory
        sideChatsAvailable = sideChats
        updateSend()
    }

    func setBranch(_ name: String?, available: Bool, enabled: Bool) {
        branch.title = name ?? "Branch"
        branch.toolTip = name.map { "Choose branch (\($0))" } ?? "Choose branch"
        branch.setAccessibilityLabel(name.map { "Branch, \($0)" } ?? "Branch")
        branch.isHidden = !available
        branch.isEnabled = enabled
    }

    func addAttachments(_ files: [PickedAttachment]) throws {
        guard queueEditState?.canSave != false else { throw ClientError.message("This queued message cannot be edited.") }
        try draft.addAttachments(files)
        onDraftChange?(draft)
        updateAttachments()
        updateSend()
    }

    func setPreparingAttachments(_ preparing: Bool) {
        guard preparingAttachments != preparing else { return }
        preparingAttachments = preparing
        updateAttachments()
        updateSend()
    }

    private func updateAttachments() {
        let count = draft.attachments.count + draft.retainedAttachments.count
        attachmentMenu.isHidden = count == 0 && !preparingAttachments
        attachmentMenu.isEnabled = count > 0 && canManageAttachments
        attach.isEnabled = canAttachFiles
        let first = BrowserAnnotationContext.attachmentLabel(
            draft.attachments.first?.name ?? draft.retainedAttachments.first?["name"].string ?? "Attachment"
        )
        attachmentMenu.title = preparingAttachments ? "Preparing attachments…" : count == 1 ? first : "\(count) attachments"
        attachmentMenu.setAccessibilityLabel(attachmentMenu.title)
    }

    private func showAttachments() {
        let menu = NSMenu()
        for file in draft.attachments {
            let item = menuItem("Remove \(BrowserAnnotationContext.attachmentLabel(file.name))", target: self, action: #selector(removeAttachment(_:)))
            item.toolTip = file.browserAnnotation?.comment
            item.representedObject = file.id
            menu.addItem(item)
        }
        for attachment in draft.retainedAttachments {
            guard let id = attachment["id"].string else { continue }
            let name = BrowserAnnotationContext.attachmentLabel(attachment["name"].string ?? "attachment")
            let item = menuItem("Remove \(name)", target: self, action: #selector(removeAttachment(_:)))
            item.representedObject = id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: attachmentMenu.bounds.height), in: attachmentMenu)
    }

    @objc private func removeAttachment(_ sender: NSMenuItem) {
        guard canManageAttachments else { return }
        if let id = sender.representedObject as? UUID { draft.attachments.removeAll { $0.id == id } }
        else if let id = sender.representedObject as? String {
            draft.retainedAttachments.removeAll { $0["id"].string == id }
            draft.retainedContextRecords = BrowserAnnotationContext.retaining(draft.retainedContextRecords, attachments: draft.retainedAttachments)
        }
        else { return }
        onDraftChange?(draft)
        updateAttachments()
        updateSend()
    }

    private func updateModelPickers(_ current: Wire) {
        selectedModel = current
        modelOptions = catalog.options(for: current)
    }

    private func setModelOption(_ id: String, value: Wire?) {
        guard queueEditState == nil, canSend, !isSending else { return }
        let next = modelOptions.setting(value, for: id)
        guard next != selectedModel else { return }
        draft.model = next
        updateModelPickers(next)
        onDraftChange?(draft)
        updateSend()
    }

    private func pickModel(_ next: Wire) {
        guard queueEditState == nil, canSend, !isSending, next != .null, next != selectedModel else { return }
        draft.model = next
        updateModelPickers(next)
        onModelChange?()
        onDraftChange?(draft)
        updateSend()
    }

    private func configure(_ button: NSPopUpButton, values: [(String, String)], selection: String?) {
        if button.itemArray.compactMap({ $0.representedObject as? String }) != values.map(\.0) {
            button.removeAllItems()
            for (value, title) in values {
                button.addItem(withTitle: title)
                button.lastItem?.representedObject = value
            }
        }
        if !values.isEmpty { button.selectItem(at: values.firstIndex(where: { $0.0 == selection }) ?? 0) }
    }

    func textDidChange(_ notification: Notification) {
        let text = editor.promptSource
        if queueEditState != nil, !draft.text.isEmpty, text.isEmpty, !editor.hasMarkedText(), cancelQueuedEdit() { return }
        let records = draft.retainedContextRecords.filter { $0["kind"].string != "terminal" } + editor.terminalContextRecords
        if draft.text != text || draft.retainedContextRecords != records { draftRevision += 1 }
        draft.text = text
        draft.retainedContextRecords = records
        updatePromptHeight()
        onDraftChange?(draft)
        updateSend()
    }

    func textViewDidChangeSelection(_ notification: Notification) { refreshSuggestions() }

    func textDidEndEditing(_ notification: Notification) {
        activeTrigger = nil
        suggestions.dismiss()
    }

    private func refreshSuggestions() {
        let provider = catalog.provider(for: selectedModel)
        let scope = commandConnection.flatMap { connection in
            commandCwd.flatMap { cwd in provider.map { ComposerCommandScope(connection: connection, instanceID: $0.id, cwd: cwd) } }
        }
        if commandScope != scope {
            catalogTask?.cancel()
            catalogTask = nil
            commandScope = scope
            scopedCatalog = nil
            catalogFailed = false
            activeTrigger = nil
        }
        guard queueEditState == nil, canSend, !isSending, !voicePhase.busy, selectedModel != .null, editor.window?.firstResponder === editor,
              !editor.hasMarkedText(),
              let trigger = ComposerCommandTrigger.detect(editor.string, caret: editor.selectedRange()) else {
            activeTrigger = nil
            dismissedTrigger = nil
            suggestions.dismiss()
            return
        }
        guard trigger != dismissedTrigger else { return }
        dismissedTrigger = nil
        let opening = activeTrigger?.kind != trigger.kind
        activeTrigger = trigger
        if opening, let scope, let loadCommandCatalog, catalogTask == nil {
            catalogFailed = false
            catalogTask = Task { [weak self] in
                do {
                    let catalog = try await loadCommandCatalog(scope)
                    try Task.checkCancellation()
                    guard let self, commandScope == scope else { return }
                    scopedCatalog = catalog
                } catch {
                    guard !Task.isCancelled, let self, commandScope == scope else { return }
                    catalogFailed = true
                }
                guard let self, commandScope == scope else { return }
                catalogTask = nil
                refreshSuggestions()
            }
        }
        let catalog = scopedCatalog ?? provider?.commandCatalog ?? .init()
        let suffix = (editor.string as NSString).substring(from: NSMaxRange(trigger.range))
        let compact = commandHistory && !draft.hasAttachments && suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let items = catalog.items(for: trigger, freshSession: freshAvailable, compact: compact, sideChats: sideChatsAvailable)
        let empty = trigger.kind == .slash ? "No matching commands" : "No matching skills"
        let status = catalogTask != nil || catalog.pending ? "Loading suggestions…" :
            catalogFailed ? "Couldn’t load suggestions" : empty
        suggestions.present(items, status: status)
    }

    private func handleSuggestionKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard modifiers.isEmpty, let activeTrigger else { return false }
        switch event.keyCode {
        case 125: return suggestions.move(1)
        case 126: return suggestions.move(-1)
        case 48, 36, 76: return suggestions.accept()
        case 53:
            dismissedTrigger = activeTrigger
            self.activeTrigger = nil
            suggestions.dismiss()
            return true
        default: return false
        }
    }

    private func applySuggestion(_ item: ComposerCommandItem) {
        guard let trigger = activeTrigger,
              ComposerCommandTrigger.detect(editor.string, caret: editor.selectedRange()) == trigger else { return }
        dismissedTrigger = trigger
        activeTrigger = nil
        suggestions.dismiss()
        switch item.action {
        case .insert(let text):
            editor.insertText(text, replacementRange: trigger.replacementRange(in: editor.string, inserting: text))
        case .model:
            editor.insertText("", replacementRange: trigger.range)
            openModelMenu()
        case .freshSession:
            guard freshAvailable else { return }
            editor.insertText("", replacementRange: trigger.range)
            setFreshContext(true)
        }
    }

    private func setFreshContext(_ fresh: Bool) {
        draft.freshContext = fresh
        onDraftChange?(draft)
        updateSend()
    }

    private func openModelMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self, modelPicker.canOpen else { return }
            modelPicker.show()
        }
    }

    private func updateSend() {
        placeholder.isHidden = queueEditState != nil || !draft.text.isEmpty
        let editable = canSend && !isSending && !voicePhase.busy && queueEditState != .saving
        if editor.isEditable != editable { editor.isEditable = editable }
        let hasContent = draft.hasAttachments || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let queueEditState {
            send.isEnabled = editable && !preparingAttachments && queueEditState.canSave && hasContent
            if queueEditState == .saving { send.toolTip = "Saving queued message…" }
            else if preparingAttachments { send.toolTip = "Preparing attachments…" }
            else { send.toolTip = "Save queued message (↩)" }
        } else {
            send.isEnabled = canSend && sendBlockReason == nil && !isSending && !preparingAttachments && selectedModel != .null &&
                (!draft.freshContext || freshAvailable) && (voicePhase == .recording || (!voicePhase.busy && hasContent))
            if let sendBlockReason { send.toolTip = sendBlockReason }
            else if preparingAttachments { send.toolTip = "Preparing attachments…" }
            else if voicePhase == .recording { send.toolTip = "Finish dictation and send (↩)" }
            else if voicePhase.busy { send.toolTip = "Waiting for dictation…" }
            else { send.toolTip = isSending ? "Sending…" : isWorking ? "Queue message (↩)" : "Send (↩)" }
        }
        let canChangeSettings = queueEditState == nil && canSend && !isSending
        runtime.isEnabled = canChangeSettings && !isWorking
        interaction.isEnabled = canChangeSettings && !isWorking
        modelPicker.render(catalog: catalog, selection: selectedModel, preferred: lastFallbackModel, options: modelOptions,
                           enabled: canChangeSettings, promptEffort: modelOptions.usesPromptEffort(draft.text))
        freshBanner.isHidden = queueEditState != nil || !draft.freshContext
        freshLabel.stringValue = freshAvailable ? "Next message starts a new session" : "Fresh sessions are unavailable"
        refreshSuggestions()
    }

    private func submit() {
        guard send.isEnabled else { return }
        if queueEditState != nil { onSaveQueuedEdit?(draft); return }
        if voicePhase == .recording { onVoiceSend?(); return }
        let command = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !draft.hasAttachments, command == "/clear", freshAvailable {
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            setFreshContext(true)
            focus()
            return
        }
        if !draft.hasAttachments, command == "/model", modelPicker.canOpen {
            editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            openModelMenu()
            return
        }
        var intent = draft
        intent.model = selectedModel
        intent.runtime = runtime.selectedItem?.representedObject as? String
        intent.interaction = interaction.selectedItem?.representedObject as? String
        onSend?(intent)
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        if sender === checkout {
            if sender.indexOfSelectedItem == 1 { onWorktree?() }
            else if sender.indexOfSelectedItem == 0 { onRootCheckout?() }
            return
        } else if let value = sender.selectedItem?.representedObject as? String {
            if sender === runtime {
                draft.runtime = value
                onModeChange?("runtimeMode", value)
            } else {
                draft.interaction = value
                onModeChange?("interactionMode", value)
            }
        }
        onDraftChange?(draft)
        updateSend()
    }
}
