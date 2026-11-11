import AppKit

@MainActor
final class QueuedMessageEditor: NSWindowController, NSTextViewDelegate {
    private let original: QueuedMessage
    private let editor = CitationTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var retained: [Wire]
    private var files: [PickedAttachment] = []
    private var task: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var attempt: Workspace.QueueEditAttempt?
    private var available = true
    private lazy var attachments = ActionButton("Attachments", symbol: "paperclip", style: .subtle) { [weak self] in self?.attachmentMenu() }
    private lazy var add = ActionButton("Attach Files…", symbol: "plus", style: .subtle) { [weak self] in self?.chooseAttachments() }
    private lazy var save = ActionButton("Save Queued Message") { [weak self] in self?.submit() }
    private lazy var cancel = ActionButton("Cancel") { [weak self] in self?.closeSheet() }
    var onSubmit: (@MainActor (Workspace.QueueEditAttempt) async throws -> Void)?
    var onClose: (() -> Void)?

    init(message: QueuedMessage, terminalClipboardSource: TerminalContextClipboard.Source? = nil) {
        original = message
        retained = message.attachments
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 532, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Edit Queued Message"
        window.contentMinSize = NSSize(width: 440, height: 246)
        let surface = Surface(WorkspaceStyle.navigation)
        window.contentView = surface
        let heading = label("Edit Queued Message", size: 16, weight: .semibold, color: WorkspaceStyle.ink)
        let prompt = Surface(WorkspaceStyle.canvas, border: WorkspaceStyle.outline, radius: 8)
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = WorkspaceStyle.ink
        editor.insertionPointColor = WorkspaceStyle.ink
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.delegate = self
        editor.setAccessibilityLabel("Queued Message")
        editor.onReadAttachment = { [weak self] pasteboard in
            guard let self, task == nil, available else { return false }
            let inputs = AttachmentInput.read(pasteboard)
            guard !inputs.isEmpty else { return false }
            prepareAttachments(inputs)
            return true
        }
        fill(textScroller(editor, editable: true), in: prompt, inset: 2)
        editor.enableCitationEditing()
        editor.terminalClipboardSource = terminalClipboardSource
        editor.setPromptSource(message.displayText, contextRecords: message.context["records"].array)
        prompt.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        status.font = .systemFont(ofSize: 11.5)
        status.maximumNumberOfLines = 3
        cancel.keyEquivalent = "\u{1b}"
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command
        let tools = row([attachments, add, NSView()], spacing: 5)
        fill(column([heading, prompt, tools, status, row([NSView(), cancel, save])], spacing: 8, alignment: .width),
             in: surface, inset: 16)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onClose?() }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    }

    func setAvailable(_ available: Bool) {
        guard self.available != available else { return }
        self.available = available
        showStatus(available ? "" : "This message is no longer available to edit. You can copy your changes before closing.")
        render()
    }

    func textDidChange(_ notification: Notification) {
        if available, preparation == nil { showStatus("") }
        render()
    }

    private var content: Workspace.QueueEditContent {
        let text = editor.promptSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !retained.isEmpty || !files.isEmpty
        let prompt = hasAttachments && text.isEmpty ? QueuedMessage.attachmentOnlyText : text
        let replacement = retained == original.attachments && files.isEmpty ? nil : retained
        return .init(text: prompt, retained: replacement, files: files, terminalContextRecords: editor.terminalContextRecords)
    }

    private func render() {
        let count = retained.count + files.count
        attachments.title = count == 1 ? "1 attachment" : "\(count) attachments"
        attachments.setAccessibilityLabel(attachments.title)
        attachments.isHidden = count == 0
        attachments.isEnabled = task == nil && available
        add.isEnabled = task == nil && preparation == nil && available
        editor.isEditable = task == nil
        save.isEnabled = task == nil && preparation == nil && available && !content.text.isEmpty
        cancel.isEnabled = task == nil
        status.isHidden = status.stringValue.isEmpty
    }

    private func chooseAttachments() {
        guard task == nil, preparation == nil, available, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach Files"
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK { self?.prepareAttachments(panel.urls.map(AttachmentInput.file)) }
        }
    }

    private func prepareAttachments(_ inputs: [AttachmentInput]) {
        guard task == nil, available else { return }
        guard preparation == nil else {
            showStatus("Wait for the current attachments to finish preparing.", error: true)
            return
        }
        showStatus("Preparing attachments…")
        preparation = Task { [weak self] in
            defer {
                self?.preparation = nil
                self?.render()
            }
            do {
                let additions = try await AttachmentInput.prepare(inputs)
                try Task.checkCancellation()
                guard let self, available else { return }
                try PickedAttachment.validate(files + additions, retaining: retained)
                files += additions
                showStatus("")
            } catch {
                if !Task.isCancelled, let self, available { showStatus(error.localizedDescription, error: true) }
            }
        }
        render()
    }

    private func attachmentMenu() {
        guard task == nil, available else { return }
        let menu = NSMenu()
        let names = (retained.map { $0["name"].string ?? "Attachment" } + files.map(\.name))
            .map(BrowserAnnotationContext.attachmentLabel)
        for (index, name) in names.enumerated() {
            let item = menuItem("Remove \(name)", target: self, action: #selector(removeAttachment(_:)))
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: attachments.bounds.height), in: attachments)
    }

    @objc private func removeAttachment(_ item: NSMenuItem) {
        guard task == nil, available else { return }
        if retained.indices.contains(item.tag) { retained.remove(at: item.tag) }
        else {
            let index = item.tag - retained.count
            if files.indices.contains(index) { files.remove(at: index) }
        }
        if preparation == nil { showStatus("") }
        render()
    }

    private func submit() {
        let content = content
        guard task == nil, preparation == nil, available, !content.text.isEmpty, let onSubmit else { return }
        let attempt = attempt.flatMap { $0.content == content ? $0 : nil } ?? .init(content: content)
        self.attempt = attempt
        showStatus("Saving…")
        task = Task {
            do {
                try await onSubmit(attempt)
                task = nil
                closeSheet()
            } catch {
                task = nil
                showStatus(error.localizedDescription, error: true)
                render()
            }
        }
        render()
    }

    private func closeSheet() {
        guard task == nil, let window, let parent = window.sheetParent else { return }
        preparation?.cancel()
        parent.endSheet(window)
    }

    private func showStatus(_ message: String, error: Bool = false) {
        status.stringValue = message
        status.textColor = error ? WorkspaceStyle.negative : WorkspaceStyle.muted
    }
}
