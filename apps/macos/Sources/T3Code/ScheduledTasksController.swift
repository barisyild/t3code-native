import AppKit

@MainActor
final class ScheduledTasksController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mutation {
        case toggle, run, delete, rotate

        var method: String {
            switch self {
            case .toggle: "scheduledTasks.setEnabled"
            case .run: "scheduledTasks.runNow"
            case .delete: "scheduledTasks.delete"
            case .rotate: "scheduledTasks.rotateWebhookToken"
            }
        }
    }

    private let workspace: Workspace
    private let table = NSTableView()
    private let environment = label(size: 12, color: WorkspaceStyle.muted)
    private let empty = label("Loading scheduled tasks…", size: 13, color: WorkspaceStyle.muted)
    private let notice = label(size: 12, color: WorkspaceStyle.accent)
    private let taskTitle = label(size: 15, weight: .semibold, color: WorkspaceStyle.ink)
    private let destination = label(size: 12, color: WorkspaceStyle.secondary)
    private let runStatus = label(size: 12, color: WorkspaceStyle.muted)
    private let prompt = NSTextView()
    private lazy var add = ActionButton("New Task", symbol: "plus") { [weak self] in self?.createTask() }
    private lazy var back = ActionButton("Back to Workspace", symbol: "chevron.left", iconOnly: true, style: .subtle) { [weak self] in self?.onBack?() }
    private lazy var refresh = ActionButton("Refresh Tasks", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in self?.reload() }
    private lazy var edit = ActionButton("Edit") { [weak self] in self?.editSelected() }
    private lazy var enable = ActionButton("Pause") { [weak self] in self?.mutateSelected(.toggle) }
    private lazy var run = ActionButton("Run Now", symbol: "play", style: .subtle) { [weak self] in self?.mutateSelected(.run) }
    private lazy var thread = ActionButton("Open Thread", style: .subtle) { [weak self] in self?.openThread() }
    private lazy var copy = ActionButton("Copy Path", style: .subtle) { [weak self] in self?.copyWebhook() }
    private lazy var deliveries = ActionButton("Deliveries", style: .subtle) { [weak self] in self?.showDeliveries() }
    private lazy var rotate = ActionButton("Rotate URL…", style: .subtle) { [weak self] in self?.confirm(.rotate) }
    private lazy var delete = ActionButton("Delete Task…", symbol: "trash", iconOnly: true, style: .subtle) { [weak self] in self?.confirm(.delete) }
    private var detail: NSView?
    private var webhookActions: NSView?
    private var tasks: [ScheduledTask] = []
    private var selectedId: String?
    private var requestedSelection: String?
    private var didLoad = false
    private var updatingSelection = false
    private var message: String?
    private var connection: UUID?
    private var generation = UUID()
    private var listener: Task<Void, Never>?
    private var mutations: [String: Task<Void, Never>] = [:]
    private var editor: ScheduledTaskEditor?
    private var deliveryPanel: ScheduledDeliveriesController?

    var onCount: ((Int?) -> Void)?
    var onBack: (() -> Void)?
    var onAddProject: (() -> Void)?
    var onOpenThread: ((String) -> Void)?

    private var selectedTask: ScheduledTask? { tasks.first { $0.id == selectedId } }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.canvas)
        let title = label("Scheduled", size: 20, weight: .semibold, color: WorkspaceStyle.ink)
        let header = row([back, column([title, environment], spacing: 2), NSView(), refresh, add], spacing: 8)
        let definitions: [(String, String, CGFloat, CGFloat)] = [
            ("name", "Task", 236, 100), ("trigger", "Trigger", 175, 88),
            ("next", "Next run", 175, 88), ("status", "Status", 100, 63),
        ]
        for (id, title, width, minimum) in definitions {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 37
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openEditorFromTable)
        table.setAccessibilityLabel("Scheduled Tasks")
        let list = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 9)
        let scroll = scroller(for: table)
        fill(scroll, in: list, inset: 1)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
        empty.alignment = .center
        empty.maximumNumberOfLines = 3
        empty.lineBreakMode = .byWordWrapping
        list.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: list.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: list.trailingAnchor, constant: -16),
        ])

        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = WorkspaceStyle.ink
        prompt.setAccessibilityLabel("Scheduled Task Prompt")
        prompt.textContainerInset = NSSize(width: 5, height: 5)
        let promptBox = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 6)
        fill(textScroller(prompt), in: promptBox, inset: 1)
        promptBox.heightAnchor.constraint(equalToConstant: 69).isActive = true
        runStatus.maximumNumberOfLines = 3
        runStatus.lineBreakMode = .byWordWrapping
        let taskActions = row([edit, enable, run, thread, NSView(), delete], spacing: 7)
        let hookActions = row([copy, deliveries, rotate, NSView()], spacing: 6)
        webhookActions = hookActions
        let detail = column([taskTitle, destination, runStatus, promptBox, taskActions, hookActions], spacing: 7, alignment: .width)
        self.detail = detail
        notice.maximumNumberOfLines = 3
        notice.lineBreakMode = .byWordWrapping
        fill(column([header, list, detail, notice], spacing: 13, alignment: .width), in: view, inset: 17)
        reloadRows()
        render()
    }

    func sync() {
        let connected = workspace.can("orchestration:read") ? workspace.connectionID : nil
        guard connected != connection else { render(); return }
        listener?.cancel()
        for operation in mutations.values { operation.cancel() }
        mutations.removeAll()
        generation = UUID()
        connection = connected
        tasks = []
        selectedId = nil
        requestedSelection = nil
        didLoad = false
        message = nil
        onCount?(nil)
        if isViewLoaded { reloadRows() }
        if connected != nil { observe() }
        render()
    }

    func shutdown() {
        listener?.cancel()
        for operation in mutations.values { operation.cancel() }
    }

    private func observe() {
        listener?.cancel()
        let generation = self.generation
        listener = Task {
            do {
                try await workspace.subscribe("scheduledTasks.subscribe", [:]) { updates in
                    guard self.generation == generation, let list = updates.last else { return }
                    tasks = list["tasks"].array.compactMap(ScheduledTask.init)
                    didLoad = true
                    onCount?(tasks.lazy.filter { $0.enabled && $0.policyBlock == nil }.count)
                    if isViewLoaded { reloadRows() }
                    render()
                }
                throw ClientError.disconnected
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                message = error.localizedDescription
                render()
            }
        }
    }

    private func reload() {
        guard connection != nil else { return }
        message = nil
        observe()
        render()
    }

    private func reloadRows() {
        updatingSelection = true
        table.reloadData()
        if let wanted = requestedSelection, tasks.contains(where: { $0.id == wanted }) {
            selectedId = wanted
            requestedSelection = nil
        }
        if let index = tasks.firstIndex(where: { $0.id == selectedId }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let first = tasks.first {
            selectedId = first.id
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else { selectedId = nil }
        updatingSelection = false
    }

    func createTask(fromThread: ThreadSummary? = nil) {
        guard workspace.can("orchestration:operate") else { return }
        guard workspace.data.projects.values.contains(where: { !$0.archived }) else {
            onAddProject?()
            return
        }
        showEditor(task: nil, fromThread: fromThread)
    }

    private func editSelected() {
        guard let task = selectedTask, mutations[task.id] == nil else { return }
        showEditor(task: task)
    }

    private func showEditor(task: ScheduledTask?, fromThread: ThreadSummary? = nil) {
        guard workspace.can("orchestration:operate"), let window = view.window, editor == nil,
              connection != nil, window.attachedSheet == nil else { return }
        let generation = self.generation
        let editor = ScheduledTaskEditor(workspace: workspace, task: task, fromThread: fromThread)
        self.editor = editor
        editor.onSave = { [weak self] input in
            guard let self, self.generation == generation, workspace.can("orchestration:operate") else {
                throw ClientError.message("The environment changed. Reopen the task editor to continue.")
            }
            let result = try await workspace.request("scheduledTasks.upsert", input)
            guard self.generation == generation else { return }
            requestedSelection = result["task"]["id"].string
            message = nil
            reloadRows()
            render()
        }
        editor.onClose = { [weak self] in
            self?.editor = nil
            self?.render()
        }
        editor.present(in: window)
    }

    private func mutateSelected(_ mutation: Mutation) {
        guard let task = selectedTask else { return }
        mutate(task, mutation)
    }

    private func mutate(_ task: ScheduledTask, _ mutation: Mutation) {
        guard workspace.can("orchestration:operate"), connection != nil, mutations[task.id] == nil else { return }
        let generation = self.generation
        message = nil
        mutations[task.id] = Task {
            defer {
                if self.generation == generation { mutations[task.id] = nil; render() }
            }
            var input: Payload = ["id": .string(task.id)]
            if mutation == .toggle { input["enabled"] = .bool(!task.enabled) }
            do {
                _ = try await workspace.request(mutation.method, input)
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
        render()
    }

    private func confirm(_ mutation: Mutation) {
        guard let task = selectedTask, let window = view.window, workspace.can("orchestration:operate"), window.attachedSheet == nil else { return }
        let generation = self.generation
        let alert = NSAlert()
        let deletion = mutation == .delete
        alert.messageText = deletion ? "Delete \(task.title)?" : "Rotate this webhook URL?"
        alert.informativeText = deletion ?
            (task.isWebhook ? "Requests to this webhook will stop working." : "This task will stop scheduling new runs.") :
            "Requests to the current URL will stop working."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: deletion ? "Delete Task" : "Rotate URL")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn, self.generation == generation else { return }
            mutate(task, mutation)
        }
    }

    private func openThread() {
        if let id = selectedTask?.threadId, workspace.data.threads[id] != nil { onOpenThread?(id) }
    }

    private func copyWebhook() {
        guard workspace.can("orchestration:operate"), let webhook = selectedTask?.webhook,
              let value = webhook["url"].string ?? webhook["path"].string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        message = webhook["url"].string == nil ? "Webhook path copied." : "Webhook URL copied."
        render()
    }

    private func showDeliveries() {
        guard let task = selectedTask, let parent = view.window, workspace.can("orchestration:operate"),
              deliveryPanel == nil, parent.attachedSheet == nil else { return }
        let generation = self.generation
        let panel = ScheduledDeliveriesController(title: task.title)
        deliveryPanel = panel
        panel.load = { [weak self] deliveryId in
            guard let self, self.generation == generation, workspace.can("orchestration:operate") else { throw ClientError.disconnected }
            var input: Payload = ["id": .string(task.id), "acceptAnyOutcome": .bool(true)]
            if let deliveryId { input["deliveryId"] = .string(deliveryId) }
            return try await workspace.request(deliveryId == nil ? "scheduledTasks.listWebhookDeliveries" : "scheduledTasks.getWebhookDelivery", input)
        }
        panel.onClose = { [weak self] in
            self?.deliveryPanel = nil
            self?.render()
        }
        panel.present(in: parent)
    }

    private func render() {
        guard isViewLoaded else { return }
        environment.stringValue = workspace.environment?.name ?? "No environment connected"
        empty.isHidden = !tasks.isEmpty
        empty.stringValue = connection == nil ? "Connect an environment to view its scheduled tasks." :
            message != nil && !didLoad ? "The task list could not load. Refresh to try again." :
            didLoad ? "No scheduled tasks in this environment." : "Loading scheduled tasks…"
        notice.stringValue = message ?? ""
        notice.isHidden = message == nil
        refresh.isEnabled = connection != nil
        let canOperate = workspace.can("orchestration:operate")
        add.isEnabled = canOperate && editor == nil
        guard let task = selectedTask else { detail?.isHidden = true; return }
        detail?.isHidden = false
        taskTitle.stringValue = task.title
        let project = workspace.data.projects[task.projectId]?.name ?? "Project unavailable"
        let slug = task.model["model"].string
        let model = workspace.providers.first { $0.id == task.model["instanceId"].string }?
            .models.first { $0.slug == slug }?.name ?? slug ?? "Agent"
        destination.stringValue = [project, task.threadMode.name, model].joined(separator: "  ·  ")
        let last = WorkspaceStyle.date(task.lastRun).map { $0.formatted(date: .abbreviated, time: .shortened) }
        let runSummary = task.runCount == 1 ? "1 run" : "\(task.runCount) runs"
        let summary = last.map { "\(runSummary), last run \($0) · \(task.status.capitalized)" } ??
            "\(runSummary), \(task.enabled ? "enabled" : "paused")"
        runStatus.stringValue = task.lastError ?? task.policyBlock ?? summary
        runStatus.textColor = task.lastError == nil ? WorkspaceStyle.muted : WorkspaceStyle.negative
        if prompt.string != task.prompt { prompt.string = task.prompt }
        let available = canOperate && mutations[task.id] == nil && editor == nil
        edit.isEnabled = available
        enable.title = task.enabled ? "Pause" : "Resume"
        enable.setAccessibilityLabel(task.enabled ? "Pause Task" : "Resume Task")
        enable.isEnabled = available && (task.enabled || task.policyBlock == nil)
        run.isHidden = task.isWebhook
        run.isEnabled = available && task.status != "running" && task.policyBlock == nil
        thread.isHidden = task.threadId.flatMap { workspace.data.threads[$0] } == nil
        delete.isEnabled = available
        webhookActions?.isHidden = !task.isWebhook || !canOperate
        copy.title = task.webhook["url"].string == nil ? "Copy Path" : "Copy URL"
        copy.setAccessibilityLabel(copy.title)
        copy.isEnabled = task.webhook["path"].string != nil
        rotate.isEnabled = available
        deliveries.isEnabled = deliveryPanel == nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let row = table.selectedRow
        selectedId = tasks.indices.contains(row) ? tasks[row].id : nil
        message = nil
        render()
    }

    @objc private func openEditorFromTable() { editSelected() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let task = tasks[index]
        let content: String
        let color: NSColor
        switch tableColumn?.identifier.rawValue {
        case "trigger": content = task.scheduleName; color = WorkspaceStyle.secondary
        case "next":
            content = WorkspaceStyle.date(task.nextRun).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
            color = WorkspaceStyle.muted
        case "status":
            if task.policyBlock != nil { content = "Blocked"; color = WorkspaceStyle.accent }
            else if task.status == "running" { content = "Running"; color = WorkspaceStyle.accent }
            else if !task.enabled { content = "Paused"; color = WorkspaceStyle.muted }
            else if task.status == "failed" { content = "Failed"; color = WorkspaceStyle.negative }
            else if task.status == "succeeded" { content = "Succeeded"; color = WorkspaceStyle.positive }
            else { content = task.isWebhook ? "Listening" : "Scheduled"; color = WorkspaceStyle.secondary }
        default: content = task.title; color = WorkspaceStyle.ink
        }
        let cell = NSTableCellView()
        let value = label(content, size: 12, color: color)
        value.toolTip = content
        fill(value, in: cell, inset: 5)
        cell.textField = value
        return cell
    }
}
