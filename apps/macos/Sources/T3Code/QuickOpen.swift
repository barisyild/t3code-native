import AppKit

@MainActor
final class QuickOpen: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDelegate, NSTableViewDataSource {
    enum Mode {
        case all, conversations, files, contents

        var title: String {
            switch self {
            case .all: "Quick Open"
            case .conversations: "Search Conversations"
            case .files: "Find Files"
            case .contents: "Find in Files"
            }
        }

        var placeholder: String {
            switch self {
            case .all: "Search commands, projects, conversations, and messages"
            case .conversations: "Search conversations and messages"
            case .files: "Search file names and paths"
            case .contents: "Search text in the current checkout"
            }
        }
    }

    struct Entry {
        enum Kind: Equatable { case action, project, thread(String) }

        let name: String
        let detail: String
        let icon: String
        var kind = Kind.action
        var keywords: [String] = []
        let action: () -> Void
    }

    private enum Request: Equatable {
        case messages(String, MessageSearchScope)
        case files(String, FileContentSearchOptions?, FileSearchScope)
    }

    private enum Item {
        enum ID: Equatable {
            case entry(Int), message(String), file(String, WorkspaceFilePosition?)
        }

        case entry(Int)
        case message(MessageSearchResult, String, MessageSearchScope)
        case file(FileSearchHit, FileSearchScope)

        var id: ID {
            switch self {
            case .entry(let index): .entry(index)
            case .message(let match, _, _): .message(match.hit.threadID)
            case .file(let hit, _): .file(hit.path, hit.position)
            }
        }
    }

    private let workspace: Workspace
    private let field = NSSearchField()
    private let results = NSTableView()
    private let status = label(size: 11.5, color: WorkspaceStyle.muted)
    private let caseSensitive = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private lazy var options = row([caseSensitive, wholeWord, regex, NSView()], spacing: 12)
    private lazy var retry = ActionButton("Retry", symbol: "arrow.clockwise", style: .subtle) { [weak self] in
        self?.refresh(force: true)
    }
    private lazy var statusRow = row([status, NSView(), retry])
    private var mode = Mode.all
    private var presented = false
    private var environmentID: String?
    private var entries: [Entry] = []
    private var items: [Item] = []
    private var remote: [Item] = []
    private var currentRequest: Request?
    private var searchTask: Task<Void, Never>?
    private var failure: String?
    private var warning: String?
    private var truncated = false
    var onOpenMessage: ((MessageSearchResult, String, MessageSearchScope) -> Void)?
    var onOpenFile: ((WorkspaceFileReference, FileSearchScope) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 590, height: 402),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = Mode.all.title
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 465, height: 260)
        super.init(window: panel)
        panel.delegate = self
        field.setAccessibilityLabel("Quick Open Search")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        let tableColumn = NSTableColumn(identifier: .init("result"))
        tableColumn.resizingMask = .autoresizingMask
        results.addTableColumn(tableColumn)
        results.headerView = nil
        results.style = .plain
        results.intercellSpacing = NSSize(width: 0, height: 2)
        results.backgroundColor = .clear
        results.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        results.autoresizingMask = [.width]
        results.delegate = self
        results.dataSource = self
        results.target = self
        results.doubleAction = #selector(runSelected)
        results.setAccessibilityLabel("Quick Open Results")
        for button in [caseSensitive, wholeWord, regex] {
            button.target = self
            button.action = #selector(changeOptions)
            button.controlSize = .small
        }
        let scroll = scroller(for: results)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let content = Surface(WorkspaceStyle.navigation)
        panel.contentView = content
        fill(column([field, options, scroll, statusRow], spacing: 8, alignment: .width), in: content, inset: 12)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func open(_ entries: [Entry], mode: Mode = .all, over parent: NSWindow) {
        guard let window else { return }
        cancelSearch()
        presented = true
        environmentID = workspace.environment?.id
        self.mode = mode
        self.entries = entries
        field.stringValue = ""
        field.placeholderString = mode.placeholder
        options.isHidden = mode != .contents
        window.title = mode.title
        window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                      y: parent.frame.maxY - window.frame.height - 72))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        window.contentView?.layoutSubtreeIfNeeded()
        windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        refresh(force: true, preserveSelection: false)
    }

    func sync() {
        guard presented else { return }
        if environmentID != workspace.environment?.id { close() }
        else { refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        presented = false
        cancelSearch()
        entries.removeAll()
        items.removeAll()
        results.reloadData()
    }

    func windowDidResize(_ notification: Notification) {
        guard let width = results.enclosingScrollView?.contentView.bounds.width, width > 0,
              let column = results.tableColumns.first, abs(column.width - width) > 1 else { return }
        column.width = width
    }

    private var actionsOnly: Bool {
        mode == .all && field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">")
    }

    private var request: Request? {
        switch mode {
        case .all, .conversations:
            let query = SearchText.messageQuery(field.stringValue)
            guard !actionsOnly, !SearchText.messageWords(query).isEmpty, let scope = workspace.messageSearchScope else { return nil }
            return .messages(query, scope)
        case .files, .contents:
            guard let scope = workspace.fileSearchScope else { return nil }
            let query = SearchText.limited(field.stringValue, to: 256)
            if mode == .files { return .files(query.trimmingCharacters(in: .whitespacesAndNewlines), nil, scope) }
            guard !query.isEmpty else { return nil }
            return .files(query, .init(caseSensitive: caseSensitive.state == .on, wholeWord: wholeWord.state == .on,
                                       regex: regex.state == .on), scope)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        currentRequest = nil
        remote.removeAll()
        failure = nil
        warning = nil
        truncated = false
    }

    private func refresh(force: Bool = false, preserveSelection: Bool = true) {
        guard presented else { return }
        let next = request
        if force || currentRequest != next {
            cancelSearch()
            currentRequest = next
            if let next {
                searchTask = Task { [weak self, workspace] in
                    do {
                        if !force { try await Task.sleep(for: .milliseconds(230)) }
                        try Task.checkCancellation()
                        let rows: [Item]
                        var note: String?
                        var limited = false
                        switch next {
                        case .messages(let query, let scope):
                            rows = try await workspace.searchMessages(query, scope: scope).map { .message($0, query, scope) }
                        case .files(let query, let options, let scope):
                            let result = try await workspace.searchFiles(query, contents: options, scope: scope)
                            rows = result.hits.map { .file($0, scope) }
                            note = result.warning
                            limited = result.truncated
                        }
                        guard let self, !Task.isCancelled, self.presented, self.currentRequest == next else { return }
                        self.remote = rows
                        self.warning = note
                        self.truncated = limited
                        self.searchTask = nil
                        self.render(preserveSelection: true)
                    } catch {
                        guard let self, !Task.isCancelled, self.presented, self.currentRequest == next else { return }
                        self.failure = error.localizedDescription
                        self.searchTask = nil
                        self.render(preserveSelection: true)
                    }
                }
            }
        }
        render(preserveSelection: preserveSelection)
    }

    private func localEntries() -> [Int] {
        guard mode == .all || mode == .conversations else { return [] }
        var query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if actionsOnly { query = String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches: [(index: Int, score: Int)] = entries.enumerated().compactMap { index, entry in
            if actionsOnly, entry.kind != .action { return nil }
            if mode == .conversations {
                guard case .thread = entry.kind else { return nil }
            }
            if case .thread(let id) = entry.kind, workspace.data.threads[id] == nil, workspace.data.archived[id] == nil { return nil }
            if words.isEmpty { return (index, 0) }
            let fields = [entry.name, entry.detail] + entry.keywords
            guard words.allSatisfy({ word in fields.contains { contains($0, word) } }) else { return nil }
            let score = entry.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? 3 :
                contains(entry.name, query) ? 2 : words.allSatisfy { contains(entry.name, $0) } ? 1 : 0
            return (index, score)
        }
        return matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(100).map(\.index)
    }

    private func contains(_ value: String, _ query: String) -> Bool {
        value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func render(preserveSelection: Bool) {
        let selected = preserveSelection && items.indices.contains(results.selectedRow) ? items[results.selectedRow].id : nil
        let local = localEntries()
        let shown = Set(local.compactMap { index -> String? in
            if case .thread(let id) = entries[index].kind { return id }
            return nil
        })
        items = local.map(Item.entry) + remote.filter {
            if case .message(let match, _, _) = $0 { return !shown.contains(match.hit.threadID) }
            return true
        }
        results.reloadData()
        if !items.isEmpty {
            let row = items.firstIndex { $0.id == selected } ?? 0
            results.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            results.scrollRowToVisible(row)
        }
        let message: String
        if let failure { message = failure }
        else if let warning { message = warning }
        else if searchTask != nil {
            switch mode {
            case .all, .conversations: message = "Searching messages…"
            case .files: message = "Finding files…"
            case .contents: message = "Searching file contents…"
            }
        } else if truncated { message = "More results available. Narrow your search." }
        else if (mode == .files || mode == .contents) && workspace.fileSearchScope == nil {
            message = "Select a checkout with file read access."
        } else if mode == .conversations && workspace.messageSearchScope == nil {
            message = "Connect an environment to search its conversations."
        } else if items.isEmpty {
            message = mode == .contents && field.stringValue.isEmpty ? "Enter text to search files." : "No matches."
        } else { message = "" }
        status.stringValue = message
        status.toolTip = message.isEmpty ? nil : message
        status.textColor = failure != nil ? WorkspaceStyle.negative : WorkspaceStyle.muted
        retry.isHidden = failure == nil
        statusRow.isHidden = message.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) { refresh(preserveSelection: false) }
    @objc private func changeOptions() { refresh(preserveSelection: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        default: return false
        }
        return true
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let index = max(0, min(items.count - 1, results.selectedRow + delta))
        results.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        results.scrollRowToVisible(index)
    }

    @objc private func runSelected() {
        let index = results.selectedRow
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .entry(let index):
            if case .thread(let id) = entries[index].kind, workspace.data.threads[id] == nil, workspace.data.archived[id] == nil {
                render(preserveSelection: false)
                return
            }
            let action = entries[index].action
            close()
            action()
        case .message(let match, let query, let scope):
            guard workspace.messageSearchScope == scope else { sync(); return }
            close()
            onOpenMessage?(match, query, scope)
        case .file(let hit, let scope):
            guard workspace.fileSearchScope == scope else { sync(); return }
            close()
            onOpenFile?(hit.reference, scope)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        guard items.indices.contains(index) else { return 31 }
        return switch items[index] {
        case .entry: 31
        case .message: 46
        case .file(let hit, _): hit.excerpt == nil ? 31 : 46
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .entry(let index):
            let entry = entries[index]
            return cell(title: entry.name, icon: entry.icon, detail: entry.detail)
        case .message(let match, let query, _):
            let excerpt = highlighted(match.hit.snippet, ranges: SearchText.ranges(in: match.hit.snippet, for: SearchText.messageWords(query)),
                                      prefix: match.hit.roleTitle)
            return cell(title: match.title, icon: "bubble.left", detail: match.projectTitle ?? "", excerpt: excerpt)
        case .file(let hit, _):
            let excerpt = hit.excerpt.map { highlighted($0, ranges: hit.ranges) }
            return cell(title: hit.path, icon: "doc", detail: hit.position.map { "Line \($0.line)" } ?? "", excerpt: excerpt)
        }
    }

    private func cell(title: String, icon: String, detail: String, excerpt: NSAttributedString? = nil) -> NSView {
        let symbol = WorkspaceStyle.icon(icon, size: 13, tint: WorkspaceStyle.muted)
        symbol.widthAnchor.constraint(equalToConstant: 21).isActive = true
        let name = label(title, size: 13, weight: .medium, color: WorkspaceStyle.ink)
        let context = label(detail, size: 11, color: WorkspaceStyle.muted)
        context.setContentHuggingPriority(.required, for: .horizontal)
        let heading = row([name, context], spacing: 12)
        var lines: [NSView] = [heading]
        if let excerpt {
            let preview = label(size: 11.5)
            preview.attributedStringValue = excerpt
            preview.toolTip = excerpt.string
            lines.append(preview)
        }
        let body = column(lines, spacing: 2, alignment: .width)
        let cell = NSTableCellView()
        fill(row([symbol, body], spacing: 6), in: cell, inset: 4)
        cell.toolTip = title
        return cell
    }

    private func highlighted(_ snippet: String, ranges: [NSRange], prefix: String? = nil) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5)
        let output = NSMutableAttributedString(string: snippet, attributes: [.font: font, .foregroundColor: WorkspaceStyle.muted])
        for range in ranges {
            output.addAttributes([.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                  .foregroundColor: WorkspaceStyle.ink], range: range)
        }
        if let prefix {
            output.insert(NSAttributedString(string: prefix + " · ", attributes: [.font: font, .foregroundColor: WorkspaceStyle.accent]), at: 0)
        }
        return output
    }
}
