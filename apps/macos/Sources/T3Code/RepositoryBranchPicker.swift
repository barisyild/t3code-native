import AppKit

@MainActor
final class RepositoryBranchPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Mode {
        case checkout
        case worktreeBase(String?)

        var selectsBase: Bool {
            if case .worktreeBase = self { return true }
            return false
        }
    }

    private let workspace: Workspace
    private let target: RepositoryTarget
    private let mode: Mode
    private let search = NSSearchField()
    private let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private lazy var apply = ActionButton(mode.selectsBase ? "Use Worktree Base" : "Switch Branch") { [weak self] in
        self?.applySelection()
    }
    private lazy var create = ActionButton("Create Branch…") { [weak self] in self?.confirmCreate() }
    private lazy var more = ActionButton("Load More") { [weak self] in self?.loadPage(append: true) }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    private var refs: [RepositoryRef] = []
    private var isRepository = false
    private var cursor: Int?
    private var loading: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private var confirming = false
    var onClose: (() -> Void)?

    init(workspace: Workspace, target: RepositoryTarget, mode: Mode) {
        self.workspace = workspace
        self.target = target
        self.mode = mode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 402),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        let title = mode.selectsBase ? "New worktree" : "Switch branch"
        window.title = title
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let context = label(target.path, size: 11, color: WorkspaceStyle.muted)
        context.toolTip = target.path
        search.placeholderString = mode.selectsBase ? "Search branches or enter a revision" : "Search local and remote branches"
        search.setAccessibilityLabel(mode.selectsBase ? "Worktree Base" : "Find Branch")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        if case .worktreeBase(let base) = mode { search.stringValue = base ?? "" }
        table.addTableColumn(NSTableColumn(identifier: .init("ref")))
        table.headerView = nil
        table.rowHeight = 30
        table.style = .inset
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.setAccessibilityLabel("Branches")
        note.font = .systemFont(ofSize: 11)
        note.textColor = WorkspaceStyle.muted
        note.maximumNumberOfLines = 3
        note.setContentHuggingPriority(.required, for: .vertical)
        note.setContentCompressionResistancePriority(.required, for: .vertical)
        apply.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        create.isHidden = mode.selectsBase
        let list = scroller(for: table)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let footer = row([create, more, NSView(), cancel, apply], spacing: 8)
        fill(column([label(title, size: 16, weight: .semibold), context, search, list, note, footer],
                    spacing: 10, alignment: .width), in: surface, inset: 18)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.loading?.cancel()
            self?.onClose?()
        }
        window.makeFirstResponder(search)
        loadPage()
    }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selected: RepositoryRef? { refs.indices.contains(table.selectedRow) ? refs[table.selectedRow] : nil }

    func controlTextDidChange(_ obj: Notification) { loadPage(debounce: true) }

    private func loadPage(append: Bool = false, debounce: Bool = false) {
        loading?.cancel()
        let id = UUID()
        requestID = id
        let query = self.query
        var input = target.input
        input["limit"] = .int(80)
        if !query.isEmpty { input["query"] = .string(String(query.prefix(256))) }
        if append, let cursor { input["cursor"] = .int(cursor) }
        else {
            refs = []
            isRepository = false
            cursor = nil
            table.reloadData()
        }
        loading = Task {
            defer {
                if requestID == id { loading = nil; render() }
            }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(180)) }
                guard workspace.isCurrent(target) else { throw ClientError.disconnected }
                let result = try await workspace.request("vcs.listRefs", input)
                try Task.checkCancellation()
                guard workspace.isCurrent(target) else { throw ClientError.disconnected }
                let refs = result["refs"].array.compactMap(RepositoryRef.init)
                isRepository = result["isRepo"].bool == true
                self.refs += refs
                cursor = result["nextCursor"].int
                table.reloadData()
                if !isRepository { setNote("This folder is outside a Git repository.") }
                else if self.refs.isEmpty {
                    setNote(mode.selectsBase ? "Enter a Git revision or choose a branch." : "No matching branches.")
                } else {
                    let count = result["totalCount"].int ?? self.refs.count
                    setNote(cursor == nil ? "" : "Showing \(self.refs.count) of \(count) refs")
                }
            } catch {
                if !Task.isCancelled { setNote(error.localizedDescription, error: true) }
            }
        }
        setNote("Loading branches…")
        render()
    }

    private func setNote(_ message: String, error: Bool = false) {
        note.stringValue = message
        note.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
    }

    private func render() {
        let idle = operation == nil && !confirming
        let canOperate = workspace.isCurrent(target) && workspace.can("orchestration:operate")
        let canSwitch = canOperate && workspace.canChangeRepository(target)
        search.isEnabled = idle
        table.isEnabled = idle
        apply.isEnabled = idle && isRepository &&
            (mode.selectsBase ? canOperate && (selected != nil || !query.isEmpty) : canSwitch && selected != nil)
        create.isEnabled = idle && isRepository && canSwitch && loading == nil && !query.isEmpty && query.utf8.count <= 255 &&
            !refs.contains { !$0.isRemote && $0.name == query }
        more.isHidden = cursor == nil
        more.isEnabled = idle && loading == nil
        cancel.isEnabled = idle
    }

    func numberOfRows(in tableView: NSTableView) -> Int { refs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let ref = refs[index]
        let icon = WorkspaceStyle.icon(ref.isCurrent ? "checkmark" : ref.isRemote ? "cloud" : "arrow.triangle.branch", size: 11)
        let name = label(ref.name, size: 12)
        name.toolTip = ref.name
        let detail = ref.isCurrent ? "Current" : ref.isDefault ? "Default" : ref.isRemote ? "Remote" : ref.worktreePath == nil ? "" : "Worktree"
        let badge = label(detail, size: 10, color: WorkspaceStyle.muted)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let cell = row([icon, name, NSView(), badge], spacing: 7)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { render() }

    @objc private func doubleClick() { applySelection() }

    private func applySelection() {
        guard apply.isEnabled else { return }
        if mode.selectsBase {
            let revision = selected?.name ?? query
            workspace.setDraftCheckout(.newWorktree(base: revision))
            closeSheet()
        } else if let selected {
            run { try await self.workspace.checkout(selected, in: self.target) }
        }
    }

    private func confirmCreate() {
        guard create.isEnabled, let window else { return }
        let branch = query
        let alert = NSAlert()
        alert.messageText = "Create \(branch)?"
        alert.informativeText = "Create the branch from the current checkout and switch to it."
        alert.addButton(withTitle: "Create and Switch")
        alert.addButton(withTitle: "Cancel")
        confirming = true
        render()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            confirming = false
            render()
            if response == .alertFirstButtonReturn { run { try await self.workspace.createBranch(branch, in: self.target) } }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        loading?.cancel()
        operation = Task {
            do {
                try await action()
                operation = nil
                closeSheet()
            } catch {
                operation = nil
                setNote(error.localizedDescription, error: true)
                render()
            }
        }
        setNote("Updating checkout…")
        render()
    }

    private func closeSheet() {
        guard operation == nil, let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
