import AppKit

@MainActor
final class TimelineView: NSView, NSTableViewDelegate, NSTableViewDataSource {
    enum CitationReveal { case missing, changed, shown }
    private struct ChangedFile: Hashable {
        let title: String
        let reference: WorkspaceFileReference?
    }

    private struct FileChange: Equatable {
        let entry: TimelineEntry
        let paths: [ChangedFile]

        var detailKey: FileDetailKey {
            .init(threadID: entry.sourceThreadID, itemID: entry.id, revision: entry.value["updatedAt"].string)
        }
    }

    private struct FileDetailKey: Hashable {
        let threadID: String
        let itemID: String
        let revision: String?
    }

    private struct GuestRow: Equatable {
        let shareID: String
        let name: String
        let message: GuestMessage
        let canResolve: Bool
        let busy: Bool
    }

    private enum Content: Equatable {
        case prompt(TimelineEntry)
        case guest(GuestRow)
        case reply(TimelineEntry)
        case webPage(ConversationPage)
        case plan(TimelineEntry, ProposedPlan)
        case fork(TimelineEntry)
        case freshSession
        case thoughts([TimelineEntry])
        case work([TimelineEntry])
        case files([FileChange])
        case credit(TimelineEntry, provider: String, model: String?)
    }

    private struct EntryRow: Equatable {
        let id: String
        let content: Content
        var endsTurn = false

        var gap: CGFloat { endsTurn ? 16 : 0 }

        var findID: String? {
            switch content {
            case .prompt(let entry), .reply(let entry), .plan(let entry, _): entry.findID
            default: nil
            }
        }
    }

    private struct PageLayout: Equatable {
        let reference: ConversationPage
        let width: CGFloat
        let zoom: CGFloat
        let height: CGFloat?
    }

    private enum ScrollPosition {
        case bottom
        case row(id: String, offset: CGFloat)
    }

    private final class CachedPage {
        let reference: ConversationPage
        let scope: AttachmentScope?
        let card: HtmlReplyCard

        init(reference: ConversationPage, scope: AttachmentScope?, card: HtmlReplyCard) {
            self.reference = reference
            self.scope = scope
            self.card = card
        }
    }

    private let table = NSTableView()
    private let scroll = TimelineScrollView()
    private var rows: [EntryRow] = []
    private var expanded = Set<String>()
    private var rendered: [String: NSAttributedString] = [:]
    private var renderingRows: [TranscriptRenderingRequest: Set<String>] = [:]
    private var pageLayouts: [String: PageLayout] = [:]
    private let pageCards = NSCache<NSString, CachedPage>()
    private var appAwaitingUser = false
    private var fileDetails: [FileDetailKey: Wire] = [:]
    private var fileLoads: [String: Task<Void, Never>] = [:]
    private var fileErrors: [String: String] = [:]
    private var columnWidth: CGFloat = 0
    private var resizePosition: ScrollPosition?
    private var findQuery = ""
    private var findMatch: ThreadFindMatch?
    private var forkEnabled = false
    private var rewindAvailable = false
    private var rewindEnabled = false
    var onFork: ((TimelineEntry) -> Void)?
    var onRewind: ((TimelineEntry) -> Void)?
    var onOpenThread: ((String) -> Void)?
    var onCite: ((AssistantCitation) -> Void)?
    var onOpenCitation: ((AssistantCitation) -> Void)?
    var citationEnvironmentID: String?
    private var citationPopup: NSPopover?
    var onPlanAction: ((TimelineEntry, ProposedPlan.Action) -> Void)?
    var onOpenAttachment: ((TimelineEntry, ChatAttachment) -> Void)?
    var onOpenGuestAttachment: ((String, GuestMessage, ChatAttachment) -> Void)?
    var onResolveGuestMessage: ((String, String, GuestMessage.Decision) -> Void)?
    var onOpenFile: ((WorkspaceFileReference, WorkspaceFileContext) -> Void)?
    private(set) var fileContext: WorkspaceFileContext?
    var attachmentStore: AttachmentStore?
    private var attachmentScope: AttachmentScope?
    weak var readingColumn: NSView?
    var canSavePlanToWorkspace = false
    var loadFileDetail: (@MainActor (TimelineEntry) async throws -> Wire)?
    var loadWebPage: (@MainActor (ConversationPage, AttachmentScope) async throws -> AttachmentFile)?
    var makeMcpAppSession: ((McpAppPage, AttachmentScope) -> McpAppSession?)?
    var hasContent: Bool { !rows.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Conversation")
        pageCards.countLimit = 6
        fill(scroller(for: table, using: scroll), in: self)
        NotificationCenter.default.addObserver(self, selector: #selector(mathRenderingChanged(_:)),
                                               name: TranscriptMathRendering.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateTranscript()
    }

    @objc private func mathRenderingChanged(_ notification: Notification) { invalidateTranscript() }

    private func invalidateTranscript() {
        rendered.removeAll()
        reload(IndexSet(rows.indices.filter {
            if case .webPage = rows[$0].content { return false }
            return true
        }))
    }

    func reset() {
        citationPopup?.close()
        citationPopup = nil
        attachmentStore?.reset()
        fileContext = nil
        findQuery = ""
        findMatch = nil
        expanded.removeAll()
        for task in fileLoads.values { task.cancel() }
        fileLoads.removeAll()
        fileErrors.removeAll()
        fileDetails.removeAll()
        rendered.removeAll()
        renderingRows.removeAll()
        resizePosition = nil
        pageLayouts.removeAll()
        pageCards.removeAllObjects()
        rows.removeAll()
        table.reloadData()
    }

    func setAttachmentScope(_ scope: AttachmentScope?) {
        guard attachmentScope != scope else { return }
        attachmentScope = scope
        attachmentStore?.setScope(scope)
        pageCards.removeAllObjects()
        let messages = IndexSet(rows.indices.filter {
            switch rows[$0].content {
            case .prompt, .reply, .guest, .webPage: true
            case .work(let entries): expanded.contains(rows[$0].id) && entries.contains { !$0.attachments.isEmpty }
            default: false
            }
        })
        if !messages.isEmpty { table.reloadData(forRowIndexes: messages, columnIndexes: IndexSet(integer: 0)) }
    }

    func setAppAwaitingUser(_ awaitingUser: Bool) {
        guard appAwaitingUser != awaitingUser else { return }
        appAwaitingUser = awaitingUser
        for row in rows {
            if case .webPage(.mcp) = row.content {
                pageCards.object(forKey: row.id as NSString)?.card.setAwaitingUser(awaitingUser)
            }
        }
    }

    func setForkEnabled(_ enabled: Bool) {
        guard forkEnabled != enabled else { return }
        forkEnabled = enabled
        let credits = IndexSet(rows.indices.filter {
            if case .credit = rows[$0].content { return true }
            return false
        })
        if !credits.isEmpty { table.reloadData(forRowIndexes: credits, columnIndexes: IndexSet(integer: 0)) }
    }

    func setRewind(available: Bool, enabled: Bool) {
        guard rewindAvailable != available || rewindEnabled != enabled else { return }
        rewindAvailable = available
        rewindEnabled = enabled
        let prompts = IndexSet(rows.indices.filter {
            if case .prompt(let entry) = rows[$0].content { return entry.canRewind }
            return false
        })
        if !prompts.isEmpty { table.reloadData(forRowIndexes: prompts, columnIndexes: IndexSet(integer: 0)) }
    }

    func clearFind() {
        guard !findQuery.isEmpty else { return }
        findQuery = ""
        findMatch = nil
        let plans = IndexSet(rows.indices.filter {
            if case .plan = rows[$0].content { return true }
            return false
        })
        for index in plans { rendered.removeValue(forKey: rows[index].id) }
        table.noteHeightOfRows(withIndexesChanged: plans)
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0 {
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                             columnIndexes: IndexSet(integer: 0))
        }
    }

    func revealFindMatch(_ match: ThreadFindMatch, query: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.findID == match.entryID }) else { return false }
        let previous = findMatch?.entryID
        var refresh = IndexSet(integer: index)
        if findQuery != query {
            for row in rows {
                if case .plan = row.content { rendered.removeValue(forKey: row.id) }
            }
            refresh.formUnion(IndexSet(rows.indices.filter {
                if case .plan = rows[$0].content { return true }
                return false
            }))
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 { refresh.insert(integersIn: visible.location..<NSMaxRange(visible)) }
        } else if let previous, let old = rows.firstIndex(where: { $0.findID == previous }) {
            refresh.insert(old)
        }
        findMatch = match
        findQuery = query
        if case .plan = rows[index].content {
            expanded.insert(rows[index].id)
            rendered.removeValue(forKey: rows[index].id)
        }
        table.noteHeightOfRows(withIndexesChanged: refresh)
        table.reloadData(forRowIndexes: refresh, columnIndexes: IndexSet(integer: 0))
        table.scrollRowToVisible(index)
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true),
           let text = findTextView(in: cell) {
            let selection = TranscriptSelection(text.attributedString())
            let ranges = ThreadFindText.ranges(of: query, in: selection.text)
            let occurrence = match.occurrence - planTitleMatches(rows[index], query: query)
            if ranges.indices.contains(occurrence) {
                text.scrollRangeToVisible(selection.displayedRange(for: ranges[occurrence]))
            }
        }
        return true
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    func revealCitation(_ citation: AssistantCitation) -> CitationReveal {
        guard let index = rows.firstIndex(where: { row in
            if case .reply(let entry) = row.content { return entry.findID == citation.messageID && entry.sourceThreadID == citation.threadID }
            return false
        }) else { return .missing }
        table.scrollRowToVisible(index)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true), let text = findTextView(in: cell) else { return .changed }
        let selection = TranscriptSelection(text.attributedString())
        guard let sourceRange = citation.range(in: selection.text) else { return .changed }
        let range = selection.displayedRange(for: sourceRange)
        text.window?.makeFirstResponder(text)
        text.setSelectedRange(range)
        text.scrollRangeToVisible(range)
        return .shown
    }

    func render(_ entries: [TimelineEntry], runModels: [String: Wire], activeRunIDs: Set<String>, providers: [Provider], workspacePath: String?,
                fileContext: WorkspaceFileContext? = nil, guestShare: GuestShare? = nil,
                canResolveGuestMessages: Bool = false, busyGuestMessages: Set<String> = []) {
        let contextChanged = self.fileContext != fileContext
        self.fileContext = fileContext
        var next = makeRows(entries, runModels: runModels, activeRunIDs: activeRunIDs, providers: providers, workspacePath: workspacePath)
        if let guestShare {
            for message in guestShare.pending {
                let row = GuestRow(shareID: guestShare.id, name: guestShare.guestName ?? "Guest", message: message,
                                   canResolve: canResolveGuestMessages, busy: busyGuestMessages.contains(message.id))
                next.append(EntryRow(id: "guest/\(guestShare.id)/\(message.id)", content: .guest(row)))
            }
        }
        guard contextChanged || rows != next else { return }
        let position = scrollPosition
        let previous = rows
        rows = next
        let oldPageIDs = previous.compactMap { row in
            if case .webPage = row.content { return row.id }
            return nil
        }
        if !oldPageIDs.isEmpty {
            let retained = Set(next.compactMap { row in
                if case .webPage = row.content { return row.id }
                return nil
            })
            for id in oldPageIDs where !retained.contains(id) {
                pageLayouts.removeValue(forKey: id)
                pageCards.removeObject(forKey: id as NSString)
            }
        }
        let common = zip(previous, next).prefix { $0.id == $1.id }.count
        if contextChanged {
            rendered.removeAll()
            table.reloadData()
        } else if common == previous.count && next.count >= previous.count {
            let changed = IndexSet((0..<common).filter { previous[$0] != next[$0] })
            for index in changed { rendered.removeValue(forKey: next[index].id) }
            if next.count > common {
                table.insertRows(at: IndexSet(integersIn: common..<next.count), withAnimation: [])
            }
            reload(changed)
        } else {
            let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let stable = Set(next.lazy.filter { old[$0.id] == $0 }.map(\.id))
            rendered = rendered.filter { stable.contains($0.key) }
            table.reloadData()
        }
        restoreScrollPosition(position)
    }

    private var scrollPosition: ScrollPosition? {
        let visible = scroll.contentView.bounds
        if rows.isEmpty || table.bounds.maxY - visible.maxY < 48 { return .bottom }
        let top = table.row(at: NSPoint(x: 1, y: visible.minY + 1))
        guard rows.indices.contains(top) else { return nil }
        return .row(id: rows[top].id, offset: visible.minY - table.rect(ofRow: top).minY)
    }

    private func restoreScrollPosition(_ position: ScrollPosition?) {
        guard let position, !rows.isEmpty else { return }
        let clip = scroll.contentView
        let y: CGFloat
        switch position {
        case .bottom:
            y = table.rect(ofRow: rows.count - 1).maxY - clip.bounds.height
        case .row(let id, let offset):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            let row = table.rect(ofRow: index)
            y = row.minY + min(offset, max(0, row.height - 1))
        }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
    }

    private func makeRows(_ entries: [TimelineEntry], runModels: [String: Wire], activeRunIDs: Set<String>, providers: [Provider],
                          workspacePath: String?) -> [EntryRow] {
        var result: [EntryRow] = []
        var work: [TimelineEntry] = []
        var thoughts: [TimelineEntry] = []
        var files: [FileChange] = []
        var lastReply: TimelineEntry?
        var lastRun: String?
        var turnStart = 0

        func appendWork() {
            guard let first = work.first else { return }
            result.append(EntryRow(id: first.id + "/work", content: .work(work)))
            work.removeAll()
        }

        func appendThoughts() {
            guard let first = thoughts.first else { return }
            result.append(EntryRow(id: first.id + "/thoughts", content: .thoughts(thoughts)))
            thoughts.removeAll()
        }

        func finishTurn() {
            appendThoughts()
            appendWork()
            if let first = files.first {
                result.append(EntryRow(id: first.entry.id + "/files", content: .files(files)))
                files.removeAll()
            }
            if let reply = lastReply, reply.value["streaming"].bool != true,
               reply.value["runId"].string.map(activeRunIDs.contains) != true {
                let selection = reply.value["runId"].string.flatMap { runModels[$0] } ?? .null
                let instance = selection["instanceId"].string ?? selection["provider"].string
                let provider = providers.first { $0.id == instance }
                let slug = selection["model"].string
                let model = provider?.models.first { $0.slug == slug }?.name ?? slug
                result.append(EntryRow(id: reply.id + "/credit",
                                       content: .credit(reply, provider: provider?.name ?? instance ?? "Agent", model: model)))
            }
            if result.count > turnStart { result[result.count - 1].endsTurn = true }
            lastReply = nil
            lastRun = nil
            turnStart = result.count
        }

        for entry in entries {
            if entry.type == "checkpoint" { continue }
            if entry.type == "fork" {
                finishTurn()
                result.append(EntryRow(id: entry.id, content: .fork(entry)))
                turnStart = result.count
                continue
            }
            if entry.type == "user_message" {
                finishTurn()
                if entry.value["freshContext"].bool == true {
                    result.append(EntryRow(id: entry.id + "/session", content: .freshSession))
                }
                result.append(EntryRow(id: entry.id, content: .prompt(entry)))
                turnStart = result.count
                continue
            }
            if let run = entry.value["runId"].string {
                if let lastRun, lastRun != run { finishTurn() }
                lastRun = run
            }
            if entry.type == "reasoning" {
                if thoughtIsLive(entry) || hasThoughtText(entry) {
                    appendWork()
                    thoughts.append(entry)
                }
                continue
            }
            appendThoughts()
            switch entry.type {
            case "assistant_message":
                appendWork()
                result.append(EntryRow(id: entry.id, content: .reply(entry)))
                lastReply = entry
            case "dynamic_tool":
                if let page = HtmlReplyReference(toolItem: entry.value) {
                    appendWork()
                    result.append(EntryRow(id: entry.id, content: .webPage(.html(page))))
                } else if let app = McpAppPage(entry) {
                    appendWork()
                    result.append(EntryRow(id: entry.id, content: .webPage(.mcp(app))))
                } else { work.append(entry) }
            case "proposed_plan":
                appendWork()
                result.append(EntryRow(id: entry.id, content: .plan(entry, ProposedPlan(markdown: entry.value["markdown"].string ?? ""))))
            case "file_change":
                let paths = entry.value["changes"].array.compactMap { $0["path"].string }
                let names = paths.isEmpty ? entry.value["fileName"].string.map { [$0] } ?? [] : paths
                let changes = names.isEmpty ? [ChangedFile(title: entry.value["title"].string ?? "Changed file", reference: nil)] :
                    names.map { changedFile($0, in: workspacePath) }
                files.append(FileChange(entry: entry, paths: changes))
            default: work.append(entry)
            }
        }
        finishTurn()
        return result
    }

    private func changedFile(_ path: String, in workspacePath: String?) -> ChangedFile {
        let reference = workspacePath.flatMap { WorkspaceFileReference(changedPath: path, root: $0) }
        let title: String
        switch reference {
        case .file(.workspace(let relative), _): title = relative
        case .file(.host(let absolute), _): title = absolute
        default: title = path
        }
        return .init(title: title, reference: reference)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize, !rows.isEmpty, resizePosition == nil { resizePosition = scrollPosition }
        super.setFrameSize(newSize)
        if resizePosition != nil { needsLayout = true }
    }

    override func layout() {
        let position = resizePosition ?? scrollPosition
        let resized = resizePosition != nil
        resizePosition = nil
        super.layout()
        if let width = readingColumn?.bounds.width, width > 38 { scroll.readingWidth = width - 38 }
        let width = table.tableColumns[0].width
        let reflow = abs(columnWidth - width) > 1
        if reflow {
            columnWidth = width
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: rows.indices))
        }
        if resized || reflow { restoreScrollPosition(position) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        let item = rows[index]
        let width = table.tableColumns[0].width
        let readingWidth = max(100, width)
        switch item.content {
        case .prompt(let entry):
            return promptHeight(body(item), attachments: messageAttachments(entry), width: width, byline: entry.guest != nil)
        case .guest(let guest):
            return promptHeight(body(item), attachments: attachmentStore == nil ? [] : guest.message.attachments,
                                width: width, byline: true, actions: guest.canResolve)
        case .reply(let entry):
            let attachments = messageAttachments(entry)
            return measuredHeight(body(item), width: readingWidth) + 14 + item.gap +
                MessageAttachmentsView.height(for: attachments) + (attachments.isEmpty ? 0 : 8)
        case .webPage(let reference):
            let width = max(80, readingWidth - HtmlReplyCard.horizontalInsets)
            let layout = pageLayout(item.id, reference: reference)
            let live = layout.flatMap { abs($0.width - width) <= 2 ? $0.height : nil }
            return reference.frameHeight(width: width, zoom: layout?.zoom ?? 1, liveHeight: live) + HtmlReplyCard.chromeHeight + 8 + item.gap
        case .credit:
            return 23 + item.gap
        case .fork:
            return 34
        case .freshSession:
            return 26
        case .files(let changes):
            let preview = min(filePaths(changes).count, 4)
            let detail = expanded.contains(item.id) ? measuredHeight(body(item), width: max(80, width - 20)) + 4 : 0
            return 50 + CGFloat(preview * 22) + detail + item.gap
        case .plan(_, let plan):
            return measuredHeight(body(item), width: max(80, width - 28)) + (plan.canCollapse ? 102 : 68) + item.gap
        case .work(let entries):
            guard expanded.contains(item.id) else { return 30 + item.gap }
            let files = entries.reduce(CGFloat(0)) { height, entry in
                let attachments = messageAttachments(entry)
                return height + (attachments.isEmpty ? 0 : MessageAttachmentsView.height(for: attachments) + 4)
            }
            return 35 + measuredHeight(body(item), width: readingWidth) + files + item.gap
        case .thoughts:
            let detail = expanded.contains(item.id) ? measuredHeight(body(item), width: readingWidth) + 5 : 0
            return 30 + detail + item.gap
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let item = rows[index]
        let cell = NSTableCellView()
        if case .freshSession = item.content {
            let icon = WorkspaceStyle.icon("arrow.counterclockwise", size: 11, tint: WorkspaceStyle.muted)
            fill(row([icon, label("New session", size: 11.5, color: WorkspaceStyle.muted), NSView()], spacing: 6), in: cell, inset: 3)
            return cell
        }
        if case .fork(let entry) = item.content {
            let source = entry.value["source"]
            let isRunFork = source["type"].string == "run"
            let title = isRunFork ? "Forked from conversation" : "Conversation fork"
            let icon = WorkspaceStyle.icon("arrow.triangle.branch", size: 12, tint: WorkspaceStyle.muted)
            var elements: [NSView] = [icon, label(title, size: 11.5, color: WorkspaceStyle.muted), NSView()]
            if let id = (isRunFork ? source["threadId"] : entry.value["targetThreadId"]).string {
                elements.append(ActionButton(isRunFork ? "Open Source Conversation" : "Open Fork",
                                             symbol: "arrow.up.right", style: .subtle) { [weak self] in self?.onOpenThread?(id) })
            }
            fill(row(elements, spacing: 7), in: cell, inset: 4)
            return cell
        }
        if case .prompt(let entry) = item.content {
            let content = highlightedBody(item)
            var pieces: [NSView] = []
            let name = entry.guest?.name
            if let name { pieces.append(guestByline(name, pending: false)) }
            let clipboard = citationEnvironmentID.map {
                TerminalContextClipboard.Source(environmentID: $0, threadID: entry.sourceThreadID, messageID: entry.findID)
            }
            let bubble = promptBubble(content, author: name ?? "You", pending: false, terminalClipboardSource: clipboard)
            if let bubble { pieces.append(bubble) }
            if let attachments = attachmentView(entry) { pieces.append(attachments) }
            placePrompt(pieces, in: cell)
            if rewindAvailable && entry.canRewind, let anchor = bubble ?? pieces.last {
                let edit = ActionButton("Edit from here", symbol: "pencil", iconOnly: true, style: .subtle) { [weak self] in
                    self?.onRewind?(entry)
                }
                edit.isEnabled = rewindEnabled
                cell.addSubview(edit)
                edit.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    edit.widthAnchor.constraint(equalToConstant: 23), edit.heightAnchor.constraint(equalToConstant: 22),
                    edit.trailingAnchor.constraint(equalTo: anchor.leadingAnchor, constant: -6),
                    edit.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
                ])
            }
            return cell
        }
        if case .guest(let guest) = item.content {
            var pieces: [NSView] = [guestByline(guest.name, pending: true)]
            if let bubble = promptBubble(body(item), author: guest.name, pending: true) { pieces.append(bubble) }
            if let attachments = attachmentView(guest.message.attachments, onOpen: { [weak self] attachment in
                self?.onOpenGuestAttachment?(guest.shareID, guest.message, attachment)
            }) { pieces.append(attachments) }
            if guest.canResolve { pieces.append(guestActions(guest)) }
            placePrompt(pieces, in: cell)
            return cell
        }

        let content: NSView
        switch item.content {
        case .reply(let entry):
            let text = textView(highlightedBody(item), accessibilityLabel: "Agent response")
            text.onQuoteSelection = { [weak self] rendered, range in
                guard let self, let environmentID = citationEnvironmentID,
                      let citation = AssistantCitation.selection(environmentID: environmentID, threadID: entry.sourceThreadID,
                                                                  messageID: entry.findID, rendered: rendered, range: range) else { return }
                onCite?(citation)
            }
            if let attachments = attachmentView(entry) {
                let holder = NSView()
                holder.addSubview(attachments)
                attachments.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    attachments.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                    attachments.topAnchor.constraint(equalTo: holder.topAnchor), attachments.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                    attachments.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor, multiplier: 0.84),
                ])
                content = column([text, holder], spacing: 8, alignment: .width)
            } else { content = text }
        case .webPage(let reference):
            content = pageCard(reference, id: item.id)
        case .plan(let entry, let plan):
            content = planCard(item, entry: entry, plan: plan)
        case .work(let entries):
            let attachments = expanded.contains(item.id) ? entries.compactMap(attachmentView) : []
            content = expandable(item, header: workHeader(item, entries: entries), attachments: attachments)
        case .thoughts(let entries):
            content = thoughtRow(item, entries: entries)
        case .files(let changes):
            content = fileCard(item, changes: changes)
        case .credit(let entry, let provider, let model):
            content = credit(entry, provider: provider, model: model)
        case .prompt, .guest, .fork, .freshSession: return cell
        }
        cell.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4 - item.gap),
        ])
        return cell
    }

    private func pageLayout(_ id: String, reference: ConversationPage) -> PageLayout? {
        guard let layout = pageLayouts[id], layout.reference == reference else { return nil }
        return layout
    }

    private func pageCard(_ reference: ConversationPage, id: String) -> HtmlReplyCard {
        let scope = attachmentScope
        let key = id as NSString
        if let cached = pageCards.object(forKey: key), cached.reference == reference, cached.scope == scope {
            cached.card.removeFromSuperview()
            return cached.card
        }
        let loader: (@MainActor () async throws -> AttachmentFile)?
        if let attachmentStore, let scope, let loadWebPage {
            loader = {
                try await attachmentStore.webPage(reference, scope: scope) { try await loadWebPage(reference, scope) }
            }
        } else { loader = nil }
        let appSession = reference.app.flatMap { app in scope.flatMap { makeMcpAppSession?(app, $0) } }
        let card = HtmlReplyCard(reference: reference, zoom: pageLayout(id, reference: reference)?.zoom ?? 1,
                                 appSession: appSession, loader: loader)
        card.setAwaitingUser(appAwaitingUser)
        pageCards.setObject(CachedPage(reference: reference, scope: scope, card: card), forKey: key)
        card.onMetrics = { [weak self] width, zoom, height in
            guard let self, attachmentScope == scope, width > 0, let index = rows.firstIndex(where: { $0.id == id }),
                  case .webPage(let current) = rows[index].content, current == reference else { return }
            let next = PageLayout(reference: reference, width: width, zoom: zoom, height: height)
            guard pageLayouts[id] != next else { return }
            let position = scrollPosition
            pageLayouts[id] = next
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
            restoreScrollPosition(position)
        }
        return card
    }

    private func workHeader(_ item: EntryRow, entries: [TimelineEntry]) -> NSView {
        let running = entries.contains { $0.value["streaming"].bool == true || $0.value["status"].string == "running" }
        return activityHeader(workTitle(entries), item: item, symbol: running ? "sparkle" : "hammer")
    }

    private func messageAttachments(_ entry: TimelineEntry) -> [ChatAttachment] {
        guard attachmentStore != nil else { return [] }
        return entry.attachments
    }

    private func attachmentView(_ entry: TimelineEntry) -> NSView? {
        attachmentView(messageAttachments(entry)) { [weak self] attachment in
            self?.onOpenAttachment?(entry, attachment)
        }
    }

    private func attachmentView(_ attachments: [ChatAttachment], onOpen: @escaping (ChatAttachment) -> Void) -> NSView? {
        guard let attachmentStore, !attachments.isEmpty else { return nil }
        let view = MessageAttachmentsView(attachments: attachments, store: attachmentStore, scope: attachmentScope, onOpen: onOpen)
        let natural = view.widthAnchor.constraint(equalToConstant: MessageAttachmentsView.width(for: attachments, available: .greatestFiniteMagnitude))
        natural.priority = .defaultHigh
        natural.isActive = true
        view.heightAnchor.constraint(equalToConstant: MessageAttachmentsView.height(for: attachments)).isActive = true
        return view
    }

    private func promptHeight(_ text: NSAttributedString, attachments: [ChatAttachment], width: CGFloat,
                              byline: Bool, actions: Bool = false) -> CGFloat {
        var heights: [CGFloat] = []
        if byline { heights.append(16) }
        if text.length > 0 { heights.append(measuredHeight(text, width: max(80, width * 0.84 - 24)) + 14) }
        if !attachments.isEmpty { heights.append(MessageAttachmentsView.height(for: attachments)) }
        if actions { heights.append(25) }
        return heights.reduce(14, +) + CGFloat(max(0, heights.count - 1)) * 8
    }

    private func promptBubble(_ text: NSAttributedString, author: String, pending: Bool,
                              terminalClipboardSource: TerminalContextClipboard.Source? = nil) -> NSView? {
        guard text.length > 0 else { return nil }
        let bubble = Surface(WorkspaceStyle.bubble, border: pending ? WorkspaceStyle.outline : nil, radius: 15)
        let maximumWidth = WorkspaceStyle.composerWidth * 0.84 - 24
        let natural = bubble.widthAnchor.constraint(equalToConstant: ceil(TranscriptText.bounds(text, width: maximumWidth).width) + 24)
        natural.priority = .defaultHigh
        natural.isActive = true
        let prompt = textView(text, accessibilityLabel: author)
        prompt.terminalClipboardSource = terminalClipboardSource
        fill(prompt, in: bubble)
        prompt.textContainerInset = NSSize(width: 12, height: 7)
        return bubble
    }

    private func placePrompt(_ pieces: [NSView], in cell: NSView) {
        let stack = column(pieces, spacing: 8, alignment: .trailing)
        cell.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5), stack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -9),
        ])
        for piece in pieces { piece.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, multiplier: 0.84).isActive = true }
    }

    private func guestByline(_ name: String, pending: Bool) -> NSView {
        let byline = label(pending ? "\(name) · Guest · Awaiting review" : "\(name) · Guest", size: 11.5,
                           weight: .medium, color: pending ? WorkspaceStyle.modelFocus : WorkspaceStyle.muted)
        byline.toolTip = byline.stringValue
        byline.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return byline
    }

    private func guestActions(_ guest: GuestRow) -> NSView {
        let dismiss = ActionButton("Dismiss", style: .subtle) { [weak self] in
            self?.onResolveGuestMessage?(guest.shareID, guest.message.id, .dismiss)
        }
        let send = ActionButton("Send to Agent", symbol: "arrow.up", style: .subtle) { [weak self] in
            self?.onResolveGuestMessage?(guest.shareID, guest.message.id, .send)
        }
        dismiss.isEnabled = !guest.busy
        send.isEnabled = !guest.busy
        let actions = row([dismiss, send], spacing: 5)
        actions.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return actions
    }

    private func activityHeader(_ title: String, item: EntryRow, symbol: String) -> NSView {
        let button = disclosure(title, item: item, symbol: symbol)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: WorkspaceStyle.muted,
        ])
        let header = row([button, NSView(), caret(item)], spacing: 7)
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return header
    }

    private func thoughtIsLive(_ entry: TimelineEntry) -> Bool {
        let status = entry.value["status"].string
        return status == "running" || ((status == nil || status == "pending") && entry.value["streaming"].bool == true)
    }

    private func hasThoughtText(_ entry: TimelineEntry) -> Bool {
        entry.value["text"].string?.contains(where: { !$0.isWhitespace }) == true
    }

    private func thoughtRow(_ item: EntryRow, entries: [TimelineEntry]) -> NSView {
        let title = entries.contains(where: thoughtIsLive) ? "Thinking…" : "Thoughts"
        if entries.contains(where: hasThoughtText) {
            return expandable(item, header: activityHeader(title, item: item, symbol: "brain"), accessibilityLabel: "Thinking details")
        }
        let header = row([WorkspaceStyle.icon("brain", size: 12, tint: WorkspaceStyle.muted),
                          label(title, size: 12.5, color: WorkspaceStyle.muted), NSView()], spacing: 6)
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return header
    }

    private func workTitle(_ entries: [TimelineEntry]) -> String {
        var reads = 0
        var commands = 0
        for entry in entries {
            if entry.value["title"].string?.hasPrefix("Read ") == true { reads += 1 }
            else if entry.type == "command_execution" { commands += 1 }
        }
        if reads > 0 || commands > 0 {
            let read = reads == 1 ? "Read 1 file" : "Read \(reads) files"
            let command = commands == 1 ? "ran 1 command" : "ran \(commands) commands"
            if reads == 0 { return command.prefix(1).uppercased() + command.dropFirst() }
            return commands == 0 ? read : "\(read) and \(command)"
        }
        if entries.count == 1, let entry = entries.first { return activity(entry).title }
        return "\(entries.count) activities"
    }

    private func filePaths(_ changes: [FileChange]) -> [ChangedFile] {
        var seen = Set<ChangedFile>()
        return changes.flatMap(\.paths).filter { seen.insert($0).inserted }
    }

    private func planCard(_ item: EntryRow, entry: TimelineEntry, plan: ProposedPlan) -> NSView {
        let badge = Surface(WorkspaceStyle.selection, radius: 4)
        fill(label("Plan", size: 10.5, weight: .medium, color: WorkspaceStyle.secondary), in: badge, inset: 4)
        let title = label(plan.title, size: 13, weight: .semibold, color: WorkspaceStyle.ink)
        title.attributedStringValue = highlighted(title.attributedStringValue, item: item)
        title.toolTip = plan.title
        let actions = ActionButton("Plan Actions", symbol: "ellipsis", iconOnly: true, style: .subtle) {}
        actions.actionBlock = { [weak self, weak actions] in
            guard let self, let actions else { return }
            planMenu(for: entry, in: actions)
        }
        actions.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let header = row([badge, title, NSView(), actions], spacing: 8)
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        var contents: [NSView] = [header, textView(highlightedBody(item), accessibilityLabel: "Proposed plan")]
        if plan.canCollapse {
            let open = expanded.contains(item.id) || !findQuery.isEmpty
            let expand = ActionButton(open ? "Collapse Plan" : "Expand Plan", symbol: open ? "chevron.up" : "chevron.down", style: .subtle) { [weak self] in
                self?.toggle(item.id)
            }
            expand.isEnabled = findQuery.isEmpty
            if !findQuery.isEmpty { expand.toolTip = "Close Find to collapse this plan" }
            let leading = NSView()
            let trailing = NSView()
            let footer = row([leading, expand, trailing])
            leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
            footer.heightAnchor.constraint(equalToConstant: 24).isActive = true
            contents.append(footer)
        }
        let card = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.outline, radius: 12)
        fill(column(contents, spacing: 10, alignment: .width), in: card, inset: 14)
        return card
    }

    private func planMenu(for entry: TimelineEntry, in anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in ProposedPlan.Action.allCases {
            let item = menuItem(action.title, target: self, action: #selector(performPlanAction(_:)))
            item.representedObject = (entry, action)
            item.isEnabled = action != .saveToWorkspace || canSavePlanToWorkspace
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func performPlanAction(_ item: NSMenuItem) {
        guard let (entry, action) = item.representedObject as? (TimelineEntry, ProposedPlan.Action) else { return }
        onPlanAction?(entry, action)
    }

    private func fileCard(_ item: EntryRow, changes: [FileChange]) -> NSView {
        let paths = filePaths(changes)
        let open = expanded.contains(item.id)
        let title = paths.count == 1 ? "1 changed file" : "\(paths.count) changed files"
        let button = disclosure(title, item: item, symbol: open ? "chevron.down" : "chevron.right")
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: WorkspaceStyle.ink,
        ])
        button.setAccessibilityHelp(open ? "Hide file diffs" : "Show file diffs")
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        var added = 0
        var removed = 0
        for change in changes {
            let value = change.entry.value
            let additions = value["additions"].int
            let deletions = value["deletions"].int
            let detail = fileDetails[change.detailKey] ?? value
            let patch = additions == nil || deletions == nil ? patchCounts(detail["diffStr"].string) : nil
            added += additions ?? patch?.added ?? 0
            removed += deletions ?? patch?.removed ?? 0
        }
        var heading: [NSView] = [button]
        if added > 0 { heading.append(label("+\(added)", size: 11.5, color: WorkspaceStyle.positive)) }
        if removed > 0 { heading.append(label("−\(removed)", size: 11.5, color: WorkspaceStyle.negative)) }
        heading.append(NSView())
        let header = row(heading, spacing: 6)
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        var content: [NSView] = [header]
        for path in paths.prefix(3) {
            let name = changedFileLabel(path)
            let file = row([WorkspaceStyle.icon("doc", size: 11, tint: WorkspaceStyle.muted), name, NSView()], spacing: 7)
            file.heightAnchor.constraint(equalToConstant: 18).isActive = true
            content.append(file)
        }
        if paths.count > 3 {
            let more = changedFilesMenu(Array(paths.dropFirst(3)))
            more.heightAnchor.constraint(equalToConstant: 18).isActive = true
            content.append(more)
        }
        if open { content.append(textView(body(item), accessibilityLabel: "File diffs")) }
        let card = Surface(WorkspaceStyle.navigation, border: WorkspaceStyle.line, radius: 12)
        fill(column(content, spacing: 4, alignment: .width), in: card, inset: 10)
        return card
    }

    private func changedFileLabel(_ path: ChangedFile) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        guard let context = fileContext, let reference = path.reference else {
            let name = label(path.title, size: 11.5, color: WorkspaceStyle.secondary)
            name.font = font
            name.toolTip = path.title
            return name
        }
        let button = ActionButton(path.title, style: .subtle) { [weak self] in self?.openFile(reference, context: context) }
        button.attributedTitle = NSAttributedString(string: path.title, attributes: [.font: font, .foregroundColor: WorkspaceStyle.secondary])
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = "Open \(path.title) in Files"
        return button
    }

    private func changedFilesMenu(_ paths: [ChangedFile]) -> NSView {
        let title = "\(paths.count) more"
        guard let context = fileContext, paths.contains(where: { $0.reference != nil }) else {
            return label(title, size: 11, color: WorkspaceStyle.muted)
        }
        let button = ActionButton(title, symbol: "chevron.down", style: .subtle) {}
        button.font = .systemFont(ofSize: 11)
        button.actionBlock = { [weak self, weak button] in
            guard let self, let button, fileContext == context else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for path in paths {
                let item = menuItem(path.title, target: self, action: #selector(openChangedFile(_:)))
                item.representedObject = path.reference.map { ($0, context) }
                item.isEnabled = path.reference != nil
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
        return row([button, NSView()])
    }

    @objc private func openChangedFile(_ item: NSMenuItem) {
        guard let (reference, context) = item.representedObject as? (WorkspaceFileReference, WorkspaceFileContext) else { return }
        openFile(reference, context: context)
    }

    private func openFile(_ reference: WorkspaceFileReference, context: WorkspaceFileContext) {
        guard context == fileContext else { return }
        onOpenFile?(reference, context)
    }

    private func patchCounts(_ patch: String?) -> (added: Int, removed: Int)? {
        guard let patch, patch.utf8.count <= 48_000 else { return nil }
        var added = 0
        var removed = 0
        var inHunk = false
        var hasHunk = false
        patch.enumerateLines { line, _ in
            if line.hasPrefix("@@") {
                inHunk = true
                hasHunk = true
            } else if line.hasPrefix("diff --git ") {
                inHunk = false
            } else if inHunk {
                if line.first == "+" { added += 1 }
                if line.first == "-" { removed += 1 }
            }
        }
        return hasHunk ? (added, removed) : nil
    }

    private func disclosure(_ title: String, item: EntryRow, symbol: String? = nil) -> ActionButton {
        let button = ActionButton(title, symbol: symbol, style: .subtle) { [weak self] in self?.toggle(item.id) }
        button.alignment = .left
        button.setAccessibilityHelp(expanded.contains(item.id) ? "Hide details" : "Show details")
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    private func caret(_ item: EntryRow) -> ActionButton {
        let open = expanded.contains(item.id)
        let symbol = open ? "chevron.down" : "chevron.right"
        let button = ActionButton(open ? "Hide details" : "Show details", symbol: symbol, iconOnly: true, style: .subtle) { [weak self] in
            self?.toggle(item.id)
        }
        button.image = WorkspaceStyle.symbol(symbol, size: 9)
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    private func expandable(_ item: EntryRow, header: NSView, accessibilityLabel: String? = nil, attachments: [NSView] = []) -> NSView {
        guard expanded.contains(item.id) else { return header }
        return column([header, textView(highlightedBody(item), accessibilityLabel: accessibilityLabel)] + attachments,
                      spacing: 4, alignment: .width)
    }

    private func credit(_ entry: TimelineEntry, provider: String, model: String?) -> NSView {
        let agent = label(provider, size: 11, weight: .medium, color: WorkspaceStyle.muted)
        var elements: [NSView] = [agent]
        if let model { elements.append(label(model, size: 11.5, color: WorkspaceStyle.muted)) }
        let copy = ActionButton("Copy reply", symbol: "document.on.document", iconOnly: true, style: .subtle) {
            guard let text = entry.value["text"].string else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copy.image = WorkspaceStyle.symbol("document.on.document", size: 9)
        copy.widthAnchor.constraint(equalToConstant: 20).isActive = true
        copy.heightAnchor.constraint(equalToConstant: 17).isActive = true
        elements.append(copy)
        if forkEnabled && entry.canFork {
            let fork = ActionButton("Fork from This Response", symbol: "arrow.triangle.branch", iconOnly: true, style: .subtle) { [weak self] in
                self?.onFork?(entry)
            }
            fork.image = WorkspaceStyle.symbol("arrow.triangle.branch", size: 11)
            fork.widthAnchor.constraint(equalToConstant: 20).isActive = true
            fork.heightAnchor.constraint(equalToConstant: 17).isActive = true
            elements.append(fork)
        }
        if let date = WorkspaceStyle.date(entry.value["completedAt"].string ?? entry.value["updatedAt"].string) {
            elements.append(label(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short),
                                  size: 11.5, color: WorkspaceStyle.muted))
        }
        elements.append(NSView())
        return row(elements, spacing: 6)
    }

    private func measuredHeight(_ body: NSAttributedString, width: CGFloat) -> CGFloat {
        max(18, ceil(TranscriptText.bounds(body, width: width).height))
    }

    private func textView(_ content: NSAttributedString, accessibilityLabel: String? = nil) -> TranscriptBodyView {
        let text = TranscriptBodyView()
        if let context = fileContext {
            text.onFileLink = { [weak self] reference in self?.openFile(reference, context: context) }
        }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.setTranscript(content)
        text.onCitation = { [weak self, weak text] citation, frame in
            guard let self, let text, text.window != nil else { return }
            citationPopup?.close()
            let popup = NSPopover()
            popup.behavior = .transient
            let card = AssistantCitationView(citation: citation, onSource: { [weak self] in self?.onOpenCitation?(citation) })
            card.onClose = { [weak popup] in popup?.close() }
            popup.contentViewController = card
            citationPopup = popup
            popup.show(relativeTo: frame, of: text, preferredEdge: .minY)
        }
        if let accessibilityLabel { text.setAccessibilityLabel(accessibilityLabel) }
        return text
    }

    private func body(_ item: EntryRow) -> NSAttributedString {
        if let existing = rendered[item.id] { return existing }
        let dark = TranscriptArtwork.isDark(effectiveAppearance)
        let content: NSAttributedString
        switch item.content {
        case .prompt(let entry), .reply(let entry):
            if let guest = entry.guest {
                content = guestText(guest.text)
                break
            }
            let isPrompt = entry.type == "user_message"
            let raw = entry.value["text"].string?.trimmingCharacters(in: .newlines) ?? ""
            let context = entry.value["context"]
            let display = isPrompt ? BrowserAnnotationContext.removingReferences(from: raw, context: context) : raw
            let text = isPrompt && !messageAttachments(entry).isEmpty ? QueuedMessage.recallableText(display) : display
            let parsed = TranscriptText.markdown(text, role: isPrompt ? .user : .assistant, fileRoot: fileContext?.root,
                                                 darkArtwork: dark, streaming: entry.value["streaming"].bool == true,
                                                 contextRecords: isPrompt ? context["records"].array : [])
            let notes = isPrompt ? BrowserAnnotationContext.comments(in: context) : []
            if notes.isEmpty { content = parsed }
            else {
                let message = NSMutableAttributedString(attributedString: parsed)
                for note in notes {
                    if message.length > 0 { message.append(NSAttributedString(string: "\n\n")) }
                    message.append(NSAttributedString(string: "Browser Region\n", attributes: [
                        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: WorkspaceStyle.muted,
                    ]))
                    message.append(NSAttributedString(string: note, attributes: [
                        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: WorkspaceStyle.ink,
                    ]))
                }
                content = message
            }
        case .guest(let guest):
            content = guestText(guest.message.text)
        case .plan(let entry, let plan):
            content = TranscriptText.markdown(plan.body(expanded: expanded.contains(item.id), finding: !findQuery.isEmpty),
                                              fileRoot: fileContext?.root, darkArtwork: dark, streaming: entry.value["streaming"].bool == true)
        case .thoughts(let entries):
            content = TranscriptText.markdown(joinedDetails(entries.compactMap { $0.value["text"].string }), role: .thought,
                                              fileRoot: fileContext?.root, darkArtwork: dark,
                                              streaming: entries.contains { $0.value["streaming"].bool == true })
        case .files(let changes):
            if fileLoads[item.id] != nil {
                content = TranscriptText.markdown("Loading file diffs…", role: .thought)
            } else if let error = fileErrors[item.id] {
                content = TranscriptText.markdown(error, role: .thought)
            } else {
                let patches = changes.map { change in
                    let detail = fileDetails[change.detailKey] ?? change.entry.value
                    let patch = detail["diffStr"].string
                    let texts = [detail["oldStr"].string, detail["newStr"].string]
                    let sections = zip(["Before", "After"], texts).compactMap { label, text in
                        text.map { "\(label)\n\($0)" }
                    }
                    let fallback = sections.isEmpty ? "No patch was recorded." : sections.joined(separator: "\n\n")
                    return change.paths.map(\.title).joined(separator: ", ") + "\n" + (patch ?? fallback)
                }
                content = TranscriptText.monospace(joinedDetails(patches), diff: true)
            }
        case .work(let entries):
            var remaining = 48_000
            let details = NSMutableAttributedString()
            for entry in entries where remaining > 0 {
                let entryActivity = activity(entry)
                let description = String(entryActivity.detail.prefix(remaining))
                remaining -= entryActivity.title.count + description.count
                if details.length > 0 { details.append(NSAttributedString(string: "\n\n")) }
                details.append(NSAttributedString(string: entryActivity.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: WorkspaceStyle.ink,
                ]))
                if !description.isEmpty && description != entryActivity.title {
                    details.append(NSAttributedString(string: "\n"))
                    details.append(entry.type == "command_execution" ? TranscriptText.monospace(description) :
                                       TranscriptText.markdown(description, fileRoot: fileContext?.root, darkArtwork: dark))
                }
            }
            content = details
        case .credit, .fork, .freshSession, .webPage:
            content = NSAttributedString()
        }
        rendered[item.id] = content
        return content
    }

    private func guestText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: WorkspaceStyle.ink])
    }

    private func joinedDetails(_ parts: [String]) -> String {
        var remaining = 48_000
        var excerpts: [String] = []
        for part in parts where remaining > 0 {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let excerpt = String(text.prefix(remaining))
            excerpts.append(excerpt)
            remaining -= excerpt.count + 2
        }
        return excerpts.joined(separator: "\n\n")
    }

    private func highlightedBody(_ item: EntryRow) -> NSAttributedString {
        let content = body(item)
        for request in TranscriptRenderingRequest.missing(in: content) {
            let alreadyLoading = renderingRows[request] != nil
            renderingRows[request, default: []].insert(item.id)
            if !alreadyLoading {
                request.load { [weak self] ready in self?.transcriptRenderingFinished(request, ready: ready) }
            }
        }
        return highlighted(content, item: item, occurrenceOffset: planTitleMatches(item, query: findQuery))
    }

    private func transcriptRenderingFinished(_ request: TranscriptRenderingRequest, ready: Bool) {
        guard let waiting = renderingRows.removeValue(forKey: request), ready else { return }
        let indexes = IndexSet(rows.indices.filter { index in
            let id = rows[index].id
            return waiting.contains(id) && rendered[id].map { TranscriptRenderingRequest.missing(in: $0).contains(request) } == true
        })
        guard !indexes.isEmpty else { return }
        let position = scrollPosition
        for index in indexes { rendered.removeValue(forKey: rows[index].id) }
        reload(indexes)
        restoreScrollPosition(position)
    }

    private func planTitleMatches(_ item: EntryRow, query: String) -> Int {
        guard case .plan(_, let plan) = item.content else { return 0 }
        return ThreadFindText.ranges(of: query, in: plan.title).count
    }

    private func highlighted(_ original: NSAttributedString, item: EntryRow, occurrenceOffset: Int = 0) -> NSAttributedString {
        guard !findQuery.isEmpty, let id = item.findID else { return original }
        let selection = TranscriptSelection(original)
        let matches = ThreadFindText.ranges(of: findQuery, in: selection.text)
        guard !matches.isEmpty else { return original }
        let output = NSMutableAttributedString(attributedString: original)
        var active: NSRange?
        for (index, match) in matches.enumerated() {
            let range = selection.displayedRange(for: match)
            if findMatch?.entryID == id && findMatch?.occurrence == index + occurrenceOffset {
                active = range
            } else {
                output.addAttribute(.backgroundColor, value: WorkspaceStyle.accent.withAlphaComponent(0.22), range: range)
            }
        }
        if let active {
            output.addAttributes([.backgroundColor: WorkspaceStyle.accent, .foregroundColor: WorkspaceStyle.canvas], range: active)
        }
        return output
    }

    private func activity(_ entry: TimelineEntry) -> (title: String, detail: String) {
        let value = entry.value
        let title = value["title"].string
        let fallback = title ?? entry.type.replacingOccurrences(of: "_", with: " ").capitalized
        return switch entry.type {
        case "proposed_plan": (title ?? "Proposed plan", value["markdown"].string ?? "")
        case "todo_list": (title ?? "Task list", value["steps"].array.compactMap { $0["text"].string ?? $0["title"].string }.joined(separator: "\n"))
        case "command_execution": (title ?? "Ran a command", [value["input"].string, value["output"].string].compactMap { $0 }.joined(separator: "\n"))
        case "approval_request": (title ?? "Approval requested", value["prompt"].string ?? value["reason"].string ?? "")
        case "user_input_request": (title ?? (value["questionAnswer"] == .null ? "Input requested" : "Questions answered"), questionDetails(value))
        case "error": ("Provider error", value["failure"]["message"].string ?? "The provider reported an error.")
        case "notification": (value["summary"].string ?? fallback, value["detail"].string ?? fallback)
        default: (fallback, value["message"].string ?? value["text"].string ?? fallback)
        }
    }

    private func questionDetails(_ item: Wire) -> String {
        let answers = item["questionAnswer"]["answers"]
        return item["questions"].array.compactMap { question in
            guard let text = question["question"].string, let id = question["id"].string else { return nil }
            let answer = answers[id]
            let reply = answer.string ?? answer.array.compactMap(\.string).joined(separator: ", ")
            return reply.isEmpty ? text : text + "\n" + reply
        }.joined(separator: "\n\n")
    }

    private func toggle(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if expanded.insert(id).inserted {
            if case .files(let changes) = rows[index].content { loadFileDiffs(changes, rowID: id) }
        } else {
            expanded.remove(id)
            fileLoads.removeValue(forKey: id)?.cancel()
        }
        rendered.removeValue(forKey: id)
        reload(IndexSet(integer: index))
    }

    private func loadFileDiffs(_ changes: [FileChange], rowID: String) {
        fileErrors.removeValue(forKey: rowID)
        guard let loadFileDetail else { return }
        let missing = changes.filter { change in
            fileDetails[change.detailKey] == nil && change.entry.value["diffStr"].string == nil
        }
        guard !missing.isEmpty else { return }
        fileLoads[rowID] = Task { [weak self] in
            guard let self else { return }
            do {
                for change in missing {
                    try Task.checkCancellation()
                    let detail = try await loadFileDetail(change.entry)
                    try Task.checkCancellation()
                    fileDetails[change.detailKey] = detail
                }
            } catch {
                guard !Task.isCancelled else { return }
                fileErrors[rowID] = error.localizedDescription
            }
            fileLoads.removeValue(forKey: rowID)
            rendered.removeValue(forKey: rowID)
            if let index = rows.firstIndex(where: { $0.id == rowID }) { reload(IndexSet(integer: index)) }
        }
    }

    private func reload(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: indexes)
        table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
    }
}

@MainActor
private final class TimelineScrollView: NSScrollView {
    var readingWidth: CGFloat? {
        didSet { if oldValue != readingWidth { tile() } }
    }

    override func tile() {
        super.tile()
        guard let readingWidth else { return }
        let area = contentView.frame
        let width = min(readingWidth, area.width)
        let leading = min(area.maxX - width, max(area.minX, bounds.midX - width / 2))
        contentView.frame = NSRect(x: leading, y: area.minY, width: width, height: area.height)
    }
}
