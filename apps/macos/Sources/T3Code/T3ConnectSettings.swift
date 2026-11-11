import AppKit
import AuthenticationServices

@MainActor
final class T3ConnectSettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let account: T3ConnectAccount?
    private let relay: ManagedRelayClient?
    private let identityLabel = label(size: 12, color: WorkspaceStyle.secondary)
    private let state = NSTextField(wrappingLabelWithString: "")
    private let list = NSTableView()
    private let listTitle = label("Linked environments", size: 12, weight: .medium, color: WorkspaceStyle.ink)
    private lazy var host = T3ConnectHostView(workspace: workspace, account: account, relay: relay)
    private lazy var signIn = ActionButton("Sign In…", symbol: "person.crop.circle") { [weak self] in self?.beginSignIn() }
    private lazy var signOut = ActionButton("Sign Out", style: .subtle) { [weak self] in self?.endSignIn() }
    private lazy var refresh = ActionButton("Refresh Environments", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in
        self?.host.refresh()
        self?.loadEnvironments()
    }
    private lazy var connect = ActionButton("Connect", symbol: "arrow.right.circle", style: .subtle) { [weak self] in self?.connectSelected() }
    private var rows: [SavedEnvironment] = []
    private var listPanel: NSView?
    private var operation: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var routeStatus: (route: RelayRoute, status: String)?
    private var operationText: String?
    private var errorText: String?
    private var listedAccount: String?
    private var rebuilding = false
    private var visible = false

    private var selected: SavedEnvironment? { rows.indices.contains(list.selectedRow) ? rows[list.selectedRow] : nil }

    init(workspace: Workspace, account: T3ConnectAccount?, relay: ManagedRelayClient?) {
        self.workspace = workspace
        self.account = account
        self.relay = relay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        let heading = label("T3 Connect", size: 17, weight: .semibold, color: WorkspaceStyle.ink)
        let header = row([column([heading, identityLabel], spacing: 3), NSView(), refresh, signOut])
        host.onLinkChange = { [weak self] in
            guard let self, visible, account?.identity != nil else { return }
            loadEnvironments()
        }
        list.addTableColumn(NSTableColumn(identifier: .init("environment")))
        list.headerView = nil
        list.rowHeight = 34
        list.backgroundColor = .clear
        list.style = .inset
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(openEnvironment)
        list.setAccessibilityLabel("T3 Connect Environments")
        let panel = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 8)
        fill(scroller(for: list), in: panel, inset: 2)
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
        listPanel = panel
        state.font = .systemFont(ofSize: 12)
        state.maximumNumberOfLines = 3
        state.setContentHuggingPriority(.required, for: .vertical)
        let actions = row([signIn, NSView(), connect])
        let stack = column([header, host, listTitle, panel, state, actions], spacing: 10, alignment: .width)
        fill(stack, in: view, inset: 20)
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        setPresented(true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        setPresented(false)
    }

    func setPresented(_ value: Bool) {
        guard visible != value else { return }
        let _ = view
        visible = value
        host.setPresented(value)
        if value {
            if let account {
                run("Loading T3 Connect…") {
                    await account.restore()
                    try await self.readEnvironments()
                }
            }
            render()
        } else {
            statusTask?.cancel()
            statusTask = nil
        }
    }

    func accountDidChange() {
        guard isViewLoaded else { return }
        if listedAccount != account?.identity?.id {
            listedAccount = nil
            rows = []
            routeStatus = nil
            reloadRows()
            if visible && operation == nil && account?.identity != nil { loadEnvironments() }
        }
        render()
    }

    func render() {
        guard isViewLoaded else { return }
        let signedIn = account?.identity != nil
        let active = selected?.id == workspace.environment?.id && workspace.connection == .ready
        identityLabel.stringValue = account?.identity?.label ?? "Account"
        signIn.isHidden = signedIn
        signIn.isEnabled = account != nil && operation == nil
        signOut.isHidden = !signedIn
        signOut.isEnabled = operation == nil
        refresh.isHidden = !signedIn
        refresh.isEnabled = operation == nil
        connect.isHidden = !signedIn || rows.isEmpty
        connect.isEnabled = signedIn && selected != nil && operation == nil && !active &&
            !(selected?.id == workspace.environment?.id && workspace.connection == .connecting)
        listPanel?.isHidden = !signedIn
        listTitle.isHidden = !signedIn
        host.sync()
        var detail: String?
        if let selected, selected.id == workspace.environment?.id {
            switch workspace.connection {
            case .ready: detail = "Connected to \(selected.name)."
            case .connecting: detail = "Connecting to \(selected.name)…"
            case .retrying, .needsPairing: detail = workspace.connectionError
            case .offline: break
            }
        }
        if detail == nil, let routeStatus, routeStatus.route == selected?.relay {
            detail = routeStatus.status == "online" ? "Environment online" : "Environment offline"
        }
        state.stringValue = errorText ?? operationText ?? detail ?? {
            if account == nil { return "T3 Connect is unavailable in this build." }
            if !signedIn { return "Sign in in your browser to see your environments." }
            return rows.isEmpty ? "No linked environments." : "Choose an environment to connect."
        }()
        state.textColor = errorText == nil ? WorkspaceStyle.muted : WorkspaceStyle.negative
        state.toolTip = state.stringValue
    }

    private func beginSignIn() {
        guard let account else { return }
        run("Waiting for browser sign-in…") {
            try await account.signIn()
            try await self.readEnvironments()
        }
    }

    private func endSignIn() {
        guard let account else { return }
        run("Signing out…") { try await account.signOut() }
    }

    private func loadEnvironments() {
        run("Loading linked environments…") { try await self.readEnvironments() }
    }

    private func readEnvironments() async throws {
        guard let account, let relay, let id = account.identity?.id else { return }
        let previous = selected?.id ?? workspace.environment?.id
        let environments = try await relay.environments(accountID: id)
        guard account.identity?.id == id else { return }
        listedAccount = id
        rows = environments
        reloadRows(selectedID: previous)
        readStatus()
    }

    private func run(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        errorText = nil
        operationText = message
        operation = Task {
            defer { operation = nil; operationText = nil; render() }
            do { try await action() }
            catch where (error as NSError).domain == ASWebAuthenticationSessionError.errorDomain &&
                (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue { }
            catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
        render()
    }

    private func readStatus() {
        statusTask?.cancel()
        statusTask = nil
        routeStatus = nil
        guard visible, let relay, let route = selected?.relay else { return }
        statusTask = Task {
            let status = try? await relay.status(route)
            guard !Task.isCancelled, selected?.relay == route, let status else { return }
            routeStatus = (route, status)
            render()
        }
    }

    private func reloadRows(selectedID: String? = nil) {
        rebuilding = true
        list.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) ?? (rows.isEmpty ? nil : 0) {
            list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { list.deselectAll(nil) }
        rebuilding = false
    }

    private func connectSelected() {
        guard connect.isEnabled, let selected, selected.relay?.accountID == account?.identity?.id else { return }
        errorText = nil
        workspace.connect(to: selected)
        render()
    }

    @objc private func openEnvironment() { connectSelected() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let environment = rows[index]
        let icon = WorkspaceStyle.icon("desktopcomputer", size: 13)
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        let title = label(environment.name, size: 12.5, weight: .medium)
        let host = label(environment.origin.host() ?? "", size: 10.5, color: WorkspaceStyle.muted)
        return row([icon, column([title, host], spacing: 1), NSView()], spacing: 7)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding else { return }
        readStatus()
        render()
    }
}
