import AppKit

@MainActor
final class ScheduledDeliveriesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSTextView()
    private var rows: [Wire] = []
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var updating = false
    var load: ((String?) async throws -> Wire)?
    var onClose: (() -> Void)?

    init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 513), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Webhook Deliveries"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 510, height: 380)
        super.init(window: window)
        let root = Surface(WorkspaceStyle.navigation)
        window.contentView = root
        let columns: [(String, String, CGFloat)] = [("time", "Received", 196), ("outcome", "Outcome", 147), ("method", "Method", 74), ("bytes", "Bytes", 73)]
        for (id, name, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = name
            column.width = width
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.style = .plain
        table.rowHeight = 28
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Webhook Deliveries")
        table.dataSource = self
        table.delegate = self
        let deliveries = scroller(for: table)
        deliveries.heightAnchor.constraint(equalToConstant: 147).isActive = true
        detail.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = WorkspaceStyle.ink
        detail.textContainerInset = NSSize(width: 5, height: 5)
        detail.setAccessibilityLabel("Webhook Delivery Details")
        let refresh = ActionButton("Refresh Deliveries", symbol: "arrow.clockwise", iconOnly: true, style: .subtle) { [weak self] in self?.refresh() }
        let close = ActionButton("Done") { [weak self] in self?.finish() }
        close.keyEquivalent = "\u{1b}"
        let heading = row([label(title, size: 14, weight: .semibold, color: WorkspaceStyle.ink), NSView(), refresh])
        let layout = column([heading, deliveries, textScroller(detail), row([NSView(), close])], spacing: 10, alignment: .width)
        fill(layout, in: root, inset: 13)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        refresh()
    }

    private func refresh() {
        guard let load else { return }
        listTask?.cancel()
        detailTask?.cancel()
        detail.string = "Loading deliveries…"
        listTask = Task {
            do {
                let list = try await load(nil)
                guard !Task.isCancelled else { return }
                rows = list["deliveries"].array
                updating = true
                table.reloadData()
                if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                updating = false
                if rows.isEmpty { detail.string = "No deliveries yet." }
                else { loadDetail() }
            } catch { if !Task.isCancelled { detail.string = error.localizedDescription } }
        }
    }

    private func loadDetail() {
        detailTask?.cancel()
        guard let load, rows.indices.contains(table.selectedRow), let id = rows[table.selectedRow]["id"].string else {
            detail.string = "Select a delivery to inspect it."
            return
        }
        detail.string = "Loading delivery…"
        detailTask = Task {
            do {
                let result = try await load(id)
                guard !Task.isCancelled else { return }
                let delivery = result["delivery"]
                let headers = (delivery["headers"].object ?? [:]).sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value.string ?? "")" }.joined(separator: "\n")
                var sections = ["\(delivery["method"].string ?? "")  \(outcome(delivery))"]
                if delivery["signatureVerified"].bool == true { sections.append("Signature verified") }
                if let error = delivery["error"].string { sections.append(error) }
                let missing = delivery["missingFields"].array.compactMap(\.string)
                if !missing.isEmpty { sections.append("Missing fields\n" + missing.joined(separator: ", ")) }
                if let query = delivery["query"].string, !query.isEmpty { sections.append("Query\n" + query) }
                if !headers.isEmpty { sections.append("Headers\n" + headers) }
                if let body = delivery["body"].string { sections.append("Body\n" + body) }
                if delivery["bodyTruncated"].bool == true { sections.append("The host truncated the recorded body.") }
                if let prompt = delivery["renderedPrompt"].string { sections.append("Rendered prompt\n" + prompt) }
                detail.string = sections.joined(separator: "\n\n")
                detail.scrollRangeToVisible(NSRange(location: 0, length: 0))
            } catch { if !Task.isCancelled { detail.string = error.localizedDescription } }
        }
    }

    private func outcome(_ value: Wire) -> String {
        if value["pendingWindow"].bool == true { return "Coalescing" }
        return value["outcome"].string?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating { loadDetail() }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        let value: String = switch tableColumn?.identifier.rawValue {
        case "time": WorkspaceStyle.date(row["receivedAt"].string).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        case "outcome": outcome(row)
        case "method": row["method"].string ?? "—"
        default: row["bodyBytes"].int.map { $0.formatted() } ?? "—"
        }
        let cell = NSTableCellView()
        let text = label(value, size: 12, color: WorkspaceStyle.secondary)
        fill(text, in: cell, inset: 4)
        cell.textField = text
        return cell
    }

    private func finish() {
        listTask?.cancel()
        detailTask?.cancel()
        if let window { window.sheetParent?.endSheet(window) }
        onClose?()
    }
}
