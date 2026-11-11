import AppKit

@MainActor
private final class ProjectActionForm: NSView, NSTextFieldDelegate {
    private let name = NSTextField()
    private let command = NSTextView()
    private let icon = NSPopUpButton()
    private let setup = NSButton(checkboxWithTitle: "Run after creating a worktree", target: nil, action: nil)
    private let wait = NSButton(checkboxWithTitle: "Wait for setup before starting the agent", target: nil, action: nil)
    private let settle = NSButton(checkboxWithTitle: "Run when the thread settles", target: nil, action: nil)
    private let stop = NSButton(checkboxWithTitle: "Stop this action when the thread settles", target: nil, action: nil)
    private let preview = NSTextField()
    private let autoPreview = NSButton(checkboxWithTitle: "Open the preview when this action starts", target: nil, action: nil)
    private let original: ProjectActionDraft
    var firstResponder: NSResponder { name }

    init(_ draft: ProjectActionDraft) {
        original = draft
        super.init(frame: .zero)
        name.stringValue = draft.name
        command.string = draft.command
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.textColor = WorkspaceStyle.ink
        command.insertionPointColor = WorkspaceStyle.ink
        command.textContainerInset = NSSize(width: 5, height: 5)
        command.isAutomaticQuoteSubstitutionEnabled = false
        command.isAutomaticDashSubstitutionEnabled = false
        command.isAutomaticTextReplacementEnabled = false
        command.isAutomaticSpellingCorrectionEnabled = false
        command.setAccessibilityLabel("Command")
        let commandScroll = textScroller(command, editable: true)
        commandScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        let commandBox = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 7)
        fill(commandScroll, in: commandBox, inset: 2)
        for style in ProjectActionIcon.allCases {
            let item = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
            item.image = WorkspaceStyle.symbol(style.symbol, size: 11)
            item.representedObject = style.rawValue
            icon.menu?.addItem(item)
        }
        icon.selectItem(withTitle: draft.icon.title)
        icon.isBordered = false
        preview.stringValue = draft.preview
        preview.placeholderString = "http://localhost:5173"
        preview.delegate = self
        for (button, value) in [(setup, draft.setup), (wait, draft.waitForSetup), (settle, draft.onSettle),
                                (stop, draft.stopOnSettle), (autoPreview, draft.autoOpenPreview)] {
            button.state = value ? .on : .off
        }
        setup.target = self
        setup.action = #selector(refreshControls)
        let fields = column([
            field("Name", name), field("Command", commandBox), field("Icon", row([icon, NSView()])),
            field("Preview URL", preview), setup, wait, settle, stop, autoPreview, NSView(),
        ], spacing: 8, alignment: .width)
        fill(fields, in: self)
        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var draft: ProjectActionDraft {
        var draft = original
        draft.name = name.stringValue
        draft.command = command.string
        draft.icon = (icon.selectedItem?.representedObject as? String).flatMap(ProjectActionIcon.init(rawValue:)) ?? .play
        draft.setup = setup.state == .on
        draft.waitForSetup = wait.state == .on
        draft.onSettle = settle.state == .on
        draft.stopOnSettle = stop.state == .on
        draft.preview = preview.stringValue
        draft.autoOpenPreview = autoPreview.state == .on
        return draft
    }

    func controlTextDidChange(_ notification: Notification) { refreshControls() }

    @objc private func refreshControls() {
        wait.isEnabled = setup.state == .on
        autoPreview.isEnabled = !preview.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func field(_ title: String, _ control: NSView) -> NSView {
        let caption = label(title, size: 12, color: WorkspaceStyle.secondary)
        caption.widthAnchor.constraint(equalToConstant: 82).isActive = true
        control.setAccessibilityLabel(title)
        return row([caption, control], spacing: 10)
    }
}

@MainActor
final class ProjectActionsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let target: ProjectTarget
    private let table = NSTableView()
    private let body = NSView()
    private let title = label("Project Actions", size: 15, weight: .semibold, color: WorkspaceStyle.ink)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var actions: [ProjectAction] = []
    private var list: NSView?
    private var form: ProjectActionForm?
    private var editing: ProjectAction?
    private var editingID: String?
    private var task: Task<Void, Never>?
    private var failure: String?
    private lazy var add = ActionButton("Add Action…", symbol: "plus", style: .subtle) { [weak self] in self?.edit(.init()) }
    private lazy var fileImport = ActionButton("Import from t3.json…", style: .subtle) { [weak self] in self?.readImports() }
    private lazy var change = ActionButton("Edit…", style: .subtle) { [weak self] in
        guard let self, let selected else { return }
        edit(selected.draft, replacing: selected)
    }
    private lazy var remove = ActionButton("Remove", style: .subtle) { [weak self] in
        guard let self, let selected else { return }
        save(.remove(selected))
    }
    private lazy var inherit = ActionButton("Use Environment Actions", style: .subtle) { [weak self] in self?.save(.inherit) }
    private lazy var done = ActionButton("Done", style: .subtle) { [weak self] in self?.dismiss() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.cancelEdit() }
    private lazy var saveButton = ActionButton("Save Action", style: .subtle) { [weak self] in
        guard let self, let form, let editingID else { return }
        save(.save(form.draft, id: editingID, replacing: editing))
    }
    private lazy var listButtons = row([inherit, NSView(), done])
    private lazy var editButtons = row([NSView(), cancel, saveButton])
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: ProjectTarget) {
        self.workspace = workspace
        self.target = target
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Project Actions"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let tableColumn = NSTableColumn(identifier: .init("action"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.rowHeight = 44
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.backgroundColor = .clear
        table.setAccessibilityLabel("Project Actions")
        table.target = self
        table.doubleAction = #selector(editSelected)
        let tableBox = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 8)
        fill(scroller(for: table), in: tableBox, inset: 2)
        let list = column([tableBox, row([add, fileImport, NSView(), change, remove])], spacing: 9, alignment: .width)
        self.list = list
        fill(list, in: body)
        remove.contentTintColor = WorkspaceStyle.negative
        message.font = .systemFont(ofSize: 11.5)
        message.textColor = WorkspaceStyle.secondary
        message.maximumNumberOfLines = 2
        let content = Surface(WorkspaceStyle.navigation)
        let layout = column([title, body, message, listButtons, editButtons], spacing: 12, alignment: .width)
        fill(layout, in: content, inset: 16)
        window.contentView = content
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var project: Project? {
        workspace.projectTarget(target.id) == target ? workspace.data.projects[target.id] : nil
    }
    private var selected: ProjectAction? { actions.indices.contains(table.selectedRow) ? actions[table.selectedRow] : nil }
    private var canEdit: Bool { workspace.canEditProjectDefaults(target) && workspace.can("settings:write") }

    func present(in parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
    }

    func sync() {
        let next = project.map(workspace.projectActions) ?? []
        if actions != next {
            let id = selected?.id
            actions = next
            table.reloadData()
            if let index = next.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        render()
    }

    private func render() {
        let idle = task == nil
        let editable = canEdit && idle
        let isEditing = form != nil
        list?.isHidden = isEditing
        listButtons.isHidden = isEditing
        editButtons.isHidden = !isEditing
        title.stringValue = isEditing ? (editing == nil ? "Add Project Action" : "Edit Project Action") : project?.name ?? "Project Actions"
        add.isEnabled = editable
        fileImport.isEnabled = editable && workspace.projectFileScope(target.id) != nil
        change.isEnabled = editable && selected != nil
        remove.isEnabled = change.isEnabled
        inherit.isEnabled = editable && project.flatMap { workspace.projectPreferences.override(.actions, for: $0) } != nil
        cancel.isEnabled = idle
        done.isEnabled = idle
        saveButton.isEnabled = editable
        let text = failure ?? (!idle ? "Working…" : project == nil ? "The project connection changed." :
            !canEdit ? "This connection can view project actions." : actions.isEmpty && !isEditing ? "No actions configured." : "")
        message.stringValue = text
        message.isHidden = text.isEmpty
    }

    @objc private func editSelected() {
        if let selected { edit(selected.draft, replacing: selected) }
    }

    private func edit(_ draft: ProjectActionDraft, replacing action: ProjectAction? = nil) {
        guard canEdit, task == nil, form == nil else { return }
        editing = action
        editingID = action?.id ?? ProjectActionChange.newID()
        failure = nil
        let form = ProjectActionForm(draft)
        self.form = form
        fill(form, in: body)
        render()
        window?.makeFirstResponder(form.firstResponder)
    }

    private func cancelEdit() {
        form?.removeFromSuperview()
        form = nil
        editing = nil
        editingID = nil
        failure = nil
        render()
    }

    private func save(_ change: ProjectActionChange) {
        guard task == nil, canEdit else { return }
        failure = nil
        task = Task { [weak self, workspace, target] in
            do {
                try await workspace.changeProjectActions(target, change)
                self?.cancelEdit()
            } catch { self?.failure = error.localizedDescription }
            self?.task = nil
            self?.sync()
        }
        render()
    }

    private func readImports() {
        guard task == nil, canEdit, let scope = workspace.projectFileScope(target.id) else { return }
        failure = nil
        task = Task { [weak self, workspace] in
            do {
                let candidates = try await workspace.readProjectFile(scope)?.actions ?? []
                guard let self else { return }
                task = nil
                let imports = candidates.filter { candidate in
                    !actions.contains { $0.draft.command == candidate.command || $0.draft.name.caseInsensitiveCompare(candidate.name) == .orderedSame }
                }
                if imports.isEmpty { failure = "No new actions in t3.json." }
                render()
                guard !imports.isEmpty, canEdit else { return }
                let menu = NSMenu()
                for draft in imports {
                    let item = menuItem(draft.name, target: self, action: #selector(importAction(_:)))
                    item.representedObject = draft
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: fileImport.bounds.height), in: fileImport)
            } catch {
                self?.task = nil
                self?.failure = error.localizedDescription
                self?.render()
            }
        }
        render()
    }

    @objc private func importAction(_ item: NSMenuItem) {
        if let draft = item.representedObject as? ProjectActionDraft { edit(draft) }
    }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }
    func tableViewSelectionDidChange(_ notification: Notification) { render() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let draft = actions[index].draft
        let name = label(draft.name, size: 12.5, weight: .medium, color: WorkspaceStyle.ink)
        let command = label(draft.command.replacingOccurrences(of: "\n", with: " "), size: 11, color: WorkspaceStyle.muted)
        command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        command.toolTip = draft.command
        let icon = WorkspaceStyle.icon(draft.icon.symbol, size: 13)
        let text = column([name, command], spacing: 3, alignment: .width)
        let cell = NSTableCellView()
        for item in [icon, text] {
            item.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(item)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
