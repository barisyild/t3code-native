import AppKit

@MainActor
final class ThreadRelationshipPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item: Equatable {
        case heading(String)
        case previousAgents
        case relation(ThreadRelationshipRow)
    }

    private let workspace: Workspace
    private let table = NSTableView()
    private let threadName = label(size: 12, color: WorkspaceStyle.muted)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var refresh = ActionButton("Refresh Related Conversations", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) {
        [weak self] in self?.reload()
    }
    private lazy var close = ActionButton("Close Related Conversations", symbol: "xmark", iconOnly: true, style: .subtle) {
        [weak self] in self?.onClose?()
    }
    private lazy var detach = ActionButton("Disconnect Agent Session", symbol: "powerplug", style: .subtle) { [weak self] in
        guard let self, let scope else { return }
        run { try await self.workspace.detachRelatedSessions(scope) }
    }
    private lazy var nativeChildren = ActionButton("Subagent Work…", symbol: "list.bullet.indent", style: .subtle) { [weak self] in
        self?.openSheet(.nativeChildren)
    }
    private lazy var footer = row([nativeChildren, detach, NSView()])
    private var presented = false
    private var scope: ThreadRelationshipScope?
    private var family: RelatedThreadFamily?
    private var requestedTitles = Set<String>()
    private var missingTitles: [String: String] = [:]
    private var unavailable = Set<String>()
    private var familyTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var actionID: UUID?
    private var failure: String?
    private var rows: [ThreadRelationshipRow] = []
    private var items: [Item] = []
    private var showsPreviousAgents = false
    private var lastProjection: ThreadRelationshipProjection?
    private var lastMergeReason: String?
    private var lastCanOperate = false
    private var sheet: RelatedWorkSheet?
    var onOpen: ((RelatedThreadTarget) -> Void)?
    var onClose: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let relationshipColumn = NSTableColumn(identifier: .init("relationship"))
        relationshipColumn.resizingMask = .autoresizingMask
        table.addTableColumn(relationshipColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.style = .plain
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Related Conversations")
        let scroll = scroller(for: table)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 4
        let title = label("Related Conversations", size: 14, weight: .semibold, color: WorkspaceStyle.ink)
        let heading = row([title, NSView(), refresh, close], spacing: 7)
        let line = Surface(WorkspaceStyle.line)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        fill(column([heading, threadName, line, notice, scroll, footer], spacing: 10, alignment: .width), in: view, inset: 13)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scroll = table.enclosingScrollView, let column = table.tableColumns.first else { return }
        let width = scroll.contentView.bounds.width
        if width > 0, abs(column.width - width) > 1 { column.width = width }
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        if presented { sync(.all) }
        else { reset(to: nil) }
    }

    func sync(_ change: Workspace.Change) {
        guard presented else { return }
        let _ = view
        let next = workspace.threadRelationshipScope
        if scope != next { reset(to: next) }
        if !change.intersection([.selection, .sidebar, .providers, .connection]).isEmpty || lastProjection != workspace.detail.relationships {
            updateRows()
        }
        updateControls()
    }

    private func reset(to scope: ThreadRelationshipScope?) {
        familyTask?.cancel()
        titleTask?.cancel()
        familyTask = nil
        titleTask = nil
        self.scope = scope
        family = nil
        requestedTitles.removeAll()
        missingTitles.removeAll()
        unavailable.removeAll()
        lastProjection = nil
        actionID = nil
        failure = nil
        showsPreviousAgents = false
        if let scope, workspace.supportsThreadFamilies { fetchFamily(scope) }
    }

    private func reload() {
        guard let scope else { return }
        failure = nil
        requestedTitles.removeAll()
        unavailable.removeAll()
        titleTask?.cancel()
        titleTask = nil
        if workspace.supportsThreadFamilies { fetchFamily(scope) }
        sync(.sidebar)
    }

    private func fetchFamily(_ scope: ThreadRelationshipScope) {
        guard familyTask == nil else { return }
        familyTask = Task { [weak self, workspace] in
            do {
                let value = try await workspace.relatedThreadFamily(scope)
                guard let self, !Task.isCancelled, self.scope == scope else { return }
                family = value
                familyTask = nil
                sync(.sidebar)
            } catch {
                guard let self, !Task.isCancelled, self.scope == scope else { return }
                familyTask = nil
                failure = error.localizedDescription
                updateControls()
            }
        }
    }

    private func updateRows() {
        lastProjection = workspace.detail.relationships
        guard let thread = workspace.selectedThread else {
            threadName.stringValue = ""
            rows = []
            rebuildItems()
            return
        }
        threadName.stringValue = thread.title
        threadName.toolTip = thread.title
        var threads = workspace.relationshipThreads
        if let family, family.sequence >= (workspace.data.sequence ?? 0) {
            threads.merge(family.threads) { shell, _ in shell }
        }
        rows = ThreadRelationships.rows(for: thread, threads: threads, projection: workspace.detail.relationships,
                                        missingTitles: missingTitles, unavailable: unavailable)
        rebuildItems()
        let missing = Set(rows.compactMap { row -> String? in
            guard let target = row.target, target.environmentID == nil, threads[target.threadID] == nil else { return nil }
            return target.threadID
        }).subtracting(requestedTitles)
        if !missing.isEmpty, titleTask == nil, let scope { lookup(missing, scope: scope) }
    }

    private func lookup(_ ids: Set<String>, scope: ThreadRelationshipScope) {
        requestedTitles.formUnion(ids)
        titleTask = Task { [weak self, workspace] in
            do {
                let value = try await workspace.relatedThreadTitles(ids, scope: scope)
                guard let self, !Task.isCancelled, self.scope == scope else { return }
                missingTitles.merge(value) { _, new in new }
                unavailable.formUnion(ids.subtracting(value.keys))
                titleTask = nil
                sync(.sidebar)
            } catch {
                guard let self, !Task.isCancelled, self.scope == scope else { return }
                titleTask = nil
                failure = error.localizedDescription
                updateControls()
            }
        }
    }

    private func rebuildItems() {
        var next: [Item] = []
        var section: ThreadRelationshipRow.Kind?
        for row in rows {
            if section != row.kind {
                section = row.kind
                switch row.kind {
                case .activeAgent: next.append(.heading("Active Subagents"))
                case .previousAgent: next.append(.previousAgents)
                case .sideChat: next.append(.heading("Side Chats"))
                default: break
                }
            }
            if row.kind != .previousAgent || showsPreviousAgents { next.append(.relation(row)) }
        }
        if next != items {
            items = next
            table.reloadData()
        }
    }

    private func updateControls() {
        let canOperate = scope != nil && workspace.can("orchestration:operate") && actionID == nil
        let reason = workspace.selectedThread?.mergeBackTargetID.map(workspace.forkMergeBackBlockedReason) ?? nil
        if canOperate != lastCanOperate || reason != lastMergeReason {
            lastCanOperate = canOperate
            lastMergeReason = reason
            table.reloadData()
        }
        refresh.isEnabled = scope != nil && familyTask == nil && titleTask == nil
        detach.isHidden = !workspace.can("orchestration:operate") || workspace.detail.queue.attachedSessionIDs.isEmpty
        detach.isEnabled = canOperate
        nativeChildren.isHidden = !workspace.canReadNativeChildWork
        nativeChildren.isEnabled = scope != nil
        footer.isHidden = detach.isHidden && nativeChildren.isHidden
        let status: String
        if let failure { status = failure }
        else if scope == nil { status = "Connect to the environment to see related conversations." }
        else if rows.isEmpty { status = familyTask != nil || !workspace.detail.loaded ? "Loading relationships…" : "No related conversations." }
        else { status = "" }
        notice.stringValue = status
        notice.textColor = failure == nil ? WorkspaceStyle.muted : WorkspaceStyle.negative
        notice.isHidden = status.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .relation = items[row] { return 38 }
        return 23
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        switch items[index] {
        case .heading(let title):
            return label(title, size: 11.5, weight: .medium, color: WorkspaceStyle.muted)
        case .previousAgents:
            return ActionButton("Previous Subagents", symbol: showsPreviousAgents ? "chevron.down" : "chevron.right", style: .subtle) { [weak self] in
                guard let self else { return }
                showsPreviousAgents.toggle()
                rebuildItems()
                table.reloadData()
            }
        case .relation(let entry):
            return relationView(entry)
        }
    }

    private func relationView(_ entry: ThreadRelationshipRow) -> NSView {
        let open = ActionButton(entry.title, symbol: entry.kind.symbol, style: .subtle) { [weak self] in
            guard let self else { return }
            if let target = entry.target { onOpen?(target) }
            else if let agent = entry.subagent { openSheet(.subagent(agent, title: entry.title)) }
        }
        open.alignment = .left
        open.font = .systemFont(ofSize: 12, weight: .medium)
        open.lineBreakMode = .byTruncatingTail
        open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        open.isEnabled = scope != nil
        open.toolTip = entry.detail.map { "\(entry.title) · \($0)" } ?? entry.title
        let details = entry.detail.map { [label($0, size: 10.5, color: WorkspaceStyle.muted)] } ?? []
        let title = column([open] + details, spacing: 1, alignment: .width)
        let state = label(Self.statusText(entry.status), size: 10.5, color: entry.isWorking ? WorkspaceStyle.accent : WorkspaceStyle.muted)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        var controls: [NSView] = state.stringValue.isEmpty ? [] : [state]
        if let id = entry.target?.threadID, entry.target?.environmentID == nil,
           workspace.selectedThread?.mergeBackTargetID == id, workspace.selectedThread?.isSideChat == false {
            let action = ActionButton("Merge Back", symbol: "arrow.turn.down.left", iconOnly: true, style: .subtle) { [weak self] in
                guard let self, let scope else { return }
                run {
                    try await self.workspace.mergeForkBack(id, scope: scope)
                    if self.workspace.threadRelationshipScope == scope { self.onOpen?(.init(threadID: id)) }
                }
            }
            action.isEnabled = lastCanOperate && lastMergeReason == nil
            action.toolTip = lastMergeReason ?? "Include this fork in the source conversation’s next message."
            controls.append(action)
        }
        if let agent = entry.subagent {
            if entry.target != nil {
                controls.append(ActionButton("About \(entry.title)", symbol: "info.circle", iconOnly: true, style: .subtle) { [weak self] in
                    self?.openSheet(.subagent(agent, title: entry.title))
                })
            }
            if agent.workflowScript != nil {
                controls.append(ActionButton("View Workflow Script", symbol: "doc.text", iconOnly: true, style: .subtle) { [weak self] in
                    self?.openSheet(.workflowScript(agent))
                })
            }
            if entry.isWorking && (agent.canStopTask || agent.canStopWorkflow),
               workspace.can("orchestration:operate") {
                let stop = ActionButton("Stop \(entry.title)", symbol: "stop.fill", iconOnly: true, style: .subtle) { [weak self] in
                    guard let self, let scope else { return }
                    run { try await self.workspace.stopRelatedSubagent(agent.id, scope: scope) }
                }
                stop.isEnabled = lastCanOperate
                controls.append(stop)
            }
        }
        let cell = NSTableCellView()
        let trailing = row(controls, spacing: 5)
        let controlsWidth = trailing.fittingSize.width
        for view in [title, trailing] {
            cell.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            title.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -7),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            trailing.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: controlsWidth),
        ])
        return cell
    }

    private func openSheet(_ content: RelatedWorkSheet.Content) {
        guard let scope, let window = view.window, window.attachedSheet == nil else { return }
        let sheet = RelatedWorkSheet(workspace: workspace, scope: scope, content: content)
        self.sheet = sheet
        sheet.onClose = { [weak self] in self?.sheet = nil }
        sheet.present(in: window)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard actionID == nil else { return }
        let id = UUID()
        actionID = id
        failure = nil
        updateControls()
        Task { [weak self] in
            guard let self else { return }
            do { try await action() }
            catch { if actionID == id { failure = error.localizedDescription } }
            if actionID == id { actionID = nil; sync(.sidebar) }
        }
    }

    private static func statusText(_ status: String?) -> String {
        switch status {
        case "running", "starting", "preparing": "Working"
        case "pending", "queued": "Queued"
        case "waiting", "needs input": "Needs input"
        case "completed", "settled": "Done"
        case "rolled_back", "interrupted", "cancelled", "canceled": "Stopped"
        case "failed", "error": "Failed"
        case "archived": "Archived"
        default: ""
        }
    }
}
