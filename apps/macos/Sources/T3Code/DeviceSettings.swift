import AppKit

@MainActor
final class DeviceSettingsController: NSViewController {
    private struct SourceRow: Equatable {
        let configuration: DeviceHostConfiguration?
        let host: DeviceHost?
        let status: DeviceState.HostStatus?
        let unavailable: Bool

        var name: String { configuration?.name ?? host?.name ?? "This machine" }
    }

    private struct SourceList: Equatable {
        let rows: [SourceRow]
        let canEdit: Bool
        let canRetry: Bool
        let canUpdate: Bool
    }

    private let workspace: Workspace
    private let environment = label(size: 12, color: WorkspaceStyle.muted)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let hub = NSSwitch()
    private let agent = NSSwitch()
    private let simlock = NSSwitch()
    private let document = DeviceSettingsDocument()
    private let sources = NSView()
    private lazy var simlockRow = settingRow("Simlock Hosts", control: simlock)
    private lazy var refresh = ActionButton("Check Versions", symbol: "arrow.clockwise", style: .subtle) {
        [weak self] in self?.checkVersions()
    }
    private lazy var add = ActionButton("Add Host…", symbol: "plus", style: .subtle) { [weak self] in self?.showAddMenu() }
    private var connection: UUID?
    private var state: DeviceState?
    private var presented = false
    private var subscription: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var status: String?
    private var failed = false
    private var list: SourceList?
    private var editor: DeviceHostEditor?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        let title = label("Devices", size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        notice.font = .systemFont(ofSize: 11.5)
        notice.maximumNumberOfLines = 3
        hub.target = self
        hub.action = #selector(changeHub)
        agent.target = self
        agent.action = #selector(changeAgentAccess)
        simlock.target = self
        simlock.action = #selector(changeSimlock)

        let scroll = scroller(for: document)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let heading = row([column([title, environment], spacing: 3), NSView(), refresh])
        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let sourceHeading = row([label("Device Sources", size: 13, weight: .semibold, color: WorkspaceStyle.ink), NSView(), add])
        let switches = column([
            settingRow("Device Hub", control: hub),
            settingRow("Allow Agent Device Access", control: agent),
            simlockRow,
        ], spacing: 8, alignment: .width)
        fill(column([switches, sourceHeading, sources], spacing: 13, alignment: .width), in: document, inset: 1)
        fill(column([heading, divider, notice, scroll], spacing: 12, alignment: .width), in: view, inset: 20)
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
        if !presented {
            subscription?.cancel()
            subscription = nil
        }
        sync()
    }

    func sync() {
        guard isViewLoaded else { return }
        let next = workspace.can("orchestration:read") ? workspace.connectionID : nil
        if next != connection {
            subscription?.cancel()
            subscription = nil
            operation?.cancel()
            operation = nil
            operationID = nil
            connection = next
            state = nil
            status = nil
            failed = false
        }
        editor?.syncConnection()
        if presented, let next { subscribe(next) }
        render()
    }

    private func settingRow(_ title: String, control: NSSwitch) -> NSView {
        control.setAccessibilityLabel(title)
        return row([label(title, size: 12, color: WorkspaceStyle.ink), NSView(), control])
    }

    private func subscribe(_ connection: UUID) {
        guard subscription == nil else { return }
        subscription = Task { [weak self, workspace] in
            var shouldInspect = true
            do {
                try await workspace.watchDevices(connection) { frames in
                    guard let self, !Task.isCancelled, self.connection == connection, self.presented else { return }
                    for frame in frames {
                        if let state = DeviceState(frame) { self.accept(state) }
                    }
                    if shouldInspect, let state = self.state {
                        shouldInspect = false
                        if state.supportsToolInspection, self.operation == nil { self.checkVersions() }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.connection == connection else { return }
                status = error.localizedDescription
                failed = true
            }
            guard let self, !Task.isCancelled, self.connection == connection else { return }
            subscription = nil
            render()
        }
    }

    private func accept(_ next: DeviceState) {
        guard next.revision >= (state?.revision ?? -1) else { return }
        state = next
        render()
    }

    private var canConfigure: Bool {
        connection != nil && workspace.can("settings:write") && operation == nil && editor == nil
    }

    private var canOperate: Bool {
        connection != nil && workspace.can("orchestration:operate") && operation == nil && editor == nil
    }

    private var addableKinds: [DeviceHostKind] {
        guard state != nil else { return [] }
        return DeviceHostKind.configuredKinds.filter { kind in
            guard workspace.deviceHostSettings.supports(kind) else { return false }
            switch kind {
            case .ssh: return true
            case .eas: return state?.supportsEasHosts == true
            case .simlock: return state?.supportsSimlockHosts == true && workspace.deviceHostSettings.simlockEnabled
            case .local: return false
            }
        }
    }

    private func render() {
        let loaded = state != nil
        let enabled = loaded && state?.hostStatus != "disabled"
        let starting = ["starting", "installing"].contains(state?.hostStatus ?? "")
        environment.stringValue = workspace.environment?.name ?? ""
        environment.isHidden = environment.stringValue.isEmpty
        hub.state = enabled ? .on : .off
        hub.isEnabled = loaded && canConfigure && !starting
        agent.state = state?.agentAccessEnabled == true ? .on : .off
        agent.isEnabled = enabled && canConfigure && !starting
        simlock.state = workspace.deviceHostSettings.simlockEnabled ? .on : .off
        simlockRow.isHidden = state?.supportsSimlockHosts != true
        simlock.isEnabled = canConfigure && workspace.deviceHostSettings.supports(.simlock)
        refresh.isEnabled = connection != nil && operation == nil && editor == nil
        add.isEnabled = canConfigure && !addableKinds.isEmpty

        let message: String
        if connection == nil { message = "Connect an environment to manage its devices." }
        else if !loaded { message = "Loading device sources…" }
        else if !workspace.can("settings:write") { message = "Settings access is required to change device sources." }
        else if starting { message = "The device hub is starting…" }
        else { message = "" }
        notice.stringValue = status ?? message
        notice.textColor = failed ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        notice.isHidden = notice.stringValue.isEmpty

        let next = SourceList(rows: sourceRows(), canEdit: canConfigure, canRetry: canOperate && state?.supportsHostRetry == true,
                              canUpdate: canOperate && state?.supportsToolUpdate == true)
        guard list != next else { return }
        list = next
        sources.subviews.forEach { $0.removeFromSuperview() }
        if !next.rows.isEmpty {
            fill(column(next.rows.map { sourceCard($0, list: next) }, spacing: 8, alignment: .width), in: sources)
        }
    }

    private func sourceRows() -> [SourceRow] {
        guard connection != nil else { return [] }
        let configurations = workspace.deviceHostSettings.configurations
        let configs = DeviceHostKind.configuredKinds.flatMap { kind in
            configurations.filter { $0.kind == kind }.sorted {
                ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id)
            }
        }
        let reports = state?.hosts ?? []
        let local = reports.first { $0.kind == .local }
        var result: [SourceRow] = []
        if state != nil {
            result.append(SourceRow(configuration: nil, host: local, status: state?.hostStatuses["local"], unavailable: false))
        }
        result += configs.map { config in
            .init(configuration: config,
                  host: reports.first { $0.id == config.id && $0.kind == config.kind },
                  status: state?.hostStatuses[config.id],
                  unavailable: config.kind == .simlock && !workspace.deviceHostSettings.simlockEnabled)
        }
        for host in reports where host.kind != .local &&
            !configs.contains(where: { $0.kind == host.kind && $0.id == host.id }) {
            result.append(.init(configuration: nil, host: host, status: state?.hostStatuses[host.id], unavailable: false))
        }
        return result
    }

    private func sourceCard(_ entry: SourceRow, list: SourceList) -> NSView {
        let title = label(entry.name, size: 13, weight: .semibold, color: WorkspaceStyle.ink)
        let subtitle: String
        if let config = entry.configuration {
            subtitle = config.subtitle.isEmpty ? config.kind.title : "\(config.kind.title) · \(config.subtitle)"
        } else { subtitle = entry.host?.kind == .local || entry.host == nil ? "Environment host" : entry.host?.kind.title ?? "" }
        let description = label(subtitle, size: 11.5, color: WorkspaceStyle.muted)
        description.toolTip = subtitle
        var controls: [NSView] = []
        if let config = entry.configuration {
            let edit = ActionButton("Edit…", style: .subtle) { [weak self] in self?.edit(config.kind, original: config) }
            let remove = ActionButton("Remove…", style: .subtle) { [weak self] in self?.confirmRemoval(config) }
            edit.setAccessibilityLabel("Edit \(config.name)")
            remove.setAccessibilityLabel("Remove \(config.name)")
            edit.isEnabled = list.canEdit
            remove.isEnabled = list.canEdit
            remove.contentTintColor = WorkspaceStyle.negative
            controls += [edit, remove]
        }
        if entry.status?.status == "failed", !entry.unavailable {
            let id = entry.host?.id ?? entry.configuration?.id ?? "local"
            let retry = ActionButton("Retry", style: .subtle) { [weak self] in self?.retryHost(id) }
            retry.setAccessibilityLabel("Retry \(entry.name)")
            retry.isEnabled = list.canRetry
            controls.append(retry)
        }
        var rows: [NSView] = [row([column([title, description], spacing: 3), NSView()] + controls)]
        let platforms = (entry.host?.platforms ?? []).filter(\.available).map { $0.platform.title }
        let missing = (entry.host?.platforms ?? []).filter { !$0.available }.compactMap(\.reason)
        let status: String?
        if entry.unavailable { status = "Simlock hosts are disabled." }
        else if let detail = entry.status?.detail, !detail.isEmpty { status = detail }
        else if entry.status?.status == "failed" { status = "Connection failed." }
        else if !platforms.isEmpty { status = platforms.joined(separator: " · ") }
        else { status = missing.first }
        if let status, !status.isEmpty {
            rows.append(messageLabel(status, warning: entry.status?.status == "failed"))
        }
        if let host = entry.host, host.kind == .local {
            for tool in DeviceTool.allCases {
                guard let version = host.tools[tool] else { continue }
                rows.append(toolRow(tool, version: version, canUpdate: list.canUpdate))
            }
            if let error = host.toolInspectionError { rows.append(messageLabel(error, warning: true)) }
        }
        let card = Surface(WorkspaceStyle.composer, border: WorkspaceStyle.outline, radius: 9)
        fill(column(rows, spacing: 5, alignment: .width), in: card, inset: 11)
        return card
    }

    private func messageLabel(_ text: String, warning: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = warning ? WorkspaceStyle.negative : WorkspaceStyle.secondary
        field.maximumNumberOfLines = 3
        return field
    }

    private func toolRow(_ tool: DeviceTool, version: DeviceHost.ToolVersion, canUpdate: Bool) -> NSView {
        let versions = version.installed.isEmpty ? "Not installed" : "Installed \(version.installed.joined(separator: ", "))"
        let detail = [tool.title, "Required \(version.required)", versions, version.running.map { "Running \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        let field = label(detail, size: 11.5, color: WorkspaceStyle.muted)
        field.toolTip = detail
        var views: [NSView] = [field, NSView()]
        if version.needsUpdate, state?.supportsToolUpdate == true {
            let update = ActionButton("Update", style: .subtle) { [weak self] in self?.updateTool(tool) }
            update.setAccessibilityLabel("Update \(tool.title)")
            update.isEnabled = canUpdate
            views.append(update)
        }
        return row(views)
    }

    private func showAddMenu() {
        guard canConfigure else { return }
        let menu = NSMenu()
        for kind in addableKinds {
            let item = menuItem(kind.title, target: self, action: #selector(addHost(_:)))
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height), in: add) }
    }

    @objc private func addHost(_ item: NSMenuItem) {
        guard let kind = (item.representedObject as? String).flatMap(DeviceHostKind.init(rawValue:)), addableKinds.contains(kind) else { return }
        edit(kind, original: nil)
    }

    private func edit(_ kind: DeviceHostKind, original: DeviceHostConfiguration?) {
        guard canConfigure, let connection, workspace.canEditDeviceHosts(connection, kind: kind),
              let window = view.window, window.attachedSheet == nil else { return }
        let editor = DeviceHostEditor(workspace: workspace, kind: kind, original: original, connection: connection)
        self.editor = editor
        editor.onClose = { [weak self] in self?.editor = nil; self?.render() }
        editor.present(in: window)
        render()
    }

    private func confirmRemoval(_ original: DeviceHostConfiguration) {
        guard canConfigure, let connection, let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(original.name)?"
        alert.informativeText = "The environment will disconnect this device source and remove its configuration."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Host").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn, self.connection == connection, canConfigure else { return }
            run("Removing host…") { [workspace] connection in
                try await workspace.removeDeviceHost(original, connection: connection)
                return nil
            }
        }
    }

    private func checkVersions() {
        guard let connection else { return }
        if presented { subscribe(connection) }
        run("Checking device sources…") { [workspace] connection in
            try await workspace.listDevices(connection, inspectOnly: true)
        }
    }

    private func retryHost(_ id: String) {
        guard canOperate else { return }
        run("Connecting to device host…") { [workspace] connection in
            try await workspace.listDevices(connection, inspectOnly: false, retryHost: id)
        }
    }

    private func updateTool(_ tool: DeviceTool) {
        guard canOperate else { return }
        run("Updating \(tool.title)…") { [workspace] connection in
            try await workspace.listDevices(connection, inspectOnly: false, updateTool: tool)
        }
    }

    @objc private func changeHub() {
        guard canConfigure else { render(); return }
        let enabled = hub.state == .on
        let fields: Payload = enabled ? ["enabled": .bool(true), "onboardingCompleted": .bool(true)] :
            ["enabled": .bool(false), "agentAccessEnabled": .bool(false)]
        run(enabled ? "Starting Device Hub…" : "Disabling Device Hub…") { [workspace] connection in
            try await workspace.configureDevices(connection, fields: fields)
        }
    }

    @objc private func changeAgentAccess() {
        guard canConfigure else { render(); return }
        let enabled = agent.state == .on
        run("Updating agent access…") { [workspace] connection in
            try await workspace.configureDevices(connection, fields: ["agentAccessEnabled": .bool(enabled)])
        }
    }

    @objc private func changeSimlock() {
        guard canConfigure else { render(); return }
        let enabled = simlock.state == .on
        run("Updating Simlock settings…") { [workspace] connection in
            try await workspace.setSimlockHostsEnabled(enabled, connection: connection)
            return nil
        }
    }

    private func run(_ message: String, _ action: @escaping @MainActor (UUID) async throws -> DeviceState?) {
        guard operation == nil, editor == nil, let connection else { return }
        let id = UUID()
        operationID = id
        status = message
        failed = false
        operation = Task { [weak self] in
            do {
                let value = try await action(connection)
                guard let self, self.connection == connection, operationID == id else { return }
                status = nil
                if let value { accept(value) }
            } catch {
                guard let self, self.connection == connection, operationID == id else { return }
                status = error.localizedDescription
                failed = true
            }
            guard let self, self.connection == connection, operationID == id else { return }
            operation = nil
            operationID = nil
            render()
        }
        render()
    }
}

private final class DeviceSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
