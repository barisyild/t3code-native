import AppKit

@MainActor
final class PullRequestDetailController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Tab: Int { case overview, activity, files, checks }

    private let workspace: Workspace
    private lazy var files = PullRequestFilesController(workspace: workspace)
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let referenceLabel = label(size: 11, color: WorkspaceStyle.muted)
    private let metadata = label(size: 12, color: WorkspaceStyle.secondary)
    private let info = label(size: 11, color: WorkspaceStyle.muted)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["Overview", "Activity", "Files", "Checks"], trackingMode: .selectOne, target: nil, action: nil)
    private let document = TranscriptBodyView()
    private let checksTable = NSTableView()
    private let checkNote = NSTextField(wrappingLabelWithString: "")
    private let revisions = NSPopUpButton()
    private lazy var documentScroll = textScroller(document)
    private lazy var checkScroll = scroller(for: checksTable)
    private lazy var hostButton = ActionButton("Open on Host", symbol: "arrow.up.right", iconOnly: true, style: .subtle) { [weak self] in self?.openOnHost() }
    private lazy var checkout = ActionButton("Start Thread…", symbol: "square.and.pencil", style: .subtle) { [weak self] in self?.checkoutRequest() }
    private lazy var linkedButton = ActionButton("Linked Threads", symbol: "link", style: .subtle) { [weak self] in self?.showLinks() }
    private lazy var reviewButton = ActionButton("Review…", symbol: "text.bubble", style: .subtle) { [weak self] in self?.showReviewEditor() }
    private var checksPanel: NSView?
    private var filesPanel: NSView?
    private var actions: NSView?
    private var target: PullRequestTarget?
    private var summary: PullRequestItem?
    private var detail: Wire?
    private var activity: Wire?
    private var renderingDocument: Set<TranscriptRenderingRequest> = []
    private var checks: [Wire] = []
    private var linked: [Wire] = []
    private var route: Wire?
    private var detailTask: Task<Void, Never>?
    private var tabTask: Task<Void, Never>?
    private var editor: PullRequestReviewEditor?
    private var generation = UUID()
    private var tabGeneration = UUID()
    private var errorMessage: String?
    private var tabError: String?
    private var tab = Tab.overview
    private var commit: String?

    var onOpenThread: ((String, Bool) -> Void)?
    var onCheckout: ((PullRequestReference, String) -> Void)?
    var onChanged: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 10)
        titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        titleField.textColor = WorkspaceStyle.ink
        titleField.maximumNumberOfLines = 3
        titleField.setContentCompressionResistancePriority(.required, for: .vertical)
        titleField.setContentHuggingPriority(.required, for: .vertical)
        let title = column([referenceLabel, titleField, metadata, info], spacing: 4, alignment: .width)
        let header = row([title, hostButton], spacing: 9)
        header.distribution = .fill
        hostButton.widthAnchor.constraint(equalToConstant: 27).isActive = true
        let actions = row([checkout, linkedButton, NSView(), reviewButton], spacing: 5)
        self.actions = actions
        tabs.controlSize = .small
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("Pull Request Detail Tabs")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = WorkspaceStyle.accent
        notice.maximumNumberOfLines = 3
        notice.setContentHuggingPriority(.required, for: .vertical)
        document.textContainerInset = NSSize(width: 4, height: 6)
        document.setAccessibilityLabel("Pull Request Text")
        document.linkTextAttributes = [.foregroundColor: NSColor.linkColor]
        document.onAppearanceChange = { [weak self] in self?.renderBody() }
        NotificationCenter.default.addObserver(self, selector: #selector(mathRenderingChanged(_:)),
                                               name: TranscriptMathRendering.didChange, object: nil)

        checksTable.addTableColumn(NSTableColumn(identifier: .init("check")))
        checksTable.headerView = nil
        checksTable.style = .inset
        checksTable.rowHeight = 43
        checksTable.backgroundColor = .clear
        checksTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        checksTable.dataSource = self
        checksTable.delegate = self
        checksTable.target = self
        checksTable.doubleAction = #selector(openCheck)
        checksTable.setAccessibilityLabel("Pull Request Checks")
        checkNote.font = .systemFont(ofSize: 12)
        checkNote.textColor = WorkspaceStyle.muted
        let checksPanel = column([checkNote, checkScroll], spacing: 6, alignment: .width)
        self.checksPanel = checksPanel

        revisions.controlSize = .small
        revisions.setAccessibilityLabel("Diff Commit")
        revisions.target = self
        revisions.action = #selector(changeRevision)
        addChild(files)
        let filesPanel = column([row([revisions, NSView()]), files.view], spacing: 6, alignment: .width)
        self.filesPanel = filesPanel
        let body = NSView()
        for child in [documentScroll, checksPanel, filesPanel] { fill(child, in: body) }
        fill(column([header, actions, tabs, notice, body], spacing: 8, alignment: .width), in: view, inset: 14)
        render()
        renderBody()
    }

    func setTarget(_ reference: PullRequestReference?, item: PullRequestItem?, connection: UUID?) {
        let next = reference.flatMap { reference in connection.map { PullRequestTarget(reference: reference, connection: $0) } }
        let changed = next != target
        let changedSummary = summary != item
        summary = item
        guard changed else {
            if changedSummary { render() }
            return
        }
        generation = UUID()
        detailTask?.cancel()
        detailTask = nil
        stopTab()
        target = next
        detail = nil
        activity = nil
        checks = []
        linked = []
        route = nil
        errorMessage = nil
        tabError = nil
        tab = .overview
        commit = nil
        tabs.selectedSegment = 0
        files.configure(nil)
        render()
        renderBody()
        if next != nil { refresh() }
    }

    func refresh() {
        guard let target, workspace.connectionID == target.connection, detailTask == nil else { return }
        let id = generation
        errorMessage = nil
        detailTask = Task {
            defer { if generation == id { detailTask = nil; render() } }
            do {
                var input = target.reference.input
                input["allowStale"] = .bool(false)
                async let core = workspace.request("pullRequests.detail", input)
                async let threads = try? workspace.request("pullRequests.linkedThreads", target.reference.input)
                let response = try await core
                guard isCurrent(target, generation: id) else { return }
                detail = response
                checks = response["checks"].array
                render()
                renderBody()
                let resolvedRoute = response["provider"].string == "github"
                    ? try? await workspace.request("pullRequests.routing", target.reference.input) : nil
                let threadList = await threads
                guard isCurrent(target, generation: id) else { return }
                route = resolvedRoute
                linked = threadList?["threads"].array ?? []
                loadTab(refresh: true)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription; renderBody() }
            }
        }
        render()
    }

    private func isCurrent(_ target: PullRequestTarget, generation: UUID) -> Bool {
        !Task.isCancelled && self.generation == generation && workspace.connectionID == target.connection
    }

    private var detailsOrRow: Wire { detail ?? summary?.value ?? .null }
    private var url: String? { detailsOrRow["url"].string }
    private var reviewer: String? { route?["viewer"].string ?? detail?["viewer"].string }
    private var canWrite: Bool {
        guard workspace.can("source-control:write"), let detail, reviewer != nil else { return false }
        return detail["provider"].string != "github" || route?["accountId"].string != nil
    }

    private func render() {
        guard isViewLoaded else { return }
        let row = detailsOrRow
        let available = target != nil
        let reference = target?.reference
        let number = reference.map { (row["provider"].string == "gitlab" ? "!" : "#") + String($0.number) }
        referenceLabel.stringValue = [reference?.repository, number].compactMap { $0 }.joined(separator: " ")
        referenceLabel.isHidden = !available
        titleField.stringValue = row["title"].string ?? (available ? "Loading pull request…" : "Select a pull request")
        titleField.toolTip = row["title"].string
        let state = row["isDraft"].bool == true && row["state"].string == "open" ? "Draft" : row["state"].string?.capitalized
        let branches = [row["headBranch"].string, row["baseBranch"].string].compactMap { $0 }.joined(separator: " → ")
        let author = row["author"]["login"].string.map { "@\($0)" }
        metadata.stringValue = [state, author, branches.isEmpty ? nil : branches].compactMap { $0 }.joined(separator: "  ·  ")
        metadata.isHidden = metadata.stringValue.isEmpty
        metadata.toolTip = metadata.stringValue
        var extra: [String] = []
        if let additions = detail?["additions"].int, let deletions = detail?["deletions"].int {
            extra.append("+\(additions)  −\(deletions)")
        }
        if let count = detail?["changedFiles"].int { extra.append("\(count) files") }
        if row["mergeability"].string == "conflicting" { extra.append("Merge conflicts") }
        extra += row["labels"].array.compactMap { $0["name"].string }
        info.stringValue = extra.joined(separator: "  ·  ")
        info.isHidden = extra.isEmpty
        info.toolTip = info.stringValue
        hostButton.isHidden = url == nil
        tabs.isHidden = !available
        actions?.isHidden = !available
        checkout.isHidden = url == nil
        checkout.isEnabled = workspace.can("source-control:write") && workspace.can("orchestration:operate") &&
            reference.flatMap { workspace.data.projects[$0.projectID] }?.archived == false
        linkedButton.isHidden = linked.isEmpty
        linkedButton.title = linked.count > 1 ? "Linked Threads (\(linked.count))" : "Open Linked Thread"
        linkedButton.setAccessibilityLabel(linkedButton.title)
        reviewButton.isHidden = reviewOptions.isEmpty
        reviewButton.isEnabled = editor == nil
        notice.stringValue = errorMessage ?? tabError ?? ""
        notice.isHidden = notice.stringValue.isEmpty
    }

    @objc private func changeTab() {
        guard let next = Tab(rawValue: tabs.selectedSegment), next != tab else { return }
        stopTab()
        tab = next
        tabError = nil
        renderBody()
        render()
        loadTab()
    }

    private func stopTab() {
        tabGeneration = UUID()
        tabTask?.cancel()
        tabTask = nil
    }

    private func loadTab(refresh: Bool = false) {
        guard let target, let detail, workspace.connectionID == target.connection else { return }
        if tab == .files {
            updateRevisions()
            files.configure(target, capabilities: detail["capabilities"], accountID: route?["accountId"].string, viewer: reviewer, canWrite: canWrite,
                            head: detail["headSha"].string, commit: commit)
        }
        let readsActivity = tab == .activity || tab == .files
        if !readsActivity && tab != .checks { render(); return }
        if readsActivity && activity != nil && !refresh { return }
        guard tabTask == nil else { return }
        let id = tabGeneration
        let requestTab = tab
        let input = target.reference.input
        tabTask = Task {
            defer { if tabGeneration == id { tabTask = nil; render() } }
            do {
                let result = try await workspace.request(readsActivity ? "pullRequests.activity" : "pullRequests.checks", input)
                guard !Task.isCancelled, tabGeneration == id, workspace.connectionID == target.connection else { return }
                if readsActivity {
                    activity = result
                    if requestTab == .files { updateRevisions() }
                } else if result != .null { checks = result["checks"].array }
                renderBody()
            } catch {
                if !Task.isCancelled {
                    tabError = error.localizedDescription
                    renderBody()
                }
            }
        }
    }

    private func renderBody() {
        guard isViewLoaded else { return }
        documentScroll.isHidden = tab == .files || tab == .checks
        filesPanel?.isHidden = tab != .files
        checksPanel?.isHidden = tab != .checks
        switch tab {
        case .overview:
            let body: String
            if let detail { body = detail["body"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "No description." }
            else { body = target == nil ? "Review changes, checks and conversation here." :
                errorMessage == nil ? "Loading description…" : "Description unavailable." }
            let dark = TranscriptArtwork.isDark(document.effectiveAppearance)
            setDocument(TranscriptText.markdown(body, darkArtwork: dark))
        case .activity:
            setDocument(activityText())
        case .files:
            break
        case .checks:
            checksTable.reloadData()
            checkNote.stringValue = checks.isEmpty ? "No checks reported." : ""
            checkNote.isHidden = !checks.isEmpty
        }
    }

    @objc private func mathRenderingChanged(_ notification: Notification) { renderBody() }

    private func setDocument(_ content: NSAttributedString) {
        document.textStorage?.setAttributedString(content)
        for request in TranscriptRenderingRequest.missing(in: content) where renderingDocument.insert(request).inserted {
            request.load { [weak self] ready in
                guard let self else { return }
                renderingDocument.remove(request)
                if ready, TranscriptRenderingRequest.missing(in: document.attributedString()).contains(request) { renderBody() }
            }
        }
    }

    private func activityText() -> NSAttributedString {
        guard let activity else { return TranscriptText.markdown(tabError == nil ? "Loading activity…" : "Activity unavailable.") }
        var entries: [(date: String, title: String, body: String)] = []
        let threads = activity["reviewThreads"].array
        let inlineIDs = Set(threads.flatMap { $0["comments"].array.compactMap { $0["id"].string } })
        for comment in activity["comments"].array where !inlineIDs.contains(comment["id"].string ?? "") {
            let author = comment["author"]["login"].string ?? "Unknown author"
            let label = comment["reviewState"].string?.replacingOccurrences(of: "_", with: " ").capitalized
            entries.append((comment["createdAt"].string ?? "", label.map { "\(author) · \($0)" } ?? author, comment["body"].string ?? ""))
        }
        for thread in threads {
            let path = thread["path"].string ?? "Inline review"
            let location = path + (thread["line"].int.map { ":\($0)" } ?? "")
            let badge = thread["isOutdated"].bool == true ? " · Outdated" : thread["isResolved"].bool == true ? " · Resolved" : ""
            for comment in thread["comments"].array {
                let author = comment["author"]["login"].string ?? "Unknown author"
                entries.append((comment["createdAt"].string ?? "", "\(author) · \(location)\(badge)", comment["body"].string ?? ""))
            }
        }
        for commit in activity["commits"].array {
            let revision = commit["oid"].string.map { String($0.prefix(7)) } ?? ""
            entries.append((commit["committedDate"].string ?? "", "Commit \(revision)", commit["messageHeadline"].string ?? ""))
        }
        guard !entries.isEmpty else { return TranscriptText.markdown("No activity yet.") }
        let result = NSMutableAttributedString()
        let dark = TranscriptArtwork.isDark(document.effectiveAppearance)
        for entry in entries.sorted(by: { $0.date < $1.date }).suffix(120) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            let date = WorkspaceStyle.date(entry.date)?.formatted(date: .abbreviated, time: .shortened)
            result.append(NSAttributedString(string: [entry.title, date].compactMap { $0 }.joined(separator: "  ·  ") + "\n",
                                             attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: WorkspaceStyle.muted]))
            result.append(TranscriptText.markdown(String(entry.body.prefix(24_000)), darkArtwork: dark))
        }
        if entries.count > 120 || activity["commentsTruncated"].bool == true || activity["reviewThreadsTruncated"].bool == true {
            result.append(NSAttributedString(string: "\n\n"))
            result.append(TranscriptText.markdown("Some activity is available on the host."))
        }
        return result
    }

    private func updateRevisions() {
        let choices = activity?["commits"].array ?? []
        revisions.removeAllItems()
        revisions.addItem(withTitle: "All changes")
        for change in choices {
            guard let oid = change["oid"].string else { continue }
            let headline = change["messageHeadline"].string ?? ""
            revisions.addItem(withTitle: "\(oid.prefix(7))  \(headline)")
            revisions.lastItem?.representedObject = oid
        }
        revisions.select(revisions.itemArray.first { $0.representedObject as? String == commit } ?? revisions.item(at: 0))
        revisions.isHidden = choices.isEmpty
    }

    @objc private func changeRevision() {
        commit = revisions.selectedItem?.representedObject as? String
        if let detail {
            files.configure(target, capabilities: detail["capabilities"], accountID: route?["accountId"].string, viewer: reviewer, canWrite: canWrite,
                            head: detail["headSha"].string, commit: commit)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { checks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let check = checks[index]
        let status = check["status"].string
        let tint: NSColor = switch status {
        case "success": WorkspaceStyle.positive
        case "failure", "action-required": WorkspaceStyle.negative
        case "pending": WorkspaceStyle.accent
        default: WorkspaceStyle.muted
        }
        let symbol = status == "success" ? "checkmark.circle" : status == "pending" ? "clock" : "circle"
        let icon = WorkspaceStyle.icon(symbol, tint: tint)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let heading = label(check["name"].string ?? "Check", size: 12, weight: .medium)
        let description = [status?.replacingOccurrences(of: "-", with: " ").capitalized, check["description"].string,
                           check["required"].bool == true ? "Required" : nil].compactMap { $0 }.joined(separator: "  ·  ")
        let note = label(description, size: 11, color: WorkspaceStyle.muted)
        return row([icon, column([heading, note], spacing: 2), NSView()], spacing: 8)
    }

    @objc private func openCheck() {
        let index = checksTable.clickedRow
        guard checks.indices.contains(index), let text = checks[index]["url"].string,
              let url = RepositoryRequestReference.webURL(text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openOnHost() {
        guard let text = url, let url = RepositoryRequestReference.webURL(text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func checkoutRequest() {
        guard let target, let url, workspace.connectionID == target.connection else { return }
        onCheckout?(target.reference, url)
    }

    private func showLinks() {
        guard !linked.isEmpty else { return }
        if linked.count == 1 { openLinked(linked[0]); return }
        let menu = NSMenu()
        for thread in linked {
            let item = menuItem(thread["title"].string ?? "Thread", target: self, action: #selector(chooseLink(_:)))
            item.representedObject = thread["id"].string
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: linkedButton.bounds.minY), in: linkedButton)
    }

    @objc private func chooseLink(_ item: NSMenuItem) {
        if let thread = linked.first(where: { $0["id"].string == item.representedObject as? String }) { openLinked(thread) }
    }

    private func openLinked(_ thread: Wire) {
        if let id = thread["id"].string { onOpenThread?(id, thread["archivedAt"].string != nil) }
    }

    private var reviewOptions: [PullRequestReviewEditor.Option] {
        guard canWrite, let detail else { return [] }
        let capabilities = detail["capabilities"]
        let permissions = detail["viewerPermissions"]
        var options: [PullRequestReviewEditor.Option] = []
        if capabilities["comment"].bool == true && permissions["comment"].bool == true { options.append(.comment) }
        let verdicts = capabilities["review"]["verdicts"].array.filter { permissions["verdicts"].array.contains($0) }
        options += verdicts.compactMap { $0.string.flatMap(PullRequestReviewEditor.Option.init(rawValue:)) }
        return options
    }

    private func showReviewEditor() {
        guard let target, let reviewer,
              let window = view.window, window.attachedSheet == nil else { return }
        let account = route?["accountId"].string
        let options = reviewOptions
        guard !options.isEmpty else { return }
        let editor = PullRequestReviewEditor(title: titleField.stringValue, viewer: reviewer, options: options)
        self.editor = editor
        editor.onClose = { [weak self] in self?.editor = nil; self?.render() }
        editor.onSubmit = { [weak self] option, body in
            guard let self, self.target == target, self.reviewer == reviewer, workspace.connectionID == target.connection,
                  self.reviewOptions.contains(option) else { throw ClientError.disconnected }
            var input = target.reference.input
            if let account { input["expectedAccountId"] = .string(account) }
            input["body"] = .string(body)
            if option != .comment {
                input["verdict"] = .string(option.rawValue)
                input["comments"] = .array([])
            }
            _ = try await workspace.request(option == .comment ? "pullRequests.comment" : "pullRequests.submitReview", input)
            guard self.target == target, workspace.connectionID == target.connection else { return }
            stopTab()
            activity = nil
            loadTab(refresh: true)
            refresh()
            onChanged?()
        }
        editor.present(in: window)
        render()
    }
}
