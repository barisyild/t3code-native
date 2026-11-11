import AppKit

@MainActor
private func formField(_ name: String, _ input: NSView) -> NSStackView {
    let caption = label(name, size: 12, color: WorkspaceStyle.secondary)
    caption.widthAnchor.constraint(equalToConstant: 126).isActive = true
    input.setAccessibilityLabel(name)
    return row([caption, input], spacing: 10)
}

@MainActor
private func formPicker(_ picker: NSPopUpButton, _ values: [(String, String)], selected: String) {
    picker.removeAllItems()
    for (id, title) in values {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = id
        picker.menu?.addItem(item)
    }
    if let index = values.firstIndex(where: { $0.0 == selected }) { picker.selectItem(at: index) }
}

@MainActor
private func selection(_ picker: NSPopUpButton) -> String? { picker.selectedItem?.representedObject as? String }

@MainActor
private final class FormDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class WebhookFilterRow: NSView {
    private let path = NSTextField()
    private let operation = NSPopUpButton()
    private let value = NSTextField()

    init(_ filter: ScheduledWebhookFilter, remove: @escaping (WebhookFilterRow) -> Void) {
        super.init(frame: .zero)
        path.placeholderString = "body.action"
        path.stringValue = filter.path
        path.setAccessibilityLabel("Webhook Filter Path")
        formPicker(operation, ScheduledWebhookFilter.Operation.allCases.map { ($0.rawValue, $0.name) }, selected: filter.operation.rawValue)
        operation.setAccessibilityLabel("Webhook Filter Operation")
        operation.target = self
        operation.action = #selector(updateOperation)
        value.stringValue = filter.value
        value.setAccessibilityLabel("Webhook Filter Value")
        let delete = ActionButton("Remove Filter", symbol: "minus.circle", iconOnly: true, style: .subtle) { [weak self] in
            if let self { remove(self) }
        }
        path.widthAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
        value.widthAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
        fill(row([path, operation, value, delete], spacing: 6), in: self)
        updateOperation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var draft: ScheduledWebhookFilter {
        var result = ScheduledWebhookFilter()
        result.path = path.stringValue
        result.operation = selection(operation).flatMap(ScheduledWebhookFilter.Operation.init(rawValue:)) ?? .equals
        result.value = value.stringValue
        return result
    }

    @objc private func updateOperation() {
        value.isEnabled = draft.operation != .exists
        value.placeholderString = draft.operation == .in ? "Comma-separated values" : "Value"
    }
}

@MainActor
private final class ScheduledWebhookFields: NSView {
    private let signed = NSButton(checkboxWithTitle: "Verify HMAC-SHA256 signatures", target: nil, action: nil)
    private let header = NSTextField()
    private let encoding = NSPopUpButton()
    private let prefix = NSTextField()
    private let secret = NSSecureTextField()
    private let age = NSTextField()
    private let replay = NSTextField()
    private let coalesce = NSTextField()
    private let seconds = NSTextField()
    private var filterRows: [WebhookFilterRow] = []
    private let filterList = NSStackView()
    private var signatureFields: NSView?
    private lazy var addFilter = ActionButton("Add Filter", symbol: "plus", style: .subtle) { [weak self] in
        self?.appendFilter(ScheduledWebhookFilter())
    }

    init(_ draft: ScheduledTriggerDraft, hasStoredSecret: Bool) {
        super.init(frame: .zero)
        signed.state = draft.signed ? .on : .off
        signed.target = self
        signed.action = #selector(updateSignature)
        header.stringValue = draft.signatureHeader
        prefix.stringValue = draft.signaturePrefix
        secret.placeholderString = hasStoredSecret ? "Leave blank to keep stored secret" : "Signing secret"
        formPicker(encoding, [("hex", "Hex"), ("base64", "Base64")], selected: draft.signatureEncoding)
        let signing = column([
            formField("Signature header", header), formField("Encoding", encoding),
            formField("Signature prefix", prefix), formField("Signing secret", secret),
        ], spacing: 8, alignment: .width)
        signatureFields = signing
        age.stringValue = draft.maxAge
        age.placeholderString = "Minutes, optional"
        replay.stringValue = draft.replayKey
        replay.placeholderString = "{{body.id}}"
        coalesce.stringValue = draft.coalesceKey
        coalesce.placeholderString = "{{headers.x-event}}"
        seconds.stringValue = draft.coalesceSeconds
        seconds.placeholderString = "Seconds, optional"
        filterList.orientation = .vertical
        filterList.alignment = .leading
        filterList.spacing = 6
        let filters = row([label("Webhook filters", size: 12, weight: .medium, color: WorkspaceStyle.secondary), NSView(), addFilter])
        let hint = label("Use {{body}}, {{headers.name}}, or {{query.name}} in the prompt.", size: 11, color: WorkspaceStyle.muted)
        hint.maximumNumberOfLines = 3
        hint.lineBreakMode = .byWordWrapping
        fill(column([hint, signed, signing, formField("Maximum age", age),
                     formField("Duplicate key", replay), formField("Coalesce key", coalesce),
                     formField("Coalesce window", seconds), filters, filterList], spacing: 8, alignment: .width), in: self)
        draft.filters.forEach(appendFilter)
        updateSignature()
        addFilter.isEnabled = filterRows.count < 16
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func read(into draft: inout ScheduledTriggerDraft) {
        draft.signed = signed.state == .on
        draft.signatureHeader = header.stringValue
        draft.signatureEncoding = selection(encoding) ?? "hex"
        draft.signaturePrefix = prefix.stringValue
        draft.signatureSecret = secret.stringValue
        draft.maxAge = age.stringValue
        draft.replayKey = replay.stringValue
        draft.coalesceKey = coalesce.stringValue
        draft.coalesceSeconds = seconds.stringValue
        draft.filters = filterRows.map(\.draft)
    }

    private func appendFilter(_ filter: ScheduledWebhookFilter) {
        guard filterRows.count < 16 else { return }
        let item = WebhookFilterRow(filter) { [weak self] item in
            guard let self else { return }
            filterRows.removeAll { $0 === item }
            filterList.removeArrangedSubview(item)
            item.removeFromSuperview()
            addFilter.isEnabled = true
        }
        filterRows.append(item)
        filterList.addArrangedSubview(item)
        item.widthAnchor.constraint(equalTo: filterList.widthAnchor).isActive = true
        addFilter.isEnabled = filterRows.count < 16
    }

    @objc private func updateSignature() { signatureFields?.isHidden = signed.state != .on }
}

@MainActor
final class ScheduledTaskEditor: NSWindowController {
    private let workspace: Workspace
    private let initial: ScheduledTaskDraft
    private let taskId = "scheduled-task:\(UUID().uuidString.lowercased())"
    private let titleField = NSTextField()
    private let prompt = NSTextView()
    private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let trigger = NSPopUpButton()
    private let fixedTime = NSTextField()
    private let weekdays: [(Int, NSButton)] = [(1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"), (0, "Sun")]
        .map { ($0.0, NSButton(checkboxWithTitle: $0.1, target: nil, action: nil)) }
    private let interval = NSTextField()
    private let runAt = NSDatePicker()
    private let project = NSPopUpButton()
    private let threadMode = NSPopUpButton()
    private let thread = NSPopUpButton()
    private let checkout = NSPopUpButton()
    private let branch = NSTextField()
    private let base = NSTextField()
    private let fromOrigin = NSButton(checkboxWithTitle: "Start from origin", target: nil, action: nil)
    private let checkoutPath = NSTextField()
    private let model = NSPopUpButton()
    private let runtime = NSPopUpButton()
    private let interaction = NSPopUpButton()
    private let error = label(size: 12, color: WorkspaceStyle.negative)
    private var models: [Wire] = []
    private var triggerSections: [ScheduledTrigger: NSView] = [:]
    private var threadField: NSView?
    private var baseField: NSView?
    private var pathField: NSView?
    private var dateChanged = false
    private var baseline: ScheduledTaskDraft?
    private var saving: Task<Void, Never>?
    private lazy var webhook = ScheduledWebhookFields(initial.trigger, hasStoredSecret: initial.original?.webhook["hasSecret"].bool == true)
    private lazy var save = ActionButton("Save Task") { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.dismiss() }

    var onSave: ((Payload) async throws -> Void)?
    var onClose: (() -> Void)?

    init(workspace: Workspace, task: ScheduledTask?, fromThread: ThreadSummary? = nil) {
        self.workspace = workspace
        let selected = workspace.selectedProject.flatMap { $0.archived ? nil : $0 }
        let project = fromThread.flatMap { workspace.data.projects[$0.projectId] } ?? selected ??
            workspace.data.projects.values.filter { !$0.archived }.min(by: Project.precedes)
        var draft = ScheduledTaskDraft(task: task, project: project?.id ?? "", model: fromThread?.model ?? workspace.defaultModel(for: project))
        if let fromThread, task == nil {
            draft.threadMode = .continueThread
            draft.thread = fromThread.id
            draft.runtime = fromThread.runtimeMode ?? draft.runtime
            draft.interaction = fromThread.interactionMode ?? draft.interaction
            if let path = fromThread.worktreePath { draft.checkout = .existing; draft.checkoutPath = path }
            draft.branch = fromThread.branch ?? ""
        }
        initial = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 638, height: 612), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = task == nil ? "New Scheduled Task" : "Edit Scheduled Task"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 578, height: 430)
        super.init(window: window)
        buildForm(in: window)
        baseline = readDraft()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(titleField)
    }

    private func buildForm(in window: NSWindow) {
        let root = Surface(WorkspaceStyle.navigation)
        window.contentView = root
        titleField.stringValue = initial.title
        prompt.string = initial.prompt
        prompt.font = .systemFont(ofSize: 13)
        prompt.textColor = WorkspaceStyle.ink
        prompt.insertionPointColor = WorkspaceStyle.ink
        prompt.allowsUndo = true
        prompt.setAccessibilityLabel("Task Prompt")
        prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        let editor = textScroller(prompt, editable: true)
        let promptBox = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 6)
        fill(editor, in: promptBox, inset: 4)
        promptBox.heightAnchor.constraint(equalToConstant: 99).isActive = true
        enabled.state = initial.enabled ? .on : .off
        fixedTime.stringValue = initial.trigger.time
        weekdays.forEach { $0.1.state = initial.trigger.weekdays.contains($0.0) ? .on : .off }
        interval.stringValue = initial.trigger.minutes
        runAt.datePickerStyle = .textFieldAndStepper
        runAt.datePickerElements = [.yearMonthDay, .hourMinute]
        runAt.dateValue = initial.trigger.date
        runAt.target = self
        runAt.action = #selector(changeDate)
        formPicker(trigger, ScheduledTrigger.allCases.map { ($0.rawValue, $0.name) }, selected: initial.trigger.kind.rawValue)
        trigger.target = self
        trigger.action = #selector(updateVisibility)

        let fixed = column([formField("Time on host", fixedTime), formField("Days", row(weekdays.map(\.1), spacing: 7))], spacing: 8, alignment: .width)
        let intervalField = formField("Minutes", interval)
        let dateField = formField("Date and local time", runAt)
        triggerSections = [.fixed: fixed, .interval: intervalField, .once: dateField, .webhook: webhook]

        let projects = workspace.data.orderedProjects.filter { !$0.archived || $0.id == initial.project }
        formPicker(project, projects.map { ($0.id, workspace.isScratch($0) ? "No project" : $0.name) }, selected: initial.project)
        project.target = self
        project.action = #selector(changeProject)
        formPicker(threadMode, ScheduledThreadMode.allCases.map { ($0.rawValue, $0.name) }, selected: initial.threadMode.rawValue)
        threadMode.target = self
        threadMode.action = #selector(updateVisibility)
        thread.target = self
        thread.action = #selector(changeThread)
        loadThreads(selecting: initial.thread)
        formPicker(checkout, ScheduledCheckout.allCases.map { ($0.rawValue, $0.name) }, selected: initial.checkout.rawValue)
        checkout.target = self
        checkout.action = #selector(updateVisibility)
        branch.stringValue = initial.branch
        branch.placeholderString = "Optional"
        base.stringValue = initial.baseRef
        checkoutPath.stringValue = initial.checkoutPath
        checkoutPath.placeholderString = "Path on the host"
        fromOrigin.state = initial.startFromOrigin ? .on : .off
        let threadField = formField("Thread", thread)
        let baseField = column([formField("Base branch", base), fromOrigin], spacing: 6, alignment: .width)
        let pathField = formField("Checkout path", checkoutPath)
        self.threadField = threadField
        self.baseField = baseField
        self.pathField = pathField
        model.target = self
        model.action = #selector(changeModel)
        loadModels(selecting: initial.model)
        loadAgentModes(runtimeValue: initial.runtime, interactionValue: initial.interaction)

        let form = column([
            heading("Task"), formField("Name", titleField), formField("Prompt", promptBox), enabled,
            heading("Trigger"), formField("Schedule", trigger), fixed, intervalField, dateField, webhook,
            heading("Destination"), formField("Project", project), formField("Runs go to", threadMode), threadField,
            formField("Workspace", checkout), formField("Branch", branch), baseField, pathField,
            heading("Agent"), formField("Model", model), formField("Permissions", runtime), formField("Mode", interaction),
        ], spacing: 9, alignment: .width)
        let document = FormDocument()
        fill(form, in: document, inset: 16)
        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        error.maximumNumberOfLines = 3
        error.lineBreakMode = .byWordWrapping
        error.isHidden = true
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        let footer = row([error, NSView(), cancel, save], spacing: 8)
        let layout = column([scroll, footer], spacing: 10, alignment: .width)
        fill(layout, in: root, inset: 12)
        updateVisibility()
    }

    private func heading(_ text: String) -> NSTextField {
        label(text, size: 14, weight: .semibold, color: WorkspaceStyle.ink)
    }

    private var currentProject: Project? { selection(project).flatMap { workspace.data.projects[$0] } }

    private func loadThreads(selecting current: String?) {
        let projectId = selection(project)
        let bound = initial.original?.threadId
        let allowUnbound = bound == nil || projectId != initial.original?.projectId
        var values: [(String, String)] = allowUnbound ? [("", "Create on first run")] : []
        let threads = workspace.data.threads.values.filter { $0.projectId == projectId && !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
        values += threads.map { ($0.id, $0.title) }
        if let bound, projectId == initial.original?.projectId, !values.contains(where: { $0.0 == bound }) {
            values.append((bound, workspace.data.archived[bound]?.title ?? "Current bound thread"))
        }
        formPicker(thread, values, selected: current ?? (allowUnbound ? "" : bound ?? ""))
    }

    private func loadModels(selecting preferred: Wire) {
        let available = workspace.providers.filter(\.isAvailable).flatMap { provider in
            provider.models.map { (provider.selection($0), "\(provider.name) · \($0.name)", $0.isDefault) }
        }
        var options = available
        if preferred != .null && !available.contains(where: { sameModel($0.0, preferred) }) {
            options.insert((preferred, preferred["model"].string ?? "Current model", false), at: 0)
        }
        models = options.map { $0.0 }
        model.removeAllItems()
        for (_, title, _) in options { model.addItem(withTitle: title) }
        if let index = options.firstIndex(where: { sameModel($0.0, preferred) }) ?? options.firstIndex(where: { $0.2 }) {
            model.selectItem(at: index)
        }
    }

    private var selectedModel: Wire {
        let index = model.indexOfSelectedItem
        guard models.indices.contains(index) else { return .null }
        let result = models[index]
        if sameModel(initial.model, result) { return initial.model }
        if let thread = selection(thread).flatMap({ workspace.data.threads[$0] }), sameModel(thread.model, result) { return thread.model }
        let projectModel = workspace.defaultModel(for: currentProject)
        if sameModel(projectModel, result) { return projectModel }
        return result
    }

    private func sameModel(_ first: Wire, _ second: Wire) -> Bool {
        first["instanceId"].string == second["instanceId"].string && first["model"].string == second["model"].string
    }

    private func loadAgentModes(runtimeValue: String, interactionValue: String) {
        let values = [("approval-required", "Ask for approval"), ("auto-accept-edits", "Auto-accept edits"),
                      ("auto", "Auto"), ("full-access", "Full access")]
        let provider = workspace.providers.first { $0.id == selectedModel["instanceId"].string }
        let supported = provider?.modes ?? values.map(\.0)
        formPicker(runtime, values.filter { supported.contains($0.0) || $0.0 == initial.original?.runtime }, selected: runtimeValue)
        let modes = [("default", "Agent"), ("plan", "Plan")]
        formPicker(interaction, provider?.supportsPlan == true || initial.original?.interaction == "plan" ? modes : [modes[0]], selected: interactionValue)
    }

    @objc private func changeProject() {
        loadThreads(selecting: nil)
        loadModels(selecting: workspace.defaultModel(for: currentProject))
        loadAgentModes(runtimeValue: "approval-required", interactionValue: "default")
    }

    @objc private func changeThread() {
        guard let thread = selection(thread).flatMap({ workspace.data.threads[$0] }) else { return }
        loadModels(selecting: thread.model)
        loadAgentModes(runtimeValue: thread.runtimeMode ?? "approval-required", interactionValue: thread.interactionMode ?? "default")
    }

    @objc private func changeModel() {
        loadAgentModes(runtimeValue: selection(runtime) ?? "approval-required", interactionValue: selection(interaction) ?? "default")
    }

    @objc private func changeDate() { dateChanged = true }

    @objc private func updateVisibility() {
        for (kind, view) in triggerSections { view.isHidden = kind.rawValue != selection(trigger) }
        threadField?.isHidden = selection(threadMode) == ScheduledThreadMode.newThread.rawValue
        baseField?.isHidden = selection(checkout) != ScheduledCheckout.worktree.rawValue
        pathField?.isHidden = selection(checkout) != ScheduledCheckout.existing.rawValue
    }

    private func readDraft() -> ScheduledTaskDraft {
        var draft = initial
        draft.title = titleField.stringValue
        draft.prompt = prompt.string
        draft.enabled = enabled.state == .on
        draft.trigger.kind = ScheduledTrigger(selection(trigger)) ?? .fixed
        draft.trigger.time = fixedTime.stringValue
        draft.trigger.weekdays = Set(weekdays.compactMap { $0.1.state == .on ? $0.0 : nil })
        draft.trigger.minutes = interval.stringValue
        draft.trigger.date = runAt.dateValue
        draft.trigger.dateChanged = dateChanged
        webhook.read(into: &draft.trigger)
        draft.project = selection(project) ?? ""
        draft.thread = selection(thread).flatMap { $0.isEmpty ? nil : $0 }
        draft.threadMode = selection(threadMode).flatMap(ScheduledThreadMode.init(rawValue:)) ?? .newThread
        draft.checkout = selection(checkout).flatMap(ScheduledCheckout.init(rawValue:)) ?? .root
        draft.branch = branch.stringValue
        draft.baseRef = base.stringValue
        draft.startFromOrigin = fromOrigin.state == .on
        draft.checkoutPath = checkoutPath.stringValue
        draft.model = selectedModel
        draft.runtime = selection(runtime) ?? initial.runtime
        draft.interaction = selection(interaction) ?? initial.interaction
        return draft
    }

    private func submit() {
        guard saving == nil, let onSave else { return }
        let payload: Payload
        do { payload = try readDraft().encode(id: taskId) }
        catch { showError(error); return }
        error.isHidden = true
        save.isEnabled = false
        cancel.isEnabled = false
        saving = Task {
            do {
                try await onSave(payload)
                finish()
            } catch {
                saving = nil
                save.isEnabled = true
                cancel.isEnabled = true
                showError(error)
            }
        }
    }

    private func showError(_ failure: any Error) {
        error.stringValue = failure.localizedDescription
        error.isHidden = false
    }

    private func dismiss() {
        guard saving == nil, let window else { return }
        guard readDraft() != baseline else { finish(); return }
        let alert = NSAlert()
        alert.messageText = "Discard changes to this task?"
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.finish() }
        }
    }

    private func finish() {
        if let window { window.sheetParent?.endSheet(window) }
        onClose?()
    }
}
