import AppKit

@MainActor
final class RepositoryActionsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let target: RepositoryTarget
    private let table = NSTableView()
    private let listHeading = label("Working tree", size: 12, weight: .semibold)
    private let branchStatus = label(size: 12, color: WorkspaceStyle.secondary)
    private let totals = label(size: 11, color: WorkspaceStyle.muted)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var refresh = ActionButton("Refresh Status", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in
        self?.refreshStatus()
    }
    private lazy var selectAll = ActionButton("Deselect All", style: .subtle) { [weak self] in self?.toggleAll() }
    private lazy var actions = ActionButton("Actions", symbol: "chevron.down") { [weak self] in self?.showActions() }
    private lazy var commit = ActionButton("Commit…") { [weak self] in self?.start(.commit) }
    private lazy var initialize = ActionButton("Initialize Git…") { [weak self] in self?.confirmInit() }
    private lazy var viewRequest = ActionButton("Open Pull Request", symbol: "arrow.up.right", style: .subtle) { [weak self] in
        self?.openRequest()
    }
    private lazy var done = ActionButton("Done") { [weak self] in self?.closeSheet() }
    private var status = RepositoryStatus()
    private var files: [RepositoryStatus.File] = []
    private var excluded: Set<String> = []
    private var observation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var refreshing = false
    private var confirming = false
    private var createdRequestURL: String?
    var onClose: (() -> Void)?
    var onRepositoryChange: (() -> Void)?

    init(workspace: Workspace, target: RepositoryTarget) {
        self.workspace = workspace
        self.target = target
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 575, height: 404),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Source Control"
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let location = label(target.path, size: 11, color: WorkspaceStyle.muted)
        location.toolTip = target.path
        let title = column([label("Source Control", size: 16, weight: .semibold), location], spacing: 3)
        let header = row([title, NSView(), refresh])
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let branch = row([WorkspaceStyle.icon("arrow.triangle.branch", size: 13), branchStatus, NSView(), viewRequest])
        branchStatus.setAccessibilityLabel("Repository Status")
        let listHeader = row([listHeading, totals, NSView(), selectAll], spacing: 7)

        table.addTableColumn(NSTableColumn(identifier: .init("files")))
        table.headerView = nil
        table.rowHeight = 28
        table.backgroundColor = .clear
        table.style = .inset
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Changed Files")
        let list = scroller(for: table)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 125).isActive = true
        feedback.font = .systemFont(ofSize: 11.5)
        feedback.maximumNumberOfLines = 3
        feedback.setContentHuggingPriority(.required, for: .vertical)
        feedback.setContentCompressionResistancePriority(.required, for: .vertical)
        feedback.setAccessibilityLabel("Git Progress")
        let message = row([spinner, feedback, NSView()], spacing: 7)
        let footer = row([done, NSView(), initialize, actions, commit])
        done.keyEquivalent = "\u{1b}"
        fill(column([header, branch, listHeader, list, message, footer], spacing: 10, alignment: .width), in: surface, inset: 18)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.observation?.cancel()
            self?.onClose?()
        }
        observe()
    }

    private func observe() {
        guard observation == nil else { return }
        observation = Task {
            defer { observation = nil }
            do {
                try await workspace.subscribe("subscribeVcsStatus", target.input) { events in
                    guard workspace.isCurrent(target) else { return }
                    let previousBranch = status.branch
                    for event in events { status.apply(event) }
                    if previousBranch != status.branch { createdRequestURL = nil }
                    reloadFiles()
                    render()
                }
            } catch {
                guard !Task.isCancelled else { return }
                setFeedback(error.localizedDescription, error: true)
                render()
            }
        }
    }

    private func reloadFiles() {
        let updated = status.files
        guard files != updated else { return }
        files = updated
        excluded.formIntersection(Set(files.map(\.path)))
        table.reloadData()
    }

    private var isBusy: Bool { operation != nil || confirming }
    private var isWritable: Bool { workspace.canChangeRepository(target) }
    private var hasSelectedFiles: Bool { files.isEmpty || files.contains { !excluded.contains($0.path) } }
    private var canPull: Bool { status.isRepo && status.hasUpstream && status.behind > 0 }
    private var requestURL: String? { createdRequestURL ?? status.pullRequest["url"].string }
    private func canRun(_ action: RepositoryAction) -> Bool {
        action.isAvailable(status: status, hasSelectedFiles: hasSelectedFiles) &&
            (!action.createsRequest || !status.defaultRef || workspace.can("orchestration:operate"))
    }

    private func setFeedback(_ message: String, error: Bool = false) {
        feedback.stringValue = message
        feedback.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        feedback.toolTip = message
    }

    func render() {
        let current = workspace.isCurrent(target)
        if !current { branchStatus.stringValue = "Checkout disconnected" }
        else if !status.isLoaded { branchStatus.stringValue = "Reading repository status…" }
        else if !status.isRepo { branchStatus.stringValue = "No Git repository" }
        else {
            var summary = [status.branch ?? "Detached HEAD"]
            if status.defaultRef { summary.append("Default") }
            if status.ahead > 0 { summary.append("↑ \(status.ahead)") }
            if status.behind > 0 { summary.append("↓ \(status.behind)") }
            branchStatus.stringValue = summary.joined(separator: "  ·  ")
        }
        if !status.isLoaded || !status.isRepo { totals.stringValue = "" }
        else if files.isEmpty { totals.stringValue = status.hasChanges ? "Changes pending" : "Clean" }
        else { totals.stringValue = "\(files.count - excluded.count) of \(files.count) selected" }
        selectAll.title = hasSelectedFiles ? "Deselect All" : "Select All"
        selectAll.setAccessibilityLabel(selectAll.title)
        selectAll.isHidden = files.isEmpty
        selectAll.isEnabled = isWritable && !isBusy
        viewRequest.title = "Open \(status.changeRequestName)"
        viewRequest.setAccessibilityLabel(viewRequest.title)
        viewRequest.isHidden = requestURL == nil
        initialize.isHidden = !status.isLoaded || status.isRepo
        initialize.isEnabled = isWritable && !isBusy
        commit.isEnabled = isWritable && !isBusy && canRun(.commit)
        actions.isEnabled = isWritable && !isBusy && status.isRepo
        refresh.isEnabled = current && !refreshing && !isBusy
        table.isEnabled = !isBusy
        done.isEnabled = !isBusy
        if operation != nil || refreshing { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let file = files[index]
        let checked = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFile(_:)))
        checked.setAccessibilityLabel("Include \(file.path)")
        checked.identifier = .init(file.path)
        checked.state = excluded.contains(file.path) ? .off : .on
        checked.isEnabled = isWritable && !isBusy
        let path = label(file.path, size: 12)
        path.toolTip = file.path
        let plus = label("+\(file.insertions)", size: 11, color: WorkspaceStyle.positive)
        let minus = label("−\(file.deletions)", size: 11, color: WorkspaceStyle.negative)
        for counter in [plus, minus] {
            counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return row([checked, path, NSView(), plus, minus], spacing: 8)
    }

    @objc private func toggleFile(_ sender: NSButton) {
        guard !isBusy, isWritable, let path = sender.identifier?.rawValue, files.contains(where: { $0.path == path }) else { return }
        if sender.state == .on { excluded.remove(path) }
        else { excluded.insert(path) }
        render()
    }

    private func toggleAll() {
        guard !isBusy, isWritable else { return }
        excluded = hasSelectedFiles ? Set(files.map(\.path)) : []
        table.reloadData()
        render()
    }

    private func refreshStatus() {
        guard workspace.isCurrent(target), !refreshing else { return }
        refreshing = true
        render()
        Task {
            defer { refreshing = false; render() }
            do {
                _ = try await workspace.request("vcs.refreshStatus", target.input)
                guard workspace.isCurrent(target) else { return }
                observe()
                setFeedback("Repository status refreshed.")
            } catch { setFeedback(error.localizedDescription, error: true) }
        }
    }

    private func showActions() {
        guard actions.isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pull = menuItem("Pull", target: self, action: #selector(pullChanges))
        pull.isEnabled = canPull
        menu.addItem(pull)
        for action in RepositoryAction.allCases where action != .commit {
            let item = menuItem(action.title(status.changeRequestName) + "…", target: self, action: #selector(chooseAction(_:)))
            item.representedObject = action.rawValue
            item.isEnabled = canRun(action)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actions.bounds.minY), in: actions)
    }

    @objc private func chooseAction(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let action = RepositoryAction(rawValue: value) else { return }
        start(action)
    }

    private func start(_ action: RepositoryAction) {
        guard !isBusy, isWritable, canRun(action), let window else { return }
        let branch = status.branch
        let files = excluded.isEmpty ? nil : files.filter { !excluded.contains($0.path) }.map(\.path)
        let title = action.title(status.changeRequestName)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = action == .commit ? "Commit the selected changes in \(branch ?? "detached HEAD")." :
            "Run this action on \(branch ?? "the current checkout")."
        var message: NSTextField?
        if action.commits {
            let field = NSTextField()
            field.placeholderString = "Commit message (leave blank to generate)"
            field.setAccessibilityLabel("Commit Message")
            field.frame.size = NSSize(width: 360, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            message = field
        }
        let defaultBranch = status.defaultRef && action != .commit
        let needsFeature = defaultBranch && action.createsRequest
        alert.addButton(withTitle: needsFeature ? "Use a New Branch" : title)
        alert.addButton(withTitle: "Cancel")
        let offerFeature = defaultBranch && !needsFeature && action.commits && workspace.can("orchestration:operate")
        if needsFeature {
            alert.informativeText = "Create a branch from \(branch ?? "the default branch"), commit and push the changes, and open a \(status.changeRequestName.lowercased())."
        } else if defaultBranch {
            alert.informativeText = "This action will push to the default branch \(branch ?? "")."
            if offerFeature { alert.addButton(withTitle: "Use a New Branch") }
            alert.alertStyle = .warning
        }
        confirm(alert, in: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn || (offerFeature && response == .alertThirdButtonReturn) else { return }
            guard status.branch == branch else {
                setFeedback("The branch changed. Check the new status before continuing.", error: true)
                return
            }
            let text = message?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.utf16.count <= 10_000 else {
                setFeedback("The commit message can be up to 10,000 characters.", error: true)
                return
            }
            run(action, message: text, paths: files, featureBranch: needsFeature || response == .alertThirdButtonReturn)
        }
    }

    private func run(_ action: RepositoryAction, message: String, paths: [String]?, featureBranch: Bool) {
        runOperation("Starting \(action.title(status.changeRequestName))…") {
            if featureBranch && !self.workspace.can("orchestration:operate") { throw ClientError.disconnected }
            var input = self.target.input
            let actionID = UUID().uuidString
            input["actionId"] = .string(actionID)
            input["action"] = .string(action.rawValue)
            if !message.isEmpty { input["commitMessage"] = .string(message) }
            if let paths { input["filePaths"] = .array(paths.map(Wire.string)) }
            if featureBranch { input["featureBranch"] = .bool(true) }
            if let thread = self.target.threadID { input["threadId"] = .string(thread) }
            else { input["projectId"] = .string(self.target.project.id) }
            var result: Wire?
            var failure: String?
            do {
                try await self.workspace.subscribe("git.runStackedAction", input) { events in
                    for event in events where event["actionId"].string == actionID {
                        switch event["kind"].string {
                        case "phase_started": self.setFeedback(event["label"].string ?? "")
                        case "hook_started": self.setFeedback("Running \(event["hookName"].string ?? "Git hook")…")
                        case "hook_output": self.setFeedback(event["text"].string ?? "")
                        case "action_failed": failure = event["message"].string
                        case "action_finished": result = event["result"]
                        default: break
                        }
                    }
                }
            } catch {
                guard result != nil else { throw error }
                failure = error.localizedDescription
            }
            guard let result else {
                throw ClientError.message(failure ?? "The environment stopped reporting progress. Refresh the repository before retrying.")
            }
            self.createdRequestURL = result["pr"]["url"].string
            let summary = result["toast"]["title"].string ?? "Git action finished."
            var details = [summary, result["toast"]["description"].string].compactMap { $0 }
            if let name = result["branch"]["name"].string, featureBranch {
                let checkout: WorkspaceCheckout = self.target.worktreePath.map { .worktree(path: $0, branch: name) } ?? .root(branch: name)
                do { try await self.workspace.changeCheckout(checkout, in: self.target) }
                catch { failure = error.localizedDescription }
            }
            if let failure { details.append(failure) }
            self.setFeedback(details.joined(separator: "\n"), error: failure != nil)
        }
    }

    @objc private func pullChanges() {
        guard canPull else { return }
        runOperation("Pulling latest changes…") {
            let result = try await self.workspace.request("vcs.pull", self.target.input)
            self.setFeedback(result["status"].string == "pulled" ? "Pulled latest changes." : "Already up to date.")
        }
    }

    private func confirmInit() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Initialize Git?"
        alert.informativeText = "Create a Git repository in \(target.path)."
        alert.addButton(withTitle: "Initialize Git")
        alert.addButton(withTitle: "Cancel")
        confirm(alert, in: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            runOperation("Initializing Git…") {
                _ = try await self.workspace.request("vcs.init", self.target.input)
                self.setFeedback("Git repository initialized.")
            }
        }
    }

    private func confirm(_ alert: NSAlert, in window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !isBusy, window.attachedSheet == nil else { return }
        confirming = true
        render()
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.confirming = false
            self?.render()
            completion(response)
        }
    }

    private func runOperation(_ progress: String, action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        setFeedback(progress)
        operation = Task {
            defer { operation = nil; table.reloadData(); render(); onRepositoryChange?() }
            do {
                try workspace.requireRepositoryWrite(target)
                try await action()
            } catch { setFeedback(error.localizedDescription, error: true) }
        }
        table.reloadData()
        render()
    }

    private func openRequest() {
        guard let requestURL, let url = RepositoryRequestReference.webURL(requestURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func closeSheet() {
        guard !isBusy, let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
