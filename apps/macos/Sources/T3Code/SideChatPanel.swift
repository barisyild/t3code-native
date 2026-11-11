import AppKit

@MainActor
final class SideChatPanel: NSViewController {
    private struct Tab: Equatable {
        let id: String
        let title: String
        let working: Bool
    }

    let conversation: ConversationController
    private let workspace: Workspace
    private let threads = NSPopUpButton()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private lazy var bringBack = ActionButton("Bring Back", symbol: "arrow.turn.down.left", style: .subtle) { [weak self] in self?.merge() }
    private lazy var remove = ActionButton("Delete Side Chat", symbol: "trash", iconOnly: true, style: .subtle) { [weak self] in self?.confirmDelete() }
    private lazy var close = ActionButton("Close Side Chat", symbol: "xmark", iconOnly: true, style: .subtle) { [weak self] in self?.onClose?() }
    private var tabs: [Tab] = []
    private var reference: SideChatReference?
    private var busy = Set<SideChatReference>()
    private var problem: (SideChatReference, String)?
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
        conversation = ConversationController(workspace: workspace, embedded: true)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = Surface(WorkspaceStyle.navigation)
        threads.isBordered = false
        threads.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        threads.setAccessibilityLabel("Side Chat")
        threads.target = self
        threads.action = #selector(selectThread)
        notice.font = .systemFont(ofSize: 11.5)
        notice.textColor = WorkspaceStyle.negative
        notice.maximumNumberOfLines = 3
        let actions = row([threads, NSView(), bringBack, remove, close], spacing: 5)
        let heading = NSView()
        fill(actions, in: heading, inset: 7)
        heading.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let divider = Surface(WorkspaceStyle.line)
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        addChild(conversation)
        fill(column([heading, divider, notice, conversation.view], spacing: 0, alignment: .width), in: view)
    }

    func render(_ change: Workspace.Change) {
        guard let reference = workspace.sideChat else { return }
        let _ = view
        let changedThread = self.reference != reference
        self.reference = reference
        if changedThread || !change.intersection([.connection, .sidebar, .selection]).isEmpty {
            let next = workspace.data.sideChats(of: reference.parentID).map { Tab(id: $0.id, title: $0.title, working: $0.isWorking) }
            if next != tabs {
                tabs = next
                threads.removeAllItems()
                for tab in next {
                    let item = NSMenuItem(title: tab.title, action: nil, keyEquivalent: "")
                    item.representedObject = tab.id
                    if tab.working { item.image = WorkspaceStyle.symbol("circle.dotted", size: 11) }
                    threads.menu?.addItem(item)
                }
            }
            threads.select(threads.itemArray.first { $0.representedObject as? String == reference.threadID })
        }
        let idle = !busy.contains(reference)
        let blocked = workspace.bringBackBlockedReason
        bringBack.isEnabled = idle && blocked == nil
        bringBack.toolTip = blocked ?? "Include this reply with the main conversation’s next message."
        bringBack.setAccessibilityHelp(bringBack.toolTip)
        remove.isEnabled = idle && workspace.can("orchestration:operate")
        notice.stringValue = problem?.0 == reference ? problem?.1 ?? "" : ""
        notice.isHidden = notice.stringValue.isEmpty
        if changedThread { conversation.render(.all) }
        else if !change.intersection([.connection, .sidebar, .selection, .providers, .sideChat]).isEmpty {
            conversation.render(change.subtracting(.timeline))
        }
    }

    @objc private func selectThread() {
        if let id = threads.selectedItem?.representedObject as? String { onSelect?(id) }
    }

    private func merge() {
        guard let reference = workspace.sideChat, let connection = workspace.connectionID, workspace.bringBackBlockedReason == nil else { return }
        run(reference) { try await self.workspace.bringBackSideChat(reference, connection: connection) }
    }

    private func confirmDelete() {
        guard let reference = workspace.sideChat, let thread = workspace.sideChatThread,
              let connection = workspace.connectionID, workspace.can("orchestration:operate"),
              let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(thread.title)?"
        alert.informativeText = "This permanently clears the side chat’s conversation history."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Side Chat").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn else { return }
            self.run(reference) {
                try await self.workspace.removeSideChat(reference, connection: connection, onlyIfUnused: false)
                self.conversation.forgetSideChatDraft(reference)
                if self.workspace.sideChat == reference { self.workspace.hideSideChat() }
            }
        }
    }

    private func run(_ reference: SideChatReference, _ action: @escaping @MainActor () async throws -> Void) {
        guard busy.insert(reference).inserted else { return }
        problem = nil
        render(.sideChat)
        Task { [weak self] in
            guard let self else { return }
            defer { busy.remove(reference); render(.sideChat) }
            do { try await action() }
            catch {
                if workspace.sideChat == reference { problem = (reference, error.localizedDescription) }
            }
        }
    }
}
