import AppKit

@MainActor
final class ComposerCommandSuggestions: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private final class SuggestionTable: NSTableView {
        override var acceptsFirstResponder: Bool { false }
    }

    private final class SuggestionRow: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            WorkspaceStyle.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    private let table = SuggestionTable()
    private let status = label(size: 11.5, color: WorkspaceStyle.muted)
    private var scroll: NSScrollView!
    private var height: NSLayoutConstraint!
    private var items: [ComposerCommandItem] = []
    var onPick: ((ComposerCommandItem) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let tableColumn = NSTableColumn(identifier: .init("suggestion"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 27
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Composer Suggestions")
        scroll = scroller(for: table)
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh
        height.isActive = true
        status.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let surface = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 11)
        fill(column([scroll, status], spacing: 0, alignment: .width), in: surface, inset: 5)
        fill(surface, in: self)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(_ items: [ComposerCommandItem], status message: String) {
        isHidden = false
        status.stringValue = message
        status.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        guard self.items != items else { return }
        let previous = self.items.indices.contains(table.selectedRow) ? self.items[table.selectedRow] : nil
        self.items = items
        height.constant = CGFloat(min(5, items.count)) * table.rowHeight
        table.reloadData()
        if !items.isEmpty { select(previous.flatMap { items.firstIndex(of: $0) } ?? 0) }
    }

    func dismiss() {
        isHidden = true
        if !items.isEmpty {
            items.removeAll()
            table.reloadData()
        }
    }

    func move(_ delta: Int) -> Bool {
        guard !isHidden, !items.isEmpty else { return false }
        let current = max(0, table.selectedRow)
        select((current + delta + items.count) % items.count)
        return true
    }

    func accept() -> Bool {
        guard !isHidden, items.indices.contains(table.selectedRow) else { return false }
        onPick?(items[table.selectedRow])
        return true
    }

    private func select(_ index: Int) {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    @objc private func clicked() {
        if items.indices.contains(table.clickedRow) { onPick?(items[table.clickedRow]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SuggestionRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let item = items[index]
        let title = label(item.title, size: 12, weight: .medium, color: WorkspaceStyle.ink)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let detail = label(item.detail, size: 11, color: WorkspaceStyle.muted)
        detail.toolTip = item.detail
        let cell = NSTableCellView()
        fill(row([title, detail, NSView()], spacing: 9), in: cell, inset: 4)
        return cell
    }
}
