import AppKit
import CoreImage

@MainActor
final class SharingAccessSettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct IssuedLink {
        let record: AccessLink
        let address: PairingAddress
        let url: URL
    }

    private enum Record: Equatable {
        case link(AccessLink)
        case client(AccessClient)

        var id: String {
            switch self {
            case .link(let link): link.id
            case .client(let client): client.id
            }
        }

        var label: String {
            switch self {
            case .link(let link): link.label
            case .client(let client): client.label
            }
        }

        var scopes: [String] {
            switch self {
            case .link(let link): link.scopes
            case .client(let client): client.scopes
            }
        }
    }

    private let workspace: Workspace
    private let environmentLabel = label(size: 12, color: WorkspaceStyle.muted)
    private let tabs = NSSegmentedControl(labels: ["Pairing Links", "Clients"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let empty = label(size: 12, color: WorkspaceStyle.muted)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let guestLinks = NSSwitch()
    private lazy var guestLinksRow = row([
        column([label("Guest links", size: 12, weight: .medium, color: WorkspaceStyle.ink),
                label("Share a conversation over T3 Connect. Turning this off stops guest access.",
                      size: 11, color: WorkspaceStyle.muted)], spacing: 3),
        NSView(), guestLinks,
    ])
    private lazy var refresh = ActionButton("Refresh Access", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in
        self?.restart()
    }
    private lazy var create = ActionButton("Create Link…", symbol: "plus") { [weak self] in self?.createLink() }
    private lazy var copy = ActionButton("Copy Link") { [weak self] in self?.copyLink() }
    private lazy var qr = ActionButton("Show QR Code…") { [weak self] in self?.showQR() }
    private lazy var revoke = ActionButton("Revoke…") { [weak self] in self?.revokeSelected() }
    private lazy var revokeOthers = ActionButton("Revoke Other Clients…") { [weak self] in self?.revokeOtherClients() }
    private var rows: [Record] = []
    private var snapshot = SharingAccessSnapshot()
    private var issued: [String: IssuedLink] = [:]
    private var removedWhileMutating = Set<String>()
    private var connection: UUID?
    private var generation = UUID()
    private var observation: Task<Void, Never>?
    private var mutation: Task<Void, Never>?
    private var active = false
    private var rebuilding = false
    private var message: String?
    private var failed = false

    private var showsLinks: Bool { tabs.selectedSegment == 0 }
    private var selected: Record? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var canWrite: Bool { connection != nil && workspace.can("access:write") }
    private var canRead: Bool { connection != nil && workspace.can("access:read") }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        let heading = label("Sharing & access", size: 17, weight: .semibold, color: WorkspaceStyle.ink)
        let header = row([column([heading, environmentLabel], spacing: 3), NSView(), refresh, create])
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("Access Records")
        guestLinks.target = self
        guestLinks.action = #selector(changeGuestLinks)
        guestLinks.setAccessibilityLabel("Guest links")
        let tableColumn = NSTableColumn(identifier: .init("access"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.style = .inset
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let panel = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 8)
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        fill(scroller(for: table), in: panel, inset: 2)
        empty.alignment = .center
        empty.maximumNumberOfLines = 2
        empty.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            empty.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
        ])
        for field in [detail, status] {
            field.font = .systemFont(ofSize: 11.5)
            field.maximumNumberOfLines = 2
            field.setContentHuggingPriority(.required, for: .vertical)
        }
        detail.textColor = WorkspaceStyle.secondary
        let actions = row([copy, qr, NSView(), revokeOthers, revoke], spacing: 8)
        fill(column([header, tabs, panel, detail, actions, guestLinksRow, status], spacing: 10, alignment: .width), in: view, inset: 20)
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        activate()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        deactivate()
    }

    func activate() {
        guard !active else { return }
        active = true
        sync()
    }

    func deactivate() {
        active = false
        clear()
        connection = nil
        render()
    }

    func sync() {
        guard active, isViewLoaded else { return }
        if connection != workspace.connectionID { restart() }
        else { render() }
    }

    private func clear() {
        generation = UUID()
        observation?.cancel()
        observation = nil
        mutation?.cancel()
        mutation = nil
        snapshot = SharingAccessSnapshot()
        issued.removeAll()
        removedWhileMutating.removeAll()
        message = nil
        failed = false
    }

    private func restart() {
        guard active else { return }
        clear()
        connection = workspace.connectionID
        render()
        guard let connection, canRead else { return }
        let generation = generation
        observation = Task { [weak self, workspace] in
            do {
                try await workspace.subscribe("subscribeAuthAccess", [:]) { events in
                    guard let self, self.generation == generation, workspace.connectionID == connection else { return }
                    for event in events where self.snapshot.receive(event) {
                        if event["type"].string == "pairingLinkRemoved", let id = event["payload"]["id"].string {
                            self.issued.removeValue(forKey: id)
                            if self.mutation != nil { self.removedWhileMutating.insert(id) }
                        }
                    }
                    self.render()
                }
                self?.showStreamError("Access updates ended. Refresh to reconnect.", generation: generation)
            } catch {
                self?.showStreamError(error.localizedDescription, generation: generation)
            }
        }
    }

    private func showStreamError(_ error: String, generation: UUID) {
        guard !Task.isCancelled, self.generation == generation else { return }
        observation = nil
        message = error
        failed = true
        render()
    }

    private func render(select id: String? = nil) {
        guard isViewLoaded else { return }
        let previous = id ?? selected?.id
        let now = Date()
        issued = issued.filter { $0.value.record.expiresAt > now }
        let links = snapshot.links.merging(issued.mapValues(\.record)) { current, _ in current }.values.filter { $0.expiresAt > now }
        let next: [Record] = showsLinks
            ? links.sorted {
                if $0.expiresAt != $1.expiresAt { return $0.expiresAt > $1.expiresAt }
                return $0.id < $1.id
            }.map(Record.link)
            : snapshot.clients.values.sorted {
                if $0.current != $1.current { return $0.current }
                if $0.connected != $1.connected { return $0.connected }
                if $0.lastConnected != $1.lastConnected {
                    return ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast)
                }
                return $0.id < $1.id
            }.map(Record.client)
        if next != rows || id != nil {
            rebuilding = true
            if next != rows {
                rows = next
                table.reloadData()
            }
            if let previous, let index = rows.firstIndex(where: { $0.id == previous }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            rebuilding = false
        }
        environmentLabel.stringValue = workspace.environment?.name ?? "No environment selected"
        table.setAccessibilityLabel(showsLinks ? "Pairing Links" : "Authorized Clients")
        empty.isHidden = !rows.isEmpty
        empty.stringValue = {
            if connection == nil { return "Connect to an environment to manage access." }
            if canRead && snapshot.revision == nil { return observation == nil && failed ? "Access is unavailable." : "Loading access…" }
            if !canRead { return showsLinks && canWrite ? "Links created here will appear in this list." : "This connection can’t view access." }
            return showsLinks ? "No active pairing links." : "No authorized clients."
        }()
        let permitsLink = !workspace.sharingConfiguration.blocksRemoteClients
        create.isEnabled = canWrite && permitsLink && mutation == nil && !workspace.delegatablePairingScopes.isEmpty &&
            (!canRead || snapshot.revision != nil) &&
            !workspace.sharingConfiguration.addresses(for: workspace.environment?.origin).isEmpty
        refresh.isEnabled = connection != nil && mutation == nil
        let fresh = selected.flatMap { issued[$0.id] }
        copy.isHidden = !showsLinks
        copy.isEnabled = fresh != nil && mutation == nil
        qr.isHidden = fresh?.address.isLoopback != false
        qr.isEnabled = mutation == nil
        revokeOthers.isHidden = showsLinks || !canWrite
        revokeOthers.isEnabled = canWrite && mutation == nil && (!canRead || snapshot.clients.values.contains { !$0.current })
        revoke.isHidden = !canWrite
        revoke.isEnabled = canWrite && mutation == nil && selected.map {
            if case .client(let client) = $0 { return !client.current }
            return true
        } == true
        detail.stringValue = selected.map { record in
            let scopes = PairingScope.titles(record.scopes)
            return scopes.isEmpty ? "No permissions listed." : scopes
        } ?? ""
        detail.isHidden = detail.stringValue.isEmpty
        detail.toolTip = detail.stringValue
        guestLinksRow.isHidden = workspace.guestSharingEnabled == nil
        let guestLinksEnabled = workspace.guestSharingEnabled == true
        guestLinks.state = guestLinksEnabled ? .on : .off
        guestLinks.isEnabled = connection != nil && mutation == nil && workspace.can("settings:write") &&
            (guestLinksEnabled || !workspace.sharingConfiguration.blocksConnect)
        guestLinks.toolTip = workspace.sharingConfiguration.blocksConnect ? "This environment’s policy restricts T3 Connect." : nil
        status.stringValue = message ?? (!permitsLink ? "This environment’s policy restricts pairing." :
            (canRead && !canWrite ? "This connection has view-only access to these settings." : ""))
        status.textColor = failed ? WorkspaceStyle.negative : WorkspaceStyle.muted
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func changeTab() { render() }

    @objc private func changeGuestLinks() {
        guard guestLinks.isEnabled else { return }
        let enabled = guestLinks.state == .on
        update(status: "Updating guest links…") { [workspace] connection in
            try await workspace.setGuestSharingEnabled(enabled, connection: connection)
            return .null
        } completed: { [weak self] _ in self?.message = nil }
    }

    private func createLink() {
        guard create.isEnabled, let connection, let window = view.window, window.attachedSheet == nil else { return }
        let addresses = workspace.sharingConfiguration.addresses(for: workspace.environment?.origin)
        let form = PairingLinkForm(addresses: addresses, permissions: PairingPermissions(granted: workspace.delegatablePairingScopes))
        let alert = NSAlert()
        alert.messageText = "Create pairing link"
        alert.informativeText = "Pair a device with this environment using the selected address and permissions."
        alert.accessoryView = form
        let confirm = alert.addButton(withTitle: "Create Link")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = form.firstResponder
        form.onPermissionsChange = { [weak confirm] allowed in confirm?.isEnabled = allowed }
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn, self.connection == connection,
                  let address = form.address, !form.scopes.isEmpty,
                  workspace.sharingConfiguration.addresses(for: workspace.environment?.origin).contains(address) else { return }
            let label = form.labelText
            let scopes = form.scopes
            run(.createLink(label: label, scopes: scopes)) { response in
                guard let id = response["id"].string, let credential = response["credential"].string,
                      let expires = WorkspaceStyle.date(response["expiresAt"].string), expires > Date(),
                      let url = address.link(credential: credential) else { throw ClientError.invalidResponse }
                guard !self.removedWhileMutating.contains(id) else {
                    self.message = "The pairing link has already expired or been revoked."
                    return
                }
                let record = AccessLink(id: id, label: response["label"].string ?? (label.isEmpty ? "Pairing link" : label),
                                        scopes: scopes, expiresAt: expires)
                self.issued[id] = IssuedLink(record: record, address: address, url: url)
                self.tabs.selectedSegment = 0
                self.message = address.isLoopback ? "Link ready to use on this Mac." : "Pairing link ready."
                self.render(select: id)
            }
        }
    }

    private func selectedLink() -> IssuedLink? {
        guard active, workspace.connectionID == connection, canWrite, let id = selected?.id,
              let link = issued[id], link.record.expiresAt > Date() else { render(); return nil }
        return link
    }

    private func copyLink() {
        guard let link = selectedLink() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
        failed = false
        message = "Pairing link copied."
        render()
    }

    private func showQR() {
        guard let link = selectedLink(), !link.address.isLoopback, let window = view.window, window.attachedSheet == nil,
              let generator = CIFilter(name: "CIQRCodeGenerator") else { return }
        generator.setValue(Data(link.url.absoluteString.utf8), forKey: "inputMessage")
        guard let code = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)),
              let pixels = CIContext().createCGImage(code, from: code.extent) else { return }
        let image = NSImageView(image: NSImage(cgImage: pixels, size: NSSize(width: 174, height: 174)))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel("Pairing QR Code")
        let accessory = Surface(.white)
        accessory.frame.size = NSSize(width: 200, height: 200)
        fill(image, in: accessory, inset: 13)
        let alert = NSAlert()
        alert.messageText = "Scan pairing link"
        alert.informativeText = "Use another device to pair with \(link.address.origin.host() ?? "this environment")."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window)
    }

    private func revokeSelected() {
        guard revoke.isEnabled, let selected else { return }
        switch selected {
        case .link(let link):
            confirm("Revoke \(link.label)?", detail: "This link will no longer pair a device.") { [weak self] in
                guard let self else { return }
                run(.revokeLink(link.id)) { response in
                    self.issued.removeValue(forKey: link.id)
                    self.message = response["revoked"].bool == true ? "Pairing link revoked." : "The link is already inactive."
                }
            }
        case .client(let client) where !client.current:
            confirm("Revoke access for \(client.label)?", detail: "This client will need a new pairing link to reconnect.") { [weak self] in
                self?.run(.revokeClient(client.id)) { response in
                    self?.message = response["revoked"].bool == true ? "Client access revoked." : "The client session is already inactive."
                }
            }
        default: break
        }
    }

    private func revokeOtherClients() {
        guard revokeOthers.isEnabled else { return }
        confirm("Revoke other clients?", detail: "Other clients will need a new pairing link. This device will stay connected.") { [weak self] in
            self?.run(.revokeOthers) { response in
                let count = response["revokedCount"].int ?? 0
                self?.message = "Revoked \(count) \(count == 1 ? "client" : "clients")."
            }
        }
    }

    private func confirm(_ title: String, detail: String, perform: @escaping () -> Void) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let generation = generation
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Revoke").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] result in
            guard self?.generation == generation, result == .alertSecondButtonReturn else { return }
            perform()
        }
    }

    private func run(_ action: SharingAccessMutation, completed: @escaping (Wire) throws -> Void) {
        guard canWrite else { return }
        update(status: "Updating access…", operation: { [workspace] connection in
            try await workspace.mutateSharingAccess(action, connection: connection)
        }, completed: completed)
    }

    private func update(status: String, operation: @escaping (UUID) async throws -> Wire,
                        completed: @escaping (Wire) throws -> Void) {
        guard active, let connection, mutation == nil else { return }
        let generation = generation
        failed = false
        message = status
        removedWhileMutating.removeAll()
        mutation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    mutation = nil
                    removedWhileMutating.removeAll()
                    render()
                }
            }
            do {
                let response = try await operation(connection)
                guard !Task.isCancelled, self.generation == generation else { return }
                try completed(response)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                failed = true
                message = error.localizedDescription
            }
        }
        render()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let record = rows[index]
        let icon: NSImageView
        let subtitle: String
        switch record {
        case .link(let link):
            icon = WorkspaceStyle.icon("link", size: 12)
            subtitle = "Expires \(link.expiresAt.formatted(date: .abbreviated, time: .shortened))"
        case .client(let client):
            icon = WorkspaceStyle.icon("desktopcomputer", size: 12)
            if client.current { subtitle = "This device" }
            else if client.connected { subtitle = "Connected" }
            else if let last = client.lastConnected { subtitle = "Last connected \(last.formatted(date: .abbreviated, time: .shortened))" }
            else { subtitle = "Paired" }
        }
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        let title = label(record.label, size: 12, weight: .medium)
        let description = label(subtitle, size: 11, color: WorkspaceStyle.muted)
        return row([icon, column([title, description], spacing: 2), NSView()], spacing: 8)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !rebuilding { render() }
    }
}
