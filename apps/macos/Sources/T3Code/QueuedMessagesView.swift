import AppKit

@MainActor
final class QueuedMessagesView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case resume, send(String), edit(String), remove(String), reorder(ThreadQueue.Reorder) }

    private let caption = label(size: 11.5, weight: .medium, color: WorkspaceStyle.muted)
    private let table = NSTableView()
    private lazy var scroll = scroller(for: table)
    private lazy var resume = ActionButton("Resume Queue", symbol: "play", style: .subtle) { [weak self] in self?.onAction?(.resume) }
    private var listHeight: NSLayoutConstraint!
    private var state = ThreadQueue.State()
    private var canOperate = false
    private var canEdit = false
    private var busy = false
    private weak var dragSource: QueueDragHandle?
    private var canReorder: Bool { canOperate && !busy && state.messages.count > 1 }
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
        table.registerForDraggedTypes([QueueDragHandle.pasteboardType])
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
        if !canReorder || previous != state.messages { invalidateDrag() }
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

    func invalidateDrag() { dragSource = nil }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let belowMiddle = proposedDropOperation == .on && state.messages.indices.contains(row) &&
            tableView.convert(info.draggingLocation, from: nil).y > tableView.rect(ofRow: row).midY
        let insertion = belowMiddle ? row + 1 : row
        guard drop(info, at: insertion) != nil else { return [] }
        tableView.setDropRow(insertion, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let move = drop(info, at: row) else { return false }
        invalidateDrag()
        onAction?(.reorder(move))
        return true
    }

    private func drop(_ info: any NSDraggingInfo, at row: Int) -> ThreadQueue.Reorder? {
        guard canReorder, let source = info.draggingSource as? QueueDragHandle, source === dragSource else { return nil }
        return state.reorder(moving: source.runID, to: row)
    }

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
        let grip = QueueDragHandle(runID: message.id)
        let cell = QueuedMessageRow(grip: grip, send: send, edit: edit, remove: remove)
        grip.dragPreview = cell
        grip.onBegin = { [weak self] source in
            guard let self, canReorder, state.messages.contains(where: { $0.id == source.runID }) else { return false }
            dragSource = source
            return true
        }
        grip.onEnd = { [weak self] source in
            if self?.dragSource === source { self?.invalidateDrag() }
        }
        fill(row([grip, preview, detail, NSView(), send, edit, remove], spacing: 6), in: cell, inset: 2)
        updateControls(cell, for: message)
        return cell
    }

    private func updateControls(_ cell: QueuedMessageRow, for message: QueuedMessage) {
        cell.grip.isEnabled = canReorder
        cell.grip.setAccessibilityCustomActions(canReorder ? [
            moveAction("Move Up", runID: message.id, direction: -1),
            moveAction("Move Down", runID: message.id, direction: 1),
        ].compactMap { $0 } : [])
        cell.send.isHidden = !canOperate || state.delivery(for: message) == nil
        cell.send.isEnabled = !busy
        cell.edit.isHidden = !canOperate || !message.editable
        cell.edit.isEnabled = canEdit && !busy
        cell.remove.isHidden = !canOperate
        cell.remove.isEnabled = !busy
    }

    private func moveAction(_ name: String, runID: String, direction: Int) -> NSAccessibilityCustomAction? {
        guard let index = state.messages.firstIndex(where: { $0.id == runID }),
              state.reorder(moving: runID, to: index + direction + (direction > 0 ? 1 : 0)) != nil else { return nil }
        return NSAccessibilityCustomAction(name: name) { [weak self] in
            guard let self, canReorder, let index = state.messages.firstIndex(where: { $0.id == runID }),
                  let move = state.reorder(moving: runID, to: index + direction + (direction > 0 ? 1 : 0)) else { return false }
            onAction?(.reorder(move))
            return true
        }
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
    let grip: QueueDragHandle
    let send: ActionButton
    let edit: ActionButton
    let remove: ActionButton

    init(grip: QueueDragHandle, send: ActionButton, edit: ActionButton, remove: ActionButton) {
        self.grip = grip
        self.send = send
        self.edit = edit
        self.remove = remove
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class QueueDragHandle: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.t3code.appkit.queued-message")
    let runID: String
    weak var dragPreview: NSView?
    var onBegin: ((QueueDragHandle) -> Bool)?
    var onEnd: ((QueueDragHandle) -> Void)?
    private var dragging = false
    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            setAccessibilityEnabled(isEnabled)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    init(runID: String) {
        self.runID = runID
        super.init(frame: .zero)
        toolTip = "Drag to reorder"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reorder queued message")
        setAccessibilityEnabled(false)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        WorkspaceStyle.bubble.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        (isEnabled ? WorkspaceStyle.secondary : WorkspaceStyle.muted).setFill()
        let dots = NSBezierPath()
        for x: CGFloat in [-2.25, 2.25] {
            for y: CGFloat in [-4.25, 0, 4.25] {
                dots.appendOval(in: NSRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2))
            }
        }
        dots.fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !dragging, window != nil else { return }
        let preview = dragPreview ?? self
        guard let representation = preview.bitmapImageRepForCachingDisplay(in: preview.bounds), onBegin?(self) == true else { return }
        preview.cacheDisplay(in: preview.bounds, to: representation)
        let image = NSImage(size: preview.bounds.size)
        image.addRepresentation(representation)
        let item = NSPasteboardItem()
        item.setString(runID, forType: Self.pasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(convert(preview.bounds, from: preview), contents: image)
        dragging = true
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        onEnd?(self)
    }
}
