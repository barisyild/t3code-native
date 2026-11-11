import AppKit

@MainActor
final class QueuedMessagesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case resume, send(String), edit(String), remove(String) }

    private let caption = label(size: 11.5, weight: .medium, color: WorkspaceStyle.muted)
    private let table = NSTableView()
    private lazy var scroll = scroller(for: table)
    private lazy var resume = ActionButton("Resume Queue", symbol: "play", style: .subtle) { [weak self] in self?.onAction?(.resume) }
    private var listHeight: NSLayoutConstraint!
    private var state = ThreadQueue.State()
    private var canOperate = false
    private var canEdit = false
    private var busy = false
    var onAction: ((Action) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let surface = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 11)
        let tableColumn = NSTableColumn(identifier: .init("queued-message"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 31
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Queued Messages")
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        listHeight.priority = .defaultHigh
        listHeight.isActive = true
        let heading = row([WorkspaceStyle.icon("clock", size: 11, tint: WorkspaceStyle.muted), caption, NSView(), resume], spacing: 6)
        fill(column([heading, scroll], spacing: 3, alignment: .width), in: surface, inset: 7)
        fill(surface, in: self)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ state: ThreadQueue.State, canOperate: Bool, canEdit: Bool, busy: Bool) {
        let hidden = state.messages.isEmpty && !state.held
        guard self.state != state || self.canOperate != canOperate || self.canEdit != canEdit ||
                self.busy != busy || isHidden != hidden else { return }
        let previous = self.state.messages
        self.state = state
        self.canOperate = canOperate
        self.canEdit = canEdit
        self.busy = busy
        isHidden = hidden
        let count = state.messages.count
        caption.stringValue = state.held ? (count == 0 ? "Queue paused" : "\(count) queued · Paused") : "\(count) queued"
        resume.isHidden = !state.held || !canOperate || state.activeRunID != nil
        resume.isEnabled = !busy
        scroll.isHidden = count == 0
        listHeight.constant = min(3, CGFloat(count)) * table.rowHeight
        if previous != state.messages {
            table.reloadData()
        } else {
            let visible = table.rows(in: table.visibleRect)
            for index in visible.location..<NSMaxRange(visible) where state.messages.indices.contains(index) {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? QueuedMessageRow {
                    updateControls(cell, for: state.messages[index])
                }
            }
        }
        if previous.isEmpty && count > 0 { table.scrollRowToVisible(0) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { state.messages.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let message = state.messages[index]
        let names = message.attachments.compactMap { $0["name"].string }.map(BrowserAnnotationContext.attachmentLabel)
        let plain = TerminalContext.plainText(AssistantCitation.plainText(message.displayText), records: message.context["records"].array)
        let text = String(plain.prefix(280)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let summary = text.isEmpty ? names.joined(separator: ", ") : text
        let preview = label(message.guestName.map { "\($0) · \(summary)" } ?? summary, size: 12, color: WorkspaceStyle.ink)
        preview.toolTip = [plain, names.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: "\n")
        let detail = label(names.count == 1 ? "1 attachment" : "\(names.count) attachments", size: 10.5, color: WorkspaceStyle.muted)
        detail.isHidden = names.isEmpty || text.isEmpty
        detail.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let send = control("Send Queued Message Now", symbol: "arrow.up", action: .send(message.id))
        let edit = control("Edit Queued Message…", symbol: "pencil", action: .edit(message.id))
        let remove = control("Remove Queued Message", symbol: "xmark", action: .remove(message.id))
        let cell = QueuedMessageRow(send: send, edit: edit, remove: remove)
        fill(row([preview, detail, NSView(), send, edit, remove], spacing: 5), in: cell, inset: 2)
        updateControls(cell, for: message)
        return cell
    }

    private func updateControls(_ cell: QueuedMessageRow, for message: QueuedMessage) {
        cell.send.isHidden = !canOperate || state.delivery(for: message) == nil
        cell.send.isEnabled = !busy
        cell.edit.isHidden = !canOperate || !message.editable
        cell.edit.isEnabled = canEdit && !busy
        cell.remove.isHidden = !canOperate
        cell.remove.isEnabled = !busy
    }

    private func control(_ title: String, symbol: String, action: Action) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, iconOnly: true, style: .subtle) { [weak self] in self?.onAction?(action) }
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        return button
    }
}

@MainActor
private final class QueuedMessageRow: NSTableCellView {
    let send: ActionButton
    let edit: ActionButton
    let remove: ActionButton

    init(send: ActionButton, edit: ActionButton, remove: ActionButton) {
        self.send = send
        self.edit = edit
        self.remove = remove
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
