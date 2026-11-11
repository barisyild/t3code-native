import AppKit

@MainActor
final class ProjectOnboardingController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode: Int { case folder, create, clone }
    private enum Submission: Equatable {
        case folder(path: String, createIfMissing: Bool)
        case named(String)
        case clone(remote: String, destination: String, transport: String)
    }

    private let workspace: Workspace
    private let environmentID: String
    private let environmentName: String
    private let currentProjectRoot: String?
    private let modes = NSSegmentedControl(labels: ["Open Folder", "New Project", "Clone Git"], trackingMode: .selectOne, target: nil, action: nil)
    private let folder = NSTextField()
    private let name = NSTextField()
    private let repository = NSTextField()
    private let destination = NSTextField()
    private let source = NSPopUpButton()
    private let transport = NSPopUpButton()
    private let createFolder = NSButton(checkboxWithTitle: "Create folder if missing", target: nil, action: nil)
    private let folderTable = NSTableView()
    private let currentDirectory = label(size: 11.5, color: WorkspaceStyle.secondary)
    private let managedRoot = label(size: 12, color: WorkspaceStyle.secondary)
    private let resolvedRepository = label(size: 11.5, color: WorkspaceStyle.secondary)
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var primary = ActionButton("Open Folder", style: .subtle) { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel", style: .subtle) { [weak self] in self?.backOrClose() }
    private lazy var browse = ActionButton("Browse on Host…", style: .subtle) { [weak self] in self?.openBrowser() }
    private lazy var browseDestination = ActionButton("Browse on Host…", style: .subtle) { [weak self] in self?.openBrowser() }
    private lazy var chooseLocal = ActionButton("Choose Folder…", style: .subtle) { [weak self] in self?.chooseWithFinder() }
    private lazy var parent = ActionButton("Parent Folder", symbol: "chevron.up", iconOnly: true, style: .subtle) { [weak self] in self?.browseParent() }
    private var folderView: NSView?
    private var nameView: NSView?
    private var cloneView: NSView?
    private var transportRow: NSView?
    private var browserView: NSView?
    private var listing: ProjectFolderListing?
    private var browsing = false
    private var destinationEdited = false
    private var resolved: CloneRepository?
    private var discovery: Task<Void, Never>?
    private var discoveryScope: ProjectOnboardingScope?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var canInterrupt = false
    private var submission: (Submission, ProjectAddAttempt)?
    var onClose: (() -> Void)?
    var onAdded: ((String?) -> Void)?

    init(workspace: Workspace, scope: ProjectOnboardingScope, initialFolder: String? = nil) {
        self.workspace = workspace
        environmentID = scope.environmentID
        environmentName = workspace.environment?.name ?? "Environment"
        currentProjectRoot = workspace.selectedProject?.root
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 268),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Add Project"
        window.isReleasedWhenClosed = false
        configure(initialFolder: initialFolder)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var scope: ProjectOnboardingScope? {
        guard let scope = workspace.projectOnboardingScope, scope.environmentID == environmentID else { return nil }
        return scope
    }
    private var mode: Mode { Mode(rawValue: modes.selectedSegment) ?? .folder }
    private var platform: String? { workspace.environmentPlatform }
    private var provider: String? { source.selectedItem?.representedObject as? String }
    private var protocolName: String { transport.selectedItem?.representedObject as? String ?? "https" }
    private var cloneURL: String? {
        if provider != nil { return protocolName == "ssh" ? resolved?.ssh : resolved?.https }
        let address = CloneAddress.normalized(repository.stringValue)
        return address.isEmpty ? nil : address
    }
    private var canClone: Bool { workspace.can("orchestration:operate") && workspace.can("source-control:write") }
    private var canUseFinder: Bool {
        workspace.environment?.isLocal == true && (platform == nil || platform == "unknown" || platform == "darwin")
    }
    private var selectedFolder: ProjectFolderListing.Entry? {
        guard let listing, listing.entries.indices.contains(folderTable.selectedRow) else { return nil }
        return listing.entries[folderTable.selectedRow]
    }

    func present(in parentWindow: NSWindow) {
        guard let window, parentWindow.attachedSheet == nil else { return }
        parentWindow.beginSheet(window) { [weak self] _ in self?.onClose?() }
        focusInput()
    }

    func sync() {
        if scope != nil, workspace.can("orchestration:operate"),
           ["Reconnect to \(environmentName) to add a project.", "This connection cannot add projects."].contains(message.stringValue) {
            setMessage("")
        }
        if mode == .clone, task == nil { discoverProviders(); suggestDestination() }
        render()
    }

    private func configure(initialFolder: String?) {
        modes.selectedSegment = Mode.folder.rawValue
        modes.target = self
        modes.action = #selector(changeOnboardingMode)
        modes.setAccessibilityLabel("Add Project Mode")
        folder.stringValue = initialFolder ?? ""
        folder.placeholderString = "~/projects/example"
        name.placeholderString = "Project name"
        repository.placeholderString = "https://github.com/owner/repository.git"
        destination.placeholderString = "~/projects/repository"
        folder.setAccessibilityLabel("Folder")
        name.setAccessibilityLabel("Name")
        repository.setAccessibilityLabel("Repository")
        destination.setAccessibilityLabel("Destination")
        for field in [folder, destination, managedRoot, currentDirectory] {
            field.cell?.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingMiddle
        }
        for field in [folder, name, repository, destination] { field.delegate = self }
        for picker in [source, transport] {
            picker.isBordered = false
            picker.font = .systemFont(ofSize: 12.5, weight: .medium)
            picker.target = self
        }
        source.addItem(withTitle: "Clone URL")
        source.action = #selector(changeCloneSource)
        source.setAccessibilityLabel("Clone Source")
        for (title, value) in [("HTTPS", "https"), ("SSH", "ssh")] {
            transport.addItem(withTitle: title)
            transport.lastItem?.representedObject = value
        }
        transport.action = #selector(changeTransport)
        transport.setAccessibilityLabel("Clone Transport")

        let body = NSView()
        let folderView = column([
            field("Folder", row([folder, browse])), row([createFolder, NSView(), chooseLocal]), NSView(),
        ], spacing: 12, alignment: .width)
        let nameView = column([field("Name", name), field("Location", managedRoot), NSView()], spacing: 12, alignment: .width)
        let transportRow = field("Transport", row([transport, resolvedRepository, NSView()]))
        let cloneView = column([
            field("Repository", row([source, repository])), transportRow,
            field("Destination", row([destination, browseDestination])), NSView(),
        ], spacing: 12, alignment: .width)
        let tableColumn = NSTableColumn(identifier: .init("folder"))
        tableColumn.resizingMask = .autoresizingMask
        folderTable.addTableColumn(tableColumn)
        folderTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        folderTable.headerView = nil
        folderTable.rowHeight = 24
        folderTable.dataSource = self
        folderTable.delegate = self
        folderTable.target = self
        folderTable.doubleAction = #selector(browseSelectedFolder)
        folderTable.backgroundColor = .clear
        folderTable.setAccessibilityLabel("Host Folders")
        let folders = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 8)
        fill(scroller(for: folderTable), in: folders, inset: 3)
        let browserView = column([row([parent, currentDirectory, NSView()]), folders], spacing: 8, alignment: .width)
        self.folderView = folderView
        self.nameView = nameView
        self.cloneView = cloneView
        self.browserView = browserView
        self.transportRow = transportRow
        for pane in [folderView, nameView, cloneView, browserView] { fill(pane, in: body) }
        message.font = .systemFont(ofSize: 11.5)
        message.maximumNumberOfLines = 3
        message.isHidden = true
        primary.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let title = row([label("Add Project", size: 16, weight: .semibold), NSView(),
                         label(environmentName, size: 12, color: WorkspaceStyle.secondary)])
        let content = Surface(WorkspaceStyle.navigation)
        fill(column([title, modes, body, message, row([NSView(), cancel, primary])], spacing: 14, alignment: .width), in: content, inset: 18)
        window?.contentView = content
    }

    private func field(_ title: String, _ value: NSView) -> NSStackView {
        let caption = label(title, size: 12, color: WorkspaceStyle.secondary)
        caption.widthAnchor.constraint(equalToConstant: 83).isActive = true
        return row([caption, value], spacing: 10)
    }

    private func render() {
        let idle = task == nil
        let available = scope != nil && workspace.can("orchestration:operate")
        let lookingUp = mode == .clone && provider != nil && resolved == nil
        modes.isHidden = browsing
        modes.isEnabled = idle
        modes.setEnabled(workspace.newProjectsRoot != nil, forSegment: Mode.create.rawValue)
        modes.setEnabled(canClone, forSegment: Mode.clone.rawValue)
        folderView?.isHidden = browsing || mode != .folder
        nameView?.isHidden = browsing || mode != .create
        cloneView?.isHidden = browsing || mode != .clone
        browserView?.isHidden = !browsing
        transportRow?.isHidden = provider == nil
        resolvedRepository.stringValue = resolved?.name ?? ""
        source.isHidden = source.numberOfItems == 1
        managedRoot.stringValue = workspace.newProjectsRoot ?? "Unavailable"
        managedRoot.toolTip = workspace.newProjectsRoot
        folder.toolTip = folder.stringValue
        destination.toolTip = destination.stringValue
        chooseLocal.isHidden = !canUseFinder
        for control in [folder, name, repository, destination, source, transport, createFolder] { control.isEnabled = idle && available }
        let canBrowse = idle && available && workspace.can("filesystem:read")
        browse.isEnabled = canBrowse
        browseDestination.isEnabled = canBrowse
        chooseLocal.isEnabled = idle && available && canUseFinder
        folderTable.isEnabled = idle
        parent.isEnabled = canBrowse && listing.flatMap { ProjectHostPath.parent(of: $0.directory, platform: platform) } != nil
        cancel.isEnabled = idle || canInterrupt
        cancel.title = browsing ? "Back" : "Cancel"
        if browsing {
            primary.title = selectedFolder == nil ? "Use This Folder" : "Use Selected Folder"
            primary.isEnabled = canBrowse && listing != nil
        } else {
            switch mode {
            case .folder:
                primary.title = "Open Folder"
                primary.isEnabled = idle && available && !trim(folder.stringValue).isEmpty
            case .create:
                primary.title = "Create Project"
                primary.isEnabled = idle && available && workspace.newProjectsRoot != nil && !trim(name.stringValue).isEmpty
            case .clone:
                primary.title = lookingUp ? "Look Up Repository" : "Clone Repository"
                primary.isEnabled = idle && available && canClone && !trim(repository.stringValue).isEmpty &&
                    (lookingUp || (cloneURL != nil && !trim(destination.stringValue).isEmpty))
            }
        }
        primary.setAccessibilityLabel(primary.title)
        cancel.setAccessibilityLabel(cancel.title)
        if !available, idle {
            setMessage(scope == nil ? "Reconnect to \(environmentName) to add a project." : "This connection cannot add projects.")
        }
        resizeForContent()
    }

    private func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func focusInput() {
        let field = mode == .folder ? folder : mode == .create ? name : repository
        window?.makeFirstResponder(field)
    }

    @objc private func changeOnboardingMode() {
        setMessage("")
        if mode == .clone { discoverProviders() }
        render()
        focusInput()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === repository { resolved = nil; suggestDestination() }
        if notification.object as? NSTextField === destination { destinationEdited = true }
        setMessage("")
        render()
    }

    @objc private func changeCloneSource() {
        resolved = nil
        repository.placeholderString = provider == nil ? "https://github.com/owner/repository.git" : "owner/repository"
        transport.selectItem(at: ["github", "forgejo", "cursorOrigin"].contains(provider) ? 0 : 1)
        suggestDestination()
        setMessage("")
        render()
    }

    @objc private func changeTransport() { suggestDestination(); render() }

    private func discoverProviders() {
        guard let scope, discoveryScope != scope else { return }
        discovery?.cancel()
        discoveryScope = scope
        discovery = Task { [weak self, workspace] in
            guard let providers = try? await workspace.cloneProviders(scope: scope),
                  !Task.isCancelled, let self, self.scope == scope else { return }
            let selection = self.provider
            source.removeAllItems()
            source.addItem(withTitle: "Clone URL")
            for provider in providers {
                let item = NSMenuItem(title: provider.title, action: nil, keyEquivalent: "")
                item.representedObject = provider.id
                source.menu?.addItem(item)
            }
            source.select(source.itemArray.first { $0.representedObject as? String == selection } ?? source.item(at: 0))
            render()
        }
    }

    private var suggestedCloneDirectory: String? {
        guard let url = cloneURL else { return nil }
        return CloneAddress.directory(url, ghq: workspace.projectOnboardingSettings.ghqLayout)
    }

    private func suggestDestination() {
        guard !destinationEdited else { return }
        destination.stringValue = suggestedCloneDirectory.map {
            ProjectHostPath.append($0, to: workspace.projectOnboardingSettings.baseDirectory, platform: platform)
        } ?? ""
    }

    private func submit() {
        guard primary.isEnabled else { return }
        if browsing {
            if let path = selectedFolder?.path ?? listing?.directory { useFolder(path) }
            return
        }
        do {
            switch mode {
            case .folder:
                let path = try ProjectHostPath.resolve(folder.stringValue, cwd: currentProjectRoot, platform: platform)
                submit(.folder(path: path, createIfMissing: createFolder.state == .on))
            case .create:
                let projectName = trim(name.stringValue)
                guard projectName.utf16.count <= 200 else { throw ClientError.message("Use a project name up to 200 characters.") }
                submit(.named(projectName))
            case .clone:
                if let provider, resolved == nil {
                    let reference = trim(repository.stringValue)
                    run("Looking up repository…", interruptible: true) { scope in
                        self.resolved = try await self.workspace.lookupCloneRepository(reference, provider: provider, scope: scope)
                        self.suggestDestination()
                        self.setMessage("")
                    }
                    return
                }
                guard let remote = cloneURL else { return }
                let path = try ProjectHostPath.resolve(destination.stringValue, cwd: currentProjectRoot, platform: platform)
                submit(.clone(remote: remote, destination: path, transport: provider == nil ? "auto" : protocolName))
            }
        } catch { setMessage(error.localizedDescription, error: true) }
    }

    private func submit(_ input: Submission) {
        let attempt = submission.flatMap { $0.0 == input ? $0.1 : nil } ?? ProjectAddAttempt()
        submission = (input, attempt)
        switch input {
        case .folder(let path, let create):
            let title = ProjectHostPath.folderName(path, platform: platform)
            run("Opening project folder…") { scope in
                try await self.workspace.addProject(path, name: title, scope: scope, attempt: attempt, createIfMissing: create)
                self.finish()
            }
        case .named(let name):
            run("Creating project…") { scope in
                let warning = try await self.workspace.createProject(name: name, scope: scope)
                self.finish(warning: warning)
            }
        case .clone(let remote, let path, let transport):
            let title = ProjectHostPath.folderName(path, platform: platform)
            let tracked = workspace.supportsProjectCloneTracking
            run(tracked ? "Starting clone…" : "Cloning repository…", interruptible: !tracked) { scope in
                try await self.workspace.startProjectClone(remote: remote, destination: path, title: title,
                                                           transport: transport, scope: scope, attempt: attempt)
                self.finish()
            }
        }
    }

    private func initialBrowserDirectory() -> String {
        let value = mode == .clone ? destination.stringValue : folder.stringValue
        guard !trim(value).isEmpty,
              let path = try? ProjectHostPath.resolve(value, cwd: currentProjectRoot, platform: platform) else {
            return workspace.projectOnboardingSettings.baseDirectory
        }
        return mode == .clone ? ProjectHostPath.parent(of: path, platform: platform) ?? path : path
    }

    private func openBrowser() {
        browsing = true
        loadFolders(initialBrowserDirectory())
    }

    private func loadFolders(_ path: String) {
        let query = ProjectHostPath.browseDirectory(path, platform: platform)
        run("Loading folders…", interruptible: true) { scope in
            let listing = try await self.workspace.browseProjectFolders(query, cwd: self.currentProjectRoot, scope: scope)
            self.listing = listing
            self.currentDirectory.stringValue = listing.directory
            self.currentDirectory.toolTip = listing.directory
            self.folderTable.deselectAll(nil)
            self.folderTable.reloadData()
            self.setMessage("")
        }
    }

    private func browseParent() {
        guard let listing, let path = ProjectHostPath.parent(of: listing.directory, platform: platform) else { return }
        loadFolders(path)
    }

    @objc private func browseSelectedFolder() {
        if let path = selectedFolder?.path { loadFolders(path) }
    }

    private func useFolder(_ path: String) {
        if mode == .clone {
            let leaf = suggestedCloneDirectory
            let name = ProjectHostPath.folderName(path, platform: platform)
            let suggestedName = leaf.flatMap { $0.split(separator: "/").last.map(String.init) }
            let same = suggestedName.map { platform == "windows" ? $0.caseInsensitiveCompare(name) == .orderedSame : $0 == name } ?? false
            destination.stringValue = same ? path : leaf.map { ProjectHostPath.append($0, to: path, platform: platform) } ?? path
            destinationEdited = true
        } else { folder.stringValue = path }
        browsing = false
        listing = nil
        setMessage("")
        render()
    }

    private func chooseWithFinder() {
        guard let window, let scope, canUseFinder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project Folder"
        let path = (initialBrowserDirectory() as NSString).expandingTildeInPath
        if path.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, self.scope == scope, result == .OK, let path = panel.url?.path else { return }
            self.useFolder(path)
            self.submit()
        }
    }

    private func backOrClose() {
        guard task == nil || canInterrupt else { return }
        task?.cancel()
        task = nil
        operationID = nil
        if browsing {
            browsing = false
            listing = nil
            setMessage("")
            render()
            focusInput()
        } else {
            discovery?.cancel()
            if let window { window.sheetParent?.endSheet(window) }
        }
    }

    private func finish(warning: String? = nil) {
        guard !Task.isCancelled else { return }
        discovery?.cancel()
        if let window { window.sheetParent?.endSheet(window) }
        onAdded?(warning)
    }

    private func run(_ status: String, interruptible: Bool = false,
                     operation: @escaping @MainActor (ProjectOnboardingScope) async throws -> Void) {
        guard task == nil, let scope else { return }
        let id = UUID()
        operationID = id
        canInterrupt = interruptible
        setMessage(status)
        task = Task {
            do { try await operation(scope) }
            catch { if operationID == id, !Task.isCancelled { setMessage(error.localizedDescription, error: true) } }
            if operationID == id {
                task = nil
                operationID = nil
                render()
            }
        }
        render()
    }

    private func setMessage(_ text: String, error: Bool = false) {
        message.stringValue = text
        message.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
        message.isHidden = text.isEmpty
        resizeForContent()
    }

    private func resizeForContent() {
        let height: CGFloat = browsing ? 380 : message.isHidden ? 268 : 308
        guard let window, let content = window.contentView, abs(content.bounds.height - height) > 1 else { return }
        window.setContentSize(NSSize(width: 610, height: height))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listing?.entries.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { render() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let listing else { return nil }
        let entry = listing.entries[index]
        let name = label(entry.name, size: 12)
        name.toolTip = entry.path
        return row([WorkspaceStyle.icon("folder", size: 12), name, NSView()], spacing: 8)
    }
}
