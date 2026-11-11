import AppKit

@MainActor
final class PullRequestInboxController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private struct ProjectChoice: Equatable {
        let id: String
        let name: String
    }

    private let workspace: Workspace
    private lazy var detail = PullRequestDetailController(workspace: workspace)
    private let table = NSTableView()
    private let search = NSSearchField()
    private let projects = NSPopUpButton()
    private let states = NSPopUpButton()
    private let involvement = NSPopUpButton()
    private let environment = label(size: 11.5, color: WorkspaceStyle.muted)
    private let count = label(size: 11, color: WorkspaceStyle.muted)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let listPane = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 10)
    private lazy var back = ActionButton("Back to Workspace", symbol: "chevron.left", iconOnly: true, style: .subtle) { [weak self] in self?.onBack?() }
    private lazy var backToList = ActionButton("All Pull Requests", symbol: "chevron.left", style: .subtle) { [weak self] in self?.select(nil) }
    private lazy var refresh = ActionButton("Refresh Pull Requests", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in
        self?.loadPage(invalidate: true)
    }
    private lazy var loadMore = ActionButton("Load More", style: .subtle) { [weak self] in self?.loadPage(append: true) }
    private var listWidth: NSLayoutConstraint?
    private var listColumn: NSView?
    private var projectChoices: [ProjectChoice] = []
    private var listing = PullRequestListing()
    private var rows: [PullRequestItem] = []
    private var connection: UUID?
    private var presented = false
    private var selected: PullRequestReference?
    private var rebuilding = false
    private var loaded = false
    private var listError: String?
    private var requestID = UUID()
    private var loading: Task<Void, Never>?
    private var refreshes: Task<Void, Never>?

    var onBack: (() -> Void)?
    var onOpenThread: ((String, Bool) -> Void)?
    var onCheckout: ((PullRequestReference, String) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.canvas)
        let heading = column([label("Pull Requests", size: 20, weight: .semibold, color: WorkspaceStyle.ink), environment], spacing: 2)
        let header = row([back, heading, NSView(), backToList, projects, refresh], spacing: 9)
        search.placeholderString = "Search pull requests"
        search.setAccessibilityLabel("Search Pull Requests")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        configure(states, label: "Pull Request State", options: [("open", "Open"), ("merged", "Merged"), ("closed", "Closed"), ("all", "All states")])
        configure(involvement, label: "Pull Request Involvement", options: [("all", "Everyone"), ("authored", "Authored by me"), ("reviewing", "Review requested")])
        configure(projects, label: "Pull Request Project", options: [("", "All projects")])
        projects.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projects.setContentHuggingPriority(.required, for: .horizontal)
        projects.widthAnchor.constraint(lessThanOrEqualToConstant: 195).isActive = true
        let filters = row([states, involvement, NSView()], spacing: 5)

        let requestColumn = NSTableColumn(identifier: .init("request"))
        requestColumn.resizingMask = .autoresizingMask
        table.addTableColumn(requestColumn)
        table.headerView = nil
        table.rowHeight = 49
        table.style = .inset
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Pull Request List")
        let scroll = scroller(for: table)
        fill(scroll, in: listPane, inset: 2)
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = WorkspaceStyle.muted
        empty.alignment = .center
        empty.maximumNumberOfLines = 4
        listPane.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerYAnchor.constraint(equalTo: listPane.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 15),
            empty.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -15),
            listPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        let listing = column([search, filters, listPane, row([count, NSView(), loadMore])], spacing: 7, alignment: .width)
        listColumn = listing
        listWidth = listing.widthAnchor.constraint(equalToConstant: 285)
        addChild(detail)
        detail.onOpenThread = { [weak self] id, archived in self?.onOpenThread?(id, archived) }
        detail.onCheckout = { [weak self] reference, url in self?.onCheckout?(reference, url) }
        detail.onChanged = { [weak self] in self?.loadPage() }
        let body = row([listing, detail.view], spacing: 12)
        body.alignment = .top
        body.distribution = .fill
        listing.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detail.view.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = WorkspaceStyle.muted
        status.maximumNumberOfLines = 3
        status.setContentHuggingPriority(.required, for: .vertical)
        fill(column([header, status, body], spacing: 11, alignment: .width), in: view, inset: 14)
        updateLayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateLayout()
    }

    func setPresented(_ value: Bool) {
        guard presented != value else { return }
        presented = value
        if value { sync(); if loaded && loading == nil { loadPage() } }
        else {
            stopRequests()
            detail.setTarget(nil, item: nil, connection: nil)
        }
    }

    func open(_ reference: PullRequestReference) { select(reference) }

    func focusSearch() {
        if listColumn?.isHidden == true { select(nil) }
        view.window?.makeFirstResponder(search)
    }

    func filterProject(_ projectID: String) {
        let _ = view
        updateProjects()
        guard let item = projects.itemArray.first(where: { $0.representedObject as? String == projectID }) else { return }
        projects.select(item)
        changeFilters()
    }

    func sync() {
        guard presented else { return }
        let _ = view
        let next = workspace.can("orchestration:read") ? workspace.connectionID : nil
        environment.stringValue = workspace.environment?.name ?? "No environment"
        if connection != next {
            stopRequests()
            connection = next
            listing = .init()
            loaded = false
            listError = nil
            selected = nil
            detail.setTarget(nil, item: nil, connection: nil)
            updateProjects()
            if let next { observeRefreshes(next); loadPage() }
        } else if updateProjects(), connection != nil, loading == nil {
            loadPage()
        }
        if connection != nil, refreshes == nil, let connection { observeRefreshes(connection) }
        if let selected { detail.setTarget(selected, item: listing.items.first { $0.reference == selected }, connection: connection) }
        render()
    }

    func shutdown() {
        stopRequests()
        detail.setTarget(nil, item: nil, connection: nil)
    }

    private func stopRequests() {
        requestID = UUID()
        loading?.cancel()
        loading = nil
        refreshes?.cancel()
        refreshes = nil
    }

    private func observeRefreshes(_ connection: UUID) {
        refreshes = Task { [weak self, workspace] in
            var last: Int?
            do {
                try await workspace.subscribe("pullRequests.subscribeRefreshes", [:]) { values in
                    guard let self, self.connection == connection, let epoch = values.last?.int else { return }
                    defer { last = epoch }
                    if let last, last != epoch {
                        self.loadPage(debounce: true)
                        self.detail.refresh()
                    }
                }
            } catch { }
        }
    }

    @discardableResult
    private func updateProjects() -> Bool {
        let choices = workspace.data.orderedProjects.filter { !$0.archived && !workspace.isScratch($0) }
            .map { ProjectChoice(id: $0.id, name: $0.name) }
        guard choices != projectChoices else { return false }
        let current = projects.selectedItem?.representedObject as? String ?? ""
        projectChoices = choices
        configure(projects, label: "Pull Request Project", options: [("", "All projects")] + choices.map { ($0.id, $0.name) })
        projects.select(projects.itemArray.first { $0.representedObject as? String == current } ?? projects.item(at: 0))
        return true
    }

    private func configure(_ picker: NSPopUpButton, label: String, options: [(String, String)]) {
        picker.removeAllItems()
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: 11)
        picker.setAccessibilityLabel(label)
        picker.target = self
        picker.action = #selector(filterChanged)
        for (key, title) in options {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            picker.menu?.addItem(item)
        }
        picker.selectItem(at: 0)
    }

    @objc private func filterChanged() { changeFilters() }

    func controlTextDidChange(_ obj: Notification) { changeFilters(debounce: true) }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var participation: String { involvement.selectedItem?.representedObject as? String ?? "all" }

    private func changeFilters(debounce: Bool = false) {
        select(nil)
        listing = .init()
        loaded = false
        listError = nil
        loadPage(debounce: debounce)
    }

    private func loadPage(append: Bool = false, debounce: Bool = false, invalidate: Bool = false) {
        guard presented, let connection, workspace.connectionID == connection else { render(); return }
        if append && (loading != nil || listing.cursors.isEmpty) { return }
        loading?.cancel()
        let requestID = UUID()
        self.requestID = requestID
        listError = nil
        var input: Payload = ["state": .string(states.selectedItem?.representedObject as? String ?? "open"),
                              "involvement": .string(participation), "limit": .int(40)]
        if let project = projects.selectedItem?.representedObject as? String, !project.isEmpty { input["projectId"] = .string(project) }
        if !query.isEmpty { input["query"] = .string(String(decoding: query.utf16.prefix(200), as: UTF16.self)) }
        if append { input["cursors"] = .object(listing.cursors) }
        loading = Task {
            defer {
                if self.requestID == requestID { loading = nil; render() }
            }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(230)) }
                guard workspace.connectionID == connection else { throw ClientError.disconnected }
                if invalidate {
                    _ = try await workspace.request("pullRequests.invalidate")
                    guard workspace.connectionID == connection else { throw ClientError.disconnected }
                    detail.refresh()
                }
                let result = try await workspace.request("pullRequests.list", input)
                guard !Task.isCancelled, workspace.connectionID == connection else { return }
                listing.apply(result, append: append)
                loaded = true
                if let selected { detail.setTarget(selected, item: listing.items.first { $0.reference == selected }, connection: connection) }
            } catch {
                if !Task.isCancelled { listError = error.localizedDescription }
            }
        }
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        let connected = connection != nil
        let next = listing.visibleItems(query: query, involvement: participation)
        if next != rows {
            rows = next
            rebuilding = true
            table.reloadData()
            updateTableSelection()
            rebuilding = false
        }
        search.isEnabled = connected
        for filter in [projects, states, involvement] { filter.isEnabled = connected }
        refresh.isEnabled = connected && loading == nil
        loadMore.isEnabled = loading == nil
        loadMore.isHidden = listing.cursors.isEmpty
        count.stringValue = rows.isEmpty ? "" : "\(rows.count) \(rows.count == 1 ? "pull request" : "pull requests")"
        empty.isHidden = !rows.isEmpty
        if !connected { empty.stringValue = "Connect to an environment to browse pull requests." }
        else if loading != nil && !loaded { empty.stringValue = "Loading pull requests…" }
        else if listError != nil { empty.stringValue = "Pull requests could not be loaded." }
        else if !listing.cursors.isEmpty { empty.stringValue = "No matches in the loaded results. Load more to continue." }
        else { empty.stringValue = "No pull requests match these filters." }
        let issues = listing.errors + listing.providerHints
        status.stringValue = listError ?? issues.first.map { issues.count > 1 ? "\($0)  ·  \(issues.count - 1) more" : $0 } ??
            (listing.truncated && listing.cursors.isEmpty ? "The source control host returned partial results." : "")
        status.toolTip = issues.joined(separator: "\n")
        status.isHidden = status.stringValue.isEmpty
        updateLayout()
    }

    private func updateLayout() {
        let wide = view.bounds.width >= 735
        let hasDetail = selected != nil
        listWidth?.isActive = wide
        listColumn?.isHidden = !wide && hasDetail
        detail.view.isHidden = !wide && !hasDetail
        backToList.isHidden = wide || !hasDetail
    }

    private func select(_ reference: PullRequestReference?) {
        selected = reference
        rebuilding = true
        updateTableSelection()
        rebuilding = false
        detail.setTarget(reference, item: rows.first { $0.reference == reference }, connection: connection)
        updateLayout()
    }

    private func updateTableSelection() {
        if let selected, let index = rows.firstIndex(where: { $0.reference == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let item = rows[index]
        let status: NSColor = switch item.state {
        case "Open": WorkspaceStyle.positive
        case "Merged": .systemPurple
        case "Closed": WorkspaceStyle.negative
        default: WorkspaceStyle.muted
        }
        let icon = WorkspaceStyle.icon("arrow.triangle.pull", size: 13, tint: status)
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        let title = label(item.title, size: 12, weight: .medium, color: WorkspaceStyle.ink)
        title.toolTip = item.title
        let reference = item.reference
        let meta = label("\(reference.repository) \(item.sigil)\(reference.number)  ·  \(item.state)", size: 10.5, color: WorkspaceStyle.muted)
        return row([icon, column([title, meta], spacing: 3), NSView()], spacing: 7)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding, rows.indices.contains(table.selectedRow) else { return }
        select(rows[table.selectedRow].reference)
    }
}
