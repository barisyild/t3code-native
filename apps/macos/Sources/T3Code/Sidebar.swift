import AppKit

@MainActor
final class NavigationRail: NSViewController {
    private(set) lazy var sidebarButton = button("Toggle Sidebar", "sidebar.left", action: { [weak self] in self?.onSidebar?() })
    private(set) lazy var newButton = button("New Thread", "square.and.pencil", action: { [weak self] in self?.onNew?() })
    private(set) lazy var terminalButton = button("Terminal", "terminal", action: { [weak self] in self?.onTerminal?() })
    private(set) lazy var filesButton = button("Files", "folder", action: { [weak self] in self?.onFiles?() })
    private(set) lazy var usageButton = button("Usage", "chart.bar", action: { [weak self] in self?.onUsage?() })
    var onSidebar: (() -> Void)?
    var onNew: (() -> Void)?
    var onSearch: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onFiles: (() -> Void)?
    var onUsage: (() -> Void)?
    var onSettings: (() -> Void)?

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let search = button("Search Threads", "magnifyingglass", action: { [weak self] in self?.onSearch?() })
        let settings = button("Settings", "gearshape", action: { [weak self] in self?.onSettings?() })
        let divider = Surface(WorkspaceStyle.line)
        divider.widthAnchor.constraint(equalToConstant: 24).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = column([sidebarButton, newButton, search, divider, terminalButton, filesButton, NSView(), usageButton, settings],
                           spacing: 6, alignment: .centerX)
        stack.setCustomSpacing(11, after: search)
        stack.setCustomSpacing(11, after: divider)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 49),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle, action: action)
        button.image = WorkspaceStyle.symbol(symbol, size: 14)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 35).isActive = true
        return button
    }
}

@MainActor
private final class NavigatorRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        WorkspaceStyle.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

@MainActor
private final class NavigatorCell: NSTableCellView {
    var activityStart: Date?
    weak var timeLabel: NSTextField?

    func refreshTime() {
        if let activityStart { timeLabel?.stringValue = WorkspaceStyle.elapsed(since: activityStart) }
    }
}

@MainActor
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private final class Item: NSObject {
        enum Section { case pinned, projects, chats, archive, empty }

        let selection: Workspace.Selection?
        let section: Section?
        let title: String
        let icon: String?
        let detail: String?
        let timestamp: String?
        let isWorking: Bool
        let needsInput: Bool
        let children: [Item]

        init(_ selection: Workspace.Selection? = nil, section: Section? = nil, title: String, icon: String? = nil,
             detail: String? = nil, timestamp: String? = nil, isWorking: Bool = false, needsInput: Bool = false,
             children: [Item] = []) {
            self.selection = selection
            self.section = section
            self.title = title
            self.icon = icon
            self.detail = detail
            self.timestamp = timestamp
            self.isWorking = isWorking
            self.needsInput = needsInput
            self.children = children
        }

        func matches(_ other: Item) -> Bool {
            selection == other.selection && section == other.section && title == other.title && icon == other.icon &&
                detail == other.detail && timestamp == other.timestamp && isWorking == other.isWorking &&
                needsInput == other.needsInput && children.count == other.children.count &&
                zip(children, other.children).allSatisfy { $0.matches($1) }
        }
    }

    private let workspace: Workspace
    private let outline = NSOutlineView()
    private lazy var scroll = scroller(for: outline)
    private let search = NSSearchField()
    private let environment = label("Disconnected", size: 11, color: WorkspaceStyle.muted)
    private let scheduledCount = label(size: 11, color: WorkspaceStyle.muted)
    private let connectionDot = WorkspaceStyle.icon("circle.fill", size: 5, tint: WorkspaceStyle.muted)
    private lazy var newThread = navigationButton("New Thread", "square.and.pencil") { [weak self] in self?.onNew?() }
    private lazy var activity = navigationButton("Activity", "waveform.path") { [weak self] in self?.toggleActivity() }
    private lazy var scheduled = navigationButton("Scheduled", "clock") { [weak self] in self?.onScheduled?() }
    private lazy var pullRequests = navigationButton("Pull Requests", "arrow.triangle.pull") { [weak self] in self?.onPullRequests?(nil) }
    private lazy var archive = navigationButton("Archive", "archivebox") { [weak self] in
        guard let self else { return }
        onShowWorkspace?()
        workspace.showArchive(!workspace.isShowingArchive)
    }
    private var roots: [Item] = []
    private var collapsed = Set<Workspace.Selection>()
    private var rebuilding = false
    private var page = WorkspacePage.conversation
    private(set) var showsActivityOnly = false
    var onAdd: (() -> Void)?
    var onSearch: (() -> Void)?
    var onNew: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onScheduled: (() -> Void)?
    var onPullRequests: ((String?) -> Void)?
    var onShowWorkspace: (() -> Void)?
    var onThreadAction: ((String, String) -> Void)?
    var onProjectSettings: ((ProjectTarget) -> Void)?
    var onProjectChange: ((ProjectTarget, ProjectMetadataChange) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let content = NSTableColumn(identifier: .init("name"))
        content.resizingMask = .autoresizingMask
        outline.addTableColumn(content)
        outline.outlineTableColumn = content
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Projects and Threads")
        let context = NSMenu()
        context.delegate = self
        outline.menu = context
        search.placeholderString = "Filter threads"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.setAccessibilityLabel("Filter threads")
        search.isHidden = true

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let searchButton = navigationButton("Search", "magnifyingglass") { [weak self] in
            guard let self else { return }
            if let onSearch { onSearch() }
            else { focusSearch() }
        }
        activity.setButtonType(.pushOnPushOff)
        scheduledCount.isHidden = scheduledCount.stringValue.isEmpty
        scheduled.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let scheduledRow = row([scheduled, scheduledCount], spacing: 6)
        let commands = column([newThread, searchButton, search, activity, pullRequests, scheduledRow, archive], spacing: 1,
                              alignment: .width)
        let commandArea = NSView()
        commandArea.addSubview(commands)
        commands.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            commands.leadingAnchor.constraint(equalTo: commandArea.leadingAnchor, constant: 8),
            commands.trailingAnchor.constraint(equalTo: commandArea.trailingAnchor),
            commands.topAnchor.constraint(equalTo: commandArea.topAnchor),
            commands.bottomAnchor.constraint(equalTo: commandArea.bottomAnchor),
        ])
        let footer = row([connectionDot, environment, NSView()], spacing: 6)
        footer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = column([commandArea, scroll, footer], spacing: 7, alignment: .width)
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 43),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
    }

    private func navigationButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, style: .subtle, action: action)
        button.alignment = .left
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
        return button
    }

    func render(reloadOutline: Bool = false) {
        let _ = view
        let canOperate = workspace.can("orchestration:operate")
        newThread.isEnabled = canOperate
        archive.isEnabled = workspace.connection == .ready
        let isArchived = workspace.isShowingArchive
        if isArchived { showsActivityOnly = false }
        activity.isEnabled = workspace.connection == .ready || showsActivityOnly
        activity.isMarked = showsActivityOnly
        activity.state = showsActivityOnly ? .on : .off
        activity.toolTip = showsActivityOnly ? "Show all threads" : "Show only active threads"
        activity.setAccessibilityHelp(activity.toolTip)
        archive.isMarked = isArchived && page == .conversation
        scheduled.isMarked = page == .scheduled
        pullRequests.isMarked = page == .pullRequests
        archive.toolTip = isArchived ? "Show All Threads" : "Show Archive"
        archive.setAccessibilityLabel(archive.toolTip)
        environment.stringValue = workspace.environment?.name ?? "Disconnected"
        environment.toolTip = workspace.environment?.origin.absoluteString
        connectionDot.contentTintColor = workspace.connection == .ready ? WorkspaceStyle.positive : WorkspaceStyle.muted

        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = isArchived ? workspace.data.archived : workspace.data.threads
        let activeParents = showsActivityOnly ? workspace.data.listedActivityParents(for: candidates) : []
        let threads = Dictionary(grouping: candidates.values.filter(workspace.data.isListed),
                                 by: \.projectId)
        let projects = workspace.data.orderedProjects
        var pinned: [ThreadSummary] = []
        var projectRows: [Item] = []
        var chats: [Item] = []
        for project in projects {
            let matchesProject = query.isEmpty || project.name.localizedCaseInsensitiveContains(query)
            let visible = (threads[project.id] ?? []).filter {
                (!showsActivityOnly || $0.isActive || activeParents.contains($0.id)) &&
                    (matchesProject || $0.title.localizedCaseInsensitiveContains(query))
            }
            if !isArchived { pinned.append(contentsOf: visible.filter(\.pinned)) }
            let children = visible.filter { isArchived || !$0.pinned }.sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return (lhs.updatedAt, lhs.id) > (rhs.updatedAt, rhs.id)
            }.map {
                threadItem($0)
            }
            if workspace.isScratch(project), !isArchived || !project.archived {
                chats.append(contentsOf: children)
            } else if !children.isEmpty || (matchesProject && (isArchived ? project.archived : !project.archived && !showsActivityOnly)) {
                let clone = workspace.cloneStatus(project.id)
                let cloning = clone?.phase == .starting || clone?.phase == .running
                let needsRetry = clone?.canRetry == true
                let icon = project.archived ? "archivebox" : cloning ? "arrow.down.circle" : needsRetry ? "exclamationmark.circle" :
                    project.pinned ? "pin" : "folder"
                let detail = clone?.sendReason.map { "\($0) · \(project.root)" } ?? project.root
                projectRows.append(Item(.project(project.id), title: project.name, icon: icon, detail: detail, needsInput: needsRetry,
                                        children: children))
            }
        }
        var next: [Item] = []
        if !pinned.isEmpty {
            next.append(Item(section: .pinned, title: "Pinned"))
            next.append(contentsOf: pinned.sorted { lhs, rhs in
                if let key = lhs.pinOrderKey { return rhs.pinOrderKey.map { (key, lhs.id) < ($0, rhs.id) } ?? true }
                if rhs.pinOrderKey != nil { return false }
                return lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
            }.map { thread in
                let project = workspace.data.projects[thread.projectId]
                return threadItem(thread, projectName: project.flatMap { workspace.isScratch($0) ? nil : $0.name })
            })
        }
        if !showsActivityOnly || !projectRows.isEmpty {
            next.append(Item(section: isArchived ? .archive : .projects, title: isArchived ? "Archived" : "Projects"))
            next.append(contentsOf: projectRows)
        }
        if !chats.isEmpty || (!isArchived && !showsActivityOnly && query.isEmpty && canOperate) {
            next.append(Item(section: .chats, title: "Chats"))
            next.append(contentsOf: chats)
        }
        if showsActivityOnly && next.isEmpty {
            next.append(Item(section: .empty, title: query.isEmpty ? "No active threads" : "No matching active threads"))
        }

        rebuilding = true
        defer { rebuilding = false }
        if reloadOutline || next.count != roots.count || !zip(next, roots).allSatisfy({ $0.matches($1) }) {
            roots = next
            outline.reloadData()
            for item in roots where !item.children.isEmpty &&
                (showsActivityOnly || !query.isEmpty || item.selection.map(collapsed.contains) != true) {
                outline.expandItem(item)
            }
        }
        if page == .conversation, let selection = workspace.selection,
           let item = roots.lazy.flatMap({ [$0] + $0.children }).first(where: { $0.selection == selection }),
           outline.row(forItem: item) >= 0 {
            let index = outline.row(forItem: item)
            if outline.selectedRow != index { outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
    }

    private func threadItem(_ thread: ThreadSummary, projectName: String? = nil) -> Item {
        let icon: String
        if thread.needsAttention { icon = "exclamationmark.circle" }
        else if thread.isWorking { icon = "circle.dotted" }
        else if thread.isWaitingForBackgroundWork { icon = "clock" }
        else { icon = thread.pinned ? "pin" : "bubble.left" }
        let context = [projectName, thread.branch].compactMap { $0 }
        return Item(.thread(thread.id), title: thread.title, icon: icon,
                    detail: context.isEmpty ? nil : context.joined(separator: " · "),
                    timestamp: thread.isWorking ? thread.activeSince : thread.updatedAt,
                    isWorking: thread.isWorking, needsInput: thread.needsAttention)
    }

    func toggleActivity() {
        showsActivityOnly.toggle()
        if workspace.isShowingArchive { workspace.showArchive(false) }
        render(reloadOutline: true)
    }

    func setScheduledCount(_ count: Int?) {
        scheduledCount.isHidden = (count ?? 0) == 0
        scheduledCount.stringValue = count.flatMap { $0 == 0 ? nil : String($0) } ?? ""
    }

    func setPage(_ page: WorkspacePage) {
        self.page = page
        render()
    }

    func focusSearch() {
        search.isHidden = false
        view.window?.makeFirstResponder(search)
    }

    func refreshActivityTimes() {
        outline.enumerateAvailableRowViews { _, index in
            (self.outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? NavigatorCell)?.refreshTime()
        }
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        search.stringValue = ""
        search.isHidden = true
        view.window?.makeFirstResponder(outline)
        render()
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let selection = (item as? Item)?.selection else { return false }
        if case .project(let id) = selection { return !workspace.isShowingArchive && workspace.data.projects[id]?.archived == false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding, outline.selectedRow >= 0,
              let selection = (outline.item(atRow: outline.selectedRow) as? Item)?.selection else { return }
        workspace.select(selection)
        onShowWorkspace?()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !rebuilding, !showsActivityOnly, search.stringValue.isEmpty,
           let selection = (notification.userInfo?["NSObject"] as? Item)?.selection {
            collapsed.insert(selection)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !rebuilding, !showsActivityOnly, search.stringValue.isEmpty,
           let selection = (notification.userInfo?["NSObject"] as? Item)?.selection {
            collapsed.remove(selection)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Item)?.section == nil ? 29 : 33
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NavigatorRow() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let cell = NavigatorCell()
        if let section = item.section {
            let title = label(item.title, size: 11.5, weight: .medium, color: WorkspaceStyle.muted)
            let header = row([title, NSView()], spacing: 4)
            if (section == .projects || section == .chats) && workspace.can("orchestration:operate") {
                let add = ActionButton(section == .chats ? "New Chat" : "Add Project",
                                       symbol: section == .chats ? "square.and.pencil" : "folder.badge.plus",
                                       iconOnly: true, style: .subtle) { [weak self] in
                    if section == .chats { self?.onNewChat?() }
                    else { self?.onAdd?() }
                }
                add.widthAnchor.constraint(equalToConstant: 24).isActive = true
                add.heightAnchor.constraint(equalToConstant: 23).isActive = true
                header.addArrangedSubview(add)
            }
            fill(header, in: cell, inset: 3)
            cell.textField = title
            return cell
        }

        let name = label(item.title, size: 13, color: WorkspaceStyle.ink)
        name.toolTip = item.detail ?? item.title
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let icon = WorkspaceStyle.icon(item.icon ?? "bubble.left", size: 12,
                                       tint: item.needsInput ? WorkspaceStyle.accent : WorkspaceStyle.secondary)
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        let stack = row([icon, name], spacing: 7)
        if let date = WorkspaceStyle.date(item.timestamp) {
            let time = label(item.isWorking ? WorkspaceStyle.elapsed(since: date) : WorkspaceStyle.age(date),
                             size: 11, color: WorkspaceStyle.muted)
            time.setContentHuggingPriority(.required, for: .horizontal)
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.edgeInsets.right = 5
            if item.isWorking {
                time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                time.textColor = WorkspaceStyle.secondary
                time.alignment = .center
                time.setAccessibilityLabel("Elapsed time")
                let badge = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 5)
                badge.addSubview(time)
                time.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    badge.heightAnchor.constraint(equalToConstant: 17),
                    time.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
                    time.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
                    time.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
                ])
                cell.activityStart = date
                cell.timeLabel = time
                stack.addArrangedSubview(badge)
            } else {
                stack.addArrangedSubview(time)
            }
        }
        fill(stack, in: cell, inset: 3)
        cell.textField = name
        return cell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let selection = (outline.item(atRow: outline.clickedRow) as? Item)?.selection else { return }
        switch selection {
        case .project(let id):
            guard let project = workspace.data.projects[id], let target = workspace.projectTarget(id) else { return }
            if !workspace.isShowingArchive, !project.archived, workspace.canEditProject(target) {
                let action = menuItem("New Thread", target: self, action: #selector(contextNew(_:)))
                action.representedObject = id
                menu.addItem(action)
            }
            if !workspace.isShowingArchive, !project.archived, !workspace.isScratch(project) {
                let action = menuItem("Pull Requests", target: self, action: #selector(contextPullRequests(_:)))
                action.representedObject = id
                menu.addItem(action)
            }
            let settings = menuItem("Project Settings…", target: self, action: #selector(contextProjectSettings(_:)))
            settings.representedObject = target
            menu.addItem(settings)
            if workspace.canEditProject(target), workspace.supportsProjectOrganization {
                let actions: [(String, ProjectMetadataChange)] = [
                    (project.pinned ? "Unpin Project" : "Pin Project", .pin(!project.pinned)),
                    (project.archived ? "Restore Project" : "Archive Project", .archive(!project.archived)),
                ]
                for (title, change) in actions {
                    let action = menuItem(title, target: self, action: #selector(contextProjectChange(_:)))
                    action.representedObject = (target, change)
                    menu.addItem(action)
                }
            }
        case .thread(let id):
            let thread = workspace.data.threads[id] ?? workspace.data.archived[id]
            if thread?.archived == false, thread?.isProviderNativeSubagent == false, workspace.can("orchestration:read"),
               workspace.canCreateGuestShare || workspace.presentedDetail(for: id)?.guestShare != nil {
                let share = menuItem("Share with Guest…", target: self, action: #selector(contextAction(_:)))
                share.representedObject = [id, "guest-share"]
                menu.addItem(share)
            }
            guard workspace.can("orchestration:operate") else { return }
            let actions = thread?.archived == true ? [("Restore Thread", "thread.unarchive")] : [
                ("Rename Thread…", "rename"),
                ("Schedule Task…", "schedule"),
                (thread?.pinned == true ? "Unpin Thread" : "Pin Thread", thread?.pinned == true ? "thread.unpin" : "thread.pin"),
                ("Archive Thread", "thread.archive"),
            ]
            for (name, command) in actions {
                let action = menuItem(name, target: self, action: #selector(contextAction(_:)))
                action.representedObject = [id, command]
                menu.addItem(action)
            }
        }
    }

    @objc private func contextNew(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        workspace.select(.project(id))
        onNew?()
    }

    @objc private func contextPullRequests(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onPullRequests?(id) }
    }

    @objc private func contextProjectSettings(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? ProjectTarget { onProjectSettings?(target) }
    }

    @objc private func contextProjectChange(_ sender: NSMenuItem) {
        if let (target, change) = sender.representedObject as? (ProjectTarget, ProjectMetadataChange) {
            onProjectChange?(target, change)
        }
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        if let args = sender.representedObject as? [String], args.count == 2 { onThreadAction?(args[0], args[1]) }
    }
}
