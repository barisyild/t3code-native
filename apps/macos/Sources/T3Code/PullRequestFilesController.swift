import AppKit

@MainActor
final class PullRequestFilesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let workspace: Workspace
    private let table = NSTableView()
    private let document = NSTextView()
    private let status = label(size: 11, color: WorkspaceStyle.muted)
    private let fileName = label(size: 12, weight: .semibold, color: WorkspaceStyle.ink)
    private let mode = NSSegmentedControl(labels: ["Patch", "Before", "After"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var more = ActionButton("Load More Files", style: .subtle) { [weak self] in self?.loadPage(append: true) }
    private lazy var viewedButton = ActionButton("Mark Viewed", symbol: "checkmark", style: .subtle) { [weak self] in self?.toggleViewed() }
    private var target: PullRequestTarget?
    private var supportsDiff = false
    private var supportsViewed = false
    private var canWrite = false
    private var accountID: String?
    private var viewer: String?
    private var head: String?
    private var revision: String?
    private var files: [PullRequestFile] = []
    private var cursor: String?
    private var viewed = Set<String>()
    private var selectedPath: String?
    private var contents: Wire?
    private var rebuilding = false
    private var pageTask: Task<Void, Never>?
    private var contentsTask: Task<Void, Never>?
    private var viewedLoad: Task<Void, Never>?
    private var mutation: Task<Void, Never>?
    private var requestID = UUID()
    private var message: String?
    private var truncated = false

    private var selectedFile: PullRequestFile? { files.first { $0.path == selectedPath } }

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.headerView = nil
        table.rowHeight = 25
        table.style = .inset
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Pull Request Changed Files")
        let list = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 6)
        fill(scroller(for: table), in: list, inset: 1)
        list.heightAnchor.constraint(equalToConstant: 110).isActive = true
        document.textContainerInset = NSSize(width: 7, height: 8)
        document.usesFindPanel = true
        document.setAccessibilityLabel("Pull Request Diff")
        let code = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 6)
        fill(textScroller(document), in: code, inset: 1)
        code.heightAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        mode.selectedSegment = 0
        mode.controlSize = .small
        mode.target = self
        mode.action = #selector(changeFileMode)
        mode.setAccessibilityLabel("File Content Version")
        let buttons = row([fileName, NSView(), viewedButton, mode], spacing: 6)
        fill(column([list, row([status, NSView(), more], spacing: 6), buttons, code], spacing: 7, alignment: .width), in: view)
        render()
    }

    func configure(_ target: PullRequestTarget?, capabilities: Wire = .null, accountID: String? = nil,
                   viewer: String? = nil, canWrite: Bool = false, head: String? = nil, commit: String? = nil) {
        let diff = capabilities["diff"].bool == true
        let marks = capabilities["viewedFiles"].string != nil
        let changed = self.target != target || self.head != head || revision != commit || supportsDiff != diff ||
            (self.viewer != nil && self.viewer != viewer)
        self.accountID = accountID
        self.viewer = viewer
        self.canWrite = canWrite
        self.target = target
        self.head = head
        revision = commit
        supportsDiff = diff
        supportsViewed = marks
        guard changed else { render(); return }
        cancel()
        selectedPath = nil
        files = []
        viewed = []
        cursor = nil
        contents = nil
        message = nil
        truncated = false
        guard isViewLoaded else { return }
        mode.selectedSegment = 0
        reloadTable()
        if target != nil && diff {
            loadPage()
            if marks && commit == nil { loadViewed() }
        } else {
            showText("This host does not provide a diff for this pull request.")
            render()
        }
    }

    private func cancel() {
        requestID = UUID()
        pageTask?.cancel()
        pageTask = nil
        contentsTask?.cancel()
        contentsTask = nil
        viewedLoad?.cancel()
        viewedLoad = nil
        mutation?.cancel()
        mutation = nil
    }

    private func input(for target: PullRequestTarget) -> Payload {
        var input = target.reference.input
        if let revision { input["commit"] = .string(revision) }
        if let accountID { input["expectedAccountId"] = .string(accountID) }
        return input
    }

    private func loadPage(append: Bool = false) {
        guard let target, workspace.connectionID == target.connection, pageTask == nil else { return }
        var input = input(for: target)
        let previousCursor = append ? cursor : nil
        if let previousCursor { input["cursor"] = .string(previousCursor) }
        message = nil
        let id = requestID
        pageTask = Task {
            defer { if requestID == id { pageTask = nil; render() } }
            do {
                let result = try await workspace.pullRequestDiff(input, connection: target.connection)
                let decoded = await Task.detached(priority: .userInitiated) { PullRequestFile.page(result) }.value
                try Task.checkCancellation()
                guard requestID == id, workspace.connectionID == target.connection else { return }
                var paths = Set(files.map(\.path))
                files += decoded.filter { paths.insert($0.path).inserted }
                cursor = result["nextCursor"].string
                if cursor == previousCursor { cursor = nil }
                truncated = truncated || result["truncated"].bool == true
                if selectedPath == nil { select(files.first) }
                reloadTable()
                if files.isEmpty { showText("No file changes to show.") }
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                if files.isEmpty { showText("The diff could not be loaded.") }
            }
        }
        if !append { showText("Loading file changes…") }
        render()
    }

    private func loadViewed() {
        guard let target else { return }
        let id = requestID
        let input = input(for: target)
        viewedLoad = Task {
            defer { if requestID == id { viewedLoad = nil; render() } }
            do {
                let value = try await workspace.request("pullRequests.filesViewed", input)
                guard !Task.isCancelled, requestID == id, workspace.connectionID == target.connection else { return }
                viewed = Set(value["files"].array.compactMap { $0["state"].string == "viewed" ? $0["path"].string : nil })
                reloadTable()
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func toggleViewed() {
        guard viewedButton.isEnabled, let file = selectedFile, let target, workspace.connectionID == target.connection else { return }
        let mark = !viewed.contains(file.path)
        message = nil
        let id = requestID
        var payload = input(for: target)
        payload["files"] = .array([.object(["path": .string(file.path), "viewed": .bool(mark)])])
        mutation = Task {
            defer { if requestID == id { mutation = nil; render() } }
            do {
                _ = try await workspace.request("pullRequests.setFilesViewed", payload)
                guard !Task.isCancelled, requestID == id, workspace.connectionID == target.connection else { return }
                if mark { viewed.insert(file.path) } else { viewed.remove(file.path) }
                reloadTable()
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
        render()
    }

    private func select(_ file: PullRequestFile?) {
        contentsTask?.cancel()
        contentsTask = nil
        contents = nil
        selectedPath = file?.path
        mode.selectedSegment = 0
        changeFileMode()
    }

    @objc private func changeFileMode() {
        guard let file = selectedFile, let target else { showText(""); render(); return }
        if mode.selectedSegment == 0 {
            showText(file.patch ?? "The host omitted this file's patch. Open a full file version to read its contents.", diff: file.patch != nil)
        } else if let contents {
            displayVersion(contents)
        } else if contentsTask == nil {
            showText("Loading file contents…")
            var input = input(for: target)
            input["changeType"] = .string(file.kind)
            input["oldPath"] = .string(file.oldPath)
            input["newPath"] = .string(file.newPath)
            contentsTask = Task {
                defer { if !Task.isCancelled && selectedPath == file.path { contentsTask = nil } }
                do {
                    let value = try await workspace.request("pullRequests.diffFileContents", input)
                    guard !Task.isCancelled, workspace.connectionID == target.connection, selectedPath == file.path else { return }
                    contents = value
                    if mode.selectedSegment != 0 { displayVersion(value) }
                } catch {
                    if !Task.isCancelled && mode.selectedSegment != 0 { showText(error.localizedDescription) }
                }
            }
        }
        render()
    }

    private func displayVersion(_ contents: Wire) {
        let value = contents[mode.selectedSegment == 1 ? "oldContents" : "newContents"].string ?? ""
        showText(value.isEmpty ? "This file version is empty or absent." : value)
    }

    private func showText(_ value: String, diff: Bool = false) {
        let maximum = 190_000
        let clipped = value.prefix(maximum)
        let text = clipped.endIndex == value.endIndex ? value : String(clipped) + "\n\n[Preview shortened. Open the pull request on its host to read the full file.]"
        document.textStorage?.setAttributedString(TranscriptText.monospace(text, diff: diff))
        document.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func reloadTable() {
        rebuilding = true
        table.reloadData()
        if let selectedPath, let index = files.firstIndex(where: { $0.path == selectedPath }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        rebuilding = false
    }

    private func render() {
        guard isViewLoaded else { return }
        fileName.stringValue = selectedFile?.path ?? "File changes"
        fileName.toolTip = selectedFile?.path
        mode.isEnabled = selectedFile != nil
        more.isHidden = cursor == nil
        more.isEnabled = pageTask == nil
        let note = truncated ? " · Partial diff" : ""
        status.stringValue = message ?? (pageTask != nil ? "Loading files…" : files.isEmpty ? "" : "\(files.count) files\(note)")
        status.toolTip = message
        let available = supportsViewed && revision == nil && canWrite && workspace.can("source-control:write")
        viewedButton.isHidden = !available
        viewedButton.isEnabled = available && selectedFile != nil && mutation == nil && viewedLoad == nil
        viewedButton.title = selectedPath.map(viewed.contains) == true ? "Mark Unviewed" : "Mark Viewed"
        viewedButton.setAccessibilityLabel(viewedButton.title)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let file = files[index]
        let isViewed = viewed.contains(file.path)
        let icon = WorkspaceStyle.icon(isViewed ? "checkmark.circle.fill" : "doc", size: 11,
                                       tint: isViewed ? WorkspaceStyle.positive : WorkspaceStyle.muted)
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        let name = label(file.path, size: 11.5, color: WorkspaceStyle.ink)
        name.toolTip = file.path
        let add = label("+\(file.additions)", size: 10.5, color: WorkspaceStyle.positive)
        let remove = label("−\(file.deletions)", size: 10.5, color: WorkspaceStyle.negative)
        for count in [add, remove] { count.setContentCompressionResistancePriority(.required, for: .horizontal) }
        return row([icon, name, NSView(), add, remove], spacing: 5)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !rebuilding, files.indices.contains(table.selectedRow) else { return }
        select(files[table.selectedRow])
    }
}
