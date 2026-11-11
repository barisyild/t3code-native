import AppKit

@MainActor
final class ProviderSettingsController: NSViewController {
    private struct ListedProvider: Equatable {
        let id: String
        let driver: String
        let name: String
        let enabled: Bool

        init(_ provider: Provider) {
            id = provider.id
            driver = provider.driver
            name = provider.name
            enabled = provider.enabled
        }
    }

    private let workspace: Workspace
    private let setup: ProviderSetupPanel
    private let picker = NSPopUpButton()
    private let icon = NSImageView()
    private let name = label(size: 17, weight: .semibold, color: WorkspaceStyle.ink)
    private let status = label(size: 11.5, color: WorkspaceStyle.secondary)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var add = ActionButton("Add Provider", symbol: "plus", style: .subtle) { [weak self] in self?.showAddMenu() }
    private lazy var refresh = ActionButton("Refresh", symbol: "arrow.clockwise", style: .subtle) { [weak self] in self?.refreshProviders() }
    private lazy var configure = ActionButton("Configure…", style: .subtle) { [weak self] in self?.editProvider() }
    private lazy var remove = ActionButton("Remove…", style: .subtle) { [weak self] in self?.confirmRemoval() }
    private lazy var detail = column([row([icon, column([name, status], spacing: 3), NSView(), configure, remove], spacing: 10),
                                      hint, setup], spacing: 10, alignment: .width)
    private var list: [ListedProvider] = []
    private var environmentID: String?
    private var selectedID: String?
    private var pendingSelection: String?
    private var presented = false
    private var editor: ProviderInstanceEditor?
    private var task: Task<Void, Never>?
    private var failure: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        setup = ProviderSetupPanel(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
        setup.onBusyChange = { [weak self] in self?.updateButtons() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        picker.target = self
        picker.action = #selector(selectProvider)
        picker.isBordered = false
        picker.setAccessibilityLabel("Provider Instance")
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 25), icon.heightAnchor.constraint(equalToConstant: 25)])
        remove.contentTintColor = WorkspaceStyle.negative
        for message in [hint, notice] {
            message.font = .systemFont(ofSize: 11.5)
            message.maximumNumberOfLines = 3
            message.textColor = WorkspaceStyle.secondary
        }
        name.lineBreakMode = .byTruncatingTail
        status.lineBreakMode = .byTruncatingTail

        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let toolbar = row([picker, NSView(), refresh, add])
        let content = ProviderSettingsDocument()
        let scroll = scroller(for: content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        fill(column([detail, notice], spacing: 10, alignment: .width), in: content, inset: 1)
        fill(column([toolbar, divider, scroll], spacing: 14, alignment: .width), in: view, inset: 20)
        sync()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        setPresented(view.window?.isVisible == true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        setPresented(false)
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        sync()
    }

    func sync() {
        guard isViewLoaded else { return }
        if environmentID != workspace.environment?.id {
            environmentID = workspace.environment?.id
            selectedID = nil
            pendingSelection = nil
            failure = nil
        }
        let current = workspace.providers.map(ListedProvider.init)
        if current != list {
            list = current
            picker.removeAllItems()
            for provider in current {
                let title = provider.enabled ? provider.name : "\(provider.name) · Disabled"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = provider.id
                item.image = Self.icon(driver: provider.driver, size: 15)
                picker.menu?.addItem(item)
            }
            if current.isEmpty { picker.addItem(withTitle: "No providers") }
        }
        if let pendingSelection, current.contains(where: { $0.id == pendingSelection }) {
            selectedID = pendingSelection
            self.pendingSelection = nil
        }
        if !current.contains(where: { $0.id == selectedID }) {
            selectedID = current.first(where: { $0.driver == "codex" && $0.enabled })?.id ?? current.first?.id
        }
        if let selectedID { picker.select(picker.itemArray.first(where: { $0.representedObject as? String == selectedID })) }
        render()
    }

    private var provider: Provider? { workspace.providers.first { $0.id == selectedID } }
    private var target: ProviderSetupTarget? { selectedID.flatMap(workspace.providerSetupTarget) }
    private var canConfigure: Bool {
        workspace.connectionID != nil && workspace.can("providers:manage") && workspace.providerConfigurations != nil
    }

    private func updateButtons() {
        let idle = task == nil && editor == nil
        picker.isEnabled = !list.isEmpty && idle
        add.isEnabled = canConfigure && idle
        refresh.isEnabled = workspace.connectionID != nil && idle
        configure.isEnabled = canConfigure && target != nil && !setup.active && idle
        remove.isHidden = provider.map { $0.id == $0.driver || workspace.providerConfigurations?[$0.id] == nil } ?? true
        remove.isEnabled = configure.isEnabled
    }

    private func render() {
        let provider = provider
        setup.sync(provider: provider, target: target, presented: presented)
        updateButtons()
        detail.isHidden = provider == nil
        if let provider {
            let config = workspace.providerEnvelope(provider)?["config"] ?? .null
            let managed = config["setupMode"].string == "managed"
            let mode = managed ? "T3 managed" : ComposerProvider(rawValue: provider.driver) == nil ? nil : "Existing CLI"
            let availability = !provider.enabled ? "Disabled" : provider.isAvailable ? "Available" : "Unavailable"
            icon.image = Self.icon(driver: provider.driver, size: 24)
            name.stringValue = provider.name
            status.stringValue = [mode, availability].compactMap { $0 }.joined(separator: " · ")
            hint.stringValue = provider.message ?? ""
            hint.isHidden = hint.stringValue.isEmpty
        }
        let guidance: String
        if workspace.connectionID == nil { guidance = "Connect an environment to manage its providers." }
        else if workspace.providerConfigurations == nil { guidance = "Provider configuration is unavailable on this environment." }
        else if !workspace.can("providers:manage") { guidance = "This connection can view providers. An administrator can grant permission to manage them." }
        else if provider == nil { guidance = "Add a provider to choose where agents run." }
        else { guidance = "" }
        notice.stringValue = failure ?? guidance
        notice.isHidden = notice.stringValue.isEmpty
        notice.textColor = failure == nil ? WorkspaceStyle.secondary : WorkspaceStyle.negative
    }

    @objc private func selectProvider() {
        selectedID = picker.selectedItem?.representedObject as? String
        pendingSelection = nil
        failure = nil
        render()
    }

    private func showAddMenu() {
        guard canConfigure, editor == nil else { return }
        let menu = NSMenu()
        for kind in ProviderCreationKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = Self.icon(driver: kind.driver, size: 15)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 4), in: add)
    }

    @objc private func addProvider(_ item: NSMenuItem) {
        guard canConfigure, let connection = workspace.connectionID,
              let raw = item.representedObject as? String, let kind = ProviderCreationKind(rawValue: raw) else { return }
        presentEditor(.create(kind, id: kind.instanceID, connection: connection), fields: .init(name: kind.title))
    }

    private func editProvider() {
        guard canConfigure, let provider, let target, let envelope = workspace.providerEnvelope(provider), !setup.active else { return }
        presentEditor(.edit(target, driver: provider.driver, managed: envelope["config"]["setupMode"].string == "managed"),
                      fields: .init(provider: provider, envelope: envelope))
    }

    private func presentEditor(_ destination: ProviderInstanceEditor.Destination, fields: ProviderConfigurationFields) {
        guard editor == nil, let window = view.window, window.attachedSheet == nil else { return }
        let editor = ProviderInstanceEditor(workspace: workspace, destination: destination, fields: fields)
        self.editor = editor
        editor.onClose = { [weak self] in self?.editor = nil; self?.sync() }
        editor.onSaved = { [weak self] id in self?.pendingSelection = id; self?.sync() }
        editor.present(in: window)
        updateButtons()
    }

    private func refreshProviders() {
        guard let connection = workspace.connectionID, task == nil else { return }
        run {
            guard self.workspace.connectionID == connection else { throw ClientError.disconnected }
            _ = try await self.workspace.request("server.refreshProviders", ["fresh": .bool(true)])
            guard self.workspace.connectionID == connection else { return }
            self.setup.reloadStreams()
        }
    }

    private func confirmRemoval() {
        guard canConfigure, let provider, let target, provider.id != provider.driver, !setup.active,
              let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(provider.name)?"
        alert.informativeText = "T3 Code stops sessions that use this provider on the environment."
        alert.addButton(withTitle: "Remove Provider").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            self.run { try await self.workspace.removeProvider(target) }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { return }
        failure = nil
        let connection = workspace.connectionID
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; sync() }
            do { try await action() }
            catch where workspace.connectionID == connection { failure = error.localizedDescription }
            catch {}
        }
        render()
    }

    private static func icon(driver: String, size: CGFloat) -> NSImage? {
        if let family = ComposerProvider(rawValue: driver) { return WorkspaceStyle.providerIcon(family, size: size) }
        return WorkspaceStyle.symbol("cpu", size: size)
    }
}

private final class ProviderSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
