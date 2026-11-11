import AppKit

@MainActor
final class UsageHubSettingsController: NSViewController {
    private struct Entry: Equatable {
        let config: UsageHubConfiguration
        let status: String
        let warning: Bool
    }

    private let workspace: Workspace
    private let environment = label(size: 12, color: WorkspaceStyle.muted)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let document = UsageHubDocument()
    private lazy var add = ActionButton("Add Hub…", symbol: "plus", style: .subtle) { [weak self] in self?.editHub(nil) }
    private var listing: [Entry]?
    private var actionsEnabled = false
    private var connection: UUID?
    private var failure: String?
    private var editor: UsageHubEditor?
    private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        notice.font = .systemFont(ofSize: 12)
        notice.maximumNumberOfLines = 4
        let heading = column([label("CLIProxyAPI hubs", size: 16, weight: .semibold, color: WorkspaceStyle.ink), environment], spacing: 3)
        let header = row([heading, NSView(), add])
        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        fill(column([header, divider, notice, scroll], spacing: 12, alignment: .width), in: view, inset: 20)
        sync()
    }

    func sync() {
        guard isViewLoaded else { return }
        if connection != workspace.connectionID {
            connection = workspace.connectionID
            failure = nil
        }
        editor?.syncConnection()
        environment.stringValue = workspace.environment?.name ?? ""
        environment.isHidden = environment.stringValue.isEmpty
        let configurations = workspace.usageHubSettings.configurations ?? [:]
        let snapshots = workspace.usageLimitSources
        let enabled = connection != nil && workspace.canEditUsageHubs && editor == nil && task == nil
        add.isEnabled = enabled
        let entries = configurations.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
            .map { config in
                let snapshot = snapshots.first { $0.id == config.id }
                if !config.enabled { return Entry(config: config, status: "Disabled", warning: false) }
                if let problem = snapshot?.notice { return Entry(config: config, status: problem, warning: true) }
                if let count = snapshot?.accounts.count {
                    let status = count == 0 ? "No accounts reported" : count == 1 ? "1 account" : "\(count) accounts"
                    return Entry(config: config, status: status, warning: false)
                }
                return Entry(config: config, status: "Waiting for quota report", warning: false)
            }
        let message: String
        if connection == nil { message = "Connect an environment to see its quota hubs." }
        else if workspace.usageHubSettings.configurations == nil { message = "Hub settings are unavailable on this environment." }
        else if !workspace.canEditUsageHubs { message = "Provider management access is required to change hub settings." }
        else if entries.isEmpty { message = "Add a CLIProxyAPI hub to show its Codex and Claude subscription limits." }
        else { message = "" }
        notice.stringValue = failure ?? message
        notice.textColor = failure == nil ? WorkspaceStyle.secondary : WorkspaceStyle.negative
        notice.isHidden = notice.stringValue.isEmpty
        guard entries != listing || actionsEnabled != enabled else { return }
        listing = entries
        actionsEnabled = enabled
        document.subviews.forEach { $0.removeFromSuperview() }
        fill(column(entries.map(entryView), spacing: 8, alignment: .width), in: document, inset: 1)
    }

    private func entryView(_ entry: Entry) -> NSView {
        let name = label(entry.config.name, size: 13, weight: .semibold, color: WorkspaceStyle.ink)
        let address = label(entry.config.address?.value ?? "Invalid hub URL", size: 11.5, color: WorkspaceStyle.muted)
        address.toolTip = address.stringValue
        let status = NSTextField(wrappingLabelWithString: entry.status)
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = entry.warning ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        status.maximumNumberOfLines = 3
        let edit = ActionButton("Edit…", style: .subtle) { [weak self] in self?.editHub(entry.config.id) }
        let remove = ActionButton("Remove…", style: .subtle) { [weak self] in self?.confirmRemoval(entry.config.id) }
        edit.setAccessibilityLabel("Edit \(entry.config.name)")
        remove.setAccessibilityLabel("Remove \(entry.config.name)")
        edit.isEnabled = actionsEnabled
        remove.isEnabled = actionsEnabled
        remove.contentTintColor = WorkspaceStyle.negative
        let top = row([column([name, address], spacing: 3), NSView(), edit, remove])
        let card = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 9)
        fill(column([top, status], spacing: 6, alignment: .width), in: card, inset: 11)
        return card
    }

    private func editHub(_ id: String?) {
        guard workspace.canEditUsageHubs, editor == nil, task == nil,
              let connection = workspace.connectionID, let window = view.window, window.attachedSheet == nil else { return }
        let original = id.flatMap { workspace.usageHubSettings.configurations?[$0] }
        guard id == nil || original != nil else { return }
        let editor = UsageHubEditor(workspace: workspace, original: original, connection: connection)
        self.editor = editor
        editor.onClose = { [weak self] in
            self?.editor = nil
            self?.sync()
        }
        editor.present(in: window)
        sync()
    }

    private func confirmRemoval(_ id: String) {
        guard workspace.canEditUsageHubs, let connection = workspace.connectionID, editor == nil, task == nil,
              let hub = workspace.usageHubSettings.configurations?[id], let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(hub.name)?"
        alert.informativeText = "The environment will delete the saved key and stop reporting this hub’s accounts."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Hub").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn, self.workspace.connectionID == connection else { return }
            self.failure = nil
            self.task = Task { [weak self] in
                guard let self else { return }
                defer { task = nil; sync() }
                do { try await workspace.removeUsageHub(id: id, connection: connection) }
                catch where workspace.connectionID == connection { failure = error.localizedDescription }
                catch {}
            }
            self.sync()
        }
    }
}

private final class UsageHubDocument: NSView {
    override var isFlipped: Bool { true }
}
