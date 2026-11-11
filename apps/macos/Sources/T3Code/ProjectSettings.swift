import AppKit

@MainActor
final class ProjectSettingsController: NSViewController {
    private let workspace: Workspace
    private let projects = NSPopUpButton()
    private let projectName = label()
    private let folder = label(size: 12, color: WorkspaceStyle.secondary)
    private let modelMode = NSPopUpButton()
    private let modelPicker = ComposerModelPicker()
    private let checkout = NSPopUpButton()
    private let autoPull = NSPopUpButton()
    private lazy var pinned = ActionButton("Pin Project", style: .subtle) { [weak self] in self?.changePin() }
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var add = ActionButton("Add Project…", symbol: "plus", style: .subtle) { [weak self] in self?.onAdd?() }
    private lazy var rename = ActionButton("Rename…", style: .subtle) { [weak self] in self?.renameProject() }
    private lazy var copy = ActionButton("Copy Project Path", symbol: "document.on.document", iconOnly: true, style: .subtle) { [weak self] in
        guard let self, let project else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.root, forType: .string)
    }
    private lazy var archive = ActionButton("Archive Project", symbol: "archivebox", style: .subtle) { [weak self] in self?.toggleArchive() }
    private lazy var remove = ActionButton("Remove Project…", style: .subtle) { [weak self] in self?.confirmRemoval() }
    private lazy var manageActions = ActionButton("Project Actions…", symbol: "play", style: .subtle) { [weak self] in self?.openActions() }
    private var actionsSheet: ProjectActionsController?
    private var form: NSView?
    private var environmentID: String?
    private var listedProjects: [Project] = []
    private var selectedID: String?
    private var displayedModel: Wire = .null
    private var task: Task<Void, Never>?
    private var failure: String?
    var onAdd: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        projects.target = self
        projects.action = #selector(selectProject)
        projects.setAccessibilityLabel("Project")
        configure(modelMode, label: "Default Model Policy", action: #selector(changeModelMode), values: [
            ("inherit", "Inherit"), ("automatic", "Automatic"), ("model", "Override"),
        ])
        configure(checkout, label: "Default Workspace", action: #selector(changeCheckout), values: [
            ("inherit", "Inherit"), ("local", "Local checkout"), ("worktree", "Worktree"),
        ])
        configure(autoPull, label: "Auto-Pull", action: #selector(changeAutoPull), values: [
            ("inherit", "Inherit"), ("on", "On"), ("off", "Off"),
        ])
        checkout.toolTip = "New worktrees start from HEAD. Choose a different base in the composer."
        autoPull.toolTip = "Let the environment fast-forward a clean checkout in the background."
        pinned.imagePosition = .imageLeading
        pinned.heightAnchor.constraint(equalToConstant: 26).isActive = true
        projectName.font = .systemFont(ofSize: 13, weight: .medium)
        remove.contentTintColor = WorkspaceStyle.negative
        status.font = .systemFont(ofSize: 12)
        status.textColor = WorkspaceStyle.secondary
        status.maximumNumberOfLines = 3
        modelPicker.onPickModel = { [weak self] selection in self?.saveDefault(.model, value: selection) }
        modelPicker.onPickOption = { [weak self] id, value in
            guard let self, ComposerModels.isSelection(displayedModel) else { return }
            let catalog = ComposerModels(providers: workspace.providers)
            saveDefault(.model, value: catalog.options(for: displayedModel).setting(value, for: id))
        }

        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let form = column([
            field("Name", row([projectName, NSView(), rename])),
            field("Folder", row([folder, NSView(), copy])),
            field("Default model", row([menuControl(modelMode), modelPicker, NSView()], spacing: 8)),
            field("Default workspace", row([menuControl(checkout), NSView()])),
            field("Auto-pull", row([menuControl(autoPull), NSView()])),
            field("Pin", row([pinned, NSView()])),
            field("Actions", row([manageActions, NSView()])),
            divider,
            row([archive, NSView(), remove]),
        ], spacing: 10, alignment: .width)
        self.form = form
        let header = field("Project", row([menuControl(projects), NSView(), add]))
        fill(column([header, form, status, NSView()], spacing: 14, alignment: .width), in: view, inset: 20)
    }

    func sync(preferred id: String? = nil) {
        let _ = view
        let environment = workspace.environment?.id
        let previous = environment == environmentID ? selectedID : nil
        environmentID = environment
        let list = workspace.data.orderedProjects
        if listedProjects != list {
            listedProjects = list
            projects.removeAllItems()
            for item in list {
                let title = item.archived ? "\(item.name) · Archived" : item.name
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.representedObject = item.id
                if item.pinned, !item.archived { menuItem.image = WorkspaceStyle.symbol("pin", size: 10) }
                projects.menu?.addItem(menuItem)
            }
        }
        let next = [id, previous, workspace.selectedProject?.id, list.first?.id]
            .compactMap { $0 }.first { workspace.data.projects[$0] != nil }
        if selectedID != next || previous != selectedID {
            modelPicker.close()
            failure = nil
        }
        selectedID = next
        if let next { projects.select(projects.itemArray.first { $0.representedObject as? String == next }) }
        actionsSheet?.sync()
        render()
    }

    private var project: Project? { selectedID.flatMap { workspace.data.projects[$0] } }
    private var target: ProjectTarget? { selectedID.flatMap(workspace.projectTarget) }

    private func render() {
        add.isEnabled = workspace.can("orchestration:operate") && task == nil
        projects.isEnabled = !listedProjects.isEmpty
        form?.isHidden = project == nil
        guard let project else {
            showStatus(workspace.connection == .ready ? "Add a project to manage its settings." : "Connect an environment to manage projects.")
            return
        }
        let editable = target.map(workspace.canEditProject) == true
        let defaultsEditable = target.map(workspace.canEditProjectDefaults) == true
        let idle = task == nil
        rename.isEnabled = editable && idle
        pinned.isEnabled = editable && workspace.supportsProjectOrganization && idle
        archive.isEnabled = editable && workspace.supportsProjectOrganization && idle
        remove.isEnabled = editable && idle
        manageActions.isEnabled = target != nil && idle
        archive.title = project.archived ? "Restore Project" : "Archive Project"
        archive.setAccessibilityLabel(archive.title)
        pinned.title = project.pinned ? "Pinned in project pickers" : "Show first in project pickers"
        pinned.image = WorkspaceStyle.symbol(project.pinned ? "checkmark.circle.fill" : "circle", size: 12)
        pinned.setAccessibilityValue(project.pinned ? "On" : "Off")
        projectName.stringValue = project.name
        folder.stringValue = project.root
        folder.toolTip = project.root
        let prefs = workspace.projectPreferences
        let model = prefs.override(.model, for: project)
        select(modelMode, model.map { $0 == .null ? "automatic" : "model" } ?? "inherit")
        let catalog = ComposerModels(providers: workspace.providers)
        let configured = prefs.value(.model, for: project)
        displayedModel = catalog.initialSelection(draft: .null, fallback: configured, existingThread: false)
        modelPicker.render(catalog: catalog, selection: displayedModel, preferred: configured,
                           options: catalog.options(for: displayedModel), enabled: defaultsEditable && idle, promptEffort: false)
        modelMode.isEnabled = defaultsEditable && idle
        checkout.isEnabled = defaultsEditable && idle
        autoPull.isEnabled = defaultsEditable && idle
        select(checkout, prefs.override(.checkout, for: project)?.string ?? "inherit")
        select(autoPull, prefs.override(.autoPull, for: project)?.bool.map { $0 ? "on" : "off" } ?? "inherit")

        if let failure { showStatus(failure) }
        else if !idle { showStatus("Saving…") }
        else if target == nil { showStatus("Waiting for the environment to reconnect…") }
        else if !prefs.loaded { showStatus("Loading project defaults…") }
        else if !editable && !defaultsEditable { showStatus("This connection has read-only access to project settings.") }
        else if !defaultsEditable { showStatus("Changing defaults requires Settings write access.") }
        else { showStatus("") }
    }

    private func showStatus(_ message: String) {
        status.stringValue = message
        status.isHidden = message.isEmpty
    }

    private func field(_ title: String, _ control: NSView) -> NSStackView {
        let caption = label(title, size: 12, color: WorkspaceStyle.secondary)
        caption.widthAnchor.constraint(equalToConstant: 126).isActive = true
        return row([caption, control], spacing: 12)
    }

    private func menuControl(_ picker: NSPopUpButton) -> NSView {
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12.5)
        picker.contentTintColor = WorkspaceStyle.ink
        let surface = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 7)
        surface.heightAnchor.constraint(equalToConstant: 28).isActive = true
        fill(picker, in: surface, inset: 3)
        return surface
    }

    private func configure(_ picker: NSPopUpButton, label: String, action: Selector, values: [(String, String)]) {
        picker.target = self
        picker.action = action
        picker.setAccessibilityLabel(label)
        for (id, title) in values {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            picker.menu?.addItem(item)
        }
    }

    private func select(_ picker: NSPopUpButton, _ value: String) {
        picker.select(picker.itemArray.first { $0.representedObject as? String == value } ?? picker.item(at: 0))
    }

    @objc private func selectProject() { sync(preferred: projects.selectedItem?.representedObject as? String) }

    @objc private func changeModelMode() {
        switch modelMode.selectedItem?.representedObject as? String {
        case "inherit": saveDefault(.model, value: nil)
        case "automatic": saveDefault(.model, value: .null)
        case "model" where ComposerModels.isSelection(displayedModel): saveDefault(.model, value: displayedModel)
        default: render()
        }
    }

    @objc private func changeCheckout() {
        let value = checkout.selectedItem?.representedObject as? String
        saveDefault(.checkout, value: value == "inherit" ? nil : value.map(Wire.string))
    }

    @objc private func changeAutoPull() {
        let value = autoPull.selectedItem?.representedObject as? String
        saveDefault(.autoPull, value: value == "inherit" ? nil : .bool(value == "on"))
    }

    private func changePin() {
        guard let project, let target, workspace.canEditProject(target) else { render(); return }
        run(target) { try await $0.changeProject(target, .pin(!project.pinned)) }
    }

    private func toggleArchive() {
        guard let project, let target, workspace.canEditProject(target) else { return }
        run(target) { try await $0.changeProject(target, .archive(!project.archived)) }
    }

    private func saveDefault(_ setting: ProjectPreferences.Setting, value: Wire?) {
        guard let project, let target, workspace.canEditProjectDefaults(target),
              workspace.projectPreferences.override(setting, for: project) != value else { render(); return }
        run(target) { try await $0.setProjectDefault(setting, value: value, target: target) }
    }

    private func renameProject() {
        guard let project, let target, workspace.canEditProject(target), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename project"
        let name = NSTextField(string: project.name)
        name.setAccessibilityLabel("Project Name")
        name.frame.size = NSSize(width: 300, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Save Name")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { failure = "Enter a project name."; render(); return }
            if value != project.name { run(target) { try await $0.changeProject(target, .rename(value)) } }
        }
    }

    private func openActions() {
        guard let target, let window = view.window, window.attachedSheet == nil else { return }
        let controller = ProjectActionsController(workspace: workspace, target: target)
        actionsSheet = controller
        controller.onClose = { [weak self, weak controller] in
            if self?.actionsSheet === controller { self?.actionsSheet = nil }
        }
        controller.present(in: window)
    }

    private func confirmRemoval() {
        guard let project, let target, workspace.canEditProject(target), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(project.name)”?"
        alert.informativeText = "This permanently removes the project and its threads from T3 Code. Project files stay on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Project").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.run(target) { try await $0.removeProject(target) }
        }
    }

    private func run(_ target: ProjectTarget, action: @escaping @MainActor (Workspace) async throws -> Void) {
        guard task == nil, workspace.projectTarget(target.id) == target else { render(); return }
        failure = nil
        task = Task { [weak self, workspace] in
            do { try await action(workspace) }
            catch where self?.target == target { self?.failure = error.localizedDescription }
            catch { }
            self?.task = nil
            self?.sync()
        }
        render()
    }
}
